import SwiftUI
import Charts

enum GaitZoneTier: String, Equatable, Sendable, Codable {
    case optimal
    case fair
    case caution
    case noData

    var label: String {
        switch self {
        case .optimal: return "Optimal"
        case .fair: return "Watch"
        case .caution: return "Elevated"
        case .noData: return "No data"
        }
    }

    var color: Color {
        switch self {
        case .optimal: return AppTheme.Colors.emerald
        case .fair: return AppTheme.Colors.ochre
        case .caution: return AppTheme.Colors.coral
        case .noData: return AppTheme.Colors.slateTeal
        }
    }

    var severity: Int {
        switch self {
        case .noData: return 0
        case .optimal: return 1
        case .fair: return 2
        case .caution: return 3
        }
    }
}

enum GaitMetricKind: String, CaseIterable, Identifiable, Equatable, Sendable, Codable {
    case steadiness
    case asymmetry
    case speed
    case stepLength
    case doubleSupport

    var id: String { rawValue }

    var title: String {
        switch self {
        case .steadiness: return "Steadiness"
        case .asymmetry: return "Asymmetry"
        case .speed: return "Walk Speed"
        case .stepLength: return "Step Length"
        case .doubleSupport: return "Double Support"
        }
    }

    var bodyZoneName: String {
        switch self {
        case .steadiness: return "Core & Posture"
        case .asymmetry: return "Pelvis & Balance"
        case .speed: return "Forward Pace"
        case .stepLength: return "Stride Arc"
        case .doubleSupport: return "Foot Contact"
        }
    }

    var icon: String {
        switch self {
        case .steadiness: return "figure.stand"
        case .asymmetry: return "scale.3d"
        case .speed: return "gauge.with.dots.needle.67percent"
        case .stepLength: return "ruler"
        case .doubleSupport: return "shoeprints.fill"
        }
    }
}

struct GaitMetricStatus: Equatable, Sendable, Codable {
    let kind: GaitMetricKind
    let value: Double?
    let formattedValue: String
    let tier: GaitZoneTier
    let statusText: String
    let sampleCount: Int
}

struct GaitBiomechanics30dSummary: Equatable, Sendable, Codable {
    let windowStart: Date
    let windowEnd: Date
    let steadiness: GaitMetricStatus
    let asymmetry: GaitMetricStatus
    let speed: GaitMetricStatus
    let stepLength: GaitMetricStatus
    let doubleSupport: GaitMetricStatus
    let speedSeries: CardioSeriesSummary
    let stepLengthSeries: CardioSeriesSummary
    let overallTier: GaitZoneTier
    let availableMetricCount: Int
    /// Normalized visual torso/pelvis inclination in `0...1` driven by asymmetry & steadiness.
    let visualInclination: Double
    let insight: String

    var hasAnyData: Bool { availableMetricCount > 0 }

    var allMetrics: [GaitMetricStatus] {
        [steadiness, asymmetry, speed, stepLength, doubleSupport]
    }

    func metric(for kind: GaitMetricKind) -> GaitMetricStatus {
        switch kind {
        case .steadiness: return steadiness
        case .asymmetry: return asymmetry
        case .speed: return speed
        case .stepLength: return stepLength
        case .doubleSupport: return doubleSupport
        }
    }

    var overallBadgeText: String {
        switch overallTier {
        case .optimal: return "Balanced"
        case .fair: return "Mild Drift"
        case .caution: return "Check Gait"
        case .noData: return "No Data"
        }
    }

