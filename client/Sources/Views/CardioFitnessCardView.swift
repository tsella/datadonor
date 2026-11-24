import SwiftUI
import Charts

enum CardioMetricKind: String, CaseIterable, Identifiable, Equatable, Sendable, Codable {
    case vo2Max
    case heartRateRecovery
    case walkingHeartRate

    var id: String { rawValue }

    var title: String {
        switch self {
        case .vo2Max: return "VO₂ Max"
        case .heartRateRecovery: return "1m HRR"
        case .walkingHeartRate: return "Walk HR"
        }
    }

    var fullTitle: String {
        switch self {
        case .vo2Max: return "VO₂ Max"
        case .heartRateRecovery: return "1-Min HR Recovery"
        case .walkingHeartRate: return "Walking Heart Rate"
        }
    }

    var unit: String {
        switch self {
        case .vo2Max: return "mL/kg·min"
        case .heartRateRecovery: return "bpm"
        case .walkingHeartRate: return "bpm"
        }
    }

    var shortUnit: String {
        switch self {
        case .vo2Max: return "mL/kg"
        case .heartRateRecovery: return "bpm"
        case .walkingHeartRate: return "bpm"
        }
    }

    var icon: String {
        switch self {
        case .vo2Max: return "lungs.fill"
        case .heartRateRecovery: return "arrow.down.heart.fill"
        case .walkingHeartRate: return "figure.walk"
        }
    }

    var tint: Color {
        switch self {
        case .vo2Max: return AppTheme.Colors.emerald
        case .heartRateRecovery: return AppTheme.Colors.teal
        case .walkingHeartRate: return AppTheme.Colors.coral
        }
    }

    /// True when an upward 30-day trend represents improving cardiovascular fitness.
    var higherIsBetter: Bool {
        switch self {
        case .vo2Max, .heartRateRecovery: return true
        case .walkingHeartRate: return false
        }
    }

    func formatValue(_ value: Double) -> String {
        switch self {
        case .vo2Max:
            return String(format: "%.1f", value)
        case .heartRateRecovery, .walkingHeartRate:
            return "\(Int(value.rounded()))"
        }
    }

    func formatDelta(_ delta: Double) -> String {
        switch self {
        case .vo2Max:
            let rounded = (delta * 10).rounded() / 10
            if rounded == 0 { return "0.0" }
            return String(format: "%@%.1f", rounded > 0 ? "+" : "", rounded)
        case .heartRateRecovery, .walkingHeartRate:
            let rounded = Int(delta.rounded())
            if rounded == 0 { return "0" }
            return "\(rounded > 0 ? "+" : "")\(rounded)"
        }
    }
}

struct CardioMetricPoint: Identifiable, Equatable, Sendable, Codable {
    var id: TimeInterval { date.timeIntervalSince1970 }
    /// Local calendar day midpoint (noon) so daily points plot cleanly on a 30-day axis.
    let date: Date
    let value: Double
    let sampleCount: Int
}

struct CardioSeriesSummary: Equatable, Sendable, Codable {
    let points: [CardioMetricPoint]
    let latest: Double?
    let average: Double?
    let delta: Double?
    /// Precomputed once off-MainActor so SwiftUI chart rendering does zero per-frame math.
    let yAxisDomain: ClosedRange<Double>

    var isEmpty: Bool { points.isEmpty }

    func nearestPoint(to date: Date) -> CardioMetricPoint? {
        guard !points.isEmpty else { return nil }
        var low = 0
        var high = points.count - 1
        while low < high {
            let mid = (low + high) / 2
            if points[mid].date < date {
                low = mid + 1
            } else {
                high = mid
            }
        }
        if low == 0 { return points[0] }
        let before = points[low - 1]
        let after = points[low]
        return abs(before.date.timeIntervalSince(date)) <= abs(after.date.timeIntervalSince(date)) ? before : after
    }

