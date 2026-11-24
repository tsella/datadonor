import SwiftUI
import Charts

struct EnergyDayBucket: Identifiable, Equatable, Sendable, Codable {
    var id: TimeInterval { date.timeIntervalSince1970 }
    /// Local start-of-day timestamp.
    let date: Date
    let basalKcal: Double
    let activeKcal: Double

    var tdeeKcal: Double {
        basalKcal + activeKcal
    }

    var midpoint: Date {
        date.addingTimeInterval(12 * 3600)
    }

    var basalShare: Double? {
        guard tdeeKcal > 0 else { return nil }
        return basalKcal / tdeeKcal
    }

    var activeShare: Double? {
        guard tdeeKcal > 0 else { return nil }
        return activeKcal / tdeeKcal
    }
}

struct Energy7dSummary: Equatable, Sendable, Codable {
    let days: [EnergyDayBucket]
    let today: EnergyDayBucket?
    let averageTDEE: Double?
    let averageBasal: Double?
    let averageActive: Double?
    let averagedDayCount: Int
    let hasAnyData: Bool
    /// Precomputed once off-MainActor so SwiftUI chart rendering does zero per-frame math.
    let xAxisDomain: ClosedRange<Date>
    let yAxisDomain: ClosedRange<Double>

    func nearestDay(to date: Date) -> EnergyDayBucket? {
        days.min { lhs, rhs in
            abs(lhs.midpoint.timeIntervalSince(date)) < abs(rhs.midpoint.timeIntervalSince(date))
        }
    }

    static func formatKcal(_ value: Double) -> String {
        Int(value.rounded()).formatted(.number)
    }

    static func build(
        dailyBasal: [Date: Double],
        dailyActive: [Date: Double],
        now: Date,
        calendar: Calendar = .current
    ) -> Energy7dSummary {
        let todayStart = calendar.startOfDay(for: now)

        var normalizedBasal: [Date: Double] = [:]
        for (date, value) in dailyBasal where value.isFinite && value > 0 {
            let day = calendar.startOfDay(for: date)
            normalizedBasal[day, default: 0] += value
        }

        var normalizedActive: [Date: Double] = [:]
        for (date, value) in dailyActive where value.isFinite && value > 0 {
            let day = calendar.startOfDay(for: date)
            normalizedActive[day, default: 0] += value
        }

        var days: [EnergyDayBucket] = []
        days.reserveCapacity(7)
        for offset in -6...0 {
            let dayDate = calendar.date(byAdding: .day, value: offset, to: todayStart)
                ?? todayStart.addingTimeInterval(Double(offset) * 86_400)
            let basal = max(0, normalizedBasal[dayDate] ?? 0)
            let active = max(0, normalizedActive[dayDate] ?? 0)
            days.append(EnergyDayBucket(date: dayDate, basalKcal: basal, activeKcal: active))
        }

        let todayBucket = days.last
        let hasAnyData = days.contains { $0.tdeeKcal > 0 }

        // Average prior completed days (excluding partial today) when available so morning
        // readings don't pull down the user's true full-day TDEE average.
        let priorCompleted = days.dropLast().filter { $0.tdeeKcal > 0 }
        let averageSample: [EnergyDayBucket]
        if !priorCompleted.isEmpty {
            averageSample = priorCompleted
        } else if let todayBucket, todayBucket.tdeeKcal > 0 {
            averageSample = [todayBucket]
        } else {
            averageSample = []
        }

        let avgTDEE: Double?
        let avgBasal: Double?
        let avgActive: Double?
        if !averageSample.isEmpty {
            let count = Double(averageSample.count)
            avgTDEE = averageSample.reduce(0) { $0 + $1.tdeeKcal } / count
            avgBasal = averageSample.reduce(0) { $0 + $1.basalKcal } / count
            avgActive = averageSample.reduce(0) { $0 + $1.activeKcal } / count
        } else {
            avgTDEE = nil
            avgBasal = nil
            avgActive = nil
        }

        let maxDaily = max(days.map(\.tdeeKcal).max() ?? 0, avgTDEE ?? 0)
        let yMax = max(1000, ceil((maxDaily * 1.14) / 500) * 500)
        let firstDay = days.first?.date ?? todayStart
        let dayAfterToday = calendar.date(byAdding: .day, value: 1, to: todayStart)
            ?? todayStart.addingTimeInterval(86_400)

        return Energy7dSummary(
            days: days,
            today: todayBucket,
            averageTDEE: avgTDEE,
            averageBasal: avgBasal,
            averageActive: avgActive,
            averagedDayCount: averageSample.count,
            hasAnyData: hasAnyData,
            xAxisDomain: firstDay...dayAfterToday,
            yAxisDomain: 0...yMax
        )
    }
}