    static func build(
        walkingSpeed30d: [TimedQuantitySample],
        stepLength30d: [TimedQuantitySample],
        asymmetry30d: [TimedQuantitySample],
        doubleSupport30d: [TimedQuantitySample],
        steadiness30d: [TimedQuantitySample],
        windowEnd: Date
    ) -> GaitBiomechanics30dSummary {
        let start30d = windowEnd.addingTimeInterval(-30 * 24 * 60 * 60)
        let start7d = windowEnd.addingTimeInterval(-7 * 24 * 60 * 60)

        // Apple Walking Steadiness is already a multi-week rolling score -> use latest valid reading.
        let validSteadiness = steadiness30d
            .filter { $0.value.isFinite && $0.date >= start30d && $0.date <= windowEnd && $0.value > 0 }
            .sorted { $0.date < $1.date }
        let steadinessPct: Double? = validSteadiness.last.map { $0.value <= 1.0 ? $0.value * 100.0 : $0.value }
        let steadinessStatus: GaitMetricStatus = {
            guard let pct = steadinessPct else {
                return GaitMetricStatus(
                    kind: .steadiness, value: nil, formattedValue: "—",
                    tier: .noData, statusText: "No data", sampleCount: 0
                )
            }
            let tier: GaitZoneTier
            let text: String
            if pct >= 75 {
                tier = .optimal
                text = "Steady"
            } else if pct >= 50 {
                tier = .fair
                text = "Low"
            } else {
                tier = .caution
                text = "Very Low"
            }
            return GaitMetricStatus(
                kind: .steadiness,
                value: pct,
                formattedValue: "\(Int(pct.rounded()))%",
                tier: tier,
                statusText: text,
                sampleCount: validSteadiness.count
            )
        }()

        // For per-walk metrics, prefer 7-day smoothed mean when available, else 30-day mean.
        let (asymVal, asymCount) = recentSmoothedMean(
            samples: asymmetry30d, start30d: start30d, start7d: start7d, end: windowEnd, allowZero: true
        )
        let asymPct = asymVal.map { $0 <= 1.0 ? $0 * 100.0 : $0 }
        let asymmetryStatus: GaitMetricStatus = {
            guard let pct = asymPct else {
                return GaitMetricStatus(
                    kind: .asymmetry, value: nil, formattedValue: "—",
                    tier: .noData, statusText: "No data", sampleCount: 0
                )
            }
            let tier: GaitZoneTier
            let text: String
            if pct < 3.0 {
                tier = .optimal
                text = "Balanced"
            } else if pct <= 6.0 {
                tier = .fair
                text = "Slight tilt"
            } else {
                tier = .caution
                text = "Asymmetric"
            }
            return GaitMetricStatus(
                kind: .asymmetry,
                value: pct,
                formattedValue: String(format: "%.1f%%", pct),
                tier: tier,
                statusText: text,
                sampleCount: asymCount
            )
        }()

        let (speedVal, speedCount) = recentSmoothedMean(
            samples: walkingSpeed30d, start30d: start30d, start7d: start7d, end: windowEnd, allowZero: false
        )
        let speedStatus: GaitMetricStatus = {
            guard let mps = speedVal else {
                return GaitMetricStatus(
                    kind: .speed, value: nil, formattedValue: "—",
                    tier: .noData, statusText: "No data", sampleCount: 0
                )
            }
            let tier: GaitZoneTier
            let text: String
            if mps >= 1.25 {
                tier = .optimal
                text = "Brisk"
            } else if mps >= 1.00 {
                tier = .fair
                text = "Moderate"
            } else {
                tier = .caution
                text = "Slow"
            }
            return GaitMetricStatus(
                kind: .speed,
                value: mps,
                formattedValue: String(format: "%.2f m/s", mps),
                tier: tier,
                statusText: text,
                sampleCount: speedCount
            )
        }()

        let (stepMeters, stepCount) = recentSmoothedMean(
            samples: stepLength30d, start30d: start30d, start7d: start7d, end: windowEnd, allowZero: false
        )
        let stepCm = stepMeters.map { $0 < 3.0 ? $0 * 100.0 : $0 }
        let stepLengthStatus: GaitMetricStatus = {
            guard let cm = stepCm else {
                return GaitMetricStatus(
                    kind: .stepLength, value: nil, formattedValue: "—",
                    tier: .noData, statusText: "No data", sampleCount: 0
                )
            }
            let tier: GaitZoneTier
            let text: String
            if cm >= 65 {
                tier = .optimal
                text = "Full stride"
            } else if cm >= 52 {
                tier = .fair
                text = "Shorter"
            } else {
                tier = .caution
                text = "Short stride"
            }
            return GaitMetricStatus(
                kind: .stepLength,
                value: cm,
                formattedValue: "\(Int(cm.rounded())) cm",
                tier: tier,
                statusText: text,
                sampleCount: stepCount
            )
        }()

        let (dsVal, dsCount) = recentSmoothedMean(
            samples: doubleSupport30d, start30d: start30d, start7d: start7d, end: windowEnd, allowZero: false
        )
        let dsPct = dsVal.map { $0 <= 1.0 ? $0 * 100.0 : $0 }
        let doubleSupportStatus: GaitMetricStatus = {
            guard let pct = dsPct else {
                return GaitMetricStatus(
                    kind: .doubleSupport, value: nil, formattedValue: "—",
                    tier: .noData, statusText: "No data", sampleCount: 0
                )
            }
            let tier: GaitZoneTier
            let text: String
            if pct <= 30.0 {
                tier = .optimal
                text = "Light"
            } else if pct <= 34.0 {
                tier = .fair
                text = "Guarded"
            } else {
                tier = .caution
                text = "Heavy"
            }
            return GaitMetricStatus(
                kind: .doubleSupport,
                value: pct,
                formattedValue: String(format: "%.0f%%", pct),
                tier: tier,
                statusText: text,
                sampleCount: dsCount
            )
        }()

        let all = [steadinessStatus, asymmetryStatus, speedStatus, stepLengthStatus, doubleSupportStatus]
        let available = all.filter { $0.tier != .noData }
        let worst = available.max { $0.tier.severity < $1.tier.severity }?.tier ?? .noData

        // Normalized inclination indicator (0 = upright/symmetric, 1 = pronounced lean/asymmetry).
        let asymFactor = min(1.0, max(0.0, (asymPct ?? 0) / 10.0))
        let steadinessFactor = steadinessPct.map { min(1.0, max(0.0, (100.0 - $0) / 60.0)) } ?? 0.0
        let inclination = max(asymFactor, steadinessFactor * 0.75)

        let insight: String
        if available.isEmpty {
            insight = "Carry your iPhone while walking to capture gait & stride biomechanics."
        } else {
            let flagged = available.filter { $0.tier == .caution || $0.tier == .fair }
            if flagged.isEmpty {
                insight = "Balanced stride and steady gait across \(available.count) metrics."
            } else if flagged.count == 1 {
                let m = flagged[0]
                insight = "\(m.kind.title) is \(m.statusText.lowercased()) (\(m.formattedValue)) — tap a zone to inspect."
            } else {
                let names = flagged.prefix(2).map(\.kind.title).joined(separator: " & ")
                insight = "\(names) show mild inclination drift over the last 30 days."
            }
        }

        let speedSeries = CardioSeriesSummary.build(
            samples: walkingSpeed30d,
            windowStart: start30d,
            windowEnd: windowEnd,
            stepPadding: 0.15,
            defaultRange: 0.8...1.8
        )
        let normalizedStepSamples = stepLength30d.map { sample in
            let cm = sample.value < 3.0 ? sample.value * 100.0 : sample.value
            return TimedQuantitySample(date: sample.date, value: cm)
        }
        let stepLengthSeries = CardioSeriesSummary.build(
            samples: normalizedStepSamples,
            windowStart: start30d,
            windowEnd: windowEnd,
            stepPadding: 5,
            defaultRange: 45...90
        )

        return GaitBiomechanics30dSummary(
            windowStart: start30d,
            windowEnd: windowEnd,
            steadiness: steadinessStatus,
            asymmetry: asymmetryStatus,
            speed: speedStatus,
            stepLength: stepLengthStatus,
            doubleSupport: doubleSupportStatus,
            speedSeries: speedSeries,
            stepLengthSeries: stepLengthSeries,
            overallTier: worst,
            availableMetricCount: available.count,
            visualInclination: inclination,
            insight: insight
        )
    }

