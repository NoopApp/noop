import SwiftUI
import Foundation
import Charts
import StrandDesign
import StrandAnalytics
import WhoopStore

// MARK: - Compare
//
// The "overlay metrics & draw conclusions" screen. Pick 2–4 metrics from the
// catalog, choose a time window, and read them on a single normalized overlay
// chart (each metric min–max scaled to 0–1 within the window so different units
// share an axis). Below, every pair of selected metrics gets a live Pearson-r
// correlation readout with a plain-English conclusion. Pure read-side: each
// metric loads from repo.series; everything else is derived in-view.

// yyyy-MM-dd → Date, fixed UTC / en_US_POSIX (per task spec).
private let compareDayParser: DateFormatter = {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.timeZone = TimeZone(identifier: "UTC")
    f.dateFormat = "yyyy-MM-dd"
    return f
}()

private func parseCompareDay(_ day: String) -> Date? { compareDayParser.date(from: day) }

// MARK: - Range control (shared spec — W / M / 3M / 6M / 1Y / ALL)

/// The canonical Strand range window. `days == nil` means ALL of history.
enum CompareRange: String, CaseIterable, Identifiable {
    case week, month, quarter, half, year, all
    var id: String { rawValue }

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

    /// The trailing window length in days; nil = everything.
    var days: Int? {
        switch self {
        case .week:    return 7
        case .month:   return 30
        case .quarter: return 90
        case .half:    return 180
        case .year:    return 365
        case .all:     return nil
        }
    }

    /// A human phrase for sentences ("over 1Y").
    var phrase: String {
        switch self {
        case .week:    return "the last 7 days"
        case .month:   return "30 days"
        case .quarter: return "3 months"
        case .half:    return "6 months"
        case .year:    return "1 year"
        case .all:     return "all history"
        }
    }

    /// This range plus every LARGER range, ascending — the auto-expand search order
    /// when a selected window holds zero points for a series.
    var widening: [CompareRange] {
        let order: [CompareRange] = [.week, .month, .quarter, .half, .year, .all]
        guard let i = order.firstIndex(of: self) else { return [.all] }
        return Array(order[i...])
    }
}

// MARK: - Per-series model

/// One selected metric, resolved over the active window: its descriptor, the
/// windowed (day,value) rows, a stable display color, and its real min/max.
private struct CompareSeries: Identifiable {
    let metric: MetricDescriptor
    let color: Color
    let rows: [(day: String, value: Double)]

    var id: String { metric.id }
    var values: [Double] { rows.map(\.value) }
    var realMin: Double { values.min() ?? 0 }
    var realMax: Double { values.max() ?? 0 }

    /// Min–max normalize a value into 0…1 within this series' window. Flat series
    /// (max == min) collapse to the mid-line so they still render.
    func normalized(_ v: Double) -> Double {
        let lo = realMin, hi = realMax
        guard hi > lo else { return 0.5 }
        return min(max((v - lo) / (hi - lo), 0), 1)
    }

    /// The value on a given day, if recorded.
    func value(on day: String) -> Double? {
        rows.first(where: { $0.day == day })?.value
    }
}

// MARK: - Root

struct CompareView: View {
    @EnvironmentObject var repo: Repository

    // Distinct, high-legibility series colors (avoid the recovery/strain ramps so
    // overlay lines read as categorical, not as a value gradient).
    private static let seriesPalette: [Color] = [
        StrandPalette.accent,        // mint-green
        StrandPalette.metricCyan,    // cyan
        StrandPalette.metricPurple,  // purple
        StrandPalette.metricAmber,   // amber
    ]

    /// Default starter selection (falls back gracefully if a key is missing).
    private static let defaultKeys = ["recovery", "sleep_performance", "weight"]

    @State private var range: CompareRange = .year
    /// Ordered selection (max 4). Drives both the legend order and color mapping.
    @State private var selected: [MetricDescriptor] = []
    /// Full-history series per selected metric id (ascending by day).
    @State private var fullSeries: [String: [(day: String, value: Double)]] = [:]
    @State private var loadedOnce = false

