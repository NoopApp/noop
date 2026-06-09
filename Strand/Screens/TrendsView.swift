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
        ScreenScaffold(title: "Trends", subtitle: "The thread of you over time.") {
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
        return ChartCard(
            title: "Recovery",
            subtitle: recovery.caption,
            trailing: avg.map { "\(Int($0.rounded()))" },
            height: NoopMetrics.chartHeight,
            chart: {
                if pts.count >= 2 {
                    TrendChart(points: pts,
                               gradient: StrandPalette.recoveryGradient,
                               valueRange: 0...100,
                               showsArea: true,
                               height: NoopMetrics.chartHeight)
                } else {
                    sparsePlaceholder
                }
            },
            footer: {
                ChartFooter([
                    ("Avg", avg.map { "\(Int($0.rounded()))" } ?? "—"),
                    ("Peak", pts.map(\.value).max().map { "\(Int($0.rounded()))" } ?? "—"),
                    ("Low", pts.map(\.value).min().map { "\(Int($0.rounded()))" } ?? "—"),
                    ("Days", "\(pts.count)"),
                ])
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
            SectionHeader("Daily signals", overline: "Trends", trailing: rangeSubtitle)
            LazyVGrid(columns: cols, alignment: .leading, spacing: NoopMetrics.gap) {
                metricChart(
                    title: "Heart rate variability", unit: "ms",
                    points: hrvPts,
                    subtitle: hrv.caption,
                    gradient: gradient(StrandPalette.metricPurple),
                    range: valueRange(hrvPts, fallback: 20...120),
                    fmt: { "\(Int($0.rounded()))" }
                )
                metricChart(
                    title: "Resting heart rate", unit: "bpm",
                    points: rhrPts,
                    subtitle: rhr.caption,
                    gradient: gradient(StrandPalette.metricRose),
                    range: valueRange(rhrPts, fallback: 40...80),
                    fmt: { "\(Int($0.rounded()))" }
                )
                metricChart(
                    title: "Day strain", unit: "/ 21",
                    points: strainPts,
                    subtitle: strain.caption,
                    gradient: StrandPalette.strainGradient,
                    range: valueRange(strainPts, fallback: 0...21),
                    fmt: { String(format: "%.1f", $0) }
                )
            }
        }
    }

    @ViewBuilder
    private func metricChart(
        title: LocalizedStringKey, unit: String,
        points pts: [TrendPoint],
        subtitle: String,
        gradient: Gradient,
        range: ClosedRange<Double>,
        fmt: @escaping (Double) -> String
    ) -> some View {
        let avg = mean(pts)
        ChartCard(
            title: title,
            subtitle: subtitle,
            trailing: avg.map(fmt),
            height: NoopMetrics.chartHeight,
            chart: {
                if pts.count >= 2 {
                    TrendChart(points: pts,
                               gradient: gradient,
                               valueRange: range,
                               showsArea: true,
                               height: NoopMetrics.chartHeight,
                               valueFormat: { "\(fmt($0)) \(unit)" })
                } else {
                    sparsePlaceholder
                }
            },
            footer: {
                ChartFooter([
                    ("Mean \(unit)", avg.map(fmt) ?? "—"),
                    ("Min", pts.map(\.value).min().map(fmt) ?? "—"),
                    ("Max", pts.map(\.value).max().map(fmt) ?? "—"),
                ])
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
        let title = (range == .all && repo.days.count > 365) ? "Recovery — all history" : "Recovery — past year"
        return NoopCard {
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

    private var sparsePlaceholder: some View {
        Text("Not enough data for this window.")
            .font(StrandFont.subhead)
            .foregroundStyle(StrandPalette.textTertiary)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            .background(StrandPalette.surfaceInset, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
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
