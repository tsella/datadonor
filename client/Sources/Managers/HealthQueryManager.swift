import Foundation
import HealthKit
import UIKit

/// Carries immutable HealthKit query results across actor boundaries for off-MainActor mapping.
private struct UncheckedSampleBatch: @unchecked Sendable {
    let samples: [HKSample]
    let deletedObjects: [HKDeletedObject]
}

/// Carries immutable HealthKit query inputs across task-group boundaries.
private struct PageFetchInput: @unchecked Sendable {
    let healthStore: HKHealthStore
    let sampleType: HKSampleType
    let anchor: HKQueryAnchor?
    let anchorData: Data?
    let originalIndex: Int
    let limit: Int
}

private enum PageReadStatus: Sendable {
    case ok
    case databaseLocked
    case failed
}

private struct FetchedPage: Sendable {
    let typeIdentifier: String
    let originalIndex: Int
    let dataPoints: [HealthDataPoint]
    let deletedUuids: [String]
    let newAnchorData: Data?
    let tokenPart: String?
    let hitPageLimit: Bool
    let hadRawItems: Bool
    let status: PageReadStatus
}

private struct PendingMultiTypeBatch {
    var dataPoints: [HealthDataPoint] = []
    var deletedUuids: [String] = []
    var anchors: [String: Data] = [:]
    var tokenParts: [String] = []
    var typeIdentifiers: [String] = []
    var nextSweepOffset: Int?

    var isEmpty: Bool {
        dataPoints.isEmpty && deletedUuids.isEmpty
    }

    var itemCount: Int {
        dataPoints.count + deletedUuids.count
    }

    mutating func append(
        typeIdentifier: String,
        dataPoints: [HealthDataPoint],
        deletedUuids: [String],
        newAnchorData: Data?,
        tokenPart: String?,
        nextSweepOffset: Int?
    ) {
        self.dataPoints.append(contentsOf: dataPoints)
        self.deletedUuids.append(contentsOf: deletedUuids)
        if let newAnchorData {
            self.anchors[typeIdentifier] = newAnchorData
        }
        if let tokenPart {
            self.tokenParts.append(tokenPart)
        }
        self.typeIdentifiers.append(typeIdentifier)
        if let nextSweepOffset {
            self.nextSweepOffset = nextSweepOffset
        }
    }

    mutating func removeAll() {
        dataPoints.removeAll(keepingCapacity: true)
        deletedUuids.removeAll(keepingCapacity: true)
        anchors.removeAll(keepingCapacity: true)
        tokenParts.removeAll(keepingCapacity: true)
        typeIdentifiers.removeAll(keepingCapacity: true)
        nextSweepOffset = nil
    }
}

private struct EncodedBatch: Sendable {
    let payloadData: Data
    let recordCount: Int
    let uploadToken: String
    let newAnchorData: Data?
}

@MainActor
final class HealthQueryManager: ObservableObject {
    enum SyncOutcome {
        case completed
        case databaseLocked
        case cancelled
        case failed
        case skipped
    }

    let healthStore: HKHealthStore
    private let defaults: UserDefaults
    private let notificationManager: NotificationManager
    @Published var isSyncing = false
    @Published var totalRecordsSynced: Int
    private var isCancelled = false
    private var lastUIUpdateTime: Date = .distantPast
    /// Whether at least one non-empty batch (samples or deletions) was uploaded during this run.
    private var didUploadBatch = false

    init(
        healthStore: HKHealthStore = HKHealthStore(),
        defaults: UserDefaults = .standard,
        notificationManager: NotificationManager = .shared
    ) {
        self.healthStore = healthStore
        self.defaults = defaults
        self.notificationManager = notificationManager
        self.totalRecordsSynced = defaults.integer(forKey: "totalRecordsSynced")
    }
    
    func cancelSync() {
        isCancelled = true
    }
    
    // MARK: - Anchor storage
    //
    // Anchors live under one prefix, and every scan of them goes through anchorKeys(), so
    // the prefix is written in one place instead of four.

    private static let anchorPrefix = "anchor_"
    private static let sweepOffsetKey = "nextTypeSweepOffset"
    private static let lastFullSweepKey = "lastFullSweepTimestamp"
    private static let pendingFullResyncKey = "pendingFullResync"

    var lastFullSweepDate: Date {
        let ts = defaults.double(forKey: Self.lastFullSweepKey)
        return ts > 0 ? Date(timeIntervalSince1970: ts) : .distantPast
    }

    /// True after the user deliberately taps "Reset Sync State" and until a full sweep
    /// completes cleanly. Prevents `reconcileAnchorState()` from re-seeding old server
    /// checkpoints and silently undoing the reset.
    var isPendingFullResync: Bool {
        get { defaults.bool(forKey: Self.pendingFullResyncKey) }
        set { defaults.set(newValue, forKey: Self.pendingFullResyncKey) }
    }

    internal func anchorKeys() -> [String] {
        defaults.dictionaryRepresentation().keys
            .filter { $0.hasPrefix(Self.anchorPrefix) }
    }

    private func getAnchorAndData(for type: String) -> (anchor: HKQueryAnchor?, data: Data?) {
        if let data = defaults.data(forKey: Self.anchorPrefix + type),
           let anchor = try? NSKeyedUnarchiver.unarchivedObject(ofClass: HKQueryAnchor.self, from: data) {
            return (anchor, data)
        }
        return (nil, nil)
    }

    /// Stores an anchor that arrived from the server as archived bytes, after checking that
    /// it really is one. A corrupt checkpoint used to be written straight into the anchor
    /// namespace, where the next read failed and the type started from zero.
    internal func storeAnchorData(_ data: Data, for type: String) {
        guard (try? NSKeyedUnarchiver.unarchivedObject(ofClass: HKQueryAnchor.self, from: data)) != nil else {
            DataDonorLogger.shared.log("Ignoring an unreadable anchor for \(type).", level: .warn)
            return
        }
        defaults.set(data, forKey: Self.anchorPrefix + type)
    }
    
