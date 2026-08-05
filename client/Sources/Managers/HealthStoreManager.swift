import Foundation
import HealthKit

class HealthStoreManager: ObservableObject {
    let healthStore = HKHealthStore()
    
    @Published var isAuthorized: Bool = UserDefaults.standard.bool(forKey: "hasRequestedHealthAccess")
    
    func requestAuthorization(completion: @escaping (Bool, Error?) -> Void = { _, _ in }) {
        guard HKHealthStore.isHealthDataAvailable() else {
            completion(false, nil)
            return
        }
        
        let quantityTypes: [HKQuantityTypeIdentifier] = [
            // Cardio & Heart
            .heartRate,
            .heartRateVariabilitySDNN,
            .restingHeartRate,
            .walkingHeartRateAverage,
            .heartRateRecoveryOneMinute,
            .vo2Max,
            .oxygenSaturation,
            .atrialFibrillationBurden,
            
            // Activity & Mobility
            .stepCount,
            .distanceWalkingRunning,
            .distanceCycling,
            .distanceSwimming,
            .distanceDownhillSnowSports,
            .swimmingStrokeCount,
            .underwaterDepth,
            .waterTemperature,
            .flightsClimbed,
            .activeEnergyBurned,
            .basalEnergyBurned,
            .appleExerciseTime,
            .appleMoveTime,
            .appleStandTime,
            .walkingAsymmetryPercentage,
            .walkingStepLength,
            .walkingDoubleSupportPercentage,
            .walkingSpeed,
            .appleWalkingSteadiness,
            .numberOfTimesFallen,
            
            // Environmental & Sleep
            .environmentalAudioExposure,
            .headphoneAudioExposure,
            .uvExposure,
            .respiratoryRate,
            
            // Vitals (General)
            .height,
            .bloodPressureDiastolic,
            .bloodPressureSystolic,
            .bodyMass,
            .bodyMassIndex,
            .bodyFatPercentage,
            .leanBodyMass,
            .bodyTemperature,
            .bloodGlucose,
            
            // Nutrition (Optional scaffolded)
            .dietaryEnergyConsumed,
            .dietaryWater
        ]
        
        // Use #available(iOS 16.0, *) to safely add new types, although our deployment target is 16.0
        var quantityIdentifiers = quantityTypes
        if #available(iOS 16.0, *) {
            quantityIdentifiers.append(.appleSleepingWristTemperature)
        }
        if #available(iOS 17.0, *) {
            quantityIdentifiers.append(.timeInDaylight)
            quantityIdentifiers.append(.physicalEffort)
        }
        if #available(iOS 18.0, *) {
            quantityIdentifiers.append(.workoutEffortScore)
            quantityIdentifiers.append(.estimatedWorkoutEffortScore)
            quantityIdentifiers.append(.appleSleepingBreathingDisturbances)
        }
        
        let categoryTypes: [HKCategoryTypeIdentifier] = [
            .sleepAnalysis,
            .appleStandHour,
            .mindfulSession,
            .menstrualFlow,
            .irregularHeartRhythmEvent,
            .highHeartRateEvent,
            .lowHeartRateEvent,
            .environmentalAudioExposureEvent
        ]
        
        var readTypes = Set<HKObjectType>()
        
        for identifier in quantityIdentifiers {
            if let type = HKObjectType.quantityType(forIdentifier: identifier) {
                readTypes.insert(type)
            }
        }
        
        for identifier in categoryTypes {
            if let type = HKObjectType.categoryType(forIdentifier: identifier) {
                readTypes.insert(type)
            }
        }
        
        readTypes.insert(HKObjectType.workoutType())
        
        healthStore.requestAuthorization(toShare: nil, read: readTypes) { success, error in
            DispatchQueue.main.async {
                if success {
                    self.isAuthorized = true
                    UserDefaults.standard.set(true, forKey: "hasRequestedHealthAccess")
                    // Now that we're authorized, ask HealthKit to wake us on new data.
                    BackgroundSyncManager.shared.setupObserverQueries(healthStore: self.healthStore)
                }
                if let error = error {
                    DataDonorLogger.shared.log("HealthKit authorization error: \(error.localizedDescription)", level: .error)
                }
            }
            completion(success, error)
        }
    }
}
