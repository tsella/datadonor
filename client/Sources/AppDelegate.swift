import UIKit
import BackgroundTasks

class AppDelegate: NSObject, UIApplicationDelegate {
    
    // We hold a reference to our sync engine to handle background events
    let syncEngine = SyncEngine()
    let healthQueryManager = HealthQueryManager()
    
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey : Any]? = nil) -> Bool {
        
        // Register Background Task
        BackgroundSyncManager.shared.registerBackgroundTasks(
            syncEngine: syncEngine,
            healthQueryManager: healthQueryManager,
            apiKey: UserDefaults.standard.string(forKey: "apiKey") ?? ""
        )
        
        DataDonorLogger.shared.log("AppDelegate: Registered Background Tasks.", level: .info)
        return true
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
