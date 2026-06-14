import SwiftUI

// MARK: - Recovery Ring (§9.3) — THE signature component
//
// A 240° open gauge arc (gap at the bottom), thick rounded-cap stroke filled
// with an AngularGradient sampling the recovery gradient (indigo → mint), filled
// to score/100 of the 240° span over a faint track. A soft outer BLOOM whose
// intensity scales with score; a luminous leading bead at the fill tip; a draw-in
// animation when the value changes. Center shows the big monospaced number (no %),
// a state word tinted to the sampled color, and an optional supporting line.

public struct RecoveryRing: View {

    /// Recovery score 0...100.
    public var score: Double
    /// Optional supporting line, e.g. "HRV 62ms · RHR 51 · ready for moderate strain".
    public var supporting: String?
    /// Diameter of the ring.
    public var diameter: CGFloat
    /// Stroke thickness (14–18pt per spec).
    public var lineWidth: CGFloat
    /// Whether to show the center read-out (number + state + supporting).
    public var showsLabel: Bool
    /// Whether hovering the ring shows a subtle tooltip (score + state word).
    public var showsHover: Bool
    /// Formats the score for the hover tooltip's bold line.
    public var valueFormat: (Double) -> String

    public init(
        score: Double,
        supporting: String? = nil,
        diameter: CGFloat = 240,
        lineWidth: CGFloat = 16,
        showsLabel: Bool = true,
        showsHover: Bool = true,
        valueFormat: @escaping (Double) -> String = { "Recovery \(Int($0.rounded()))" }
    ) {
        self.score = score
        self.supporting = supporting
        self.diameter = diameter
        self.lineWidth = lineWidth
        self.showsLabel = showsLabel
        self.showsHover = showsHover
        self.valueFormat = valueFormat
    }

    /// Cursor location while hovering, in ring-local coordinates.
    @State private var hoverPoint: CGPoint? = nil
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    // 240° open gauge: gap centered at the bottom.
    // Sweep from 150° to 390° (== 30°), i.e. start lower-left, end lower-right.
    private let arcSpanDegrees: Double = 240
    private var startAngle: Angle { .degrees(150) }   // lower-left
    private var endAngle: Angle { .degrees(150 + arcSpanDegrees) } // 390° == 30°

    // Animated fill fraction so changing `score` draws the arc in.
    @State private var animatedFraction: Double = 0
    @State private var bloomPulse: Bool = false

    private var fraction: Double { min(max(score / 100.0, 0), 1) }
    private var tipColor: Color { StrandPalette.recoveryColor(score) }
    private var stateWord: String { StrandPalette.recoveryState(score) }
    /// Bloom intensity 0.18...0.55 scaled by score.
    private var bloomOpacity: Double { 0.18 + 0.37 * fraction }
    private var bloomRadius: CGFloat { lineWidth * (0.9 + 1.4 * fraction) }

    public var body: some View {
        ZStack {
            ring
            if showsLabel { centerLabel }
            if showsHover, let pt = hoverPoint {
                PositionedTooltip(
                    anchor: pt,
                    container: CGSize(width: diameter, height: diameter),
                    tooltip: ChartTooltip(
                        value: valueFormat(score),
                        label: stateWord,
                        accent: tipColor
                    )
                )
                .animation(StrandMotion.fade, value: hoverPoint == nil)
            }
        }
        .frame(width: diameter, height: diameter)
        // Collapse the loose center Text fragments (and the otherwise-unlabeled
        // standalone ring) into one coherent VoiceOver element.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(valueFormat(score)))
        .accessibilityValue(Text(stateWord))
        .contentShape(Rectangle())
        .onContinuousHover(coordinateSpace: .local) { phase in
            guard showsHover else { return }
            switch phase {
            case .active(let location): hoverPoint = location
            case .ended: hoverPoint = nil
            }
        }
        .onAppear {
            withAnimation(StrandMotion.drawIn) { animatedFraction = fraction }
            // Reduce Motion: leave the bloom at its resting opacity instead of breathing.
            if !reduceMotion { bloomPulse = true }
        }
        .onChange(of: score) { _ in
            withAnimation(StrandMotion.drawIn) { animatedFraction = fraction }
        }
    }

    // MARK: Ring assembly

    private var ring: some View {
        ZStack {
            // Outer bloom: a blurred copy of the filled arc, opacity scaled by score,
            // gently breathing for life.
            arcShape(to: animatedFraction)
                .stroke(
                    AngularGradient(
                        gradient: StrandPalette.recoveryGradient,
                        center: .center,
                        startAngle: startAngle,
                        endAngle: endAngle
                    ),
                    style: StrokeStyle(lineWidth: lineWidth * 1.05, lineCap: .round)
                )
                .blur(radius: bloomRadius)
                .opacity(bloomOpacity * (bloomPulse ? 1.0 : 0.78))
                .animation(StrandMotion.breathe(reduced: reduceMotion), value: bloomPulse)
                .blendMode(.plusLighter)

            // Faint full-span track (remainder).
            arcShape(to: 1.0)
                .stroke(
                    StrandPalette.hairline.opacity(0.55),
                    style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)
                )

            // The filled gradient arc.
            arcShape(to: animatedFraction)
                .stroke(
                    AngularGradient(
                        gradient: StrandPalette.recoveryGradient,
                        center: .center,
                        startAngle: startAngle,
                        endAngle: endAngle
                    ),
                    style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)
                )

