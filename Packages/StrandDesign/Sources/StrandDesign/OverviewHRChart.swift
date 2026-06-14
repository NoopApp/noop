import SwiftUI
import Charts

// MARK: - Overview HR Chart (§ Today — day-in-review)
//
// The Today screen's 24h heart-rate line, annotated like WHOOP's "Overview HR":
// the rose HR curve overlaid with a sleep band, a recovery marker at wake, a
// strain marker at "now", and a sport glyph at each workout's HR peak. The line +
// hover affordance mirror `TrendChart`; this view adds the marker layers and pins
// the x-axis to the HR window so markers never stretch the timeline.
//
// Colours stay in NOOP's language (rose line, green recovery, warm strain, indigo
// sleep) rather than copying WHOOP's blue. Tokens only — never hardcode hex.

public struct OverviewHRChart: View {

    /// The sleep period to shade as a band, with an optional corner label (e.g. duration "6:06").
    public struct SleepSpan: Sendable {
        public var start: Date
        public var end: Date
        public var label: String?
        public init(start: Date, end: Date, label: String? = nil) {
            self.start = start; self.end = end; self.label = label
        }
    }

    /// A workout window; the sport glyph is placed at the HR peak inside [start, end].
    public struct WorkoutSpan: Identifiable, Sendable {
        public let id = UUID()
        public var start: Date
        public var end: Date
        public var symbol: String          // SF Symbol (see `sportSymbol`)
        public init(start: Date, end: Date, symbol: String) {
            self.start = start; self.end = end; self.symbol = symbol
        }
    }

    /// A labelled vertical marker pinned to a moment in the day (recovery at wake, strain at now).
    public struct EdgeMarker: Sendable {
        public var date: Date
        public var label: String
        public var color: Color
        public var alignment: HorizontalAlignment
        public init(date: Date, label: String, color: Color, alignment: HorizontalAlignment = .leading) {
            self.date = date; self.label = label; self.color = color; self.alignment = alignment
        }
    }

    public var points: [TrendPoint]
    public var sleep: SleepSpan?
    public var workouts: [WorkoutSpan]
    public var recovery: EdgeMarker?
    public var effort: EdgeMarker?
    public var gradient: Gradient
    public var valueRange: ClosedRange<Double>
    /// Explicit x-axis window. When set, the axis spans exactly this range (so missing data shows as
    /// empty space); when nil, the axis is derived from the data extent.
    public var xRange: ClosedRange<Date>?
    public var height: CGFloat
    public var showsHover: Bool
    public var valueFormat: (Double) -> String
    public var dateFormat: (Date) -> String

    /// Tint for the workout glyph badges (NOOP's warm strain accent by default).
    public var workoutTint: Color

    private let averageValue: Double

    public init(
        points: [TrendPoint],
        sleep: SleepSpan? = nil,
        workouts: [WorkoutSpan] = [],
        recovery: EdgeMarker? = nil,
        effort: EdgeMarker? = nil,
        gradient: Gradient = Gradient(colors: [StrandPalette.metricRose.opacity(0.55), StrandPalette.metricRose]),
        valueRange: ClosedRange<Double> = 40...120,
        xRange: ClosedRange<Date>? = nil,
        height: CGFloat = 220,
        showsHover: Bool = true,
        workoutTint: Color = StrandPalette.strain033,
        valueFormat: @escaping (Double) -> String = { String(Int($0.rounded())) },
        dateFormat: @escaping (Date) -> String = { TrendChart.defaultDateString($0) }
    ) {
        let sorted = points.sorted { $0.date < $1.date }
        self.points = sorted
        self.sleep = sleep
        self.workouts = workouts
        self.recovery = recovery
        self.effort = effort
        self.gradient = gradient
        self.valueRange = valueRange
        self.xRange = xRange
        self.height = height
        self.showsHover = showsHover
        self.workoutTint = workoutTint
        self.valueFormat = valueFormat
        self.dateFormat = dateFormat
        self.averageValue = sorted.isEmpty
            ? valueRange.lowerBound
            : sorted.map(\.value).reduce(0, +) / Double(sorted.count)
    }

