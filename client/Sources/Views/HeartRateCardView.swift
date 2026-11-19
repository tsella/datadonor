import SwiftUI
import Charts

struct HeartRateSamplePoint: Equatable, Sendable {
    let date: Date
    let bpm: Double
}

struct HeartRateBucket: Identifiable, Equatable, Sendable, Codable {
    var id: TimeInterval { date.timeIntervalSince1970 }
    let date: Date
    let minBPM: Double
    let maxBPM: Double
    let avgBPM: Double
    let count: Int
    /// Breaks `LineMark`/`AreaMark` cleanly across multi-bucket wearing gaps (e.g. Watch charging).
    let segmentId: Int
}

struct HeartRate24hSummary: Equatable, Sendable, Codable {
    let windowStart: Date
    let windowEnd: Date
    let buckets: [HeartRateBucket]
    let latestBPM: Double?
    let minBPM: Double?
    let maxBPM: Double?
    let restingHeartRateBPM: Double?
    let hrvMilliseconds: Double?
    let hrvIs24hAverage: Bool
    /// Precomputed once off-MainActor so SwiftUI chart rendering does zero per-frame math.
    let yAxisDomain: ClosedRange<Double>

    func nearestBucket(to date: Date, maxDistance: TimeInterval = 45 * 60) -> HeartRateBucket? {
        guard !buckets.isEmpty else { return nil }
        // Binary search on sorted bucket dates in O(log B).
        var low = 0
        var high = buckets.count - 1
        while low < high {
            let mid = (low + high) / 2
            if buckets[mid].date < date {
                low = mid + 1
            } else {
                high = mid
            }
        }
        let candidate: HeartRateBucket
        if low == 0 {
            candidate = buckets[0]
        } else {
            let before = buckets[low - 1]
            let after = buckets[low]
            candidate = abs(before.date.timeIntervalSince(date)) <= abs(after.date.timeIntervalSince(date)) ? before : after
        }
        return abs(candidate.date.timeIntervalSince(date)) <= maxDistance ? candidate : nil
    }

    static func build(
        samples: [HeartRateSamplePoint],
        restingHeartRateBPM: Double?,
        hrvSamples24h: [Double],
        fallbackHRV: Double?,
        windowEnd: Date,
        bucketInterval: TimeInterval = 15 * 60,
        gapBreakThreshold: TimeInterval = 45 * 60
    ) -> HeartRate24hSummary {
        let windowStart = windowEnd.addingTimeInterval(-24 * 60 * 60)
        let inWindow = samples
            .filter { $0.date >= windowStart && $0.date <= windowEnd }
            .sorted { $0.date < $1.date }

        let latestBPM = inWindow.last?.bpm
        let minBPM = inWindow.map(\.bpm).min()
        let maxBPM = inWindow.map(\.bpm).max()

        var grouped: [Int: [Double]] = [:]
        for sample in inWindow {
            let index = max(0, Int(sample.date.timeIntervalSince(windowStart) / bucketInterval))
            grouped[index, default: []].append(sample.bpm)
        }

        let sortedIndices = grouped.keys.sorted()
        var buckets: [HeartRateBucket] = []
        buckets.reserveCapacity(sortedIndices.count)

        var segmentId = 0
        var previousDate: Date?
        for index in sortedIndices {
            guard let values = grouped[index], !values.isEmpty else { continue }
            let bucketDate = windowStart.addingTimeInterval((Double(index) + 0.5) * bucketInterval)
            if let prev = previousDate, bucketDate.timeIntervalSince(prev) > gapBreakThreshold {
                segmentId += 1
            }
            previousDate = bucketDate

            let lo = values.min() ?? values[0]
            let hi = values.max() ?? values[0]
            let avg = values.reduce(0, +) / Double(values.count)
            buckets.append(HeartRateBucket(
                date: bucketDate,
                minBPM: lo,
                maxBPM: hi,
                avgBPM: avg,
                count: values.count,
                segmentId: segmentId
            ))
        }

        let hrvAvg: Double?
        let is24hAvg: Bool
        if !hrvSamples24h.isEmpty {
            hrvAvg = hrvSamples24h.reduce(0, +) / Double(hrvSamples24h.count)
            is24hAvg = true
        } else {
            hrvAvg = fallbackHRV
            is24hAvg = false
        }

        var domainLow = minBPM ?? 50
        var domainHigh = maxBPM ?? 110
        if let rhr = restingHeartRateBPM {
            domainLow = min(domainLow, rhr)
            domainHigh = max(domainHigh, rhr)
        }
        let paddedLow = max(30, floor((domainLow - 8) / 10) * 10)
        let paddedHigh = max(paddedLow + 20, ceil((domainHigh + 8) / 10) * 10)

        return HeartRate24hSummary(
            windowStart: windowStart,
            windowEnd: windowEnd,
            buckets: buckets,
            latestBPM: latestBPM,
            minBPM: minBPM,
            maxBPM: maxBPM,
            restingHeartRateBPM: restingHeartRateBPM,
            hrvMilliseconds: hrvAvg,
            hrvIs24hAverage: is24hAvg,
            yAxisDomain: paddedLow...paddedHigh
        )
    }
}

