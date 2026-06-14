import SwiftUI
import StrandDesign
import WhoopStore
import Foundation

// MARK: - Trends
//
// The longitudinal view, rebuilt on the locked Noop component system so every
// surface, height and gap is identical: one SegmentedPillControl for the range,
// a hero recovery ChartCard, a uniform grid of HRV / Resting HR / Day Strain
// ChartCards (all NoopMetrics.chartHeight tall), and the whole history as a
// recovery YearHeatStrip in a NoopCard. No hand-sized cards anywhere.

struct TrendsView: View {
    @EnvironmentObject var repo: Repository
    // NOTE: deliberately does NOT observe LiveState — Trends shows historical data only, and
    // observing it forced a full re-render of this subtree on every ~1 Hz live-HR tick.

    // The shared range control: W(7) / M(30) / 3M(90) / 6M(180) / 1Y(365) / ALL.
    enum Range: Int, CaseIterable, Identifiable {
        case week = 7, month = 30, quarter = 90, half = 180, year = 365, all = 0
        var id: Int { rawValue }
        var label: String {
            switch self {
            case .week:    return "W"
            case .month:   return "M"
            case .quarter: return "3M"
            case .half:    return "6M"
            case .year:    return "1Y"
            case .all:     return "ALL"
            }
        }
        /// Trailing-day window, or nil for "all history".
        var days: Int? { self == .all ? nil : rawValue }

        /// This range plus every LARGER range, ascending — the auto-expand search
        /// order when the selected window holds zero points.
        var widening: [Range] {
            let order: [Range] = [.week, .month, .quarter, .half, .year, .all]
            guard let i = order.firstIndex(of: self) else { return [.all] }
            return Array(order[i...])
        }
    }

    @State private var range: Range = .quarter

    // Effort display scale (#268) — routes the Effort small-multiple's numbers + unit. Display-only.
    @AppStorage(UnitPrefs.effortScaleKey) private var effortScaleRaw = EffortScale.hundred.rawValue
    private var effortScale: EffortScale { UnitPrefs.resolveEffortScale(effortScaleRaw) }

    // yyyy-MM-dd → Date (en_US_POSIX, UTC), per task spec.
    private static let dayParser: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()
    private func date(_ day: String) -> Date? { Self.dayParser.date(from: day) }

    // MARK: Window selection (relative to the LATEST day, with auto-expand)

    /// The latest recorded day across all history (anchors every window).
    private var latestDay: Date? {
        guard let d = repo.days.last?.day else { return nil }
        return date(d)
    }

    /// Days for a given range, taken RELATIVE TO TODAY (the phone's local date) — not the latest
    /// recorded day, which on a stale import anchored W/M/3M to months-old data so it looked current
    /// (issue #23). Empty short windows auto-widen (see `resolve`), so old imports surface under a
    /// wider range / All history instead of masquerading as recent. `.all` returns everything.
    /// ISO yyyy-MM-dd compares chronologically.
    private func days(for r: Range) -> [DailyMetric] {
        guard let n = r.days else { return repo.days }
        let cutoffKey = Repository.localDayKey(Calendar.current.date(byAdding: .day, value: -(n - 1), to: Date()) ?? Date())
        return repo.days.filter { $0.day >= cutoffKey }
    }

    /// Build trend points from a metric accessor over a day slice.
    private func points(_ days: ArraySlice<DailyMetric>, _ value: (DailyMetric) -> Double?) -> [TrendPoint] {
        days.compactMap { d in
            guard let v = value(d), let dt = date(d.day) else { return nil }
            return TrendPoint(date: dt, value: v)
        }
    }
    private func points(_ days: [DailyMetric], _ value: (DailyMetric) -> Double?) -> [TrendPoint] {
        points(days[...], value)
    }

    // MARK: Resolved metric (memoized per body)
    //
    // days(for:) / points each re-filter the full multi-year `repo.days` array,
    // and the subviews used to fan out to them many times per render (caption +
    // widened + windowPoints, ×4 metrics). `resolve(_:)` walks the widening order
    // ONCE per metric (the smallest range ≥ selected whose window holds ≥1 point,
    // else ALL), captures that window's points and its effective range, then
    // derives the caption / widened flag from those — so a single body evaluation
    // filters each metric's window once instead of dozens of times. Identical
    // results to the old per-helper (effectiveRange / windowPoints / caption /
    // widened) computation.
    private struct ResolvedMetric {
        var points: [TrendPoint]
        var effective: Range
        var widened: Bool
        var caption: String
    }

