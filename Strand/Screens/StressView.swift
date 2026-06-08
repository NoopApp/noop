import SwiftUI
import Foundation
import StrandDesign
import WhoopStore

// MARK: - Stress Monitor
//
// A clear, Whoop-style "Stress Monitor": one 0–3 number, a band (LOW/MEDIUM/HIGH),
// and a single plain-English line on *why*. The score is a transparent proxy for
// autonomic load.
//
// Source of the daily 0–3 value, in priority order:
//   1. The persisted `stress` metric series ("my-whoop") via `repo.series` — if a
//      day has a stored stress value we trust it.
//   2. Otherwise we DERIVE it from how today's resting HR / HRV sit against a
//      personal 30-day baseline. Stress shows up as HIGHER resting HR and LOWER
//      HRV, so we sum two z-scores and squash onto 0–3 with a logistic curve:
//
//        zRHR = (todayRHR − meanRHR) / sdRHR        // positive when RHR is UP
//        zHRV = (meanHRV − todayHRV) / sdHRV        // positive when HRV is DOWN
//        raw  = zRHR + zHRV                          // combined autonomic load
//        stress = 3 / (1 + e^(−raw))                // 0 calm · 1.5 baseline · 3 high
//
// Bands:  0–1 LOW · 1–2 MEDIUM · 2–3 HIGH.
//
// Everything is computed live from `repo.days` (+ the stored series), so the math
// is fully inspectable — see the "How this is computed" card at the bottom.

struct StressView: View {
    @EnvironmentObject var repo: Repository
    @EnvironmentObject var live: LiveState

    /// The stored 0–3 stress series ("my-whoop"), oldest→newest. Empty → derive.
    @State private var storedSeries: [(day: String, value: Double)] = []
    @State private var loaded = false
    /// Trend window for the chart (W/M/3M/6M/1Y/ALL).
    @State private var range: ExploreRange = .month

    /// Cached StressModel + the input signature it was built from. Rebuilding the
    /// model is expensive (z-score derivation + per-day date parsing over the full
    /// history), so we recompute it only when its inputs actually change — NOT on
    /// every body re-eval (hover / animation / 1 Hz HR ticks).
    @State private var model: StressModel?
    @State private var modelSignature: StressInputs?

    var body: some View {
        ScreenScaffold(title: "Stress", subtitle: "Autonomic load from HRV and resting heart rate") {
            if let model {
                content(model)
            } else if !loaded {
                ComingSoon(what: "Reading your heart-rate variability and resting heart rate…")
            } else {
                emptyState
            }
        }
        .onAppear { rebuildModelIfNeeded() }
        .onChange(of: repo.days) { _ in rebuildModelIfNeeded() }
        .task { await load() }
    }

    private func load() async {
        storedSeries = await repo.series(key: "stress", source: "my-whoop")
        loaded = true
        rebuildModelIfNeeded()
    }

    /// Recompute the cached `StressModel` only when (repo.days, storedSeries)
    /// actually changed since the last build. Equality is an O(n) value compare,
    /// far cheaper than the model rebuild it guards.
    private func rebuildModelIfNeeded() {
        let signature = StressInputs(days: repo.days, stored: storedSeries)
        guard signature != modelSignature else { return }
        modelSignature = signature
        model = StressModel(days: repo.days, stored: storedSeries)
    }

    // MARK: Loaded content

    @ViewBuilder
    private func content(_ model: StressModel) -> some View {
        VStack(alignment: .leading, spacing: NoopMetrics.sectionGap) {

            // 1. HERO — the gauge + band + one plain-English line, all in one card.
            heroCard(model)

            // 2. Today's numbers — uniform 104pt tiles in one grid.
            VStack(alignment: .leading, spacing: NoopMetrics.gap) {
                SectionHeader("Today", overline: "Markers", trailing: "vs 30-day baseline")
                tileGrid(model)
            }

            // 3. Trend over the chosen window.
            trendSection(model)

            // 4. Transparency — how the number is built.
            methodologyCard(model)
        }
    }

