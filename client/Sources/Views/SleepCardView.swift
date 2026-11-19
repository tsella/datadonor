import SwiftUI
import Charts
import HealthKit

enum SleepStageKind: Int, CaseIterable, Equatable, Sendable, Codable {
    case awake = 0
    case rem = 1
    case core = 2
    case deep = 3

    static let orderedLabels: [String] = allCases.map(\.label)

    var label: String {
        switch self {
        case .awake: return "Awake"
        case .rem: return "REM"
        case .core: return "Core"
        case .deep: return "Deep"
        }
    }

    var color: Color {
        switch self {
        case .awake: return AppTheme.Colors.sleepAwake
        case .rem: return AppTheme.Colors.sleepREM
        case .core: return AppTheme.Colors.sleepCore
        case .deep: return AppTheme.Colors.sleepDeep
        }
    }

    var isAsleep: Bool {
        self != .awake
    }

    /// Maps `HKCategoryValueSleepAnalysis` raw values to chartable stages.
    /// Returns `nil` for `.inBed` (0), which represents time in bed rather than a sleep stage.
    static func from(categoryValue: Int) -> SleepStageKind? {
        switch categoryValue {
        case HKCategoryValueSleepAnalysis.awake.rawValue:
            return .awake
        case HKCategoryValueSleepAnalysis.asleepREM.rawValue:
            return .rem
        case HKCategoryValueSleepAnalysis.asleepCore.rawValue,
             HKCategoryValueSleepAnalysis.asleepUnspecified.rawValue:
            return .core
        case HKCategoryValueSleepAnalysis.asleepDeep.rawValue:
            return .deep
        default:
            return nil
        }
    }

    static func isGranularStage(categoryValue: Int) -> Bool {
        categoryValue == HKCategoryValueSleepAnalysis.asleepREM.rawValue ||
        categoryValue == HKCategoryValueSleepAnalysis.asleepCore.rawValue ||
        categoryValue == HKCategoryValueSleepAnalysis.asleepDeep.rawValue
    }
}

struct RawSleepSample: Equatable, Sendable {
    let startDate: Date
    let endDate: Date
    let categoryValue: Int
    let sourceKey: String
    let isWatchSource: Bool
}

struct SleepSegment: Identifiable, Equatable, Sendable, Codable {
    var id: String { "\(stage.rawValue)-\(Int(start.timeIntervalSince1970))-\(Int(end.timeIntervalSince1970))" }
    let start: Date
    let end: Date
    let stage: SleepStageKind

    var duration: TimeInterval {
        max(0, end.timeIntervalSince(start))
    }
}

struct SleepStageShare: Identifiable, Equatable, Sendable, Codable {
    var id: Int { stage.rawValue }
    let stage: SleepStageKind
    let ratio: Double
}

struct Sleep24hSummary: Equatable, Sendable, Codable {
    let windowStart: Date
    let windowEnd: Date
    let sessionStart: Date?
    let sessionEnd: Date?
    let segments: [SleepSegment]
    let totalAsleepSeconds: TimeInterval
    let awakeSeconds: TimeInterval
    let remSeconds: TimeInterval
    let coreSeconds: TimeInterval
    let deepSeconds: TimeInterval
    let selectedSourceName: String?
    /// True only when the selected source recorded granular sleep stages (Core/Deep/REM)
    /// rather than coarse `.asleepUnspecified` intervals.
    let hasGranularStages: Bool
    /// Precomputed once off-MainActor for smooth rendering.
    let chartDomain: ClosedRange<Date>
    let distributionShares: [SleepStageShare]

    var totalAsleepHours: Double {
        totalAsleepSeconds / 3600.0
    }

    var restorativeShare: Double? {
        guard hasGranularStages, totalAsleepSeconds > 0 else { return nil }
        return (remSeconds + deepSeconds) / totalAsleepSeconds
    }

    var efficiency: Double? {
        let span = totalAsleepSeconds + awakeSeconds
        guard span > 0, totalAsleepSeconds > 0 else { return nil }
        return totalAsleepSeconds / span
    }

    func segment(at date: Date) -> SleepSegment? {
        if let exact = segments.first(where: { date >= $0.start && date <= $0.end }) {
            return exact
        }
        return segments.min { lhs, rhs in
            let d1 = min(abs(lhs.start.timeIntervalSince(date)), abs(lhs.end.timeIntervalSince(date)))
            let d2 = min(abs(rhs.start.timeIntervalSince(date)), abs(rhs.end.timeIntervalSince(date)))
            return d1 < d2
        }
    }

