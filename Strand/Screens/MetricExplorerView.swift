import SwiftUI
import Foundation
import StrandDesign
import StrandAnalytics
import WhoopStore

// MARK: - Explore (Metric Explorer + Detail)
//
// The catalog-driven "Explore" surface. The root is a grouped list — one
// SectionHeader per MetricCatalog.category, then a row per metric — pushing a
// MetricDetailView. The detail is a uniform analytic dossier built ONLY from the
// locked StrandDesign components (NoopCard / ChartCard / StatTile / InsightCard /
// SegmentedPillControl). No custom card heights, paddings, or surfaces anywhere.
//
// Sparse-metric rule (owner saw "no data" on metrics that HAVE data): a series may
// be sampled weekly (weight / body fat). The window is taken RELATIVE TO THE LATEST
// data point — not "now" — so a stale-but-present series still resolves. If the
// selected window holds ≥1 point we SHOW THAT WINDOW (so W/M/3M stay visibly
// distinct); only when it holds ZERO points do we auto-expand to the smallest larger
// range that does. The hero always shows the latest available point + "as of <date>".

// yyyy-MM-dd → Date, fixed UTC / en_US_POSIX (per task spec).
private let strandDayParser: DateFormatter = {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.timeZone = TimeZone(identifier: "UTC")
    f.dateFormat = "yyyy-MM-dd"
    return f
}()

private func parseDay(_ day: String) -> Date? { strandDayParser.date(from: day) }

/// "9 Jun 2026" — long, locale-stable date for the hero "as of" line.
private func longDate(_ d: Date) -> String {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.timeZone = TimeZone(identifier: "UTC")
    f.dateFormat = "d MMM yyyy"
    return f.string(from: d)
}

/// The category accent (colour communicates category only — never decoration).
private func metricAccent(_ m: MetricDescriptor) -> Color {
    switch m.key {
    case "recovery", "sleep_performance", "hours_vs_needed_pct", "sleep_consistency",
         "restorative_pct", "restorative_min", "sleep_efficiency", "sleep_total_min",
         "sleep_deep_min", "sleep_rem_min":
        return StrandPalette.accent
    case "strain", "hr_zones45_min", "hr_zones_all_min", "strength_min", "hr_zones13_min":
        return StrandPalette.strainColor(14)              // mid-strain hue
    case "hrv", "vo2max", "lean_mass":
        return StrandPalette.metricPurple
    case "rhr", "stress", "sleep_debt_min", "body_fat", "max_hr":
        return StrandPalette.metricRose
    case "spo2", "steps":
        return StrandPalette.metricCyan
    case "energy_kcal", "active_kcal":
        return StrandPalette.metricAmber
    default:
        return m.source == "apple-health" ? StrandPalette.metricCyan : StrandPalette.textPrimary
    }
}

/// The gradient for a metric's trend line — strain/recovery ride their data scales;
/// everything else uses a flat tint of its category accent.
private func metricGradient(_ m: MetricDescriptor) -> Gradient {
    if m.category == "Strain" { return StrandPalette.strainGradient }
    if m.key == "recovery" { return StrandPalette.recoveryGradient }
    let c = metricAccent(m)
    return Gradient(colors: [c.opacity(0.55), c])
}

// MARK: - Range

/// The W/M/3M/6M/1Y/ALL window, driving the single SegmentedPillControl.
enum ExploreRange: Int, CaseIterable, Identifiable, Hashable {
    case week = 7, month = 30, quarter = 90, half = 180, year = 365, all = 0
    var id: Int { rawValue }
    var label: String {
        switch self {
        case .week: return "W"; case .month: return "M"; case .quarter: return "3M"
        case .half: return "6M"; case .year: return "1Y"; case .all: return "ALL"
        }
    }
    var name: String {
        switch self {
        case .week: return "week"; case .month: return "month"; case .quarter: return "quarter"
        case .half: return "6 months"; case .year: return "year"; case .all: return "all time"
        }
    }
    /// Trailing days the window spans (nil = everything).
    var days: Int? { self == .all ? nil : rawValue }

    /// This range plus every LARGER range, ascending — the auto-expand search order
    /// when the selected window holds zero points. ALW always terminates the chain.
    var widening: [ExploreRange] {
        let order: [ExploreRange] = [.week, .month, .quarter, .half, .year, .all]
        guard let i = order.firstIndex(of: self) else { return [.all] }
        return Array(order[i...])
    }
}

// MARK: - Root: categorized list

