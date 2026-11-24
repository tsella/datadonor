import SwiftUI
import Charts

enum OvernightVitalKind: String, CaseIterable, Identifiable, Equatable, Sendable, Codable {
    case wristTemp
    case respiratoryRate
    case bloodOxygen
    case breathingDisturbances

    var id: String { rawValue }

    var title: String {
        switch self {
        case .wristTemp: return "Wrist Temp"
        case .respiratoryRate: return "Resp Rate"
        case .bloodOxygen: return "SpO₂"
        case .breathingDisturbances: return "Breathing"
        }
    }

    var fullTitle: String {
        switch self {
        case .wristTemp: return "Sleeping Wrist Temp"
        case .respiratoryRate: return "Respiratory Rate"
        case .bloodOxygen: return "Blood Oxygen (SpO₂)"
        case .breathingDisturbances: return "Breathing Disturbances"
        }
    }

    var shortUnit: String {
        switch self {
        case .wristTemp: return "°C"
        case .respiratoryRate: return "br/m"
        case .bloodOxygen: return "%"
        case .breathingDisturbances: return "/hr"
        }
    }

    var icon: String {
        switch self {
        case .wristTemp: return "thermometer.medium"
        case .respiratoryRate: return "wind"
        case .bloodOxygen: return "drop.fill"
        case .breathingDisturbances: return "lungs.fill"
        }
    }

    var tint: Color {
        switch self {
        case .wristTemp: return AppTheme.Colors.ochre
        case .respiratoryRate: return AppTheme.Colors.sleepCore
        case .bloodOxygen: return AppTheme.Colors.teal
        case .breathingDisturbances: return AppTheme.Colors.sleepDeep
        }
    }

    func formatValue(_ value: Double) -> String {
        switch self {
        case .wristTemp:
            let rounded = (value * 10).rounded() / 10
            if rounded == 0 { return "0.0°C" }
            return String(format: "%@%.1f°C", rounded > 0 ? "+" : "", rounded)
        case .respiratoryRate:
            return String(format: "%.1f", value)
        case .bloodOxygen:
            return "\(Int(value.rounded()))%"
        case .breathingDisturbances:
            return String(format: "%.1f", value)
        }
    }

    func formatAxisValue(_ value: Double) -> String {
        switch self {
        case .wristTemp:
            let rounded = (value * 10).rounded() / 10
            if rounded == 0 { return "0°" }
            return String(format: "%@%.1f°", rounded > 0 ? "+" : "", rounded)
        case .respiratoryRate:
            return "\(Int(value.rounded()))"
        case .bloodOxygen:
            return "\(Int(value.rounded()))%"
        case .breathingDisturbances:
            return "\(Int(value.rounded()))"
        }
    }
}

enum OvernightOutlierState: String, Equatable, Sendable, Codable {
    case typical
    case high
    case low

    var isOutlier: Bool { self != .typical }
}

enum OvernightWatchStatus: String, Equatable, Sendable, Codable {
    case typical
    case watch
    case elevated
    case noData

    var color: Color {
        switch self {
        case .typical: return AppTheme.Colors.emerald
        case .watch: return AppTheme.Colors.ochre
        case .elevated: return AppTheme.Colors.coral
        case .noData: return .secondary
        }
    }

    var symbolName: String {
        switch self {
        case .typical: return "checkmark.shield.fill"
        case .watch: return "exclamationmark.triangle.fill"
        case .elevated: return "exclamationmark.shield.fill"
        case .noData: return "moon.stars.fill"
        }
    }
}

struct OvernightVitalPoint: Identifiable, Equatable, Sendable, Codable {
    var id: TimeInterval { date.timeIntervalSince1970 }
    /// Local calendar day start.
    let date: Date
    let value: Double
    let outlierState: OvernightOutlierState

    var midpoint: Date {
        date.addingTimeInterval(12 * 3600)
    }
}