    /// Precomputed unit lookup table for all supported quantity types. Immutable after
    /// initialization, so it can be read safely from background mapping tasks without
    /// actor hops or locks.
    nonisolated private static let unitTable: [HKQuantityTypeIdentifier: HKUnit] = {
        var map: [HKQuantityTypeIdentifier: HKUnit] = [:]
        for id in HealthTypeCatalog.quantityIdentifiers {
            map[id] = buildUnit(for: id)
        }
        return map
    }()

    nonisolated private static func unit(for identifier: HKQuantityTypeIdentifier) -> HKUnit {
        unitTable[identifier] ?? buildUnit(for: identifier)
    }

    nonisolated private static func buildUnit(for identifier: HKQuantityTypeIdentifier) -> HKUnit {
        switch identifier {
        case .heartRate, .restingHeartRate, .walkingHeartRateAverage, .heartRateRecoveryOneMinute: return HKUnit.count().unitDivided(by: .minute())
        case .heartRateVariabilitySDNN: return HKUnit.secondUnit(with: .milli)
        case .vo2Max: return HKUnit(from: "ml/(kg*min)")
        case .oxygenSaturation, .bodyFatPercentage, .walkingAsymmetryPercentage, .walkingDoubleSupportPercentage, .atrialFibrillationBurden, .appleWalkingSteadiness: return HKUnit.percent()
        case .stepCount, .swimmingStrokeCount, .flightsClimbed, .numberOfTimesFallen, .uvExposure: return HKUnit.count()
        case .distanceWalkingRunning, .distanceCycling, .distanceSwimming, .distanceDownhillSnowSports, .walkingStepLength, .height, .underwaterDepth: return HKUnit.meter()
        case .activeEnergyBurned, .basalEnergyBurned, .dietaryEnergyConsumed: return HKUnit.kilocalorie()
        case .appleExerciseTime, .appleStandTime, .appleMoveTime: return HKUnit.minute()
        case .walkingSpeed: return HKUnit.meter().unitDivided(by: .second())
        case .environmentalAudioExposure, .headphoneAudioExposure: return HKUnit.decibelAWeightedSoundPressureLevel()
        case .respiratoryRate: return HKUnit.count().unitDivided(by: .minute())
        case .bloodPressureDiastolic, .bloodPressureSystolic: return HKUnit.millimeterOfMercury()
        case .bodyMass, .leanBodyMass: return HKUnit.gramUnit(with: .kilo)
        case .bodyMassIndex: return HKUnit.count()
        case .dietaryWater: return HKUnit.literUnit(with: .milli)
        case .waterTemperature, .bodyTemperature: return HKUnit.degreeCelsius()
        case .bloodGlucose: return HKUnit(from: "mg/dL")
        default:
            if #available(iOS 16.0, *), identifier == .appleSleepingWristTemperature { return HKUnit.degreeCelsius() }
            if #available(iOS 17.0, *), identifier == .timeInDaylight { return HKUnit.minute() }
            if #available(iOS 17.0, *), identifier == .physicalEffort { return HKUnit.kilocalorie().unitDivided(by: HKUnit.gramUnit(with: .kilo).unitMultiplied(by: HKUnit.hour())) }
            if #available(iOS 18.0, *), identifier == .workoutEffortScore { return HKUnit.appleEffortScore() }
            if #available(iOS 18.0, *), identifier == .estimatedWorkoutEffortScore { return HKUnit.appleEffortScore() }
            if #available(iOS 18.0, *), identifier == .appleSleepingBreathingDisturbances { return HKUnit.count() }
            return HKUnit.count()
        }
    }
    
    nonisolated private static func mapSample(_ sample: HKSample, formatter: ISO8601DateFormatter) -> HealthDataPoint? {
        let sampleMetadata: [String: String]? = {
            guard let meta = sample.metadata, !meta.isEmpty else { return nil }
            var dict = [String: String](minimumCapacity: meta.count)
            for (key, value) in meta {
                if let numberValue = value as? NSNumber {
                    dict[key] = numberValue.stringValue
                } else if let stringValue = value as? String {
                    dict[key] = stringValue
                } else if let dateValue = value as? Date {
                    dict[key] = formatter.string(from: dateValue)
                } else {
                    dict[key] = String(describing: value)
                }
            }
            return dict.isEmpty ? nil : dict
        }()
        
        if let quantitySample = sample as? HKQuantitySample {
            let identifier = HKQuantityTypeIdentifier(rawValue: sample.sampleType.identifier)
            let preferredUnit = unit(for: identifier)
            // Skip rather than store 0.0: a fabricated zero is indistinguishable from a real
            // measurement once it is in the database, and the anchor moves past it either way.
            guard quantitySample.quantity.is(compatibleWith: preferredUnit) else {
                DataDonorLogger.shared.log("Unit mismatch: \(sample.sampleType.identifier) sample unit \(quantitySample.quantity) is incompatible with preferred unit \(preferredUnit.unitString). Skipping sample.", level: .warn)
                return nil
            }
            let value = quantitySample.quantity.doubleValue(for: preferredUnit)
            return HealthDataPoint(
                type: sample.sampleType.identifier,
                value: .double(value),
                unit: preferredUnit.unitString,
                startDate: formatter.string(from: sample.startDate),
                endDate: formatter.string(from: sample.endDate),
                source: sample.sourceRevision.source.name,
                uuid: sample.uuid.uuidString,
                metadata: sampleMetadata
            )
        } else if let categorySample = sample as? HKCategorySample {
            return HealthDataPoint(
                type: sample.sampleType.identifier,
                value: .string("\(categorySample.value)"),
                unit: nil,
                startDate: formatter.string(from: sample.startDate),
                endDate: formatter.string(from: sample.endDate),
                source: sample.sourceRevision.source.name,
                uuid: sample.uuid.uuidString,
                metadata: sampleMetadata
            )
        } else if let workoutSample = sample as? HKWorkout {
            var workoutMeta = sampleMetadata ?? [String: String]()
            workoutMeta["duration"] = String(workoutSample.duration)
            if let energy = workoutSample.totalEnergyBurned {
                workoutMeta["totalEnergyBurned"] = String(energy.doubleValue(for: .kilocalorie()))
            }
            if let distance = workoutSample.totalDistance {
                workoutMeta["totalDistance"] = String(distance.doubleValue(for: .meter()))
            }
            workoutMeta["workoutActivityType"] = String(workoutSample.workoutActivityType.rawValue)
            
            return HealthDataPoint(
                type: sample.sampleType.identifier,
                value: .string(String(workoutSample.workoutActivityType.rawValue)),
                unit: nil,
                startDate: formatter.string(from: sample.startDate),
                endDate: formatter.string(from: sample.endDate),
                source: sample.sourceRevision.source.name,
                uuid: sample.uuid.uuidString,
                metadata: workoutMeta
            )
        }
        return nil
    }

