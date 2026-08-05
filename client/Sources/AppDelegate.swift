import UIKit
import BackgroundTasks

class AppDelegate: NSObject, UIApplicationDelegate {

    // We hold a reference to our sync engine to handle background events
    let syncEngine = SyncEngine()
    let healthQueryManager = HealthQueryManager()
    let healthStoreManager = HealthStoreManager()

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey : Any]? = nil) -> Bool {

        // Register Background Task. The API key is deliberately not captured here — the
        // handler reads it at execution time so key changes take effect without a relaunch.
        BackgroundSyncManager.shared.registerBackgroundTasks(
            syncEngine: syncEngine,
            healthQueryManager: healthQueryManager
        )

        // Registration alone never runs anything; a request has to be submitted.
        BackgroundSyncManager.shared.scheduleAppRefresh()

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
