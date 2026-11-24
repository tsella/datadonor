import SwiftUI

enum ReadinessTier: String, Equatable, Sendable, Codable {
    case optimal = "Optimal"
    case good = "Good"
    case fair = "Fair"
    case recover = "Take It Easy"

    var color: Color {
        switch self {
        case .optimal: return AppTheme.Colors.emerald
        case .good: return AppTheme.Colors.slateTeal
        case .fair: return AppTheme.Colors.ochre
        case .recover: return AppTheme.Colors.coral
        }
    }

    static func forScore(_ score: Int) -> ReadinessTier {
        switch score {
        case 85...100: return .optimal
        case 70...84: return .good
        case 55...69: return .fair
        default: return .recover
        }
    }
}

struct ReadinessFactor: Identifiable, Equatable, Sendable, Codable {
    let id: String
    let title: String
    let icon: String
    let valueText: String
    let detailText: String
    let score: Double // 0...100
    let weight: Double
    let tier: ReadinessTier
}

struct ReadinessSummary: Equatable, Sendable, Codable {
    let score: Int?
    let tier: ReadinessTier
    let insight: String
    let factors: [ReadinessFactor]

    var availableFactorCount: Int { factors.count }

    private static func clamp(_ value: Double, min lo: Double, max hi: Double) -> Double {
        Swift.min(hi, Swift.max(lo, value))
    }

    static func build(
        hrvToday: Double?,
        hrvBaseline14d: Double?,
        rhrToday: Double?,
        rhrBaseline14d: Double?,
        sleepHours24h: Double?,
        restorativeSleepShare: Double?,
        wristTempTodayC: Double?,
        wristTempBaseline14dC: Double?
    ) -> ReadinessSummary {
        var factors: [ReadinessFactor] = []

        if let hrv = hrvToday, hrv > 0 {
            let score: Double
            let detail: String
            if let base = hrvBaseline14d, base > 0 {
                let ratio = hrv / base
                score = clamp(78.0 + (ratio - 1.0) * 110.0, min: 15, max: 100)
                let pct = Int(((ratio - 1.0) * 100.0).rounded())
                detail = abs(pct) <= 2 ? "at 14d avg" : "\(pct > 0 ? "+" : "")\(pct)% vs 14d"
            } else {
                score = clamp(50.0 + (hrv - 30.0) * 0.9, min: 25, max: 95)
                detail = "24h avg"
            }
            factors.append(ReadinessFactor(
                id: "hrv",
                title: "HRV",
                icon: "waveform.path.ecg",
                valueText: "\(Int(hrv.rounded())) ms",
                detailText: detail,
                score: score,
                weight: 0.30,
                tier: ReadinessTier.forScore(Int(score.rounded()))
            ))
        }

        if let rhr = rhrToday, rhr > 0 {
            let score: Double
            let detail: String
            if let base = rhrBaseline14d, base > 0 {
                let delta = rhr - base
                score = clamp(80.0 - delta * 6.0, min: 15, max: 100)
                let roundedDelta = Int(delta.rounded())
                detail = roundedDelta == 0 ? "at 14d avg" : "\(roundedDelta > 0 ? "+" : "")\(roundedDelta) bpm vs 14d"
            } else {
                score = clamp(95.0 - max(0, rhr - 55.0) * 1.4, min: 30, max: 95)
                detail = "Latest"
            }
            factors.append(ReadinessFactor(
                id: "rhr",
                title: "RHR",
                icon: "heart.fill",
                valueText: "\(Int(rhr.rounded())) bpm",
                detailText: detail,
                score: score,
                weight: 0.25,
                tier: ReadinessTier.forScore(Int(score.rounded()))
            ))
        }

        if let hours = sleepHours24h, hours > 0 {
            let durationScore = clamp(100.0 - max(0, 7.75 - hours) * 17.5, min: 15, max: 100)
            let finalSleepScore: Double
            let detail: String
            if let share = restorativeSleepShare {
                let stageScore = clamp(85.0 + (share - 0.35) * 150.0, min: 40, max: 100)
                finalSleepScore = 0.75 * durationScore + 0.25 * stageScore
                detail = "\(Int((share * 100).rounded()))% deep+REM"
            } else {
                finalSleepScore = durationScore
                detail = "Last 24h"
            }
            factors.append(ReadinessFactor(
                id: "sleep",
                title: "Sleep",
                icon: "bed.double.fill",
                valueText: Sleep24hSummary.formatDuration(hours * 3600.0),
                detailText: detail,
                score: finalSleepScore,
                weight: 0.30,
                tier: ReadinessTier.forScore(Int(finalSleepScore.rounded()))
            ))
        }

        if let temp = wristTempTodayC, let base = wristTempBaseline14dC {
            let delta = temp - base
            let absDelta = abs(delta)
            let score = clamp(100.0 - max(0, absDelta - 0.15) * 85.0, min: 15, max: 100)
            let formattedDelta = String(format: "%@%.1f°C", delta >= 0 ? "+" : "", delta)
            factors.append(ReadinessFactor(
                id: "temp",
                title: "Wrist Temp",
                icon: "thermometer.medium",
                valueText: formattedDelta,
                detailText: absDelta <= 0.25 ? "within baseline" : "vs 14d avg",
                score: score,
                weight: 0.15,
                tier: ReadinessTier.forScore(Int(score.rounded()))
            ))
        }

        guard !factors.isEmpty else {
            return ReadinessSummary(
                score: nil,
                tier: .fair,
                insight: "Need recent HRV, RHR, or sleep data to calculate readiness.",
                factors: []
            )
        }

        let totalWeight = factors.reduce(0.0) { $0 + $1.weight }
        let weighted = factors.reduce(0.0) { $0 + $1.score * $1.weight } / totalWeight
        let finalScore = Int(clamp(weighted.rounded(), min: 0, max: 100))
        let tier = ReadinessTier.forScore(finalScore)

        return ReadinessSummary(
            score: finalScore,
            tier: tier,
            insight: buildInsight(tier: tier, factors: factors),
            factors: factors
        )
    }