    static func build(
        samples: [TimedQuantitySample],
        windowStart: Date,
        windowEnd: Date,
        stepPadding: Double,
        defaultRange: ClosedRange<Double>,
        calendar: Calendar = .current
    ) -> CardioSeriesSummary {
        var byDay: [Date: [Double]] = [:]
        for sample in samples where sample.value.isFinite && sample.date >= windowStart && sample.date <= windowEnd && sample.value > 0 {
            let day = calendar.startOfDay(for: sample.date)
            byDay[day, default: []].append(sample.value)
        }

        let sortedDays = byDay.keys.sorted()
        var points: [CardioMetricPoint] = []
        points.reserveCapacity(sortedDays.count)

        for day in sortedDays {
            guard let values = byDay[day], !values.isEmpty else { continue }
            let avg = values.reduce(0, +) / Double(values.count)
            // Anchor at noon, clamped within the 30-day window so early-morning samples never
            // plot outside `windowStart...windowEnd`.
            let rawPointDate = day.addingTimeInterval(12 * 3600)
            let pointDate = min(windowEnd, max(windowStart, rawPointDate))
            points.append(CardioMetricPoint(date: pointDate, value: avg, sampleCount: values.count))
        }

        let latest = points.last?.value
        let average: Double? = points.isEmpty
            ? nil
            : (points.reduce(0) { $0 + $1.value } / Double(points.count))
        let delta: Double? = points.count >= 2
            ? (points.last!.value - points.first!.value)
            : nil

        let domain: ClosedRange<Double>
        if let lo = points.map(\.value).min(), let hi = points.map(\.value).max() {
            let low = max(0, floor((lo - stepPadding) / stepPadding) * stepPadding)
            let high = max(low + stepPadding * 2, ceil((hi + stepPadding) / stepPadding) * stepPadding)
            domain = low...high
        } else {
            domain = defaultRange
        }

        return CardioSeriesSummary(
            points: points,
            latest: latest,
            average: average,
            delta: delta,
            yAxisDomain: domain
        )
    }
}

struct CardioFitness30dSummary: Equatable, Sendable, Codable {
    let windowStart: Date
    let windowEnd: Date
    let vo2Max: CardioSeriesSummary
    let heartRateRecovery: CardioSeriesSummary
    let walkingHeartRate: CardioSeriesSummary

    var hasAnyData: Bool {
        !vo2Max.isEmpty || !heartRateRecovery.isEmpty || !walkingHeartRate.isEmpty
    }

    var preferredMetric: CardioMetricKind {
        if !vo2Max.isEmpty { return .vo2Max }
        if !heartRateRecovery.isEmpty { return .heartRateRecovery }
        if !walkingHeartRate.isEmpty { return .walkingHeartRate }
        return .vo2Max
    }

    func series(for metric: CardioMetricKind) -> CardioSeriesSummary {
        switch metric {
        case .vo2Max: return vo2Max
        case .heartRateRecovery: return heartRateRecovery
        case .walkingHeartRate: return walkingHeartRate
        }
    }

    static func build(
        vo2Max30d: [TimedQuantitySample],
        heartRateRecovery30d: [TimedQuantitySample],
        walkingHeartRate30d: [TimedQuantitySample],
        windowEnd: Date,
        calendar: Calendar = .current
    ) -> CardioFitness30dSummary {
        let windowStart = windowEnd.addingTimeInterval(-30 * 24 * 60 * 60)

        let vo2 = CardioSeriesSummary.build(
            samples: vo2Max30d,
            windowStart: windowStart,
            windowEnd: windowEnd,
            stepPadding: 4,
            defaultRange: 25...60,
            calendar: calendar
        )
        let hrr = CardioSeriesSummary.build(
            samples: heartRateRecovery30d,
            windowStart: windowStart,
            windowEnd: windowEnd,
            stepPadding: 5,
            defaultRange: 10...55,
            calendar: calendar
        )
        let walkingHR = CardioSeriesSummary.build(
            samples: walkingHeartRate30d,
            windowStart: windowStart,
            windowEnd: windowEnd,
            stepPadding: 5,
            defaultRange: 70...120,
            calendar: calendar
        )

        return CardioFitness30dSummary(
            windowStart: windowStart,
            windowEnd: windowEnd,
            vo2Max: vo2,
            heartRateRecovery: hrr,
            walkingHeartRate: walkingHR
        )
    }
}

struct CardioFitnessCardView: View {
    let summary: CardioFitness30dSummary?
    let isAuthorized: Bool
    let isLoading: Bool

    @AppStorage("cardCollapsed_cardioFitness") private var isCollapsed = false
    @State private var selectedMetric: CardioMetricKind?
    @State private var selectedPoint: CardioMetricPoint?

