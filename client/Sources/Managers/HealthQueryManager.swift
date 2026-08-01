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
        case .heartRate, .restingHeartRate, .walkingHeartRateAverage: return HKUnit.count().unitDivided(by: .minute())
        case .heartRateVariabilitySDNN: return HKUnit.secondUnit(with: .milli)
        case .vo2Max: return HKUnit(from: "ml/(kg*min)")
        case .oxygenSaturation, .bodyFatPercentage, .walkingAsymmetryPercentage, .walkingDoubleSupportPercentage: return HKUnit.percent()
        case .stepCount, .swimmingStrokeCount, .flightsClimbed: return HKUnit.count()
        case .distanceWalkingRunning, .distanceCycling, .distanceSwimming, .walkingStepLength, .height: return HKUnit.meter()
        case .activeEnergyBurned, .basalEnergyBurned, .dietaryEnergyConsumed: return HKUnit.kilocalorie()
        case .appleExerciseTime, .appleStandTime: return HKUnit.minute()
        case .walkingSpeed: return HKUnit.meter().unitDivided(by: .second())
        case .environmentalAudioExposure: return HKUnit.decibelAWeightedSoundPressureLevel()
        case .respiratoryRate: return HKUnit.count().unitDivided(by: .minute())
        case .bloodPressureDiastolic, .bloodPressureSystolic: return HKUnit.millimeterOfMercury()
        case .bodyMass, .leanBodyMass: return HKUnit.gramUnit(with: .kilo)
        case .bodyMassIndex: return HKUnit.count()
        case .dietaryWater: return HKUnit.literUnit(with: .milli)
        default:
            if #available(iOS 16.0, *), identifier == .appleSleepingWristTemperature { return HKUnit.degreeCelsius() }
            return HKUnit.count()
        }
    }
    
    private func mapSample(_ sample: HKSample) -> HealthDataPoint? {
        let formatter = ISO8601DateFormatter()
        if let quantitySample = sample as? HKQuantitySample {
            let identifier = HKQuantityTypeIdentifier(rawValue: sample.sampleType.identifier)
            let preferredUnit = unit(for: identifier)
            let value = quantitySample.quantity.is(compatibleWith: preferredUnit) ? quantitySample.quantity.doubleValue(for: preferredUnit) : 0.0
            return HealthDataPoint(type: sample.sampleType.identifier, value: .double(value), unit: preferredUnit.unitString, startDate: formatter.string(from: sample.startDate), endDate: formatter.string(from: sample.endDate), source: sample.sourceRevision.source.name)
        } else if let categorySample = sample as? HKCategorySample {
            return HealthDataPoint(type: sample.sampleType.identifier, value: .string("\(categorySample.value)"), unit: nil, startDate: formatter.string(from: sample.startDate), endDate: formatter.string(from: sample.endDate), source: sample.sourceRevision.source.name)
        }
        return nil
    }
    
    func getAllSupportedQuantityTypes() -> [HKQuantityTypeIdentifier] {
        var types: [HKQuantityTypeIdentifier] = [
            .heartRate, .heartRateVariabilitySDNN, .restingHeartRate, .walkingHeartRateAverage,
            .vo2Max, .oxygenSaturation, .stepCount, .distanceWalkingRunning, .distanceCycling,
            .distanceSwimming, .swimmingStrokeCount, .flightsClimbed, .activeEnergyBurned,
            .basalEnergyBurned, .appleExerciseTime, .appleStandTime, .walkingAsymmetryPercentage,
            .walkingStepLength, .walkingDoubleSupportPercentage, .walkingSpeed, .environmentalAudioExposure,
            .respiratoryRate, .height, .bloodPressureDiastolic, .bloodPressureSystolic, .bodyMass,
            .bodyMassIndex, .bodyFatPercentage, .leanBodyMass, .dietaryEnergyConsumed, .dietaryWater
        ]
        if #available(iOS 16.0, *) { types.append(.appleSleepingWristTemperature) }
        if #available(iOS 17.0, *) { types.append(.timeInDaylight) }
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
            let (fetchedSamples, newAnchor) = await withCheckedContinuation { continuation in
                let query = HKAnchoredObjectQuery(type: sampleType, predicate: nil, anchor: anchor, limit: limit) { (query, samples, deletedObjects, returnedAnchor, error) in
                    continuation.resume(returning: (samples, returnedAnchor))
                }
                self.healthStore.execute(query)
            }
            
            if let samples = fetchedSamples, !samples.isEmpty {
                let dataPoints = samples.compactMap { self.mapSample($0) }
                let deviceId = UIDevice.current.identifierForVendor?.uuidString ?? "unknown"
                let payload = HealthDataPayload(
                    deviceId: deviceId,
                    syncTimestamp: ISO8601DateFormatter().string(from: Date()),
                    data: dataPoints
                )
                
                do {
                    let data = try JSONEncoder().encode(payload)
                    try await syncEngine.sync(payload: data, serverURL: serverURL, apiKey: apiKey)
                    self.saveAnchor(newAnchor, for: sampleType.identifier)
                    anchor = newAnchor
                    DataDonorLogger.shared.log("Synced \(samples.count) records for \(sampleType.identifier)", level: .debug)
                    
                    // Update stats for DashboardView
                    let now = Date()
                    let shouldUpdateTimestamp = now.timeIntervalSince(self.lastUIUpdateTime) >= 5.0
                    
                    self.totalRecordsSynced += samples.count
                    UserDefaults.standard.set(self.totalRecordsSynced, forKey: "totalRecordsSynced")
                    
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
        self.totalRecordsSynced = 0
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
        
        self.isSyncing = true
        self.isCancelled = false
        
        defer {
            self.isSyncing = false
        }
        
        let deviceId = UIDevice.current.identifierForVendor?.uuidString ?? "unknown"
        do {
            let serverHasData = try await syncEngine.fetchServerCheckpoint(serverURL: url, apiKey: apiKey, deviceId: deviceId)
            if !serverHasData {
                DataDonorLogger.shared.log("Server has no data for device. Resetting local anchors to force full resync.", level: .info)
                self.resetAllAnchors()
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