/// The "Explore" picker — categories as sections, metrics as rows, each pushing a
/// MetricDetailView. A faint trailing "•" marks metrics whose series is empty.
struct MetricExplorerView: View {
    @EnvironmentObject var repo: Repository
    /// metric.id → whether its series is empty (loaded once, lazily).
    @State private var emptyByID: [String: Bool] = [:]

    var body: some View {
        NavigationStack {
            ScreenScaffold(title: "Explore", subtitle: "Every signal, one tap deep.") {
                ForEach(MetricCatalog.categories, id: \.self) { category in
                    let metrics = MetricCatalog.inCategory(category)
                    if !metrics.isEmpty {
                        VStack(alignment: .leading, spacing: NoopMetrics.gap) {
                            SectionHeader("\(category)", overline: "Category",
                                          trailing: "\(metrics.count)")
                            NoopCard(padding: 0) {
                                VStack(spacing: 0) {
                                    ForEach(Array(metrics.enumerated()), id: \.element.id) { idx, metric in
                                        NavigationLink(value: metric) {
                                            MetricRow(metric: metric,
                                                      isEmpty: emptyByID[metric.id] ?? false)
                                        }
                                        .buttonStyle(.plain)
                                        if idx < metrics.count - 1 {
                                            Divider().overlay(StrandPalette.hairline)
                                                .padding(.leading, 56)
                                        }
                                    }
                                }
                            }
                        }
                        .padding(.bottom, NoopMetrics.sectionGap - 20)
                    }
                }
            }
            .navigationDestination(for: MetricDescriptor.self) { metric in
                MetricDetailView(metric: metric)
            }
        }
        .task { await probeEmptiness() }
    }

    /// One lightweight pass to learn which metrics have no series, so rows can flag
    /// them with the faint trailing dot. Failures default to "has data" (no dot).
    private func probeEmptiness() async {
        guard emptyByID.isEmpty else { return }
        var map: [String: Bool] = [:]
        for metric in MetricCatalog.all {
            let s = await repo.series(key: metric.key, source: metric.source)
            map[metric.id] = s.isEmpty
        }
        emptyByID = map
    }
}

// MARK: - One catalog row

private struct MetricRow: View {
    let metric: MetricDescriptor
    let isEmpty: Bool

    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(StrandPalette.surfaceInset)
                Image(systemName: metric.icon)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(metricAccent(metric))
            }
            .frame(width: 34, height: 34)

            VStack(alignment: .leading, spacing: 1) {
                Text(metric.title)
                    .font(StrandFont.body)
                    .foregroundStyle(StrandPalette.textPrimary)
                Text(metric.source == "apple-health" ? "Apple Health" : "Whoop")
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textTertiary)
            }

            Spacer(minLength: 8)

            if !metric.unit.isEmpty {
                Text(metric.unit)
                    .font(StrandFont.captionNumber)
                    .foregroundStyle(StrandPalette.textSecondary)
            }
            // Faint trailing dot ONLY when this metric has no series at all.
            if isEmpty {
                Text("•")
                    .font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.textTertiary.opacity(0.5))
                    .accessibilityLabel("No data")
            }
            Image(systemName: "chevron.right")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(StrandPalette.textTertiary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(metric.title), \(metric.unit.isEmpty ? metric.category : metric.unit)\(isEmpty ? ", no data" : "")")
        .accessibilityAddTraits(.isButton)
    }
}

// MARK: - Detail / drill-down

/// The full analytic dossier for one metric, built ONLY from locked components:
/// a SegmentedPillControl range, a hero ChartCard (line + latest "as of"), a uniform
/// StatTile row (Average / Min / Max / Latest / Δ), and a "What correlates" NoopCard.
struct MetricDetailView: View {
    let metric: MetricDescriptor
    @EnvironmentObject var repo: Repository

    @State private var range: ExploreRange = .month
    /// Full ascending series for this metric — ALL history.
    @State private var series: [(day: String, value: Double)] = []
    /// Every OTHER catalog series, loaded once for the correlation scan.
    @State private var others: [(metric: MetricDescriptor, series: [(day: String, value: Double)])] = []
    @State private var loaded = false

    /// Cached correlation scan, keyed by its inputs (selected range + the metric id),
    /// so the full cross-catalog Pearson sweep runs ONLY when those change — not on
    /// every body re-eval (hover / 1 Hz HR ticks / animation). Recomputed from
    /// `recomputeCorrelations(...)` after load and on range change.
    @State private var correlationCache: [CorrRow] = []
    /// The (metricID, range) the cache was built for; nil means "not yet computed".
    @State private var correlationKey: String? = nil

    // MARK: Derived

