import SwiftUI
import Foundation
import StrandDesign
import StrandAnalytics
import WhoopStore

// MARK: - SleepView
//
// Whoop-sleep clarity on the locked Noop component system. Scannable in two seconds:
//   1. HERO ChartCard "Last night" — the stage breakdown (Hypnogram if intervals
//      reconstruct from stagesJSON, else a clean proportional stacked stage bar),
//      trailing = total asleep, footer = REM/Deep/Light/Awake each "Xh Ym · NN%".
//   2. A uniform grid of fixed StatTiles, each with a sparkline and a "vs typical"
//      caption: Performance, Efficiency, Consistency, Hours vs Needed, Restorative,
//      Respiratory, Sleep Debt.
//   2b. The sleep-debt LEDGER card — a rolling 14-night running balance of (slept −
//      personal need) with a plain-English read and a diverging per-night delta bar.
//   3. "Stages vs typical" NoopCard — Deep/REM/Light as horizontal bars, last-night
//      minutes with a marker at the personal typical (mean) so highs/lows pop.
//   4. A 30-day asleep-hours ChartCard trend.
//
// Every surface is a NoopCard / StatTile / ChartCard — no hand-sized cards, one grid,
// equal margins. Data wiring is preserved from the previous screen (stagesJSON =
// minutes for light/deep/rem/awake; typical = mean of repo.days).

struct SleepView: View {
    @EnvironmentObject var repo: Repository
    @EnvironmentObject var live: LiveState

    // The standard tile grid: ONE adaptive column set, used for every tile group.
    private let tileColumns = [GridItem(.adaptive(minimum: 168), spacing: NoopMetrics.gap)]

    /// Memoized snapshot of every expensive derivation (latest Night with its intervals
    /// resolved once, the seven metric series, the trend points, the typical means). Rebuilt
    /// only when the underlying repo data actually changes — NOT on hover/animation/1Hz HR
    /// ticks that merely re-evaluate `body`. `nil` until first build or when there's no night.
    @State private var model: SleepModel?
    /// The repo signature the cached `model` was built from. Cheap to compute every render;
    /// when it differs from the current inputs we rebuild the model.
    @State private var modelKey: SleepInputKey?

    /// Which night the hero hypnogram shows: 0 = last night, N = N sleep-sessions back.
    /// Snaps back to 0 whenever the data key changes — a stale offset would silently point
    /// at a different session after a sync. The memoized trend `model` stays cached since
    /// the trends are night-independent. (#160)
    @State private var nightOffset = 0
    /// Memoized decode of the NAVIGATED night (nil when `nightOffset == 0` — the hero reads
    /// `model.night` then). Rebuilt only in the `nightOffset` / data-key onChange handlers;
    /// `decodedNight` JSON-decodes, which must never run per body pass (1Hz HR ticks). (#160)
    @State private var navNight: Night?

    /// Every sleep BLOCK across both sources, UN-deduplicated (`repo.allSleepSessions`) — `repo.sleeps`
    /// keeps one winner per night for the dashboard, collapsing split-sleep days (a nap + a main
    /// sleep on the same day) into a single block. The hero groups these by day (`navDays`) and
    /// merges each day into one Night, so a split day reads as one correctly-totalled night with the
    /// gaps preserved. Oldest→newest. Falls back to `repo.sleeps` until loaded. (#170)
    @State private var allSessions: [CachedSleepSession] = []

    var body: some View {
        // Resolve the memoized model for THIS render. `dataKey` is O(1)-ish (counts + last-row
        // identity), so comparing it every render is cheap. When it matches the cached key we
        // reuse the cached model untouched — the many body re-evaluations from hover/animation/
        // 1Hz HR ticks pay nothing. When it differs (or on first render) we build once, here,
        // synchronously, so the very first frame already shows content (no empty-state flash).
        let key = dataKey
        let resolved: SleepModel? = (key == modelKey) ? model : buildModel()
        ScreenScaffold(title: "Sleep", subtitle: "Last night, read in two seconds.") {
            Group {
                if let resolved {
                    VStack(alignment: .leading, spacing: NoopMetrics.sectionGap) {
                        hero(resolved)
                        metricGrid(resolved)
                        sleepDebtLedger(resolved)
                        stagesVsTypical(resolved)
                        durationTrend(resolved)
                    }
                } else {
                    emptyState
                }
            }
            // Persist the freshly-built model so subsequent renders with the same inputs hit
            // the cache. Writing State during body is not allowed, so commit it after layout;
            // `resolved` already drives THIS frame, so there is no flash and no extra rebuild.
            .onChange(of: key) { newKey in
                modelKey = newKey
                model = buildModel()
                // New data invalidates a navigated offset — the same offset would silently
                // point at a different session. Snap back to last night. (#160)
                nightOffset = 0
                navNight = nil
            }
            // The navigated night is decoded once per ◀/▶ press, never per body pass —
            // `decodedNight` JSON-decodes and body re-evaluates at 1Hz while HR streams. (#160)
            .onChange(of: nightOffset) { newOffset in
                navNight = newOffset == 0 ? nil : decodedNight(at: newOffset)
            }
            .onAppear {
                if modelKey != key {
                    modelKey = key
                    model = resolved
                    nightOffset = 0
                    navNight = nil
                }
            }
            // Load EVERY sleep block across BOTH sources (un-deduplicated) so the hero's ◀/▶ can
            // browse split-sleep days the dashboard collapses — including Bluetooth-only nights,
            // whose blocks live under the computed source. Re-runs whenever a sync/import bumps
            // refreshSeq; snaps back to the newest day and rebuilds the model so offset 0 reflects
            // the freshly-loaded blocks. (#170)
            .task(id: repo.refreshSeq) {
                allSessions = await repo.allSleepSessions()
                nightOffset = 0
                navNight = nil
                modelKey = dataKey
                model = buildModel()
            }
        }
    }

    // MARK: - 1. HERO — stage breakdown

    @ViewBuilder
    private func hero(_ model: SleepModel) -> some View {
        // Offset 0 reads the memoized latest night; navigated offsets read the cached
        // `navNight` — never a fresh decode here (this runs on every 1Hz HR tick). When a
        // navigated session decoded to no usable stages, the header stays on that REAL
        // session's date/times with an honest placeholder in the chart slot — never the
        // latest night silently rendered under a navigated label. (#160)
        VStack(alignment: .leading, spacing: NoopMetrics.gap) {
            if nightOffset == 0 {
                nightNavHeader(trailing: model.night.spanLabel)
                sleepWindowRow(model.night)
                stageCard(model.night, intervals: model.intervals)
            } else if let night = navNight {
                nightNavHeader(trailing: night.spanLabel)
                sleepWindowRow(night)
                stageCard(night, intervals: night.intervals)
            } else if let session = sessionRow(at: nightOffset) {
                // Stage-less stub purely to reuse Night's date/time formatting.
                let stub = Night(session: session, stages: Stages(awake: 0, light: 0, deep: 0, rem: 0))
                nightNavHeader(trailing: stub.spanLabel)
                sleepWindowRow(stub)
                ChartCard(
                    title: "Stage breakdown",
                    subtitle: "\(durationText(Double(session.endTs - session.startTs) / 60.0)) in bed",
                    height: NoopMetrics.chartHeight,
                    chart: { noStagePlaceholder }
                )
            }
        }
    }

