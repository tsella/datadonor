import SwiftUI
import Charts

struct SyncDataPoint: Identifiable, Equatable {
    let id = UUID()
    let date: Date
    let type: String
    let count: Int
    // Using a default density of 0.8 for the bar width since it was added later
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
    
    // Vibrant Neon Palette for Dark Mode
    let chartColors: [String: Color] = [
        "Heart Rate": Color(red: 1.0, green: 0.15, blue: 0.35), // Neon Pink/Crimson
        "Steps": Color(red: 0.0, green: 0.8, blue: 1.0),       // Electric Cyan
        "Sleep": Color(red: 0.6, green: 0.2, blue: 1.0),       // Deep Neon Purple
        "Workouts": Color(red: 0.1, green: 0.95, blue: 0.4)    // Neon Green
    ]
    
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            // Header
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Sync History")
                        .font(.title3)
                        .fontWeight(.bold)
                        .foregroundColor(Color.primary.opacity(0.85))
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                    
                    HStack(spacing: 6) {
                        if healthQueryManager.isSyncing {
                            ProgressView()
                                .controlSize(.small)
                                .tint(Color.white.opacity(0.8))
                            Text("Sync in progress...")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        } else if storedLastSync > 0 {
                            Text("Last synced: \(Date(timeIntervalSince1970: storedLastSync), style: .time)")
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
                Text("\(healthQueryManager.totalRecordsSynced)")
                    .font(.headline)
                    .fontWeight(.bold)
                    .foregroundColor(Color.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(
                        LinearGradient(
                            colors: [Color(red: 0.4, green: 0.2, blue: 0.8), Color(red: 0.6, green: 0.3, blue: 0.9)],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .clipShape(Capsule())
                    .shadow(color: Color.black.opacity(0.05), radius: 5, x: 0, y: 2)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            
            // Interactive Legend & Controls
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 12) {
                    ForEach(["Heart Rate", "Steps", "Sleep", "Workouts"], id: \.self) { type in
                        HStack(spacing: 4) {
                            Circle()
                                .fill(chartColors[type] ?? .gray)
                                .frame(width: 8, height: 8)
                            Text(type)
                                .font(.system(size: 11, weight: .medium))
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                        }
                    }
                }
            }
            .padding(.top, -5)
            
            // Animated Chart
            Chart {
                ForEach(syncData) { item in
                    BarMark(
                        x: .value("Date", item.date, unit: .month),
                        y: .value("Records", item.count),
                        width: .ratio(CGFloat(item.density))
                    )
                    .foregroundStyle(chartColors[item.type] ?? .gray)
                    .cornerRadius(4)
                }
            }
            .chartXAxis {
                AxisMarks { _ in
                    AxisGridLine(stroke: StrokeStyle(lineWidth: 1, dash: [4]))
                        .foregroundStyle(Color.gray.opacity(0.15))
                    AxisValueLabel(format: .dateTime.year().month(.abbreviated))
                        .foregroundStyle(Color.primary.opacity(0.6))
                        .font(.caption)
                }
            }
            .chartYAxis {
                AxisMarks(position: .leading) { _ in
                    AxisGridLine(stroke: StrokeStyle(lineWidth: 1, dash: [4]))
                        .foregroundStyle(Color.gray.opacity(0.15))
                    AxisValueLabel()
                        .foregroundStyle(Color.primary.opacity(0.5))
                        .font(.caption2)
                }
            }
            .chartLegend(.hidden)
            .frame(height: 220)
            .animation(.spring(response: 0.6, dampingFraction: 0.8), value: syncData)
        }
        .padding(24)
        .background(.ultraThinMaterial)
        .cornerRadius(28)
        .shadow(color: Color.black.opacity(0.05), radius: 25, x: 0, y: 15)
        .onAppear {
            lastRefreshCount = healthQueryManager.totalRecordsSynced
            refreshData()
        }
        .onChange(of: healthQueryManager.totalRecordsSynced) { newTotal in
            if healthQueryManager.isSyncing {
                if newTotal - lastRefreshCount >= 5000 {
                    lastRefreshCount = newTotal
                    refreshData()
                }
            }
        }
        .onChange(of: healthQueryManager.isSyncing) { isSyncing in
            if !isSyncing {
                // Refresh after sync finishes
                lastRefreshCount = healthQueryManager.totalRecordsSynced
                refreshData()
            }
        }
        .onChange(of: serverDiscoveryManager.resolvedURL) { newURL in
            if newURL != nil {
                refreshData()
            }
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
        
        // 1. Load from cache immediately
        if let cachedData = UserDefaults.standard.data(forKey: cacheKey),
           let response = try? JSONDecoder().decode(ServerStatsResponse.self, from: cachedData) {
            await MainActor.run {
                updateChartData(from: response.stats)
            }
        }
        
        // 2. Fetch fresh data from server
        let serverStr = !customServerURL.isEmpty ? customServerURL : serverDiscoveryManager.resolvedURL?.absoluteString ?? ""
        guard let serverURL = URL(string: serverStr) else { return }
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