    var body: some View {
        let metric = activeMetric
        let activeSeries = summary?.series(for: metric)

        CollapsibleCard(isCollapsed: $isCollapsed, accessibilityTitle: "Cardio Fitness") {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 7) {
                    Image(systemName: "lungs.fill")
                        .font(.subheadline)
                        .foregroundColor(AppTheme.Colors.emerald)
                    Text("Cardio Fitness")
                        .font(.system(.headline, design: .rounded))
                        .foregroundColor(.primary)
                }

                Text(subtitleText(metric: metric, series: activeSeries))
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .monospacedDigit()
            }
        } headerTrailing: {
            if let value = selectedPoint?.value ?? activeSeries?.latest {
                HStack(alignment: .firstTextBaseline, spacing: 3) {
                    Text(metric.formatValue(value))
                        .font(.system(.title3, design: .rounded).weight(.bold))
                        .foregroundColor(metric.tint)
                        .monospacedDigit()
                        .contentTransition(.numericText())
                    Text(metric.shortUnit)
                        .font(.caption.weight(.medium))
                        .foregroundColor(.secondary)
                }
                .padding(.top, 1)
                .animation(AppTheme.Animations.readoutUpdate, value: value)
            }
        } content: {
            if !isAuthorized {
                Text("Grant Health access to track your 30-day VO₂ Max, 1-minute HR recovery, and walking heart rate.")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .padding(.vertical, 8)
            } else {
                HStack(spacing: 8) {
                    ForEach(CardioMetricKind.allCases) { kind in
                        metricSelectorTile(kind: kind, isSelected: kind == metric)
                    }
                }

                if let summary, let activeSeries, !activeSeries.isEmpty {
                    trendChart(summary: summary, metric: metric, series: activeSeries)
                        .frame(height: 185)

                    HStack(spacing: 12) {
                        legendChip(color: metric.tint, label: metric.title, isDashed: false)
                        if activeSeries.average != nil {
                            legendChip(color: AppTheme.Colors.slateTeal, label: "30d avg", isDashed: true)
                        }
                        Spacer(minLength: 4)
                        Text(selectedPoint == nil ? "Hold & drag" : sampleCountLabel)
                            .font(.caption2)
                            .foregroundColor(.secondary.opacity(0.85))
                            .monospacedDigit()
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
                } else if summary?.hasAnyData == true {
                    Text("No \(metric.fullTitle) readings recorded in the last 30 days.")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.vertical, 36)
                } else {
                    Text("No VO₂ Max, HR recovery, or walking HR recorded in the last 30 days.")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.vertical, 36)
                }
            }
        }
    }

    private var activeMetric: CardioMetricKind {
        if let selectedMetric {
            return selectedMetric
        }
        return summary?.preferredMetric ?? .vo2Max
    }

    private var sampleCountLabel: String {
        guard let pt = selectedPoint else { return "" }
        return "\(pt.sampleCount) reading\(pt.sampleCount == 1 ? "" : "s")"
    }

    private func subtitleText(metric: CardioMetricKind, series: CardioSeriesSummary?) -> String {
        if let point = selectedPoint {
            let day = point.date.formatted(.dateTime.month(.abbreviated).day())
            return "\(day) · \(metric.fullTitle)"
        }
        if let delta = series?.delta {
            return "\(metric.fullTitle) · \(metric.formatDelta(delta)) over 30d"
        }
        if let avg = series?.average {
            return "\(metric.fullTitle) · 30d avg \(metric.formatValue(avg))"
        }
        return "30-day recovery & fitness trend"
    }

    private func metricSelectorTile(kind: CardioMetricKind, isSelected: Bool) -> some View {
        let series = summary?.series(for: kind)
        let valueText = series?.latest.map { kind.formatValue($0) } ?? "—"

        let captionText: String
        let captionColor: Color
        if let delta = series?.delta {
            captionText = "\(kind.formatDelta(delta)) 30d"
            let improved = kind.higherIsBetter ? (delta > 0.05) : (delta < -0.5)
            let declined = kind.higherIsBetter ? (delta < -0.05) : (delta > 0.5)
            if improved {
                captionColor = AppTheme.Colors.emerald
            } else if declined {
                captionColor = AppTheme.Colors.coral
            } else {
                captionColor = .secondary
            }
        } else if series?.latest != nil {
            captionText = kind.shortUnit
            captionColor = .secondary
        } else {
            captionText = "No data"
            captionColor = .secondary
        }

        return Button {
            withAnimation(AppTheme.Animations.chartUpdate) {
                selectedMetric = kind
                selectedPoint = nil
            }
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 4) {
                    Image(systemName: kind.icon)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(kind.tint)
                    Text(kind.title)
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .foregroundColor(.primary.opacity(0.85))
                        .lineLimit(1)
                }

                Text(valueText)
                    .font(.system(.headline, design: .rounded).weight(.bold))
                    .foregroundColor(.primary)
                    .monospacedDigit()
                    .contentTransition(.numericText())
                    .lineLimit(1)

                Text(captionText)
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .foregroundColor(captionColor)
                    .monospacedDigit()
                    .lineLimit(1)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: AppTheme.Layout.insetCornerRadius, style: .continuous)
                    .fill(isSelected ? kind.tint.opacity(0.14) : AppTheme.Colors.insetSurface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: AppTheme.Layout.insetCornerRadius, style: .continuous)
                    .strokeBorder(
                        isSelected ? kind.tint.opacity(0.50) : AppTheme.Colors.cardBorder,
                        lineWidth: isSelected ? 1.25 : 1
                    )
            )
        }
        .buttonStyle(.plain)
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

    private func trendChart(
        summary: CardioFitness30dSummary,
        metric: CardioMetricKind,
        series: CardioSeriesSummary
    ) -> some View {
        let yFloor = series.yAxisDomain.lowerBound
        let latestPoint = series.points.last

        return Chart {
            if series.points.count >= 2 {
                ForEach(series.points) { point in
                    AreaMark(
                        x: .value("Date", point.date),
                        yStart: .value("Floor", yFloor),
                        yEnd: .value(metric.title, point.value)
                    )
                    .interpolationMethod(.catmullRom)
                    .foregroundStyle(AppTheme.Colors.trendAreaGradient(for: metric.tint))
                }
            }

            if let avg = series.average {
                RuleMark(y: .value("30d Avg", avg))
                    .foregroundStyle(AppTheme.Colors.slateTeal.opacity(0.75))
                    .lineStyle(StrokeStyle(lineWidth: 1.25, dash: [4, 4]))
                    .annotation(position: .top, alignment: .leading, spacing: 3) {
                        Text("Avg \(metric.formatValue(avg))")
                            .font(.system(size: 10, weight: .semibold, design: .rounded))
                            .foregroundColor(AppTheme.Colors.slateTeal)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(
                                Capsule()
                                    .fill(AppTheme.Colors.cardSurface.opacity(0.92))
                            )
                            .overlay(
                                Capsule()
                                    .strokeBorder(AppTheme.Colors.slateTeal.opacity(0.28), lineWidth: 0.75)
                            )
                    }
            }

            if series.points.count >= 2 {
                ForEach(series.points) { point in
                    LineMark(
                        x: .value("Date", point.date),
                        y: .value(metric.title, point.value)
                    )
                    .foregroundStyle(metric.tint)
                    .lineStyle(StrokeStyle(lineWidth: 2.3, lineCap: .round, lineJoin: .round))
                    .interpolationMethod(.catmullRom)
                }
            }

            ForEach(series.points) { point in
                let isSelected = (selectedPoint?.id == point.id)
                let isLatest = (selectedPoint == nil && latestPoint?.id == point.id)

                if isLatest {
                    PointMark(
                        x: .value("Date", point.date),
                        y: .value(metric.title, point.value)
                    )
                    .foregroundStyle(metric.tint.opacity(0.22))
                    .symbolSize(130)
                }

                PointMark(
                    x: .value("Date", point.date),
                    y: .value(metric.title, point.value)
                )
                .foregroundStyle(isSelected ? AppTheme.Colors.cardSurface : metric.tint)
                .symbolSize(isSelected ? 80 : (isLatest ? 38 : 22))

                if isSelected {
                    PointMark(
                        x: .value("Date", point.date),
                        y: .value(metric.title, point.value)
                    )
                    .foregroundStyle(metric.tint)
                    .symbolSize(40)
                }
            }

            if let selected = selectedPoint {
                RuleMark(x: .value("Selected", selected.date))
                    .foregroundStyle(metric.tint.opacity(0.40))
                    .lineStyle(StrokeStyle(lineWidth: 1.25))
            }
        }
        .chartXScale(domain: summary.windowStart...summary.windowEnd)
        .chartYScale(domain: series.yAxisDomain)
        .chartXAxis {
            AxisMarks(values: .stride(by: .day, count: 7)) { value in
                AxisGridLine(stroke: AppTheme.Layout.gridStroke)
                    .foregroundStyle(AppTheme.Colors.gridLine)
                AxisValueLabel(anchor: .top) {
                    if let date = value.as(Date.self) {
                        Text(date.formatted(.dateTime.month(.abbreviated).day()))
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
                    if let val = value.as(Double.self) {
                        Text(metric.formatValue(val))
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
                    let nearest = series.nearestPoint(to: date)
                    if nearest != selectedPoint {
                        selectedPoint = nearest
                    }
                },
                onEnd: {
                    if selectedPoint != nil {
                        withAnimation(AppTheme.Animations.scrubRelease) {
                            selectedPoint = nil
                        }
                    }
                }
            )
        }
        .disableChartAxisAnimations()
    }
}
