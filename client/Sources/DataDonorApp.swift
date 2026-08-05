import SwiftUI

@main
struct DataDonorApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    
    @StateObject private var healthStoreManager = HealthStoreManager()
    @StateObject private var serverDiscoveryManager = ServerDiscoveryManager()
    
    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(healthStoreManager)
                .environmentObject(serverDiscoveryManager)
                .environmentObject(appDelegate.healthQueryManager)
                .environmentObject(appDelegate.syncEngine)
        }
    }
}