    private static func recentSmoothedMean(
        samples: [TimedQuantitySample],
        start30d: Date,
        start7d: Date,
        end: Date,
        allowZero: Bool
    ) -> (Double?, Int) {
        let in30 = samples.filter {
            $0.value.isFinite && $0.date >= start30d && $0.date <= end && (allowZero ? $0.value >= 0 : $0.value > 0)
        }
        guard !in30.isEmpty else { return (nil, 0) }
        let in7 = in30.filter { $0.date >= start7d }
        let pool = in7.isEmpty ? in30 : in7
        let mean = pool.reduce(0) { $0 + $1.value } / Double(pool.count)
        return (mean, in30.count)
    }
}

struct GaitBiomechanicsCardView: View {
    let summary: GaitBiomechanics30dSummary?
    let isAuthorized: Bool
    let isLoading: Bool

    @AppStorage("cardCollapsed_gait") private var isCollapsed = false
    @State private var focusedMetric: GaitMetricKind?
    @State private var selectedSpeedPoint: CardioMetricPoint?
    @State private var selectedStepPoint: CardioMetricPoint?

    var body: some View {
        CollapsibleCard(isCollapsed: $isCollapsed, accessibilityTitle: "Gait & Biomechanics") {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 7) {
                    Image(systemName: "figure.walk")
                        .font(.subheadline)
                        .foregroundColor(AppTheme.Colors.teal)
                    Text("Gait & Biomechanics")
                        .font(.system(.headline, design: .rounded))
                        .foregroundColor(.primary)
                }

                Text(subtitleText)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(2)
            }
        } headerTrailing: {
            if let summary, summary.hasAnyData {
                Text(summary.overallBadgeText)
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundColor(summary.overallTier.color)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .background(
                        Capsule()
                            .fill(summary.overallTier.color.opacity(0.14))
                    )
                    .overlay(
                        Capsule()
                            .strokeBorder(summary.overallTier.color.opacity(0.32), lineWidth: 0.75)
                    )
                    .padding(.top, 2)
            }
        } content: {
            if !isAuthorized {
                Text("Grant Health access to visualize walking symmetry, steadiness, stride length, and biomechanics.")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .padding(.vertical, 8)
            } else if let summary, summary.hasAnyData {
                silhouetteStage(summary)

                metricGrid(summary)

                if !summary.speedSeries.isEmpty || !summary.stepLengthSeries.isEmpty {
                    VStack(spacing: 10) {
                        if !summary.speedSeries.isEmpty {
                            gaitTrendRow(
                                title: "Walk Speed",
                                icon: GaitMetricKind.speed.icon,
                                tint: summary.speed.tier.color,
                                series: summary.speedSeries,
                                windowStart: summary.windowStart,
                                windowEnd: summary.windowEnd,
                                selectedPoint: $selectedSpeedPoint,
                                formatValue: { String(format: "%.2f m/s", $0) },
                                formatAxis: { String(format: "%.1f", $0) },
                                formatDelta: { delta in
                                    let r = (delta * 100).rounded() / 100
                                    if r == 0 { return "0.00" }
                                    return String(format: "%@%.2f m/s", r > 0 ? "+" : "", r)
                                }
                            )
                        }

                        if !summary.stepLengthSeries.isEmpty {
                            gaitTrendRow(
                                title: "Step Length",
                                icon: GaitMetricKind.stepLength.icon,
                                tint: summary.stepLength.tier.color,
                                series: summary.stepLengthSeries,
                                windowStart: summary.windowStart,
                                windowEnd: summary.windowEnd,
                                selectedPoint: $selectedStepPoint,
                                formatValue: { "\(Int($0.rounded())) cm" },
                                formatAxis: { "\(Int($0.rounded()))" },
                                formatDelta: { delta in
                                    let r = Int(delta.rounded())
                                    if r == 0 { return "0 cm" }
                                    return "\(r > 0 ? "+" : "")\(r) cm"
                                }
                            )
                        }
                    }
                }

                HStack(spacing: 12) {
                    zoneLegend(color: AppTheme.Colors.emerald, label: "Optimal")
                    zoneLegend(color: AppTheme.Colors.ochre, label: "Watch")
                    zoneLegend(color: AppTheme.Colors.coral, label: "Elevated")
                    Spacer(minLength: 4)
                    Text(focusedMetric == nil ? "Tap to highlight" : "Tap to reset")
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
                Text("No walking gait or biomechanics data recorded in the last 30 days.")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 36)
            }
        }
    }

    private var subtitleText: String {
        if let kind = focusedMetric, let status = summary?.metric(for: kind) {
            return "\(kind.bodyZoneName) · \(kind.title): \(status.formattedValue) (\(status.statusText))"
        }
        return summary?.insight ?? "30-day walking biomechanics"
    }

    // MARK: - Interactive Biomechanical Silhouette Stage

    private func silhouetteStage(_ data: GaitBiomechanics30dSummary) -> some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: AppTheme.Layout.insetCornerRadius, style: .continuous)
                .fill(AppTheme.Colors.insetSurface)
                .overlay(
                    RoundedRectangle(cornerRadius: AppTheme.Layout.insetCornerRadius, style: .continuous)
                        .strokeBorder(AppTheme.Colors.cardBorder, lineWidth: 1)
                )

            GaitSilhouetteCanvas(summary: data, focusedMetric: focusedMetric)
                .frame(height: 184)
                .padding(.horizontal, 8)

            // Live zone annotation badges positioned cleanly in corners of the stage.
            HStack {
                if let kind = focusedMetric {
                    let status = data.metric(for: kind)
                    stageBadge(
                        icon: kind.icon,
                        text: "\(kind.bodyZoneName) · \(status.formattedValue)",
                        tint: status.tier.color
                    )
                } else {
                    stageBadge(
                        icon: "scale.3d",
                        text: "Tilt \(data.asymmetry.formattedValue)",
                        tint: data.asymmetry.tier.color
                    )
                }
                Spacer()
                if data.stepLength.value != nil {
                    stageBadge(
                        icon: "ruler",
                        text: "Stride \(data.stepLength.formattedValue)",
                        tint: data.stepLength.tier.color
                    )
                }
            }
            .padding(10)
        }
        .frame(height: 190)
        .animation(AppTheme.Animations.chartUpdate, value: focusedMetric)
    }

    private func stageBadge(icon: String, text: String, tint: Color) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(tint)
            Text(text)
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .foregroundColor(.primary.opacity(0.85))
                .monospacedDigit()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            Capsule()
                .fill(AppTheme.Colors.cardSurface.opacity(0.92))
        )
        .overlay(
            Capsule()
                .strokeBorder(tint.opacity(0.32), lineWidth: 0.75)
        )
    }

    // MARK: - Metric Selector Grid

    private func metricGrid(_ data: GaitBiomechanics30dSummary) -> some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                gaitTile(data.steadiness)
                gaitTile(data.asymmetry)
            }
            HStack(spacing: 8) {
                gaitTile(data.speed)
                gaitTile(data.stepLength)
                gaitTile(data.doubleSupport)
            }
        }
    }

    private func gaitTile(_ status: GaitMetricStatus) -> some View {
        let isFocused = (focusedMetric == status.kind)
        let isDimmed = (focusedMetric != nil && !isFocused)
        let tint = status.tier.color

        return Button {
            withAnimation(AppTheme.Animations.collapse) {
                focusedMetric = isFocused ? nil : status.kind
            }
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 4) {
                    Circle()
                        .fill(status.tier == .noData ? Color.secondary.opacity(0.35) : tint)
                        .frame(width: 6, height: 6)
                    Text(status.kind.title)
                        .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                        .foregroundColor(.primary.opacity(0.82))
                        .lineLimit(1)
                        .minimumScaleFactor(0.72)
                }

                Text(status.formattedValue)
                    .font(.system(.subheadline, design: .rounded).weight(.bold))
                    .foregroundColor(.primary)
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)

                Text(status.statusText)
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .foregroundColor(status.tier == .noData ? .secondary : tint)
                    .lineLimit(1)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: AppTheme.Layout.chipCornerRadius, style: .continuous)
                    .fill(isFocused ? tint.opacity(0.16) : AppTheme.Colors.insetSurface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: AppTheme.Layout.chipCornerRadius, style: .continuous)
                    .strokeBorder(isFocused ? tint.opacity(0.55) : AppTheme.Colors.cardBorder, lineWidth: isFocused ? 1.25 : 1)
            )
            .opacity(isDimmed ? 0.55 : 1.0)
        }
        .buttonStyle(.plain)
    }

    private func gaitTrendRow(
        title: String,
        icon: String,
        tint: Color,
        series: CardioSeriesSummary,
        windowStart: Date,
        windowEnd: Date,
        selectedPoint: Binding<CardioMetricPoint?>,
        formatValue: @escaping (Double) -> String,
        formatAxis: @escaping (Double) -> String,
        formatDelta: @escaping (Double) -> String
    ) -> some View {
        let activePoint = selectedPoint.wrappedValue
        let yFloor = series.yAxisDomain.lowerBound

        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(tint)
                Text(title)
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundColor(.primary)
                Text("· 30d")
                    .font(.caption2)
                    .foregroundColor(.secondary)

                Spacer()

                if let pt = activePoint {
                    Text("\(pt.date.formatted(.dateTime.month(.abbreviated).day())) · \(formatValue(pt.value))")
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .foregroundColor(tint)
                        .monospacedDigit()
                } else if let delta = series.delta {
                    Text(formatDelta(delta))
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .foregroundColor(delta >= 0 ? AppTheme.Colors.emerald : AppTheme.Colors.coral)
                        .monospacedDigit()
                } else if let latest = series.latest {
                    Text(formatValue(latest))
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .foregroundColor(.secondary)
                        .monospacedDigit()
                }
            }

            Chart {
                if series.points.count >= 2 {
                    ForEach(series.points) { point in
                        AreaMark(
                            x: .value("Date", point.date),
                            yStart: .value("Floor", yFloor),
                            yEnd: .value(title, point.value)
                        )
                        .interpolationMethod(.catmullRom)
                        .foregroundStyle(AppTheme.Colors.trendAreaGradient(for: tint))
                    }
                }

                if let avg = series.average {
                    RuleMark(y: .value("30d Avg", avg))
                        .foregroundStyle(AppTheme.Colors.slateTeal.opacity(0.60))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                }

                if series.points.count >= 2 {
                    ForEach(series.points) { point in
                        LineMark(
                            x: .value("Date", point.date),
                            y: .value(title, point.value)
                        )
                        .foregroundStyle(tint)
                        .lineStyle(StrokeStyle(lineWidth: 2.0, lineCap: .round, lineJoin: .round))
                        .interpolationMethod(.catmullRom)
                    }
                }

                ForEach(series.points) { point in
                    let isSelected = (activePoint?.id == point.id)
                    PointMark(
                        x: .value("Date", point.date),
                        y: .value(title, point.value)
                    )
                    .foregroundStyle(isSelected ? AppTheme.Colors.cardSurface : tint)
                    .symbolSize(isSelected ? 70 : 18)

                    if isSelected {
                        PointMark(
                            x: .value("Date", point.date),
                            y: .value(title, point.value)
                        )
                        .foregroundStyle(tint)
                        .symbolSize(34)
                    }
                }

                if let pt = activePoint {
                    RuleMark(x: .value("Selected", pt.date))
                        .foregroundStyle(tint.opacity(0.35))
                        .lineStyle(StrokeStyle(lineWidth: 1))
                }
            }
            .chartXScale(domain: windowStart...windowEnd)
            .chartYScale(domain: series.yAxisDomain)
            .chartXAxis {
                AxisMarks(values: .stride(by: .day, count: 10)) { value in
                    AxisGridLine(stroke: AppTheme.Layout.gridStroke)
                        .foregroundStyle(AppTheme.Colors.gridLine)
                    AxisValueLabel(anchor: .top) {
                        if let date = value.as(Date.self) {
                            Text(date.formatted(.dateTime.month(.abbreviated).day()))
                                .font(.system(size: 9, weight: .medium, design: .rounded))
                                .foregroundColor(.secondary)
                        }
                    }
                }
            }
            .chartYAxis {
                AxisMarks(position: .trailing, values: .automatic(desiredCount: 3)) { value in
                    AxisGridLine(stroke: AppTheme.Layout.gridStroke)
                        .foregroundStyle(AppTheme.Colors.gridLine)
                    AxisValueLabel {
                        if let val = value.as(Double.self) {
                            Text(formatAxis(val))
                                .font(.system(size: 9, weight: .medium, design: .rounded))
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
                        if nearest != selectedPoint.wrappedValue {
                            selectedPoint.wrappedValue = nearest
                        }
                    },
                    onEnd: {
                        if selectedPoint.wrappedValue != nil {
                            withAnimation(AppTheme.Animations.scrubRelease) {
                                selectedPoint.wrappedValue = nil
                            }
                        }
                    }
                )
            }
            .frame(height: 88)
            .disableChartAxisAnimations()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: AppTheme.Layout.insetCornerRadius, style: .continuous)
                .fill(AppTheme.Colors.insetSurface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: AppTheme.Layout.insetCornerRadius, style: .continuous)
                .strokeBorder(AppTheme.Colors.cardBorder, lineWidth: 1)
        )
    }

    private func zoneLegend(color: Color, label: String) -> some View {
        HStack(spacing: 5) {
            Circle()
                .fill(color)
                .frame(width: 7, height: 7)
            Text(label)
                .font(.caption2.weight(.medium))
                .foregroundColor(.secondary)
        }
    }
}

