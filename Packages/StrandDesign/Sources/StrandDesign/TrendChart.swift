import SwiftUI
import Charts

// MARK: - Trend Chart (§9.4 Trends)
//
// A line/area chart whose line is gradient-stroked by value — reusable for
// recovery / HRV / RHR / strain trends. The gradient defaults to the recovery
// scale (so a recovery-over-time line travels indigo → mint by daily score), but
// any gradient + value-range can be supplied for HRV/RHR/etc.

/// One point on a trend line.
public struct TrendPoint: Identifiable, Sendable {
    public let id = UUID()
    public var date: Date
    public var value: Double

    public init(date: Date, value: Double) {
        self.date = date
        self.value = value
    }
}

public struct TrendChart: View {

    public var points: [TrendPoint]
    /// The gradient the line/area is stroked with (defaults to the recovery scale).
    public var gradient: Gradient
    /// The value range mapped onto the gradient (0 → bottom color, max → top color).
    public var valueRange: ClosedRange<Double>
    /// Whether to draw the soft area fill below the line.
    public var showsArea: Bool
    public var height: CGFloat
    /// Whether hovering reveals a crosshair + tooltip for the nearest point.
    public var showsHover: Bool
    /// Formats a point's value for the tooltip's bold line (default: rounded int).
    public var valueFormat: (Double) -> String
    /// Formats a point's date for the tooltip's secondary line.
    public var dateFormat: (Date) -> String

    public init(
        points: [TrendPoint],
        gradient: Gradient = StrandPalette.recoveryGradient,
        valueRange: ClosedRange<Double> = 0...100,
        showsArea: Bool = true,
        height: CGFloat = 220,
        showsHover: Bool = true,
        valueFormat: @escaping (Double) -> String = { String(Int($0.rounded())) },
        dateFormat: @escaping (Date) -> String = { TrendChart.defaultDateString($0) }
    ) {
        self.points = points.sorted { $0.date < $1.date }
        self.gradient = gradient
        self.valueRange = valueRange
        self.showsArea = showsArea
        self.height = height
        self.showsHover = showsHover
        self.valueFormat = valueFormat
        self.dateFormat = dateFormat
    }

    /// The x-position the cursor is hovering, in chart-local coordinates.
    @State private var hoverX: CGFloat? = nil