struct OvernightVitalSeries: Equatable, Sendable, Codable {
    let kind: OvernightVitalKind
    let points: [OvernightVitalPoint]
    let latest: OvernightVitalPoint?
    let baseline: Double?
    let typicalRange: ClosedRange<Double>?
    let yAxisDomain: ClosedRange<Double>

    var isEmpty: Bool { points.isEmpty }
    var isLatestOutlier: Bool { latest?.outlierState.isOutlier ?? false }
    var hasAnyOutlier: Bool { points.contains { $0.outlierState.isOutlier } }

    func nearestPoint(to date: Date) -> OvernightVitalPoint? {
        points.min { lhs, rhs in
            abs(lhs.midpoint.timeIntervalSince(date)) < abs(rhs.midpoint.timeIntervalSince(date))
        }
    }

    var statusCaption: String {
        guard let latest else { return "No data" }
        switch latest.outlierState {
        case .typical:
            return "Typical"
        case .high:
            return "Above avg"
        case .low:
            return "Below avg"
        }
    }
}

struct OvernightVitals7dSummary: Equatable, Sendable, Codable {
    let dayStarts: [Date]
    let xAxisDomain: ClosedRange<Date>
    let wristTemp: OvernightVitalSeries
    let respiratoryRate: OvernightVitalSeries
    let bloodOxygen: OvernightVitalSeries
    let breathingDisturbances: OvernightVitalSeries
    let watchStatus: OvernightWatchStatus
    let latestOutlierCount: Int
    let availableChannelCount: Int
    let insight: String

    var hasAnyData: Bool { availableChannelCount > 0 }

    /// Core 3 channels always shown; includes Breathing Disturbances (iOS 18+) when data exists.
    var displayKinds: [OvernightVitalKind] {
        var kinds: [OvernightVitalKind] = [.wristTemp, .respiratoryRate, .bloodOxygen]
        if !breathingDisturbances.isEmpty {
            kinds.append(.breathingDisturbances)
        }
        return kinds
    }

    var preferredKind: OvernightVitalKind {
        // Prioritize any channel currently showing an outlier so the user sees it immediately.
        for kind in displayKinds where series(for: kind).isLatestOutlier {
            return kind
        }
        for kind in displayKinds where !series(for: kind).isEmpty {
            return kind
        }
        return .wristTemp
    }

    func series(for kind: OvernightVitalKind) -> OvernightVitalSeries {
        switch kind {
        case .wristTemp: return wristTemp
        case .respiratoryRate: return respiratoryRate
        case .bloodOxygen: return bloodOxygen
        case .breathingDisturbances: return breathingDisturbances
        }
    }

    var badgeText: String {
        switch watchStatus {
        case .typical:
            return "Typical"
        case .watch:
            return "1 Outlier"
        case .elevated:
            return "\(latestOutlierCount) Outliers"
        case .noData:
            return "No Data"
        }
    }