    static func formatDuration(_ seconds: TimeInterval) -> String {
        let totalMinutes = max(0, Int((seconds / 60.0).rounded()))
        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60
        if hours > 0 && minutes > 0 {
            return "\(hours)h \(minutes)m"
        } else if hours > 0 {
            return "\(hours)h"
        } else {
            return "\(minutes)m"
        }
    }

    /// Merges overlapping `[start, end]` intervals and returns merged ranges.
    static func mergeIntervals(_ intervals: [(Date, Date)]) -> [(Date, Date)] {
        let valid = intervals.filter { $0.1 > $0.0 }.sorted { $0.0 < $1.0 }
        guard !valid.isEmpty else { return [] }
        var merged: [(Date, Date)] = [valid[0]]
        for (start, end) in valid.dropFirst() {
            let lastIndex = merged.count - 1
            if start <= merged[lastIndex].1 {
                merged[lastIndex].1 = max(merged[lastIndex].1, end)
            } else {
                merged.append((start, end))
            }
        }
        return merged
    }

    /// Deduplicates multi-writer sleep samples (e.g. Watch + Oura + iPhone Clock), clips to
    /// the last 24h window, and union-merges overlapping intervals so sleep is never double-counted.
    static func build(samples: [RawSleepSample], windowEnd: Date) -> Sleep24hSummary {
        let windowStart = windowEnd.addingTimeInterval(-24 * 60 * 60)

        struct ClippedSample {
            let start: Date
            let end: Date
            let stage: SleepStageKind
            let isGranular: Bool
            let isWatchSource: Bool
        }

        var bySource: [String: [ClippedSample]] = [:]
        for sample in samples {
            guard let stage = SleepStageKind.from(categoryValue: sample.categoryValue) else { continue }
            let clippedStart = max(sample.startDate, windowStart)
            let clippedEnd = min(sample.endDate, windowEnd)
            guard clippedEnd > clippedStart else { continue }
            bySource[sample.sourceKey, default: []].append(ClippedSample(
                start: clippedStart,
                end: clippedEnd,
                stage: stage,
                isGranular: SleepStageKind.isGranularStage(categoryValue: sample.categoryValue),
                isWatchSource: sample.isWatchSource
            ))
        }

        let chosenKey: String? = bySource.keys.max { lhs, rhs in
            let lSamples = bySource[lhs] ?? []
            let rSamples = bySource[rhs] ?? []

            let lRank = (lSamples.contains(where: \.isGranular) ? 2 : 0) + (lSamples.contains(where: \.isWatchSource) ? 1 : 0)
            let rRank = (rSamples.contains(where: \.isGranular) ? 2 : 0) + (rSamples.contains(where: \.isWatchSource) ? 1 : 0)
            if lRank != rRank { return lRank < rRank }

            let lAsleep = mergeIntervals(lSamples.filter { $0.stage.isAsleep }.map { ($0.start, $0.end) })
                .reduce(0.0) { $0 + $1.1.timeIntervalSince($1.0) }
            let rAsleep = mergeIntervals(rSamples.filter { $0.stage.isAsleep }.map { ($0.start, $0.end) })
                .reduce(0.0) { $0 + $1.1.timeIntervalSince($1.0) }
            return lAsleep < rAsleep
        }

        guard let chosenKey, let chosen = bySource[chosenKey], !chosen.isEmpty else {
            return Sleep24hSummary(
                windowStart: windowStart,
                windowEnd: windowEnd,
                sessionStart: nil,
                sessionEnd: nil,
                segments: [],
                totalAsleepSeconds: 0,
                awakeSeconds: 0,
                remSeconds: 0,
                coreSeconds: 0,
                deepSeconds: 0,
                selectedSourceName: nil,
                hasGranularStages: false,
                chartDomain: windowStart...windowEnd,
                distributionShares: []
            )
        }

        var segments: [SleepSegment] = []
        var totals: [SleepStageKind: TimeInterval] = [:]
        for stage in SleepStageKind.allCases {
            let stageIntervals = chosen.filter { $0.stage == stage }.map { ($0.start, $0.end) }
            let merged = mergeIntervals(stageIntervals)
            var sum: TimeInterval = 0
            for (s, e) in merged {
                sum += e.timeIntervalSince(s)
                segments.append(SleepSegment(start: s, end: e, stage: stage))
            }
            totals[stage] = sum
        }
        segments.sort { $0.start < $1.start }

        let allAsleepMerged = mergeIntervals(
            chosen.filter { $0.stage.isAsleep }.map { ($0.start, $0.end) }
        )
        let totalAsleep = allAsleepMerged.reduce(0.0) { $0 + $1.1.timeIntervalSince($1.0) }

        let sessionStart = segments.map(\.start).min()
        let sessionEnd = segments.map(\.end).max()
        let domain: ClosedRange<Date>
        if let start = sessionStart, let end = sessionEnd, end > start {
            let pad = max(5 * 60, end.timeIntervalSince(start) * 0.03)
            domain = start.addingTimeInterval(-pad)...end.addingTimeInterval(pad)
        } else {
            domain = windowStart...windowEnd
        }

        let deep = totals[.deep] ?? 0
        let core = totals[.core] ?? 0
        let rem = totals[.rem] ?? 0
        let awake = totals[.awake] ?? 0
        let totalAll = max(1, deep + core + rem + awake)
        let shares: [SleepStageShare] = [
            SleepStageShare(stage: .deep, ratio: deep / totalAll),
            SleepStageShare(stage: .core, ratio: core / totalAll),
            SleepStageShare(stage: .rem, ratio: rem / totalAll),
            SleepStageShare(stage: .awake, ratio: awake / totalAll)
        ].filter { $0.ratio > 0.005 }

        let hasGranular = chosen.contains(where: \.isGranular)

        return Sleep24hSummary(
            windowStart: windowStart,
            windowEnd: windowEnd,
            sessionStart: sessionStart,
            sessionEnd: sessionEnd,
            segments: segments,
            totalAsleepSeconds: totalAsleep,
            awakeSeconds: awake,
            remSeconds: rem,
            coreSeconds: core,
            deepSeconds: deep,
            selectedSourceName: chosenKey,
            hasGranularStages: hasGranular,
            chartDomain: domain,
            distributionShares: shares
        )
    }
}