/// Custom single-pass vector `Canvas` rendering a sculpted, anatomically proportioned
/// side-profile human walking silhouette whose body zones, posture inclination, stride arc,
/// momentum lines, and ground contact pads are colored by real HealthKit gait metrics.
private struct GaitSilhouetteCanvas: View {
    let summary: GaitBiomechanics30dSummary
    let focusedMetric: GaitMetricKind?

    var body: some View {
        Canvas { context, size in
            guard size.width > 0, size.height > 0, size.width.isFinite, size.height.isFinite else { return }

            let cx = size.width * 0.50
            let groundY = size.height - 20
            // Scale cleanly to canvas height while preserving true ~7.6-head human proportions.
            let scale = min(1.06, max(0.72, (size.height - 34) / 146.0))

            let clampedInclination = summary.visualInclination.isFinite
                ? min(1.0, max(0.0, summary.visualInclination))
                : 0.0
            // Subtle anatomical forward torso/head pitch around the pelvis pivot (in radians).
            // Positive pitch rotates upper body clockwise (forward lean to the right).
            let leanRadians = clampedInclination * 0.145
            let hipPivot = CGPoint(x: 0, y: 74)

            func map(_ x: CGFloat, _ y: CGFloat, pivotUpperBody: Bool = false) -> CGPoint {
                var px = x
                var py = y
                if pivotUpperBody {
                    let dx = x - hipPivot.x
                    let dy = y - hipPivot.y
                    let c = CGFloat(cos(leanRadians))
                    let s = CGFloat(sin(leanRadians))
                    // In y-up figure coordinates, clockwise forward lean is (dx*c + dy*s, -dx*s + dy*c).
                    px = hipPivot.x + dx * c + dy * s
                    py = hipPivot.y - dx * s + dy * c
                }
                return CGPoint(x: cx + px * scale, y: groundY - py * scale)
            }

            let steadinessColor = zoneColor(for: .steadiness)
            let asymmetryColor = zoneColor(for: .asymmetry)
            let speedColor = zoneColor(for: .speed)
            let stepColor = zoneColor(for: .stepLength)
            let contactColor = zoneColor(for: .doubleSupport)

            let pelvisPt = map(0, 74)
            let shoulderPt = map(-0.5, 111, pivotUpperBody: true)
            let crownPt = map(0, 146, pivotUpperBody: true)

            // 1. Ground plane + soft elliptical ground shadow beneath the walker
            var ground = Path()
            ground.move(to: CGPoint(x: cx - 118, y: groundY))
            ground.addLine(to: CGPoint(x: cx + 118, y: groundY))
            context.stroke(
                ground,
                with: .color(AppTheme.Colors.gridLine),
                style: StrokeStyle(lineWidth: 1, dash: [4, 4])
            )

            let shadowRect = CGRect(x: cx - 48 * scale, y: groundY - 3, width: 98 * scale, height: 8)
            context.fill(
                Path(ellipseIn: shadowRect),
                with: .radialGradient(
                    Gradient(colors: [Color.primary.opacity(0.11), Color.clear]),
                    center: CGPoint(x: cx + 2 * scale, y: groundY + 1),
                    startRadius: 2,
                    endRadius: 50 * scale
                )
            )

            // 2. Vertical posture plumb reference line (Steadiness)
            var plumb = Path()
            plumb.move(to: map(0, 146))
            plumb.addLine(to: CGPoint(x: cx, y: groundY))
            context.stroke(
                plumb,
                with: .color(steadinessColor.opacity(0.24)),
                style: StrokeStyle(lineWidth: 1, dash: [3, 3])
            )

            // 3. Soft ambient core aura behind upper torso (Steadiness)
            let auraCenter = CGPoint(x: (shoulderPt.x + pelvisPt.x) * 0.5, y: (shoulderPt.y + pelvisPt.y) * 0.5)
            let auraRadius: CGFloat = 48 * scale
            context.fill(
                Path(ellipseIn: CGRect(
                    x: auraCenter.x - auraRadius,
                    y: auraCenter.y - auraRadius,
                    width: auraRadius * 2,
                    height: auraRadius * 2
                )),
                with: .radialGradient(
                    Gradient(colors: [steadinessColor.opacity(0.18), steadinessColor.opacity(0.0)]),
                    center: auraCenter,
                    startRadius: 0,
                    endRadius: auraRadius
                )
            )

            // 4. Forward momentum / pace streaks behind upper back (Walking Speed)
            for (idx, figY) in [CGFloat(116), 102, 88].enumerated() {
                let len: CGFloat = (idx == 1 ? 30 : 21) * scale
                let xEnd = map(-20 - CGFloat(idx) * 2.5, figY, pivotUpperBody: true).x
                let yPos = map(0, figY, pivotUpperBody: true).y
                var streak = Path()
                streak.move(to: CGPoint(x: xEnd - len, y: yPos))
                streak.addLine(to: CGPoint(x: xEnd, y: yPos))
                context.stroke(
                    streak,
                    with: .linearGradient(
                        Gradient(colors: [speedColor.opacity(0.0), speedColor.opacity(0.75)]),
                        startPoint: CGPoint(x: xEnd - len, y: yPos),
                        endPoint: CGPoint(x: xEnd, y: yPos)
                    ),
                    style: StrokeStyle(lineWidth: 2.0, lineCap: .round)
                )
            }

            // 5. Foot ground-contact pressure pads (Double Support)
            let trailingContactX = map(-27.5, 0).x
            let leadingContactX = map(33.5, 0).x
            for footX in [trailingContactX, leadingContactX] {
                let padRect = CGRect(x: footX - 14 * scale, y: groundY - 3.2, width: 28 * scale, height: 6.4)
                context.fill(
                    Path(ellipseIn: padRect),
                    with: .color(contactColor.opacity(0.28))
                )
                context.stroke(
                    Path(ellipseIn: padRect),
                    with: .color(contactColor.opacity(0.78)),
                    lineWidth: 1.15
                )
            }

            // 6. Stride arc between trailing push-off and leading heel-strike (Step Length)
            var strideArc = Path()
            strideArc.move(to: CGPoint(x: trailingContactX + 10 * scale, y: groundY - 2))
            strideArc.addQuadCurve(
                to: CGPoint(x: leadingContactX - 10 * scale, y: groundY - 2),
                control: CGPoint(x: cx + 2 * scale, y: groundY - 19 * scale)
            )
            context.stroke(
                strideArc,
                with: .color(stepColor.opacity(0.82)),
                style: StrokeStyle(lineWidth: 1.8, lineCap: .round, dash: [4, 3])
            )

            // 7. Pelvis / balance inclination arc (Asymmetry) framing the hip zone clearly
            let arcRadius: CGFloat = 31 * scale
            var balanceArc = Path()
            balanceArc.addArc(
                center: pelvisPt,
                radius: arcRadius,
                startAngle: .degrees(-148),
                endAngle: .degrees(-32),
                clockwise: false
            )
            context.stroke(
                balanceArc,
                with: .color(asymmetryColor.opacity(0.38)),
                style: StrokeStyle(lineWidth: 2.0, lineCap: .round, dash: [3, 2.5])
            )

            // =========================================================================
            // SCULPTED ANATOMICAL SILHOUETTE (Back-to-front depth layering)
            // =========================================================================

            // A. Far (left) arm — natural athletic counter-swing FORWARD with crisp elbow bend
            var farArm = Path()
            farArm.move(to: map(3.5, 113.5, pivotUpperBody: true))
            // Outer upper arm descending forward to elbow
            farArm.addCurve(
                to: map(14.5, 91.5, pivotUpperBody: true),
                control1: map(8.5, 107.5, pivotUpperBody: true),
                control2: map(12.0, 99.0, pivotUpperBody: true)
            )
            // Forearm angling crisply forward-upward in natural stride swing
            farArm.addCurve(
                to: map(27.0, 88.0, pivotUpperBody: true),
                control1: map(18.5, 89.2, pivotUpperBody: true),
                control2: map(23.0, 88.2, pivotUpperBody: true)
            )
            // Sculpted relaxed walking hand
            farArm.addCurve(
                to: map(33.2, 87.2, pivotUpperBody: true),
                control1: map(29.8, 88.8, pivotUpperBody: true),
                control2: map(32.8, 88.6, pivotUpperBody: true)
            )
            farArm.addCurve(
                to: map(27.5, 82.8, pivotUpperBody: true),
                control1: map(33.2, 85.0, pivotUpperBody: true),
                control2: map(30.4, 83.2, pivotUpperBody: true)
            )
            // Underside forearm back to bent elbow point
            farArm.addCurve(
                to: map(11.8, 84.8, pivotUpperBody: true),
                control1: map(21.5, 83.2, pivotUpperBody: true),
                control2: map(15.5, 83.5, pivotUpperBody: true)
            )
            // Inner upper arm returning to anterior chest/axilla
            farArm.addCurve(
                to: map(4.0, 102.0, pivotUpperBody: true),
                control1: map(8.8, 88.8, pivotUpperBody: true),
                control2: map(6.2, 95.5, pivotUpperBody: true)
            )
            farArm.closeSubpath()
            context.fill(farArm, with: .color(steadinessColor.opacity(0.54)))

            // B. Trailing (back) leg — propulsive toe-off behind hip with realistic lifted-heel foot
            var backLeg = Path()
            backLeg.move(to: map(1.5, 72))
            // Front thigh descending back toward trailing knee
            backLeg.addCurve(
                to: map(-9.0, 41.5),
                control1: map(-1.2, 59.0),
                control2: map(-5.2, 49.5)
            )
            // Front shin descending cleanly to dorsal ankle & arch
            backLeg.addCurve(
                to: map(-24.2, 12.0),
                control1: map(-14.2, 31.5),
                control2: map(-20.0, 20.5)
            )
            // Instep curving smoothly down to planted forefoot/toes
            backLeg.addCurve(
                to: map(-16.0, 2.2),
                control1: map(-21.2, 6.8),
                control2: map(-17.8, 4.0)
            )
            backLeg.addCurve(
                to: map(-17.8, 0.5),
                control1: map(-15.5, 1.0),
                control2: map(-16.5, 0.5)
            )
            // Planted ball of foot / toes pressing ground
            backLeg.addLine(to: map(-26.2, 0.5))
            // Concave plantar arch rising cleanly to lifted heel
            backLeg.addCurve(
                to: map(-36.2, 11.8),
                control1: map(-30.0, 3.0),
                control2: map(-34.2, 7.2)
            )
            // Rounded lifted heel counter curving cleanly into narrow Achilles tendon
            backLeg.addCurve(
                to: map(-32.2, 16.2),
                control1: map(-37.2, 14.0),
                control2: map(-35.2, 15.8)
            )
            // Achilles tendon rising into sculpted gastrocnemius calf bulge
            backLeg.addCurve(
                to: map(-19.0, 43.0),
                control1: map(-28.0, 24.5),
                control2: map(-25.0, 34.5)
            )
            // Smooth back of knee & trailing hamstring up to glute
            backLeg.addCurve(
                to: map(-11.0, 72.0),
                control1: map(-16.2, 52.0),
                control2: map(-14.2, 62.0)
            )
            backLeg.closeSubpath()
            context.fill(
                backLeg,
                with: .linearGradient(
                    Gradient(colors: [asymmetryColor.opacity(0.50), stepColor.opacity(0.60)]),
                    startPoint: map(-5, 72),
                    endPoint: map(-25, 2)
                )
            )

            // C. Leading (front) leg — muscular thigh, smooth knee, sculpted calf, sleek heel-strike foot
            var frontLeg = Path()
            frontLeg.move(to: map(8.5, 73.0))
            // Quadriceps sweep to rounded knee
            frontLeg.addCurve(
                to: map(21.8, 41.0),
                control1: map(14.8, 62.0),
                control2: map(19.8, 51.0)
            )
            // Clean tibial shin down to ankle
            frontLeg.addCurve(
                to: map(32.5, 10.8),
                control1: map(24.8, 31.5),
                control2: map(29.2, 20.0)
            )
            // Sleek dorsal foot / shoe instep angled slightly upward at heel strike
            frontLeg.addCurve(
                to: map(46.0, 5.6),
                control1: map(37.5, 9.2),
                control2: map(43.2, 7.8)
            )
            // Rounded toe box curving under to sole & heel-strike contact
            frontLeg.addCurve(
                to: map(43.2, 1.8),
                control1: map(47.2, 3.8),
                control2: map(46.0, 2.0)
            )
            frontLeg.addCurve(
                to: map(28.5, 0.5),
                control1: map(38.0, 1.2),
                control2: map(32.5, 0.5)
            )
            // Rounded heel curving cleanly into Achilles tendon
            frontLeg.addCurve(
                to: map(26.2, 9.5),
                control1: map(25.6, 1.2),
                control2: map(25.2, 5.2)
            )
            // Sculpted gastrocnemius calf tapering smoothly into popliteal back of knee
            frontLeg.addCurve(
                to: map(13.2, 39.2),
                control1: map(22.8, 20.0),
                control2: map(16.8, 29.5)
            )
            // Smooth hamstring curve back to gluteal fold
            frontLeg.addCurve(
                to: map(-9.0, 68.0),
                control1: map(7.2, 49.5),
                control2: map(-2.2, 58.2)
            )
            frontLeg.closeSubpath()
            context.fill(
                frontLeg,
                with: .linearGradient(
                    Gradient(colors: [asymmetryColor, stepColor]),
                    startPoint: map(2, 74),
                    endPoint: map(34, 4)
                )
            )

            // D. Sculpted Head, Neck, Chest, Ribcage, Waist & Pelvis/Glute (continuous human profile)
            var headAndTorso = Path()
            headAndTorso.move(to: map(-9.2, 67.5))
            // Glute -> lumbar curve -> mid-back -> upper thoracic back
            headAndTorso.addCurve(
                to: map(-8.0, 86.5, pivotUpperBody: true),
                control1: map(-12.6, 74.8, pivotUpperBody: true),
                control2: map(-9.5, 81.0, pivotUpperBody: true)
            )
            headAndTorso.addCurve(
                to: map(-9.5, 112.5, pivotUpperBody: true),
                control1: map(-8.8, 96.0, pivotUpperBody: true),
                control2: map(-12.0, 105.0, pivotUpperBody: true)
            )
            // Upper trapezius into nape of neck
            headAndTorso.addCurve(
                to: map(-4.2, 124.2, pivotUpperBody: true),
                control1: map(-7.2, 117.8, pivotUpperBody: true),
                control2: map(-5.0, 120.5, pivotUpperBody: true)
            )
            // Fuller anatomical cranium (occiput -> smooth rounded crown -> forehead)
            headAndTorso.addCurve(
                to: map(-1.0, 145.5, pivotUpperBody: true),
                control1: map(-9.6, 130.0, pivotUpperBody: true),
                control2: map(-9.0, 144.8, pivotUpperBody: true)
            )
            headAndTorso.addCurve(
                to: map(6.8, 139.0, pivotUpperBody: true),
                control1: map(4.8, 145.8, pivotUpperBody: true),
                control2: map(7.0, 142.8, pivotUpperBody: true)
            )
            // Refined side profile: brow -> nose -> chin -> clean jawline
            headAndTorso.addLine(to: map(6.9, 136.5, pivotUpperBody: true))
            headAndTorso.addCurve(
                to: map(8.8, 133.4, pivotUpperBody: true),
                control1: map(7.8, 135.3, pivotUpperBody: true),
                control2: map(9.1, 134.2, pivotUpperBody: true)
            )
            headAndTorso.addCurve(
                to: map(7.0, 127.6, pivotUpperBody: true),
                control1: map(8.0, 132.0, pivotUpperBody: true),
                control2: map(7.9, 129.2, pivotUpperBody: true)
            )
            // Jawline -> throat -> clavicle
            headAndTorso.addCurve(
                to: map(2.6, 122.4, pivotUpperBody: true),
                control1: map(5.4, 126.2, pivotUpperBody: true),
                control2: map(3.2, 125.0, pivotUpperBody: true)
            )
            headAndTorso.addCurve(
                to: map(7.4, 113.5, pivotUpperBody: true),
                control1: map(2.6, 118.2, pivotUpperBody: true),
                control2: map(5.0, 115.2, pivotUpperBody: true)
            )
            // Athletic chest -> waist -> anterior hip
            headAndTorso.addCurve(
                to: map(9.4, 92.5, pivotUpperBody: true),
                control1: map(12.0, 108.0, pivotUpperBody: true),
                control2: map(11.8, 99.5, pivotUpperBody: true)
            )
            headAndTorso.addCurve(
                to: map(8.5, 72.5),
                control1: map(8.2, 85.0, pivotUpperBody: true),
                control2: map(9.2, 78.5, pivotUpperBody: true)
            )
            headAndTorso.addCurve(
                to: map(-9.2, 67.5),
                control1: map(4.0, 66.0),
                control2: map(-4.0, 65.5)
            )
            headAndTorso.closeSubpath()

            context.fill(
                headAndTorso,
                with: .linearGradient(
                    Gradient(stops: [
                        .init(color: steadinessColor, location: 0.0),
                        .init(color: steadinessColor, location: 0.62),
                        .init(color: asymmetryColor, location: 1.0)
                    ]),
                    startPoint: crownPt,
                    endPoint: pelvisPt
                )
            )

            // E. Near (right) arm — realistic upper-arm drop + crisp elbow bend swinging backward
            var nearArm = Path()
            // Rounded deltoid cap at shoulder
            nearArm.move(to: map(-2.2, 114.2, pivotUpperBody: true))
            // Posterior upper arm (tricep) descending cleanly to distinct bent elbow point
            nearArm.addCurve(
                to: map(-12.2, 90.0, pivotUpperBody: true),
                control1: map(-7.8, 109.5, pivotUpperBody: true),
                control2: map(-10.8, 99.2, pivotUpperBody: true)
            )
            // Elbow cap curving slightly downward-back along posterior forearm to wrist
            nearArm.addCurve(
                to: map(-23.2, 74.5, pivotUpperBody: true),
                control1: map(-15.5, 85.5, pivotUpperBody: true),
                control2: map(-20.0, 79.5, pivotUpperBody: true)
            )
            // Natural relaxed trailing hand
            nearArm.addCurve(
                to: map(-26.8, 68.5, pivotUpperBody: true),
                control1: map(-25.8, 72.5, pivotUpperBody: true),
                control2: map(-27.6, 70.2, pivotUpperBody: true)
            )
            nearArm.addCurve(
                to: map(-20.5, 70.2, pivotUpperBody: true),
                control1: map(-25.2, 66.8, pivotUpperBody: true),
                control2: map(-22.4, 68.2, pivotUpperBody: true)
            )
            // Anterior forearm rising to crisp inner elbow crease
            nearArm.addCurve(
                to: map(-6.8, 88.2, pivotUpperBody: true),
                control1: map(-15.8, 75.8, pivotUpperBody: true),
                control2: map(-10.5, 82.8, pivotUpperBody: true)
            )
            // Bicep rising cleanly back into shoulder/deltoid
            nearArm.addCurve(
                to: map(2.6, 107.2, pivotUpperBody: true),
                control1: map(-2.6, 94.5, pivotUpperBody: true),
                control2: map(1.2, 100.8, pivotUpperBody: true)
            )
            nearArm.addCurve(
                to: map(-2.2, 114.2, pivotUpperBody: true),
                control1: map(3.2, 111.5, pivotUpperBody: true),
                control2: map(0.8, 114.8, pivotUpperBody: true)
            )
            nearArm.closeSubpath()

            // Crisp separation rim where near arm overlaps torso
            context.stroke(
                nearArm,
                with: .color(AppTheme.Colors.insetSurface.opacity(0.70)),
                style: StrokeStyle(lineWidth: 2.0, lineCap: .round, lineJoin: .round)
            )
            context.fill(
                nearArm,
                with: .linearGradient(
                    Gradient(colors: [steadinessColor, steadinessColor.opacity(0.88)]),
                    startPoint: map(-2, 114, pivotUpperBody: true),
                    endPoint: map(-26, 69, pivotUpperBody: true)
                )
            )

            // 8. Inclination indicator needle & biomechanical motion-capture joint nodes
            let needleAngle = Angle.degrees(-90 + clampedInclination * 38.0)
            let needleTip = CGPoint(
                x: pelvisPt.x + cos(needleAngle.radians) * (arcRadius + 4.0),
                y: pelvisPt.y + sin(needleAngle.radians) * (arcRadius + 4.0)
            )
            var needle = Path()
            needle.move(to: pelvisPt)
            needle.addLine(to: needleTip)
            context.stroke(
                needle,
                with: .color(asymmetryColor.opacity(0.90)),
                style: StrokeStyle(lineWidth: 1.75, lineCap: .round)
            )

            // Subtle crisp dot at tip of inclination needle on the arc
            context.fill(
                Path(ellipseIn: CGRect(x: needleTip.x - 2.2, y: needleTip.y - 2.2, width: 4.4, height: 4.4)),
                with: .color(asymmetryColor)
            )

            // Crisp biomechanical motion-capture joint nodes (shoulder, pelvis, front knee)
            let jointNodes: [(CGPoint, Color, CGFloat)] = [
                (shoulderPt, steadinessColor, 2.7),
                (pelvisPt, asymmetryColor, 3.5),
                (map(17.5, 40.5), stepColor, 2.5)
            ]
            for (pt, tint, r) in jointNodes {
                context.fill(
                    Path(ellipseIn: CGRect(x: pt.x - r - 1.2, y: pt.y - r - 1.2, width: (r + 1.2) * 2, height: (r + 1.2) * 2)),
                    with: .color(AppTheme.Colors.cardSurface.opacity(0.85))
                )
                context.fill(
                    Path(ellipseIn: CGRect(x: pt.x - r, y: pt.y - r, width: r * 2, height: r * 2)),
                    with: .color(tint)
                )
            }
        }
    }

    private func zoneColor(for kind: GaitMetricKind) -> Color {
        let base = summary.metric(for: kind).tier.color
        let isNoData = summary.metric(for: kind).tier == .noData
        let dimmedByFocus = focusedMetric != nil && focusedMetric != kind
        if dimmedByFocus {
            return base.opacity(0.24)
        }
        return isNoData ? base.opacity(0.45) : base
    }
}