    static func build(
        wristTemp14d: [TimedQuantitySample],
        respiratoryRate14d: [TimedQuantitySample],
        bloodOxygen14d: [TimedQuantitySample],
        breathingDisturbances14d: [TimedQuantitySample] = [],
        now: Date,
        calendar: Calendar = .current
    ) -> OvernightVitals7dSummary {
        let todayStart = calendar.startOfDay(for: now)
        let dayStarts: [Date] = (-6...0).map { offset in
            calendar.date(byAdding: .day, value: offset, to: todayStart)
                ?? todayStart.addingTimeInterval(Double(offset) * 86_400)
        }
        let firstDay = dayStarts.first ?? todayStart
        let dayAfterToday = calendar.date(byAdding: .day, value: 1, to: todayStart)
            ?? todayStart.addingTimeInterval(86_400)
        let xDomain = firstDay...dayAfterToday

        let start14d = calendar.date(byAdding: .day, value: -13, to: todayStart)
            ?? todayStart.addingTimeInterval(-13 * 86_400)

        let tempSeries = buildWristTempSeries(
            samples: wristTemp14d,
            start14d: start14d,
            firstDay7d: firstDay,
            now: now,
            calendar: calendar
        )

        let respSeries = buildAbsoluteSeries(
            kind: .respiratoryRate,
            samples: respiratoryRate14d,
            start14d: start14d,
            firstDay7d: firstDay,
            now: now,
            calendar: calendar,
            normalHalfWidth: 1.5,
            highOutlierDelta: 1.8,
            lowOutlierDelta: 2.2,
            absoluteHighFloor: 21.0,
            absoluteLowCeiling: 9.0,
            minDomainSpan: 6.0,
            clampMin: 6.0,
            clampMax: 35.0
        )

        let normalizedSpO2 = bloodOxygen14d.map { sample in
            let pct = sample.value <= 1.0 ? sample.value * 100.0 : sample.value
            return TimedQuantitySample(date: sample.date, value: pct)
        }
        let spo2Series = buildAbsoluteSeries(
            kind: .bloodOxygen,
            samples: normalizedSpO2,
            start14d: start14d,
            firstDay7d: firstDay,
            now: now,
            calendar: calendar,
            normalHalfWidth: 1.5,
            highOutlierDelta: nil, // higher SpO2 is never an illness warning
            lowOutlierDelta: 2.2,
            absoluteHighFloor: nil,
            absoluteLowCeiling: 94.0,
            minDomainSpan: 6.0,
            clampMin: 85.0,
            clampMax: 100.0
        )

        let breathingSeries = buildAbsoluteSeries(
            kind: .breathingDisturbances,
            samples: breathingDisturbances14d,
            start14d: start14d,
            firstDay7d: firstDay,
            now: now,
            calendar: calendar,
            normalHalfWidth: 2.0,
            highOutlierDelta: 2.5,
            lowOutlierDelta: nil,
            absoluteHighFloor: 10.0,
            absoluteLowCeiling: nil,
            minDomainSpan: 8.0,
            clampMin: 0.0,
            clampMax: 60.0
        )

        let allSeries = [tempSeries, respSeries, spo2Series, breathingSeries]
        let available = allSeries.filter { !$0.isEmpty }
        let outliers = available.filter { $0.isLatestOutlier }

        let status: OvernightWatchStatus
        let insight: String
        if available.isEmpty {
            status = .noData
            insight = "Wear Apple Watch during sleep to track 7-day overnight baselines."
        } else if outliers.isEmpty {
            status = .typical
            insight = available.count == 1
                ? "\(available[0].kind.title) is within your typical baseline."
                : "All \(available.count) overnight vitals are within your typical baseline."
        } else if outliers.count == 1 {
            status = .watch
            let s = outliers[0]
            let direction = s.latest?.outlierState == .high ? "above" : "below"
            insight = "\(s.kind.title) is \(direction) baseline — keep an eye on recovery."
        } else {
            status = .elevated
            let names = outliers.prefix(2).map(\.kind.title).joined(separator: " and ")
            insight = "\(names) diverged from baseline — consider extra rest."
        }

        return OvernightVitals7dSummary(
            dayStarts: dayStarts,
            xAxisDomain: xDomain,
            wristTemp: tempSeries,
            respiratoryRate: respSeries,
            bloodOxygen: spo2Series,
            breathingDisturbances: breathingSeries,
            watchStatus: status,
            latestOutlierCount: outliers.count,
            availableChannelCount: available.count,
            insight: insight
        )
    }

    // MARK: - Series Builders

    private static func groupDailyAverages(
        samples: [TimedQuantitySample],
        from start: Date,
        to end: Date,
        calendar: Calendar
    ) -> [(day: Date, value: Double)] {
        var buckets: [Date: [Double]] = [:]
        for sample in samples where sample.value.isFinite && sample.date >= start && sample.date <= end && sample.value > 0 {
            let day = calendar.startOfDay(for: sample.date)
            buckets[day, default: []].append(sample.value)
        }
        return buckets.keys.sorted().compactMap { day in
            guard let vals = buckets[day], !vals.isEmpty else { return nil }
            return (day, vals.reduce(0, +) / Double(vals.count))
        }
    }