    /// The stage-breakdown ChartCard for a decoded night: hypnogram when intervals
    /// reconstruct, else the proportional stage bar. Intervals are passed in so offset 0
    /// uses the memoized `model.intervals` rather than re-deriving them. (#160)
    @ViewBuilder
    private func stageCard(_ night: Night, intervals: [SleepInterval]) -> some View {
        let s = night.stages
        let isPersisted = (night.realSegments?.count ?? 0) >= 2
        ChartCard(
            title: "Stage breakdown",
            subtitle: "\(durationText(night.timeInBed)) in bed · \(efficiencyText(night)) efficiency"
                + (isPersisted ? " · stages approximate (on-device)" : ""),
            trailing: durationText(s.asleep),
            height: NoopMetrics.chartHeight,
            chart: {
                if intervals.count >= 2 {
                    Hypnogram(intervals: intervals,
                              height: NoopMetrics.chartHeight,
                              showsStageAxis: true,
                              nightStart: night.onsetDate)
                } else {
                    stageBar(s)
                }
            },
            footer: {
                ChartFooter([
                    ("REM",   "\(durationText(s.rem)) · \(pct(s.rem, s.total))%"),
                    ("Deep",  "\(durationText(s.deep)) · \(pct(s.deep, s.total))%"),
                    ("Light", "\(durationText(s.light)) · \(pct(s.light, s.total))%"),
                    ("Awake", "\(durationText(s.awake)) · \(pct(s.awake, s.total))%"),
                ])
            }
        )
    }

