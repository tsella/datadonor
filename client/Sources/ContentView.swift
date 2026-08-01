import SwiftUI

struct ContentView: View {
    @EnvironmentObject var healthStoreManager: HealthStoreManager
    @EnvironmentObject var serverDiscoveryManager: ServerDiscoveryManager
    @EnvironmentObject var healthQueryManager: HealthQueryManager
    @EnvironmentObject var networkMonitor: NetworkMonitor
    @EnvironmentObject var syncEngine: SyncEngine
    @AppStorage("apiKey") private var apiKey = ""
    @AppStorage("customServerURL") private var customServerURL = ""
    
    var body: some View {
        NavigationStack {
            ZStack {
                // Deep, vibrant dark mode gradient
                LinearGradient(
                    gradient: Gradient(colors: [
                        Color(red: 0.05, green: 0.03, blue: 0.12), // Deep Violet
                        Color(red: 0.12, green: 0.05, blue: 0.25)  // Rich Indigo
                    ]),
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                .ignoresSafeArea()
                
                ScrollView(showsIndicators: false) {
                    VStack(spacing: 25) {
                    // Header Logo & Title
                    ZStack(alignment: .topTrailing) {
                        HStack {
                            Spacer()
                            VStack(spacing: 10) {
                                Image("Logo")
                                    .resizable()
                                    .aspectRatio(contentMode: .fit)
                                    .frame(width: 80, height: 80)
                                    .shadow(color: Color.black.opacity(0.15), radius: 10, x: 0, y: 5)
                                
                                Text("DataDonor")
                                    .font(.system(size: 32, weight: .heavy, design: .rounded))
                                    .foregroundColor(Color.primary.opacity(0.85))
                            }
                            Spacer()
                        }
                        
                        NavigationLink(destination: SettingsView()) {
                            Image(systemName: "gearshape.fill")
                                .font(.title3)
                                .foregroundColor(Color.primary.opacity(0.6))
                                .padding(12)
                                .background(.ultraThinMaterial)
                                .clipShape(Circle())
                                .shadow(color: Color.black.opacity(0.05), radius: 8, x: 0, y: 4)
                        }
                        .padding(.trailing, 20)
                        .padding(.top, 10)
                    }
                    .padding(.top, 10)
                    
                    // Server Connection Glassmorphism Card
                    VStack(spacing: 12) {
                        if let url = (!customServerURL.isEmpty ? URL(string: customServerURL) : serverDiscoveryManager.resolvedURL) {
                            HStack {
                                Image(systemName: "server.rack")
                                    .font(.title3)
                                Text("Connected to Server")
                                    .font(.headline)
                                Spacer()
                                Image(systemName: "checkmark.circle.fill")
                                    .font(.title3)
                            }
                            .foregroundColor(Color(red: 0.3, green: 0.65, blue: 0.5)) // Pastel green
                            
                            Text(url.absoluteString)
                                .font(.footnote)
                                .foregroundColor(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        } else {
                            HStack {
                                ProgressView()
                                    .tint(Color.purple.opacity(0.5))
                                Text("Discovering Server...")
                                    .font(.headline)
                                    .foregroundColor(.secondary)
                                Spacer()
                            }
                        }
                    }
                    .padding(20)
                    .background(.ultraThinMaterial)
                    .cornerRadius(24)
                    .shadow(color: Color.black.opacity(0.04), radius: 20, x: 0, y: 10)
                    .padding(.horizontal, 20)
                    
                    // Beautiful Dashboard Chart
                    DashboardView()
                        .padding(.horizontal, 20)
                    
                    Spacer()
                    
                    // Modern Floating Action Button
                    if !healthStoreManager.isAuthorized {
                        Button(action: {
                            healthStoreManager.requestAuthorization()
                        }) {
                            HStack {
                                Image(systemName: "heart.fill")
                                Text("Grant Health Access")
                                    .fontWeight(.bold)
                            }
                            .font(.title3)
                            .foregroundColor(.white)
                            .padding(.vertical, 18)
                            .frame(maxWidth: .infinity)
                            .background(
                                LinearGradient(
                                    colors: [Color(red: 1.0, green: 0.65, blue: 0.75), Color(red: 0.9, green: 0.55, blue: 0.85)],
                                    startPoint: .leading,
                                    endPoint: .trailing
                                )
                            )
                            .cornerRadius(25)
                            .shadow(color: Color(red: 1.0, green: 0.65, blue: 0.75).opacity(0.4), radius: 15, x: 0, y: 8)
                        }
                        .padding(.horizontal, 30)
                        .padding(.bottom, 30)
                    } else {
                        if healthQueryManager.isSyncing {
                            Button(action: {
                                healthQueryManager.cancelSync()
                            }) {
                                HStack {
                                    Image(systemName: "stop.circle.fill")
                                    Text("Stop Sync")
                                        .fontWeight(.bold)
                                }
                                .font(.title3)
                                .foregroundColor(.white)
                                .padding(.vertical, 18)
                                .frame(maxWidth: .infinity)
                                .background(
                                    LinearGradient(
                                        colors: [Color(red: 0.9, green: 0.4, blue: 0.4), Color(red: 0.8, green: 0.3, blue: 0.3)],
                                        startPoint: .leading,
                                        endPoint: .trailing
                                    )
                                )
                                .cornerRadius(25)
                                .shadow(color: Color(red: 0.9, green: 0.4, blue: 0.4).opacity(0.4), radius: 15, x: 0, y: 8)
                            }
                            .padding(.horizontal, 30)
                            .padding(.bottom, 30)
                        } else {
                            Button(action: {
                                Task {
                                    let overrideURL = URL(string: customServerURL)
                                    await healthQueryManager.performSync(
                                        syncEngine: syncEngine,
                                        networkMonitor: networkMonitor,
                                        serverURL: overrideURL ?? serverDiscoveryManager.resolvedURL,
                                        apiKey: apiKey
                                    )
                                }
                            }) {
                                HStack {
                                    Image(systemName: "arrow.triangle.2.circlepath")
                                    Text("Sync Now")
                                        .fontWeight(.bold)
                                }
                                .font(.title3)
                                .foregroundColor(.white)
                                .padding(.vertical, 18)
                                .frame(maxWidth: .infinity)
                                .background(
                                    LinearGradient(
                                        colors: [Color(red: 0.4, green: 0.6, blue: 0.9), Color(red: 0.3, green: 0.5, blue: 0.8)],
                                        startPoint: .leading,
                                        endPoint: .trailing
                                    )
                                )
                                .cornerRadius(25)
                                .shadow(color: Color(red: 0.4, green: 0.6, blue: 0.9).opacity(0.4), radius: 15, x: 0, y: 8)
                            }
                            .padding(.horizontal, 30)
                            .padding(.bottom, 30)
                        }
                    }
                    }
                }
            }
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .onAppear {
                serverDiscoveryManager.startDiscovery()
            }
        }
        .preferredColorScheme(.dark)
    }
}