    private static func buildWristTempSeries(
        samples: [TimedQuantitySample],
        start14d: Date,
        firstDay7d: Date,
        now: Date,
        calendar: Calendar
    ) -> OvernightVitalSeries {
        let daily14 = groupDailyAverages(samples: samples, from: start14d, to: now, calendar: calendar)
        guard !daily14.isEmpty else {
            return OvernightVitalSeries(
                kind: .wristTemp,
                points: [],
                latest: nil,
                baseline: nil,
                typicalRange: nil,
                yAxisDomain: -1.0...1.0
            )
        }

        // Compute personal 14-day baseline excluding the latest day when enough prior nights exist.
        let baselinePool = daily14.count >= 4 ? Array(daily14.dropLast()) : daily14
        let baselineC = baselinePool.reduce(0) { $0 + $1.value } / Double(baselinePool.count)
        let hasReliableBaseline = daily14.count >= 3

        let halfWidth = 0.40
        let outlierThreshold = 0.45

        let points7d: [OvernightVitalPoint] = daily14
            .filter { $0.day >= firstDay7d }
            .map { entry in
                let delta = entry.value - baselineC
                let state: OvernightOutlierState
                if hasReliableBaseline {
                    if delta >= outlierThreshold {
                        state = .high
                    } else if delta <= -outlierThreshold {
                        state = .low
                    } else {
                        state = .typical
                    }
                } else {
                    state = .typical
                }
                return OvernightVitalPoint(date: entry.day, value: delta, outlierState: state)
            }

        let maxAbs = max(0.8, (points7d.map { abs($0.value) }.max() ?? 0.5) + 0.3)
        let roundedBound = ceil(maxAbs * 2.0) / 2.0

        return OvernightVitalSeries(
            kind: .wristTemp,
            points: points7d,
            latest: points7d.last,
            baseline: 0.0,
            typicalRange: -halfWidth...halfWidth,
            yAxisDomain: -roundedBound...roundedBound
        )
    }

    private static func buildAbsoluteSeries(
        kind: OvernightVitalKind,
        samples: [TimedQuantitySample],
        start14d: Date,
        firstDay7d: Date,
        now: Date,
        calendar: Calendar,
        normalHalfWidth: Double,
        highOutlierDelta: Double?,
        lowOutlierDelta: Double?,
        absoluteHighFloor: Double?,
        absoluteLowCeiling: Double?,
        minDomainSpan: Double,
        clampMin: Double,
        clampMax: Double
    ) -> OvernightVitalSeries {
        let daily14 = groupDailyAverages(samples: samples, from: start14d, to: now, calendar: calendar)
        guard !daily14.isEmpty else {
            return OvernightVitalSeries(
                kind: kind,
                points: [],
                latest: nil,
                baseline: nil,
                typicalRange: nil,
                yAxisDomain: clampMin...(clampMin + minDomainSpan)
            )
        }

        let baselinePool = daily14.count >= 4 ? Array(daily14.dropLast()) : daily14
        let baseline = baselinePool.reduce(0) { $0 + $1.value } / Double(baselinePool.count)
        let hasReliableBaseline = daily14.count >= 3

        let clampedBaseline = min(clampMax, max(clampMin, baseline))
        let typicalLow = max(clampMin, clampedBaseline - normalHalfWidth)
        let typicalHigh = min(clampMax, max(typicalLow, clampedBaseline + normalHalfWidth))

        let points7d: [OvernightVitalPoint] = daily14
            .filter { $0.day >= firstDay7d }
            .map { entry in
                let delta = entry.value - baseline
                var state: OvernightOutlierState = .typical

                if let absHigh = absoluteHighFloor, entry.value >= absHigh {
                    state = .high
                } else if let absLow = absoluteLowCeiling, entry.value <= absLow {
                    state = .low
                } else if hasReliableBaseline {
                    if let hiDelta = highOutlierDelta, delta >= hiDelta {
                        state = .high
                    } else if let loDelta = lowOutlierDelta, delta <= -loDelta {
                        state = .low
                    }
                }
                return OvernightVitalPoint(date: entry.day, value: entry.value, outlierState: state)
            }

        let vals = points7d.map(\.value) + [typicalLow, typicalHigh]
        let rawLow = vals.min() ?? baseline - minDomainSpan / 2
        let rawHigh = vals.max() ?? baseline + minDomainSpan / 2
        let span = max(minDomainSpan, (rawHigh - rawLow) + 2.0)
        let mid = (rawLow + rawHigh) / 2.0
        var low = max(clampMin, floor(mid - span / 2.0))
        var high = min(clampMax, ceil(mid + span / 2.0))
        if high - low < minDomainSpan {
            low = max(clampMin, high - minDomainSpan)
            high = min(clampMax, low + minDomainSpan)
        }

        return OvernightVitalSeries(
            kind: kind,
            points: points7d,
            latest: points7d.last,
            baseline: baseline,
            typicalRange: typicalLow...typicalHigh,
            yAxisDomain: low...high
        )
    }
}

