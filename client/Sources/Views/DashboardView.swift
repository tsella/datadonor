import SwiftUI
import Charts
import UIKit

struct SyncDataPoint: Identifiable, Equatable {
    let id = UUID()
    let date: Date
    let type: String
    let count: Int
    var density: Double = 0.8
}

struct ServerStat: Codable {
    let date: String
    let type: String
    let count: Int
}
struct ServerStatsResponse: Codable {
    let stats: [ServerStat]
}

struct DashboardView: View {
    @AppStorage("lastSyncTimestamp") private var storedLastSync: Double = 0.0
    @EnvironmentObject var healthQueryManager: HealthQueryManager
    @EnvironmentObject var serverDiscoveryManager: ServerDiscoveryManager
    @EnvironmentObject var syncEngine: SyncEngine
    @AppStorage("apiKey") private var apiKey = ""
    @AppStorage("customServerURL") private var customServerURL = ""
    
    @State private var syncData: [SyncDataPoint] = []
    @State private var fetchTask: Task<Void, Never>?
    @State private var lastRefreshCount: Int = 0
    
    // Earthy pastel palette matching mockup
    let chartColors: [String: Color] = [
        "Heart Rate": Color(red: 223/255.0, green: 107/255.0, blue: 83/255.0),
        "Steps": Color(red: 103/255.0, green: 139/255.0, blue: 150/255.0),
        "Sleep": Color(red: 35/255.0, green: 163/255.0, blue: 147/255.0),
        "Workouts": Color(red: 210/255.0, green: 163/255.0, blue: 91/255.0)
    ]
    
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            // Header
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Sync History")
                        .font(.headline)
                        .foregroundColor(.primary)
                    
                    HStack(spacing: 6) {
                        if healthQueryManager.isSyncing {
                            ProgressView()
                                .controlSize(.small)
                            Text("auto-sync on")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        } else if storedLastSync > 0 {
                            Text("Last synced \(Date(timeIntervalSince1970: storedLastSync).formatted(date: .omitted, time: .shortened)) · auto-sync on")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        } else {
                            Text("No records synced yet.")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                }
                
                Spacer()
                
                // Total Count
                Text(formatCount(healthQueryManager.totalRecordsSynced))
                    .font(.headline)
                    .fontWeight(.bold)
                    .foregroundColor(Color(red: 0.04, green: 0.63, blue: 0.57)) // Teal color
            }
            
            // Animated Chart
            Chart {
                ForEach(syncData) { item in
                    BarMark(
                        x: .value("Date", item.date, unit: .month),
                        y: .value("Records", item.count),
                        width: .ratio(CGFloat(item.density))
                    )
                    .foregroundStyle(chartColors[item.type] ?? .gray)
                }
            }
            .chartXAxis {
                AxisMarks(values: .stride(by: .year)) { value in
                    AxisValueLabel(format: .dateTime.year())
                        .foregroundStyle(Color.secondary)
                        .font(.caption)
                }
            }
            .chartYAxis(.hidden)
            .chartLegend(.hidden)
            .frame(height: 250)
            .animation(.spring(response: 0.6, dampingFraction: 0.8), value: syncData)
            
            // Legend at the bottom
            HStack(spacing: 16) {
                ForEach(["Heart Rate", "Steps", "Sleep", "Workouts"], id: \.self) { type in
                    HStack(spacing: 6) {
                        Circle()
                            .fill(chartColors[type] ?? .gray)
                            .frame(width: 8, height: 8)
                        Text(type == "Heart Rate" ? "Heart" : type)
                            .font(.caption)
                            .foregroundColor(.primary)
                    }
                }
            }
            .padding(.top, 10)
        }
        .padding(20)
        .background(Color(uiColor: .secondarySystemGroupedBackground))
        .cornerRadius(20)
        .shadow(color: Color.black.opacity(0.05), radius: 10, x: 0, y: 5)
        .onAppear {
            lastRefreshCount = healthQueryManager.totalRecordsSynced
            refreshData()
        }
        .onChange(of: healthQueryManager.totalRecordsSynced) { newTotal in
            if healthQueryManager.isSyncing {
                if newTotal < lastRefreshCount {
                    lastRefreshCount = newTotal
                }
                if newTotal - lastRefreshCount >= 5000 {
                    lastRefreshCount = newTotal
                    refreshData()
                }
            }
        }
        .onChange(of: healthQueryManager.isSyncing) { isSyncing in
            if !isSyncing {
                lastRefreshCount = healthQueryManager.totalRecordsSynced
                refreshData()
            }
        }
        .onChange(of: serverDiscoveryManager.activeServerURL) { newURL in
            if newURL != nil {
                refreshData()
            }
        }
    }
    
    private func formatCount(_ count: Int) -> String {
        if count >= 1_000_000 {
            return String(format: "%.2fM", Double(count) / 1_000_000.0)
        } else if count >= 1_000 {
            return String(format: "%.1fK", Double(count) / 1_000.0)
        } else {
            return "\(count)"
        }
    }
    
    private func refreshData() {
        fetchTask?.cancel()
        fetchTask = Task {
            await fetchDashboardStats()
        }
    }
    
    private func fetchDashboardStats() async {
        let cacheKey = "dashboard_cache_months"
        
        if let cachedData = UserDefaults.standard.data(forKey: cacheKey),
           let response = try? JSONDecoder().decode(ServerStatsResponse.self, from: cachedData) {
            await MainActor.run {
                updateChartData(from: response.stats)
            }
        }
        
        // Only ever talk to an approved server — this used to use the pre-approval
        // `resolvedURL`, which sent the API key to any host that answered mDNS.
        guard let serverURL = ServerResolver.resolve(
            override: customServerURL,
            discovered: serverDiscoveryManager.activeServerURL) else { return }
        let deviceId = UIDevice.current.identifierForVendor?.uuidString ?? ""
        
        do {
            let data = try await syncEngine.fetchStats(
                serverURL: serverURL,
                apiKey: apiKey,
                timeScale: "months",
                deviceId: deviceId
            )
            
            if let decoded = try? JSONDecoder().decode(ServerStatsResponse.self, from: data) {
                UserDefaults.standard.set(data, forKey: cacheKey)
                await MainActor.run {
                    updateChartData(from: decoded.stats)
                }
            }
        } catch {
            print("Dashboard fetch failed: \(error)")
        }
    }
    
    private func updateChartData(from serverStats: [ServerStat]) {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        
        var newPoints: [SyncDataPoint] = []
        for stat in serverStats {
            if let date = formatter.date(from: stat.date) {
                newPoints.append(SyncDataPoint(date: date, type: stat.type, count: stat.count))
            }
        }
        
        withAnimation(.spring(response: 0.6, dampingFraction: 0.8)) {
            self.syncData = newPoints
        }
    }
}
