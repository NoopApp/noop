import SwiftUI
import Foundation
import StrandDesign
import StrandAnalytics
import WhoopStore

// MARK: - Insights
//
// The headline "interrogate what affects what" screen. Two halves:
//
//  1. BEHAVIOUR EFFECTS — split your logged journal answers (Alcohol, Caffeine,
//     Late meal, Meditation…) into the days each behaviour WAS logged vs NOT, then
//     compare a chosen outcome metric (Recovery / HRV / Sleep performance / RHR)
//     between the two groups. Ranked by effect size (Cohen's d) with significant
//     effects first; each card carries the plain-English sentence, the with/without
//     means, group counts, a significance pill, and the effect-size magnitude.
//     Tint is sign-aware: a behaviour that moves the outcome the "good" way
//     (respecting higherIsBetter) is positive/green, the "bad" way is critical/red.
//
//  2. METRIC RELATIONSHIPS — a curated set of Pearson correlations between daily
//     series (sleep ↔ recovery, today's strain ↔ next-day recovery via a 1-day lag,
//     HRV ↔ recovery, RHR ↔ recovery), each rendered as a one-line insight with r
//     and a plain-English reading of strength + direction.
//
// All math comes from StrandAnalytics (BehaviorInsights / CorrelationEngine); this
// view only loads the series, shapes them, and presents. Empty state via ComingSoon
// when there is no journal data to interrogate.

struct InsightsView: View {
    @EnvironmentObject var repo: Repository

    // MARK: Selected outcome (segmented)

    /// One interrogable outcome metric: how to fetch it and how to read its direction.
    enum Outcome: String, CaseIterable, Identifiable {
        case recovery, hrv, sleep, rhr
        var id: String { rawValue }

        /// Short segment label.
        var label: String {
            switch self {
            case .recovery: return "Charge"
            case .hrv:      return "HRV"
            case .sleep:    return "Rest"
            case .rhr:      return "RHR"
            }
        }
        /// The metricSeries key (source is always "my-whoop" for these).
        var key: String {
            switch self {
            case .recovery: return "recovery"
            case .hrv:      return "hrv"
            case .sleep:    return "sleep_performance"
            case .rhr:      return "rhr"
            }
        }
        /// The human outcome name used by BehaviorInsights.sentence.
        var outcomeName: String {
            switch self {
            case .recovery: return "Charge"
            case .hrv:      return "HRV"
            case .sleep:    return "Rest"
            case .rhr:      return "Resting HR"
            }
        }
        /// Whether a higher value is the "good" direction (drives tint).
        var higherIsBetter: Bool {
            switch self {
            case .recovery, .hrv, .sleep: return true
            case .rhr:                    return false
            }
        }
    }

    @State private var outcome: Outcome = .recovery

    // MARK: Loaded state

    /// behaviour question → set of days where it was answered yes.
    @State private var behaviours: [String: Set<String>] = [:]
    /// outcome key → [day: value].
    @State private var outcomeByKey: [String: [String: Double]] = [:]
    /// outcome key → ordered (day, value) series for correlations.
    @State private var seriesByKey: [String: [(day: String, value: Double)]] = [:]
    @State private var loaded = false

    // MARK: Memoized derived state
    //
    // The ranking and correlations are expensive (BehaviorInsights.rank +
    // four Pearson correlations) and were previously recomputed inside `body`
    // on EVERY render — including hover/animation/1Hz HR ticks. Cache them in
    // @State and recompute only when their inputs change.

    /// Ranked behaviour effects for the current outcome, recomputed via
    /// recomputeRanked() only when behaviours / outcomeByKey / outcome change.
    @State private var ranked: [BehaviorEffect] = []
    /// Curated metric relationships, recomputed via recomputeRelationships()
    /// only when the loaded series change.
    @State private var relationships: [Relationship] = []

    private let outcomeKeys = ["recovery", "hrv", "sleep_performance", "rhr"]

    // MARK: Native-logging state for the journal card

    /// Distinct imported question strings, so the card adopts the export's exact wording.
    @State private var importedQuestions: [String] = []
    /// The selected day's native answers (question → answeredYes) — drives the chip state.
    @State private var dayAnswers: [String: Bool] = [:]
    /// 0 = today, 1 = yesterday (late logging).
    @State private var journalDayOffset = 0