struct OvernightVitalsCardView: View {
    let summary: OvernightVitals7dSummary?
    let isAuthorized: Bool
    let isLoading: Bool

    @AppStorage("cardCollapsed_overnightVitals") private var isCollapsed = false
    @State private var selectedKind: OvernightVitalKind?
    @State private var selectedPoint: OvernightVitalPoint?

    var body: some View {
        let kind = activeKind
        let activeSeries = summary?.series(for: kind)

        CollapsibleCard(isCollapsed: $isCollapsed, accessibilityTitle: "Overnight Vitals") {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 7) {
                    Image(systemName: "moon.stars.fill")
                        .font(.subheadline)
                        .foregroundColor(AppTheme.Colors.sleepDeep)
                    Text("Overnight Vitals")
                        .font(.system(.headline, design: .rounded))
                        .foregroundColor(.primary)
                }

                Text(subtitleText(kind: kind))
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .monospacedDigit()
                    .lineLimit(2)
            }
        } headerTrailing: {
            if let point = selectedPoint {
                Text(kind.formatValue(point.value))
                    .font(.system(.title3, design: .rounded).weight(.bold))
                    .foregroundColor(point.outlierState.isOutlier ? AppTheme.Colors.coral : kind.tint)
                    .monospacedDigit()
                    .contentTransition(.numericText())
                    .padding(.top, 1)
                    .animation(AppTheme.Animations.readoutUpdate, value: point.id)
            } else if let summary, summary.hasAnyData {
                HStack(spacing: 4) {
                    Image(systemName: summary.watchStatus.symbolName)
                        .font(.system(size: 11, weight: .semibold))
                    Text(summary.badgeText)
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                }
                .foregroundColor(summary.watchStatus.color)
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .background(
                    Capsule()
                        .fill(summary.watchStatus.color.opacity(0.14))
                )
                .overlay(
                    Capsule()
                        .strokeBorder(summary.watchStatus.color.opacity(0.32), lineWidth: 0.75)
                )
                .padding(.top, 2)
            }
        } content: {
            if !isAuthorized {
                Text("Grant Health access to monitor 7-day wrist temperature, respiratory rate, and blood oxygen baselines.")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .padding(.vertical, 8)
            } else {
                metricTilesGrid(activeKind: kind)

                if let summary, let activeSeries, !activeSeries.isEmpty {
                    vitalsChart(summary: summary, kind: kind, series: activeSeries)
                        .frame(height: 185)

                    HStack(spacing: 12) {
                        legendBandChip(color: AppTheme.Colors.emerald, label: "Typical")
                        if activeSeries.hasAnyOutlier {
                            legendDotChip(color: AppTheme.Colors.coral, label: "Outlier")
                        }
                        legendDashedChip(color: AppTheme.Colors.slateTeal, label: "14d avg")
                        Spacer(minLength: 4)
                        Text(selectedPoint == nil ? "Hold & drag" : selectedOutlierLabel)
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
                } else if summary?.hasAnyData == true {
                    Text("No \(kind.fullTitle) samples recorded in the last 7 days.")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.vertical, 36)
                } else {
                    Text("No overnight wrist temp, respiratory rate, or SpO₂ recorded in the last 7 days.")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.vertical, 36)
                }
            }
        }
    }

    private var activeKind: OvernightVitalKind {
        if let selectedKind, let summary, summary.displayKinds.contains(selectedKind) {
            return selectedKind
        }
        return summary?.preferredKind ?? .wristTemp
    }

    private var selectedOutlierLabel: String {
        guard let point = selectedPoint else { return "" }
        switch point.outlierState {
        case .typical: return "Within baseline"
        case .high: return "Above baseline"
        case .low: return "Below baseline"
        }
    }

    private func subtitleText(kind: OvernightVitalKind) -> String {
        if let point = selectedPoint {
            let isToday = summary?.dayStarts.last.map { Calendar.current.isDate(point.date, inSameDayAs: $0) } ?? false
            let dayLabel = isToday
                ? "Today"
                : point.date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
            return "\(dayLabel) · \(kind.fullTitle)"
        }
        return summary?.insight ?? "7-day early-illness baseline watch"
    }

    @ViewBuilder
    private func metricTilesGrid(activeKind: OvernightVitalKind) -> some View {
        let kinds = summary?.displayKinds ?? [.wristTemp, .respiratoryRate, .bloodOxygen]
        if kinds.count <= 3 {
            HStack(spacing: 8) {
                ForEach(kinds) { kind in
                    vitalTile(kind: kind, isSelected: kind == activeKind)
                }
            }
        } else {
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
                ForEach(kinds) { kind in
                    vitalTile(kind: kind, isSelected: kind == activeKind)
                }
            }
        }
    }

    private func vitalTile(kind: OvernightVitalKind, isSelected: Bool) -> some View {
        let series = summary?.series(for: kind)
        let valueText = series?.latest.map { kind.formatValue($0.value) } ?? "—"
        let isOutlier = series?.isLatestOutlier ?? false
        let accent = isOutlier ? AppTheme.Colors.coral : kind.tint
        let statusColor: Color = series?.latest == nil
            ? .secondary
            : (isOutlier ? AppTheme.Colors.coral : AppTheme.Colors.emerald)

        return Button {
            withAnimation(AppTheme.Animations.chartUpdate) {
                selectedKind = kind
                selectedPoint = nil
            }
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 4) {
                    Image(systemName: kind.icon)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(accent)
                    Text(kind.title)
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .foregroundColor(.primary.opacity(0.85))
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    if series?.latest != nil {
                        Circle()
                            .fill(statusColor)
                            .frame(width: 6, height: 6)
                    }
                }

                Text(valueText)
                    .font(.system(.headline, design: .rounded).weight(.bold))
                    .foregroundColor(.primary)
                    .monospacedDigit()
                    .contentTransition(.numericText())
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)

                Text(series?.statusCaption ?? "No data")
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .foregroundColor(statusColor)
                    .lineLimit(1)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: AppTheme.Layout.insetCornerRadius, style: .continuous)
                    .fill(isSelected ? accent.opacity(0.14) : AppTheme.Colors.insetSurface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: AppTheme.Layout.insetCornerRadius, style: .continuous)
                    .strokeBorder(
                        isSelected ? accent.opacity(0.50) : AppTheme.Colors.cardBorder,
                        lineWidth: isSelected ? 1.25 : 1
                    )
            )
        }
        .buttonStyle(.plain)
    }

    private func legendBandChip(color: Color, label: String) -> some View {
        HStack(spacing: 5) {
            RoundedRectangle(cornerRadius: 2)
                .fill(color.opacity(0.28))
                .overlay(RoundedRectangle(cornerRadius: 2).strokeBorder(color.opacity(0.55), lineWidth: 0.75))
                .frame(width: 11, height: 7)
            Text(label)
                .font(.caption2.weight(.medium))
                .foregroundColor(.secondary)
        }
    }

    private func legendDotChip(color: Color, label: String) -> some View {
        HStack(spacing: 5) {
            Circle()
                .fill(color)
                .frame(width: 7, height: 7)
            Text(label)
                .font(.caption2.weight(.medium))
                .foregroundColor(.secondary)
        }
    }

    private func legendDashedChip(color: Color, label: String) -> some View {
        HStack(spacing: 5) {
            HStack(spacing: 2) {
                Capsule().fill(color).frame(width: 5, height: 2)
                Capsule().fill(color).frame(width: 5, height: 2)
            }
            Text(label)
                .font(.caption2.weight(.medium))
                .foregroundColor(.secondary)
        }
    }

    private func vitalsChart(
        summary: OvernightVitals7dSummary,
        kind: OvernightVitalKind,
        series: OvernightVitalSeries
    ) -> some View {
        let todayDate = summary.dayStarts.last

        return Chart {
            // Shaded personal typical-range band (14-day baseline ± typical variance)
            if let typical = series.typicalRange {
                RectangleMark(
                    xStart: .value("Start", summary.xAxisDomain.lowerBound),
                    xEnd: .value("End", summary.xAxisDomain.upperBound),
                    yStart: .value("Low", typical.lowerBound),
                    yEnd: .value("High", typical.upperBound)
                )
                .foregroundStyle(AppTheme.Colors.typicalBandFill)
            }

            if let baseline = series.baseline {
                RuleMark(y: .value("Baseline", baseline))
                    .foregroundStyle(AppTheme.Colors.slateTeal.opacity(0.65))
                    .lineStyle(StrokeStyle(lineWidth: 1.15, dash: [4, 4]))
            }

            if series.points.count >= 2 {
                ForEach(series.points) { point in
                    LineMark(
                        x: .value("Day", point.midpoint),
                        y: .value(kind.title, point.value)
                    )
                    .foregroundStyle(kind.tint.opacity(0.75))
                    .lineStyle(StrokeStyle(lineWidth: 2.0, lineCap: .round, lineJoin: .round))
                    .interpolationMethod(.catmullRom)
                }
            }

            ForEach(series.points) { point in
                let isSelected = (selectedPoint?.id == point.id)
                let pointColor = point.outlierState.isOutlier ? AppTheme.Colors.coral : kind.tint

                if point.outlierState.isOutlier || isSelected {
                    PointMark(
                        x: .value("Day", point.midpoint),
                        y: .value(kind.title, point.value)
                    )
                    .foregroundStyle(pointColor.opacity(0.24))
                    .symbolSize(isSelected ? 150 : 120)
                }

                PointMark(
                    x: .value("Day", point.midpoint),
                    y: .value(kind.title, point.value)
                )
                .foregroundStyle(isSelected ? AppTheme.Colors.cardSurface : pointColor)
                .symbolSize(isSelected ? 82 : 46)

                if isSelected {
                    PointMark(
                        x: .value("Day", point.midpoint),
                        y: .value(kind.title, point.value)
                    )
                    .foregroundStyle(pointColor)
                    .symbolSize(40)
                }
            }

            if let selected = selectedPoint {
                RuleMark(x: .value("Selected", selected.midpoint))
                    .foregroundStyle(kind.tint.opacity(0.35))
                    .lineStyle(StrokeStyle(lineWidth: 1.25))
            }
        }
        .chartXScale(domain: summary.xAxisDomain)
        .chartYScale(domain: series.yAxisDomain)
        .chartXAxis {
            AxisMarks(values: summary.dayStarts) { value in
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
                    if let val = value.as(Double.self) {
                        Text(kind.formatAxisValue(val))
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
