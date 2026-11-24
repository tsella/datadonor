import SwiftUI
import Charts
import HealthKit

struct HeartRateSamplePoint: Equatable, Sendable {
    let date: Date
    let bpm: Double
}

struct HeartRateWorkoutWindow: Identifiable, Equatable, Sendable, Codable {
    var id: String { "\(activityName)-\(Int(start.timeIntervalSince1970))-\(Int(end.timeIntervalSince1970))" }
    let start: Date
    let end: Date
    let activityName: String
    let symbolName: String
    let durationMinutes: Int
    let activeKilocalories: Int?

    var midpoint: Date {
        start.addingTimeInterval(end.timeIntervalSince(start) / 2.0)
    }

    static func descriptor(for activityType: HKWorkoutActivityType) -> (name: String, symbol: String) {
        switch activityType {
        case .running: return ("Run", "figure.run")
        case .walking: return ("Walk", "figure.walk")
        case .cycling: return ("Cycle", "bicycle")
        case .traditionalStrengthTraining, .functionalStrengthTraining:
            return ("Strength", "dumbbell.fill")
        case .crossTraining: return ("Cross Train", "figure.cross.training")
        case .rowing: return ("Row", "figure.rower")
        case .yoga: return ("Yoga", "figure.yoga")
        case .swimming: return ("Swim", "figure.pool.swim")
        case .hiking: return ("Hike", "figure.hiking")
        case .mixedCardio, .highIntensityIntervalTraining:
            return ("Cardio", "flame.fill")
        case .preparationAndRecovery, .cooldown, .flexibility:
            return ("Recovery", "figure.cooldown")
        default:
            return ("Workout", "figure.mixed.cardio")
        }
    }
}

struct HeartRateSleepWindow: Identifiable, Equatable, Sendable, Codable {
    var id: String { "sleep-\(Int(start.timeIntervalSince1970))-\(Int(end.timeIntervalSince1970))" }
    let start: Date
    let end: Date
    let asleepSeconds: TimeInterval

    var midpoint: Date {
        start.addingTimeInterval(end.timeIntervalSince(start) / 2.0)
    }

    /// Groups asleep `SleepSegment`s into continuous sleep windows, bridging brief
    /// mid-sleep awakenings up to `maxGap` while keeping separate naps distinct.
    static func windows(
        from segments: [SleepSegment],
        maxGap: TimeInterval = 45 * 60
    ) -> [HeartRateSleepWindow] {
        let asleepIntervals = Sleep24hSummary.mergeIntervals(
            segments.filter { $0.stage.isAsleep }.map { ($0.start, $0.end) }
        )
        guard let first = asleepIntervals.first else { return [] }

        var clusters: [(start: Date, end: Date, asleepSeconds: TimeInterval)] = [
            (first.0, first.1, first.1.timeIntervalSince(first.0))
        ]

        for (s, e) in asleepIntervals.dropFirst() {
            let lastIdx = clusters.count - 1
            if s.timeIntervalSince(clusters[lastIdx].end) <= maxGap {
                clusters[lastIdx].end = max(clusters[lastIdx].end, e)
                clusters[lastIdx].asleepSeconds += e.timeIntervalSince(s)
            } else {
                clusters.append((s, e, e.timeIntervalSince(s)))
            }
        }

        return clusters.compactMap { cluster in
            guard cluster.end.timeIntervalSince(cluster.start) >= 60,
                  cluster.asleepSeconds >= 60 else {
                return nil
            }
            return HeartRateSleepWindow(
                start: cluster.start,
                end: cluster.end,
                asleepSeconds: cluster.asleepSeconds
            )
        }
    }
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
    let workouts: [HeartRateWorkoutWindow]
    let sleepWindows: [HeartRateSleepWindow]
    let latestBPM: Double?
    let minBPM: Double?
    let maxBPM: Double?
    let restingHeartRateBPM: Double?
    let hrvMilliseconds: Double?
    let hrvIs24hAverage: Bool
    /// Precomputed once off-MainActor so SwiftUI chart rendering does zero per-frame math.
    let yAxisDomain: ClosedRange<Double>

    func workout(at date: Date) -> HeartRateWorkoutWindow? {
        workouts.first { date >= $0.start && date <= $0.end }
    }

    func sleepWindow(at date: Date) -> HeartRateSleepWindow? {
        sleepWindows.first { date >= $0.start && date <= $0.end }
    }

    var totalSleepSeconds: TimeInterval {
        sleepWindows.reduce(0) { $0 + $1.asleepSeconds }
    }

