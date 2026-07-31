import Foundation
import BackgroundTasks
import HealthKit

class BackgroundSyncManager {
    static let shared = BackgroundSyncManager()
    
    let syncTaskIdentifier = "la.tsel.datadonor.backgroundSync"
    
    private init() {}
    
    func registerBackgroundTasks(syncEngine: SyncEngine, networkMonitor: NetworkMonitor, healthQueryManager: HealthQueryManager, apiKey: String) {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: syncTaskIdentifier, using: nil) { task in
            self.handleAppRefresh(task: task as! BGAppRefreshTask, syncEngine: syncEngine, networkMonitor: networkMonitor, healthQueryManager: healthQueryManager, apiKey: apiKey)
        }
    }
    
    func scheduleAppRefresh() {
        let request = BGAppRefreshTaskRequest(identifier: syncTaskIdentifier)
        // Schedule to run loosely every 15 minutes, iOS permitting
        request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
        
        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            print("Could not schedule app refresh: \(error)")
        }
    }
    
    private func handleAppRefresh(task: BGAppRefreshTask, syncEngine: SyncEngine, networkMonitor: NetworkMonitor, healthQueryManager: HealthQueryManager, apiKey: String) {
        // Reschedule for the next cycle
        scheduleAppRefresh()
        
        // Define expiration logic
        task.expirationHandler = {
            // Task is expiring, stop work
            // URLSession background config handles ongoing uploads natively.
        }
        
        // Execute the pipeline
        Task {
            await healthQueryManager.performSync(syncEngine: syncEngine, networkMonitor: networkMonitor, apiKey: apiKey)
            task.setTaskCompleted(success: true)
        }
    }
    
    func setupObserverQueries(healthStore: HKHealthStore) {
        let stepType = HKObjectType.quantityType(forIdentifier: .stepCount)!
        
        let query = HKObserverQuery(sampleType: stepType, predicate: nil) { query, completionHandler, error in
            if let error = error {
                print("Observer query error: \(error)")
                completionHandler()
                return
            }
            // A new health event occurred in the background. We can trigger a sync.
            // Note: iOS will wake the app up in the background to handle this.
            completionHandler()
        }
        
        healthStore.execute(query)
        healthStore.enableBackgroundDelivery(for: stepType, frequency: .hourly) { success, error in
            if !success {
                print("Failed to enable background delivery")
            }
        }
    }
}