    // MARK: 1 · Hero gauge card

    private func heroCard(_ model: StressModel) -> some View {
        NoopCard {
            VStack(spacing: 14) {
                HStack {
                    Text("Stress monitor").strandOverline()
                    Spacer()
                    StatePill("\(model.band.title)", tone: model.band.tone, showsDot: true)
                }
                StressGauge(score: model.score, band: model.band)
                    .frame(maxWidth: .infinity)
                // One plain-English line, full width under the gauge.
                Text(model.explanation)
                    .font(StrandFont.subhead)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: 2 · Today's tiles (uniform grid)

    private func tileGrid(_ model: StressModel) -> some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 168), spacing: NoopMetrics.gap)],
            alignment: .leading,
            spacing: NoopMetrics.gap
        ) {
            // Today's stress value, with its band as the caption.
            StatTile(
                label: "Stress",
                value: String(format: "%.1f", model.score),
                caption: "of 3 · \(model.band.title)",
                accent: StressRamp.color(model.score),
                sparkline: model.sparkValues.count > 1 ? model.sparkValues : nil,
                sparkColor: StressRamp.color(model.score)
            )
            // Resting HR — an INCREASE is the stressful direction.
            markerTile(
                label: "Resting HR",
                value: model.rhrToday.map { "\($0) bpm" } ?? "—",
                delta: model.rhrDelta,
                accent: StrandPalette.metricRose,
                higherIsStress: true
            )
            // HRV — a DECREASE is the stressful direction.
            markerTile(
                label: "HRV",
                value: model.hrvToday.map { "\(Int($0.rounded())) ms" } ?? "—",
                delta: model.hrvDelta,
                accent: StrandPalette.metricPurple,
                higherIsStress: false
            )
            // Estimated calm time — share of recent days spent in the LOW band.
            StatTile(
                label: "Calm time",
                value: model.calmTimeValue,
                caption: model.calmTimeCaption,
                accent: StressRamp.calm
            )
        }
    }

    /// A vs-baseline marker as a fixed-height StatTile. The delta is tinted by
    /// whether the move is toward stress (warning) or recovery (positive).
    private func markerTile(label: LocalizedStringKey, value: String, delta: Double?, accent: Color, higherIsStress: Bool) -> some View {
        let deltaText: String?
        let deltaColor: Color
        if let delta, abs(delta) >= 0.5 {
            let up = delta > 0
            let isStressful = (up == higherIsStress)
            deltaText = "\(up ? "+" : "−")\(Int(abs(delta).rounded())) vs base"
            deltaColor = isStressful ? StrandPalette.statusWarning : StrandPalette.statusPositive
        } else {
            deltaText = "at baseline"
            deltaColor = StrandPalette.textTertiary
        }
        return StatTile(
            label: label,
            value: value,
            caption: nil,
            accent: accent,
            delta: deltaText,
            deltaColor: deltaColor
        )
    }

    // MARK: 3 · Trend (range-controlled)

    @ViewBuilder
    private func trendSection(_ model: StressModel) -> some View {
        let points = windowedTrend(model)
        VStack(alignment: .leading, spacing: NoopMetrics.gap) {
            SectionHeader("Stress Trend", overline: "History", trailing: range.name)
            if points.count >= 2 {
                let avg = points.map(\.value).reduce(0, +) / Double(points.count)
                ChartCard(
                    title: "Stress · \(range.label)",
                    subtitle: "Daily 0–3 proxy",
                    trailing: "avg " + String(format: "%.1f", avg)
                ) {
                    TrendChart(
                        points: points,
                        gradient: StressRamp.gradient,
                        valueRange: 0...3,
                        showsArea: true,
                        height: NoopMetrics.chartHeight,
                        valueFormat: { String(format: "%.1f", $0) }
                    )
                } footer: {
                    ChartFooter([
                        ("Today", String(format: "%.1f", model.score)),
                        ("Average", String(format: "%.1f", avg)),
                        ("Days", "\(points.count)"),
                    ])
                }
                // The one segmented control — full width, right-aligned.
                HStack {
                    Spacer()
                    SegmentedPillControl(ExploreRange.allCases, selection: $range) { $0.label }
                }
            } else {
                NoopCard {
                    Text("Not enough recent days to chart a trend yet. Import a history or keep wearing your strap.")
                        .font(StrandFont.subhead)
                        .foregroundStyle(StrandPalette.textTertiary)
                        .frame(maxWidth: .infinity, minHeight: 120, alignment: .center)
                        .multilineTextAlignment(.center)
                }
            }
        }
    }

    /// The full daily proxy trend, sliced to the selected trailing window. Falls
    /// back to ALL when the trailing slice holds < 2 points.
    private func windowedTrend(_ model: StressModel) -> [TrendPoint] {
        let all = model.fullTrend
        guard let days = range.days, let last = all.last?.date else { return all }
        let cutoff = last.addingTimeInterval(-Double(days - 1) * 86_400)
        let slice = all.filter { $0.date >= cutoff }
        return slice.count >= 2 ? slice : all
    }

    // MARK: 4 · Methodology (transparency)

    private func methodologyCard(_ model: StressModel) -> some View {
        NoopCard {
            VStack(alignment: .leading, spacing: 8) {
                Text("How this is computed").strandOverline()
                Text(model.usingStored
                     ? "Today's value is your recorded daily stress score (0–3)."
                     : "Stress is derived from two autonomic signals.")
                    .font(StrandFont.body)
                    .foregroundStyle(StrandPalette.textPrimary)
                Text("We compare today's resting heart rate and HRV to your own 30-day baseline. A higher-than-usual resting HR and a lower-than-usual HRV both push the score up — classic signs the body is activated. The combined shift is mapped onto a 0–3 scale: 0 is calm, 1.5 sits at your baseline, 3 is highly activated.")
                    .font(StrandFont.subhead)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                Divider().overlay(StrandPalette.hairline)
                HStack(spacing: 0) {
                    bandLegend("0–1", "LOW", StressRamp.calm)
                    bandLegend("1–2", "MEDIUM", StressRamp.steady)
                    bandLegend("2–3", "HIGH", StressRamp.tense)
                }
            }
        }
    }

    private func bandLegend(_ range: String, _ label: String, _ color: Color) -> some View {
        HStack(spacing: 7) {
            Circle().fill(color).frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 1) {
                Text(label).font(StrandFont.captionNumber).foregroundStyle(StrandPalette.textPrimary)
                Text(range).font(StrandFont.footnote).foregroundStyle(StrandPalette.textTertiary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Empty state

    private var emptyState: some View {
        ComingSoon(what: "No stress history yet. Import your WHOOP export in Data Sources to see it.")
    }
}

// MARK: - Stress band

enum StressBand {
    case low, medium, high

    init(score: Double) {
        switch score {
        case ..<1.0: self = .low
        case ..<2.0: self = .medium
        default:     self = .high
        }
    }

    var title: String {
        switch self {
        case .low:    return "LOW"
        case .medium: return "MEDIUM"
        case .high:   return "HIGH"
        }
    }

    var tone: StrandTone {
        switch self {
        case .low:    return .positive
        case .medium: return .warning
        case .high:   return .critical
        }
    }
}

// MARK: - Stress ramp (its own scale: calm blue → balanced mint → tense amber)
//
// Deliberately distinct from the recovery ramp — low stress reads cool/blue,
// rising stress warms toward amber. Never the red→green recovery traffic light.

enum StressRamp {
    static let calm    = Color(hex: "#4FA9C9") // cool blue — low
    static let steady  = Color(hex: "#5BD3A0") // mint — balanced
    static let tense   = Color(hex: "#E8C24B") // amber — high

    static let stops: [Gradient.Stop] = [
        .init(color: calm,   location: 0.00),
        .init(color: steady, location: 0.50),
        .init(color: tense,  location: 1.00),
    ]

    static let gradient = Gradient(stops: stops)

    /// Sample the ramp at a 0–3 stress score.
    static func color(_ score: Double) -> Color {
        StrandPalette.sample(stops: stops, at: min(max(score / 3.0, 0), 1))
    }
}

// MARK: - Stress model inputs (cache key)

/// An `Equatable` snapshot of everything `StressModel.init` reads, used to decide
/// when the cached model must be rebuilt. `DailyMetric` is already `Equatable`;
/// the stored series is a tuple array (not `Equatable`), so we mirror it into an
/// `Equatable` shape. Comparison is O(n) — cheap versus rebuilding the model.
private struct StressInputs: Equatable {
    let days: [DailyMetric]
    let stored: [StoredPoint]

    struct StoredPoint: Equatable {
        let day: String
        let value: Double
    }

    init(days: [DailyMetric], stored: [(day: String, value: Double)]) {
        self.days = days
        self.stored = stored.map { StoredPoint(day: $0.day, value: $0.value) }
    }
}

// MARK: - Stress model (transparent: stored value OR z-score derivation)

struct StressModel {
    let score: Double            // 0–3 (today)
    let band: StressBand
    let explanation: String
    let rhrToday: Int?
    let hrvToday: Double?
    let rhrDelta: Double?        // today − baseline mean (bpm)
    let hrvDelta: Double?        // today − baseline mean (ms)
    let fullTrend: [TrendPoint]  // entire daily proxy history, oldest→newest
    let calmTimeValue: String    // e.g. "58%"
    let calmTimeCaption: String  // e.g. "of last 30 days"
    let usingStored: Bool        // true when today's value came from the stored series

    /// Last up-to-14 trend values, for the hero tile sparkline.
    var sparkValues: [Double] { Array(fullTrend.suffix(14)).map(\.value) }

    private static let dayParser: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    /// Build from oldest→newest daily metrics plus any stored "stress" series.
    /// Returns nil only when there is no usable signal at all.
    init?(days: [DailyMetric], stored: [(day: String, value: Double)]) {
        guard let today = days.last else { return nil }

        // Stored values keyed by day, clamped to 0–3.
        let storedByDay: [String: Double] = Dictionary(
            stored.map { ($0.day, min(max($0.value, 0), 3)) },
            uniquingKeysWith: { _, b in b }
        )

        // Baseline window: up to 30 days ending the day BEFORE today, so "today"
        // is measured against its own recent past rather than itself.
        let history = Array(days.dropLast())
        let baseline = Array(history.suffix(30))

        let rhrBase = baseline.compactMap { $0.restingHr }.map(Double.init)
        let hrvBase = baseline.compactMap { $0.avgHrv }

        let meanRHR = StressMath.mean(rhrBase)
        let sdRHR   = StressMath.std(rhrBase, mean: meanRHR)
        let meanHRV = StressMath.mean(hrvBase)
        let sdHRV   = StressMath.std(hrvBase, mean: meanHRV)

        let rhrT = today.restingHr.map(Double.init)
        let hrvT = today.avgHrv

        // Resolve today's score: prefer a stored value, else derive.
        let derivedAvailable = (rhrT != nil && meanRHR != nil) || (hrvT != nil && meanHRV != nil)
        let storedToday = storedByDay[today.day]
        guard storedToday != nil || derivedAvailable else { return nil }

        let derivedToday: Double? = derivedAvailable
            ? StressMath.squash(StressMath.rawScore(
                rhrToday: rhrT, meanRHR: meanRHR, sdRHR: sdRHR,
                hrvToday: hrvT, meanHRV: meanHRV, sdHRV: sdHRV))
            : nil

        let s = storedToday ?? derivedToday ?? 1.5
        self.usingStored = storedToday != nil
        self.score = s
        self.band = StressBand(score: s)
        self.rhrToday = today.restingHr
        self.hrvToday = hrvT
        self.rhrDelta = (rhrT != nil && meanRHR != nil) ? (rhrT! - meanRHR!) : nil
        self.hrvDelta = (hrvT != nil && meanHRV != nil) ? (hrvT! - meanHRV!) : nil

        self.explanation = StressMath.explanation(
            band: self.band,
            rhrDelta: self.rhrDelta,
            hrvDelta: self.hrvDelta,
            usingStored: self.usingStored
        )

        // Full daily proxy history: stored value if present for the day, else the
        // z-score derivation against the SAME baseline so the line is comparable.
        var pts: [TrendPoint] = []
        for d in days {
            guard let date = Self.dayParser.date(from: d.day) else { continue }
            if let v = storedByDay[d.day] {
                pts.append(TrendPoint(date: date, value: v))
                continue
            }
            let dRHR = d.restingHr.map(Double.init)
            let dHRV = d.avgHrv
            guard (dRHR != nil && meanRHR != nil) || (dHRV != nil && meanHRV != nil) else { continue }
            let r = StressMath.rawScore(
                rhrToday: dRHR, meanRHR: meanRHR, sdRHR: sdRHR,
                hrvToday: dHRV, meanHRV: meanHRV, sdHRV: sdHRV
            )
            pts.append(TrendPoint(date: date, value: StressMath.squash(r)))
        }
        self.fullTrend = pts

        // "Calm time": share of the last 30 charted days that sat in the LOW band.
        let recent = Array(pts.suffix(30))
        if recent.isEmpty {
            self.calmTimeValue = "—"
            self.calmTimeCaption = "needs history"
        } else {
            let calm = recent.filter { $0.value < 1.0 }.count
            let pct = Int((Double(calm) / Double(recent.count) * 100).rounded())
            self.calmTimeValue = "\(pct)%"
            self.calmTimeCaption = "low-stress days · \(recent.count)d"
        }
    }
}

// MARK: - Stress math (pure, testable helpers)

enum StressMath {
    static func mean(_ xs: [Double]) -> Double? {
        guard !xs.isEmpty else { return nil }
        return xs.reduce(0, +) / Double(xs.count)
    }

    /// Population standard deviation; 0 when there's no spread.
    static func std(_ xs: [Double], mean m: Double?) -> Double {
        guard let m, xs.count > 1 else { return 0 }
        let v = xs.map { ($0 - m) * ($0 - m) }.reduce(0, +) / Double(xs.count)
        return v.squareRoot()
    }

    /// Combined autonomic z-score. RHR-up and HRV-down both push it positive.
    static func rawScore(
        rhrToday: Double?, meanRHR: Double?, sdRHR: Double,
        hrvToday: Double?, meanHRV: Double?, sdHRV: Double
    ) -> Double {
        var sum = 0.0
        if let r = rhrToday, let m = meanRHR, sdRHR > 0.0001 {
            sum += (r - m) / sdRHR            // up = stress
        }
        if let h = hrvToday, let m = meanHRV, sdHRV > 0.0001 {
            sum += (m - h) / sdHRV            // down = stress
        }
        return sum
    }

    /// Logistic squash of the raw z-sum onto 0–3 (baseline 0 → 1.5).
    static func squash(_ raw: Double) -> Double {
        let s = 3.0 / (1.0 + exp(-raw))
        return min(max(s, 0), 3)
    }

    static func explanation(band: StressBand, rhrDelta: Double?, hrvDelta: Double?, usingStored: Bool) -> String {
        let rhrUp = (rhrDelta ?? 0) > 1.0
        let rhrDn = (rhrDelta ?? 0) < -1.0
        let hrvUp = (hrvDelta ?? 0) > 1.0
        let hrvDn = (hrvDelta ?? 0) < -1.0

        switch band {
        case .high:
            if rhrUp && hrvDn {
                return "Resting HR is elevated and HRV is below your baseline — both classic signs of high activation. Prioritise rest, hydration and an easy day."
            } else if hrvDn {
                return "HRV has dropped well below your baseline, pointing to elevated stress or fatigue. Ease off and give your body time to recover."
            } else if rhrUp {
                return "Resting heart rate is running high versus your norm — your body is under load today. Keep effort light."
            }
            return "Your autonomic markers are skewed toward stress today. Treat it as a recovery-focused day."
        case .medium:
            if rhrUp || hrvDn {
                return "Slightly off baseline — \(rhrUp ? "resting HR is a touch high" : "HRV is a little low") — so you're moderately activated. Nothing alarming; just don't overreach."
            }
            return "You're sitting around your typical autonomic baseline — moderate stress, a normal, balanced day."
        case .low:
            if rhrDn && hrvUp {
                return "Resting heart rate is low and HRV is up — your nervous system looks well-recovered and calm. A great day to push if you want to."
            } else if hrvUp {
                return "HRV is above baseline, a sign of a relaxed, well-recovered nervous system. Stress is low."
            }
            return "Resting heart rate and HRV are sitting at or below baseline — low physiological stress. You're in a calm, recovered state."
        }
    }
}

// MARK: - Semicircular stress gauge (0–3, blue → mint → amber sweep)
//
// A compact half-dial: cool-blue at 0, mint at the midpoint, amber at 3 — its own
// ramp, never the recovery traffic light. The value + band read inside the bowl.

struct StressGauge: View {
    let score: Double          // 0–3
    let band: StressBand
    var diameter: CGFloat = 248

    @State private var animated = false

    private var fraction: CGFloat { CGFloat(min(max(score / 3.0, 0), 1)) }

    var body: some View {
        let lineWidth: CGFloat = 16
        ZStack {
            ZStack {
                // Background track (the full semicircle).
                StressArc(progress: 1)
                    .stroke(StrandPalette.surfaceInset, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                // Subtle ghost of the full ramp under the track.
                StressArc(progress: 1)
                    .stroke(
                        AngularGradient(
                            gradient: StressRamp.gradient,
                            center: .center,
                            startAngle: .degrees(180),
                            endAngle: .degrees(360)
                        ),
                        style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)
                    )
                    .opacity(0.16)
                // Value arc, swept to the current fraction.
                StressArc(progress: animated ? fraction : 0)
                    .stroke(
                        AngularGradient(
                            gradient: StressRamp.gradient,
                            center: .center,
                            startAngle: .degrees(180),
                            endAngle: .degrees(360)
                        ),
                        style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)
                    )
                    .shadow(color: StressRamp.color(score).opacity(0.55), radius: 10)
            }
            .frame(width: diameter, height: diameter)
            // The arc occupies the top half of its bounding box; pin it so the
            // readout sits inside the bowl.
            .frame(height: diameter / 2 + lineWidth, alignment: .top)
            .clipped()

            // Center readout (number + band), tucked into the semicircle.
            VStack(spacing: 2) {
                Text(String(format: "%.1f", score))
                    .font(StrandFont.display(58))
                    .foregroundStyle(StrandPalette.textPrimary)
                    .contentTransition(.numericText())
                Text("of 3 · \(band.title)")
                    .font(StrandFont.overline)
                    .tracking(StrandFont.overlineTracking)
                    .foregroundStyle(StressRamp.color(score))
            }
            .offset(y: 12)
        }
        .frame(maxWidth: .infinity)
        .frame(height: diameter / 2 + lineWidth + 26)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Stress \(String(format: "%.1f", score)) of 3, \(band.title)")
        .onAppear {
            withAnimation(StrandMotion.drawIn) { animated = true }
        }
    }
}

/// A 180° arc across the top half (from 9 o'clock sweeping over the top to 3
/// o'clock), trimmed to `progress` (0…1).
struct StressArc: Shape {
    var progress: CGFloat

    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    func path(in rect: CGRect) -> Path {
        var p = Path()
        let lineInset: CGFloat = 16
        let radius = min(rect.width, rect.height) / 2 - lineInset
        // Center the arc on the bottom-middle so the bowl opens upward.
        let center = CGPoint(x: rect.midX, y: rect.height)
        let start = Angle.degrees(180)
        let end = Angle.degrees(180 + 180 * Double(min(max(progress, 0), 1)))
        p.addArc(center: center, radius: radius, startAngle: start, endAngle: end, clockwise: false)
        return p
    }
}

// MARK: - Preview

#if DEBUG
private func sampleStressTrend(_ n: Int) -> [TrendPoint] {
    let cal = Calendar.current
    let today = Date()
    return (0..<n).map { i in
        let date = cal.date(byAdding: .day, value: -(n - 1 - i), to: today)!
        let v = 1.4 + 0.9 * sin(Double(i) / 2.4) + Double((i * 13) % 5) * 0.12
        return TrendPoint(date: date, value: min(max(v, 0), 3))
    }
}

private struct StressPreviewHarness: View {
    let score: Double
    @State private var range: ExploreRange = .month
    var body: some View {
        let band = StressBand(score: score)
        ScrollView {
            VStack(alignment: .leading, spacing: NoopMetrics.sectionGap) {
                Text("Stress").font(StrandFont.title1).foregroundStyle(StrandPalette.textPrimary)

                NoopCard {
                    VStack(spacing: 14) {
                        HStack {
                            Text("Stress monitor").strandOverline()
                            Spacer()
                            StatePill("\(band.title)", tone: band.tone)
                        }
                        StressGauge(score: score, band: band)
                            .frame(maxWidth: .infinity)
                        Text(StressMath.explanation(band: band, rhrDelta: 3, hrvDelta: -8, usingStored: false))
                            .font(StrandFont.subhead)
                            .foregroundStyle(StrandPalette.textSecondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }

                LazyVGrid(columns: [GridItem(.adaptive(minimum: 168), spacing: NoopMetrics.gap)],
                          alignment: .leading, spacing: NoopMetrics.gap) {
                    StatTile(label: "Stress", value: String(format: "%.1f", score),
                             caption: "of 3 · \(band.title)", accent: StressRamp.color(score))
                    StatTile(label: "Resting HR", value: "54 bpm", accent: StrandPalette.metricRose,
                             delta: "+3 vs base", deltaColor: StrandPalette.statusWarning)
                    StatTile(label: "HRV", value: "48 ms", accent: StrandPalette.metricPurple,
                             delta: "−8 vs base", deltaColor: StrandPalette.statusWarning)
                    StatTile(label: "Calm time", value: "58%", caption: "low-stress days · 30d",
                             accent: StressRamp.calm)
                }

                ChartCard(title: "Stress · M", subtitle: "Daily 0–3 proxy", trailing: "avg 1.5") {
                    TrendChart(points: sampleStressTrend(30), gradient: StressRamp.gradient,
                               valueRange: 0...3, showsArea: true, height: NoopMetrics.chartHeight,
                               valueFormat: { String(format: "%.1f", $0) })
                } footer: {
                    ChartFooter([("Today", String(format: "%.1f", score)), ("Average", "1.5"), ("Days", "30")])
                }
                HStack { Spacer(); SegmentedPillControl(ExploreRange.allCases, selection: $range) { $0.label } }
            }
            .padding(NoopMetrics.screenPadding)
        }
        .background(StrandPalette.surfaceBase)
    }
}

#Preview("Stress — HIGH") {
    StressPreviewHarness(score: 2.4)
        .frame(width: 720, height: 1000)
        .preferredColorScheme(.dark)
}

#Preview("Stress — LOW") {
    StressPreviewHarness(score: 0.6)
        .frame(width: 720, height: 1000)
        .preferredColorScheme(.dark)
}
#endif
