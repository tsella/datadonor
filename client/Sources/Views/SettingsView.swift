import SwiftUI

struct SettingsView: View {
    @AppStorage("apiKey") private var apiKey = ""
    @AppStorage("customServerURL") private var customServerURL = ""
    @EnvironmentObject private var serverDiscoveryManager: ServerDiscoveryManager
    
    @AppStorage("isApiKeyVerified") private var isApiKeyVerified = false
    @State private var isShowingQRScanner = false
    
    @State private var approvedServers: [String] = UserDefaults.standard.stringArray(forKey: "approvedServers") ?? []
    
    var body: some View {
        Form {
            Section(header: Text("Authentication"), footer: Text("The API key shared with your local server.")) {
                if isApiKeyVerified {
                    HStack {
                        SecureField("API Key", text: $apiKey)
                        Spacer()
                        Button(action: { isShowingQRScanner = true }) {
                            Image(systemName: "qrcode.viewfinder")
                                .foregroundColor(.blue)
                        }
                    }
                } else {
                    HStack {
                        TextField("API Key", text: $apiKey)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled(true)
                        Spacer()
                        Button(action: { isShowingQRScanner = true }) {
                            Image(systemName: "qrcode.viewfinder")
                                .foregroundColor(.blue)
                        }
                    }
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
                                ServerTrustStore.shared.forget(host: host)
                            }
                        }
                        approvedServers.remove(atOffsets: indexSet)
                        UserDefaults.standard.set(approvedServers, forKey: "approvedServers")
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
            
            Section(header: Text("Debugging")) {
                NavigationLink("View Logs", destination: LogViewer())
            }
        }
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            approvedServers = UserDefaults.standard.stringArray(forKey: "approvedServers") ?? []
        }
        .sheet(isPresented: $isShowingQRScanner) {
            QRScannerView { scannedKey in
                apiKey = scannedKey
                isShowingQRScanner = false
            }
            .ignoresSafeArea()
        }
    }
}

