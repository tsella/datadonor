import Foundation
import HealthKit
import UIKit

class HealthQueryManager: ObservableObject {
    let healthStore = HKHealthStore()
    
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
    
    // Resolves the preferred HKUnit for a given HKQuantityTypeIdentifier
    private func unit(for identifier: HKQuantityTypeIdentifier) -> HKUnit {
        switch identifier {
        case .heartRate, .restingHeartRate, .walkingHeartRateAverage:
            return HKUnit.count().unitDivided(by: .minute())
        case .heartRateVariabilitySDNN:
            return HKUnit.secondUnit(with: .milli)
        case .vo2Max:
            return HKUnit(from: "ml/(kg*min)")
        case .oxygenSaturation, .bodyFatPercentage, .walkingAsymmetryPercentage, .walkingDoubleSupportPercentage:
            return HKUnit.percent()
        case .stepCount, .swimmingStrokeCount, .flightsClimbed:
            return HKUnit.count()
        case .distanceWalkingRunning, .distanceCycling, .distanceSwimming, .walkingStepLength, .height:
            return HKUnit.meter()
        case .activeEnergyBurned, .basalEnergyBurned, .dietaryEnergyConsumed:
            return HKUnit.kilocalorie()
        case .appleExerciseTime, .appleStandTime:
            return HKUnit.minute()
        case .walkingSpeed:
            return HKUnit.meter().unitDivided(by: .second())
        case .environmentalAudioExposure:
            return HKUnit.decibelAWeightedSoundPressureLevel()
        case .respiratoryRate:
            return HKUnit.count().unitDivided(by: .minute())
        case .bloodPressureDiastolic, .bloodPressureSystolic:
            return HKUnit.millimeterOfMercury()
        case .bodyMass, .leanBodyMass:
            return HKUnit.gramUnit(with: .kilo)
        case .bodyMassIndex:
            return HKUnit.count() // BMI is technically dimensionless, count works
        case .dietaryWater:
            return HKUnit.literUnit(with: .milli)
        default:
            if #available(iOS 16.0, *), identifier == .appleSleepingWristTemperature {
                return HKUnit.degreeCelsius()
            }
            return HKUnit.count()
        }
    }
    
    private func mapSample(_ sample: HKSample) -> HealthDataPoint? {
        let formatter = ISO8601DateFormatter()
        
        if let quantitySample = sample as? HKQuantitySample {
            let identifier = HKQuantityTypeIdentifier(rawValue: sample.sampleType.identifier)
            let preferredUnit = unit(for: identifier)
            let value = quantitySample.quantity.is(compatibleWith: preferredUnit) ? quantitySample.quantity.doubleValue(for: preferredUnit) : 0.0
            
            return HealthDataPoint(
                type: sample.sampleType.identifier,
                value: .double(value),
                unit: preferredUnit.unitString,
                startDate: formatter.string(from: sample.startDate),
                endDate: formatter.string(from: sample.endDate),
                source: sample.sourceRevision.source.name
            )
        } else if let categorySample = sample as? HKCategorySample {
            return HealthDataPoint(
                type: sample.sampleType.identifier,
                value: .string("\(categorySample.value)"),
                unit: nil,
                startDate: formatter.string(from: sample.startDate),
                endDate: formatter.string(from: sample.endDate),
                source: sample.sourceRevision.source.name
            )
        }
        return nil
    }
    
    // Exposed array to sync all types. We will extract this dynamically in production.
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
    
    func performSync(syncEngine: SyncEngine, networkMonitor: NetworkMonitor, apiKey: String) async {
        guard networkMonitor.isConnectedToTargetSSID else {
            print("Skipping sync: Not connected to target Wi-Fi SSID.")
            return
        }
        
        let allQuantities = getAllSupportedQuantityTypes().compactMap { HKObjectType.quantityType(forIdentifier: $0) }
        let allCategories = getAllSupportedCategoryTypes().compactMap { HKObjectType.categoryType(forIdentifier: $0) }
        let allTypes: [HKSampleType] = allQuantities + allCategories
        
        for sampleType in allTypes {
            let anchor = getAnchor(for: sampleType.identifier)
            
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                // Set limit to 1000 per request so we don't blow up memory on huge backfills
                let query = HKAnchoredObjectQuery(type: sampleType, predicate: nil, anchor: anchor, limit: 1000) { [weak self] (query, samples, deletedObjects, newAnchor, error) in
                    guard let self = self else {
                        continuation.resume()
                        return
                    }
                    
                    if let samples = samples, !samples.isEmpty {
                        let dataPoints = samples.compactMap { self.mapSample($0) }
                        let payload = HealthDataPayload(
                            deviceId: UIDevice.current.identifierForVendor?.uuidString ?? "unknown",
                            syncTimestamp: ISO8601DateFormatter().string(from: Date()),
                            data: dataPoints
                        )
                        
                        Task {
                            do {
                                let data = try JSONEncoder().encode(payload)
                                try await syncEngine.sync(payload: data)
                                self.saveAnchor(newAnchor, for: sampleType.identifier)
                            } catch {
                                print("Failed to sync \(sampleType.identifier): \(error)")
                            }
                        }
                    }
                    // In a true backfill, we'd loop until samples.count < limit, but for scaffold this is fine.
                    continuation.resume()
                }
                self.healthStore.execute(query)
            }
        }
    }
}
