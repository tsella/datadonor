import SwiftUI

struct SettingsView: View {
    @AppStorage("apiKey") private var apiKey = ""
    @AppStorage("targetSSID") private var targetSSID = ""
    @AppStorage("customServerURL") private var customServerURL = ""
    
    var body: some View {
        Form {
            Section(header: Text("Authentication"), footer: Text("The API key shared with your local server.")) {
                SecureField("API Key", text: $apiKey)
            }
            
            Section(header: Text("Network Sync"), footer: Text("The app will only sync when connected to this Wi-Fi network.")) {
                TextField("Target Wi-Fi SSID", text: $targetSSID)
            }
            
            Section(header: Text("Server Override"), footer: Text("Leave blank to use automatic mDNS discovery (_datadonor._tcp).")) {
                TextField("Custom Server URL", text: $customServerURL)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled(true)
            }
        }
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
    }
}