    /// Maps samples, computes the deterministic upload token and encodes the JSON payload
    /// off the main actor so 5000-record batches never block UI rendering.
    nonisolated private static func buildEncodedBatch(
        batch: UncheckedSampleBatch,
        sampleTypeIdentifier: String,
        currentAnchorData: Data?,
        newAnchorData: Data?,
        deviceId: String
    ) throws -> EncodedBatch? {
        let formatter = ISO8601DateFormatter()
        var dataPoints: [HealthDataPoint] = []
        dataPoints.reserveCapacity(batch.samples.count)
        for sample in batch.samples {
            if let point = mapSample(sample, formatter: formatter) {
                dataPoints.append(point)
            }
        }
        let deletedUuids = batch.deletedObjects.map { $0.uuid.uuidString }

        if dataPoints.isEmpty && deletedUuids.isEmpty {
            return nil
        }

        let base64Anchor = newAnchorData?.base64EncodedString()
        let payload = HealthDataPayload(
            deviceId: deviceId,
            syncTimestamp: formatter.string(from: Date()),
            data: dataPoints,
            anchors: base64Anchor.map { [sampleTypeIdentifier: $0] },
            deletedUuids: deletedUuids.isEmpty ? nil : deletedUuids
        )

        let payloadData = try JSONEncoder().encode(payload)
        let uploadToken = SyncEngine.batchToken(
            type: sampleTypeIdentifier,
            anchorData: currentAnchorData,
            firstUUID: batch.samples.first?.uuid.uuidString ?? deletedUuids.first,
            lastUUID: batch.samples.last?.uuid.uuidString ?? deletedUuids.last,
            deletedCount: deletedUuids.count
        )

        return EncodedBatch(
            payloadData: payloadData,
            recordCount: dataPoints.count,
            uploadToken: uploadToken,
            newAnchorData: newAnchorData
        )
    }
    
    func getAllSupportedQuantityTypes() -> [HKQuantityTypeIdentifier] {
        HealthTypeCatalog.quantityIdentifiers
    }

    func getAllSupportedCategoryTypes() -> [HKCategoryTypeIdentifier] {
        HealthTypeCatalog.categoryIdentifiers
    }

    func getAllSupportedWorkoutTypes() -> [HKWorkoutType] {
        return [.workoutType()]
    }

    private enum ExhaustOutcome {
        case success
        case failed
        case cancelled
        case databaseLocked
    }

    nonisolated private static func isDatabaseInaccessible(_ error: Error) -> Bool {
        if let hkError = error as? HKError, hkError.code == .errorDatabaseInaccessible {
            return true
        }
        let nsError = error as NSError
        return nsError.domain == HKErrorDomain &&
            nsError.code == HKError.Code.errorDatabaseInaccessible.rawValue
    }

    nonisolated private static func isCancellationError(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        if let urlError = error as? URLError, urlError.code == .cancelled { return true }
        let nsError = error as NSError
        return nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled
    }

