import SwiftUI
import Charts

/// Single source of truth for DataDonor's earthy pastel palette, card metrics, and animations.
enum AppTheme {
    enum Colors {
        // Brand & accents
        static let teal = Color(red: 0.04, green: 0.63, blue: 0.57)
        static let coral = Color(red: 223/255.0, green: 107/255.0, blue: 83/255.0)
        static let coralDeep = Color(red: 199/255.0, green: 79/255.0, blue: 61/255.0)
        static let slateTeal = Color(red: 103/255.0, green: 139/255.0, blue: 150/255.0)
        static let emerald = Color(red: 35/255.0, green: 163/255.0, blue: 147/255.0)
        static let ochre = Color(red: 210/255.0, green: 163/255.0, blue: 91/255.0)

        // Sleep stages
        static let sleepAwake = coral
        static let sleepREM = Color(red: 92/255.0, green: 179/255.0, blue: 189/255.0)
        static let sleepCore = Color(red: 76/255.0, green: 127/255.0, blue: 168/255.0)
        static let sleepDeep = Color(red: 78/255.0, green: 92/255.0, blue: 158/255.0)

        // Semantic surfaces & strokes
        static let groupedBackground = Color(uiColor: .systemGroupedBackground)
        static let cardSurface = Color(uiColor: .secondarySystemGroupedBackground)
        static let insetSurface = Color(uiColor: .tertiarySystemGroupedBackground)
        static let cardBorder = Color.primary.opacity(0.04)
        static let subtleBorder = Color.primary.opacity(0.05)
        static let cardShadow = Color.black.opacity(0.06)
        static let gridLine = Color.secondary.opacity(0.14)
        static let gridLineSoft = Color.secondary.opacity(0.12)
        static let trackFill = Color.primary.opacity(0.07)
        static let destructive = Color.red.opacity(0.9)
        static let warning = Color.orange
        static let typicalBandFill = emerald.opacity(0.11)

        // Splash screen palette
        static let splashBackgroundTop = Color(red: 16/255.0, green: 23/255.0, blue: 38/255.0)
        static let splashBackgroundBottom = Color(red: 11/255.0, green: 16/255.0, blue: 27/255.0)
        static let splashViolet = Color(red: 124/255.0, green: 109/255.0, blue: 214/255.0)
        static let splashGlassSurface = Color.white.opacity(0.08)
        static let splashGlassBorder = Color.white.opacity(0.18)
        static let splashTitlePrimary = Color.white
        static let splashTitleSecondary = Color.white.opacity(0.68)
        static let splashBackdropGradient = LinearGradient(
            colors: [splashBackgroundTop, splashBackgroundBottom],
            startPoint: .top,
            endPoint: .bottom
        )
        static func splashRingGradient(angle: Angle) -> AngularGradient {
            AngularGradient(
                colors: [splashViolet, teal, emerald, coral, ochre, splashViolet],
                center: .center,
                angle: angle
            )
        }

        // Prebuilt gradients reused across chart marks to avoid repeated allocations in ForEach.
        static let heartLineGradient = LinearGradient(
            colors: [coral, coralDeep],
            startPoint: .top,
            endPoint: .bottom
        )
        static let heartAreaGradient = LinearGradient(
            colors: [coral.opacity(0.24), coral.opacity(0.06), coral.opacity(0.0)],
            startPoint: .top,
            endPoint: .bottom
        )
        static let heartRangeGradient = LinearGradient(
            colors: [coral.opacity(0.36), coral.opacity(0.14)],
            startPoint: .top,
            endPoint: .bottom
        )
        static let heartRangeHighlightedGradient = LinearGradient(
            colors: [coral.opacity(0.65), coral.opacity(0.35)],
            startPoint: .top,
            endPoint: .bottom
        )
        static let workoutBandGradient = LinearGradient(
            colors: [ochre.opacity(0.24), ochre.opacity(0.06)],
            startPoint: .top,
            endPoint: .bottom
        )
        static let workoutBandHighlightedGradient = LinearGradient(
            colors: [ochre.opacity(0.38), ochre.opacity(0.12)],
            startPoint: .top,
            endPoint: .bottom
        )
        static let sleepBandGradient = LinearGradient(
            colors: [sleepDeep.opacity(0.18), sleepCore.opacity(0.05)],
            startPoint: .top,
            endPoint: .bottom
        )
        static let sleepBandHighlightedGradient = LinearGradient(
            colors: [sleepDeep.opacity(0.32), sleepCore.opacity(0.11)],
            startPoint: .top,
            endPoint: .bottom
        )

