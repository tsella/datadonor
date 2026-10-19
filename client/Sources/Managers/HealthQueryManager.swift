import Foundation
import HealthKit
import UIKit

@MainActor
final class HealthQueryManager: ObservableObject {
    let healthStore = HKHealthStore()
    @Published var isSyncing = false
    @Published var totalRecordsSynced: Int = UserDefaults.standard.integer(forKey: "totalRecordsSynced")
    private var isCancelled = false
    private var lastUIUpdateTime: Date = .distantPast
    /// One formatter for every encoded date. Its output is identical to a fresh instance,
    /// so per-sample construction only bought setup cost: a 5000-record batch built 5000.
    private static let iso8601 = ISO8601DateFormatter()
    /// Records accepted by the server during the current run. Drives the heartbeat.
    private var uploadedRecords = 0
    
    func cancelSync() {
        isCancelled = true
    }
    
    // Persistent anchors storage
    private func getAnchor(for type: String) -> HKQueryAnchor? {
        if let data = UserDefaults.standard.data(forKey: "anchor_\(type)"),
           let anchor = try? NSKeyedUnarchiver.unarchivedObject(ofClass: HKQueryAnchor.self, from: data) {
            return anchor
        }
        return nil
    }
    
    private func saveAnchor(_ anchor: HKQueryAnchor?, for type: String) {
        if let anchor = anchor,
           let data = try? NSKeyedArchiver.archivedData(withRootObject: anchor, requiringSecureCoding: true) {
            UserDefaults.standard.set(data, forKey: "anchor_\(type)")
        }
    }
    