struct SleepCardView: View {
    let summary: Sleep24hSummary?
    let isAuthorized: Bool
    let isLoading: Bool

    @AppStorage("cardCollapsed_sleep") private var isCollapsed = false
    @State private var selectedSegment: SleepSegment?

    var body: some View {
        CollapsibleCard(isCollapsed: $isCollapsed, accessibilityTitle: "Sleep") {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 7) {
                    Image(systemName: "bed.double.fill")
                        .font(.subheadline)
                        .foregroundColor(AppTheme.Colors.sleepCore)
                    Text("Sleep")
                        .font(.system(.headline, design: .rounded))
                        .foregroundColor(.primary)
                }

                Text(subtitleText)
                    .font(.caption)
                    .foregroundColor(selectedSegment?.stage.color ?? .secondary)
                    .monospacedDigit()
            }
        } headerTrailing: {
            if let summary, summary.totalAsleepSeconds > 0 {
                Text(selectedSegment.map { Sleep24hSummary.formatDuration($0.duration) }
                     ?? Sleep24hSummary.formatDuration(summary.totalAsleepSeconds))
                    .font(.system(.title3, design: .rounded).weight(.bold))
                    .foregroundColor(selectedSegment?.stage.color ?? AppTheme.Colors.sleepCore)
                    .monospacedDigit()
                    .contentTransition(.numericText())
                    .padding(.top, 1)
                    .animation(AppTheme.Animations.readoutUpdate, value: selectedSegment?.id)
            }
        } content: {
            if !isAuthorized {
                Text("Grant Health access to view your last 24 hours of sleep stages.")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .padding(.vertical, 8)
            } else if let summary, !summary.segments.isEmpty {
                sleepHypnogramChart(summary)
                    .frame(height: 175)

                stageDistributionBar(summary.distributionShares)

                HStack(spacing: 8) {
                    stageChip(.deep, seconds: summary.deepSeconds)
                    stageChip(.core, seconds: summary.coreSeconds)
                    stageChip(.rem, seconds: summary.remSeconds)
                    stageChip(.awake, seconds: summary.awakeSeconds)
                }

                HStack {
                    if let efficiency = summary.efficiency {
                        Text("Efficiency \(Int((efficiency * 100).rounded()))%")
                            .font(.caption2.weight(.medium))
                            .foregroundColor(.secondary)
                            .monospacedDigit()
                    }
                    Spacer()
                    Text(selectedSegment == nil ? "Hold & drag to inspect stages" : (selectedSegment?.stage.label ?? ""))
                        .font(.caption2)
                        .foregroundColor(.secondary.opacity(0.85))
                }
            } else if isLoading {
                HStack {
                    Spacer()
                    ProgressView()
                        .padding(.vertical, 48)
                    Spacer()
                }
            } else {
                Text("No sleep recorded in the last 24 hours.")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 36)
            }
        }
    }

    private var subtitleText: String {
        if let seg = selectedSegment {
            let startStr = seg.start.formatted(date: .omitted, time: .shortened)
            let endStr = seg.end.formatted(date: .omitted, time: .shortened)
            return "\(seg.stage.label) · \(startStr) – \(endStr)"
        }
        if let start = summary?.sessionStart, let end = summary?.sessionEnd {
            let startStr = start.formatted(date: .omitted, time: .shortened)
            let endStr = end.formatted(date: .omitted, time: .shortened)
            return "\(startStr) – \(endStr) · Last 24h"
        }
        return "Last 24 hours"
    }

    private func sleepHypnogramChart(_ data: Sleep24hSummary) -> some View {
        Chart {
            if let selected = selectedSegment {
                RuleMark(x: .value("Selected", selected.start.addingTimeInterval(selected.duration / 2)))
                    .foregroundStyle(selected.stage.color.opacity(0.45))
                    .lineStyle(StrokeStyle(lineWidth: 1.25, dash: [3, 3]))
            }

            ForEach(data.segments) { seg in
                let isDimmed = (selectedSegment != nil && selectedSegment?.id != seg.id)
                BarMark(
                    xStart: .value("Start", seg.start),
                    xEnd: .value("End", seg.end),
                    y: .value("Stage", seg.stage.label),
                    height: .fixed(18)
                )
                .foregroundStyle(AppTheme.Colors.barGradient(for: seg.stage.color, dimmed: isDimmed))
                .cornerRadius(6)
            }
        }
        .chartYScale(domain: SleepStageKind.orderedLabels)
        .chartXScale(domain: data.chartDomain)
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 4)) { value in
                AxisGridLine(stroke: AppTheme.Layout.gridStroke)
                    .foregroundStyle(AppTheme.Colors.gridLine)
                AxisValueLabel(anchor: .top) {
                    if let date = value.as(Date.self) {
                        Text(date.formatted(date: .omitted, time: .shortened))
                            .font(.system(size: 10, weight: .medium, design: .rounded))
                            .foregroundColor(.secondary)
                    }
                }
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading) { value in
                AxisGridLine(stroke: AppTheme.Layout.gridStroke)
                    .foregroundStyle(AppTheme.Colors.gridLineSoft)
                AxisValueLabel {
                    if let label = value.as(String.self) {
                        Text(label)
                            .font(.system(size: 10, weight: .semibold, design: .rounded))
                            .foregroundColor(.secondary)
                    }
                }
            }
        }
        .chartLegend(.hidden)
        .chartOverlay { proxy in
            DateChartScrubOverlay(
                proxy: proxy,
                onScrubDate: { date in
                    let hit = data.segment(at: date)
                    if hit != selectedSegment {
                        selectedSegment = hit
                    }
                },
                onEnd: {
                    if selectedSegment != nil {
                        withAnimation(AppTheme.Animations.scrubRelease) {
                            selectedSegment = nil
                        }
                    }
                }
            )
        }
    }

    private func stageDistributionBar(_ shares: [SleepStageShare]) -> some View {
        GeometryReader { geo in
            HStack(spacing: 2) {
                ForEach(shares) { part in
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(part.stage.color)
                        .frame(width: max(4, (geo.size.width - CGFloat(max(0, shares.count - 1)) * 2) * part.ratio))
                }
            }
        }
        .frame(height: 8)
    }

    private func stageChip(_ stage: SleepStageKind, seconds: TimeInterval) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                Circle()
                    .fill(stage.color)
                    .frame(width: 6, height: 6)
                Text(stage.label)
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .foregroundColor(.secondary)
            }
            Text(seconds > 0 ? Sleep24hSummary.formatDuration(seconds) : "—")
                .font(.system(size: 12, weight: .bold, design: .rounded))
                .foregroundColor(.primary)
                .monospacedDigit()
                .lineLimit(1)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: AppTheme.Layout.chipCornerRadius, style: .continuous)
                .fill(AppTheme.Colors.insetSurface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: AppTheme.Layout.chipCornerRadius, style: .continuous)
                .strokeBorder(stage.color.opacity(0.14), lineWidth: 1)
        )
    }
}