    /// Reads one page from HealthKit and maps its samples off the main actor.
    /// Used by the concurrent incremental sweep so ~54 types finish reading in <500ms.
    nonisolated private static func fetchSinglePage(_ input: PageFetchInput) async -> FetchedPage {
        let typeIdentifier = input.sampleType.identifier
        let (fetchedSamples, fetchedDeleted, newAnchor, queryError) = await withCheckedContinuation { continuation in
            let query = HKAnchoredObjectQuery(
                type: input.sampleType,
                predicate: nil,
                anchor: input.anchor,
                limit: input.limit
            ) { (_, samples, deletedObjects, returnedAnchor, error) in
                continuation.resume(returning: (samples, deletedObjects, returnedAnchor, error))
            }
            input.healthStore.execute(query)
        }

        if let queryError {
            if isDatabaseInaccessible(queryError) {
                return FetchedPage(
                    typeIdentifier: typeIdentifier,
                    originalIndex: input.originalIndex,
                    dataPoints: [],
                    deletedUuids: [],
                    newAnchorData: nil,
                    tokenPart: nil,
                    hitPageLimit: false,
                    hadRawItems: false,
                    status: .databaseLocked
                )
            }
            DataDonorLogger.shared.log(
                "HealthKit read failed for \(typeIdentifier): \(queryError.localizedDescription)",
                level: .error)
            return FetchedPage(
                typeIdentifier: typeIdentifier,
                originalIndex: input.originalIndex,
                dataPoints: [],
                deletedUuids: [],
                newAnchorData: nil,
                tokenPart: nil,
                hitPageLimit: false,
                hadRawItems: false,
                status: .failed
            )
        }

        let samplesToProcess = fetchedSamples ?? []
        let deletedToProcess = fetchedDeleted ?? []

        guard !samplesToProcess.isEmpty || !deletedToProcess.isEmpty else {
            return FetchedPage(
                typeIdentifier: typeIdentifier,
                originalIndex: input.originalIndex,
                dataPoints: [],
                deletedUuids: [],
                newAnchorData: nil,
                tokenPart: nil,
                hitPageLimit: false,
                hadRawItems: false,
                status: .ok
            )
        }

        let newAnchorData: Data? = newAnchor.flatMap {
            try? NSKeyedArchiver.archivedData(withRootObject: $0, requiringSecureCoding: true)
        }

        let formatter = ISO8601DateFormatter()
        var dataPoints: [HealthDataPoint] = []
        dataPoints.reserveCapacity(samplesToProcess.count)
        for sample in samplesToProcess {
            if let point = mapSample(sample, formatter: formatter) {
                dataPoints.append(point)
            }
        }
        let deletedUuids = deletedToProcess.map { $0.uuid.uuidString }
        let tokenPart = SyncEngine.batchToken(
            type: typeIdentifier,
            anchorData: input.anchorData,
            firstUUID: samplesToProcess.first?.uuid.uuidString ?? deletedUuids.first,
            lastUUID: samplesToProcess.last?.uuid.uuidString ?? deletedUuids.last,
            deletedCount: deletedUuids.count
        )

        return FetchedPage(
            typeIdentifier: typeIdentifier,
            originalIndex: input.originalIndex,
            dataPoints: dataPoints,
            deletedUuids: deletedUuids,
            newAnchorData: newAnchorData,
            tokenPart: tokenPart,
            hitPageLimit: samplesToProcess.count >= input.limit || deletedToProcess.count >= input.limit,
            hadRawItems: true,
            status: .ok
        )
    }

    /// Uploads a combined multi-type batch in a single HTTP request and commits all its
    /// local anchors atomically once the server acknowledges 2xx.
    private func flushPendingBatch(
        _ pending: inout PendingMultiTypeBatch,
        syncEngine: SyncEngine,
        serverURL: URL,
        apiKey: String,
        deviceId: String,
        transport: SyncEngine.Transport,
        timeout: TimeInterval
    ) async -> ExhaustOutcome {
        guard !pending.isEmpty else {
            pending.removeAll()
            return .success
        }

        let dataPoints = pending.dataPoints
        let deletedUuids = pending.deletedUuids
        let anchors = pending.anchors
        let tokenParts = pending.tokenParts
        let typeIdentifiers = pending.typeIdentifiers
        let nextSweepOffset = pending.nextSweepOffset

        do {
            let (payloadData, uploadToken) = try await Task.detached(priority: .utility) { () -> (Data, String) in
                let formatter = ISO8601DateFormatter()
                let encodedAnchors: [String: String] = anchors.mapValues { $0.base64EncodedString() }
                let payload = HealthDataPayload(
                    deviceId: deviceId,
                    syncTimestamp: formatter.string(from: Date()),
                    data: dataPoints,
                    anchors: encodedAnchors.isEmpty ? nil : encodedAnchors,
                    deletedUuids: deletedUuids.isEmpty ? nil : deletedUuids
                )
                let encoded = try JSONEncoder().encode(payload)
                let token = SyncEngine.combinedBatchToken(parts: tokenParts)
                return (encoded, token)
            }.value

            try await syncEngine.sync(
                payload: payloadData,
                serverURL: serverURL,
                apiKey: apiKey,
                token: uploadToken,
                transport: transport,
                timeout: timeout
            )

            for (typeId, anchorData) in anchors {
                defaults.set(anchorData, forKey: Self.anchorPrefix + typeId)
            }
            if let nextSweepOffset {
                defaults.set(nextSweepOffset, forKey: Self.sweepOffsetKey)
            }

            let count = dataPoints.count
            DataDonorLogger.shared.log(
                "Synced batched payload: \(count) record(s), \(deletedUuids.count) deletion(s) across \(typeIdentifiers.count) type(s).",
                level: .debug)

            let now = Date()
            let shouldUpdateTimestamp = now.timeIntervalSince(self.lastUIUpdateTime) >= 5.0
            self.addSyncedRecords(count)
            self.didUploadBatch = true
            if shouldUpdateTimestamp {
                defaults.set(now.timeIntervalSince1970, forKey: "lastSyncTimestamp")
                self.lastUIUpdateTime = now
            }

            pending.removeAll()
            return .success
        } catch {
            pending.removeAll()
            if isCancelled || Task.isCancelled || Self.isCancellationError(error) {
                isCancelled = true
                return .cancelled
            }
            let summary = typeIdentifiers.joined(separator: ", ")
            DataDonorLogger.shared.log(
                "Failed to sync batch (\(summary)): \(error.localizedDescription). Anchors not advanced; will retry next sync.",
                level: .error)
            notificationManager.reportSyncFailure(type: typeIdentifiers.first ?? "batch", error: error)
            return .failed
        }
    }
    
