import SwiftUI

struct ContentView: View {
    @EnvironmentObject var healthStoreManager: HealthStoreManager
    @EnvironmentObject var serverDiscoveryManager: ServerDiscoveryManager
    @EnvironmentObject var healthQueryManager: HealthQueryManager
    @EnvironmentObject var syncEngine: SyncEngine
    @AppStorage("apiKey") private var apiKey = ""
    @AppStorage("customServerURL") private var customServerURL = ""
    
    @State private var showingApprovalAlert = false
    
    var body: some View {
        NavigationStack {
            ZStack {
                // Adaptive system background
                Color(uiColor: .systemGroupedBackground)
                    .ignoresSafeArea()
                
                ScrollView(showsIndicators: false) {
                    VStack(spacing: 25) {
                        // Header Logo & Title
                        HStack(alignment: .center, spacing: 12) {
                            Image("Logo")
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                                .frame(width: 44, height: 44)
                                .clipShape(RoundedRectangle(cornerRadius: 10))
                                .shadow(color: Color.black.opacity(0.1), radius: 4, x: 0, y: 2)
                            
                            Text("DataDonor")
                                .font(.system(size: 28, weight: .bold, design: .rounded))
                                .foregroundColor(.primary)
                            
                            Spacer()
                            
                            NavigationLink(destination: SettingsView()) {
                                Image(systemName: "gearshape.fill")
                                    .font(.title3)
                                    .foregroundColor(.secondary)
                                    .padding(12)
                                    .background(Color(uiColor: .secondarySystemGroupedBackground))
                                    .clipShape(Circle())
                                    .shadow(color: Color.black.opacity(0.05), radius: 5, x: 0, y: 2)
                            }
                        }
                        .padding(.horizontal, 20)
                        .padding(.top, 10)
                        
                        // Server Connection Card
                        VStack(spacing: 12) {
                            if let url = ServerResolver.resolve(override: customServerURL, discovered: serverDiscoveryManager.activeServerURL) {
                                HStack {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text("Connected to Server")
                                            .font(.headline)
                                            .foregroundColor(.primary)
                                        
                                        // Extract host and port
                                        if let host = url.host, let port = url.port {
                                            Text("\(host):\(String(port))")
                                                .font(.subheadline)
                                                .foregroundColor(.secondary)
                                        } else {
                                            Text(url.absoluteString)
                                                .font(.subheadline)
                                                .foregroundColor(.secondary)
                                        }
                                    }
                                    
                                    Spacer()
                                    
                                    Image(systemName: "checkmark.circle.fill")
                                        .font(.title2)
                                        .foregroundColor(Color(red: 0.04, green: 0.63, blue: 0.57)) // Teal checkmark
                                }
                            } else if ServerResolver.overrideIsInvalid(customServerURL) {
                                HStack {
                                    Image(systemName: "exclamationmark.triangle.fill")
                                        .foregroundColor(.orange)
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text("Invalid Server URL")
                                            .font(.headline)
                                            .foregroundColor(.primary)
                                        Text("Include a scheme, e.g. https://192.168.1.5:8443")
                                            .font(.subheadline)
                                            .foregroundColor(.secondary)
                                    }
                                    Spacer()
                                }
                            } else {
                                HStack {
                                    ProgressView()
                                        .tint(.secondary)
                                    Text("Discovering Server...")
                                        .font(.headline)
                                        .foregroundColor(.secondary)
                                        .padding(.leading, 8)
                                    Spacer()
                                }
                            }
                        }
                        .padding(20)
                        .background(Color(uiColor: .secondarySystemGroupedBackground))
                        .cornerRadius(20)
                        .shadow(color: Color.black.opacity(0.05), radius: 10, x: 0, y: 5)
                        .padding(.horizontal, 20)
                        
                        // Dashboard Chart
                        DashboardView()
                            .padding(.horizontal, 20)
                        
                        Spacer(minLength: 20)
                        
                        // Action Button
                        if !healthStoreManager.isAuthorized {
                            Button(action: {
                                healthStoreManager.requestAuthorization()
                            }) {
                                HStack {
                                    Image(systemName: "heart.fill")
                                    Text("Grant Health Access")
                                        .fontWeight(.semibold)
                                }
                                .font(.headline)
                                .foregroundColor(.white)
                                .padding(.vertical, 16)
                                .frame(maxWidth: .infinity)
                                .background(Color(red: 0.04, green: 0.63, blue: 0.57)) // Solid Teal
                                .cornerRadius(16)
                                .shadow(color: Color(red: 0.04, green: 0.63, blue: 0.57).opacity(0.3), radius: 10, x: 0, y: 5)
                            }
                            .padding(.horizontal, 20)
                            .padding(.bottom, 20)
                        } else {
                            if healthQueryManager.isSyncing {
                                Button(action: {
                                    healthQueryManager.cancelSync()
                                }) {
                                    HStack {
                                        Image(systemName: "stop.circle.fill")
                                        Text("Stop Sync")
                                            .fontWeight(.semibold)
                                    }
                                    .font(.headline)
                                    .foregroundColor(.white)
                                    .padding(.vertical, 16)
                                    .frame(maxWidth: .infinity)
                                    .background(Color.red.opacity(0.9))
                                    .cornerRadius(16)
                                    .shadow(color: Color.red.opacity(0.3), radius: 10, x: 0, y: 5)
                                }
                                .padding(.horizontal, 20)
                                .padding(.bottom, 20)
                            } else {
                                Button(action: {
                                    Task {
                                        await healthQueryManager.performSync(
                                            syncEngine: syncEngine,
                                            serverURL: ServerResolver.resolve(
                                                override: customServerURL,
                                                discovered: serverDiscoveryManager.activeServerURL),
                                            apiKey: apiKey
                                        )
                                    }
                                }) {
                                    HStack {
                                        Image(systemName: "arrow.triangle.2.circlepath")
                                        Text("Sync Now")
                                            .fontWeight(.semibold)
                                    }
                                    .font(.headline)
                                    .foregroundColor(.white)
                                    .padding(.vertical, 16)
                                    .frame(maxWidth: .infinity)
                                    .background(Color(red: 0.04, green: 0.63, blue: 0.57)) // Solid Teal
                                    .cornerRadius(16)
                                    .shadow(color: Color(red: 0.04, green: 0.63, blue: 0.57).opacity(0.3), radius: 10, x: 0, y: 5)
                                }
                                .padding(.horizontal, 20)
                                .padding(.bottom, 20)
                            }
                        }
                    }
                    .padding(.top, 10)
                }
            }
            .navigationTitle("")
            .navigationBarHidden(true)
            .onAppear {
                serverDiscoveryManager.startDiscovery()
            }
            .onChange(of: serverDiscoveryManager.pendingApprovalURL) { newURL in
                if newURL != nil {
                    showingApprovalAlert = true
                }
            }
            .onChange(of: serverDiscoveryManager.activeServerURL) { newURL in
                guard newURL != nil, !healthQueryManager.isSyncing, healthStoreManager.isAuthorized,
                      !apiKey.isEmpty else { return }
                Task {
                    await healthQueryManager.performSync(
                        syncEngine: syncEngine,
                        serverURL: ServerResolver.resolve(override: customServerURL, discovered: newURL),
                        apiKey: apiKey
                    )
                }
            }
            .onChange(of: healthQueryManager.isSyncing) { isSyncing in
                UIApplication.shared.isIdleTimerDisabled = isSyncing
            }
            .alert("New Server Discovered", isPresented: $showingApprovalAlert) {
                Button("Approve") {
                    if let url = serverDiscoveryManager.pendingApprovalURL {
                        var approved = UserDefaults.standard.stringArray(forKey: "approvedServers") ?? []
                        if !approved.contains(url.absoluteString) {
                            approved.append(url.absoluteString)
                        }
                        UserDefaults.standard.set(approved, forKey: "approvedServers")

                        serverDiscoveryManager.activeServerURL = url
                        // Make the server reachable from the background task too.
                        ServerResolver.rememberActive(url)
                        serverDiscoveryManager.pendingApprovalURL = nil
                    }
                }
                Button("Decline", role: .cancel) {
                    serverDiscoveryManager.pendingApprovalURL = nil
                }
            } message: {
                if let url = serverDiscoveryManager.pendingApprovalURL {
                    Text("Would you like to connect and sync with \(url.absoluteString)?")
                } else {
                    Text("Would you like to connect to this new server?")
                }
            }
        }
    }
}