struct HeartRateCardView: View {
    let summary: HeartRate24hSummary?
    let isAuthorized: Bool
    let isLoading: Bool

    @AppStorage("cardCollapsed_heartRate") private var isCollapsed = false
    @State private var selectedBucket: HeartRateBucket?

    var body: some View {
        CollapsibleCard(isCollapsed: $isCollapsed, accessibilityTitle: "Heart Rate") {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 7) {
                    Image(systemName: "heart.fill")
                        .font(.subheadline)
                        .foregroundColor(AppTheme.Colors.coral)
                    Text("Heart Rate")
                        .font(.system(.headline, design: .rounded))
                        .foregroundColor(.primary)
                }

                Text(subtitleText)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .monospacedDigit()
            }
        } headerTrailing: {
            if let readout = headerReadout {
                HStack(alignment: .firstTextBaseline, spacing: 3) {
                    Text(readout)
                        .font(.system(.title3, design: .rounded).weight(.bold))
                        .foregroundColor(AppTheme.Colors.coral)
                        .monospacedDigit()
                        .contentTransition(.numericText())
                    Text("bpm")
                        .font(.caption.weight(.medium))
                        .foregroundColor(.secondary)
                }
                .padding(.top, 1)
                .animation(AppTheme.Animations.readoutUpdate, value: readout)
            }
        } content: {
            if !isAuthorized {
                Text("Grant Health access to view your last 24 hours of heart rate, RHR, and HRV.")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .padding(.vertical, 8)
            } else {
                HStack(spacing: 12) {
                    indicatorCard(
                        title: "RHR",
                        icon: "heart.text.square.fill",
                        tint: AppTheme.Colors.slateTeal,
                        value: summary?.restingHeartRateBPM.map { "\(Int($0.rounded()))" } ?? "—",
                        unit: summary?.restingHeartRateBPM != nil ? "bpm" : "",
                        caption: "Resting"
                    )

                    indicatorCard(
                        title: "HRV",
                        icon: "waveform.path.ecg",
                        tint: AppTheme.Colors.emerald,
                        value: summary?.hrvMilliseconds.map { "\(Int($0.rounded()))" } ?? "—",
                        unit: summary?.hrvMilliseconds != nil ? "ms" : "",
                        caption: (summary?.hrvIs24hAverage ?? true) ? "24h avg" : "Latest"
                    )
                }

                if let summary, !summary.buckets.isEmpty {
                    heartRateChart(summary)
                        .frame(height: 205)

                    HStack(spacing: 14) {
                        legendChip(color: AppTheme.Colors.coral, label: "Heart Rate", isDashed: false)
                        if summary.restingHeartRateBPM != nil {
                            legendChip(color: AppTheme.Colors.slateTeal, label: "RHR", isDashed: true)
                        }
                        Spacer()
                        Text(selectedBucket == nil ? "Drag to inspect" : selectedSampleCountLabel)
                            .font(.caption2)
                            .foregroundColor(.secondary.opacity(0.85))
                            .monospacedDigit()
                    }
                    .padding(.top, 2)
                } else if isLoading {
                    HStack {
                        Spacer()
                        ProgressView()
                            .padding(.vertical, 52)
                        Spacer()
                    }
                } else {
                    Text("No heart rate samples recorded in the last 24 hours.")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.vertical, 40)
                }
            }
        }
    }

    private var headerReadout: String? {
        if let bucket = selectedBucket {
            return "\(Int(bucket.avgBPM.rounded()))"
        }
        return summary?.latestBPM.map { "\(Int($0.rounded()))" }
    }

    private var subtitleText: String {
        if let bucket = selectedBucket {
            let time = bucket.date.formatted(date: .omitted, time: .shortened)
            let lo = Int(bucket.minBPM.rounded())
            let hi = Int(bucket.maxBPM.rounded())
            return lo == hi ? "\(time) · \(lo) bpm" : "\(time) · \(lo)–\(hi) bpm"
        }
        if let minBPM = summary?.minBPM, let maxBPM = summary?.maxBPM {
            return "\(Int(minBPM.rounded()))–\(Int(maxBPM.rounded())) bpm · Last 24h"
        }
        return "Last 24 hours"
    }

    private var selectedSampleCountLabel: String {
        guard let bucket = selectedBucket else { return "" }
        return "\(bucket.count) sample\(bucket.count == 1 ? "" : "s")"
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

    private func indicatorCard(
        title: String,
        icon: String,
        tint: Color,
        value: String,
        unit: String,
        caption: String
    ) -> some View {
        HStack(spacing: 11) {
            ZStack {
                RoundedRectangle(cornerRadius: AppTheme.Layout.chipCornerRadius, style: .continuous)
                    .fill(tint.opacity(0.15))
                    .frame(width: 34, height: 34)
                Image(systemName: icon)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(tint)
            }

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(title)
                        .font(.caption.weight(.semibold))
                        .foregroundColor(.primary.opacity(0.8))
                    Text("· \(caption)")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }

                HStack(alignment: .firstTextBaseline, spacing: 3) {
                    Text(value)
                        .font(.system(.title3, design: .rounded).weight(.bold))
                        .foregroundColor(.primary)
                        .monospacedDigit()
                        .contentTransition(.numericText())
                    if !unit.isEmpty {
                        Text(unit)
                            .font(.caption2.weight(.medium))
                            .foregroundColor(.secondary)
                    }
                }
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: AppTheme.Layout.insetCornerRadius, style: .continuous)
                .fill(AppTheme.Colors.insetSurface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: AppTheme.Layout.insetCornerRadius, style: .continuous)
                .strokeBorder(tint.opacity(0.16), lineWidth: 1)
        )
    }

    private func heartRateChart(_ data: HeartRate24hSummary) -> some View {
        let yFloor = data.yAxisDomain.lowerBound
        let latestBucket = data.buckets.last

        return Chart {
            ForEach(data.buckets) { bucket in
                AreaMark(
                    x: .value("Time", bucket.date),
                    yStart: .value("Floor", yFloor),
                    yEnd: .value("Avg", bucket.avgBPM),
                    series: .value("Segment", bucket.segmentId)
                )
                .interpolationMethod(.catmullRom)
                .foregroundStyle(AppTheme.Colors.heartAreaGradient)
            }

            if let rhr = data.restingHeartRateBPM {
                RuleMark(y: .value("RHR", rhr))
                    .foregroundStyle(AppTheme.Colors.slateTeal.opacity(0.75))
                    .lineStyle(StrokeStyle(lineWidth: 1.25, dash: [4, 4]))
                    .annotation(position: .top, alignment: .leading, spacing: 3) {
                        Text("RHR \(Int(rhr.rounded()))")
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

            ForEach(data.buckets) { bucket in
                let isHighlighted = (selectedBucket?.id == bucket.id)

                if bucket.maxBPM - bucket.minBPM >= 1.5 {
                    BarMark(
                        x: .value("Time", bucket.date),
                        yStart: .value("Min", bucket.minBPM),
                        yEnd: .value("Max", bucket.maxBPM),
                        width: .fixed(isHighlighted ? 6 : 4)
                    )
                    .foregroundStyle(
                        isHighlighted
                            ? AppTheme.Colors.heartRangeHighlightedGradient
                            : AppTheme.Colors.heartRangeGradient
                    )
                    .cornerRadius(3)
                }

                LineMark(
                    x: .value("Time", bucket.date),
                    y: .value("Avg", bucket.avgBPM),
                    series: .value("Segment", bucket.segmentId)
                )
                .foregroundStyle(AppTheme.Colors.heartLineGradient)
                .lineStyle(StrokeStyle(lineWidth: 2.4, lineCap: .round, lineJoin: .round))
                .interpolationMethod(.catmullRom)
            }

            if selectedBucket == nil, let latest = latestBucket {
                PointMark(
                    x: .value("Time", latest.date),
                    y: .value("Avg", latest.avgBPM)
                )
                .foregroundStyle(AppTheme.Colors.coral.opacity(0.22))
                .symbolSize(140)

                PointMark(
                    x: .value("Time", latest.date),
                    y: .value("Avg", latest.avgBPM)
                )
                .foregroundStyle(AppTheme.Colors.coral)
                .symbolSize(34)
            }

            if let selected = selectedBucket {
                RuleMark(x: .value("Selected", selected.date))
                    .foregroundStyle(AppTheme.Colors.coral.opacity(0.45))
                    .lineStyle(StrokeStyle(lineWidth: 1.25))

                PointMark(
                    x: .value("Time", selected.date),
                    y: .value("Avg", selected.avgBPM)
                )
                .foregroundStyle(AppTheme.Colors.cardSurface)
                .symbolSize(90)

                PointMark(
                    x: .value("Time", selected.date),
                    y: .value("Avg", selected.avgBPM)
                )
                .foregroundStyle(AppTheme.Colors.coralDeep)
                .symbolSize(42)
            }
        }
        .chartXScale(domain: data.windowStart...data.windowEnd)
        .chartYScale(domain: data.yAxisDomain)
        .chartXAxis {
            AxisMarks(values: .stride(by: .hour, count: 6)) { value in
                AxisGridLine(stroke: AppTheme.Layout.gridStroke)
                    .foregroundStyle(AppTheme.Colors.gridLine)
                AxisValueLabel(anchor: .top) {
                    if let date = value.as(Date.self) {
                        Text(date.formatted(.dateTime.hour(.defaultDigits(amPM: .abbreviated))))
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
                    if let bpm = value.as(Double.self) {
                        Text("\(Int(bpm.rounded()))")
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
                    let nearest = data.nearestBucket(to: date)
                    if nearest != selectedBucket {
                        selectedBucket = nearest
                    }
                },
                onEnd: {
                    if selectedBucket != nil {
                        withAnimation(AppTheme.Animations.scrubRelease) {
                            selectedBucket = nil
                        }
                    }
                }
            )
        }
    }
}