            // Luminous leading bead at the fill tip.
            if animatedFraction > 0.001 {
                bead
            }
        }
    }

    // MARK: Leading bead

    private var bead: some View {
        GeometryReader { geo in
            let radius = (min(geo.size.width, geo.size.height) - lineWidth) / 2
            let center = CGPoint(x: geo.size.width / 2, y: geo.size.height / 2)
            let tipAngle = startAngle.radians + (arcSpanDegrees * .pi / 180) * animatedFraction
            let pt = CGPoint(
                x: center.x + radius * cos(tipAngle),
                y: center.y + radius * sin(tipAngle)
            )
            ZStack {
                // soft halo
                Circle()
                    .fill(tipColor)
                    .frame(width: lineWidth * 2.4, height: lineWidth * 2.4)
                    .blur(radius: lineWidth * 0.9)
                    .opacity(0.7)
                    .blendMode(.plusLighter)
                // bright core
                Circle()
                    .fill(Color.white)
                    .frame(width: lineWidth * 0.62, height: lineWidth * 0.62)
                    .overlay(Circle().fill(tipColor).opacity(0.35))
            }
            .position(pt)
        }
    }

    // MARK: Center read-out

    private var centerLabel: some View {
        VStack(spacing: 2) {
            Text(numberString)
                .font(StrandFont.display(diameter * 0.30))
                .foregroundStyle(StrandPalette.textPrimary)
                .contentTransition(.numericText())
            Text(stateWord)
                .font(StrandFont.overline)
                .tracking(StrandFont.overlineTracking)
                .foregroundStyle(tipColor)
            if let supporting {
                Text(supporting)
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: diameter * 0.78)
                    .padding(.top, 4)
            }
        }
    }

    private var numberString: String {
        String(Int(score.rounded()))
    }

    // MARK: Arc shape

    private func arcShape(to fraction: Double) -> RecoveryArc {
        RecoveryArc(
            startAngle: startAngle,
            spanDegrees: arcSpanDegrees,
            fraction: fraction,
            lineWidth: lineWidth
        )
    }
}

// MARK: - Arc Shape

/// An open 240° gauge arc that fills clockwise from the start angle.
public struct RecoveryArc: Shape {
    public var startAngle: Angle
    public var spanDegrees: Double
    public var fraction: Double
    public var lineWidth: CGFloat

    public var animatableData: Double {
        get { fraction }
        set { fraction = newValue }
    }

    public func path(in rect: CGRect) -> Path {
        let radius = (min(rect.width, rect.height) - lineWidth) / 2
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let end = Angle.degrees(startAngle.degrees + spanDegrees * min(max(fraction, 0), 1))
        var path = Path()
        path.addArc(
            center: center,
            radius: radius,
            startAngle: startAngle,
            endAngle: end,
            clockwise: false
        )
        return path
    }
}

#if DEBUG
#Preview("RecoveryRing — scores") {
    VStack(spacing: 16) {
        HStack(spacing: 28) {
            RecoveryRing(score: 22, supporting: "HRV 38ms · RHR 58 · take it easy", diameter: 220)
            RecoveryRing(score: 55, supporting: "HRV 49ms · RHR 54 · moderate ok", diameter: 220)
        }
        Text("Hover a ring for a recovery + state-word tooltip.")
            .font(StrandFont.footnote).foregroundStyle(StrandPalette.textTertiary)
    }
    .padding(40)
    .background(StrandPalette.surfaceBase)
    .preferredColorScheme(.dark)
}

#Preview("RecoveryRing — primed/peak") {
    HStack(spacing: 28) {
        RecoveryRing(score: 78, supporting: "HRV 62ms · RHR 51 · ready for moderate strain", diameter: 220)
        RecoveryRing(score: 91, supporting: "HRV 74ms · RHR 47 · primed to push", diameter: 220)
    }
    .padding(40)
    .background(StrandPalette.surfaceBase)
    .preferredColorScheme(.dark)
}

private struct RecoveryRingLive: View {
    @State private var score: Double = 64
    var body: some View {
        VStack(spacing: 24) {
            RecoveryRing(score: score, supporting: "drag to feel the draw-in", diameter: 260)
            Slider(value: $score, in: 0...100)
                .frame(width: 280)
        }
        .padding(40)
        .background(StrandPalette.surfaceBase)
        .preferredColorScheme(.dark)
    }
}

#Preview("RecoveryRing — interactive") { RecoveryRingLive() }
#endif
