import SwiftUI

struct ContentView: View {
    @EnvironmentObject var healthStoreManager: HealthStoreManager
    @EnvironmentObject var serverDiscoveryManager: ServerDiscoveryManager
    
    var body: some View {
        NavigationStack {
            ZStack {
                // True full-screen pastel gradient background
                LinearGradient(
                    gradient: Gradient(colors: [
                        Color(red: 0.96, green: 0.93, blue: 1.0), // Soft Lavender
                        Color(red: 1.0, green: 0.95, blue: 0.96)  // Pale Pink
                    ]),
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                .ignoresSafeArea()
                
                VStack(spacing: 25) {
                    // Header Logo & Title
                    VStack(spacing: 10) {
                        Image(systemName: "heart.text.square.fill")
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(width: 70, height: 70)
                            .foregroundStyle(
                                LinearGradient(
                                    colors: [Color(red: 1.0, green: 0.6, blue: 0.7), Color(red: 0.7, green: 0.5, blue: 0.9)],
                                    startPoint: .top, endPoint: .bottom
                                )
                            )
                            .shadow(color: Color(red: 1.0, green: 0.6, blue: 0.7).opacity(0.4), radius: 15, x: 0, y: 8)
                        
                        Text("DataDonor")
                            .font(.system(size: 32, weight: .heavy, design: .rounded))
                            .foregroundColor(Color.primary.opacity(0.85))
                    }
                    .padding(.top, 20)
                    
                    // Server Connection Glassmorphism Card
                    VStack(spacing: 12) {
                        if let url = serverDiscoveryManager.resolvedURL {
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
                }
                .padding(.top, 30) // added to push content below the settings icon
            }
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    NavigationLink(destination: SettingsView()) {
                        Image(systemName: "slider.horizontal.3")
                            .font(.title3)
                            .foregroundColor(Color.primary.opacity(0.6))
                            .padding(8)
                            .background(.ultraThinMaterial)
                            .clipShape(Circle())
                    }
                }
            }
        }
    }
}