    /// Drains remaining pages of a sample type that exceeded a single page limit (e.g.
    /// historical backfills), uploading in 5000-record batches.
    private func exhaustQuery(
        for sampleType: HKSampleType,
        syncEngine: SyncEngine,
        serverURL: URL,
        apiKey: String,
        deviceId: String,
        transport: SyncEngine.Transport,
        timeout: TimeInterval,
        limit: Int = 5000
    ) async -> ExhaustOutcome {
        var (anchor, anchorData) = getAnchorAndData(for: sampleType.identifier)
        var hasMoreData = true

        while hasMoreData {
            if isCancelled || Task.isCancelled {
                isCancelled = true
                return .cancelled
            }
            let (fetchedSamples, fetchedDeletedObjects, newAnchor, queryError) = await withCheckedContinuation { continuation in
                let query = HKAnchoredObjectQuery(type: sampleType, predicate: nil, anchor: anchor, limit: limit) { (_, samples, deletedObjects, returnedAnchor, error) in
                    continuation.resume(returning: (samples, deletedObjects, returnedAnchor, error))
                }
                self.healthStore.execute(query)
            }

            // A failed read used to look like an empty page: the anchor advanced and the
            // run counted as clean. Treat it as a failure so the anchor stays put and the
            // next run retries this range — except when the device is simply locked, which
            // is normal in the background and should defer quietly without alerting.
            if let queryError {
                if Self.isDatabaseInaccessible(queryError) {
                    return .databaseLocked
                }
                DataDonorLogger.shared.log(
                    "HealthKit read failed for \(sampleType.identifier): \(queryError.localizedDescription)",
                    level: .error)
                return .failed
            }
            
            let samplesToProcess = fetchedSamples ?? []
            let deletedToProcess = fetchedDeletedObjects ?? []
            
            if !samplesToProcess.isEmpty || !deletedToProcess.isEmpty {
                let newAnchorData: Data? = newAnchor.flatMap {
                    try? NSKeyedArchiver.archivedData(withRootObject: $0, requiringSecureCoding: true)
                }
                let rawBatch = UncheckedSampleBatch(samples: samplesToProcess, deletedObjects: deletedToProcess)
                let typeIdentifier = sampleType.identifier
                let currentAnchorData = anchorData

                do {
                    let encodedBatch = try await Task.detached(priority: .utility) {
                        try Self.buildEncodedBatch(
                            batch: rawBatch,
                            sampleTypeIdentifier: typeIdentifier,
                            currentAnchorData: currentAnchorData,
                            newAnchorData: newAnchorData,
                            deviceId: deviceId
                        )
                    }.value

                    // Every sample in this batch was unmappable and there is nothing to delete.
                    // Skip the round trip, but still advance past them so we don't spin here.
                    guard let encodedBatch else {
                        if let newAnchorData {
                            defaults.set(newAnchorData, forKey: Self.anchorPrefix + typeIdentifier)
                        }
                        anchor = newAnchor
                        anchorData = newAnchorData
                        continue
                    }

                    // Returns only once the server has stored the batch — including the case
                    // where it acknowledged the upload while the app was killed. Anything
                    // else throws, so the anchor below is never advanced past records the
                    // server did not store.
                    try await syncEngine.sync(
                        payload: encodedBatch.payloadData,
                        serverURL: serverURL,
                        apiKey: apiKey,
                        token: encodedBatch.uploadToken,
                        transport: transport,
                        timeout: timeout
                    )

                    if let newAnchorData = encodedBatch.newAnchorData {
                        defaults.set(newAnchorData, forKey: Self.anchorPrefix + typeIdentifier)
                    }
                    anchor = newAnchor
                    anchorData = encodedBatch.newAnchorData
                    DataDonorLogger.shared.log(
                        "Synced \(encodedBatch.recordCount) records for \(typeIdentifier)", level: .debug)

                    // Update stats for DashboardView
                    let now = Date()
                    let shouldUpdateTimestamp = now.timeIntervalSince(self.lastUIUpdateTime) >= 5.0

                    // Count what we actually sent, not what HealthKit handed us: mapSample
                    // drops samples it cannot represent.
                    self.addSyncedRecords(encodedBatch.recordCount)
                    self.didUploadBatch = true

                    if shouldUpdateTimestamp {
                        defaults.set(now.timeIntervalSince1970, forKey: "lastSyncTimestamp")
                        self.lastUIUpdateTime = now
                    }
                } catch {
                    if isCancelled || Task.isCancelled || Self.isCancellationError(error) {
                        isCancelled = true
                        return .cancelled
                    }
                    // Stop this type here. The anchor stays where it is, so the next sync
                    // retries this exact batch instead of silently skipping it.
                    DataDonorLogger.shared.log("Failed to sync \(sampleType.identifier): \(error.localizedDescription). Anchor not advanced; will retry next sync.", level: .error)
                    notificationManager.reportSyncFailure(
                        type: sampleType.identifier, error: error)
                    return .failed
                }
            } else {
                hasMoreData = false
            }
        }
        return .success
    }

    /// Keeps the published count and its persisted copy in lockstep on the main actor.
    /// These used to be written from two threads, so they drifted apart and the drift
    /// survived relaunch because the property is seeded from UserDefaults.
    private func addSyncedRecords(_ count: Int) {
        totalRecordsSynced += count
        defaults.set(totalRecordsSynced, forKey: "totalRecordsSynced")
    }

    private func setSyncedRecords(_ count: Int) {
        totalRecordsSynced = count
        defaults.set(count, forKey: "totalRecordsSynced")
    }

    private func clearLocalSyncState() {
        for key in anchorKeys() {
            defaults.removeObject(forKey: key)
        }
        defaults.removeObject(forKey: Self.sweepOffsetKey)
        defaults.removeObject(forKey: Self.lastFullSweepKey)
        defaults.set(0.0, forKey: "lastSyncTimestamp")
        setSyncedRecords(0)
    }

