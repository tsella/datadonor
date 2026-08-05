import SwiftUI

@main
struct DataDonorApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    @StateObject private var serverDiscoveryManager = ServerDiscoveryManager()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(appDelegate.healthStoreManager)
                .environmentObject(serverDiscoveryManager)
                .environmentObject(appDelegate.healthQueryManager)
                .environmentObject(appDelegate.syncEngine)
        }
    }
}