    private static func buildInsight(tier: ReadinessTier, factors: [ReadinessFactor]) -> String {
        let lowest = factors.min { $0.score < $1.score }
        let highest = factors.max { $0.score < $1.score }

        switch tier {
        case .optimal:
            if let top = highest {
                return "Strong recovery led by \(top.title) (\(top.detailText)) — primed for peak effort."
            }
            return "All recovery signals look strong — primed for peak effort."
        case .good:
            return "Recovery signals are steady — ready for a normal training day."
        case .fair:
            if let low = lowest {
                return "\(low.title) is trailing (\(low.detailText)) — consider moderate intensity today."
            }
            return "Moderate recovery — keep effort steady today."
        case .recover:
            if let low = lowest {
                return "\(low.title) signals strain (\(low.detailText)) — prioritize rest and recovery."
            }
            return "Recovery signals show strain — prioritize rest today."
        }
    }
}

struct ReadinessCardView: View {
    let summary: ReadinessSummary?
    let isAuthorized: Bool
    let isLoading: Bool

    @AppStorage("cardCollapsed_readiness") private var isCollapsed = false

    var body: some View {
        CollapsibleCard(isCollapsed: $isCollapsed, accessibilityTitle: "Readiness") {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 7) {
                    Image(systemName: "bolt.heart.fill")
                        .font(.subheadline)
                        .foregroundColor(summary?.tier.color ?? AppTheme.Colors.emerald)
                    Text("Readiness")
                        .font(.system(.headline, design: .rounded))
                        .foregroundColor(.primary)
                }

                Text(subtitleText)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .monospacedDigit()
            }
        } headerTrailing: {
            if let score = summary?.score, let tier = summary?.tier {
                HStack(alignment: .firstTextBaseline, spacing: 2) {
                    Text("\(score)")
                        .font(.system(.title3, design: .rounded).weight(.bold))
                        .foregroundColor(tier.color)
                        .monospacedDigit()
                        .contentTransition(.numericText())
                    Text("/100")
                        .font(.caption2.weight(.medium))
                        .foregroundColor(.secondary)
                }
                .padding(.top, 1)
            }
        } content: {
            if !isAuthorized {
                Text("Grant Health access to calculate your personal readiness score.")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .padding(.vertical, 8)
            } else if let summary, let score = summary.score {
                HStack(spacing: 18) {
                    scoreRing(score: score, color: summary.tier.color)

                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 8) {
                            Text(summary.tier.rawValue)
                                .font(.system(.subheadline, design: .rounded).weight(.bold))
                                .foregroundColor(summary.tier.color)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 4)
                                .background(
                                    Capsule()
                                        .fill(summary.tier.color.opacity(0.14))
                                )

                            Text("\(summary.availableFactorCount) signal\(summary.availableFactorCount == 1 ? "" : "s")")
                                .font(.caption2.weight(.medium))
                                .foregroundColor(.secondary)
                        }

                        Text(summary.insight)
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                VStack(spacing: 10) {
                    ForEach(summary.factors) { factor in
                        factorRow(factor)
                    }
                }
            } else if isLoading {
                HStack {
                    Spacer()
                    ProgressView()
                        .padding(.vertical, 44)
                    Spacer()
                }
            } else {
                Text("Not enough recent HealthKit data yet to score readiness.")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 32)
            }
        }
    }

    private var subtitleText: String {
        if let summary, summary.score != nil {
            return "\(summary.tier.rawValue) · vs 14-day baseline"
        }
        return "Daily recovery score"
    }

    internal static func scoreRingProgress(for score: Int) -> Double {
        max(0.0, min(1.0, Double(score) / 100.0))
    }

    internal static func scoreRingGradientEndDegrees(for score: Int) -> Double {
        max(1.0, 360.0 * scoreRingProgress(for: score))
    }

    private func scoreRing(score: Int, color: Color) -> some View {
        let progress = Self.scoreRingProgress(for: score)
        let endDegrees = Self.scoreRingGradientEndDegrees(for: score)
        return ZStack {
            Circle()
                .stroke(color.opacity(0.16), lineWidth: 9)

            if progress > 0 {
                Circle()
                    .trim(from: 0, to: progress)
                    .stroke(
                        AngularGradient(
                            gradient: Gradient(colors: [color.opacity(0.65), color]),
                            center: .center,
                            startAngle: .degrees(0),
                            endAngle: .degrees(endDegrees)
                        ),
                        style: StrokeStyle(lineWidth: 9, lineCap: .round)
                    )
                    .rotationEffect(.degrees(-90))
                    .animation(AppTheme.Animations.chartUpdate, value: score)
            }

            VStack(spacing: 0) {
                Text("\(score)")
                    .font(.system(size: 26, weight: .bold, design: .rounded))
                    .foregroundColor(.primary)
                    .monospacedDigit()
                    .contentTransition(.numericText())
                Text("SCORE")
                    .font(.system(size: 8, weight: .bold, design: .rounded))
                    .tracking(0.8)
                    .foregroundColor(.secondary)
            }
        }
        .frame(width: 82, height: 82)
    }

    private func factorRow(_ factor: ReadinessFactor) -> some View {
        let factorColor = factor.tier.color
        let fraction = factor.score.isFinite ? max(0.06, min(1.0, factor.score / 100.0)) : 0.06

        return VStack(spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: factor.icon)
                    .font(.caption.weight(.semibold))
                    .foregroundColor(factorColor)
                    .frame(width: 16)

                Text(factor.title)
                    .font(.system(.caption, design: .rounded).weight(.semibold))
                    .foregroundColor(.primary)

                Text(factor.detailText)
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .lineLimit(1)

                Spacer()

                Text(factor.valueText)
                    .font(.system(.caption, design: .rounded).weight(.bold))
                    .foregroundColor(.primary)
                    .monospacedDigit()
            }

            GeometryReader { geo in
                let barWidth = max(0, geo.size.width) * fraction
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(AppTheme.Colors.trackFill)
                    Capsule()
                        .fill(
                            LinearGradient(
                                colors: [factorColor.opacity(0.72), factorColor],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .frame(width: barWidth.isFinite ? barWidth : 0)
                }
            }
            .frame(height: 6)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(AppTheme.Colors.insetSurface)
        )
    }
}
