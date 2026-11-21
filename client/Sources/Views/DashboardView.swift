import SwiftUI
import Charts
import UIKit

struct SyncDataPoint: Identifiable, Equatable, Sendable {
    var id: String { "\(type)-\(Int(date.timeIntervalSince1970))" }
    let date: Date
    let type: String
    let count: Int
    var density: Double = 0.8
}

struct ServerStat: Codable, Sendable {
    let date: String
    let type: String
    let count: Int
}

struct ServerStatsResponse: Codable, Sendable {
    let stats: [ServerStat]
    let totalRecords: Int?

    enum CodingKeys: String, CodingKey {
        case stats
        case totalRecords = "total_records"
    }
}

/// Precomputed lookup tables for `DashboardView` so 60–120Hz drag scrubbing performs O(log N)
/// month snapping and O(1) totals/breakdowns without filtering or sorting inside `body`.
struct SyncHistoryIndex: Equatable, Sendable {
    let visiblePoints: [SyncDataPoint]
    let sortedMonths: [Date]
    let visibleTotalByMonth: [Date: Int]
    let countByMonthAndCategory: [Date: [String: Int]]

    static let empty = SyncHistoryIndex(
        visiblePoints: [],
        sortedMonths: [],
        visibleTotalByMonth: [:],
        countByMonthAndCategory: [:]
    )

    static func build(from allPoints: [SyncDataPoint], selectedCategory: String?) -> SyncHistoryIndex {
        var byMonthAndCat: [Date: [String: Int]] = [:]
        var visible: [SyncDataPoint] = []
        visible.reserveCapacity(allPoints.count)
        var visibleTotals: [Date: Int] = [:]

        for point in allPoints {
            byMonthAndCat[point.date, default: [:]][point.type, default: 0] += point.count
            if selectedCategory == nil || point.type == selectedCategory {
                visible.append(point)
                visibleTotals[point.date, default: 0] += point.count
            }
        }

        let months = visibleTotals.keys.sorted()
        return SyncHistoryIndex(
            visiblePoints: visible,
            sortedMonths: months,
            visibleTotalByMonth: visibleTotals,
            countByMonthAndCategory: byMonthAndCat
        )
    }

    func total(for month: Date) -> Int {
        visibleTotalByMonth[month] ?? 0
    }

    func count(for month: Date, category: String) -> Int? {
        countByMonthAndCategory[month]?[category]
    }

    /// Binary search for the month closest to `date` in O(log M).
    func nearestMonth(to date: Date) -> Date? {
        guard !sortedMonths.isEmpty else { return nil }
        var low = 0
        var high = sortedMonths.count - 1
        while low < high {
            let mid = (low + high) / 2
            if sortedMonths[mid] < date {
                low = mid + 1
            } else {
                high = mid
            }
        }
        if low == 0 { return sortedMonths[0] }
        let before = sortedMonths[low - 1]
        let after = sortedMonths[low]
        return abs(before.timeIntervalSince(date)) <= abs(after.timeIntervalSince(date)) ? before : after
    }
}

struct DashboardView: View {
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("lastSyncTimestamp") private var storedLastSync: Double = 0.0
    @AppStorage("cardCollapsed_syncHistory") private var isCollapsed = false
    @EnvironmentObject var healthQueryManager: HealthQueryManager
    @EnvironmentObject var serverDiscoveryManager: ServerDiscoveryManager
    @EnvironmentObject var syncEngine: SyncEngine
    @AppStorage("customServerURL") private var customServerURL = ""

    @State private var syncData: [SyncDataPoint]
    @State private var index: SyncHistoryIndex
    @State private var serverTotalRecords: Int
    @State private var selectedMonth: Date?
    @State private var selectedCategory: String?
    @State private var fetchTask: Task<Void, Never>?
    @State private var fetchGuard = FetchGenerationGuard()
    @State private var lastRefreshCount: Int = 0

    private static let cacheKey = "dashboard_cache_months"
    private static let categories = ["Heart Rate", "Steps", "Sleep", "Workouts"]