    /// Cache of the last pairwise-correlation scan + the inputs it was computed for.
    /// The scan (alignByDay + Pearson over full windows) is expensive and was re-run on
    /// every body evaluation — including hover/animation/HR ticks. We recompute it only
    /// when the windowed series content actually changes (see `correlationKey`).
    @State private var pairCache: [PairResult] = []
    @State private var pairCacheKey: String = ""

    private let maxSelection = 4
    private let minSelection = 2

    var body: some View {
        ScreenScaffold(title: "Compare", subtitle: "Overlay signals, draw conclusions.") {
            VStack(alignment: .leading, spacing: NoopMetrics.sectionGap) {
                metricSection

                if selected.count < minSelection {
                    ComingSoon(what: "Compare needs at least two metrics with history. Import your WHOOP export in Data Sources first.")
                } else {
                    let series = activeSeries
                    if series.allSatisfy({ $0.rows.isEmpty }) {
                        ComingSoon(what: loadedOnce
                            ? "No data for these metrics in \(range.phrase). Widen the range or pick metrics you've logged."
                            : "Reading your history…")
                    } else {
                        overlaySection(series)
                        correlationSection(series)
                    }
                }
            }
        }
        .task { await loadIfNeeded() }
        .task(id: selectionKey) {
            await loadSelected()
            refreshPairCache(activeSeries)
        }
        // Recompute the pairwise scan only when the windowed series content changes,
        // never on hover/animation/HR-tick re-renders that don't touch these inputs.
        .onChange(of: correlationKey(activeSeries)) { _ in
            refreshPairCache(activeSeries)
        }
    }

    // MARK: - Selection key (re-loads when the set of metrics changes)

    private var selectionKey: String { selected.map(\.id).sorted().joined(separator: "|") }

    // MARK: - Active windowed series

    /// A full-history series' rows over a given range, taken RELATIVE TO THAT SERIES'
    /// LATEST data point (not "now"); `.all` returns everything.
    private func slice(_ full: [(day: String, value: Double)], _ r: CompareRange) -> [(day: String, value: Double)] {
        guard let n = r.days else { return full }
        guard let lastDay = full.last?.day, let last = parseCompareDay(lastDay) else { return [] }
        let cutoff = last.addingTimeInterval(-Double(n - 1) * 86_400)
        return full.filter { row in
            guard let d = parseCompareDay(row.day) else { return false }
            return d >= cutoff
        }
    }

    /// The range actually used for a series: the SELECTED range when its window holds
    /// ≥1 point, else the smallest LARGER range that does. So sparse metrics still
    /// overlay against dense ones, and switching ranges stays visibly distinct.
    private func effectiveRange(_ full: [(day: String, value: Double)]) -> CompareRange {
        guard !full.isEmpty else { return range }
        for r in range.widening where !slice(full, r).isEmpty { return r }
        return .all
    }

    /// Selected metrics resolved to windowed rows + stable colors, in pick order.
    private var activeSeries: [CompareSeries] {
        selected.enumerated().map { idx, metric in
            let full = fullSeries[metric.id] ?? []
            let rows = slice(full, effectiveRange(full))
            return CompareSeries(
                metric: metric,
                color: Self.seriesPalette[idx % Self.seriesPalette.count],
                rows: rows
            )
        }
    }

    /// True if any selected series had to auto-widen past the selected range.
    private var anyWidened: Bool {
        selected.contains { metric in
            let full = fullSeries[metric.id] ?? []
            return !full.isEmpty && effectiveRange(full) != range
        }
    }

    /// "N readings · <range>" caption near the control, flagging any auto-widen.
    private var rangeCaption: String {
        let series = activeSeries
        let total = series.reduce(0) { $0 + $1.rows.count }
        let unit = total == 1 ? "reading" : "readings"
        let base = "\(total) \(unit) across \(series.count) · \(range.phrase)"
        return anyWidened ? base + " · sparse widened" : base
    }

    // MARK: - Loading

