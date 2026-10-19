import SwiftUI

struct SettingsView: View {
    @AppStorage("customServerURL") private var customServerURL = ""
    @EnvironmentObject private var serverDiscoveryManager: ServerDiscoveryManager
    @EnvironmentObject private var healthQueryManager: HealthQueryManager
    @EnvironmentObject private var syncEngine: SyncEngine
    
    @State private var apiKey: String = ServerResolver.loadApiKey()
    @State private var isRevealingApiKey = false
    @State private var isShowingQRScanner = false
    @State private var isShowingResetConfirmation = false
    @State private var connectionStatusMessage: String?
    @State private var connectionStatusSuccess = false
    @State private var isTestingConnection = false
    
    @State private var approvedServers: [String] = ServerResolver.approvedServers()
    
    var body: some View {
        Form {
            Section(header: Text("Authentication"), footer: Text("The API key shared with your local server (stored in Keychain).")) {
                HStack {
                    if isRevealingApiKey {
                        TextField("API Key", text: $apiKey)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled(true)
                    } else {
                        SecureField("API Key", text: $apiKey)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled(true)
                    }
                    Button(action: { isRevealingApiKey.toggle() }) {
                        Image(systemName: isRevealingApiKey ? "eye.slash" : "eye")
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.borderless)
                    Button(action: { isShowingQRScanner = true }) {
                        Image(systemName: "qrcode.viewfinder")
                            .foregroundColor(.blue)
                    }
                    .buttonStyle(.borderless)
                }

                if let resolvedURL = ServerResolver.resolve(
                    override: customServerURL,
                    discovered: serverDiscoveryManager.activeServerURL
                ), !apiKey.isEmpty {
                    Button(action: {
                        Task { await testConnection(url: resolvedURL) }
                    }) {
                        HStack {
                            Text("Test Connection")
                            Spacer()
                            if isTestingConnection {
                                ProgressView()
                            }
                        }
                    }
                    .disabled(isTestingConnection)
                }

                if let status = connectionStatusMessage {
                    Label(
                        status,
                        systemImage: connectionStatusSuccess ? "checkmark.circle.fill" : "xmark.octagon.fill"
                    )
                    .font(.caption)
                    .foregroundColor(connectionStatusSuccess ? .green : .red)
                }
            }
            
            Section(header: Text("Approved Servers"), footer: Text("Automatically sync when discovering these Bonjour servers.")) {
                if approvedServers.isEmpty {
                    Text("No servers approved yet.")
                        .foregroundColor(.secondary)
                        .italic()
                } else {
                    ForEach(approvedServers, id: \.self) { server in
                        Text(server)
                    }
                    .onDelete { indexSet in
                        // Drop the pinned certificate too, so re-approving a server with a
                        // rotated cert works instead of failing the pin check forever.
                        for index in indexSet {
                            if let host = URL(string: approvedServers[index])?.host {
                                let targetHost = ServerResolver.canonicalHost(host)
                                ServerTrustStore.shared.forget(host: host)
                                // Removes every stored entry for this host, including
                                // differently-cased ones left by older builds.
                                ServerResolver.revokeApproval(matchingHost: host)
                                if let activeHost = serverDiscoveryManager.activeServerURL?.host,
                                   ServerResolver.canonicalHost(activeHost) == targetHost {
                                    serverDiscoveryManager.activeServerURL = nil
                                }
                            }
                        }
                        approvedServers = ServerResolver.approvedServers()
                    }
                }
            }
            
            Section(header: Text("Server Override"), footer: Text("Leave blank to use automatic mDNS discovery (_datadonor._tcp).")) {
                TextField("Custom Server URL", text: $customServerURL)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled(true)

                if ServerResolver.overrideIsInvalid(customServerURL) {
                    Label(
                        "Not a valid URL. Include the scheme, e.g. https://192.168.1.5:8443",
                        systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundColor(.orange)
                }

                if customServerURL.isEmpty {
                    HStack {
                        Text("Active:")
                            .foregroundColor(.secondary)
                        Spacer()
                        if let active = serverDiscoveryManager.activeServerURL {
                            Text(active.absoluteString)
                                .foregroundColor(.green)
                        } else {
                            Text("Searching...")
                                .foregroundColor(.orange)
                        }
                    }
                }
            }

            Section(
                header: Text("Sync State"),
                footer: Text("Clears local HealthKit checkpoints so the next sync re-uploads your full health history.")
            ) {
                Button(role: .destructive) {
                    isShowingResetConfirmation = true
                } label: {
                    Text("Reset Sync State")
                }
                .disabled(healthQueryManager.isSyncing)
            }
            
            Section(header: Text("Debugging")) {
                NavigationLink("View Logs", destination: LogViewer())
            }
        }
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            apiKey = ServerResolver.loadApiKey()
            approvedServers = ServerResolver.approvedServers()
        }
        .onChange(of: apiKey) { newValue in
            ServerResolver.saveApiKey(newValue)
            connectionStatusMessage = nil
        }
        .alert("Reset Sync State?", isPresented: $isShowingResetConfirmation) {
            Button("Reset", role: .destructive) {
                healthQueryManager.resetAllAnchors()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will clear all local sync checkpoints and re-sync your full HealthKit archive on the next run.")
        }
        .sheet(isPresented: $isShowingQRScanner) {
            QRScannerView { scannedKey in
                apiKey = scannedKey
                ServerResolver.saveApiKey(scannedKey)
                isShowingQRScanner = false
            }
            .ignoresSafeArea()
        }
    }

    @MainActor
    private func testConnection(url: URL) async {
        isTestingConnection = true
        connectionStatusMessage = nil
        defer { isTestingConnection = false }

        do {
            let ok = try await syncEngine.ping(url: url, apiKey: apiKey)
            connectionStatusSuccess = ok
            connectionStatusMessage = ok
                ? "Connected and authenticated with \(url.host ?? url.absoluteString)."
                : "Server responded, but rejected the API key."
        } catch {
            connectionStatusSuccess = false
            connectionStatusMessage = "Connection failed: \(error.localizedDescription)"
        }
    }
}

