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
        static let collapse = Animation.spring(response: 0.32, dampingFraction: 0.84)
        static let chartUpdate = Animation.spring(response: 0.55, dampingFraction: 0.82)
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

/// Reusable iOS 16+ chart drag-to-scrub gesture overlay that translates touch X into a Date.
struct DateChartScrubOverlay: View {
    let proxy: ChartProxy
    let onScrubDate: (Date) -> Void
    let onEnd: () -> Void

    var body: some View {
        GeometryReader { geometry in
            Rectangle()
                .fill(.clear)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            let origin = geometry[proxy.plotAreaFrame].origin
                            let locationX = value.location.x - origin.x
                            guard locationX >= 0, locationX <= proxy.plotAreaSize.width,
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
    }
}