    /// Clears all local anchors and sync counters so the next sync performs a full backfill.
    /// Refuses to run while a sync is in flight (preventing a mid-sync half-reset) and sets
    /// `isPendingFullResync` so `reconcileAnchorState` will not immediately re-seed old
    /// checkpoints from the server on the next Sync Now.
    @discardableResult
    func resetAllAnchors() -> Bool {
        guard !isSyncing else {
            DataDonorLogger.shared.log("Ignoring reset request: a sync is currently running.", level: .warn)
            return false
        }
        clearLocalSyncState()
        isPendingFullResync = true
        DataDonorLogger.shared.log("Reset all local anchors and sync state (full resync pending).", level: .info)
        return true
    }

    /// Orders the full catalog so high-signal types sync first, followed by the remaining
    /// types rotated from where the last sweep left off. Prevents late-catalog types from
    /// starving across short 30-second background refresh windows.
    private func orderedSweepTypes() -> (priority: [HKSampleType], secondary: [HKSampleType], startOffset: Int) {
        let quantityTypes = getAllSupportedQuantityTypes().compactMap { HKObjectType.quantityType(forIdentifier: $0) }
        let categoryTypes = getAllSupportedCategoryTypes().compactMap { HKObjectType.categoryType(forIdentifier: $0) }
        let all = quantityTypes + categoryTypes + getAllSupportedWorkoutTypes()

        let prioritySet = HealthTypeCatalog.priorityIdentifiers
        var priority: [HKSampleType] = []
        var secondary: [HKSampleType] = []

        for type in all {
            if prioritySet.contains(type.identifier) {
                priority.append(type)
            } else {
                secondary.append(type)
            }
        }

        guard !secondary.isEmpty else {
            return (priority, [], 0)
        }
        let rawOffset = max(0, defaults.integer(forKey: Self.sweepOffsetKey))
        let offset = rawOffset % secondary.count
        let rotated = Array(secondary[offset...]) + Array(secondary[..<offset])
        return (priority, rotated, offset)
    }
    