    var totalActivitySeconds: TimeInterval {
        workouts.reduce(0) { $0 + max(0, $1.end.timeIntervalSince($1.start)) }
    }

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
        workouts: [HeartRateWorkoutWindow] = [],
        sleepWindows: [HeartRateSleepWindow] = [],
        restingHeartRateBPM: Double?,
        hrvSamples24h: [Double],
        fallbackHRV: Double?,
        windowEnd: Date,
        bucketInterval: TimeInterval = 15 * 60,
        gapBreakThreshold: TimeInterval = 45 * 60
    ) -> HeartRate24hSummary {
        let windowStart = windowEnd.addingTimeInterval(-24 * 60 * 60)
        let inWindow = samples
            .filter { $0.bpm.isFinite && $0.bpm > 0 && $0.date >= windowStart && $0.date <= windowEnd }
            .sorted { $0.date < $1.date }

        // Clip workouts to the 24h window and deduplicate identical multi-writer entries
        // (e.g. Apple Watch + Strava writing the same interval), preferring richer kcal data.
        var dedupedWorkouts: [String: HeartRateWorkoutWindow] = [:]
        for workout in workouts {
            let s = max(workout.start, windowStart)
            let e = min(workout.end, windowEnd)
            guard e.timeIntervalSince(s) >= 60 else { continue }
            let clipped = HeartRateWorkoutWindow(
                start: s,
                end: e,
                activityName: workout.activityName,
                symbolName: workout.symbolName,
                durationMinutes: workout.durationMinutes,
                activeKilocalories: workout.activeKilocalories
            )
            if let existing = dedupedWorkouts[clipped.id] {
                if (clipped.activeKilocalories ?? -1) > (existing.activeKilocalories ?? -1) {
                    dedupedWorkouts[clipped.id] = clipped
                }
            } else {
                dedupedWorkouts[clipped.id] = clipped
            }
        }
        let clippedWorkouts = dedupedWorkouts.values.sorted { $0.start < $1.start }

        let clippedSleep: [HeartRateSleepWindow] = sleepWindows.compactMap { sleep in
            let s = max(sleep.start, windowStart)
            let e = min(sleep.end, windowEnd)
            let span = e.timeIntervalSince(s)
            guard span >= 60 else { return nil }
            let originalSpan = max(1, sleep.end.timeIntervalSince(sleep.start))
            let scaledAsleep = (s == sleep.start && e == sleep.end)
                ? sleep.asleepSeconds
                : min(span, sleep.asleepSeconds * (span / originalSpan))
            guard scaledAsleep >= 60 else { return nil }
            return HeartRateSleepWindow(start: s, end: e, asleepSeconds: scaledAsleep)
        }.sorted { $0.start < $1.start }

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
            let rawBucketDate = windowStart.addingTimeInterval((Double(index) + 0.5) * bucketInterval)
            let bucketDate = min(windowEnd, max(windowStart, rawBucketDate))
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
            workouts: clippedWorkouts,
            sleepWindows: clippedSleep,
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
                    MetricIndicatorTile(
                        title: "RHR",
                        icon: "heart.text.square.fill",
                        tint: AppTheme.Colors.slateTeal,
                        value: summary?.restingHeartRateBPM.map { "\(Int($0.rounded()))" } ?? "—",
                        unit: summary?.restingHeartRateBPM != nil ? "bpm" : "",
                        caption: "Resting"
                    )

                    MetricIndicatorTile(
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

                    if !summary.sleepWindows.isEmpty || !summary.workouts.isEmpty {
                        eventSummaryStrip(summary)
                    }

                    HStack(spacing: 10) {
                        legendChip(color: AppTheme.Colors.coral, label: "HR", isDashed: false)
                        if summary.restingHeartRateBPM != nil {
                            legendChip(color: AppTheme.Colors.slateTeal, label: "RHR", isDashed: true)
                        }
                        if !summary.sleepWindows.isEmpty {
                            legendChip(color: AppTheme.Colors.sleepDeep, label: "Sleep", isDashed: false)
                        }
                        if !summary.workouts.isEmpty {
                            legendChip(color: AppTheme.Colors.ochre, label: "Activity", isDashed: false)
                        }
                        Spacer(minLength: 4)
                        Text(selectedBucket == nil ? "Hold & drag" : selectedSampleCountLabel)
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
            let bpmRange = lo == hi ? "\(lo) bpm" : "\(lo)–\(hi) bpm"
            if let workout = summary?.workout(at: bucket.date) {
                return "\(time) · \(workout.activityName) · \(bpmRange)"
            }
            if summary?.sleepWindow(at: bucket.date) != nil {
                return "\(time) · Sleep · \(bpmRange)"
            }
            return "\(time) · \(bpmRange)"
        }
        if let minBPM = summary?.minBPM, let maxBPM = summary?.maxBPM {
            return "\(Int(minBPM.rounded()))–\(Int(maxBPM.rounded())) bpm · Last 24h"
        }
        return "Last 24 hours"
    }

    private func eventSummaryStrip(_ summary: HeartRate24hSummary) -> some View {
        let activeWorkout = selectedBucket.flatMap { summary.workout(at: $0.date) }
        let isSleepHighlighted = activeWorkout == nil &&
            (selectedBucket.flatMap { summary.sleepWindow(at: $0.date) } != nil)
        let isActivityHighlighted = activeWorkout != nil

        return HStack(spacing: 8) {
            if !summary.sleepWindows.isEmpty {
                eventChip(
                    symbolName: "moon.zzz.fill",
                    title: "Sleep",
                    detail: "· \(Sleep24hSummary.formatDuration(summary.totalSleepSeconds))",
                    tint: AppTheme.Colors.sleepDeep,
                    isHighlighted: isSleepHighlighted
                )
            }
            if !summary.workouts.isEmpty {
                let symbol = summary.workouts.count == 1
                    ? summary.workouts[0].symbolName
                    : "figure.mixed.cardio"
                eventChip(
                    symbolName: symbol,
                    title: "Activities",
                    detail: "· \(Sleep24hSummary.formatDuration(summary.totalActivitySeconds))",
                    tint: AppTheme.Colors.ochre,
                    isHighlighted: isActivityHighlighted
                )
            }
            Spacer(minLength: 0)
        }
    }

    private func eventChip(
        symbolName: String,
        title: String,
        detail: String,
        tint: Color,
        isHighlighted: Bool
    ) -> some View {
        HStack(spacing: 6) {
            Image(systemName: symbolName)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(tint)
                .frame(width: 13, height: 13)
            Text(title)
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundColor(.primary)
                .lineLimit(1)
            Text(detail)
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .foregroundColor(.secondary)
                .monospacedDigit()
                .lineLimit(1)
        }
        .padding(.horizontal, 10)
        .frame(height: 26)
        .background(
            Capsule()
                .fill(tint.opacity(isHighlighted ? 0.24 : 0.12))
        )
        .overlay(
            Capsule()
                .strokeBorder(tint.opacity(isHighlighted ? 0.55 : 0.24), lineWidth: 1)
        )
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

    private func heartRateChart(_ data: HeartRate24hSummary) -> some View {
        let yFloor = data.yAxisDomain.lowerBound
        let yCeiling = data.yAxisDomain.upperBound
        let latestBucket = data.buckets.last
        let activeWorkout = selectedBucket.flatMap { data.workout(at: $0.date) }
        let activeSleep = selectedBucket.flatMap { data.sleepWindow(at: $0.date) }

        return Chart {
            // Shaded sleep windows behind workouts and the heart rate trace
            ForEach(data.sleepWindows) { sleep in
                let isSleepHighlighted = (activeWorkout == nil && activeSleep?.id == sleep.id)

                RectangleMark(
                    xStart: .value("Sleep Start", sleep.start),
                    xEnd: .value("Sleep End", sleep.end),
                    yStart: .value("Floor", yFloor),
                    yEnd: .value("Ceiling", yCeiling)
                )
                .foregroundStyle(
                    isSleepHighlighted
                        ? AppTheme.Colors.sleepBandHighlightedGradient
                        : AppTheme.Colors.sleepBandGradient
                )
                .cornerRadius(4)
            }

            // Shaded workout windows behind the heart rate trace
            ForEach(data.workouts) { workout in
                let isWorkoutHighlighted = (activeWorkout?.id == workout.id)

                RectangleMark(
                    xStart: .value("Workout Start", workout.start),
                    xEnd: .value("Workout End", workout.end),
                    yStart: .value("Floor", yFloor),
                    yEnd: .value("Ceiling", yCeiling)
                )
                .foregroundStyle(
                    isWorkoutHighlighted
                        ? AppTheme.Colors.workoutBandHighlightedGradient
                        : AppTheme.Colors.workoutBandGradient
                )
                .cornerRadius(4)
            }

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
        .disableChartAxisAnimations()
    }
}