    /// The night's clock window — when you fell asleep and when you woke — as its own clearly
    /// labelled row. These were previously only in the nav-header's trailing caption, which
    /// truncates between the two chevrons on a phone, so in practice the two times people look for
    /// first were effectively hidden. The header now carries just the date span.
    @ViewBuilder
    private func sleepWindowRow(_ night: Night) -> some View {
        HStack(spacing: 0) {
            sleepTime(icon: "moon.zzz.fill", label: "Asleep", value: night.onsetText)
            Spacer(minLength: 12)
            Rectangle().fill(StrandPalette.hairline).frame(width: 1, height: 30)
            Spacer(minLength: 12)
            sleepTime(icon: "sun.max.fill", label: "Woke", value: night.wakeText)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .frame(maxWidth: .infinity)
        .background(StrandPalette.surfaceRaised, in: RoundedRectangle(cornerRadius: 14))
    }

    private func sleepTime(icon: String, label: LocalizedStringKey, value: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(StrandFont.headline)
                .foregroundStyle(StrandPalette.accent)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(label).strandOverline()
                Text(value).font(StrandFont.number(22)).foregroundStyle(StrandPalette.textPrimary)
            }
        }
        .accessibilityElement(children: .combine)
    }

    /// Full-width proportional stacked stage bar (fallback when no intervals).
    @ViewBuilder
    private func stageBar(_ s: Stages) -> some View {
        let total = max(1, s.total)
        VStack(alignment: .leading, spacing: 10) {
            Spacer(minLength: 0)
            GeometryReader { geo in
                HStack(spacing: 2) {
                    segment(.deep, s.deep, total, geo.size.width)
                    segment(.light, s.light, total, geo.size.width)
                    segment(.rem, s.rem, total, geo.size.width)
                    segment(.awake, s.awake, total, geo.size.width)
                }
            }
            .frame(height: 34)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Sleep stage breakdown: deep \(pct(s.deep, s.total)) percent, light \(pct(s.light, s.total)) percent, REM \(pct(s.rem, s.total)) percent, awake \(pct(s.awake, s.total)) percent")
            HStack(spacing: 16) {
                legend(.deep, "Deep")
                legend(.light, "Light")
                legend(.rem, "REM")
                legend(.awake, "Awake")
            }
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private func segment(_ stage: SleepStage, _ minutes: Double, _ total: Double, _ width: CGFloat) -> some View {
        let w = CGFloat(minutes / total) * width
        Rectangle()
            .fill(StrandPalette.sleepStageColor(stage))
            .frame(width: max(0, w))
    }

    @ViewBuilder
    private func legend(_ stage: SleepStage, _ label: String) -> some View {
        HStack(spacing: 5) {
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(StrandPalette.sleepStageColor(stage))
                .frame(width: 9, height: 9)
            Text(label).font(StrandFont.footnote).foregroundStyle(StrandPalette.textTertiary)
        }
    }

    // MARK: - 2. Metric grid (UNIFORM fixed-height StatTiles, each with sparkline)

    @ViewBuilder
    private func metricGrid(_ model: SleepModel) -> some View {
        // Per-tile latest value + history series (for the sparkline) + typical mean.
        // All seven series are computed ONCE in the model build (each is a full pass over
        // repo.days/repo.sleeps) — here we only read the memoized results.
        let perf  = model.performance
        let eff   = model.efficiency
        let cons  = model.consistency
        let need  = model.hoursVsNeeded
        let rest  = model.restorative
        let resp  = model.respiratory
        let debt  = model.sleepDebt

        VStack(alignment: .leading, spacing: NoopMetrics.gap) {
            SectionHeader("Night detail", overline: "Metrics", trailing: "vs typical")
            LazyVGrid(columns: tileColumns, alignment: .leading, spacing: NoopMetrics.gap) {

                StatTile(
                    label: "Rest",
                    value: pctValue(perf.latest),
                    caption: vsTypical(perf.latest, perf.typical, suffix: "%"),
                    accent: perf.latest.map { StrandPalette.recoveryColor($0) } ?? StrandPalette.textPrimary,
                    sparkline: spark(perf.series),
                    sparkColor: StrandPalette.accent)

                StatTile(
                    label: "Efficiency",
                    value: pctValue(eff.latest),
                    caption: vsTypical(eff.latest, eff.typical, suffix: "%"),
                    accent: StrandPalette.statusPositive,
                    sparkline: spark(eff.series),
                    sparkColor: StrandPalette.statusPositive)

                StatTile(
                    label: "Consistency",
                    value: pctValue(cons.latest),
                    caption: vsTypical(cons.latest, cons.typical, suffix: "%"),
                    accent: cons.latest.map { StrandPalette.recoveryColor($0) } ?? StrandPalette.textPrimary,
                    sparkline: spark(cons.series),
                    sparkColor: StrandPalette.metricCyan)

                StatTile(
                    label: "Hours vs Needed",
                    value: pctValue(need.latest),
                    caption: vsTypical(need.latest, need.typical, suffix: "%"),
                    accent: need.latest.map { StrandPalette.recoveryColor(min(100, $0)) } ?? StrandPalette.textPrimary,
                    sparkline: spark(need.series),
                    sparkColor: StrandPalette.accent)

                StatTile(
                    label: "Restorative",
                    value: pctValue(rest.latest),
                    caption: vsTypical(rest.latest, rest.typical, suffix: "%"),
                    accent: StrandPalette.sleepREM,
                    sparkline: spark(rest.series),
                    sparkColor: StrandPalette.sleepREM)

                StatTile(
                    label: "Respiratory",
                    value: rrValue(resp.latest),
                    caption: vsTypical(resp.latest, resp.typical, suffix: " rpm", decimals: 1),
                    accent: StrandPalette.metricPurple,
                    sparkline: spark(resp.series),
                    sparkColor: StrandPalette.metricPurple)

                StatTile(
                    label: "Sleep Debt",
                    value: debt.latest.map { durationText($0) } ?? "—",
                    caption: debtCaption(debt.latest),
                    accent: debtColor(debt.latest),
                    sparkline: spark(debt.series),
                    sparkColor: StrandPalette.metricRose)
            }
        }
    }

    // MARK: - 2b. Sleep-debt ledger (rolling 14-night running balance)

    /// A running balance of (slept − personal need) across the recent fortnight, surfaced
    /// as one card: the net debt/surplus headline, a plain-English read, and a diverging
    /// bar of each night's delta (surplus above the line, deficit below). Honest: a simple
    /// accumulator — a surplus night offsets a deficit one — capped at 14 nights, no-data
    /// nights skipped. (#242)
    @ViewBuilder
    private func sleepDebtLedger(_ model: SleepModel) -> some View {
        let ledger = model.sleepDebtLedger
        VStack(alignment: .leading, spacing: NoopMetrics.gap) {
            SectionHeader("Sleep-debt ledger", overline: "Last 14 nights",
                          trailing: "running balance")
            NoopCard {
                if ledger.nightCount == 0 {
                    Text("No nights with sleep data yet — your ledger fills in as you wear the strap to bed.")
                        .font(StrandFont.subhead)
                        .foregroundStyle(StrandPalette.textTertiary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    VStack(alignment: .leading, spacing: 14) {
                        // Headline: net balance + the short tag (DEBT / SURPLUS / ON TARGET).
                        HStack(alignment: .firstTextBaseline) {
                            Text(debtHeadline(ledger))
                                .font(StrandFont.number(26))
                                .foregroundStyle(debtBalanceColor(ledger))
                                .lineLimit(1)
                                .minimumScaleFactor(0.6)
                            Spacer(minLength: 8)
                            Text(debtTag(ledger))
                                .font(StrandFont.captionNumber)
                                .foregroundStyle(debtBalanceColor(ledger))
                        }
                        // Plain-English read.
                        Text(debtRead(ledger))
                            .font(StrandFont.subhead)
                            .foregroundStyle(StrandPalette.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                        // Per-night diverging delta bars (surplus up, deficit down).
                        debtDeltaBars(ledger)
                        Divider().overlay(StrandPalette.hairline)
                        ChartFooter([
                            ("Balance", debtSigned(ledger.balanceMin)),
                            ("Per-night need", durationText(ledger.needMin)),
                            ("Nights", "\(ledger.nightCount)"),
                        ])
                    }
                }
            }
        }
    }

    /// The diverging per-night delta strip: each night a bar from the centre line — up
    /// (accent) for a surplus, down (rose) for a deficit — scaled to the largest |delta|.
    @ViewBuilder
    private func debtDeltaBars(_ ledger: SleepDebtLedger) -> some View {
        let deltas = ledger.nights.map { $0.deltaMin }
        let scale = max(deltas.map { abs($0) }.max() ?? 1, 1)
        GeometryReader { geo in
            let n = max(deltas.count, 1)
            let slot = geo.size.width / CGFloat(n)
            let barW = max(2, slot * 0.6)
            let midY = geo.size.height / 2
            ZStack(alignment: .topLeading) {
                // Centre (zero) line.
                Rectangle()
                    .fill(StrandPalette.hairline)
                    .frame(height: 1)
                    .position(x: geo.size.width / 2, y: midY)
                ForEach(Array(deltas.enumerated()), id: \.offset) { i, d in
                    let frac = CGFloat(abs(d) / scale)
                    let h = max(2, frac * (midY - 2))
                    let x = slot * CGFloat(i) + slot / 2
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(d >= 0 ? StrandPalette.accent : StrandPalette.metricRose)
                        .frame(width: barW, height: h)
                        // Surplus grows upward from the centre, deficit downward.
                        .position(x: x, y: d >= 0 ? midY - h / 2 : midY + h / 2)
                }
            }
        }
        .frame(height: 56)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Per-night sleep balance: \(ledger.nightCount) nights, net \(debtSigned(ledger.balanceMin))")
    }

    // MARK: - 3. Stages vs typical

    @ViewBuilder
    private func stagesVsTypical(_ model: SleepModel) -> some View {
        let s = model.night.stages
        // Per-stage typical means are computed ONCE in the model build (each a full pass
        // over repo.days) and read here.
        VStack(alignment: .leading, spacing: NoopMetrics.gap) {
            SectionHeader("Stages vs typical", overline: "Last night",
                          trailing: "marker = your mean")
            NoopCard {
                VStack(alignment: .leading, spacing: 14) {
                    stageRow("Deep",  last: s.deep,  typical: model.typicalDeepMin,  color: StrandPalette.sleepDeep)
                    Divider().overlay(StrandPalette.hairline)
                    stageRow("REM",   last: s.rem,   typical: model.typicalRemMin,   color: StrandPalette.sleepREM)
                    Divider().overlay(StrandPalette.hairline)
                    stageRow("Light", last: s.light, typical: model.typicalLightMin, color: StrandPalette.sleepLight)
                }
            }
        }
    }

    /// One stage bar: last-night minutes filled, with a vertical marker at the typical mean.
    @ViewBuilder
    private func stageRow(_ label: String, last: Double, typical: Double?, color: Color) -> some View {
        // Scale both values against a shared per-row max so the marker is meaningful.
        let scaleMax = max(last, typical ?? 0) * 1.18
        let max = scaleMax > 0 ? scaleMax : 1
        let deltaText: String = {
            guard let typical, typical > 0 else { return "" }
            let diff = last - typical
            let sign = diff >= 0 ? "+" : "−"
            return "\(sign)\(durationText(abs(diff))) vs typ"
        }()
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(label.uppercased()).strandOverline()
                Spacer()
                Text(durationText(last)).font(StrandFont.captionNumber).foregroundStyle(StrandPalette.textPrimary)
                if !deltaText.isEmpty {
                    Text(deltaText)
                        .font(StrandFont.footnote)
                        .foregroundStyle(last >= (typical ?? last) ? StrandPalette.statusPositive : StrandPalette.statusWarning)
                }
            }
            GeometryReader { geo in
                let w = geo.size.width
                ZStack(alignment: .leading) {
                    // track
                    Capsule(style: .continuous)
                        .fill(StrandPalette.surfaceInset)
                    // last-night fill
                    Capsule(style: .continuous)
                        .fill(color)
                        .frame(width: w * CGFloat(min(1, last / max)))
                    // typical marker
                    if let typical, typical > 0 {
                        Rectangle()
                            .fill(StrandPalette.textPrimary)
                            .frame(width: 2, height: 16)
                            .position(x: w * CGFloat(min(1, typical / max)), y: 5)
                    }
                }
            }
            .frame(height: 10)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(label): \(durationText(last)) last night\(typical.map { ", typical \(durationText($0))" } ?? "")")
        }
    }

    // MARK: - 4. 30-day asleep-hours trend

    @ViewBuilder
    private func durationTrend(_ model: SleepModel) -> some View {
        // Trailing-30 trend points and the typical total are precomputed in the model build
        // (full passes over repo.days) — read here, not recomputed per render.
        let pts = model.trendPoints
        let avg = model.typicalTotalMin.map { $0 / 60.0 }
        VStack(alignment: .leading, spacing: NoopMetrics.gap) {
            SectionHeader("Asleep duration", overline: "Trend", trailing: "Last 30 days")
            ChartCard(
                title: "Hours asleep",
                subtitle: "Per night, trailing 30 days",
                trailing: avg.map { String(format: "%.1f h avg", $0) },
                height: NoopMetrics.chartHeight,
                chart: {
                    if pts.count >= 2 {
                        TrendChart(points: pts,
                                   gradient: StrandPalette.recoveryGradient,
                                   valueRange: trendRange(pts),
                                   showsArea: true,
                                   height: NoopMetrics.chartHeight,
                                   valueFormat: { String(format: "%.1f h", $0) })
                    } else {
                        sparsePlaceholder
                    }
                },
                footer: {
                    ChartFooter([
                        ("Avg",    avg.map { String(format: "%.1f h", $0) } ?? "—"),
                        ("Min",    pts.map(\.value).min().map { String(format: "%.1f h", $0) } ?? "—"),
                        ("Max",    pts.map(\.value).max().map { String(format: "%.1f h", $0) } ?? "—"),
                        ("Nights", "\(pts.count)"),
                    ])
                }
            )
        }
    }

    // MARK: - Memoization plumbing

    /// A cheap fingerprint of the repo inputs this screen derives from. Recomputed every
    /// render but only contains counts + the identity of the newest/oldest rows, so equality
    /// is fast. When it changes we know `repo.days`/`repo.sleeps` actually changed and the
    /// memoized `model` must be rebuilt; otherwise hover/animation/1Hz HR re-renders are free.
    private var dataKey: SleepInputKey {
        SleepInputKey(
            loaded: repo.loaded,
            daysCount: repo.days.count,
            sleepsCount: repo.sleeps.count,
            firstDay: repo.days.first?.day,
            lastDay: repo.days.last?.day,
            lastDayUpdated: repo.days.last,
            lastSleep: repo.sleeps.last,
            refreshSeq: repo.refreshSeq)
    }

    /// Build every expensive derivation exactly once. Called only when `dataKey` changes,
    /// so each full pass over repo.days / repo.sleeps runs once per data change rather than
    /// once per render. Returns nil when there is no usable latest night (renders empty state).
    private func buildModel() -> SleepModel? {
        guard let night = latestNight else { return nil }
        return SleepModel(
            night: night,
            intervals: night.intervals,
            isPersistedHypnogram: (night.realSegments?.count ?? 0) >= 2,
            performance: performanceSeries,
            efficiency: efficiencySeries,
            consistency: consistencySeries,
            hoursVsNeeded: hoursVsNeededSeries,
            restorative: restorativeSeries,
            respiratory: respiratorySeries,
            sleepDebt: sleepDebtSeries,
            typicalTotalMin: typicalTotalMin,
            typicalDeepMin: typicalStageMin(\.deepMin),
            typicalRemMin: typicalStageMin(\.remMin),
            typicalLightMin: typicalStageMin(\.lightMin),
            trendPoints: durationTrendPoints,
            sleepDebtLedger: debtLedger)
    }

    /// The rolling 14-night sleep-debt ledger from the cached daily metrics. Uses the
    /// SAME personal sleep need the tiles use (`sleepNeedMin`, ≥ 7.5 h, the per-user
    /// override over the 8 h default), measured against each night's `totalSleepMin`.
    /// Skips nights with no sleep (the analytics function does the skip). (#242)
    private var debtLedger: SleepDebtLedger {
        SleepDebt.ledger(
            series: repo.days.map { (day: $0.day, totalSleepMin: $0.totalSleepMin) },
            needHours: sleepNeedMin / 60.0)
    }

    // MARK: - Derived model

    /// The most recent sleep, decoded into stage durations. TWO stagesJSON formats exist:
    /// imported nights store a dict of MINUTES {"light","deep","rem","awake"}; on-device computed
    /// nights store a SEGMENT ARRAY [{start,end,stage}] (AnalyticsEngine.encodeStages). Only the
    /// dict was decoded before, so a Bluetooth-only user's night vanished from this tab entirely
    /// while Intelligence showed it (#77). Computed nights also carry their REAL timeline now —
    /// the hypnogram draws genuine segments instead of the synthetic reconstruction.
    private var latestNight: Night? { decodedNight(at: 0) }

    /// The browsable block list: every sleep session un-deduplicated (incl. same-day naps / split
    /// sleep). Falls back to `repo.sleeps` (one-per-night) until the fuller list loads, so the hero
    /// is never empty during the first frame. (#170)
    private var navSessions: [CachedSleepSession] {
        allSessions.isEmpty ? repo.sleeps : allSessions
    }

    /// The browsable DAY list: every block grouped by the calendar day it ENDS on (matching the
    /// dashboard's per-night merge), newest day first, blocks within a day oldest→newest. Each day
    /// is ONE ◀/▶ stop, so a split-sleep day reads as a single night and the "N nights ago" label
    /// stays truthful — two blocks of the same day are never "1 night ago" AND "2 nights ago". (#170)
    private var navDays: [[CachedSleepSession]] {
        let cal = Calendar.current
        func endDay(_ s: CachedSleepSession) -> Date {
            cal.startOfDay(for: Date(timeIntervalSince1970: TimeInterval(s.endTs)))
        }
        let groups = Dictionary(grouping: navSessions, by: endDay)
        return groups.keys.sorted(by: >).map { key in
            (groups[key] ?? []).sorted { $0.startTs < $1.startTs }
        }
    }

    /// Merge all of a day's blocks into ONE `Night`: stage minutes summed, each block's timeline
    /// concatenated onto a single axis with the REAL gap between blocks preserved, efficiency
    /// recomputed over time-in-bed (carried on the synthetic session so a navigated day never
    /// borrows `repo.today`'s efficiency). Returns nil if no block decodes to usable stages. (#170)
    private func mergeDay(_ sessions: [CachedSleepSession]) -> Night? {
        guard let first = sessions.first,
              let last = sessions.max(by: { $0.endTs < $1.endTs }) else { return nil }
        let onset = first.startTs, wake = last.endTs
        var stages = Stages(awake: 0, light: 0, deep: 0, rem: 0)
        var segs: [SleepInterval] = []
        for s in sessions {
            let shift = TimeInterval(s.startTs - onset)
            if let seg = decodeSegments(s.stagesJSON, sessionStart: s.startTs), seg.stages.total > 0 {
                stages.awake += seg.stages.awake; stages.light += seg.stages.light
                stages.deep  += seg.stages.deep;  stages.rem   += seg.stages.rem
                for iv in seg.intervals {
                    segs.append(SleepInterval(stage: iv.stage, start: iv.start + shift, end: iv.end + shift))
                }
            } else if let st = decodeStages(s.stagesJSON), st.total > 0 {
                stages.awake += st.awake; stages.light += st.light
                stages.deep  += st.deep;  stages.rem   += st.rem
            }
        }
        guard stages.asleep > 0 else { return nil }
        let eff = stages.total > 0 ? stages.asleep / stages.total : nil   // fraction ≤ 1
        let synth = CachedSleepSession(startTs: onset, endTs: wake, efficiency: eff,
                                       restingHr: nil, avgHrv: nil, stagesJSON: nil)
        let realSegs = segs.count >= 2 ? segs.sorted { $0.start < $1.start } : nil
        return Night(session: synth, stages: stages, realSegments: realSegs)
    }

    /// The merged Night for the DAY `offset` stops back from the most recent (0 = last night).
    /// Backs the hero's ◀/▶ navigation via the `navNight` cache — JSON-decodes, so it only runs
    /// from `buildModel()` and the onChange handlers, never per render. (#160, #170)
    private func decodedNight(at offset: Int) -> Night? {
        let days = navDays
        guard offset >= 0, offset < days.count else { return nil }
        return mergeDay(days[offset])
    }

    /// A synthetic session spanning the DAY `offset` stops back (onset of its first block → wake of
    /// its last), for the honest no-stage-data header when a day's blocks don't decode to usable
    /// stages. (#160, #170)
    private func sessionRow(at offset: Int) -> CachedSleepSession? {
        let days = navDays
        guard offset >= 0, offset < days.count,
              let first = days[offset].first,
              let last = days[offset].max(by: { $0.endTs < $1.endTs }) else { return nil }
        return CachedSleepSession(startTs: first.startTs, endTs: last.endTs,
                                  efficiency: nil, restingHr: nil, avgHrv: nil, stagesJSON: nil)
    }

    /// Header above the hypnogram with ◀/▶ to browse past nights. ◀ goes older (increasing offset),
    /// ▶ goes newer; each is disabled at its bound. The canonical SectionHeader carries the
    /// hierarchy so the hero reads like every other section. (#160)
    @ViewBuilder
    private func nightNavHeader(trailing: String) -> some View {
        let lastIndex = max(navDays.count - 1, 0)
        let title: LocalizedStringKey = nightOffset == 0 ? "Last night"
            : (nightOffset == 1 ? "1 night ago" : "\(nightOffset) nights ago")
        HStack(spacing: 12) {
            Button { if nightOffset < lastIndex { nightOffset += 1 } } label: {
                Image(systemName: "chevron.left")
                    .font(StrandFont.headline)
                    .foregroundStyle(nightOffset >= lastIndex ? StrandPalette.textTertiary : StrandPalette.accent)
            }
            .buttonStyle(.plain)
            .disabled(nightOffset >= lastIndex)
            .accessibilityLabel("Previous night")

            SectionHeader(title, overline: "Sleep", trailing: trailing)

            Button { if nightOffset > 0 { nightOffset -= 1 } } label: {
                Image(systemName: "chevron.right")
                    .font(StrandFont.headline)
                    .foregroundStyle(nightOffset == 0 ? StrandPalette.textTertiary : StrandPalette.accent)
            }
            .buttonStyle(.plain)
            .disabled(nightOffset == 0)
            .accessibilityLabel("Next night")
        }
    }

    /// Mean total sleep duration (minutes) across nights with data — the "typical".
    private var typicalTotalMin: Double? {
        mean(repo.days.compactMap { $0.totalSleepMin }.filter { $0 > 0 })
    }

    /// Mean of a per-stage minutes column across days with data.
    private func typicalStageMin(_ key: KeyPath<DailyMetric, Double?>) -> Double? {
        mean(repo.days.compactMap { $0[keyPath: key] }.filter { $0 > 0 })
    }

    // MARK: - Per-tile series (latest, typical mean, sparkline history)

    private typealias Metric = (latest: Double?, typical: Double?, series: [Double])

    /// Build a metric from a per-day transform, keeping only finite positive-ish values.
    private func metric(_ transform: (DailyMetric) -> Double?) -> Metric {
        let series = repo.days.compactMap(transform).filter { $0.isFinite }
        return (series.last, mean(series), series)
    }

    /// Sleep performance %: the imported WHOOP figure (sleep_performance, 0–100) when the
    /// export carried one for that day; else the APPROXIMATE fallback (asleep / personal
    /// need, capped 100) so strap-only days after the import horizon stay populated.
    private var performanceSeries: Metric {
        let imported = repo.importedSleep
        let need = sleepNeedMin
        return metric { d in
            if let p = imported[d.day]?.performancePct { return p }   // export-verbatim
            guard let asleep = d.totalSleepMin, asleep > 0, need > 0 else { return nil }
            return min(100, asleep / need * 100)   // APPROXIMATE fallback
        }
    }

    private var efficiencySeries: Metric {
        metric { d in
            guard let e = d.efficiency else { return nil }
            return e <= 1.0 ? e * 100 : e
        }
    }

    /// Consistency: prefer the imported sleep_consistency series, but only when it covers
    /// the latest night — otherwise "latest" would silently be a months-old import-era
    /// value. Fallback is the APPROXIMATE rolling bedtime-spread score (per session, lower
    /// spread → higher score, same SD→score mapping).
    private var consistencySeries: Metric {
        let imported = repo.importedSleep
        if let lastDay = repo.days.last?.day, imported[lastDay]?.consistencyPct != nil {
            let series = repo.days.compactMap { imported[$0.day]?.consistencyPct }
            return (series.last, mean(series), series)
        }
        let cal = Calendar.current
        func bedMinutes(_ s: CachedSleepSession) -> Double {
            let d = Date(timeIntervalSince1970: TimeInterval(s.startTs))
            let comps = cal.dateComponents([.hour, .minute], from: d)
            var m = Double((comps.hour ?? 0) * 60 + (comps.minute ?? 0))
            if m < 12 * 60 { m += 24 * 60 }   // wrap evening onsets into one continuous scale
            return m
        }
        let mins = repo.sleeps.map(bedMinutes)
        guard mins.count >= 3 else { return (nil, nil, []) }
        var scores: [Double] = []
        for i in mins.indices {
            let lo = Swift.max(0, i - 13)
            let window = Array(mins[lo...i])
            guard window.count >= 3 else { continue }
            let m = window.reduce(0, +) / Double(window.count)
            let variance = window.map { ($0 - m) * ($0 - m) }.reduce(0, +) / Double(window.count)
            let sd = variance.squareRoot()
            scores.append(Swift.max(0, Swift.min(100, 100 * (1 - sd / 120))))
        }
        return (scores.last, mean(scores), scores)
    }

    /// Hours vs needed % = asleep / need (can exceed 100 on a long night). The imported
    /// sleep_need_min wins per day; else the APPROXIMATE personal-mean need.
    private var hoursVsNeededSeries: Metric {
        let imported = repo.importedSleep
        let fallbackNeed = sleepNeedMin
        return metric { d in
            guard let asleep = d.totalSleepMin, asleep > 0 else { return nil }
            let need = imported[d.day]?.needMin ?? fallbackNeed
            guard need > 0 else { return nil }
            return asleep / need * 100
        }
    }

    /// Restorative % = (deep + REM) / asleep — the share of the night that does the work.
    private var restorativeSeries: Metric {
        metric { d in
            guard let deep = d.deepMin, let rem = d.remMin,
                  let asleep = d.totalSleepMin, asleep > 0 else { return nil }
            return (deep + rem) / asleep * 100
        }
    }

    private var respiratorySeries: Metric {
        metric { $0.respRateBpm }
    }

    /// Sleep debt (minutes): the imported sleep_debt_min when the export carried it; else
    /// the APPROXIMATE per-night need − asleep, floored at 0 (no "credit").
    private var sleepDebtSeries: Metric {
        let imported = repo.importedSleep
        let need = sleepNeedMin
        let series = repo.days.compactMap { d -> Double? in
            if let debt = imported[d.day]?.debtMin { return debt }   // minutes, export-verbatim
            guard let asleep = d.totalSleepMin, asleep > 0, need > 0 else { return nil }
            return Swift.max(0, need - asleep)   // APPROXIMATE fallback
        }
        return (series.last, mean(series), series)
    }

    /// The personal sleep need (minutes): mean asleep, but never below a 7.5h floor so
    /// debt/performance read sensibly even for a chronically short sleeper.
    private var sleepNeedMin: Double {
        Swift.max(450, typicalTotalMin ?? 450)   // 450 min = 7.5h
    }

    // MARK: - Trend points

    /// Trailing 30 days of total sleep, plotted in HOURS. Falls back to all nights with
    /// data if the trailing window is too sparse.
    private var durationTrendPoints: [TrendPoint] {
        let fmt = SleepView.dayParser
        func build(_ slice: ArraySlice<DailyMetric>) -> [TrendPoint] {
            slice.compactMap { d -> TrendPoint? in
                guard let mins = d.totalSleepMin, mins > 0,
                      let date = fmt.date(from: d.day) else { return nil }
                return TrendPoint(date: date, value: mins / 60.0)
            }
        }
        let recent = build(repo.days.suffix(30))
        if recent.count >= 2 { return recent }
        return build(repo.days[...])
    }

    private func trendRange(_ pts: [TrendPoint]) -> ClosedRange<Double> {
        let vals = pts.map(\.value)
        let lo = Swift.max(0, (vals.min() ?? 0) - 1)
        let hi = (vals.max() ?? 9) + 1
        return lo...Swift.max(hi, lo + 1)
    }

    // MARK: - Empty / sparse states

    @ViewBuilder
    private var emptyState: some View {
        // While the strap is mid-offload, say so — "No nights" reads as final otherwise (#77).
        if live.backfilling { SyncingHistoryNote(chunks: live.syncChunksThisSession) }
        if repo.loaded {
            ComingSoon(what: "No nights here yet. Import your WHOOP export in Data Sources to see every night, your sleep stages and trends straight away. Or open Intelligence to see last night computed from the strap after you wear it to bed.")
        } else {
            ComingSoon(what: "Loading your sleep history…")
        }
    }

    private var sparsePlaceholder: some View {
        Text("Not enough nights yet.")
            .font(StrandFont.subhead)
            .foregroundStyle(StrandPalette.textTertiary)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            .background(StrandPalette.surfaceInset, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    /// Hero chart slot for a NAVIGATED session with no decodable stages — honest about the
    /// gap instead of rendering the latest night under a navigated label. (#160)
    private var noStagePlaceholder: some View {
        Text("No stage data recorded for this night.")
            .font(StrandFont.footnote)
            .foregroundStyle(StrandPalette.textTertiary)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            .background(StrandPalette.surfaceInset, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    // MARK: - Formatting helpers

    private func pct(_ minutes: Double, _ total: Double) -> Int {
        total > 0 ? Int((minutes / total * 100).rounded()) : 0
    }

    private func pctValue(_ v: Double?) -> String {
        v.map { "\(Int($0.rounded()))%" } ?? "—"
    }

    private func rrValue(_ v: Double?) -> String {
        v.map { String(format: "%.1f", $0) } ?? "—"
    }

    /// "+12% vs typical" / "−0.4 rpm vs typical" — the latest-vs-mean caption every tile carries.
    private func vsTypical(_ latest: Double?, _ typical: Double?, suffix: String, decimals: Int = 0) -> String {
        guard let latest, let typical, typical != 0 else { return "vs typical —" }
        let diff = latest - typical
        let sign = diff >= 0 ? "+" : "−"
        let mag = abs(diff)
        let num = decimals == 0 ? "\(Int(mag.rounded()))" : String(format: "%.\(decimals)f", mag)
        return "\(sign)\(num)\(suffix) vs typical"
    }

    private func debtCaption(_ debt: Double?) -> String {
        guard let debt else { return "vs need" }
        return debt < 15 ? "On target" : "Below need"
    }

    private func debtColor(_ debt: Double?) -> Color {
        guard let debt else { return StrandPalette.textPrimary }
        switch debt {
        case ..<15:  return StrandPalette.statusPositive
        case ..<60:  return StrandPalette.statusWarning
        default:     return StrandPalette.statusCritical
        }
    }

    // MARK: - Sleep-debt ledger formatting

    /// "≈2h 10m" magnitude headline — leading "≈" because it's an accumulated estimate.
    /// Reads "On target" inside the deadband so a few stray minutes don't show as debt.
    private func debtHeadline(_ ledger: SleepDebtLedger) -> String {
        if ledger.magnitudeMin < SleepDebt.onTargetBandMin { return "On target" }
        return "≈\(durationText(ledger.magnitudeMin))"
    }

    /// Short tag under/beside the headline: DEBT / SURPLUS / ON TARGET.
    private func debtTag(_ ledger: SleepDebtLedger) -> String {
        if ledger.magnitudeMin < SleepDebt.onTargetBandMin { return "balanced" }
        return ledger.isDebt ? "sleep debt" : "surplus"
    }

    /// Plain-English read of the running balance over the window.
    private func debtRead(_ ledger: SleepDebtLedger) -> String {
        let nights = ledger.nightCount
        let span = "the last \(nights) night\(nights == 1 ? "" : "s")"
        if ledger.magnitudeMin < SleepDebt.onTargetBandMin {
            return "You're roughly on top of your sleep across \(span) — slept minutes balance out against your need."
        }
        let mag = durationText(ledger.magnitudeMin)
        if ledger.isDebt {
            return "You've banked about \(mag) of sleep debt over \(span). Surplus nights count back against it — an earlier night or two would clear it."
        }
        return "You're carrying about \(mag) of surplus over \(span) — you've slept past your need on balance. Nicely ahead."
    }

    /// Color the balance by sign + size: surplus/within-band → positive green, modest
    /// debt → warning, heavier debt → critical.
    private func debtBalanceColor(_ ledger: SleepDebtLedger) -> Color {
        if ledger.magnitudeMin < SleepDebt.onTargetBandMin || !ledger.isDebt {
            return StrandPalette.statusPositive
        }
        // A debt: amber up to ~3 h accumulated, red beyond.
        return ledger.magnitudeMin < 180 ? StrandPalette.statusWarning : StrandPalette.statusCritical
    }

    /// Signed "+1h 20m" / "−2h 10m" / "0m" balance string.
    private func debtSigned(_ minutes: Double) -> String {
        if abs(minutes) < 1 { return "0m" }
        let sign = minutes >= 0 ? "+" : "−"
        return "\(sign)\(durationText(abs(minutes)))"
    }

    private func efficiencyText(_ night: Night) -> String {
        let e = efficiencyPct(night)
        return e.map { "\(Int($0.rounded()))%" } ?? "—"
    }

    /// Efficiency in percent. Prefer the stored session value, else asleep / time-in-bed.
    private func efficiencyPct(_ night: Night) -> Double? {
        if let stored = night.session.efficiency ?? repo.today?.efficiency {
            return stored <= 1.0 ? stored * 100 : stored
        }
        let bed = night.timeInBed
        guard bed > 0 else { return nil }
        return Swift.min(100, night.stages.asleep / bed * 100)
    }

    private func durationText(_ minutes: Double) -> String {
        let m = Swift.max(0, Int(minutes.rounded()))
        if m < 60 { return "\(m)m" }
        return "\(m / 60)h \(m % 60)m"
    }

    /// A sparkline needs at least two points; otherwise return nil so the tile stays clean.
    private func spark(_ series: [Double]) -> [Double]? {
        let tail = Array(series.suffix(30))
        return tail.count > 1 ? tail : nil
    }

    private func mean(_ vals: [Double]) -> Double? {
        guard !vals.isEmpty else { return nil }
        return vals.reduce(0, +) / Double(vals.count)
    }

    // MARK: - Stage decoding

    /// Decode the imported stagesJSON dict of MINUTES {"light","deep","rem","awake"}.
    private func decodeStages(_ json: String?) -> Stages? {
        guard let json, let data = json.data(using: .utf8) else { return nil }
        guard let obj = try? JSONSerialization.jsonObject(with: data),
              let dict = obj as? [String: Any] else { return nil }
        func val(_ key: String) -> Double {
            if let n = dict[key] as? NSNumber { return n.doubleValue }
            if let d = dict[key] as? Double { return d }
            if let i = dict[key] as? Int { return Double(i) }
            return 0
        }
        let s = Stages(awake: val("awake"), light: val("light"),
                       deep: val("deep"), rem: val("rem"))
        return s.total > 0 ? s : nil
    }

    /// Decode the COMPUTED stagesJSON segment array [{"start":epoch,"end":epoch,"stage":"wake"|
    /// "light"|"deep"|"rem"}] into stage totals plus the real timeline (seconds relative to the
    /// session start, the Hypnogram's domain). The on-device SleepStager calls awake "wake". (#77)
    private func decodeSegments(
        _ json: String?, sessionStart: Int
    ) -> (stages: Stages, intervals: [SleepInterval])? {
        guard let json, let data = json.data(using: .utf8),
              let arr = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]],
              !arr.isEmpty else { return nil }
        var stages = Stages(awake: 0, light: 0, deep: 0, rem: 0)
        var intervals: [SleepInterval] = []
        for seg in arr {
            guard let start = (seg["start"] as? NSNumber)?.intValue,
                  let end = (seg["end"] as? NSNumber)?.intValue, end > start,
                  let name = seg["stage"] as? String else { continue }
            let minutes = Double(end - start) / 60.0
            let stage: SleepStage
            switch name {
            case "wake", "awake": stage = .awake; stages.awake += minutes
            case "light": stage = .light; stages.light += minutes
            case "deep": stage = .deep; stages.deep += minutes
            case "rem": stage = .rem; stages.rem += minutes
            default: continue
            }
            intervals.append(SleepInterval(
                stage: stage,
                start: TimeInterval(start - sessionStart),
                end: TimeInterval(end - sessionStart)))
        }
        return stages.total > 0 ? (stages, intervals) : nil
    }

    /// yyyy-MM-dd → Date (en_US_POSIX, UTC), per task spec.
    private static let dayParser: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()
}

// MARK: - Local value types

/// Cheap, Equatable fingerprint of the repo inputs SleepView derives from. Two snapshots are
/// equal iff the data the screen reads is unchanged, so the heavy `SleepModel` rebuild is
/// skipped on the many `body` re-evaluations that don't touch sleep data.
private struct SleepInputKey: Equatable {
    let loaded: Bool
    let daysCount: Int
    let sleepsCount: Int
    let firstDay: String?
    let lastDay: String?
    /// Newest day row (Equatable) — catches in-place edits to the latest day's values.
    let lastDayUpdated: DailyMetric?
    /// Newest sleep session (Equatable) — catches a re-import of the latest night.
    let lastSleep: CachedSleepSession?
    /// Bumped on every Repository.refresh — catches a re-import that changes only the
    /// imported metricSeries figures (importedSleep) without touching days/sleeps.
    let refreshSeq: Int
}

/// Memoized result of every expensive SleepView derivation. Built once per data change in
/// `buildModel()` and read by the subviews, so full passes over repo.days / repo.sleeps and
/// the Night.intervals reconstruction no longer run on every render.
private struct SleepModel {
    /// (latest, typical mean, full history) per metric — mirrors SleepView.Metric.
    typealias Metric = (latest: Double?, typical: Double?, series: [Double])

    let night: Night
    /// Stage intervals for the hypnogram — computed once (Night.intervals is a computed
    /// property; it was previously re-derived on each access during render).
    let intervals: [SleepInterval]
    /// True when `intervals` are the stager's persisted per-epoch segments (on-device
    /// APPROXIMATE staging), not the synthesized architecture.
    let isPersistedHypnogram: Bool

    let performance: Metric
    let efficiency: Metric
    let consistency: Metric
    let hoursVsNeeded: Metric
    let restorative: Metric
    let respiratory: Metric
    let sleepDebt: Metric

    let typicalTotalMin: Double?
    let typicalDeepMin: Double?
    let typicalRemMin: Double?
    let typicalLightMin: Double?

    let trendPoints: [TrendPoint]

    /// Rolling 14-night sleep-debt ledger: Σ(slept − personal need) across the recent
    /// fortnight, with the per-night deltas behind it. Computed once per data change.
    let sleepDebtLedger: SleepDebtLedger
}

private struct Stages {
    var awake: Double
    var light: Double
    var deep: Double
    var rem: Double
    /// All stages (includes awake) — total time-in-bed minutes.
    var total: Double { awake + light + deep + rem }
    /// Asleep time = total minus awake.
    var asleep: Double { light + deep + rem }
}

private struct Night {
    let session: CachedSleepSession
    let stages: Stages
    /// The REAL per-segment timeline for on-device computed nights (nil for imported nights,
    /// whose export carries totals only — those keep the synthetic reconstruction below). (#77)
    var realSegments: [SleepInterval]? = nil

    /// Total time in bed in minutes (from reconstructed stages).
    var timeInBed: Double { stages.total }

    /// The wall-clock start of the night (for the Hypnogram's clock labels).
    var onsetDate: Date { Date(timeIntervalSince1970: TimeInterval(session.startTs)) }

    /// Stage intervals laid end-to-end across the night, in seconds from start.
    /// On-device computed nights use their REAL timeline; imported nights are reconstructed
    /// from durations only (the export has no per-epoch timeline).
    var intervals: [SleepInterval] {
        if let real = realSegments, real.count >= 2 { return real }
        var t: TimeInterval = 0
        var out: [SleepInterval] = []
        func add(_ stage: SleepStage, _ minutes: Double) {
            guard minutes > 0 else { return }
            let secs = minutes * 60
            out.append(SleepInterval(stage: stage, start: t, end: t + secs))
            t += secs
        }
        // A plausible architecture: deep early, REM later, awake last.
        add(.light, stages.light * 0.4)
        add(.deep, stages.deep)
        add(.light, stages.light * 0.3)
        add(.rem, stages.rem)
        add(.light, stages.light * 0.3)
        add(.awake, stages.awake)
        return out
    }

    var onsetText: String { Night.timeFmt.string(from: Date(timeIntervalSince1970: TimeInterval(session.startTs))) }
    var wakeText: String { Night.timeFmt.string(from: Date(timeIntervalSince1970: TimeInterval(session.endTs))) }
    var dateLabel: String { Night.dateFmt.string(from: Date(timeIntervalSince1970: TimeInterval(session.startTs))) }

    /// Date label that becomes a span when the night crosses midnight (onset on a different
    /// calendar day from wake) — e.g. "Fri 13 → Sat 14 Jun" — otherwise a single date. Lets an
    /// aggregated day that started the previous evening read honestly. (#170)
    var spanLabel: String {
        let onsetDay = Date(timeIntervalSince1970: TimeInterval(session.startTs))
        let wakeDay  = Date(timeIntervalSince1970: TimeInterval(session.endTs))
        let cal = Calendar.current
        if cal.isDate(onsetDay, inSameDayAs: wakeDay) { return Night.dateFmt.string(from: onsetDay) }
        return "\(Night.spanFmt.string(from: onsetDay)) → \(Night.dateFmt.string(from: wakeDay))"
    }

    // 12-hour clock for the Asleep/Woke row (e.g. "11:42 PM") — the times people read at a glance.
    private static let timeFmt: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "h:mm a"; return f
    }()
    private static let dateFmt: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "EEE d MMM"; return f
    }()
    /// Onset side of a cross-midnight span — no month (the wake side carries it): "Fri 13".
    private static let spanFmt: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "EEE d"; return f
    }()
}