        static let syncCategoryColors: [String: Color] = [
            "Heart Rate": coral,
            "Steps": slateTeal,
            "Sleep": emerald,
            "Workouts": ochre
        ]

        static func syncCategoryColor(for category: String) -> Color {
            syncCategoryColors[category] ?? .gray
        }

        static func barGradient(for color: Color, dimmed: Bool) -> LinearGradient {
            LinearGradient(
                colors: [
                    color.opacity(dimmed ? 0.28 : 0.96),
                    color.opacity(dimmed ? 0.16 : 0.72)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        }

        static func trendAreaGradient(for color: Color) -> LinearGradient {
            LinearGradient(
                colors: [color.opacity(0.24), color.opacity(0.05), color.opacity(0.0)],
                startPoint: .top,
                endPoint: .bottom
            )
        }
    }

    enum Layout {
        static let screenHorizontalPadding: CGFloat = 20
        static let cardCornerRadius: CGFloat = 22
        static let cardPadding: CGFloat = 20
        static let cardContentSpacing: CGFloat = 18
        static let cardStackSpacing: CGFloat = 20
        static let insetCornerRadius: CGFloat = 14
        static let chipCornerRadius: CGFloat = 10
        static let buttonCornerRadius: CGFloat = 16
        static let gridStroke = StrokeStyle(lineWidth: 0.5, dash: [3, 3])
    }

    enum Animations {
        /// Critically damped (`dampingFraction: 1.0`) so animating Swift Charts `BarMark` /
        /// `RectangleMark` heights and collapsible card frames never overshoots below zero
        /// (which triggers `[SwiftUI] Invalid frame dimension (negative or non-finite).`).
        static let collapse = Animation.spring(response: 0.32, dampingFraction: 1.0)
        static let chartUpdate = Animation.spring(response: 0.50, dampingFraction: 1.0)
        static let scrubRelease = Animation.easeOut(duration: 0.18)
        static let readoutUpdate = Animation.easeOut(duration: 0.14)
    }
}

/// Tracks monotonic request generations so an older, slower async fetch cannot overwrite
/// newer UI state after a refresh supersedes it.
struct FetchGenerationGuard: Sendable {
    private(set) var current: Int = 0

    mutating func beginNext() -> Int {
        current += 1
        return current
    }

    func isCurrent(_ generation: Int) -> Bool {
        generation == current
    }
}

/// Shared fold/collapse toggle button used in the header of every main card.
struct CardCollapseButton: View {
    @Binding var isCollapsed: Bool
    let cardTitle: String

    var body: some View {
        Button {
            withAnimation(AppTheme.Animations.collapse) {
                isCollapsed.toggle()
            }
        } label: {
            Image(systemName: "chevron.up")
                .font(.caption.weight(.semibold))
                .foregroundColor(.secondary)
                .rotationEffect(.degrees(isCollapsed ? 180 : 0))
                .frame(width: 28, height: 28)
                .background(AppTheme.Colors.insetSurface)
                .clipShape(Circle())
                .overlay(
                    Circle()
                        .strokeBorder(AppTheme.Colors.subtleBorder, lineWidth: 0.5)
                )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isCollapsed ? "Expand \(cardTitle)" : "Collapse \(cardTitle)")
    }
}

/// Reusable rounded card container with consistent surface, hairline border, shadow,
/// header alignment, and persistent fold/collapse affordance.
struct CollapsibleCard<HeaderLeading: View, HeaderTrailing: View, BodyContent: View>: View {
    @Binding var isCollapsed: Bool
    let accessibilityTitle: String
    let contentSpacing: CGFloat
    @ViewBuilder let headerLeading: () -> HeaderLeading
    @ViewBuilder let headerTrailing: () -> HeaderTrailing
    @ViewBuilder let content: () -> BodyContent