    private func loadIfNeeded() async {
        guard selected.isEmpty else { return }
        // Seed the default selection from whichever default keys exist.
        var picks: [MetricDescriptor] = []
        for key in Self.defaultKeys {
            if let m = MetricCatalog.all.first(where: { $0.key == key }) { picks.append(m) }
        }
        if picks.isEmpty { picks = Array(MetricCatalog.all.prefix(2)) }
        selected = Array(picks.prefix(maxSelection))
    }

    /// Load (and cache) the full history for any selected metric not yet fetched.
    private func loadSelected() async {
        for metric in selected where fullSeries[metric.id] == nil {
            let s = await repo.series(key: metric.key, source: metric.source)
            fullSeries[metric.id] = s
        }
        loadedOnce = true
    }

    // MARK: - Metric picker section (chips + range control)

    private var metricSection: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.gap) {
            SectionHeader("Metrics", overline: "Overlay 2–4 signals")
            NoopCard {
                VStack(alignment: .leading, spacing: NoopMetrics.gap) {
                    HStack(alignment: .center) {
                        SegmentedPillControl(CompareRange.allCases, selection: $range) { $0.label }
                            .accessibilityLabel("Time range")
                        Spacer()
                        addMenu
                    }

                    if selected.count >= minSelection {
                        Text(rangeCaption)
                            .font(StrandFont.footnote)
                            .foregroundStyle(anyWidened ? StrandPalette.statusWarning : StrandPalette.textTertiary)
                            .accessibilityLabel(rangeCaption)
                    }

                    if selected.isEmpty {
                        Text("Nothing selected yet.")
                            .font(StrandFont.subhead)
                            .foregroundStyle(StrandPalette.textTertiary)
                    } else {
                        FlowChips(metrics: selected, colorFor: colorFor) { metric in
                            remove(metric)
                        }
                    }
                }
            }
        }
    }

    /// Grouped "add metric" menu, sectioned by catalog category. Disables already-
    /// picked metrics and the whole control once the cap is reached.
    private var addMenu: some View {
        Menu {
            ForEach(MetricCatalog.categories, id: \.self) { category in
                let metrics = MetricCatalog.inCategory(category)
                if !metrics.isEmpty {
                    Section(category) {
                        ForEach(metrics) { metric in
                            let isOn = selected.contains(metric)
                            Button {
                                toggle(metric)
                            } label: {
                                Label(metric.title, systemImage: isOn ? "checkmark" : metric.icon)
                            }
                            .disabled(!isOn && selected.count >= maxSelection)
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "plus.circle.fill")
                Text(selected.count >= maxSelection ? "Max 4" : "Add metric")
                    .font(StrandFont.subhead)
            }
            .foregroundStyle(selected.count >= maxSelection ? StrandPalette.textTertiary : StrandPalette.accent)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .disabled(selected.count >= maxSelection)
        .accessibilityLabel("Add a metric to compare")
    }

    private func colorFor(_ metric: MetricDescriptor) -> Color {
        guard let idx = selected.firstIndex(of: metric) else { return StrandPalette.textSecondary }
        return Self.seriesPalette[idx % Self.seriesPalette.count]
    }

    private func toggle(_ metric: MetricDescriptor) {
        if selected.contains(metric) {
            remove(metric)
        } else if selected.count < maxSelection {
            withAnimation(StrandMotion.gentle) { selected.append(metric) }
        }
    }

    private func remove(_ metric: MetricDescriptor) {
        withAnimation(StrandMotion.gentle) { selected.removeAll { $0 == metric } }
    }

    // MARK: - Overlay chart section (locked ChartCard)

    @ViewBuilder
    private func overlaySection(_ series: [CompareSeries]) -> some View {
        let nonEmpty = series.filter { !$0.rows.isEmpty }
        VStack(alignment: .leading, spacing: NoopMetrics.gap) {
            SectionHeader("Overlay", overline: "\(range.phrase)")
            ChartCard(
                title: "Normalized overlay",
                subtitle: anyWidened
                    ? "Min–max normalized · sparse series widened past \(range.phrase) · hover for real values"
                    : "Each line min–max normalized within \(range.phrase) · hover for real values",
                trailing: "\(nonEmpty.count) series"
            ) {
                OverlayChart(series: nonEmpty, height: NoopMetrics.chartHeight)
            } footer: {
                legend(nonEmpty)
            }
        }
    }

    private func legend(_ series: [CompareSeries]) -> some View {
        VStack(spacing: 0) {
            ForEach(Array(series.enumerated()), id: \.element.id) { idx, s in
                HStack(spacing: 10) {
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(s.color)
                        .frame(width: 14, height: 3)
                    Text(s.metric.title)
                        .font(StrandFont.subhead)
                        .foregroundStyle(StrandPalette.textPrimary)
                    Spacer()
                    Text("\(s.metric.format(s.realMin)) – \(s.metric.format(s.realMax))")
                        .font(StrandFont.captionNumber)
                        .foregroundStyle(StrandPalette.textSecondary)
                }
                .padding(.vertical, 7)
                .accessibilityElement(children: .combine)
                .accessibilityLabel("\(s.metric.title), range \(s.metric.format(s.realMin)) to \(s.metric.format(s.realMax))")
                if idx < series.count - 1 {
                    Divider().overlay(StrandPalette.hairline)
                }
            }
        }
    }

    // MARK: - Pairwise correlations card

    private struct PairResult: Identifiable {
        let id: String
        let a: CompareSeries
        let b: CompareSeries
        let r: Double
        let n: Int
    }

    /// A stable fingerprint of the inputs the correlation scan depends on: the
    /// non-empty series (in order) and their windowed content. Row content only
    /// changes when `selected`, `range`, or fetched `fullSeries` change, so this
    /// covers every case that alters the scan result. Used to invalidate `pairCache`.
    private func correlationKey(_ series: [CompareSeries]) -> String {
        series
            .filter { !$0.rows.isEmpty }
            .map { s in "\(s.id):\(s.rows.count):\(s.rows.first?.day ?? "")>\(s.rows.last?.day ?? "")" }
            .joined(separator: "|")
    }

    /// Cached accessor used by the body. Returns the memoized scan when the inputs
    /// match `pairCacheKey`; otherwise computes once for THIS render (without mutating
    /// state — that would be illegal mid-body) so the visible result is never stale by
    /// a frame. The matching `.onChange`/`.task` then persists the same result into
    /// `@State`, so subsequent renders (hover/animation/HR ticks) hit the cache.
    private func pairResults(_ series: [CompareSeries]) -> [PairResult] {
        correlationKey(series) == pairCacheKey ? pairCache : computePairResults(series)
    }

    /// The actual (expensive) pairwise scan. Pure — no view state read/written.
    private func computePairResults(_ series: [CompareSeries]) -> [PairResult] {
        var out: [PairResult] = []
        let s = series.filter { !$0.rows.isEmpty }
        guard s.count >= 2 else { return out }
        for i in 0..<(s.count - 1) {
            for j in (i + 1)..<s.count {
                let pairs = CorrelationEngine.alignByDay(s[i].rows, s[j].rows)
                guard pairs.count >= 3, let c = CorrelationEngine.pearson(pairs) else { continue }
                out.append(PairResult(
                    id: "\(s[i].id)~\(s[j].id)",
                    a: s[i], b: s[j], r: c.r, n: c.n
                ))
            }
        }
        // Strongest relationships first.
        out.sort { abs($0.r) > abs($1.r) }
        return out
    }

    /// Recompute the pair cache if (and only if) the correlation inputs changed.
    private func refreshPairCache(_ series: [CompareSeries]) {
        let key = correlationKey(series)
        guard key != pairCacheKey else { return }
        pairCacheKey = key
        pairCache = computePairResults(series)
    }

    @ViewBuilder
    private func correlationSection(_ series: [CompareSeries]) -> some View {
        let pairs = pairResults(series)
        VStack(alignment: .leading, spacing: NoopMetrics.gap) {
            SectionHeader("How They Move Together",
                          overline: "Pearson r · \(range.phrase)",
                          trailing: pairs.isEmpty ? nil : "\(pairs.count) pairs")

            if pairs.isEmpty {
                NoopCard {
                    Text("Not enough overlapping days between these metrics in \(range.phrase). Widen the range.")
                        .font(StrandFont.subhead)
                        .foregroundStyle(StrandPalette.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                ForEach(pairs) { p in
                    pairCard(p)
                }
            }
        }
    }

    /// One pairwise correlation as its own NoopCard.
    private func pairCard(_ p: PairResult) -> some View {
        let tint = correlationColor(p.r)
        return NoopCard {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    // Two color swatches for the pair.
                    HStack(spacing: 3) {
                        Circle().fill(p.a.color).frame(width: 8, height: 8)
                        Circle().fill(p.b.color).frame(width: 8, height: 8)
                    }
                    Text("\(p.a.metric.title) ↔ \(p.b.metric.title)")
                        .font(StrandFont.headline)
                        .foregroundStyle(StrandPalette.textPrimary)
                    Spacer()
                    Text("r = \(signedR(p.r))")
                        .font(StrandFont.number(18))
                        .foregroundStyle(tint)
                }

                Text(insightSentence(p))
                    .font(StrandFont.subhead)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                Text("\(p.n) overlapping days · \(strengthWord(p.r)) \(directionWord(p.r)) correlation")
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textTertiary)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(p.a.metric.title) versus \(p.b.metric.title), r equals \(String(format: "%.2f", p.r)), \(p.n) days")
    }

    // MARK: - Insight language

    /// "Weight ↔ Recovery: r = −0.34 (moderate negative) over 1Y" + a plain-English
    /// conclusion when |r| is notable.
    private func insightSentence(_ p: PairResult) -> String {
        let head = "\(p.a.metric.title) ↔ \(p.b.metric.title): r = \(signedR(p.r)) (\(strengthWord(p.r)) \(directionWord(p.r))) over \(p.n) shared days."
        guard abs(p.r) >= 0.3 else {
            return head + " No clear relationship — they move largely independently."
        }
        let lower = p.r < 0
        let aT = p.a.metric.title.lowercased()
        let bT = p.b.metric.title.lowercased()
        let verb = lower ? "tends to fall" : "tends to rise"
        return head + " When \(aT) rises, \(bT) \(verb) — a \(strengthWord(p.r)) \(directionWord(p.r)) link."
    }

    private func signedR(_ r: Double) -> String {
        (r >= 0 ? "+" : "−") + String(format: "%.2f", abs(r))
    }

    private func strengthWord(_ r: Double) -> String {
        switch abs(r) {
        case ..<0.1:  return "negligible"
        case ..<0.3:  return "weak"
        case ..<0.5:  return "moderate"
        case ..<0.7:  return "strong"
        default:      return "very strong"
        }
    }

    private func directionWord(_ r: Double) -> String {
        if abs(r) < 0.1 { return "" }
        return r >= 0 ? "positive" : "negative"
    }

    private func correlationColor(_ r: Double) -> Color {
        let base = r >= 0 ? StrandPalette.statusPositive : StrandPalette.statusCritical
        return base.opacity(0.55 + 0.45 * min(abs(r), 1.0))
    }
}

// MARK: - Selected-metric chips (wrapping flow layout)

/// Removable chips for the active selection, tinted to each series' color.
private struct FlowChips: View {
    let metrics: [MetricDescriptor]
    let colorFor: (MetricDescriptor) -> Color
    let onRemove: (MetricDescriptor) -> Void

    private let columns = [GridItem(.adaptive(minimum: 150), spacing: 8, alignment: .leading)]

    var body: some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: 8) {
            ForEach(metrics) { metric in
                let color = colorFor(metric)
                HStack(spacing: 7) {
                    Circle().fill(color).frame(width: 8, height: 8)
                    Text(metric.title)
                        .font(StrandFont.subhead)
                        .foregroundStyle(StrandPalette.textPrimary)
                        .lineLimit(1)
                    Spacer(minLength: 2)
                    Button {
                        onRemove(metric)
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(StrandPalette.textTertiary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Remove \(metric.title)")
                }
                .padding(.horizontal, 11)
                .padding(.vertical, 8)
                .background(
                    Capsule(style: .continuous).fill(StrandPalette.surfaceOverlay)
                )
                .overlay(
                    Capsule(style: .continuous).stroke(color.opacity(0.4), lineWidth: 1)
                )
            }
        }
    }
}

// MARK: - Overlay chart (custom multi-line Swift Chart, normalized 0–1)

/// Draws each series as its own colored line on a shared 0…1 normalized y-axis.
/// Hovering reveals a crosshair plus a tooltip listing every series' REAL value on
/// the nearest day.
private struct OverlayChart: View {
    let series: [CompareSeries]
    var height: CGFloat = 260

    @State private var hoverX: CGFloat? = nil

    // A flat, plottable point: the series title (drives the categorical color
    // scale), the date, and the min–max normalized y.
    private struct Plot: Identifiable {
        // Stable identity (one value per metric per day) so Chart can diff across renders instead
        // of treating every point as new on each hover tick — was `UUID()`, which forced full rebuilds.
        var id: String { title + "@" + String(date.timeIntervalSince1970) }
        let title: String
        let date: Date
        let norm: Double
    }

    /// All series flattened into normalized plot points (dropping unparseable days).
    private var plots: [Plot] {
        series.flatMap { s in
            s.rows.compactMap { row -> Plot? in
                guard let d = parseCompareDay(row.day) else { return nil }
                return Plot(title: s.metric.title, date: d, norm: s.normalized(row.value))
            }
        }
    }

    /// The union of all days present, ascending — the x-domain for hover snapping.
    private var allDays: [String] {
        var set = Set<String>()
        for s in series { for r in s.rows { set.insert(r.day) } }
        return set.sorted()
    }

    var body: some View {
        Chart(plots) { p in
            LineMark(
                x: .value("Date", p.date),
                y: .value("Normalized", p.norm)
            )
            .interpolationMethod(.catmullRom)
            .lineStyle(StrokeStyle(lineWidth: 2.2, lineCap: .round, lineJoin: .round))
            .foregroundStyle(by: .value("Metric", p.title))

            PointMark(
                x: .value("Date", p.date),
                y: .value("Normalized", p.norm)
            )
            .symbolSize(10)
            .foregroundStyle(by: .value("Metric", p.title))
        }
        .chartForegroundStyleScale(range: series.map(\.color))
        .chartYScale(domain: 0...1)
        .chartYAxis {
            // Normalized axis — label endpoints as low/high rather than raw numbers.
            AxisMarks(position: .leading, values: [0.0, 0.5, 1.0]) { value in
                AxisGridLine().foregroundStyle(StrandPalette.hairline.opacity(0.4))
                AxisValueLabel {
                    if let d = value.as(Double.self) {
                        Text(d == 0 ? "low" : d == 1 ? "high" : "mid")
                            .font(StrandFont.footnote)
                            .foregroundStyle(StrandPalette.textTertiary)
                    }
                }
            }
        }
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 5)) { _ in
                AxisGridLine().foregroundStyle(StrandPalette.hairline.opacity(0.4))
                AxisValueLabel().foregroundStyle(StrandPalette.textTertiary)
                    .font(StrandFont.footnote)
            }
        }
        .chartLegend(.hidden) // legend rendered separately with real min/max
        .chartOverlay { proxy in
            GeometryReader { geo in
                let plot = geo[proxy.plotAreaFrame]
                ZStack(alignment: .topLeading) {
                    if let hx = hoverX,
                       let day = nearestDay(toX: hx, proxy: proxy, plot: plot),
                       let d = parseCompareDay(day),
                       let px = proxy.position(forX: d) {
                        let cx = px + plot.minX
                        // Vertical crosshair at the hovered day.
                        Rectangle()
                            .fill(StrandPalette.hairlineStrong)
                            .frame(width: 1, height: geo.size.height)
                            .position(x: cx, y: geo.size.height / 2)

                        // Dot on each series at this day (where it has a value).
                        ForEach(series) { s in
                            if let v = s.value(on: day),
                               let py = proxy.position(forY: s.normalized(v)) {
                                Circle()
                                    .fill(s.color)
                                    .frame(width: 9, height: 9)
                                    .overlay(Circle().stroke(StrandPalette.surfaceBase, lineWidth: 2))
                                    .position(x: cx, y: py + plot.minY)
                            }
                        }

                        MultiTooltip(
                            day: day,
                            series: series,
                            anchorX: cx,
                            container: geo.size
                        )
                    }
                }
                .animation(StrandMotion.fade, value: hoverX)
                .contentShape(Rectangle())
                .onContinuousHover(coordinateSpace: .local) { phase in
                    switch phase {
                    case .active(let location): hoverX = location.x
                    case .ended: hoverX = nil
                    }
                }
            }
        }
        .frame(height: height)
    }

    /// Map a cursor x back to the nearest day-string present in the data.
    private func nearestDay(toX x: CGFloat, proxy: ChartProxy, plot: CGRect) -> String? {
        guard !allDays.isEmpty else { return nil }
        let relX = x - plot.minX
        guard let date: Date = proxy.value(atX: relX) else { return nil }
        return allDays.min(by: { a, b in
            let da = parseCompareDay(a) ?? .distantPast
            let db = parseCompareDay(b) ?? .distantPast
            return abs(da.timeIntervalSince(date)) < abs(db.timeIntervalSince(date))
        })
    }
}

