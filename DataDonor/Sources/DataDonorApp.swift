import SwiftUI

@main
struct DataDonorApp: App {
    @StateObject private var healthStoreManager = HealthStoreManager()
    @StateObject private var serverDiscoveryManager = ServerDiscoveryManager()
    let syncEngine = SyncEngine()
    
    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(healthStoreManager)
                .environmentObject(serverDiscoveryManager)
        }
    }
}
