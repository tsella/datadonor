import Foundation
import HealthKit

/// The one list of HealthKit types the app requests access to and sweeps.
///
/// It used to exist twice, here and in `HealthQueryManager`, with the same three
/// `#available` blocks on both sides. A type added to the sweep but not to the
/// authorization set was queried without read permission: HealthKit returns an empty
/// page, the anchor still advances, and the type looks synced forever.
enum HealthTypeCatalog {
    static var quantityIdentifiers: [HKQuantityTypeIdentifier] {
        var types: [HKQuantityTypeIdentifier] = [
            // Cardio and heart
            .heartRate, .heartRateVariabilitySDNN, .restingHeartRate, .walkingHeartRateAverage,
            .heartRateRecoveryOneMinute, .vo2Max, .oxygenSaturation, .atrialFibrillationBurden,
            // Activity and mobility
            .stepCount, .distanceWalkingRunning, .distanceCycling, .distanceSwimming,
            .distanceDownhillSnowSports, .swimmingStrokeCount, .underwaterDepth, .waterTemperature,
            .flightsClimbed, .activeEnergyBurned, .basalEnergyBurned, .appleExerciseTime,
            .appleMoveTime, .appleStandTime, .walkingAsymmetryPercentage, .walkingStepLength,
            .walkingDoubleSupportPercentage, .walkingSpeed, .appleWalkingSteadiness,
            .numberOfTimesFallen,
            // Environment and breathing
            .environmentalAudioExposure, .headphoneAudioExposure, .uvExposure, .respiratoryRate,
            // Vitals
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

    static var categoryIdentifiers: [HKCategoryTypeIdentifier] {
        [
            .sleepAnalysis, .appleStandHour, .mindfulSession, .menstrualFlow,
            .irregularHeartRhythmEvent, .highHeartRateEvent, .lowHeartRateEvent,
            .environmentalAudioExposureEvent
        ]
    }

    static var readTypes: Set<HKObjectType> {
        var types = Set<HKObjectType>()
        for identifier in quantityIdentifiers {
            if let type = HKObjectType.quantityType(forIdentifier: identifier) { types.insert(type) }
        }
        for identifier in categoryIdentifiers {
            if let type = HKObjectType.categoryType(forIdentifier: identifier) { types.insert(type) }
        }
        types.insert(HKObjectType.workoutType())
        return types
    }
}

class HealthStoreManager: ObservableObject {
    let healthStore = HKHealthStore()
    
    @Published var isAuthorized: Bool = UserDefaults.standard.bool(forKey: "hasRequestedHealthAccess")
    
    func requestAuthorization(completion: @escaping (Bool, Error?) -> Void = { _, _ in }) {
        guard HKHealthStore.isHealthDataAvailable() else {
            completion(false, nil)
            return
        }
        
        // One source of truth for the type list, shared with the sync sweep.
        let readTypes = HealthTypeCatalog.readTypes

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