    @State private var hoverX: CGFloat? = nil

    // MARK: Geometry helpers

    /// The x-axis window. When the caller supplies `xRange` (e.g. a full calendar day for a past
    /// date), that wins — so a stretch with no samples reads as visible empty space rather than the
    /// axis silently collapsing to the data extent. Otherwise it's pinned to the HR data so markers
    /// (sleep onset the night before, etc.) can't stretch the timeline. Safe even for sparse input.
    private var xDomain: ClosedRange<Date> {
        if let xRange, xRange.upperBound > xRange.lowerBound { return xRange }
        let lo = points.first?.date ?? Date(timeIntervalSince1970: 0)
        let hi = points.last?.date ?? lo.addingTimeInterval(3600)
        return hi > lo ? lo...hi : lo...lo.addingTimeInterval(3600)
    }

    private func clampX(_ d: Date) -> Date {
        min(max(d, xDomain.lowerBound), xDomain.upperBound)
    }

    /// Map a value onto 0...1 over the value range, for the gradient stops.
    private func unit(_ value: Double) -> Double {
        let lo = valueRange.lowerBound, hi = valueRange.upperBound
        guard hi > lo else { return 0 }
        return min(max((value - lo) / (hi - lo), 0), 1)
    }

    private var valueGradient: LinearGradient {
        LinearGradient(gradient: gradient, startPoint: .bottom, endPoint: .top)
    }

    /// The peak HR sample inside a workout window, where its glyph is anchored.
    private func peak(in w: WorkoutSpan) -> TrendPoint? {
        points
            .filter { $0.date >= w.start && $0.date <= w.end }
            .max(by: { $0.value < $1.value })
    }

    private func nearestPoint(toX x: CGFloat, proxy: ChartProxy, plot: CGRect) -> TrendPoint? {
        guard !points.isEmpty else { return nil }
        let relX = x - plot.minX
        guard let date: Date = proxy.value(atX: relX) else { return nil }
        return points.min(by: {
            abs($0.date.timeIntervalSince(date)) < abs($1.date.timeIntervalSince(date))
        })
    }

    // MARK: Mark layers
    //
    // Only lines/bands live as Chart marks. All text labels + workout glyphs are drawn in the
    // overlay (below) via the proxy — Swift Charts' `.annotation` overflow-clamping needs macOS 14
    // and gets clipped by the card's fixed height on 13, so we position labels ourselves.

