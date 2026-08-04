import Foundation
import HealthKit
import UIKit

@MainActor
final class HealthQueryManager: ObservableObject, @unchecked Sendable {
    let healthStore = HKHealthStore()
    @Published var isSyncing = false
    @Published var totalRecordsSynced: Int = UserDefaults.standard.integer(forKey: "totalRecordsSynced")
    private var isCancelled = false
    private var lastUIUpdateTime: Date = .distantPast
    
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
        let formatter = ISO8601DateFormatter()
        if let quantitySample = sample as? HKQuantitySample {
            let identifier = HKQuantityTypeIdentifier(rawValue: sample.sampleType.identifier)
            let preferredUnit = unit(for: identifier)
            let value: Double
            if quantitySample.quantity.is(compatibleWith: preferredUnit) {
                value = quantitySample.quantity.doubleValue(for: preferredUnit)
            } else {
                value = 0.0
                DataDonorLogger.shared.log("Unit mismatch: \(sample.sampleType.identifier) sample unit \(quantitySample.quantity) is incompatible with preferred unit \(preferredUnit.unitString). Storing 0.0.", level: .warn)
            }
            return HealthDataPoint(type: sample.sampleType.identifier, value: .double(value), unit: preferredUnit.unitString, startDate: formatter.string(from: sample.startDate), endDate: formatter.string(from: sample.endDate), source: sample.sourceRevision.source.name, uuid: sample.uuid.uuidString)
        } else if let categorySample = sample as? HKCategorySample {
            return HealthDataPoint(type: sample.sampleType.identifier, value: .string("\(categorySample.value)"), unit: nil, startDate: formatter.string(from: sample.startDate), endDate: formatter.string(from: sample.endDate), source: sample.sourceRevision.source.name, uuid: sample.uuid.uuidString)
        }
        return nil
    }
    
    func getAllSupportedQuantityTypes() -> [HKQuantityTypeIdentifier] {
        var types: [HKQuantityTypeIdentifier] = [
            .heartRate, .heartRateVariabilitySDNN, .restingHeartRate, .walkingHeartRateAverage,
            .heartRateRecoveryOneMinute, .vo2Max, .oxygenSaturation, .atrialFibrillationBurden,
            .stepCount, .distanceWalkingRunning, .distanceCycling, .distanceSwimming,
            .distanceDownhillSnowSports, .swimmingStrokeCount, .underwaterDepth, .waterTemperature,
            .flightsClimbed, .activeEnergyBurned, .basalEnergyBurned, .appleExerciseTime,
            .appleMoveTime, .appleStandTime, .walkingAsymmetryPercentage, .walkingStepLength,
            .walkingDoubleSupportPercentage, .walkingSpeed, .appleWalkingSteadiness,
            .numberOfTimesFallen,
            .environmentalAudioExposure, .headphoneAudioExposure, .uvExposure, .respiratoryRate,
            .height, .bloodPressureDiastolic,
            .bloodPressureSystolic, .bodyMass, .bodyMassIndex, .bodyFatPercentage, .leanBodyMass,
            .bodyTemperature, .bloodGlucose, .dietaryEnergyConsumed, .dietaryWater
        ]
        if #available(iOS 16.0, *) { types.append(.appleSleepingWristTemperature) }
        if #available(iOS 17.0, *) { 
            types.append(.timeInDaylight) 
            types.append(.physicalEffort)
        }
        if #available(iOS 18.0, *) {
            types.append(.workoutEffortScore)
            types.append(.estimatedWorkoutEffortScore)
            types.append(.appleSleepingBreathingDisturbances)
        }
        return types
    }
    
    func getAllSupportedCategoryTypes() -> [HKCategoryTypeIdentifier] {
        return [
            .sleepAnalysis, .appleStandHour, .mindfulSession, .menstrualFlow,
            .irregularHeartRhythmEvent, .highHeartRateEvent, .lowHeartRateEvent,
            .environmentalAudioExposureEvent
        ]
    }
    
    private func exhaustQuery(for sampleType: HKSampleType, syncEngine: SyncEngine, serverURL: URL, apiKey: String, limit: Int = 1000) async {
        var anchor = getAnchor(for: sampleType.identifier)
        var hasMoreData = true
        
        while hasMoreData {
            if isCancelled { break }
            let (fetchedSamples, fetchedDeletedObjects, newAnchor) = await withCheckedContinuation { continuation in
                let query = HKAnchoredObjectQuery(type: sampleType, predicate: nil, anchor: anchor, limit: limit) { (query, samples, deletedObjects, returnedAnchor, error) in
                    continuation.resume(returning: (samples, deletedObjects, returnedAnchor))
                }
                self.healthStore.execute(query)
            }
            
            let samplesToProcess = fetchedSamples ?? []
            let deletedToProcess = fetchedDeletedObjects ?? []
            
            if !samplesToProcess.isEmpty || !deletedToProcess.isEmpty {
                let dataPoints = samplesToProcess.compactMap { self.mapSample($0) }
                let deletedUuids = deletedToProcess.compactMap { $0.uuid.uuidString }
                
                let deviceId = UIDevice.current.identifierForVendor?.uuidString ?? "unknown"
                
                var base64Anchor: String? = nil
                if let safeAnchor = newAnchor {
                    base64Anchor = try? NSKeyedArchiver.archivedData(withRootObject: safeAnchor, requiringSecureCoding: true).base64EncodedString()
                }
                
                let payload = HealthDataPayload(
                    deviceId: deviceId,
                    syncTimestamp: ISO8601DateFormatter().string(from: Date()),
                    data: dataPoints,
                    anchors: [sampleType.identifier: base64Anchor].compactMapValues { $0 },
                    deletedUuids: deletedUuids.isEmpty ? nil : deletedUuids
                )
                
                do {
                    let encoder = JSONEncoder()
                    let payloadData = try encoder.encode(payload)
                    try await syncEngine.sync(payload: payloadData, serverURL: serverURL, apiKey: apiKey)
                    
                    self.saveAnchor(newAnchor, for: sampleType.identifier)
                    anchor = newAnchor
                    DataDonorLogger.shared.log("Synced \(samplesToProcess.count) records for \(sampleType.identifier)", level: .debug)
                    
                    // Update stats for DashboardView
                    let now = Date()
                    let shouldUpdateTimestamp = now.timeIntervalSince(self.lastUIUpdateTime) >= 5.0
                    
                    let recordsCount = samplesToProcess.count
                    DispatchQueue.main.async {
                        self.totalRecordsSynced += recordsCount
                    }
                    UserDefaults.standard.set(UserDefaults.standard.integer(forKey: "totalRecordsSynced") + recordsCount, forKey: "totalRecordsSynced")
                    
                    if shouldUpdateTimestamp {
                        UserDefaults.standard.set(now.timeIntervalSince1970, forKey: "lastSyncTimestamp")
                        self.lastUIUpdateTime = now
                    }
                } catch {
                    DataDonorLogger.shared.log("Failed to encode/sync \(sampleType.identifier): \(error)", level: .warn)
                    hasMoreData = false
                }
            } else {
                hasMoreData = false
            }
        }
    }
    
    private func resetAllAnchors() {
        for key in UserDefaults.standard.dictionaryRepresentation().keys {
            if key.hasPrefix("anchor_") {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }
        UserDefaults.standard.set(0.0, forKey: "lastSyncTimestamp")
        UserDefaults.standard.set(0, forKey: "totalRecordsSynced")
        DispatchQueue.main.async {
            self.totalRecordsSynced = 0
        }
        UserDefaults.standard.synchronize()
    }
    
    private func wipeLocalAnchorsOnly() {
        for key in UserDefaults.standard.dictionaryRepresentation().keys {
            if key.hasPrefix("anchor_") {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }
        UserDefaults.standard.synchronize()
    }
    
    func performSync(syncEngine: SyncEngine, networkMonitor: NetworkMonitor, serverURL: URL?, apiKey: String) async {
        guard let url = serverURL else {
            DataDonorLogger.shared.log("Skipping sync: No server URL resolved.", level: .warn)
            return
        }
        
        guard networkMonitor.isConnectedToTargetSSID else {
            DataDonorLogger.shared.log("Skipping sync: Not connected to target Wi-Fi SSID.", level: .info)
            return
        }
        
        DataDonorLogger.shared.log("Starting health data extraction loop.", level: .info)
        
        DispatchQueue.main.async {
            self.isSyncing = true
        }
        self.isCancelled = false
        
        defer {
            DispatchQueue.main.async {
                self.isSyncing = false
            }
        }
        
        let deviceId = UIDevice.current.identifierForVendor?.uuidString ?? "unknown"
        do {
            if let checkpointData = try await syncEngine.fetchServerCheckpoint(serverURL: url, apiKey: apiKey, deviceId: deviceId) {
                let serverAnchors = checkpointData.checkpoints
                
                // Align local record count with server's actual count
                DispatchQueue.main.async {
                    self.totalRecordsSynced = checkpointData.totalRecords
                }
                UserDefaults.standard.set(checkpointData.totalRecords, forKey: "totalRecordsSynced")
                
                if serverAnchors.isEmpty {
                    DataDonorLogger.shared.log("Server has no data for device. Resetting local anchors to force full resync.", level: .info)
                    self.resetAllAnchors()
                } else {
                    DataDonorLogger.shared.log("Received server checkpoints. Overwriting local state.", level: .info)
                    self.wipeLocalAnchorsOnly() // Wipe local anchor state first, preserving sync counts
                    for (dataType, base64Str) in serverAnchors {
                        if let data = Data(base64Encoded: base64Str) {
                            UserDefaults.standard.set(data, forKey: "anchor_\(dataType)")
                        }
                    }
                    UserDefaults.standard.synchronize()
                }
            } else {
                DataDonorLogger.shared.log("Failed to fetch server checkpoints (nil response). Proceeding with local state.", level: .warn)
            }
        } catch {
            DataDonorLogger.shared.log("Failed to fetch server checkpoint: \(error)", level: .warn)
        }
        
        let allQuantities = getAllSupportedQuantityTypes().compactMap { HKObjectType.quantityType(forIdentifier: $0) }
        let allCategories = getAllSupportedCategoryTypes().compactMap { HKObjectType.categoryType(forIdentifier: $0) }
        let allTypes: [HKSampleType] = allQuantities + allCategories
        
        for sampleType in allTypes {
            if isCancelled {
                DataDonorLogger.shared.log("Sync was cancelled by user.", level: .info)
                break
            }
            await exhaustQuery(for: sampleType, syncEngine: syncEngine, serverURL: url, apiKey: apiKey)
        }
        
        // Final timestamp update
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: "lastSyncTimestamp")
        self.lastUIUpdateTime = Date()
        
        DataDonorLogger.shared.log("Completed health data extraction loop.", level: .info)
    }
}
