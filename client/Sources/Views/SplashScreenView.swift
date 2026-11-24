import SwiftUI

/// Pure, precomputed waveform and pulse-physics math for `SplashScreenView`.
///
/// Precomputing the ECG lookup table once keeps 120Hz `Canvas` draws free of per-frame
/// transcendental calls along the trace.
enum SplashWaveformMath {
    static let sampleCount = 160

    /// Physiological P-Q-R-S-T waveform amplitude in `[-0.35, 1.0]` for normalized `u` in `0...1`,
    /// with the primary R-peak aligned at `u = 0.50`.
    static func ecgAmplitude(at u: Double) -> Double {
        let pWave = 0.16 * exp(-pow((u - 0.370) / 0.024, 2))
        let qDip = -0.18 * exp(-pow((u - 0.465) / 0.011, 2))
        let rPeak = 1.00 * exp(-pow((u - 0.500) / 0.014, 2))
        let sDip = -0.30 * exp(-pow((u - 0.535) / 0.012, 2))
        let tWave = 0.26 * exp(-pow((u - 0.655) / 0.036, 2))
        return pWave + qDip + rPeak + sDip + tWave
    }

    /// Precomputed normalized `(u, amplitude)` points sampled once at launch.
    static let ecgLUT: [(u: CGFloat, y: CGFloat)] = (0...sampleCount).map { idx in
        let u = Double(idx) / Double(sampleCount)
        return (CGFloat(u), CGFloat(ecgAmplitude(at: u)))
    }

    /// Physiological double-beat ("lub-dub") emblem scale impulse synced to the ECG R-peak at `t = 0.44s`.
    static func lubDubScale(at t: Double) -> CGFloat {
        let lub = 0.065 * exp(-pow((t - 0.44) / 0.055, 2))
        let dub = 0.038 * exp(-pow((t - 0.63) / 0.065, 2))
        return CGFloat(1.0 + lub + dub)
    }

    static func easeOutCubic(_ x: Double) -> Double {
        let c = min(1.0, max(0.0, x))
        let inv = 1.0 - c
        return 1.0 - inv * inv * inv
    }

    static func easeInOutCubic(_ x: Double) -> Double {
        let c = min(1.0, max(0.0, x))
        return c < 0.5 ? 4 * c * c * c : 1 - pow(-2 * c + 2, 3) / 2
    }
}

/// GPU-accelerated biometric splash screen rendered in a single `Canvas` pass.
///
/// Choreography (~1.35s, tap-to-skip, `Reduce Motion` aware):
/// 1. Luminous ECG pulse sweeps across the viewport; as the R-peak hits dead center it
///    triggers concentric biometric ripple rings and a synchronized "lub-dub" emblem beat.
/// 2. Four vital telemetry particles (Heart Rate, Sleep, Readiness, Energy) spiral inward
///    along orbital arcs and converge into the DataDonor heart medallion.
/// 3. Smoothly dissolves out once the choreography finishes and cached/initial vitals are ready,
///    then removes itself completely from the view hierarchy (0% ongoing CPU/GPU cost).
struct SplashScreenView: View {
    enum SplashPhase: Equatable {
        case animating
        case dismissing
        case finished
    }

    let isReady: Bool
    let onFinished: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @State private var startDate = Date()
    @State private var latestIsReady = false
    @State private var phase: SplashPhase = .animating
    @State private var isExitingVisual = false
    @State private var emblemAppeared = false
    @State private var textAppeared = false
    @State private var dismissTask: Task<Void, Never>?

    /// Shared vertical offset from full-screen center so Canvas focal effects (ECG R-peak,
    /// ripple rings, orbital convergence) align to 0.0pt with the emblem medallion center.
    private static let focalYOffset: CGFloat = -44

    private struct OrbitalNode {
        let startAngle: Double
        let startRadius: CGFloat
        let delay: Double
        let color: Color
    }

    private static let orbitalNodes: [OrbitalNode] = [
        OrbitalNode(startAngle: -2.45, startRadius: 175, delay: 0.08, color: AppTheme.Colors.coral),
        OrbitalNode(startAngle: -0.62, startRadius: 168, delay: 0.14, color: AppTheme.Colors.splashViolet),
        OrbitalNode(startAngle: 0.82, startRadius: 178, delay: 0.20, color: AppTheme.Colors.emerald),
        OrbitalNode(startAngle: 2.52, startRadius: 170, delay: 0.26, color: AppTheme.Colors.ochre)
    ]