// MARK: - Preview

#if DEBUG
#Preview("Sleep") {
    SleepView()
        .environmentObject(Repository.previewSleep())
        .environmentObject(LiveState())
        .frame(width: 980, height: 1180)
        .preferredColorScheme(.dark)
}

@MainActor
private extension Repository {
    /// Sample repository populated with imported-style nights for previews.
    static func previewSleep() -> Repository {
        let repo = Repository(deviceId: "preview")
        let cal = Calendar.current
        let now = Date()

        var days: [DailyMetric] = []
        var sleeps: [CachedSleepSession] = []
        let fmt: DateFormatter = {
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.dateFormat = "yyyy-MM-dd"
            return f
        }()

        for i in (0..<30).reversed() {
            let date = cal.date(byAdding: .day, value: -i, to: now)!
            let jitter = Double((i * 23) % 11) - 5
            let light = 210.0 + jitter
            let deep = 80.0 + jitter * 0.5
            let rem = 95.0 + jitter * 0.7
            let awake = 25.0 + Double((i * 7) % 9)
            let asleep = light + deep + rem
            let stagesJSON = "{\"light\":\(light),\"deep\":\(deep),\"rem\":\(rem),\"awake\":\(awake)}"

            days.append(DailyMetric(
                day: fmt.string(from: date),
                totalSleepMin: asleep,
                efficiency: 88 + jitter * 0.3,
                deepMin: deep, remMin: rem, lightMin: light,
                disturbances: Int(awake / 6), restingHr: 50 + (i % 4),
                avgHrv: 65 - Double(i % 5), recovery: 60 + jitter,
                strain: 10 + Double(i % 6), exerciseCount: i % 2,
                spo2Pct: 96, skinTempDevC: 33.4, respRateBpm: 14.6 + jitter * 0.1))

            var onset = cal.date(bySettingHour: 22, minute: 50 + Int(jitter), second: 0, of: date) ?? date
            onset = cal.date(byAdding: .day, value: -1, to: onset) ?? onset
            let end = onset.addingTimeInterval((asleep + awake) * 60)
            sleeps.append(CachedSleepSession(
                startTs: Int(onset.timeIntervalSince1970),
                endTs: Int(end.timeIntervalSince1970),
                efficiency: 88 + jitter * 0.3,
                restingHr: 50 + (i % 4),
                avgHrv: 65 - Double(i % 5),
                stagesJSON: stagesJSON))
        }

        repo.days = days
        repo.sleeps = sleeps
        repo.loaded = true
        return repo
    }
}
#endif