    var body: some View {
        ScreenScaffold(title: "Insights", subtitle: "Interrogate what affects what.") {
            if !loaded {
                ComingSoon(what: "Reading your journal and outcomes…")
            } else {
                VStack(alignment: .leading, spacing: NoopMetrics.sectionGap) {
                    // Native logging — always reachable: the account-free way into Insights.
                    JournalLogCard(importedQuestions: importedQuestions,
                                   answers: dayAnswers,
                                   dayOffset: $journalDayOffset,
                                   onChanged: { Task { await load() } })
                    // Mind — daily mood check-in + mood↔body correlations.
                    // Self-contained (owns its own load/state); sits with the
                    // journal card so the two daily-logging surfaces read as one
                    // "log today" block above the derived insights.
                    MindSection()
                    if behaviours.isEmpty {
                        // No journal yet — explain, without dead-ending on a paid export.
                        NoopCard {
                            Text("Log behaviours above — after a few days of answers, NOOP ranks how each one moves your charge, HRV and rest. Importing a WHOOP export (which includes its journal) backfills history instantly.")
                                .font(StrandFont.subhead)
                                .foregroundStyle(StrandPalette.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    } else {
                        behaviourSection
                    }
                    relationshipsSection
                }
            }
        }
        .task(id: repo.loaded) { await load() }
        // Recompute the cached ranking only when the outcome selection changes.
        // (behaviours / outcomeByKey change only at load, which calls
        //  recomputeRanked() directly, so keying on `outcome` is sufficient.)
        .onChange(of: outcome) { _ in recomputeRanked() }
    }

    // MARK: - Load

    private func load() async {
        // Journal → behaviours map (only "yes" answers count as the behaviour occurring).
        // journalEntries() is the imported ∪ native union (native wins per day+question).
        let entries = await repo.journalEntries()
        var byBehaviour: [String: Set<String>] = [:]
        for e in entries where e.answeredYes {
            byBehaviour[e.question, default: []].insert(e.day)
        }

        // The logging card's inputs: the export's exact question strings (so logged days join
        // imported history) and the selected day's native chip state — a targeted read, since the
        // merged list carries no deviceId to filter on.
        let imported = await repo.importedJournalEntries()
        let importedQs = NSOrderedSet(array: imported.map(\.question)).array as? [String] ?? []
        let selectedDayKey = Repository.localDayKey(
            Calendar.current.date(byAdding: .day, value: -journalDayOffset, to: Date()) ?? Date())
        let nativeAnswers = await repo.nativeJournalAnswers(day: selectedDayKey)

        // Daily metrics for the strap-only outcome fallback (merged, imported-wins). The view is
        // MainActor-isolated, so reading the published cache here is on the right actor.
        let mergedDays = repo.days

        // Outcome series (Whoop) → both [day:value] dictionaries and ordered series. The imported
        // metricSeries only exists after a CSV import; fill the days it doesn't cover from the
        // merged daily metrics so an account-free user's logging still gets effects
        // (recovery/hrv/rhr have daily columns; sleep_performance stays import-only).
        var byKey: [String: [String: Double]] = [:]
        var seriesMap: [String: [(day: String, value: Double)]] = [:]
        for key in outcomeKeys {
            let s = await repo.resolvedSeries(key: key, source: "my-whoop").values
            var dict: [String: Double] = [:]
            for row in s { dict[row.day] = row.value }
            for d in mergedDays where dict[d.day] == nil {
                if let v = Self.dailyOutcome(key: key, day: d) { dict[d.day] = v }
            }
            byKey[key] = dict
            seriesMap[key] = dict.sorted { $0.key < $1.key }.map { (day: $0.key, value: $0.value) }
        }

        await MainActor.run {
            self.behaviours = byBehaviour
            self.importedQuestions = importedQs
            self.dayAnswers = nativeAnswers
            self.outcomeByKey = byKey
            self.seriesByKey = seriesMap
            self.loaded = true
            // Seed the memoized derived state from the freshly loaded inputs.
            self.recomputeRanked()
            self.recomputeRelationships()
        }
    }

    /// The merged DailyMetric column backing an outcome key, for days the imported metricSeries
    /// doesn't cover (strap-only users). sleep_performance has no daily column, so it stays
    /// import-only — never seeded here.
    private static func dailyOutcome(key: String, day d: DailyMetric) -> Double? {
        switch key {
        case "recovery": return d.recovery
        case "hrv":      return d.avgHrv
        case "rhr":      return d.restingHr.map(Double.init)
        default:         return nil
        }
    }

    // MARK: - Memoized recomputation

    /// Rebuild the cached behaviour ranking for the current inputs.
    /// Called at load and whenever `outcome` changes — NOT in `body`.
    private func recomputeRanked() {
        let outcomeDays = outcomeByKey[outcome.key] ?? [:]
        ranked = BehaviorInsights.rank(
            behaviors: behaviours,
            outcomeByDay: outcomeDays,
            outcome: outcome.outcomeName
        )
    }

    /// Rebuild the cached metric relationships from the loaded series.
    /// Called at load only — the series don't change after that.
    private func recomputeRelationships() {
        relationships = computeRelationships()
    }

    // MARK: - Behaviour effects section

    private var behaviourSection: some View {
        // `ranked` is memoized in @State (see recomputeRanked()); reading it
        // here does no expensive work per render.
        VStack(alignment: .leading, spacing: NoopMetrics.gap) {
            // Header + the ONE segmented pill control for choosing the outcome.
            HStack(alignment: .center) {
                SectionHeader("Behaviour Effects",
                              overline: "What moves your \(outcome.outcomeName.lowercased())")
                Spacer()
                SegmentedPillControl(Outcome.allCases, selection: $outcome) { $0.label }
                    .accessibilityLabel("Outcome metric")
            }

            if ranked.isEmpty {
                noEffects
            } else {
                ForEach(ranked.indices, id: \.self) { i in
                    effectCard(ranked[i])
                }
            }
        }
    }

    private var noEffects: some View {
        NoopCard {
            Text("Not enough overlap between your journal answers and \(outcome.outcomeName.lowercased()) "
                + "to measure an effect yet. Keep logging — effects need days both with and without each behaviour.")
                .font(StrandFont.subhead)
                .foregroundStyle(StrandPalette.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// One behaviour-effect card: sentence + with/without StatTiles + significance pill.
    private func effectCard(_ e: BehaviorEffect) -> some View {
        // Sign-aware tint: did this behaviour move the outcome the GOOD way?
        // good move = (delta > 0 when higherIsBetter) OR (delta < 0 when lower is better).
        let movedGood: Bool? = {
            if e.delta == 0 { return nil }
            let up = e.delta > 0
            return up == outcome.higherIsBetter
        }()
        let tint: StrandTone = {
            guard let good = movedGood else { return .neutral }
            // Only let strong-tint shine when significant; weak effects read muted.
            if e.significant { return good ? .positive : .critical }
            return good ? .positive : .warning
        }()
        let tintColor = toneColor(tint)
        let deltaText: String = {
            let arrow = e.delta > 0 ? "↑" : (e.delta < 0 ? "↓" : "→")
            if let pct = e.pctChange { return "\(arrow) \(Int(abs(pct).rounded()))%" }
            return "\(arrow) \(String(format: "%.1f", abs(e.delta)))"
        }()
        // Build the plain-English sentence ONCE and reuse it for both the visible
        // copy and the accessibility label (was computed twice per card).
        let sentence = BehaviorInsights.sentence(e)

        return NoopCard {
            VStack(alignment: .leading, spacing: NoopMetrics.gap) {

                // Header: behaviour name + significance pill.
                HStack(alignment: .firstTextBaseline) {
                    HStack(spacing: 8) {
                        Circle().fill(tintColor).frame(width: 8, height: 8)
                        Text(e.behavior)
                            .font(StrandFont.headline)
                            .foregroundStyle(StrandPalette.textPrimary)
                    }
                    Spacer()
                    StatePill(e.significant ? "SIGNIFICANT" : "EXPLORATORY",
                              tone: e.significant ? .positive : .neutral,
                              showsDot: false)
                }

                // Plain-English sentence.
                Text(sentence)
                    .font(StrandFont.body)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                // With / without means as uniform StatTiles.
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 168), spacing: NoopMetrics.gap)],
                    alignment: .leading,
                    spacing: NoopMetrics.gap
                ) {
                    StatTile(label: "With",
                             value: formatOutcome(e.meanWith),
                             caption: "n = \(e.nWith)",
                             accent: tintColor,
                             delta: deltaText,
                             deltaColor: tintColor)
                    StatTile(label: "Without",
                             value: formatOutcome(e.meanWithout),
                             caption: "n = \(e.nWithout)",
                             accent: StrandPalette.textPrimary)
                }

                Divider().overlay(StrandPalette.hairline)

                // Effect-size footer: Cohen's d + interpretation.
                HStack {
                    Text("Effect size").strandOverline()
                    Spacer()
                    HStack(spacing: 6) {
                        Text(String(format: "d = %.2f", e.cohensD))
                            .font(StrandFont.captionNumber)
                            .foregroundStyle(tintColor)
                        Text(effectMagnitudeWord(e.cohensD))
                            .font(StrandFont.caption)
                            .foregroundStyle(StrandPalette.textTertiary)
                    }
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(sentence
            + " Cohen's d \(String(format: "%.2f", e.cohensD)). "
            + (e.significant ? "Statistically significant." : "Exploratory, not yet significant."))
    }

    // MARK: - Metric relationships section

    private var relationshipsSection: some View {
        // `relationships` is memoized in @State (see recomputeRelationships());
        // the four Pearson correlations no longer run per render.
        let rels = relationships
        return VStack(alignment: .leading, spacing: NoopMetrics.gap) {
            SectionHeader("Metric Relationships", overline: "Pearson r")

            if rels.isEmpty {
                NoopCard {
                    Text("Not enough overlapping history to correlate your metrics yet.")
                        .font(StrandFont.subhead)
                        .foregroundStyle(StrandPalette.textTertiary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                NoopCard {
                    VStack(spacing: 0) {
                        ForEach(Array(rels.enumerated()), id: \.element.id) { idx, rel in
                            relationshipRow(rel)
                            if idx < rels.count - 1 {
                                Divider().overlay(StrandPalette.hairline)
                            }
                        }
                    }
                }
            }
        }
    }

    /// A curated metric relationship plus its computed correlation.
    private struct Relationship: Identifiable {
        let id: String
        let title: String        // "Sleep → Recovery"
        let blurb: String        // what the pairing probes
        let corr: Correlation
    }

    private func computeRelationships() -> [Relationship] {
        func series(_ key: String) -> [(day: String, value: Double)] { seriesByKey[key] ?? [] }
        var out: [Relationship] = []

        // Sleep performance ↔ recovery (same day).
        if let c = CorrelationEngine.pearson(
            CorrelationEngine.alignByDay(series("sleep_performance"), series("recovery"))) {
            out.append(.init(id: "sleep-rec",
                             title: "Rest ↔ Charge",
                             blurb: "How closely a good night tracks next-morning charge.",
                             corr: c))
        }
        // HRV ↔ recovery (same day).
        if let c = CorrelationEngine.pearson(
            CorrelationEngine.alignByDay(series("hrv"), series("recovery"))) {
            out.append(.init(id: "hrv-rec",
                             title: "HRV ↔ Charge",
                             blurb: "Heart-rate variability as the engine behind your charge score.",
                             corr: c))
        }
        // Resting HR ↔ recovery (same day) — expected to be negative.
        if let c = CorrelationEngine.pearson(
            CorrelationEngine.alignByDay(series("rhr"), series("recovery"))) {
            out.append(.init(id: "rhr-rec",
                             title: "Resting HR ↔ Charge",
                             blurb: "A lower resting heart rate usually means a higher charge.",
                             corr: c))
        }
        // Today's recovery ↔ NEXT-day recovery (1-day lag) as a strain/carry-over proxy.
        // (Strain series isn't in the outcome set; recovery→next-day recovery shows
        //  how much yesterday carries into today.)
        if let c = CorrelationEngine.lagged(x: series("recovery"), y: series("recovery"), lagDays: 1) {
            out.append(.init(id: "rec-lag",
                             title: "Charge → Next-day charge",
                             blurb: "How much one day's charge carries into the next.",
                             corr: c))
        }

        return out
    }

    private func relationshipRow(_ rel: Relationship) -> some View {
        let r = rel.corr.r
        let strength = correlationColor(r)
        // Build the reading sentence ONCE and reuse it for the visible copy and
        // the accessibility label (was computed twice per row).
        let sentence = relationshipSentence(rel)
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(rel.title)
                    .font(StrandFont.headline)
                    .foregroundStyle(StrandPalette.textPrimary)
                Spacer()
                Text(String(format: "r = %+.2f", r))
                    .font(StrandFont.number(16))
                    .foregroundStyle(strength)
                StatePill(rel.corr.pApprox < 0.05 ? "p < 0.05" : "n.s.",
                          tone: rel.corr.pApprox < 0.05 ? .accent : .neutral,
                          showsDot: false)
            }

            // r bar — visual magnitude/direction (hover reveals the exact value).
            rBar(r: r, color: strength, label: rel.title)

            Text(sentence)
                .font(StrandFont.subhead)
                .foregroundStyle(StrandPalette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            Text(rel.blurb)
                .font(StrandFont.footnote)
                .foregroundStyle(StrandPalette.textTertiary)
        }
        .padding(.vertical, 11)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(sentence)
    }

    /// A centred bar: zero in the middle, fills left (negative) or right (positive)
    /// proportional to |r|. Hovering reveals a tooltip with the exact r value, so the
    /// bar — like every Strand chart — is never an unexplained coloured shape.
    private func rBar(r: Double, color: Color, label: String) -> some View {
        RBar(r: r, color: color, label: label)
    }

    // MARK: - Formatting / interpretation helpers

    /// Map a tone to its public palette color (StrandTone.color is module-internal).
    private func toneColor(_ tone: StrandTone) -> Color {
        switch tone {
        case .neutral:  return StrandPalette.textSecondary
        case .accent:   return StrandPalette.accent
        case .positive: return StrandPalette.statusPositive
        case .warning:  return StrandPalette.statusWarning
        case .critical: return StrandPalette.statusCritical
        }
    }

    /// Format an outcome value with sensible units for the selected metric.
    private func formatOutcome(_ v: Double) -> String {
        switch outcome {
        case .recovery, .sleep: return "\(Int(v.rounded()))%"
        case .hrv:              return "\(Int(v.rounded())) ms"
        case .rhr:              return "\(Int(v.rounded())) bpm"
        }
    }

    /// Cohen's d → conventional magnitude word.
    private func effectMagnitudeWord(_ d: Double) -> String {
        switch abs(d) {
        case ..<0.2:  return "negligible"
        case ..<0.5:  return "small"
        case ..<0.8:  return "moderate"
        default:      return "large"
        }
    }

    /// |r| → strength word.
    private func strengthWord(_ r: Double) -> String {
        switch abs(r) {
        case ..<0.1:  return "no"
        case ..<0.3:  return "a weak"
        case ..<0.5:  return "a moderate"
        case ..<0.7:  return "a strong"
        default:      return "a very strong"
        }
    }

    /// Tint a correlation by strength, keyed on the recovery gradient so strong
    /// positive reads mint and strong negative reads red.
    private func correlationColor(_ r: Double) -> Color {
        // Map r∈[-1,1] → 0…1 of the recovery scale (−1 red, 0 gold, +1 mint).
        StrandPalette.sample(stops: StrandPalette.recoveryStops, at: (r + 1) / 2)
    }

    private func relationshipSentence(_ rel: Relationship) -> String {
        let r = rel.corr.r
        let dir = r > 0 ? "positive" : (r < 0 ? "negative" : "flat")
        let strength = strengthWord(r)
        return "\(strength.capitalizedFirst) \(dir) relationship "
            + "(r = \(String(format: "%.2f", r)), n = \(rel.corr.n))."
    }
}

// MARK: - Correlation magnitude bar (hover-aware)

/// A centred correlation bar (zero in the middle, fills left/negative or
/// right/positive by |r|). On hover it shows the locked ChartTooltip with the exact
/// r value, matching the hover affordance every other Strand chart provides.
private struct RBar: View {
    let r: Double
    let color: Color
    let label: String

    @State private var hovering = false

    var body: some View {
        GeometryReader { geo in
            let half = geo.size.width / 2
            let mag = CGFloat(min(abs(r), 1.0)) * half
            ZStack(alignment: .leading) {
                Capsule().fill(StrandPalette.surfaceInset)
                // centre tick
                Rectangle()
                    .fill(StrandPalette.hairlineStrong)
                    .frame(width: 1)
                    .position(x: half, y: geo.size.height / 2)
                // value fill
                Capsule()
                    .fill(color)
                    .frame(width: mag, height: geo.size.height)
                    .offset(x: r >= 0 ? half : half - mag)
            }
            .clipShape(Capsule())
        }
        .frame(height: 8)
        // Tooltip floats above the bar without affecting layout (overlays aren't
        // clipped), so the exact r value reads on hover — same affordance as charts.
        .overlay(alignment: .center) {
            if hovering {
                ChartTooltip(
                    value: String(format: "r = %+.2f", r),
                    label: label,
                    accent: color
                )
                .fixedSize()
                .offset(y: -26)
                .transition(.opacity)
                .allowsHitTesting(false)
            }
        }
        .contentShape(Rectangle())
        .onContinuousHover { phase in
            switch phase {
            case .active: hovering = true
            case .ended:  hovering = false
            }
        }
        .animation(StrandMotion.fade, value: hovering)
        .accessibilityHidden(true)
    }
}

private extension String {
    /// Capitalise only the first letter (keeps "a weak" → "A weak").
    var capitalizedFirst: String {
        guard let first = first else { return self }
        return String(first).uppercased() + dropFirst()
    }
}

// MARK: - Preview

#if DEBUG
@MainActor
private func insightsPreviewRepo() -> Repository {
    let repo = Repository(deviceId: "preview")
    repo.loaded = true
    return repo
}

#Preview("Insights") {
    InsightsView()
        .environmentObject(insightsPreviewRepo())
        .frame(width: 920, height: 900)
        .preferredColorScheme(.dark)
}
#endif