    private static let rippleSpecs: [(delay: Double, color: Color)] = [
        (0.00, AppTheme.Colors.teal),
        (0.13, AppTheme.Colors.splashViolet),
        (0.26, AppTheme.Colors.emerald)
    ]

    var body: some View {
        ZStack {
            AppTheme.Colors.splashBackdropGradient
                .ignoresSafeArea()

            if reduceMotion {
                reducedMotionContent
            } else {
                animatedContent
            }
        }
        .ignoresSafeArea()
        .scaleEffect(isExitingVisual ? 1.07 : 1.0)
        .opacity(isExitingVisual ? 0.0 : 1.0)
        .contentShape(Rectangle())
        .onAppear {
            latestIsReady = isReady
        }
        .onChange(of: isReady) { _, newValue in
            latestIsReady = newValue
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .background {
                finishImmediately()
            }
        }
        .onDisappear {
            dismissTask?.cancel()
            dismissTask = nil
        }
        .onTapGesture {
            triggerDismiss()
        }
        .task {
            startDate = Date()
            latestIsReady = isReady
            if reduceMotion {
                emblemAppeared = true
                textAppeared = true
                try? await Task.sleep(nanoseconds: 550_000_000)
                guard !Task.isCancelled else { return }
                triggerDismiss()
                return
            }

            // Stage crisp emblem & typography entrances synced to the R-peak crossing center.
            withAnimation(.spring(response: 0.48, dampingFraction: 0.78).delay(0.32)) {
                emblemAppeared = true
            }
            withAnimation(.easeOut(duration: 0.46).delay(0.46)) {
                textAppeared = true
            }

            // Hold for core choreography (~1.35s), then wait briefly if first-ever uncached
            // load is still in flight (capped at 2.0s total so launch never feels stuck).
            try? await Task.sleep(nanoseconds: 1_350_000_000)
            let deadline = Date().addingTimeInterval(0.65)
            while !latestIsReady && Date() < deadline && !Task.isCancelled && phase == .animating {
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
            guard !Task.isCancelled else { return }
            triggerDismiss()
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Loading DataDonor")
    }

    // MARK: - Animated 120Hz Path

    private var animatedContent: some View {
        TimelineView(.animation(minimumInterval: nil, paused: phase != .animating || scenePhase != .active)) { timeline in
            let t = max(0, timeline.date.timeIntervalSince(startDate))
            let beatScale = SplashWaveformMath.lubDubScale(at: t)
            let ringRotation = Angle.degrees(t * 95)

            ZStack {
                // Single-pass GPU Canvas for ambient aura, ECG pulse sweep, ripples, and converging nodes.
                Canvas(opaque: false, rendersAsynchronously: true) { context, size in
                    guard size.width > 0, size.height > 0, size.width.isFinite, size.height.isFinite else { return }
                    drawAtmosphericBackdrop(in: &context, size: size, t: t)
                    drawECGWaveform(in: &context, size: size, t: t)
                    drawPulseRipples(in: &context, size: size, t: t)
                    drawConvergingNodes(in: &context, size: size, t: t)
                }
                .ignoresSafeArea()
                .allowsHitTesting(false)

                Color.clear
                    .frame(width: 108, height: 108)
                    .overlay {
                        emblemMedallion(ringRotation: ringRotation)
                            .scaleEffect((emblemAppeared ? 1.0 : 0.70) * beatScale)
                            .opacity(emblemAppeared ? 1.0 : 0.0)
                    }
                    .overlay(alignment: .bottom) {
                        brandWordmark(t: t)
                            .fixedSize()
                            .alignmentGuide(.bottom) { d in d[.top] - 24 }
                            .offset(y: textAppeared ? 0 : 12)
                            .opacity(textAppeared ? 1.0 : 0.0)
                    }
                    .offset(y: Self.focalYOffset)
            }
        }
    }

    // MARK: - Reduce Motion Path

    private var reducedMotionContent: some View {
        Color.clear
            .frame(width: 108, height: 108)
            .overlay {
                emblemMedallion(ringRotation: .zero)
            }
            .overlay(alignment: .bottom) {
                brandWordmark(t: 1.0)
                    .fixedSize()
                    .alignmentGuide(.bottom) { d in d[.top] - 24 }
            }
            .offset(y: Self.focalYOffset)
    }

    // MARK: - Centerpiece Emblem & Typography

    private func emblemMedallion(ringRotation: Angle) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 30, style: .continuous)
                .fill(AppTheme.Colors.splashGlassSurface)
                .frame(width: 108, height: 108)
                .overlay(
                    RoundedRectangle(cornerRadius: 30, style: .continuous)
                        .strokeBorder(AppTheme.Colors.splashRingGradient(angle: ringRotation), lineWidth: 1.75)
                        .opacity(0.85)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 30, style: .continuous)
                        .strokeBorder(AppTheme.Colors.splashGlassBorder, lineWidth: 0.75)
                )