    @ChartContentBuilder private var marks: some ChartContent {
        // Sleep band — shaded region behind the curve (drawn first so the HR line/area sit on top).
        if let sleep, sleep.end > xDomain.lowerBound {
            RectangleMark(
                xStart: .value("Sleep start", clampX(sleep.start)),
                xEnd: .value("Sleep end", clampX(sleep.end))
            )
            .foregroundStyle(StrandPalette.sleepDeep.opacity(0.32))
        }

        ForEach(points) { p in
            AreaMark(x: .value("Time", p.date), y: .value("BPM", p.value))
                .interpolationMethod(.catmullRom)
                .foregroundStyle(
                    LinearGradient(
                        colors: [
                            StrandPalette.sample(stops: gradient.toStops(), at: unit(averageValue)).opacity(0.28),
                            Color.clear
                        ],
                        startPoint: .top, endPoint: .bottom
                    )
                )
        }
        ForEach(points) { p in
            LineMark(x: .value("Time", p.date), y: .value("BPM", p.value))
                .interpolationMethod(.catmullRom)
                .lineStyle(StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
                .foregroundStyle(valueGradient)
        }

        // Wake divider — the sleep→day boundary. Always shown with a sleep band so the band reads
        // even before recovery calibrates (when the green recovery rule is absent).
        if let sleep, sleep.end > xDomain.lowerBound, sleep.end < xDomain.upperBound {
            RuleMark(x: .value("Wake", clampX(sleep.end)))
                .foregroundStyle(StrandPalette.sleepLight.opacity(0.5))
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
        }
        if let recovery {
            RuleMark(x: .value("Recovery", clampX(recovery.date)))
                .foregroundStyle(recovery.color.opacity(0.85))
                .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
        }
        if let effort {
            RuleMark(x: .value("Effort", clampX(effort.date)))
                .foregroundStyle(effort.color.opacity(0.85))
                .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
        }
    }

    // MARK: Overlay helpers

    /// Screen x for a date (plot-relative position offset into container coords). nil if off-scale.
    private func xPos(_ date: Date, _ proxy: ChartProxy, _ plot: CGRect) -> CGFloat? {
        proxy.position(forX: date).map { $0 + plot.minX }
    }

    /// Rough label width for edge-clamping (footnote ≈ 6.5pt/char + padding/glyph).
    private func estWidth(_ s: String, extra: CGFloat = 18) -> CGFloat { CGFloat(s.count) * 6.5 + extra }

    /// Place a label centred on `x`, clamped so it never spills past the plot edges.
    @ViewBuilder
    private func placed<V: View>(_ view: V, atX x: CGFloat, topY: CGFloat, width: CGFloat, plot: CGRect) -> some View {
        let half = width / 2
        let cx = min(max(x, plot.minX + half + 4), plot.maxX - half - 4)
        view.position(x: cx, y: topY)
    }

    @ViewBuilder
    private func markerLabels(proxy: ChartProxy, plot: CGRect) -> some View {
        let topY = plot.minY + 12
        if let sleep, let label = sleep.label, sleep.end > xDomain.lowerBound {
            placed(SleepBandLabel(text: label),
                   atX: xPos(clampX(sleep.start), proxy, plot) ?? plot.minX,
                   topY: topY, width: estWidth(label, extra: 34), plot: plot)
        }
        if let recovery, let rx = xPos(clampX(recovery.date), proxy, plot) {
            placed(MarkerLabel(text: recovery.label, color: recovery.color),
                   atX: rx, topY: topY, width: estWidth(recovery.label), plot: plot)
        }
        if let effort, let sx = xPos(clampX(effort.date), proxy, plot) {
            placed(MarkerLabel(text: effort.label, color: effort.color),
                   atX: sx, topY: topY, width: estWidth(effort.label), plot: plot)
        }
        ForEach(workouts) { w in
            if let pk = peak(in: w),
               let px = xPos(pk.date, proxy, plot),
               let pyRel = proxy.position(forY: pk.value) {
                let cx = min(max(px, plot.minX + 14), plot.maxX - 14)
                WorkoutBadge(symbol: w.symbol, tint: workoutTint)
                    .position(x: cx, y: max(topY + 26, pyRel + plot.minY - 20))
            }
        }
    }

    @ViewBuilder
    private func hoverLayer(proxy: ChartProxy, plot: CGRect, container: CGSize) -> some View {
        if showsHover, let hx = hoverX,
           let p = nearestPoint(toX: hx, proxy: proxy, plot: plot),
           let pxRel = proxy.position(forX: p.date),
           let pyRel = proxy.position(forY: p.value) {
            let cx = pxRel + plot.minX
            let cy = pyRel + plot.minY
            let color = StrandPalette.sample(stops: gradient.toStops(), at: unit(p.value))
            CrosshairRule(x: cx, height: container.height)
            HighlightDot(color: color).position(x: cx, y: cy)
            PositionedTooltip(
                anchor: CGPoint(x: cx, y: cy),
                container: container,
                tooltip: ChartTooltip(value: valueFormat(p.value), label: dateFormat(p.date), accent: color)
            )
        }
    }

    // MARK: Body

    public var body: some View {
        Chart { marks }
        .chartXScale(domain: xDomain)
        .chartYScale(domain: valueRange)
        // catmullRom overshoots past the data on sharp turns and the area gradient draws
        // unclipped — clip the plot so a spiky HR curve doesn't bleed past the chart (see TrendChart).
        .chartPlotStyle { plotArea in plotArea.clipped() }
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 5)) { _ in
                AxisGridLine().foregroundStyle(StrandPalette.hairline.opacity(0.4))
                AxisValueLabel().foregroundStyle(StrandPalette.textTertiary)
                    .font(StrandFont.footnote)
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { _ in
                AxisGridLine().foregroundStyle(StrandPalette.hairline.opacity(0.4))
                AxisValueLabel().foregroundStyle(StrandPalette.textTertiary)
                    .font(StrandFont.footnote)
            }
        }
        .chartOverlay { proxy in
            GeometryReader { geo in
                let plot = geo[proxy.plotAreaFrame]
                ZStack(alignment: .topLeading) {
                    markerLabels(proxy: proxy, plot: plot)
                    hoverLayer(proxy: proxy, plot: plot, container: geo.size)
                }
                .animation(StrandMotion.fade, value: hoverX)
                .contentShape(Rectangle())
                .onContinuousHover(coordinateSpace: .local) { phase in
                    guard showsHover else { return }
                    // Non-animating transaction: otherwise crossing the plot edge re-runs the
                    // line's draw-on animation and flickers the curve (mirrors TrendChart #104).
                    var tx = Transaction()
                    tx.disablesAnimations = true
                    withTransaction(tx) {
                        switch phase {
                        case .active(let location): hoverX = location.x
                        case .ended: hoverX = nil
                        }
                    }
                }
            }
        }
        .frame(height: height)
    }
}