    private static let sharedDateFormatter: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "EEE d MMM"; return f
    }()

    /// Default tooltip date format ("EEE d MMM"), exposed so it can seed the
    /// `dateFormat` default argument.
    public static func defaultDateString(_ date: Date) -> String {
        sharedDateFormatter.string(from: date)
    }

    /// The point nearest a given chart-local x, using the proxy to map back.
    private func nearestPoint(toX x: CGFloat, proxy: ChartProxy, plot: CGRect) -> TrendPoint? {
        guard !points.isEmpty else { return nil }
        // Map the cursor x (relative to the plot area) back to a Date.
        let relX = x - plot.minX
        guard let date: Date = proxy.value(atX: relX) else { return nil }
        // Find the TrendPoint whose date is closest.
        return points.min(by: {
            abs($0.date.timeIntervalSince(date)) < abs($1.date.timeIntervalSince(date))
        })
    }

    // Map data values onto the unit interval for gradient stops.
    private func unit(_ value: Double) -> Double {
        let lo = valueRange.lowerBound, hi = valueRange.upperBound
        guard hi > lo else { return 0 }
        return min(max((value - lo) / (hi - lo), 0), 1)
    }

    // A vertical gradient keyed to the value axis so the stroke color tracks value.
    private var valueGradient: LinearGradient {
        LinearGradient(gradient: gradient, startPoint: .bottom, endPoint: .top)
    }

    public var body: some View {
        Chart {
            if showsArea {
                ForEach(points) { p in
                    AreaMark(
                        x: .value("Date", p.date),
                        y: .value("Value", p.value)
                    )
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
            }
            ForEach(points) { p in
                LineMark(
                    x: .value("Date", p.date),
                    y: .value("Value", p.value)
                )
                .interpolationMethod(.catmullRom)
                .lineStyle(StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
                .foregroundStyle(valueGradient)
            }
            ForEach(points) { p in
                PointMark(
                    x: .value("Date", p.date),
                    y: .value("Value", p.value)
                )
                .symbolSize(18)
                .foregroundStyle(StrandPalette.sample(stops: gradient.toStops(), at: unit(p.value)))
            }
        }
        .chartYScale(domain: valueRange)
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
                    if showsHover,
                       let hx = hoverX,
                       let p = nearestPoint(toX: hx, proxy: proxy, plot: plot),
                       let px = proxy.position(forX: p.date),
                       let py = proxy.position(forY: p.value) {
                        let cx = px + plot.minX
                        let cy = py + plot.minY
                        let color = StrandPalette.sample(stops: gradient.toStops(), at: unit(p.value))

                        // Vertical crosshair at the nearest x.
                        CrosshairRule(x: cx, height: geo.size.height)

                        // Highlighted dot on the line.
                        HighlightDot(color: color)
                            .position(x: cx, y: cy)

                        // Tooltip near the point, kept in bounds.
                        PositionedTooltip(
                            anchor: CGPoint(x: cx, y: cy),
                            container: geo.size,
                            tooltip: ChartTooltip(
                                value: valueFormat(p.value),
                                label: dateFormat(p.date),
                                accent: color
                            )
                        )
                    }
                }
                .animation(StrandMotion.fade, value: hoverX)
                .contentShape(Rectangle())
                .onContinuousHover(coordinateSpace: .local) { phase in
                    guard showsHover else { return }
                    // Update the hover position in a NON-animating transaction. Otherwise entering or
                    // leaving the chart flips hoverX inside an animated context, the body re-evaluates,
                    // and SwiftUI Charts re-runs the line's draw-on animation — flickering the curve to a
                    // flat baseline and back as the cursor crosses the plot edge (#104). The crosshair's
                    // own fade is the overlay's .animation(value: hoverX) above and is unaffected by this.
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

    private var averageValue: Double {
        guard !points.isEmpty else { return valueRange.lowerBound }
        return points.map(\.value).reduce(0, +) / Double(points.count)
    }
}

// MARK: - Gradient → stops bridge

extension Gradient {
    /// Reconstruct ordered stops from a Gradient. SwiftUI does not expose `.stops`
    /// directly on all paths, so we use the public `stops` mirror when present.
    func toStops() -> [Gradient.Stop] {
        // `Gradient.stops` is public on macOS 13+; expose for our sampler.
        self.stops
    }
}

#if DEBUG
private func sampleTrend(days: Int, base: Double, swing: Double) -> [TrendPoint] {
    let cal = Calendar.current
    let today = Date()
    return (0..<days).map { i in
        let date = cal.date(byAdding: .day, value: -(days - 1 - i), to: today)!
        let v = base + swing * sin(Double(i) / 3.0) + Double((i * 17) % 9) - 4
        return TrendPoint(date: date, value: max(0, v))
    }
}

#Preview("TrendChart — recovery") {
    VStack(alignment: .leading, spacing: 12) {
        Text("Recovery — 30 days").strandOverline()
        Text("Hover the line: crosshair + dot + date/value tooltip.")
            .font(StrandFont.footnote).foregroundStyle(StrandPalette.textTertiary)
        TrendChart(points: sampleTrend(days: 30, base: 62, swing: 22))
    }
    .padding(28)
    .frame(width: 720, height: 340)
    .background(StrandPalette.surfaceBase)
    .preferredColorScheme(.dark)
}

#Preview("TrendChart — HRV") {
    VStack(alignment: .leading, spacing: 12) {
        Text("HRV (ms) — 30 days").strandOverline()
        Text("Hover to read each day's HRV in ms.")
            .font(StrandFont.footnote).foregroundStyle(StrandPalette.textTertiary)
        TrendChart(
            points: sampleTrend(days: 30, base: 58, swing: 14),
            gradient: StrandPalette.recoveryGradient,
            valueRange: 20...100,
            showsArea: true,
            valueFormat: { "\(Int($0.rounded())) ms" }
        )
    }
    .padding(28)
    .frame(width: 720, height: 340)
    .background(StrandPalette.surfaceBase)
    .preferredColorScheme(.dark)
}
#endif
