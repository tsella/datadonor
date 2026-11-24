import SwiftUI

struct SettingsView: View {
    @AppStorage("customServerURL") private var customServerURL = ""
    @EnvironmentObject private var serverDiscoveryManager: ServerDiscoveryManager
    @EnvironmentObject private var healthQueryManager: HealthQueryManager
    @EnvironmentObject private var syncEngine: SyncEngine
    
    @State private var apiKey: String = ServerResolver.loadApiKey()
    @State private var apiKeySaveError: String?
    @State private var isRevealingApiKey = false
    @State private var isShowingQRScanner = false
    @State private var isShowingResetConfirmation = false
    @State private var connectionStatusMessage: String?
    @State private var connectionStatusSuccess = false
    @State private var isTestingConnection = false
    @State private var testConnectionTask: Task<Void, Never>?
    @State private var testConnectionGuard = FetchGenerationGuard()
    
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

                if let apiKeySaveError {
                    Label(apiKeySaveError, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundColor(.red)
                }

                if let resolvedURL = ServerResolver.resolve(
                    override: customServerURL,
                    discovered: serverDiscoveryManager.activeServerURL
                ), !apiKey.isEmpty {
                    Button(action: {
                        startTestConnection(url: resolvedURL)
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

            Section(header: Text("About")) {
                HStack {
                    Text("Version")
                    Spacer()
                    Text(Self.appVersionDescription)
                        .foregroundColor(.secondary)
                }
            }
        }
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            apiKey = ServerResolver.loadApiKey()
            approvedServers = ServerResolver.approvedServers()
        }
        .onChange(of: apiKey) { _, newValue in
            persistApiKey(newValue)
            cancelTestConnection(clearMessage: true)
        }
        .onChange(of: customServerURL) {
            cancelTestConnection(clearMessage: true)
        }
        .onDisappear {
            cancelTestConnection(clearMessage: false)
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
                persistApiKey(scannedKey)
                isShowingQRScanner = false
            }
            .ignoresSafeArea()
        }
    }

    private func persistApiKey(_ value: String) {
        if ServerResolver.saveApiKey(value) {
            apiKeySaveError = nil
        } else {
            apiKeySaveError = "Could not save API key to Keychain. Unlock your device and try again."
        }
    }

    private static var appVersionDescription: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "—"
        let build = info?["CFBundleVersion"] as? String ?? "—"
        return "\(version) (\(build))"
    }

    private func cancelTestConnection(clearMessage: Bool) {
        _ = testConnectionGuard.beginNext()
        testConnectionTask?.cancel()
        testConnectionTask = nil
        isTestingConnection = false
        if clearMessage {
            connectionStatusMessage = nil
        }
    }

    private func startTestConnection(url: URL) {
        testConnectionTask?.cancel()
        let generation = testConnectionGuard.beginNext()
        let keySnapshot = apiKey
        let engine = syncEngine

        isTestingConnection = true
        connectionStatusMessage = nil

        testConnectionTask = Task { @MainActor in
            defer {
                if testConnectionGuard.isCurrent(generation) {
                    isTestingConnection = false
                }
            }
            let result = await engine.checkConnection(url: url, apiKey: keySnapshot)
            guard !Task.isCancelled, testConnectionGuard.isCurrent(generation) else { return }

            switch result {
            case .ok:
                connectionStatusSuccess = true
                connectionStatusMessage = "Connected and authenticated with \(url.host ?? url.absoluteString)."
            case .unauthorized:
                connectionStatusSuccess = false
                connectionStatusMessage = "Server responded, but rejected the API key."
            case .serverError(let code):
                connectionStatusSuccess = false
                connectionStatusMessage = "Server returned HTTP \(code)."
            case .unreachable(let reason):
                connectionStatusSuccess = false
                connectionStatusMessage = "Connection failed: \(reason)"
            }
        }
    }
}