    private func resolve(_ value: (DailyMetric) -> Double?) -> ResolvedMetric {
        // Find the smallest range ≥ selected whose window has ≥1 point, keeping
        // that window's points so we don't re-filter to read them back.
        for r in range.widening {
            let pts = points(days(for: r), value)
            if !pts.isEmpty {
                return ResolvedMetric(points: pts, effective: r,
                                      widened: r != range, caption: caption(count: pts.count, eff: r))
            }
        }
        // No range held data: fall back to ALL (matches effectiveRange()).
        let pts = points(days(for: .all), value)
        return ResolvedMetric(points: pts, effective: .all,
                              widened: .all != range, caption: caption(count: pts.count, eff: .all))
    }

    /// Caption text from an already-resolved count + effective range. Mirrors
    /// `caption(_:)` exactly but takes precomputed inputs to avoid re-filtering.
    private func caption(count n: Int, eff: Range) -> String {
        let unit = n == 1 ? "reading" : "readings"
        if eff != range {
            return "\(n) \(unit) · sparse — widened to \(name(for: eff))"
        }
        return "\(n) \(unit) · \(name(for: range))"
    }

    /// A padded value range for a series so the line isn't flat against the axis.
    private func valueRange(_ pts: [TrendPoint], fallback: ClosedRange<Double>, pad: Double = 0.12) -> ClosedRange<Double> {
        let vals = pts.map(\.value)
        guard let lo = vals.min(), let hi = vals.max() else { return fallback }
        if hi <= lo { return (lo - 1)...(hi + 1) }
        let span = hi - lo
        return (lo - span * pad)...(hi + span * pad)
    }

    private func mean(_ pts: [TrendPoint]) -> Double? {
        guard !pts.isEmpty else { return nil }
        return pts.map(\.value).reduce(0, +) / Double(pts.count)
    }

    /// The window's trend as a signed mean-of-recent-half minus mean-of-earlier-half. Drives a
    /// TrendChip so the card reads its direction at a glance, like Today's deltas. nil for a window
    /// too short to split. `higherIsBetter == nil` (e.g. Effort) keeps the chip neutral.
    private func periodChange(_ pts: [TrendPoint]) -> Double? {
        guard pts.count >= 4 else { return nil }
        let mid = pts.count / 2
        let earlier = pts.prefix(mid).map(\.value)
        let recent = pts.suffix(pts.count - mid).map(\.value)
        guard !earlier.isEmpty, !recent.isEmpty else { return nil }
        let e = earlier.reduce(0, +) / Double(earlier.count)
        let r = recent.reduce(0, +) / Double(recent.count)
        return r - e
    }

    /// A TrendChip for a window's period change, coloured green/rose by whether the move is good for
    /// THIS metric (`higherIsBetter`); neutral when direction has no valence or the change is flat.
    @ViewBuilder
    private func changeChip(_ pts: [TrendPoint], higherIsBetter: Bool?, fmt: @escaping (Double) -> String) -> some View {
        if let d = periodChange(pts), abs(d) > 0.0001 {
            let sign = d >= 0 ? "+" : "−"
            let color: Color = {
                guard let better = higherIsBetter else { return StrandPalette.textTertiary }
                return (d > 0) == better ? StrandPalette.statusPositive : StrandPalette.metricRose
            }()
            TrendChip(text: "\(sign)\(fmt(abs(d)))", color: color)
        }
    }

    /// "Trailing 90 days" / "All history" — used as a card subtitle.
    private var rangeSubtitle: String {
        guard let n = range.days else { return "All history" }
        return "Trailing \(n) days"
    }

    private func name(for r: Range) -> String {
        switch r {
        case .week:    return "week"
        case .month:   return "month"
        case .quarter: return "3 months"
        case .half:    return "6 months"
        case .year:    return "year"
        case .all:     return "all history"
        }
    }

    var body: some View {
        ScreenScaffold(title: "Trends", subtitle: "The thread of you over time.",
                       onRefresh: { await repo.refresh() }) {
            if repo.days.isEmpty {
                ComingSoon(what: repo.loaded
                    ? "Trends need history to draw. Import your WHOOP export in Data Sources to see weeks, months and years instantly."
                    : "Loading your history…")
            } else {
                // Resolve each metric's window ONCE per body and pass the results
                // down — rangeBar/heroRecovery/smallMultiples all reuse these
                // instead of re-filtering repo.days through caption/widened/
                // windowPoints on every render (hover, animation, 1 Hz HR tick).
                let recovery = resolve { $0.recovery }
                let hrv = resolve { $0.avgHrv }
                let rhr = resolve { $0.restingHr.map(Double.init) }
                let strain = resolve { $0.strain }
                VStack(alignment: .leading, spacing: NoopMetrics.sectionGap) {
                    // Week-in-review digest (#208) — self-hides when this week has no data.
                    WeeklyDigestCard()
                    rangeBar(recovery: recovery)
                    heroRecovery(recovery: recovery)
                    smallMultiples(hrv: hrv, rhr: rhr, strain: strain)
                    yearStrip
                }
            }
        }
    }