            Image("Logo")
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 78, height: 78)
                .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        }
    }

    private func brandWordmark(t: Double) -> some View {
        VStack(spacing: 10) {
            Text("DataDonor")
                .font(.system(size: 33, weight: .bold, design: .rounded))
                .tracking(textAppeared ? 0.2 : 4.0)
                .foregroundColor(AppTheme.Colors.splashTitlePrimary)

            HStack(spacing: 7) {
                vitalDot(color: AppTheme.Colors.coral, phase: t * 4.5)
                vitalDot(color: AppTheme.Colors.splashViolet, phase: t * 4.5 - 0.7)
                vitalDot(color: AppTheme.Colors.emerald, phase: t * 4.5 - 1.4)
                vitalDot(color: AppTheme.Colors.ochre, phase: t * 4.5 - 2.1)

                Text(isReady ? "Personal Health Telemetry" : "Syncing Vitals")
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .tracking(0.6)
                    .foregroundColor(AppTheme.Colors.splashTitleSecondary)
                    .padding(.leading, 3)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .background(
                Capsule()
                    .fill(AppTheme.Colors.splashGlassSurface)
            )
            .overlay(
                Capsule()
                    .strokeBorder(AppTheme.Colors.splashGlassBorder, lineWidth: 0.75)
            )
        }
    }

    private func vitalDot(color: Color, phase: Double) -> some View {
        let pulse = reduceMotion ? 1.0 : (0.62 + 0.38 * (0.5 + 0.5 * sin(phase)))
        return Circle()
            .fill(color)
            .frame(width: 5.5, height: 5.5)
            .opacity(pulse)
    }

    // MARK: - Single-Pass Canvas Layers

    private func drawAtmosphericBackdrop(in context: inout GraphicsContext, size: CGSize, t: Double) {
        let center = CGPoint(x: size.width * 0.5, y: size.height * 0.5 + Self.focalYOffset)
        let breath = 0.5 + 0.5 * sin(t * 2.2)
        let peakBloom = exp(-pow((t - 0.48) / 0.26, 2))

        // Upper-left soft violet aura (radial gradient avoids expensive Gaussian blur passes).
        let topLeftCenter = CGPoint(x: size.width * 0.22, y: size.height * 0.24)
        let topLeftRadius = max(size.width, size.height) * 0.48
        context.fill(
            Path(ellipseIn: CGRect(
                x: topLeftCenter.x - topLeftRadius,
                y: topLeftCenter.y - topLeftRadius,
                width: topLeftRadius * 2,
                height: topLeftRadius * 2
            )),
            with: .radialGradient(
                Gradient(colors: [
                    AppTheme.Colors.splashViolet.opacity(0.20 + 0.05 * breath),
                    AppTheme.Colors.splashViolet.opacity(0.0)
                ]),
                center: topLeftCenter,
                startRadius: 0,
                endRadius: topLeftRadius
            )
        )

        // Lower-right soft teal/emerald aura.
        let bottomRightCenter = CGPoint(x: size.width * 0.82, y: size.height * 0.74)
        let bottomRightRadius = max(size.width, size.height) * 0.50
        context.fill(
            Path(ellipseIn: CGRect(
                x: bottomRightCenter.x - bottomRightRadius,
                y: bottomRightCenter.y - bottomRightRadius,
                width: bottomRightRadius * 2,
                height: bottomRightRadius * 2
            )),
            with: .radialGradient(
                Gradient(colors: [
                    AppTheme.Colors.teal.opacity(0.18 + 0.05 * (1.0 - breath)),
                    AppTheme.Colors.teal.opacity(0.0)
                ]),
                center: bottomRightCenter,
                startRadius: 0,
                endRadius: bottomRightRadius
            )
        )

        // Center ignition glow synced with the ECG R-peak strike.
        let coreRadius: CGFloat = 155 + CGFloat(peakBloom) * 55
        context.fill(
            Path(ellipseIn: CGRect(
                x: center.x - coreRadius,
                y: center.y - coreRadius,
                width: coreRadius * 2,
                height: coreRadius * 2
            )),
            with: .radialGradient(
                Gradient(colors: [
                    AppTheme.Colors.emerald.opacity(0.14 + 0.22 * peakBloom),
                    AppTheme.Colors.splashViolet.opacity(0.06 + 0.08 * peakBloom),
                    Color.clear
                ]),
                center: center,
                startRadius: 0,
                endRadius: coreRadius
            )
        )
    }

    private func drawECGWaveform(in context: inout GraphicsContext, size: CGSize, t: Double) {
        let sweepProgress = SplashWaveformMath.easeInOutCubic(t / 0.88)
        let fadeOut: Double = t < 0.78 ? 1.0 : max(0.0, 1.0 - (t - 0.78) / 0.38)
        guard sweepProgress > 0.005, fadeOut > 0.005 else { return }

        let baselineY = size.height * 0.5 + Self.focalYOffset
        let amplitude: CGFloat = 62
        let trailLength = 0.58
        let startU = max(0.0, sweepProgress - trailLength)

        let lut = SplashWaveformMath.ecgLUT
        let startIdx = max(0, Int(floor(startU * Double(SplashWaveformMath.sampleCount))))
        let endIdx = min(SplashWaveformMath.sampleCount, Int(ceil(sweepProgress * Double(SplashWaveformMath.sampleCount))))
        guard endIdx > startIdx else { return }

        var path = Path()
        for i in startIdx...endIdx {
            let pt = lut[i]
            let x = pt.u * size.width
            let y = baselineY - pt.y * amplitude
            if i == startIdx {
                path.move(to: CGPoint(x: x, y: y))
            } else {
                path.addLine(to: CGPoint(x: x, y: y))
            }
        }

        let startX = CGFloat(startU) * size.width
        let headX = CGFloat(sweepProgress) * size.width
        let headPt = lut[endIdx]
        let headPoint = CGPoint(x: headPt.u * size.width, y: baselineY - headPt.y * amplitude)

        // Wide soft glow stroke behind the crisp core trace.
        context.stroke(
            path,
            with: .linearGradient(
                Gradient(colors: [
                    AppTheme.Colors.splashViolet.opacity(0.0),
                    AppTheme.Colors.teal.opacity(0.18 * fadeOut),
                    AppTheme.Colors.emerald.opacity(0.28 * fadeOut)
                ]),
                startPoint: CGPoint(x: startX, y: baselineY),
                endPoint: CGPoint(x: headX, y: baselineY)
            ),
            style: StrokeStyle(lineWidth: 9, lineCap: .round, lineJoin: .round)
        )

        // Sharp luminous ECG core trace.
        context.stroke(
            path,
            with: .linearGradient(
                Gradient(colors: [
                    AppTheme.Colors.splashViolet.opacity(0.0),
                    AppTheme.Colors.splashViolet.opacity(0.55 * fadeOut),
                    AppTheme.Colors.teal.opacity(0.95 * fadeOut),
                    AppTheme.Colors.emerald.opacity(fadeOut)
                ]),
                startPoint: CGPoint(x: startX, y: baselineY),
                endPoint: CGPoint(x: headX, y: baselineY)
            ),
            style: StrokeStyle(lineWidth: 2.3, lineCap: .round, lineJoin: .round)
        )

        // Radiant comet head at the leading tip of the pulse.
        if sweepProgress < 0.99 {
            let glowR: CGFloat = 14
            context.fill(
                Path(ellipseIn: CGRect(x: headPoint.x - glowR, y: headPoint.y - glowR, width: glowR * 2, height: glowR * 2)),
                with: .radialGradient(
                    Gradient(colors: [
                        Color.white.opacity(0.95 * fadeOut),
                        AppTheme.Colors.emerald.opacity(0.55 * fadeOut),
                        Color.clear
                    ]),
                    center: headPoint,
                    startRadius: 0,
                    endRadius: glowR
                )
            )
        }
    }

    private func drawPulseRipples(in context: inout GraphicsContext, size: CGSize, t: Double) {
        let strikeTime = 0.42
        guard t >= strikeTime else { return }

        let center = CGPoint(x: size.width * 0.5, y: size.height * 0.5 + Self.focalYOffset)
        let duration = 0.88

        for spec in Self.rippleSpecs {
            let localT = t - strikeTime - spec.delay
            guard localT > 0, localT < duration else { continue }
            let raw = localT / duration
            let eased = SplashWaveformMath.easeOutCubic(raw)
            let radius: CGFloat = 46 + CGFloat(eased) * 155
            let alpha = pow(1.0 - raw, 2.0) * 0.48
            let lineWidth: CGFloat = max(0.5, 2.2 * CGFloat(1.0 - raw))

            let ringRect = CGRect(
                x: center.x - radius,
                y: center.y - radius,
                width: radius * 2,
                height: radius * 2
            )
            context.stroke(
                Path(ellipseIn: ringRect),
                with: .color(spec.color.opacity(alpha)),
                lineWidth: lineWidth
            )
        }
    }

    private func drawConvergingNodes(in context: inout GraphicsContext, size: CGSize, t: Double) {
        let center = CGPoint(x: size.width * 0.5, y: size.height * 0.5 + Self.focalYOffset)
        let travelDuration = 0.72

        for node in Self.orbitalNodes {
            let localT = t - node.delay
            guard localT > 0, localT < travelDuration else { continue }

            let p = localT / travelDuration
            let eased = SplashWaveformMath.easeInOutCubic(p)
            let alpha = sin(p * .pi) // smooth fade-in at outer orbit, dissolve into heart at arrival

            // Draw a delicate 6-segment tapered orbital comet trail.
            let trailSteps = 6
            for step in stride(from: trailSteps, through: 1, by: -1) {
                let trailP = max(0.0, p - Double(step) * 0.028)
                let trailEased = SplashWaveformMath.easeInOutCubic(trailP)
                let pt = orbitalPoint(center: center, node: node, progress: trailEased)
                let factor = 1.0 - Double(step) / Double(trailSteps + 1)
                let r = CGFloat(2.0 + 1.8 * factor)
                context.fill(
                    Path(ellipseIn: CGRect(x: pt.x - r, y: pt.y - r, width: r * 2, height: r * 2)),
                    with: .color(node.color.opacity(alpha * factor * 0.55))
                )
            }

            let head = orbitalPoint(center: center, node: node, progress: eased)
            let haloR: CGFloat = 9
            context.fill(
                Path(ellipseIn: CGRect(x: head.x - haloR, y: head.y - haloR, width: haloR * 2, height: haloR * 2)),
                with: .radialGradient(
                    Gradient(colors: [
                        Color.white.opacity(0.9 * alpha),
                        node.color.opacity(0.65 * alpha),
                        Color.clear
                    ]),
                    center: head,
                    startRadius: 0,
                    endRadius: haloR
                )
            )
        }
    }

    private func orbitalPoint(center: CGPoint, node: OrbitalNode, progress: Double) -> CGPoint {
        let radius = node.startRadius * CGFloat(1.0 - progress)
        let angle = node.startAngle + progress * 1.45
        return CGPoint(
            x: center.x + cos(angle) * radius,
            y: center.y + sin(angle) * radius
        )
    }

    // MARK: - Dismissal

    private func triggerDismiss() {
        guard phase == .animating else { return }
        phase = .dismissing
        withAnimation(.easeInOut(duration: 0.36)) {
            isExitingVisual = true
        }
        dismissTask?.cancel()
        dismissTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 380_000_000)
            guard !Task.isCancelled, phase == .dismissing else { return }
            phase = .finished
            onFinished()
        }
    }

    private func finishImmediately() {
        guard phase != .finished else { return }
        phase = .finished
        dismissTask?.cancel()
        dismissTask = nil
        onFinished()
    }
}