    /// The trailing-N-days slice for a given range, taken RELATIVE TO THE LATEST data
    /// point (not "now") — `.all` returns everything.
    private func slice(for r: ExploreRange) -> [(day: String, value: Double)] {
        guard let days = r.days else { return series }
        guard let lastDay = series.last?.day, let last = parseDay(lastDay) else { return [] }
        let cutoff = last.addingTimeInterval(-Double(days - 1) * 86_400)
        return series.filter { row in
            guard let d = parseDay(row.day) else { return false }
            return d >= cutoff
        }
    }

    /// The range actually shown: the SELECTED range whenever its window holds ≥1
    /// point, otherwise the smallest LARGER range that does. So switching ranges is
    /// always visibly distinct when data allows, and only sparse windows widen.
    private var effectiveRange: ExploreRange {
        guard !series.isEmpty else { return range }
        for r in range.widening where !slice(for: r).isEmpty { return r }
        return .all
    }

    /// The window immediately preceding the active one (equal length, by day count).
    private func previousWindow(effectiveRange: ExploreRange,
                                windowed: [(day: String, value: Double)]) -> [(day: String, value: Double)] {
        guard effectiveRange != .all else { return [] }
        let size = windowed.count
        guard size > 0 else { return [] }
        // Index of the active window's first row, then step back `size` rows.
        guard let firstDay = windowed.first?.day,
              let lo = series.firstIndex(where: { $0.day == firstDay }) else { return [] }
        let prevLo = max(0, lo - size)
        guard prevLo < lo else { return [] }
        return Array(series[prevLo..<lo])
    }

    private func trendPoints(_ windowed: [(day: String, value: Double)]) -> [TrendPoint] {
        windowed.compactMap { row in
            guard let d = parseDay(row.day) else { return nil }
            return TrendPoint(date: d, value: row.value)
        }
    }

    /// Padded value range so the line never sits flush against an axis.
    private func valueRange(_ windowValues: [Double]) -> ClosedRange<Double> {
        let v = windowValues
        guard let lo = v.min(), let hi = v.max() else { return 0...1 }
        if hi <= lo { return (lo - 1)...(hi + 1) }
        let span = hi - lo
        return (lo - span * 0.12)...(hi + span * 0.12)
    }

    private var latest: (day: String, value: Double)? { series.last }

    // MARK: Body