    // MARK: Range control

    private func rangeBar(recovery: ResolvedMetric) -> some View {
        let cap = recovery.caption
        let isWide = recovery.widened
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                SegmentedPillControl(Range.allCases, selection: $range) { $0.label }
                Spacer()
                Text(rangeSubtitle).strandOverline()
            }
            Text(cap)
                .font(StrandFont.footnote)
                .foregroundStyle(isWide ? StrandPalette.statusWarning : StrandPalette.textTertiary)
                .accessibilityLabel(cap)
        }
    }

    // MARK: Hero — recovery over time

    private func heroRecovery(recovery: ResolvedMetric) -> some View {
        let pts = recovery.points
        let avg = mean(pts)
        // Charge world — green. The hero is a domain-tinted, glowing line with a bright "now" cap.
        return ChartCard(
            title: "Charge",
            // The range bar above already prints the authoritative "N readings · <range>"
            // caption; the hero only needs to name its window so the count isn't doubled
            // within one card height.
            subtitle: rangeSubtitle,
            trailing: avg.map { "\(Int($0.rounded()))" },
            height: NoopMetrics.chartHeight,
            tint: StrandPalette.chargeColor,
            chart: {
                if pts.count >= 2 {
                    glowChart(points: pts,
                              gradient: StrandPalette.recoveryGradient,
                              // Recovery is a 0–100 score; lift only the ceiling ~6% so a
                              // near-100 peak and the NowEndCap halo clear the top edge,
                              // matching the headroom the padded small multiples already get.
                              valueRange: 0...106,
                              tip: StrandPalette.chargeBright,
                              valueFormat: { "\(Int($0.rounded()))" })
                } else {
                    sparsePlaceholder
                }
            },
            footer: {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        ChartFooter([
                            ("Avg", avg.map { "\(Int($0.rounded()))" } ?? "—"),
                            ("Peak", pts.map(\.value).max().map { "\(Int($0.rounded()))" } ?? "—"),
                            ("Low", pts.map(\.value).min().map { "\(Int($0.rounded()))" } ?? "—"),
                            ("Days", "\(pts.count)"),
                        ])
                        changeChip(pts, higherIsBetter: true, fmt: { "\(Int($0.rounded()))" })
                    }
                }
            }
        )
    }

    // MARK: Small multiples — HRV / Resting HR / Day Strain

    private func smallMultiples(hrv: ResolvedMetric, rhr: ResolvedMetric, strain: ResolvedMetric) -> some View {
        let cols = [GridItem(.adaptive(minimum: 320), spacing: NoopMetrics.gap)]
        let hrvPts = hrv.points
        let rhrPts = rhr.points
        let strainPts = strain.points

        return VStack(alignment: .leading, spacing: NoopMetrics.gap) {
            // No trailing window label here — the range bar's overline already states it;
            // a second "Trailing 90 days" in the same scroll region just repeats it.
            SectionHeader("Daily signals", overline: "Trends")
            LazyVGrid(columns: cols, alignment: .leading, spacing: NoopMetrics.gap) {
                // HRV / Resting HR are Charge sub-signals → the Charge (green) card world, each line
                // keeping its established metric hue for legibility. Effort sits in its amber world.
                metricChart(
                    title: "Heart rate variability", unit: "ms",
                    points: hrvPts,
                    gradient: gradient(StrandPalette.metricPurple),
                    tip: StrandPalette.metricPurple,
                    tint: StrandPalette.chargeColor,
                    higherIsBetter: true,
                    range: valueRange(hrvPts, fallback: 20...120),
                    fmt: { "\(Int($0.rounded()))" }
                )
                metricChart(
                    title: "Resting heart rate", unit: "bpm",
                    points: rhrPts,
                    gradient: gradient(StrandPalette.metricRose),
                    tip: StrandPalette.metricRose,
                    tint: StrandPalette.chargeColor,
                    higherIsBetter: false,
                    range: valueRange(rhrPts, fallback: 40...80),
                    fmt: { "\(Int($0.rounded()))" }
                )
                metricChart(
                    // Plotted points + range stay on the stored 0–100 scale (line shape unchanged); only the
                    // displayed numbers + unit follow the Effort-scale toggle, converted inside `fmt`. (#268)
                    title: "Effort", unit: "/ \(UnitFormatter.effortScaleMax(effortScale))",
                    points: strainPts,
                    gradient: StrandPalette.strainGradient,
                    tip: StrandPalette.effortBright,
                    tint: StrandPalette.effortColor,
                    higherIsBetter: nil,
                    range: valueRange(strainPts, fallback: 0...100),
                    fmt: { UnitFormatter.effortDisplay($0, scale: effortScale) }
                )
            }
        }
    }

    @ViewBuilder
    private func metricChart(
        title: LocalizedStringKey, unit: String,
        points pts: [TrendPoint],
        subtitle: String? = nil,
        gradient: Gradient,
        tip: Color,
        tint: Color,
        higherIsBetter: Bool?,
        range: ClosedRange<Double>,
        fmt: @escaping (Double) -> String
    ) -> some View {
        let avg = mean(pts)
        ChartCard(
            title: title,
            subtitle: subtitle,
            trailing: avg.map(fmt),
            height: NoopMetrics.chartHeight,
            tint: tint,
            chart: {
                if pts.count >= 2 {
                    glowChart(points: pts, gradient: gradient, valueRange: range,
                              tip: tip, valueFormat: { "\(fmt($0)) \(unit)" })
                } else {
                    sparsePlaceholder
                }
            },
            footer: {
                HStack {
                    ChartFooter([
                        // Plain "MEAN" to match the bare MIN/MAX columns (the uppercasing
                        // footer made "Mean ms" read as a shouty "MEAN MS"); the unit moves
                        // into the value, e.g. "58 ms".
                        ("Mean", avg.map { "\(fmt($0)) \(unit)" } ?? "—"),
                        ("Min", pts.map(\.value).min().map(fmt) ?? "—"),
                        ("Max", pts.map(\.value).max().map(fmt) ?? "—"),
                    ])
                    changeChip(pts, higherIsBetter: higherIsBetter, fmt: fmt)
                }
            }
        )
    }

    // MARK: Year heat-strip

    private var yearStrip: some View {
        // Always show at least a full year for context; expand to all history on ALL.
        let stripDays = max(range.days ?? repo.days.count, 365)
        let recent = repo.days.suffix(stripDays)
        let recoveryDays: [RecoveryDay] = recent.compactMap { d in
            guard let dt = date(d.day) else { return nil }
            return RecoveryDay(date: dt, score: d.recovery)
        }
        let title = (range == .all && repo.days.count > 365) ? "Charge — all history" : "Charge — past year"
        return NoopCard(tint: StrandPalette.chargeColor) {
            VStack(alignment: .leading, spacing: 12) {
                SectionHeader("\(title)", overline: "Calendar", trailing: "\(recoveryDays.filter { $0.score != nil }.count) days")
                if recoveryDays.isEmpty {
                    sparsePlaceholder.frame(height: 120)
                } else {
                    ScrollView(.horizontal, showsIndicators: false) {
                        YearHeatStrip(days: recoveryDays).padding(.vertical, 2)
                    }
                    Divider().overlay(StrandPalette.hairline)
                    legend
                }
            }
        }
    }

    private var legend: some View {
        HStack(spacing: 8) {
            Text("Depleted").font(StrandFont.footnote).foregroundStyle(StrandPalette.textTertiary)
            LinearGradient(gradient: StrandPalette.recoveryGradient, startPoint: .leading, endPoint: .trailing)
                .frame(width: 120, height: 8)
                .clipShape(Capsule())
            Text("Peaked").font(StrandFont.footnote).foregroundStyle(StrandPalette.textTertiary)
            Spacer()
        }
    }

    // MARK: Shared bits

    /// Single-color gradient (for metric lines that aren't a value ramp).
    private func gradient(_ color: Color) -> Gradient {
        Gradient(stops: [
            .init(color: color.opacity(0.55), location: 0.0),
            .init(color: color, location: 1.0),
        ])
    }

    /// A domain-tinted `TrendChart` with a soft glow and a bright end-cap dot at the latest point —
    /// the Bevel "now" idiom matching Today's OverviewHRChart. The glow is a blurred copy of the same
    /// line under the crisp one; the end-cap is a small halo + white core pinned to the final sample.
    /// Pure presentation: it forwards every value to the locked `TrendChart` unchanged.
    @ViewBuilder
    private func glowChart(points pts: [TrendPoint], gradient: Gradient, valueRange: ClosedRange<Double>,
                           tip: Color, valueFormat: @escaping (Double) -> String) -> some View {
        ZStack(alignment: .topLeading) {
            // Soft underglow — the same line, blurred and dimmed, so the curve reads as lit.
            TrendChart(points: pts, gradient: gradient, valueRange: valueRange,
                       showsArea: false, height: NoopMetrics.chartHeight, showsHover: false)
                .blur(radius: 6)
                .opacity(0.5)
                .allowsHitTesting(false)
            // The crisp, interactive line + area.
            TrendChart(points: pts, gradient: gradient, valueRange: valueRange,
                       showsArea: true, height: NoopMetrics.chartHeight, valueFormat: valueFormat)
            // Bright end-cap at the most-recent sample — "now".
            NowEndCap(value: pts.last?.value, valueRange: valueRange, tip: tip)
                .allowsHitTesting(false)
        }
    }

    private var sparsePlaceholder: some View {
        Text("Not enough data for this window.")
            .font(StrandFont.subhead)
            .foregroundStyle(StrandPalette.textTertiary)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            .background(StrandPalette.surfaceInset, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

// MARK: - Now end-cap

/// A glowing dot pinned to the latest point of a `TrendChart` — a halo + white core in the domain
/// tip colour, the Bevel "now" marker. Pinned to the trailing edge (the most-recent x) and mapped
/// vertically by the value within the chart's value range. Decorative + accessibility-hidden; the
/// real read-out is the card's trailing value and the line's own hover tooltip.
private struct NowEndCap: View {
    let value: Double?
    let valueRange: ClosedRange<Double>
    let tip: Color

    private func unit(_ v: Double) -> Double {
        let lo = valueRange.lowerBound, hi = valueRange.upperBound
        guard hi > lo else { return 0.5 }
        return min(max((v - lo) / (hi - lo), 0), 1)
    }

    var body: some View {
        GeometryReader { geo in
            if let v = value {
                // TrendChart pads the plot ~6.5pt top/bottom; inset the mapping so the cap lands on
                // the curve rather than the frame edge. The latest sample is always at the right edge.
                let inset: CGFloat = 7
                let h = max(geo.size.height - inset * 2, 1)
                let y = inset + (1 - CGFloat(unit(v))) * h
                let x = geo.size.width - inset
                ZStack {
                    Circle().fill(tip.opacity(0.30)).frame(width: 18, height: 18)
                    Circle().fill(tip.opacity(0.65)).frame(width: 11, height: 11)
                    Circle().fill(Color.white).frame(width: 5, height: 5)
                }
                .position(x: x, y: y)
            }
        }
        .accessibilityHidden(true)
    }
}

#if DEBUG
@MainActor
private func previewRepo() -> Repository {
    let repo = Repository(deviceId: "preview")
    let cal = Calendar(identifier: .gregorian)
    let fmt = DateFormatter()
    fmt.locale = Locale(identifier: "en_US_POSIX")
    fmt.timeZone = TimeZone(identifier: "UTC")
    fmt.dateFormat = "yyyy-MM-dd"
    let today = Date()
    var seeded: [DailyMetric] = []
    let span = 365 * 3
    for i in stride(from: span - 1, through: 0, by: -1) {
        guard let d = cal.date(byAdding: .day, value: -i, to: today) else { continue }
        let phase = Double(span - 1 - i)
        let rec = 55 + 28 * sin(phase / 11.0) + Double((Int(phase) * 31) % 17) - 8
        let hrv = 58 + 16 * sin(phase / 9.0) + Double((Int(phase) * 13) % 11) - 5
        let rhr = 52 + 4 * sin(phase / 7.0) + Double((Int(phase) * 7) % 5) - 2
        let strain = 9 + 6 * sin(phase / 5.0 + 1.2) + Double((Int(phase) * 5) % 4) - 2
        let gap = Int(phase) % 23 == 0
        seeded.append(DailyMetric(
            day: fmt.string(from: d),
            totalSleepMin: 420, efficiency: 0.9, deepMin: 90, remMin: 110, lightMin: 200,
            disturbances: 6, restingHr: gap ? nil : Int(rhr.rounded()),
            avgHrv: gap ? nil : max(15, hrv), recovery: gap ? nil : max(2, min(99, rec)),
            strain: gap ? nil : max(0, min(21, strain)), exerciseCount: 1
        ))
    }
    repo.days = seeded
    repo.loaded = true
    return repo
}

#Preview("Trends") {
    TrendsView()
        .environmentObject(previewRepo())
        .environmentObject(LiveState())
        .frame(width: 960, height: 960)
        .preferredColorScheme(.dark)
}
#endif
