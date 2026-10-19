import Foundation
import HealthKit
import UIKit

/// Carries immutable HealthKit query results across actor boundaries for off-MainActor mapping.
private struct UncheckedSampleBatch: @unchecked Sendable {
    let samples: [HKSample]
    let deletedObjects: [HKDeletedObject]
}

private struct EncodedBatch: Sendable {
    let payloadData: Data
    let recordCount: Int
    let uploadToken: String
    let newAnchorData: Data?
}

@MainActor
final class HealthQueryManager: ObservableObject {
    let healthStore: HKHealthStore
    @Published var isSyncing = false
    @Published var totalRecordsSynced: Int = UserDefaults.standard.integer(forKey: "totalRecordsSynced")
    private var isCancelled = false
    private var lastUIUpdateTime: Date = .distantPast
    /// Records accepted by the server during the current run. Drives the heartbeat.
    private var uploadedRecords = 0

    init(healthStore: HKHealthStore = HKHealthStore()) {
        self.healthStore = healthStore
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

    private func anchorKeys() -> [String] {
        UserDefaults.standard.dictionaryRepresentation().keys
            .filter { $0.hasPrefix(Self.anchorPrefix) }
    }

    private func getAnchorAndData(for type: String) -> (anchor: HKQueryAnchor?, data: Data?) {
        if let data = UserDefaults.standard.data(forKey: Self.anchorPrefix + type),
           let anchor = try? NSKeyedUnarchiver.unarchivedObject(ofClass: HKQueryAnchor.self, from: data) {
            return (anchor, data)
        }
        return (nil, nil)
    }

    /// Stores an anchor that arrived from the server as archived bytes, after checking that
    /// it really is one. A corrupt checkpoint used to be written straight into the anchor
    /// namespace, where the next read failed and the type started from zero.
    private func storeAnchorData(_ data: Data, for type: String) {
        guard (try? NSKeyedUnarchiver.unarchivedObject(ofClass: HKQueryAnchor.self, from: data)) != nil else {
            DataDonorLogger.shared.log("Ignoring an unreadable anchor for \(type).", level: .warn)
            return
        }
        UserDefaults.standard.set(data, forKey: Self.anchorPrefix + type)
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
        case databaseLocked
    }

    private static func isDatabaseInaccessible(_ error: Error) -> Bool {
        if let hkError = error as? HKError, hkError.code == .errorDatabaseInaccessible {
            return true
        }
        let nsError = error as NSError
        return nsError.domain == HKErrorDomain &&
            nsError.code == HKError.Code.errorDatabaseInaccessible.rawValue
    }
    
    /// Drains a sample type, uploading in batches.
    /// `limit` is the HealthKit page size *and* the upload batch size. At 5000 a typical
    /// batch encodes to a few MB against the server's 50MB body limit, so the headroom is
    /// large; the win is cutting round trips ~5x on a multi-million-record backfill.
    private func exhaustQuery(
        for sampleType: HKSampleType,
        syncEngine: SyncEngine,
        serverURL: URL,
        apiKey: String,
        deviceId: String,
        limit: Int = 5000
    ) async -> ExhaustOutcome {
        var (anchor, anchorData) = getAnchorAndData(for: sampleType.identifier)
        var hasMoreData = true

        while hasMoreData {
            if isCancelled { break }
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
                            UserDefaults.standard.set(newAnchorData, forKey: Self.anchorPrefix + typeIdentifier)
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
                        token: encodedBatch.uploadToken
                    )

                    if let newAnchorData = encodedBatch.newAnchorData {
                        UserDefaults.standard.set(newAnchorData, forKey: Self.anchorPrefix + typeIdentifier)
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
                    self.uploadedRecords += encodedBatch.recordCount

                    if shouldUpdateTimestamp {
                        UserDefaults.standard.set(now.timeIntervalSince1970, forKey: "lastSyncTimestamp")
                        self.lastUIUpdateTime = now
                    }
                } catch {
                    // Stop this type here. The anchor stays where it is, so the next sync
                    // retries this exact batch instead of silently skipping it.
                    DataDonorLogger.shared.log("Failed to sync \(sampleType.identifier): \(error.localizedDescription). Anchor not advanced; will retry next sync.", level: .error)
                    NotificationManager.shared.reportSyncFailure(
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
        UserDefaults.standard.set(totalRecordsSynced, forKey: "totalRecordsSynced")
    }

    private func setSyncedRecords(_ count: Int) {
        totalRecordsSynced = count
        UserDefaults.standard.set(count, forKey: "totalRecordsSynced")
    }

    /// Clears all local anchors and sync counters so the next sync performs a full backfill.
    func resetAllAnchors() {
        for key in anchorKeys() {
            UserDefaults.standard.removeObject(forKey: key)
        }
        UserDefaults.standard.removeObject(forKey: Self.sweepOffsetKey)
        UserDefaults.standard.set(0.0, forKey: "lastSyncTimestamp")
        setSyncedRecords(0)
        DataDonorLogger.shared.log("Reset all local anchors and sync state.", level: .info)
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
        let offset = UserDefaults.standard.integer(forKey: Self.sweepOffsetKey) % secondary.count
        let rotated = Array(secondary[offset...]) + Array(secondary[..<offset])
        return (priority, rotated, offset)
    }
    
    /// - Parameters:
    ///   - types: restrict the sweep to these types (an observer wake passes the one that
    ///     changed). Nil means the full sweep.
    ///   - reconcileAnchors: ask the server what it holds before running. Skipped for
    ///     observer wakes, where the extra round trip costs most of the runtime window.
    /// - Returns: true when every type reached its anchor.
    @discardableResult
    func performSync(syncEngine: SyncEngine,
                     serverURL: URL?,
                     apiKey: String,
                     types: [HKSampleType]? = nil,
                     reconcileAnchors: Bool = true) async -> Bool {
        guard let url = serverURL else {
            DataDonorLogger.shared.log("Skipping sync: No server URL resolved.", level: .warn)
            return false
        }
        
        // Guard against overlapping runs: discovery, the manual button and the background
        // task can all fire performSync, and concurrent runs corrupt the shared anchors.
        guard !isSyncing else {
            DataDonorLogger.shared.log("Skipping sync: another sync is already running.", level: .info)
            return false
        }

        DataDonorLogger.shared.log("Starting health data extraction loop.", level: .info)

        isSyncing = true
        isCancelled = false
        uploadedRecords = 0

        defer { isSyncing = false }

        let deviceId = UIDevice.current.identifierForVendor?.uuidString ?? "unknown"

        if reconcileAnchors {
            await reconcileAnchorState(syncEngine: syncEngine, serverURL: url, apiKey: apiKey, deviceId: deviceId)
        }

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

        for (index, sampleType) in allTypes.enumerated() {
            if isCancelled {
                DataDonorLogger.shared.log("Sync was cancelled by user.", level: .info)
                break
            }
            let outcome = await exhaustQuery(
                for: sampleType,
                syncEngine: syncEngine,
                serverURL: url,
                apiKey: apiKey,
                deviceId: deviceId
            )
            switch outcome {
            case .success:
                if secondaryTotal > 0 && index >= priorityCount {
                    let completedSecondary = index - priorityCount + 1
                    let nextOffset = (initialOffset + completedSecondary) % secondaryTotal
                    UserDefaults.standard.set(nextOffset, forKey: Self.sweepOffsetKey)
                }
            case .failed:
                failedTypes.append(sampleType.identifier)
            case .databaseLocked:
                DataDonorLogger.shared.log(
                    "HealthKit database is locked (protected data unavailable); deferring remaining types.",
                    level: .info)
                wasDatabaseLocked = true
            }
            if wasDatabaseLocked {
                break
            }
        }

        if wasDatabaseLocked {
            return false
        }

        // Only a clean run moves "last synced". A run where every type failed, or one the
        // user stopped, leaves the previous value: the dashboard renders this key as the
        // last successful sync, and a cancelled run has not synced anything.
        if failedTypes.isEmpty && !isCancelled {
            UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: "lastSyncTimestamp")
            self.lastUIUpdateTime = Date()
        }

        if failedTypes.isEmpty {
            _ = NotificationManager.shared.recordSyncOutcome(failedTypeCount: 0)
            DataDonorLogger.shared.log("Completed health data extraction loop.", level: .info)
        } else {
            // Anchors for these types were left in place, so the next run retries them.
            DataDonorLogger.shared.log(
                "Completed extraction loop with \(failedTypes.count) failed type(s): \(failedTypes.joined(separator: ", ")). These will retry on the next sync.",
                level: .warn)
            // The owner hears about a persistent problem, not a blip: three failing
            // runs in a row, then at most one alert an hour.
            if NotificationManager.shared.recordSyncOutcome(failedTypeCount: failedTypes.count) {
                NotificationManager.shared.sendSyncErrorNotification(
                    message: "\(failedTypes.count) data type(s) failed on 3 syncs in a row. The app keeps retrying.")
            }
        }

        // Heartbeat. A run that uploaded nothing still tells the server this device is
        // alive and which anchors it holds, so "nothing new today" stays distinguishable
        // from "the app stopped syncing". Without it the two look identical in the archive.
        if uploadedRecords == 0 && !isCancelled {
            await sendHeartbeat(syncEngine: syncEngine, serverURL: url, apiKey: apiKey, deviceId: deviceId)
        }

        return failedTypes.isEmpty && !isCancelled
    }

    /// Decides which anchor set to trust.
    ///
    /// This used to replace local anchors with the server's on every run. When an earlier
    /// upload failed, the server's anchor was behind and the app re-walked ranges it had
    /// already delivered, lengthening each run and raising the chance of another expiry.
    /// A type now keeps its local anchor unless the app holds none at all, which is the
    /// reinstall case the server copy exists for.
    ///
    /// Consequence: a server restored from an older backup will not pull the archive back
    /// by itself. "Reset sync state" is the deliberate path for that.
    private func reconcileAnchorState(syncEngine: SyncEngine, serverURL: URL, apiKey: String, deviceId: String) async {
        let localAnchorKeys = Set(anchorKeys())

        do {
            guard let checkpointData = try await syncEngine.fetchServerCheckpoint(
                serverURL: serverURL, apiKey: apiKey, deviceId: deviceId) else {
                DataDonorLogger.shared.log(
                    "Failed to fetch server checkpoints (nil response). Proceeding with local state.", level: .warn)
                return
            }

            setSyncedRecords(max(checkpointData.totalRecords, totalRecordsSynced))

            if checkpointData.checkpoints.isEmpty {
                DataDonorLogger.shared.log("Server holds no checkpoints for this device.", level: .info)
                if localAnchorKeys.isEmpty {
                    DataDonorLogger.shared.log("No local anchors either: forcing a full resync.", level: .info)
                    resetAllAnchors()
                }
                return
            }

            if localAnchorKeys.isEmpty {
                DataDonorLogger.shared.log("No local anchors; seeding them from the server.", level: .info)
                for (dataType, base64Str) in checkpointData.checkpoints {
                    if let data = Data(base64Encoded: base64Str) {
                        storeAnchorData(data, for: dataType)
                    }
                }
                return
            }

            var seeded = 0
            for (dataType, base64Str) in checkpointData.checkpoints where !localAnchorKeys.contains("anchor_\(dataType)") {
                if let data = Data(base64Encoded: base64Str) {
                    storeAnchorData(data, for: dataType)
                    seeded += 1
                }
            }
            DataDonorLogger.shared.log(
                "Kept \(localAnchorKeys.count) local anchor(s); seeded \(seeded) missing one(s) from the server.",
                level: .info)
        } catch {
            DataDonorLogger.shared.log(
                "Failed to fetch server checkpoint: \(error.localizedDescription). Proceeding with local state.",
                level: .warn)
        }
    }

    /// Posts the local anchors with an empty data array. The server accepts it, refreshes
    /// the checkpoint timestamp and writes no rows.
    private func sendHeartbeat(syncEngine: SyncEngine, serverURL: URL, apiKey: String, deviceId: String) async {
        var anchors: [String: String] = [:]
        for key in anchorKeys() {
            if let data = UserDefaults.standard.data(forKey: key) {
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
            try await syncEngine.sync(payload: encoded, serverURL: serverURL, apiKey: apiKey, timeout: 30)
            DataDonorLogger.shared.log("Heartbeat sent with \(anchors.count) anchor(s).", level: .debug)
        } catch {
            DataDonorLogger.shared.log("Heartbeat failed: \(error.localizedDescription)", level: .warn)
        }
    }
}