    /// - Parameters:
    ///   - types: restrict the sweep to these types (an observer wake passes the ones that
    ///     changed). Nil means the full sweep.
    ///   - reconcileAnchors: ask the server what it holds before running. Skipped for
    ///     observer wakes, where the extra round trip costs most of the runtime window.
    ///   - transport: `.immediate` for background wakes (avoids `nsurlsessiond` discretionary
    ///     deferral); `.background` for foreground-initiated syncs/backfills.
    ///   - sendHeartbeatWhenEmpty: whether to POST a lightweight heartbeat when no new samples
    ///     were found (defaults to true for full sweeps).
    @discardableResult
    func performSync(syncEngine: SyncEngine,
                     serverURL: URL?,
                     apiKey: String,
                     types: [HKSampleType]? = nil,
                     reconcileAnchors: Bool = true,
                     transport: SyncEngine.Transport = .background,
                     sendHeartbeatWhenEmpty: Bool = true) async -> SyncOutcome {
        guard let url = serverURL else {
            DataDonorLogger.shared.log("Skipping sync: No server URL resolved.", level: .warn)
            return .skipped
        }
        
        // Guard against overlapping runs: discovery, the manual button and the background
        // task can all fire performSync, and concurrent runs corrupt the shared anchors.
        guard !isSyncing else {
            DataDonorLogger.shared.log("Skipping sync: another sync is already running.", level: .info)
            return .skipped
        }

        DataDonorLogger.shared.log("Starting health data extraction loop.", level: .info)

        isSyncing = true
        isCancelled = false
        didUploadBatch = false

        defer { isSyncing = false }

        let deviceId = UIDevice.current.identifierForVendor?.uuidString ?? "unknown"
        let uploadTimeout: TimeInterval = (transport == .immediate) ? 20 : 300
        let pageLimit = 5000
        let maxBatchRecords = 5000
        let readConcurrency = 8

        if reconcileAnchors {
            await reconcileAnchorState(syncEngine: syncEngine, serverURL: url, apiKey: apiKey, deviceId: deviceId)
        }

        if isCancelled || Task.isCancelled {
            return .cancelled
        }

        let isFullSweep = (types == nil)
        let allTypes: [HKSampleType]
        let priorityCount: Int
        let secondaryTotal: Int
        let initialOffset: Int

        if let types {
            allTypes = types
            priorityCount = types.count
            secondaryTotal = 0
            initialOffset = 0
        } else {
            let ordered = orderedSweepTypes()
            allTypes = ordered.priority + ordered.secondary
            priorityCount = ordered.priority.count
            secondaryTotal = ordered.secondary.count
            initialOffset = ordered.startOffset
        }

        var failedTypes: [String] = []
        var wasDatabaseLocked = false
        var pendingBatch = PendingMultiTypeBatch()

        func nextSweepOffset(forIndex index: Int) -> Int? {
            guard secondaryTotal > 0 && index >= priorityCount else { return nil }
            let completedSecondary = index - priorityCount + 1
            return (initialOffset + completedSecondary) % secondaryTotal
        }

        // Read types in bounded concurrent chunks and pack multiple incremental types into
        // single HTTP POSTs. Any type that hits `pageLimit` (a large backlog) flushes the
        // accumulated batch and immediately drains its remaining pages via `exhaustQuery`.
        var chunkStart = 0
        while chunkStart < allTypes.count {
            if isCancelled || Task.isCancelled {
                isCancelled = true
                DataDonorLogger.shared.log("Sync was cancelled.", level: .info)
                break
            }

            let chunkEnd = min(chunkStart + readConcurrency, allTypes.count)
            var inputs: [PageFetchInput] = []
            inputs.reserveCapacity(chunkEnd - chunkStart)
            for idx in chunkStart..<chunkEnd {
                let sampleType = allTypes[idx]
                let (anchor, anchorData) = getAnchorAndData(for: sampleType.identifier)
                inputs.append(PageFetchInput(
                    healthStore: healthStore,
                    sampleType: sampleType,
                    anchor: anchor,
                    anchorData: anchorData,
                    originalIndex: idx,
                    limit: pageLimit
                ))
            }

            let pages = await withTaskGroup(of: FetchedPage.self, returning: [FetchedPage].self) { group in
                for input in inputs {
                    group.addTask(priority: .utility) {
                        await Self.fetchSinglePage(input)
                    }
                }
                var collected: [FetchedPage] = []
                collected.reserveCapacity(inputs.count)
                for await page in group {
                    collected.append(page)
                }
                return collected.sorted { $0.originalIndex < $1.originalIndex }
            }

            if pages.contains(where: { $0.status == .databaseLocked }) {
                DataDonorLogger.shared.log(
                    "HealthKit database is locked (protected data unavailable); deferring remaining types.",
                    level: .info)
                wasDatabaseLocked = true
                break
            }

            for page in pages {
                if isCancelled || Task.isCancelled {
                    isCancelled = true
                    break
                }

                let sweepOffset = nextSweepOffset(forIndex: page.originalIndex)

                switch page.status {
                case .databaseLocked:
                    wasDatabaseLocked = true
                case .failed:
                    failedTypes.append(page.typeIdentifier)
                case .ok:
                    if !page.hadRawItems {
                        if pendingBatch.isEmpty, let sweepOffset {
                            defaults.set(sweepOffset, forKey: Self.sweepOffsetKey)
                        }
                        continue
                    }

                    // All samples were unmappable and there were no deletions; advance
                    // anchor without a network round trip.
                    if page.dataPoints.isEmpty && page.deletedUuids.isEmpty {
                        if let newAnchorData = page.newAnchorData {
                            defaults.set(newAnchorData, forKey: Self.anchorPrefix + page.typeIdentifier)
                        }
                        if pendingBatch.isEmpty, let sweepOffset {
                            defaults.set(sweepOffset, forKey: Self.sweepOffsetKey)
                        }
                        continue
                    }

                    // Flush before exceeding the batch cap so payloads stay well bounded.
                    if !pendingBatch.isEmpty && pendingBatch.itemCount + page.dataPoints.count + page.deletedUuids.count > maxBatchRecords {
                        let batchTypes = pendingBatch.typeIdentifiers
                        let flushOutcome = await flushPendingBatch(
                            &pendingBatch,
                            syncEngine: syncEngine,
                            serverURL: url,
                            apiKey: apiKey,
                            deviceId: deviceId,
                            transport: transport,
                            timeout: uploadTimeout
                        )
                        if flushOutcome == .cancelled {
                            isCancelled = true
                            break
                        } else if flushOutcome == .failed {
                            failedTypes.append(contentsOf: batchTypes)
                        }
                    }

                    pendingBatch.append(
                        typeIdentifier: page.typeIdentifier,
                        dataPoints: page.dataPoints,
                        deletedUuids: page.deletedUuids,
                        newAnchorData: page.newAnchorData,
                        tokenPart: page.tokenPart,
                        nextSweepOffset: sweepOffset
                    )

                    // If this type filled a full page, flush its first page now so its anchor
                    // advances, then drain the remaining pages sequentially.
                    if page.hitPageLimit {
                        let batchTypes = pendingBatch.typeIdentifiers
                        let flushOutcome = await flushPendingBatch(
                            &pendingBatch,
                            syncEngine: syncEngine,
                            serverURL: url,
                            apiKey: apiKey,
                            deviceId: deviceId,
                            transport: transport,
                            timeout: uploadTimeout
                        )
                        switch flushOutcome {
                        case .cancelled:
                            isCancelled = true
                        case .failed:
                            failedTypes.append(contentsOf: batchTypes)
                        case .databaseLocked:
                            wasDatabaseLocked = true
                        case .success:
                            let drainOutcome = await exhaustQuery(
                                for: allTypes[page.originalIndex],
                                syncEngine: syncEngine,
                                serverURL: url,
                                apiKey: apiKey,
                                deviceId: deviceId,
                                transport: transport,
                                timeout: uploadTimeout,
                                limit: pageLimit
                            )
                            switch drainOutcome {
                            case .success:
                                if let sweepOffset {
                                    defaults.set(sweepOffset, forKey: Self.sweepOffsetKey)
                                }
                            case .failed:
                                failedTypes.append(page.typeIdentifier)
                            case .cancelled:
                                isCancelled = true
                            case .databaseLocked:
                                wasDatabaseLocked = true
                            }
                        }
                    }
                }

                if wasDatabaseLocked || isCancelled {
                    break
                }
            }

            if wasDatabaseLocked || isCancelled {
                break
            }
            chunkStart = chunkEnd
        }

        // Flush any remaining batched incremental records in one final request.
        if !pendingBatch.isEmpty && !wasDatabaseLocked && !isCancelled && !Task.isCancelled {
            let batchTypes = pendingBatch.typeIdentifiers
            let flushOutcome = await flushPendingBatch(
                &pendingBatch,
                syncEngine: syncEngine,
                serverURL: url,
                apiKey: apiKey,
                deviceId: deviceId,
                transport: transport,
                timeout: uploadTimeout
            )
            if flushOutcome == .cancelled {
                isCancelled = true
            } else if flushOutcome == .failed {
                failedTypes.append(contentsOf: batchTypes)
            }
        }

        if wasDatabaseLocked {
            return .databaseLocked
        }

        if isCancelled || Task.isCancelled {
            return .cancelled
        }

        // Only a clean run moves "last synced". A run where types failed, or one that was
        // cancelled, leaves the previous value.
        if failedTypes.isEmpty {
            let now = Date()
            defaults.set(now.timeIntervalSince1970, forKey: "lastSyncTimestamp")
            if isFullSweep {
                defaults.set(now.timeIntervalSince1970, forKey: Self.lastFullSweepKey)
                isPendingFullResync = false
            }
            self.lastUIUpdateTime = now
            // Only a clean full sweep clears the failure streak; a 1-type observer wake
            // succeeding must not mask a persistent failure in another data type.
            recordCompletionOutcome(failedTypeCount: 0, isFullSweep: isFullSweep)
            DataDonorLogger.shared.log("Completed health data extraction loop.", level: .info)
        } else {
            // Anchors for these types were left in place, so the next run retries them.
            DataDonorLogger.shared.log(
                "Completed extraction loop with \(failedTypes.count) failed type(s): \(failedTypes.joined(separator: ", ")). These will retry on the next sync.",
                level: .warn)
            // The owner hears about a persistent problem, not a blip: three failing
            // runs in a row, then at most one alert an hour.
            if recordCompletionOutcome(failedTypeCount: failedTypes.count, isFullSweep: isFullSweep) {
                notificationManager.sendSyncErrorNotification(
                    message: "\(failedTypes.count) data type(s) failed on 3 syncs in a row. The app keeps retrying.")
            }
        }

        // Heartbeat. A run that uploaded nothing still tells the server this device is
        // alive and which anchors it holds, so "nothing new today" stays distinguishable
        // from "the app stopped syncing".
        if !didUploadBatch && sendHeartbeatWhenEmpty && failedTypes.isEmpty {
            await sendHeartbeat(syncEngine: syncEngine, serverURL: url, apiKey: apiKey, deviceId: deviceId)
        }

        return failedTypes.isEmpty ? .completed : .failed
    }