    var body: some View {
        // Compute the heavy window derivations ONCE per body eval, then hand them to
        // the subviews — instead of every subview re-deriving `effectiveRange` /
        // `windowed` (each of which re-parses + re-filters the full history).
        let effRange = effectiveRange
        let win = slice(for: effRange)
        let fellBack = effRange != range
        return ScrollView {
            VStack(alignment: .leading, spacing: NoopMetrics.sectionGap) {
                rangeBar(effectiveRange: effRange, windowed: win, windowFellBack: fellBack)
                if loaded && series.isEmpty {
                    // ONLY genuine empty state: no data in the entire history.
                    ComingSoon(what: "Import your history first. A WHOOP export in Data Sources fills every metric you can explore here in about a minute.")
                } else if !loaded {
                    ComingSoon(what: "Reading your \(metric.title.lowercased())…")
                } else {
                    heroChart(effectiveRange: effRange, windowed: win, windowFellBack: fellBack)
                    statRow(effectiveRange: effRange, windowed: win)
                    correlationCard
                }
            }
            .padding(NoopMetrics.screenPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(StrandPalette.surfaceBase)
        .navigationTitle(metric.title)
        .task(id: metric.id) { await load() }
        // Range changes the window, hence the correlation inputs — recompute the
        // cached scan rather than letting `correlationCard` run it inside body.
        .onChange(of: range) { _ in recomputeCorrelations() }
    }

    private func load() async {
        series = await repo.series(key: metric.key, source: metric.source)
        var loadedOthers: [(metric: MetricDescriptor, series: [(day: String, value: Double)])] = []
        for other in MetricCatalog.all where other.id != metric.id {
            let s = await repo.series(key: other.key, source: other.source)
            if !s.isEmpty { loadedOthers.append((other, s)) }
        }
        others = loadedOthers
        loaded = true
        // First correlation build, now that `series`/`others` exist.
        recomputeCorrelations()
    }

    // MARK: Range bar

    private func rangeBar(effectiveRange: ExploreRange,
                          windowed: [(day: String, value: Double)],
                          windowFellBack: Bool) -> some View {
        let caption = rangeCaption(effectiveRange: effectiveRange,
                                   windowed: windowed,
                                   windowFellBack: windowFellBack)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(metric.category.uppercased()).strandOverline()
                    Text(metric.title)
                        .font(StrandFont.title2)
                        .foregroundStyle(StrandPalette.textPrimary)
                }
                Spacer()
                SegmentedPillControl(ExploreRange.allCases, selection: $range) { $0.label }
            }
            Text(caption)
                .font(StrandFont.footnote)
                .foregroundStyle(windowFellBack ? StrandPalette.statusWarning : StrandPalette.textTertiary)
                .accessibilityLabel(caption)
        }
    }

    /// "N readings · <range>" near the control, flagging an auto-widen when one happened.
    private func rangeCaption(effectiveRange: ExploreRange,
                              windowed: [(day: String, value: Double)],
                              windowFellBack: Bool) -> String {
        guard loaded, !series.isEmpty else { return "—" }
        let n = windowed.count
        let unit = n == 1 ? "reading" : "readings"
        if windowFellBack {
            return "\(n) \(unit) · sparse — widened to \(effectiveRange.name)"
        }
        return "\(n) \(unit) · \(range.name)"
    }

    // MARK: Hero chart

    private func heroChart(effectiveRange: ExploreRange,
                           windowed: [(day: String, value: Double)],
                           windowFellBack: Bool) -> some View {
        let asOf: String = {
            guard let day = latest?.day, let d = parseDay(day) else { return "—" }
            return "as of \(longDate(d))"
        }()
        let heroValue = latest.map { metric.format($0.value) } ?? "—"
        let subtitle = windowFellBack
            ? "Sparse — widened to \(effectiveRange.name) · \(windowed.count) readings"
            : "\(windowed.count) readings · \(range.name)"
        return ChartCard(
            title: "\(metric.title)",
            subtitle: subtitle,
            trailing: "\(heroValue) · \(asOf)"
        ) {
            TrendChart(
                points: trendPoints(windowed),
                gradient: metricGradient(metric),
                valueRange: valueRange(windowed.map(\.value)),
                showsArea: true,
                height: NoopMetrics.chartHeight,
                valueFormat: { metric.format($0) }
            )
        } footer: {
            ChartFooter([
                ("Window", effectiveRange.label),
                ("Points", "\(windowed.count)"),
                ("Latest", heroValue),
            ])
        }
    }

    // MARK: Stat tile row (uniform 104pt tiles)

    private func statRow(effectiveRange: ExploreRange,
                         windowed: [(day: String, value: Double)]) -> some View {
        let windowValues = windowed.map(\.value)
        let s = ComparisonEngine.stat(windowValues)
        let cmp = ComparisonEngine.compare(current: windowValues,
                                           previous: previousWindow(effectiveRange: effectiveRange,
                                                                    windowed: windowed).map(\.value))
        let accent = metricAccent(metric)

        // Δ vs previous equal-length window. Tinted by higherIsBetter.
        let hasDelta = cmp.current.n > 0 && cmp.previous.n > 0
        let deltaText: String? = hasDelta ? signed(cmp.delta) : nil
        let deltaColor: Color = {
            guard hasDelta, cmp.direction != 0, let better = metric.higherIsBetter else {
                return StrandPalette.textTertiary
            }
            return ((cmp.direction > 0) == better)
                ? StrandPalette.statusPositive : StrandPalette.statusCritical
        }()
        let deltaCaption = hasDelta ? "vs prev \(effectiveRange.name)"
            : (effectiveRange == .all ? "all history" : "no prior \(effectiveRange.name)")

        return LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 168), spacing: NoopMetrics.gap)],
            alignment: .leading,
            spacing: NoopMetrics.gap
        ) {
            StatTile(label: "Average", value: metric.format(s.mean),
                     caption: "\(s.n) days", accent: accent,
                     sparkline: windowValues.count > 1 ? windowValues : nil,
                     sparkColor: accent)
            StatTile(label: "Min", value: metric.format(s.min),
                     accent: StrandPalette.textPrimary)
            StatTile(label: "Max", value: metric.format(s.max),
                     accent: StrandPalette.textPrimary)
            StatTile(label: "Latest", value: latest.map { metric.format($0.value) } ?? "—",
                     caption: latestCaption, accent: accent)
            StatTile(label: "Δ vs prev", value: deltaText ?? "—",
                     caption: deltaCaption, accent: StrandPalette.textPrimary,
                     delta: cmp.pctChange.map { "\($0 >= 0 ? "+" : "")\(String(format: "%.1f", $0))%" },
                     deltaColor: deltaColor)
        }
    }

    private var latestCaption: String? {
        guard let day = latest?.day, let d = parseDay(day) else { return nil }
        return longDate(d)
    }

    // MARK: Correlations

    private struct CorrRow: Identifiable {
        let id: String
        let metric: MetricDescriptor
        let r: Double
        let n: Int
    }

    /// Top |r| catalog metrics over a given window (|r| ≥ 0.30, n ≥ 10). Pure — takes
    /// the window so the heavy scan can be driven from `recomputeCorrelations()` into
    /// the `@State` cache instead of running inside `body`.
    private func computeCorrelationRows(windowed: [(day: String, value: Double)]) -> [CorrRow] {
        let myDays = Set(windowed.map(\.day))
        guard !myDays.isEmpty else { return [] }
        var rows: [CorrRow] = []
        for entry in others {
            let otherWindowed = entry.series.filter { myDays.contains($0.day) }
            let pairs = CorrelationEngine.alignByDay(windowed, otherWindowed)
            guard pairs.count >= 10, let c = CorrelationEngine.pearson(pairs) else { continue }
            if abs(c.r) >= 0.3 {
                rows.append(CorrRow(id: entry.metric.id, metric: entry.metric, r: c.r, n: c.n))
            }
        }
        rows.sort { abs($0.r) > abs($1.r) }
        return Array(rows.prefix(6))
    }

    /// Rebuild the cached correlation scan for the CURRENT effective window, but only
    /// when its key (metric id + selected range) actually changed — so re-evals that
    /// don't alter the inputs (hover / HR ticks) are no-ops.
    private func recomputeCorrelations() {
        let key = "\(metric.id)|\(range.rawValue)"
        guard correlationKey != key else { return }
        correlationKey = key
        correlationCache = computeCorrelationRows(windowed: slice(for: effectiveRange))
    }

    private var correlationCard: some View {
        let rows = correlationCache
        return NoopCard {
            VStack(alignment: .leading, spacing: NoopMetrics.gap) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("What correlates").strandOverline()
                    Text("Pearson r over the visible window · |r| ≥ 0.30, n ≥ 10")
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textTertiary)
                }
                if rows.isEmpty {
                    Text("Nothing in the catalog moves clearly with \(metric.title.lowercased()) over this window. Widen the range to surface relationships.")
                        .font(StrandFont.subhead)
                        .foregroundStyle(StrandPalette.textTertiary)
                        .frame(maxWidth: .infinity, minHeight: 56, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    VStack(spacing: 0) {
                        ForEach(Array(rows.enumerated()), id: \.element.id) { idx, row in
                            correlationRowView(row)
                            if idx < rows.count - 1 {
                                Divider().overlay(StrandPalette.hairline)
                            }
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func correlationRowView(_ row: CorrRow) -> some View {
        let color = correlationColor(row.r)
        HStack(spacing: 12) {
            Image(systemName: row.metric.icon)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(StrandPalette.textSecondary)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text(row.metric.title)
                    .font(StrandFont.body)
                    .foregroundStyle(StrandPalette.textPrimary)
                Text("\(row.metric.category) · n = \(row.n)")
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textTertiary)
            }
            Spacer(minLength: 8)
            HStack(spacing: 10) {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(StrandPalette.surfaceInset)
                        Capsule().fill(color)
                            .frame(width: max(4, geo.size.width * min(abs(row.r), 1.0)))
                    }
                }
                .frame(width: 64, height: 6)
                Text("\(row.r >= 0 ? "+" : "−")\(String(format: "%.2f", abs(row.r)))")
                    .font(StrandFont.number(15))
                    .foregroundStyle(color)
                    .frame(width: 52, alignment: .trailing)
            }
        }
        .padding(.vertical, 10)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(row.metric.title), correlation \(String(format: "%.2f", row.r)), \(row.n) days")
    }

    // MARK: Helpers

    private func signed(_ delta: Double) -> String {
        (delta >= 0 ? "+" : "−") + metric.format(abs(delta))
    }

    private func correlationColor(_ r: Double) -> Color {
        let base = r >= 0 ? StrandPalette.statusPositive : StrandPalette.statusCritical
        return base.opacity(0.55 + 0.45 * min(abs(r), 1.0))
    }
}

// MARK: - Preview

#if DEBUG
@MainActor
private func explorerPreviewRepo() -> Repository {
    let repo = Repository(deviceId: "preview")
    repo.loaded = true
    return repo
}

#Preview("Explore") {
    MetricExplorerView()
        .environmentObject(explorerPreviewRepo())
        .frame(width: 900, height: 820)
        .preferredColorScheme(.dark)
}

#Preview("Metric Detail") {
    NavigationStack {
        MetricDetailView(metric: MetricCatalog.all.first { $0.key == "recovery" }!)
    }
    .environmentObject(explorerPreviewRepo())
    .frame(width: 900, height: 820)
    .preferredColorScheme(.dark)
}
#endif
