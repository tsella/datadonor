import Foundation
import HealthKit

class HealthStoreManager: ObservableObject {
    let healthStore = HKHealthStore()
    
    @Published var isAuthorized = false
    
    func requestAuthorization(completion: @escaping (Bool, Error?) -> Void = { _, _ in }) {
        guard HKHealthStore.isHealthDataAvailable() else {
            completion(false, nil)
            return
        }
        
        let quantityTypes: [HKQuantityTypeIdentifier] = [
            .stepCount,
            .distanceWalkingRunning,
            .heartRate,
            .activeEnergyBurned,
            .basalEnergyBurned,
            .flightsClimbed,
            .oxygenSaturation,
            .bloodPressureDiastolic,
            .bloodPressureSystolic,
            .bodyMass,
            .bodyMassIndex,
            .bodyFatPercentage,
            .leanBodyMass,
            .dietaryEnergyConsumed,
            .dietaryWater
        ]
        
        let categoryTypes: [HKCategoryTypeIdentifier] = [
            .sleepAnalysis,
            .appleStandHour,
            .mindfulSession,
            .menstrualFlow
        ]
        
        var readTypes = Set<HKObjectType>()
        
        for identifier in quantityTypes {
            if let type = HKObjectType.quantityType(forIdentifier: identifier) {
                readTypes.insert(type)
            }
        }
        
        for identifier in categoryTypes {
            if let type = HKObjectType.categoryType(forIdentifier: identifier) {
                readTypes.insert(type)
            }
        }
        
        healthStore.requestAuthorization(toShare: nil, read: readTypes) { success, error in
            DispatchQueue.main.async {
                self.isAuthorized = success
            }
            completion(success, error)
        }
    }
}