    private func unit(for identifier: HKQuantityTypeIdentifier) -> HKUnit {
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
    
    private func mapSample(_ sample: HKSample) -> HealthDataPoint? {
        let formatter = Self.iso8601
        
        let sampleMetadata: [String: String]? = {
            var dict = [String: String]()
            if let meta = sample.metadata {
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
            return HealthDataPoint(type: sample.sampleType.identifier, value: .double(value), unit: preferredUnit.unitString, startDate: formatter.string(from: sample.startDate), endDate: formatter.string(from: sample.endDate), source: sample.sourceRevision.source.name, uuid: sample.uuid.uuidString, metadata: sampleMetadata)
        } else if let categorySample = sample as? HKCategorySample {
            return HealthDataPoint(type: sample.sampleType.identifier, value: .string("\(categorySample.value)"), unit: nil, startDate: formatter.string(from: sample.startDate), endDate: formatter.string(from: sample.endDate), source: sample.sourceRevision.source.name, uuid: sample.uuid.uuidString, metadata: sampleMetadata)
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
    
    func getAllSupportedQuantityTypes() -> [HKQuantityTypeIdentifier] {
        HealthTypeCatalog.quantityIdentifiers
    }

    func getAllSupportedCategoryTypes() -> [HKCategoryTypeIdentifier] {
        HealthTypeCatalog.categoryIdentifiers
    }

    func getAllSupportedWorkoutTypes() -> [HKWorkoutType] {
        return [.workoutType()]
    }
    
    /// Drains a sample type, uploading in batches. Returns false if a batch failed to
    /// upload, in which case the anchor was left untouched for a later retry.
    @discardableResult
    /// `limit` is the HealthKit page size *and* the upload batch size. At 5000 a typical
    /// batch encodes to a few MB against the server's 50MB body limit, so the headroom is
    /// large; the win is cutting round trips ~5x on a multi-million-record backfill.
    private func exhaustQuery(for sampleType: HKSampleType, syncEngine: SyncEngine, serverURL: URL, apiKey: String, limit: Int = 5000) async -> Bool {
        var anchor = getAnchor(for: sampleType.identifier)
        var hasMoreData = true
        var syncFailed = false

        while hasMoreData {
            if isCancelled { break }
            let (fetchedSamples, fetchedDeletedObjects, newAnchor, queryError) = await withCheckedContinuation { continuation in
                let query = HKAnchoredObjectQuery(type: sampleType, predicate: nil, anchor: anchor, limit: limit) { (query, samples, deletedObjects, returnedAnchor, error) in
                    continuation.resume(returning: (samples, deletedObjects, returnedAnchor, error))
                }
                self.healthStore.execute(query)
            }

            // A failed read used to look like an empty page: the anchor advanced and the
            // run counted as clean. Treat it as a failure so the anchor stays put and the
            // next run retries this range.
            if let queryError {
                DataDonorLogger.shared.log(
                    "HealthKit read failed for \(sampleType.identifier): \(queryError.localizedDescription)",
                    level: .error)
                syncFailed = true
                break
            }
            
            let samplesToProcess = fetchedSamples ?? []
            let deletedToProcess = fetchedDeletedObjects ?? []
            
            if !samplesToProcess.isEmpty || !deletedToProcess.isEmpty {
                let dataPoints = samplesToProcess.compactMap { self.mapSample($0) }
                let deletedUuids = deletedToProcess.compactMap { $0.uuid.uuidString }

                // Every sample in this batch was unmappable and there is nothing to delete.
                // Skip the round trip, but still advance past them so we don't spin here.
                if dataPoints.isEmpty && deletedUuids.isEmpty {
                    self.saveAnchor(newAnchor, for: sampleType.identifier)
                    anchor = newAnchor
                    continue
                }

                let deviceId = UIDevice.current.identifierForVendor?.uuidString ?? "unknown"
                
                var base64Anchor: String? = nil
                if let safeAnchor = newAnchor {
                    base64Anchor = try? NSKeyedArchiver.archivedData(withRootObject: safeAnchor, requiringSecureCoding: true).base64EncodedString()
                }
                
                let payload = HealthDataPayload(
                    deviceId: deviceId,
                    syncTimestamp: Self.iso8601.string(from: Date()),
                    data: dataPoints,
                    anchors: [sampleType.identifier: base64Anchor].compactMapValues { $0 },
                    deletedUuids: deletedUuids.isEmpty ? nil : deletedUuids
                )
                
                do {
                    let encoder = JSONEncoder()
                    let payloadData = try encoder.encode(payload)
                    // Returns only once the server has stored the batch — including the case
                    // where it acknowledged the upload while the app was killed. Anything
                    // else throws, so the anchor below is never advanced past records the
                    // server did not store.
                    try await syncEngine.sync(
                        payload: payloadData, serverURL: serverURL, apiKey: apiKey)

                    self.saveAnchor(newAnchor, for: sampleType.identifier)
                    anchor = newAnchor
                    DataDonorLogger.shared.log("Synced \(dataPoints.count) records for \(sampleType.identifier)", level: .debug)

                    // Update stats for DashboardView
                    let now = Date()
                    let shouldUpdateTimestamp = now.timeIntervalSince(self.lastUIUpdateTime) >= 5.0

                    // Count what we actually sent, not what HealthKit handed us: mapSample
                    // drops samples it cannot represent.
                    self.addSyncedRecords(dataPoints.count)
                    self.uploadedRecords += dataPoints.count

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
                    hasMoreData = false
                    syncFailed = true
                }
            } else {
                hasMoreData = false
            }
        }
        return !syncFailed
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

    private func resetAllAnchors() {
        for key in UserDefaults.standard.dictionaryRepresentation().keys {
            if key.hasPrefix("anchor_") {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }
        UserDefaults.standard.set(0.0, forKey: "lastSyncTimestamp")
        setSyncedRecords(0)
    }
    
    private func wipeLocalAnchorsOnly() {
        for key in UserDefaults.standard.dictionaryRepresentation().keys {
            if key.hasPrefix("anchor_") {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }
        UserDefaults.standard.synchronize()
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
        if let types {
            allTypes = types
        } else {
            let quantityTypes = getAllSupportedQuantityTypes().compactMap { HKObjectType.quantityType(forIdentifier: $0) }
            let categoryTypes = getAllSupportedCategoryTypes().compactMap { HKObjectType.categoryType(forIdentifier: $0) }
            allTypes = quantityTypes + categoryTypes + getAllSupportedWorkoutTypes()
        }
        
        var failedTypes: [String] = []
        for sampleType in allTypes {
            if isCancelled {
                DataDonorLogger.shared.log("Sync was cancelled by user.", level: .info)
                break
            }
            let ok = await exhaustQuery(for: sampleType, syncEngine: syncEngine, serverURL: url, apiKey: apiKey)
            if !ok { failedTypes.append(sampleType.identifier) }
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
        let localAnchorKeys = Set(
            UserDefaults.standard.dictionaryRepresentation().keys.filter { $0.hasPrefix("anchor_") }
        )

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
                        UserDefaults.standard.set(data, forKey: "anchor_\(dataType)")
                    }
                }
                return
            }

            var seeded = 0
            for (dataType, base64Str) in checkpointData.checkpoints where !localAnchorKeys.contains("anchor_\(dataType)") {
                if let data = Data(base64Encoded: base64Str) {
                    UserDefaults.standard.set(data, forKey: "anchor_\(dataType)")
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
        for key in UserDefaults.standard.dictionaryRepresentation().keys where key.hasPrefix("anchor_") {
            if let data = UserDefaults.standard.data(forKey: key) {
                anchors[String(key.dropFirst("anchor_".count))] = data.base64EncodedString()
            }
        }
        guard !anchors.isEmpty else { return }

        let payload = HealthDataPayload(
            deviceId: deviceId,
            syncTimestamp: Self.iso8601.string(from: Date()),
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