// MARK: - Marker chrome

/// Sport glyph in a tinted badge, anchored above a workout's HR peak.
private struct WorkoutBadge: View {
    let symbol: String
    let tint: Color
    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 11, weight: .bold))
            .foregroundStyle(StrandPalette.textPrimary)
            .frame(width: 22, height: 22)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(tint)
            )
            .shadow(color: tint.opacity(0.5), radius: 4, y: 1)
            .allowsHitTesting(false)
    }
}

/// Small caps read-out for the recovery / strain edge markers (e.g. "67% Recovery").
private struct MarkerLabel: View {
    let text: String
    let color: Color
    var body: some View {
        Text(text)
            .font(StrandFont.footnote)
            .fontWeight(.semibold)
            .foregroundStyle(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(StrandPalette.surfaceOverlay.opacity(0.92))
            )
            .fixedSize()
            .allowsHitTesting(false)
    }
}

/// Moon glyph + sleep duration, shown at the leading corner of the sleep band.
private struct SleepBandLabel: View {
    let text: String
    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "moon.fill").font(.system(size: 9))
            Text(text).font(StrandFont.footnote).fontWeight(.semibold)
        }
        .foregroundStyle(StrandPalette.sleepLight)
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(StrandPalette.surfaceOverlay.opacity(0.92))
        )
        .fixedSize()
        .allowsHitTesting(false)
    }
}

#if DEBUG
#Preview("OverviewHRChart") {
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let pts: [TrendPoint] = (0..<288).map { i in
        let t = now.addingTimeInterval(Double(i) * 300 - 288 * 300)
        let base = 58.0 + 18 * abs(sin(Double(i) / 30.0))
        let spike = (i > 200 && i < 215) ? 75.0 : 0
        return TrendPoint(date: t, value: base + spike)
    }
    return VStack(alignment: .leading, spacing: 12) {
        Text("Overview HR").strandOverline()
        OverviewHRChart(
            points: pts,
            sleep: .init(start: pts.first!.date, end: pts.first!.date.addingTimeInterval(6 * 3600 + 6 * 60), label: "6:06"),
            workouts: [.init(start: pts[200].date, end: pts[215].date, symbol: "figure.run")],
            recovery: .init(date: pts.first!.date.addingTimeInterval(6 * 3600), label: "67% Recovery", color: StrandPalette.recoveryColor(67)),
            effort: .init(date: pts.last!.date, label: "12.5 Effort", color: StrandPalette.strainColor(12.5), alignment: .trailing),
            valueRange: 45...140
        )
    }
    .padding(28)
    .frame(width: 760, height: 360)
    .background(StrandPalette.surfaceBase)
    .preferredColorScheme(.dark)
}
#endif
