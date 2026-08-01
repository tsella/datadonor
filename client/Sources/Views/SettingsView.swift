import SwiftUI

struct SettingsView: View {
    @AppStorage("apiKey") private var apiKey = ""
    @AppStorage("targetSSID") private var targetSSID = ""
    @AppStorage("isSSIDLocked") private var isSSIDLocked = false
    @AppStorage("customServerURL") private var customServerURL = ""
    @EnvironmentObject private var networkMonitor: NetworkMonitor
    @EnvironmentObject private var serverDiscoveryManager: ServerDiscoveryManager
    
    @AppStorage("isApiKeyVerified") private var isApiKeyVerified = false
    
    var body: some View {
        Form {
            Section(header: Text("Authentication"), footer: Text("The API key shared with your local server.")) {
                if isApiKeyVerified {
                    SecureField("API Key", text: $apiKey)
                } else {
                    TextField("API Key", text: $apiKey)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled(true)
                }
            }
            
            Section(header: Text("Network Sync"), footer: Text("The app will only sync when connected to this Wi-Fi network.")) {
                HStack {
                    if isSSIDLocked {
                        Text(targetSSID.isEmpty ? "None" : targetSSID)
                            .foregroundColor(targetSSID.isEmpty ? .gray : .primary)
                    } else {
                        TextField("Target Wi-Fi SSID", text: $targetSSID)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled(true)
                    }
                    
                    Spacer()
                    
                    Button(action: {
                        withAnimation {
                            isSSIDLocked.toggle()
                        }
                    }) {
                        Image(systemName: isSSIDLocked ? "lock.fill" : "lock.open.fill")
                            .foregroundColor(isSSIDLocked ? .green : .gray)
                    }
                }
                
                if !isSSIDLocked, let currentSSID = networkMonitor.currentSSID, !currentSSID.isEmpty {
                    Button(action: {
                        targetSSID = currentSSID
                        withAnimation {
                            isSSIDLocked = true
                        }
                    }) {
                        HStack {
                            Text("Use Current: \(currentSSID)")
                                .foregroundColor(.primary)
                            Spacer()
                            SignalStrengthView(strength: networkMonitor.currentSignalStrength)
                        }
                    }
                }
            }
            
            Section(header: Text("Server Override"), footer: Text("Leave blank to use automatic mDNS discovery (_datadonor._tcp).")) {
                TextField("Custom Server URL", text: $customServerURL)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled(true)
                
                if customServerURL.isEmpty {
                    HStack {
                        Text("Discovered:")
                            .foregroundColor(.secondary)
                        Spacer()
                        if let resolved = serverDiscoveryManager.resolvedURL {
                            Text(resolved.absoluteString)
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
    }
}

struct SignalStrengthView: View {
    var strength: Double // 0.0 to 1.0
    
    var body: some View {
        HStack(spacing: 2) {
            ForEach(0..<4) { index in
                let threshold = Double(index + 1) / 4.0
                let isFilled = strength >= threshold || (index == 0 && strength > 0)
                RoundedRectangle(cornerRadius: 1)
                    .fill(isFilled ? Color.blue : Color.gray.opacity(0.3))
                    .frame(width: 4, height: 6 + CGFloat(index * 3))
            }
        }
        .frame(height: 16, alignment: .bottom)
    }
}
