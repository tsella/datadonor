import SwiftUI
import Charts

struct SyncDataPoint: Identifiable, Equatable {
    let id = UUID()
    let date: Date
    let type: String
    let count: Int
}

enum TimeScale {
    case days, weeks, months
}

struct DashboardView: View {
    @State private var syncData: [SyncDataPoint] = []
    @State private var timeScale: TimeScale = .days
    @State private var isSyncing = false
    @State private var lastSyncTimestamp: Date? = nil
    
    // Custom curated pastel palette
    let chartColors: [String: Color] = [
        "Heart Rate": Color(red: 1.0, green: 0.7, blue: 0.75), // Pastel Pink
        "Steps": Color(red: 0.65, green: 0.8, blue: 1.0),      // Pastel Blue
        "Sleep": Color(red: 0.8, green: 0.75, blue: 0.95),     // Pastel Purple
        "Workouts": Color(red: 0.65, green: 0.9, blue: 0.75)   // Pastel Green
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
                    
                    HStack(spacing: 6) {
                        if isSyncing {
                            ProgressView()
                                .controlSize(.small)
                                .tint(Color(red: 0.65, green: 0.5, blue: 0.9))
                            Text("Sync in progress...")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        } else if let lastSync = lastSyncTimestamp {
                            Text("Last synced: \(lastSync, style: .time)")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        } else {
                            Text("Waiting for sync...")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                }
                
                Spacer()
                
                // Total Count
                Text("\(syncData.map { $0.count }.reduce(0, +))")
                    .font(.headline)
                    .fontWeight(.bold)
                    .foregroundColor(Color(red: 0.65, green: 0.5, blue: 0.9))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(Color.white.opacity(0.7))
                    .clipShape(Capsule())
                    .shadow(color: Color.black.opacity(0.05), radius: 5, x: 0, y: 2)
            }
            
            // Interactive Legend
            HStack(spacing: 12) {
                ForEach(["Heart Rate", "Steps", "Sleep", "Workouts"], id: \.self) { type in
                    HStack(spacing: 4) {
                        Circle()
                            .fill(chartColors[type] ?? .gray)
                            .frame(width: 8, height: 8)
                        Text(type)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(.secondary)
                    }
                }
            }
            .padding(.top, -5)
            
            // Animated Chart
            Chart {
                ForEach(syncData) { item in
                    BarMark(
                        x: .value("Date", item.date, unit: timeScale == .days ? .day : (timeScale == .weeks ? .weekOfYear : .month)),
                        y: .value("Records", item.count)
                    )
                    .foregroundStyle(chartColors[item.type] ?? .gray)
                    .cornerRadius(4)
                }
            }
            .chartXAxis {
                if timeScale == .days {
                    AxisMarks(values: .stride(by: .day)) { _ in
                        AxisGridLine(stroke: StrokeStyle(lineWidth: 1, dash: [4]))
                            .foregroundStyle(Color.gray.opacity(0.15))
                        AxisValueLabel(format: .dateTime.weekday(.abbreviated))
                            .foregroundStyle(Color.primary.opacity(0.6))
                            .font(.caption)
                    }
                } else if timeScale == .weeks {
                    AxisMarks(values: .stride(by: .weekOfYear)) { _ in
                        AxisGridLine(stroke: StrokeStyle(lineWidth: 1, dash: [4]))
                            .foregroundStyle(Color.gray.opacity(0.15))
                        AxisValueLabel(format: .dateTime.week())
                            .foregroundStyle(Color.primary.opacity(0.6))
                            .font(.caption)
                    }
                } else {
                    AxisMarks(values: .stride(by: .month)) { _ in
                        AxisGridLine(stroke: StrokeStyle(lineWidth: 1, dash: [4]))
                            .foregroundStyle(Color.gray.opacity(0.15))
                        AxisValueLabel(format: .dateTime.month(.abbreviated))
                            .foregroundStyle(Color.primary.opacity(0.6))
                            .font(.caption)
                    }
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
            .animation(.easeInOut, value: timeScale)
        }
        .padding(24)
        .background(.ultraThinMaterial)
        .cornerRadius(28)
        .shadow(color: Color.black.opacity(0.05), radius: 25, x: 0, y: 15)
        .onAppear {
            simulateSync()
        }
    }
    
    func simulateSync() {
        guard !isSyncing else { return }
        isSyncing = true
        syncData = []
        timeScale = .days
        
        let types = ["Heart Rate", "Steps", "Sleep", "Workouts"]
        let calendar = Calendar.current
        let today = Date()
        
        // Stage 1: Sync Days
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            var daysData: [SyncDataPoint] = []
            for dayOffset in (0..<7).reversed() {
                guard let date = calendar.date(byAdding: .day, value: -dayOffset, to: today) else { continue }
                for type in types {
                    let maxCount = (type == "Sleep" || type == "Workouts") ? 5 : 800
                    daysData.append(SyncDataPoint(date: date, type: type, count: Int.random(in: 1...maxCount)))
                }
            }
            syncData = daysData
            
            // Stage 2: Sync Weeks
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                timeScale = .weeks
                var weeksData: [SyncDataPoint] = []
                for weekOffset in (0..<4).reversed() {
                    guard let date = calendar.date(byAdding: .weekOfYear, value: -weekOffset, to: today) else { continue }
                    for type in types {
                        let maxCount = (type == "Sleep" || type == "Workouts") ? 35 : 5600
                        weeksData.append(SyncDataPoint(date: date, type: type, count: Int.random(in: 20...maxCount)))
                    }
                }
                syncData = weeksData
                
                // Stage 3: Sync Months
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                    timeScale = .months
                    var monthsData: [SyncDataPoint] = []
                    for monthOffset in (0..<6).reversed() {
                        guard let date = calendar.date(byAdding: .month, value: -monthOffset, to: today) else { continue }
                        for type in types {
                            let maxCount = (type == "Sleep" || type == "Workouts") ? 150 : 24000
                            monthsData.append(SyncDataPoint(date: date, type: type, count: Int.random(in: 100...maxCount)))
                        }
                    }
                    syncData = monthsData
                    
                    // Finish
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                        isSyncing = false
                        lastSyncTimestamp = Date()
                    }
                }
            }
        }
    }
}