struct EnergyCardView: View {
    let summary: Energy7dSummary?
    let isAuthorized: Bool
    let isLoading: Bool

    @AppStorage("cardCollapsed_energy") private var isCollapsed = false
    @State private var selectedDay: EnergyDayBucket?

    var body: some View {
        CollapsibleCard(isCollapsed: $isCollapsed, accessibilityTitle: "Energy") {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 7) {
                    Image(systemName: "flame.fill")
                        .font(.subheadline)
                        .foregroundColor(AppTheme.Colors.ochre)
                    Text("Energy")
                        .font(.system(.headline, design: .rounded))
                        .foregroundColor(.primary)
                }

                Text(subtitleText)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .monospacedDigit()
            }
        } headerTrailing: {
            if let day = displayDay, day.tdeeKcal > 0 {
                HStack(alignment: .firstTextBaseline, spacing: 3) {
                    Text(Energy7dSummary.formatKcal(day.tdeeKcal))
                        .font(.system(.title3, design: .rounded).weight(.bold))
                        .foregroundColor(AppTheme.Colors.ochre)
                        .monospacedDigit()
                        .contentTransition(.numericText())
                    Text("kcal")
                        .font(.caption.weight(.medium))
                        .foregroundColor(.secondary)
                }
                .padding(.top, 1)
                .animation(AppTheme.Animations.readoutUpdate, value: day.id)
            }
        } content: {
            if !isAuthorized {
                Text("Grant Health access to view your daily TDEE, basal, and active energy.")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .padding(.vertical, 8)
            } else {
                HStack(spacing: 12) {
                    MetricIndicatorTile(
                        title: "Basal",
                        icon: "bolt.heart.fill",
                        tint: AppTheme.Colors.slateTeal,
                        value: basalValueText,
                        unit: basalValueText == "—" ? "" : "kcal",
                        caption: basalCaptionText
                    )

                    MetricIndicatorTile(
                        title: "Active",
                        icon: "flame.fill",
                        tint: AppTheme.Colors.ochre,
                        value: activeValueText,
                        unit: activeValueText == "—" ? "" : "kcal",
                        caption: activeCaptionText
                    )
                }
                .animation(AppTheme.Animations.readoutUpdate, value: displayDay?.id)

                if let summary, summary.hasAnyData {
                    energyChart(summary)
                        .frame(height: 185)

                    HStack(spacing: 12) {
                        legendChip(color: AppTheme.Colors.slateTeal, label: "Basal", isDashed: false)
                        legendChip(color: AppTheme.Colors.ochre, label: "Active", isDashed: false)
                        if summary.averageTDEE != nil {
                            legendChip(color: AppTheme.Colors.coral, label: "Avg", isDashed: true)
                        }
                        Spacer(minLength: 4)
                        Text(selectedDay == nil ? "Hold & drag" : "TDEE")
                            .font(.caption2)
                            .foregroundColor(.secondary.opacity(0.85))
                            .lineLimit(1)
                    }
                    .padding(.top, 2)
                } else if isLoading {
                    HStack {
                        Spacer()
                        ProgressView()
                            .padding(.vertical, 48)
                        Spacer()
                    }
                } else {
                    Text("No basal or active energy recorded in the last 7 days.")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.vertical, 36)
                }
            }
        }
    }

    private var displayDay: EnergyDayBucket? {
        selectedDay ?? summary?.today
    }

    private var basalValueText: String {
        guard let day = displayDay, day.tdeeKcal > 0 else { return "—" }
        return Energy7dSummary.formatKcal(day.basalKcal)
    }

    private var activeValueText: String {
        guard let day = displayDay, day.tdeeKcal > 0 else { return "—" }
        return Energy7dSummary.formatKcal(day.activeKcal)
    }

    private var basalCaptionText: String {
        if let share = displayDay?.basalShare {
            return "\(Int((share * 100).rounded()))%"
        }
        return "Resting"
    }

    private var activeCaptionText: String {
        if let share = displayDay?.activeShare {
            return "\(Int((share * 100).rounded()))%"
        }
        return "Burn"
    }

    private var subtitleText: String {
        if let selected = selectedDay {
            let isToday = (selected.id == summary?.today?.id)
            let dayLabel = isToday
                ? "Today"
                : selected.date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
            return "\(dayLabel) · TDEE"
        }
        if let avg = summary?.averageTDEE, let count = summary?.averagedDayCount, count > 0 {
            return "Today's TDEE · \(count)d avg \(Energy7dSummary.formatKcal(avg)) kcal"
        }
        return "TDEE · Basal + Active"
    }

    private func legendChip(color: Color, label: String, isDashed: Bool) -> some View {
        HStack(spacing: 6) {
            if isDashed {
                HStack(spacing: 2) {
                    Capsule().fill(color).frame(width: 5, height: 2)
                    Capsule().fill(color).frame(width: 5, height: 2)
                }
            } else {
                Circle()
                    .fill(color)
                    .frame(width: 7, height: 7)
            }
            Text(label)
                .font(.caption2.weight(.medium))
                .foregroundColor(.secondary)
        }
    }

    private func energyChart(_ data: Energy7dSummary) -> some View {
        let todayDate = data.today?.date

        return Chart {
            ForEach(data.days) { day in
                let isDimmed = selectedDay != nil && selectedDay?.id != day.id

                if day.basalKcal > 0 {
                    BarMark(
                        x: .value("Day", day.date, unit: .day),
                        yStart: .value("Floor", 0),
                        yEnd: .value("Basal", day.basalKcal),
                        width: .ratio(0.56)
                    )
                    .foregroundStyle(AppTheme.Colors.barGradient(for: AppTheme.Colors.slateTeal, dimmed: isDimmed))
                    .cornerRadius(day.activeKcal > 0 ? 3 : 6)
                }

                if day.activeKcal > 0 {
                    BarMark(
                        x: .value("Day", day.date, unit: .day),
                        yStart: .value("Basal", day.basalKcal),
                        yEnd: .value("TDEE", day.tdeeKcal),
                        width: .ratio(0.56)
                    )
                    .foregroundStyle(AppTheme.Colors.barGradient(for: AppTheme.Colors.ochre, dimmed: isDimmed))
                    .cornerRadius(6)
                }
            }

            if let avg = data.averageTDEE, avg > 0 {
                RuleMark(y: .value("Avg TDEE", avg))
                    .foregroundStyle(AppTheme.Colors.coral.opacity(0.75))
                    .lineStyle(StrokeStyle(lineWidth: 1.25, dash: [4, 4]))
                    .annotation(position: .top, alignment: .leading, spacing: 3) {
                        Text("Avg \(Energy7dSummary.formatKcal(avg))")
                            .font(.system(size: 10, weight: .semibold, design: .rounded))
                            .foregroundColor(AppTheme.Colors.coral)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(
                                Capsule()
                                    .fill(AppTheme.Colors.cardSurface.opacity(0.92))
                            )
                            .overlay(
                                Capsule()
                                    .strokeBorder(AppTheme.Colors.coral.opacity(0.28), lineWidth: 0.75)
                            )
                    }
            }

            if let selected = selectedDay {
                RuleMark(x: .value("Selected", selected.midpoint))
                    .foregroundStyle(AppTheme.Colors.ochre.opacity(0.35))
                    .lineStyle(StrokeStyle(lineWidth: 1.25))
            }
        }
        .chartXScale(domain: data.xAxisDomain)
        .chartYScale(domain: data.yAxisDomain)
        .chartXAxis {
            AxisMarks(values: data.days.map(\.date)) { value in
                AxisValueLabel(centered: true) {
                    if let date = value.as(Date.self) {
                        let isToday = todayDate.map { Calendar.current.isDate(date, inSameDayAs: $0) } ?? false
                        Text(isToday ? "Today" : date.formatted(.dateTime.weekday(.abbreviated)))
                            .font(.system(size: 10, weight: isToday ? .semibold : .medium, design: .rounded))
                            .foregroundColor(isToday ? .primary : .secondary)
                    }
                }
            }
        }
        .chartYAxis {
            AxisMarks(position: .trailing, values: .automatic(desiredCount: 4)) { value in
                AxisGridLine(stroke: AppTheme.Layout.gridStroke)
                    .foregroundStyle(AppTheme.Colors.gridLine)
                AxisValueLabel {
                    if let kcal = value.as(Double.self) {
                        Text(Energy7dSummary.formatKcal(kcal))
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
                    let nearest = data.nearestDay(to: date)
                    if nearest != selectedDay {
                        selectedDay = nearest
                    }
                },
                onEnd: {
                    if selectedDay != nil {
                        withAnimation(AppTheme.Animations.scrubRelease) {
                            selectedDay = nil
                        }
                    }
                }
            )
        }
        .disableChartAxisAnimations()
    }
}