    init(
        isCollapsed: Binding<Bool>,
        accessibilityTitle: String,
        contentSpacing: CGFloat = AppTheme.Layout.cardContentSpacing,
        @ViewBuilder headerLeading: @escaping () -> HeaderLeading,
        @ViewBuilder headerTrailing: @escaping () -> HeaderTrailing,
        @ViewBuilder content: @escaping () -> BodyContent
    ) {
        self._isCollapsed = isCollapsed
        self.accessibilityTitle = accessibilityTitle
        self.contentSpacing = contentSpacing
        self.headerLeading = headerLeading
        self.headerTrailing = headerTrailing
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: isCollapsed ? 0 : contentSpacing) {
            HStack(alignment: .top, spacing: 12) {
                headerLeading()
                Spacer(minLength: 8)
                headerTrailing()
                CardCollapseButton(isCollapsed: $isCollapsed, cardTitle: accessibilityTitle)
            }

            if !isCollapsed {
                content()
            }
        }
        .padding(AppTheme.Layout.cardPadding)
        .background(AppTheme.Colors.cardSurface)
        .clipShape(RoundedRectangle(cornerRadius: AppTheme.Layout.cardCornerRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: AppTheme.Layout.cardCornerRadius, style: .continuous)
                .strokeBorder(AppTheme.Colors.cardBorder, lineWidth: 1)
        )
        .shadow(color: AppTheme.Colors.cardShadow, radius: 12, x: 0, y: 6)
    }
}

/// Reusable compact vitals KPI tile (used in Heart Rate for RHR/HRV and Energy for Basal/Active).
struct MetricIndicatorTile: View {
    let title: String
    let icon: String
    let tint: Color
    let value: String
    let unit: String
    let caption: String

    var body: some View {
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
                    if !caption.isEmpty {
                        Text("· \(caption)")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    }
                }

                HStack(alignment: .firstTextBaseline, spacing: 3) {
                    Text(value)
                        .font(.system(.title3, design: .rounded).weight(.bold))
                        .foregroundColor(.primary)
                        .monospacedDigit()
                        .contentTransition(.numericText())
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
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
}

/// Reusable iOS 16+ chart press-and-drag scrub overlay that translates touch X into a Date
/// without hijacking vertical `ScrollView` swipes.
struct DateChartScrubOverlay: View {
    let proxy: ChartProxy
    let onScrubDate: (Date) -> Void
    let onEnd: () -> Void

    @GestureState private var isScrubbing = false

    var body: some View {
        GeometryReader { geometry in
            Rectangle()
                .fill(.clear)
                .contentShape(Rectangle())
                .gesture(
                    LongPressGesture(minimumDuration: 0.15)
                        .sequenced(before: DragGesture(minimumDistance: 0))
                        .updating($isScrubbing) { value, state, _ in
                            if case .second(true, _) = value {
                                state = true
                            }
                        }
                        .onChanged { value in
                            guard case .second(true, let drag) = value,
                                  let location = drag?.location,
                                  let plotFrame = proxy.plotFrame else {
                                return
                            }
                            let origin = geometry[plotFrame].origin
                            let locationX = location.x - origin.x
                            guard locationX >= 0, locationX <= proxy.plotSize.width,
                                  let date = proxy.value(atX: locationX, as: Date.self) else {
                                return
                            }
                            onScrubDate(date)
                        }
                        .onEnded { _ in
                            onEnd()
                        }
                )
        }
        .onChange(of: isScrubbing) { _, active in
            if !active {
                onEnd()
            }
        }
    }
}

extension View {
    /// Prevents parent SwiftUI `withAnimation` transactions from animating Swift Charts'
    /// internal `AxisMarks` scale-domain transitions, which otherwise log
    /// `[SwiftUI] Invalid frame dimension (negative or non-finite).` on every animated frame.
    func disableChartAxisAnimations() -> some View {
        transaction { transaction in
            transaction.animation = nil
            transaction.disablesAnimations = true
        }
    }
}