    private static let monthLabelFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM yyyy"
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter
    }()

    init() {
        if let cachedData = UserDefaults.standard.data(forKey: Self.cacheKey),
           let response = try? JSONDecoder().decode(ServerStatsResponse.self, from: cachedData) {
            let points = Self.buildPoints(from: response.stats)
            _syncData = State(initialValue: points)
            _index = State(initialValue: SyncHistoryIndex.build(from: points, selectedCategory: nil))
            let cachedTotal = response.totalRecords ?? points.reduce(0) { $0 + $1.count }
            _serverTotalRecords = State(initialValue: cachedTotal)
        } else {
            _syncData = State(initialValue: [])
            _index = State(initialValue: .empty)
            _serverTotalRecords = State(initialValue: 0)
        }
    }

    var body: some View {
        CollapsibleCard(isCollapsed: $isCollapsed, accessibilityTitle: "Sync History") {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 7) {
                    Image(systemName: "chart.bar.fill")
                        .font(.subheadline)
                        .foregroundColor(AppTheme.Colors.teal)
                    Text("Sync History")
                        .font(.system(.headline, design: .rounded))
                        .foregroundColor(.primary)
                }

                if let selectedMonth {
                    Text("\(Self.monthLabelFormatter.string(from: selectedMonth))\(selectedCategory.map { " · \($0)" } ?? "")")
                        .font(.caption.weight(.medium))
                        .foregroundColor(AppTheme.Colors.teal)
                        .monospacedDigit()
                } else {
                    syncStatusSubtitle
                }
            }
        } headerTrailing: {
            Text(Self.formatCount(selectedMonth.map(index.total(for:)) ?? max(healthQueryManager.totalRecordsSynced, serverTotalRecords)))
                .font(.system(.title3, design: .rounded).weight(.bold))
                .foregroundColor(AppTheme.Colors.teal)
                .monospacedDigit()
                .padding(.top, 1)
                .animation(AppTheme.Animations.readoutUpdate, value: selectedMonth)
        } content: {
            if index.visiblePoints.isEmpty {
                Text("No sync history available yet.")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 48)
            } else {
                syncHistoryChart
                    .frame(height: 225)
            }

            HStack(spacing: 8) {
                ForEach(Self.categories, id: \.self) { type in
                    categoryPill(for: type)
                }
            }
            .padding(.top, 2)
        }
        .task {
            lastRefreshCount = healthQueryManager.totalRecordsSynced
            refreshData()
        }
        .onAppear {
            refreshData()
        }
        .onChange(of: customServerURL) { _ in
            refreshData()
        }
        .onChange(of: scenePhase) { newPhase in
            if newPhase == .active {
                refreshData()
            }
        }
        .onChange(of: healthQueryManager.totalRecordsSynced) { newTotal in
            guard healthQueryManager.isSyncing else { return }
            if newTotal < lastRefreshCount {
                lastRefreshCount = newTotal
            } else if newTotal - lastRefreshCount >= 5000 {
                lastRefreshCount = newTotal
                refreshData()
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

    @ViewBuilder
    private var syncStatusSubtitle: some View {
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
            } else if !syncData.isEmpty {
                Text("Restored from server · auto-sync on")
                    .font(.caption)
                    .foregroundColor(.secondary)
            } else {
                Text("No records synced yet.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
    }

    private var syncHistoryChart: some View {
        Chart {
            if let selectedMonth {
                RuleMark(x: .value("Selected Month", selectedMonth, unit: .month))
                    .foregroundStyle(Color.secondary.opacity(0.22))
                    .lineStyle(StrokeStyle(lineWidth: 1.25, dash: [3, 3]))
            }

            ForEach(index.visiblePoints) { item in
                let baseColor = AppTheme.Colors.syncCategoryColor(for: item.type)
                let isDimmed = (selectedMonth != nil && selectedMonth != item.date)

                BarMark(
                    x: .value("Date", item.date, unit: .month),
                    y: .value("Records", item.count),
                    width: .ratio(0.76)
                )
                .foregroundStyle(AppTheme.Colors.barGradient(for: baseColor, dimmed: isDimmed))
                .cornerRadius(4)
            }
        }
        .chartXAxis {
            AxisMarks(values: .stride(by: .year)) { value in
                AxisGridLine(stroke: AppTheme.Layout.gridStroke)
                    .foregroundStyle(AppTheme.Colors.gridLine)
                AxisValueLabel(anchor: .top) {
                    if let date = value.as(Date.self) {
                        Text(date.formatted(.dateTime.year()))
                            .font(.system(size: 10, weight: .medium, design: .rounded))
                            .foregroundColor(.secondary)
                    }
                }
            }
        }
        .chartYAxis {
            AxisMarks(position: .trailing, values: .automatic(desiredCount: 4)) { value in
                AxisGridLine(stroke: AppTheme.Layout.gridStroke)
                    .foregroundStyle(AppTheme.Colors.gridLine)
                AxisValueLabel {
                    if let count = value.as(Int.self) {
                        Text(Self.formatCount(count))
                            .font(.system(size: 10, weight: .medium, design: .rounded))
                            .foregroundColor(.secondary)
                            .monospacedDigit()
                    }
                }
            }
        }
        .chartLegend(.hidden)
        .chartOverlay { proxy in
            DateChartScrubOverlay(
                proxy: proxy,
                onScrubDate: { date in
                    let nearest = index.nearestMonth(to: date)
                    if nearest != selectedMonth {
                        selectedMonth = nearest
                    }
                },
                onEnd: {
                    if selectedMonth != nil {
                        withAnimation(AppTheme.Animations.scrubRelease) {
                            selectedMonth = nil
                        }
                    }
                }
            )
        }
    }

    private func categoryPill(for type: String) -> some View {
        let color = AppTheme.Colors.syncCategoryColor(for: type)
        let isSoloed = (selectedCategory == type)
        let isDimmed = (selectedCategory != nil && !isSoloed)
        let monthCount = selectedMonth.flatMap { index.count(for: $0, category: type) }
        let shortName = (type == "Heart Rate") ? "Heart" : type

        return Button {
            withAnimation(AppTheme.Animations.collapse) {
                let nextCategory = isSoloed ? nil : type
                selectedCategory = nextCategory
                index = SyncHistoryIndex.build(from: syncData, selectedCategory: nextCategory)
            }
        } label: {
            VStack(spacing: 2) {
                HStack(spacing: 5) {
                    Circle()
                        .fill(color)
                        .frame(width: 7, height: 7)
                    Text(shortName)
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .foregroundColor(.primary)
                        .lineLimit(1)
                }

                if let monthCount {
                    Text(Self.formatCount(monthCount))
                        .font(.system(size: 10, weight: .medium, design: .rounded))
                        .foregroundColor(.secondary)
                        .monospacedDigit()
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: AppTheme.Layout.chipCornerRadius, style: .continuous)
                    .fill(isSoloed ? color.opacity(0.16) : AppTheme.Colors.insetSurface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: AppTheme.Layout.chipCornerRadius, style: .continuous)
                    .strokeBorder(isSoloed ? color.opacity(0.45) : AppTheme.Colors.cardBorder, lineWidth: 1)
            )
            .opacity(isDimmed ? 0.45 : 1.0)
        }
        .buttonStyle(.plain)
    }

    static func formatCount(_ count: Int) -> String {
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
        let generation = fetchGuard.beginNext()
        fetchTask = Task { @MainActor in
            await Task.yield()
            await fetchDashboardStats(generation: generation)
        }
    }

    @MainActor
    private func fetchDashboardStats(generation: Int) async {
        let apiKey = ServerResolver.loadApiKey()
        guard !apiKey.isEmpty,
              let serverURL = ServerResolver.resolve(
                  override: customServerURL,
                  discovered: serverDiscoveryManager.activeServerURL) else { return }
        let deviceId = UIDevice.current.identifierForVendor?.uuidString ?? ""

        do {
            let data = try await syncEngine.fetchStats(
                serverURL: serverURL,
                apiKey: apiKey,
                timeScale: "months",
                deviceId: deviceId,
                scope: "all"
            )
            guard !Task.isCancelled, fetchGuard.isCurrent(generation) else { return }

            let activeCategory = selectedCategory
            let decoded: ([SyncDataPoint], SyncHistoryIndex, Int?)? = await Task.detached(priority: .utility) {
                guard let response = try? JSONDecoder().decode(ServerStatsResponse.self, from: data) else {
                    return nil
                }
                let points = Self.buildPoints(from: response.stats)
                let builtIndex = SyncHistoryIndex.build(from: points, selectedCategory: activeCategory)
                return (points, builtIndex, response.totalRecords)
            }.value

            guard !Task.isCancelled, fetchGuard.isCurrent(generation),
                  let (newPoints, newIndex, reportedTotal) = decoded else {
                return
            }

            // Guard against an older server (pre-`scope=all`, omitting `total_records`) wiping
            // a valid cached chart when a reinstalled device reconnects with a new `device_id`.
            if newPoints.isEmpty && reportedTotal == nil && !syncData.isEmpty {
                return
            }

            let resolvedTotal = reportedTotal ?? newPoints.reduce(0) { $0 + $1.count }
            UserDefaults.standard.set(data, forKey: Self.cacheKey)
            applyUpdatedData(points: newPoints, index: newIndex, serverTotal: resolvedTotal, animated: true)
        } catch {
            if !(error is CancellationError) {
                print("Dashboard fetch failed: \(error)")
            }
        }
    }

    nonisolated private static func buildPoints(from serverStats: [ServerStat]) -> [SyncDataPoint] {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = TimeZone(secondsFromGMT: 0)

        var newPoints: [SyncDataPoint] = []
        newPoints.reserveCapacity(serverStats.count)
        for stat in serverStats {
            if let date = formatter.date(from: stat.date) {
                newPoints.append(SyncDataPoint(date: date, type: stat.type, count: stat.count))
            }
        }
        return newPoints
    }

    @MainActor
    private func applyUpdatedData(
        points: [SyncDataPoint],
        index newIndex: SyncHistoryIndex,
        serverTotal: Int,
        animated: Bool
    ) {
        guard points != syncData || serverTotal != serverTotalRecords else { return }
        // Rebuild index if selectedCategory changed while decoding off-actor.
        let finalIndex = (selectedCategory == nil && newIndex.visiblePoints.count == points.count)
            ? newIndex
            : SyncHistoryIndex.build(from: points, selectedCategory: selectedCategory)

        if animated && UIApplication.shared.applicationState == .active {
            withAnimation(AppTheme.Animations.chartUpdate) {
                syncData = points
                index = finalIndex
                serverTotalRecords = serverTotal
            }
        } else {
            syncData = points
            index = finalIndex
            serverTotalRecords = serverTotal
        }
    }
}