    @discardableResult
    internal func recordCompletionOutcome(failedTypeCount: Int, isFullSweep: Bool) -> Bool {
        if failedTypeCount == 0 && !isFullSweep {
            return false
        }
        return notificationManager.recordSyncOutcome(failedTypeCount: failedTypeCount)
    }

    /// Decides which anchor set to trust.
    ///
    /// A type keeps its local anchor unless the app holds none at all (the reinstall case),
    /// EXCEPT when `isPendingFullResync` is true (the user explicitly tapped "Reset Sync State"),
    /// in which case server checkpoints are NOT seeded back until a full backfill finishes.
    private func reconcileAnchorState(syncEngine: SyncEngine, serverURL: URL, apiKey: String, deviceId: String) async {
        if isPendingFullResync {
            DataDonorLogger.shared.log(
                "Skipping server checkpoint seed: deliberate full resync is pending.", level: .info)
            return
        }

        do {
            guard let checkpointData = try await syncEngine.fetchServerCheckpoint(
                serverURL: serverURL, apiKey: apiKey, deviceId: deviceId) else {
                DataDonorLogger.shared.log(
                    "Failed to fetch server checkpoints (nil response). Proceeding with local state.", level: .warn)
                return
            }

            applyServerCheckpoints(checkpointData.checkpoints, totalRecords: checkpointData.totalRecords)
        } catch {
            DataDonorLogger.shared.log(
                "Failed to fetch server checkpoint: \(error.localizedDescription). Proceeding with local state.",
                level: .warn)
        }
    }

    internal func applyServerCheckpoints(_ checkpoints: [String: String], totalRecords: Int) {
        if isPendingFullResync {
            DataDonorLogger.shared.log(
                "Ignoring server checkpoints while deliberate full resync is pending.", level: .info)
            return
        }

        let localAnchorKeys = Set(anchorKeys())
        setSyncedRecords(max(totalRecords, totalRecordsSynced))

        if checkpoints.isEmpty {
            DataDonorLogger.shared.log("Server holds no checkpoints for this device.", level: .info)
            if localAnchorKeys.isEmpty {
                DataDonorLogger.shared.log("No local anchors either: starting a full sync.", level: .info)
                clearLocalSyncState()
            }
            return
        }

        if localAnchorKeys.isEmpty {
            DataDonorLogger.shared.log("No local anchors; seeding them from the server.", level: .info)
            for (dataType, base64Str) in checkpoints {
                if let data = Data(base64Encoded: base64Str) {
                    storeAnchorData(data, for: dataType)
                }
            }
            return
        }

        var seeded = 0
        for (dataType, base64Str) in checkpoints where !localAnchorKeys.contains("anchor_\(dataType)") {
            if let data = Data(base64Encoded: base64Str) {
                storeAnchorData(data, for: dataType)
                seeded += 1
            }
        }
        DataDonorLogger.shared.log(
            "Kept \(localAnchorKeys.count) local anchor(s); seeded \(seeded) missing one(s) from the server.",
            level: .info)
    }

    /// Posts the local anchors with an empty data array. The server accepts it, refreshes
    /// the checkpoint timestamp and writes no rows.
    private func sendHeartbeat(syncEngine: SyncEngine, serverURL: URL, apiKey: String, deviceId: String) async {
        var anchors: [String: String] = [:]
        for key in anchorKeys() {
            if let data = defaults.data(forKey: key) {
                anchors[String(key.dropFirst(Self.anchorPrefix.count))] = data.base64EncodedString()
            }
        }
        guard !anchors.isEmpty else { return }

        let payload = HealthDataPayload(
            deviceId: deviceId,
            syncTimestamp: ISO8601DateFormatter().string(from: Date()),
            data: [],
            anchors: anchors,
            deletedUuids: nil
        )
        do {
            let encoded = try JSONEncoder().encode(payload)
            try await syncEngine.sync(
                payload: encoded,
                serverURL: serverURL,
                apiKey: apiKey,
                transport: .immediate,
                timeout: 10
            )
            DataDonorLogger.shared.log("Heartbeat sent with \(anchors.count) anchor(s).", level: .debug)
        } catch {
            DataDonorLogger.shared.log("Heartbeat failed: \(error.localizedDescription)", level: .warn)
        }
    }
}
