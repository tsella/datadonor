import UIKit
import BackgroundTasks
import HealthKit

@MainActor
class AppDelegate: NSObject, UIApplicationDelegate {

    // Single shared HealthKit store across the entire process
    let healthStore = HKHealthStore()
    // We hold a reference to our sync engine to handle background events
    let syncEngine = SyncEngine()
    lazy var healthQueryManager = HealthQueryManager(healthStore: healthStore)
    lazy var healthStoreManager = HealthStoreManager(healthStore: healthStore)

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey : Any]? = nil) -> Bool {

        // Registration must happen before this method returns. The API key is deliberately
        // not captured here: the handlers read it at execution time, so key changes take
        // effect without a relaunch.
        BackgroundSyncManager.shared.configure(
            syncEngine: syncEngine,
            healthQueryManager: healthQueryManager
        )
        BackgroundSyncManager.shared.registerBackgroundTasks()

        // Registration alone never runs anything; a request has to be submitted. Both are
        // queued: an app refresh for the delta, a processing window for a sweep that does
        // not fit in a 30-second refresh.
        BackgroundSyncManager.shared.scheduleAppRefresh()
        BackgroundSyncManager.shared.scheduleProcessing()

        NotificationManager.shared.requestAuthorization()

        // Observer queries don't survive process death, so re-register them each launch
        // for users who already granted access.
        if healthStoreManager.isAuthorized {
            BackgroundSyncManager.shared.setupObserverQueries(healthStore: healthStoreManager.healthStore)
        }

        DataDonorLogger.shared.log("AppDelegate: Registered and scheduled Background Tasks.", level: .info)
        return true
    }

    func applicationDidEnterBackground(_ application: UIApplication) {
        // Keep a pending request alive across suspensions.
        BackgroundSyncManager.shared.scheduleAppRefresh()
        BackgroundSyncManager.shared.scheduleProcessing()
    }

    func application(_ application: UIApplication, handleEventsForBackgroundURLSession identifier: String, completionHandler: @escaping () -> Void) {
        DataDonorLogger.shared.log("AppDelegate: Handling events for background URL session: \(identifier)", level: .info)

        if identifier == "la.tsel.datadonor.sync" {
            syncEngine.backgroundCompletionHandler = completionHandler
        } else {
            completionHandler()
        }
    }
}