// MARK: - Multi-series tooltip

/// A floating tooltip listing each series' REAL value on the hovered day, kept
/// inside the chart bounds.
private struct MultiTooltip: View {
    let day: String
    let series: [CompareSeries]
    let anchorX: CGFloat
    let container: CGSize

    private var dateLabel: String {
        guard let d = parseCompareDay(day) else { return day }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "EEE d MMM yyyy"
        return f.string(from: d)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(dateLabel)
                .font(StrandFont.footnote)
                .foregroundStyle(StrandPalette.textTertiary)
            ForEach(series) { s in
                HStack(spacing: 7) {
                    Circle().fill(s.color).frame(width: 7, height: 7)
                    Text(s.metric.title)
                        .font(StrandFont.caption)
                        .foregroundStyle(StrandPalette.textSecondary)
                    Spacer(minLength: 12)
                    Text(s.value(on: day).map { s.metric.format($0) } ?? "—")
                        .font(StrandFont.captionNumber)
                        .foregroundStyle(StrandPalette.textPrimary)
                }
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(StrandPalette.surfaceOverlay)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(StrandPalette.hairline, lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.4), radius: 10, y: 6)
        .frame(width: tooltipWidth, alignment: .leading)
        .position(x: clampedX, y: tooltipHeight / 2 + 8)
        .allowsHitTesting(false)
    }

    private var tooltipWidth: CGFloat { 220 }
    private var tooltipHeight: CGFloat { CGFloat(24 + series.count * 18) }

    /// Keep the tooltip on the side of the crosshair with more room, clamped.
    private var clampedX: CGFloat {
        let half = tooltipWidth / 2
        let preferRight = anchorX < container.width / 2
        let target = preferRight ? anchorX + half + 14 : anchorX - half - 14
        return min(max(target, half + 4), container.width - half - 4)
    }
}

// MARK: - Preview

#if DEBUG
@MainActor
private func comparePreviewRepo() -> Repository {
    let repo = Repository(deviceId: "preview")
    repo.loaded = true
    return repo
}

#Preview("Compare") {
    CompareView()
        .environmentObject(comparePreviewRepo())
        .frame(width: 920, height: 860)
        .preferredColorScheme(.dark)
}
#endif
