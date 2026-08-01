import SwiftUI
import Charts

struct SyncDataPoint: Identifiable, Equatable {
    let id = UUID()
    let date: Date
    let type: String
    let count: Int
    let density: Double
}

enum TimeScale {
    case days, months, years
}

struct DashboardView: View {
    @AppStorage("totalRecordsSynced") private var totalRecordsSynced: Int = 0
    @AppStorage("lastSyncTimestamp") private var storedLastSync: Double = 0.0
    @State private var timeScale: TimeScale = .days
    
    let syncData: [SyncDataPoint] = []
    
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
                        if storedLastSync > 0 {
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
                Text("\(totalRecordsSynced)")
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
                    let unit: Calendar.Component = {
                        switch timeScale {
                        case .days: return .day
                        case .months: return .month
                        case .years: return .year
                        }
                    }()
                    BarMark(
                        x: .value("Date", item.date, unit: unit),
                        y: .value("Records", item.count),
                        width: .ratio(CGFloat(item.density))
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
                        AxisValueLabel(format: .dateTime.weekday(.abbreviated), centered: true)
                            .foregroundStyle(Color.primary.opacity(0.6))
                            .font(.caption)
                    }
                } else if timeScale == .months {
                    // Omit explicit stride so Swift Charts automatically spaces the 24 months nicely
                    AxisMarks { value in
                        AxisGridLine(stroke: StrokeStyle(lineWidth: 1, dash: [4]))
                            .foregroundStyle(Color.gray.opacity(0.15))
                        AxisValueLabel(centered: true) {
                            if let date = value.as(Date.self) {
                                VStack(spacing: 2) {
                                    Text(date, format: .dateTime.month(.abbreviated))
                                        .font(.caption)
                                    Text(date, format: .dateTime.year())
                                        .font(.caption2)
                                }
                                .foregroundStyle(Color.primary.opacity(0.6))
                            }
                        }
                    }
                } else {
                    AxisMarks(values: .stride(by: .year)) { _ in
                        AxisGridLine(stroke: StrokeStyle(lineWidth: 1, dash: [4]))
                            .foregroundStyle(Color.gray.opacity(0.15))
                        AxisValueLabel(format: .dateTime.year(), centered: true)
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
            .animation(.easeInOut, value: timeScale)
        }
        .padding(24)
        .background(.ultraThinMaterial)
        .cornerRadius(28)
        .shadow(color: Color.black.opacity(0.05), radius: 25, x: 0, y: 15)
    }
    

}
