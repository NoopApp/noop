package com.noop.ui

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.noop.data.DailyMetric
import com.noop.data.JournalEntry
import kotlinx.coroutines.launch
import java.util.Locale
import kotlin.math.abs
import kotlin.math.roundToInt
import kotlin.math.sqrt

// MARK: - Insights
//
// The "interrogate what affects what" screen, ported from the macOS InsightsView.
// Two halves:
//
//  1. BEHAVIOUR EFFECTS — split logged journal answers (the days each behaviour WAS
//     logged "yes" vs NOT) and compare a chosen outcome metric (Recovery / HRV /
//     Sleep / RHR) between the two groups. Ranked by effect size (Cohen's d), with
//     significant effects first. Each card carries a plain-English sentence, the
//     with/without means, group counts, a significance pill, and the magnitude word.
//     Tint is sign-aware: a behaviour that moves the outcome the "good" way (respecting
//     higherIsBetter) reads positive/green, the "bad" way reads critical/red.
//
//  2. METRIC RELATIONSHIPS — a curated set of Pearson correlations between daily series
//     (HRV ↔ recovery, sleep ↔ recovery, RHR ↔ recovery, recovery → next-day recovery),
//     each rendered as a one-line insight with r and a plain-English reading.
//
// Data note vs macOS: the Swift app computes these via the StrandAnalytics package
// (BehaviorInsights / CorrelationEngine) over a metricSeries store. On Android the
// analytics package isn't ported, and the guaranteed outcome source is the cached
// DailyMetric rows (vm.recentDays). So the outcome series here are read straight off
// those rows (recovery / avgHrv / sleep-efficiency / restingHr) and the simple, honest
// math (group means + Cohen's d, Pearson r) is computed inline below. No fabricated
// values: a behaviour or relationship only appears when there is real overlapping data.

// MARK: - Outcome (segmented selection)

/** One interrogable outcome metric: how to read it off a DailyMetric, its label,
 *  units, and whether higher is the "good" direction (drives sign-aware tint). */
private enum class Outcome(
    val label: String,
    val outcomeName: String,
    val higherIsBetter: Boolean,
    val pick: (DailyMetric) -> Double?,
    val format: (Double) -> String,
) {
    Recovery(
        label = "Recovery", outcomeName = "Recovery", higherIsBetter = true,
        pick = { it.recovery }, format = { "${it.roundToInt()}%" },
    ),
    Hrv(
        label = "HRV", outcomeName = "HRV", higherIsBetter = true,
        pick = { it.avgHrv }, format = { "${it.roundToInt()} ms" },
    ),
    Sleep(
        label = "Sleep", outcomeName = "Sleep efficiency", higherIsBetter = true,
        pick = { it.efficiency }, format = { "${it.roundToInt()}%" },
    ),
    Rhr(
        label = "RHR", outcomeName = "Resting HR", higherIsBetter = false,
        pick = { it.restingHr?.toDouble() }, format = { "${it.roundToInt()} bpm" },
    ),
}

// MARK: - Computed shapes (plain data, no analytics package dependency)

/** One behaviour's effect on the selected outcome: with/without means, counts,
 *  Cohen's d and a crude significance flag. */
private data class BehaviorEffect(
    val behavior: String,
    val meanWith: Double,
    val meanWithout: Double,
    val nWith: Int,
    val nWithout: Int,
    val cohensD: Double,
) {
    val delta: Double get() = meanWith - meanWithout
    /** Crude significance: a non-trivial effect with enough days on both sides.
     *  Honest stand-in for a t-test — |d| ≥ 0.5 ("moderate") with ≥3 days each side. */
    val significant: Boolean get() = abs(cohensD) >= 0.5 && nWith >= 3 && nWithout >= 3
}

/** A curated metric relationship plus its computed Pearson correlation. */
private data class Relationship(
    val id: String,
    val title: String,
    val blurb: String,
    val r: Double,
    val n: Int,
) {
    /** Crude significance flag for |r| with n pairs (rough p < 0.05 threshold). */
    val significant: Boolean get() = n >= 4 && abs(r) >= significanceThreshold(n)
}

/** The fully-computed insight inputs for the current data, recomputed off recentDays. */
private data class InsightModel(
    /** behaviour question → set of days it was answered "yes". */
    val behaviours: Map<String, Set<String>>,
    /** day → value, per outcome. */
    val outcomeByDay: Map<Outcome, Map<String, Double>>,
    /** ordered (day, value) per outcome for correlations. */
    val seriesByOutcome: Map<Outcome, List<Pair<String, Double>>>,
)

// MARK: - Screen

/**
 * Insights — behaviour effects + metric relationships over cached history.
 *
 * Loads the journal (all days) and the per-day outcome series from `vm.recentDays`,
 * then presents the ranked behaviour effects for the selected outcome and the curated
 * Pearson relationships. Empty/sparse states explain what's missing rather than faking
 * numbers, matching the macOS data-display contract.
 */
@Composable
fun InsightsScreen(vm: AppViewModel) {
    val days by vm.recentDays.collectAsStateWithLifecycle()

    // Journal answers (all history): imported "my-whoop" rows UNIONED with native "noop-journal"
    // rows (native wins per (day, question)). Keyed on journalSeq so the logging card's saves and
    // clears refresh the effects immediately; re-loaded too when the cached days change underneath.
    var behaviours by remember { mutableStateOf<Map<String, Set<String>>>(emptyMap()) }
    var journalLoaded by remember { mutableStateOf(false) }
    var journalSeq by remember { mutableStateOf(0) }
    var dayOffset by remember { mutableStateOf(0L) }
    var importedQuestions by remember { mutableStateOf<List<String>>(emptyList()) }
    var dayAnswers by remember { mutableStateOf<Map<String, Boolean>>(emptyMap()) }
    val ctx = androidx.compose.ui.platform.LocalContext.current
    val scope = androidx.compose.runtime.rememberCoroutineScope()
    var customQuestions by remember { mutableStateOf(loadCustomJournalQuestions(ctx)) }

    androidx.compose.runtime.LaunchedEffect(journalSeq, dayOffset) {
        val imported = vm.repo.journal("my-whoop", "0000-01-01", "9999-12-31")
        val native = vm.repo.journal(JOURNAL_DEVICE_ID, "0000-01-01", "9999-12-31")
        val entries = mergeJournalEntries(imported, native)
        val byBehaviour = mutableMapOf<String, MutableSet<String>>()
        for (e in entries) if (e.answeredYes) {
            byBehaviour.getOrPut(e.question) { mutableSetOf() }.add(e.day)
        }
        behaviours = byBehaviour.mapValues { it.value.toSet() }
        importedQuestions = imported.map { it.question }.distinct()
        val key = journalDayKey(dayOffset)
        dayAnswers = native.filter { it.day == key }.associate { it.question to it.answeredYes }
        journalLoaded = true
    }

    // Selected outcome metric for the behaviour-effects half.
    var outcome by remember { mutableStateOf(Outcome.Recovery) }

    // Build outcome day-maps + ordered series off the cached daily metrics. Cheap and
    // recomputed only when `days` changes (not on every recomposition).
    val model = remember(days, behaviours) { buildModel(days, behaviours) }

    // Ranked behaviour effects for the current outcome (recomputed when outcome/data change).
    val ranked = remember(model, outcome) { rankEffects(model, outcome) }
    // Curated relationships (independent of the selected outcome).
    val relationships = remember(model) { computeRelationships(model) }

    ScreenScaffold(title = "Insights", subtitle = "Interrogate what affects what.") {

        // --- Native journal logging (always reachable — the account-free way in) ---
        JournalLogCard(
            catalog = mergeJournalCatalog(importedQuestions, customQuestions),
            answers = dayAnswers,
            dayOffset = dayOffset,
            onDayOffset = { dayOffset = it },
            onAnswer = { q, yes ->
                scope.launch {
                    vm.repo.upsertJournal(
                        listOf(JournalEntry(JOURNAL_DEVICE_ID, journalDayKey(dayOffset), q, yes)),
                    )
                    journalSeq++
                }
            },
            onClear = { q ->
                scope.launch {
                    vm.repo.deleteJournalEntry(JOURNAL_DEVICE_ID, journalDayKey(dayOffset), q)
                    journalSeq++
                }
            },
            onAddCustom = { q ->
                val next = customQuestions + q
                saveCustomJournalQuestions(ctx, next)
                customQuestions = next
            },
        )

        Spacer(Modifier.height(Metrics.sectionGap - 20.dp))

        // --- Behaviour effects -------------------------------------------------
        if (!journalLoaded) {
            NoopCard {
                Text(
                    "Reading your journal and outcomes…",
                    style = NoopType.subhead,
                    color = Palette.textTertiary,
                )
            }
        } else if (behaviours.isEmpty()) {
            // No journal yet — explain, without dead-ending on a paid export.
            DataPendingNote(
                title = "Insights read your journal and outcomes",
                body = "Log behaviours above — after a few days of answers, NOOP ranks how each " +
                    "one moves your recovery, HRV and sleep. Importing a WHOOP export (which " +
                    "includes its journal) backfills history instantly.",
            )
        } else {
            BehaviourSection(
                outcome = outcome,
                onOutcome = { outcome = it },
                ranked = ranked,
            )
        }

        Spacer(Modifier.height(Metrics.sectionGap - 20.dp))

        // --- Metric relationships ---------------------------------------------
        RelationshipsSection(relationships)
    }
}

// MARK: - Behaviour effects section

@Composable
private fun BehaviourSection(
    outcome: Outcome,
    onOutcome: (Outcome) -> Unit,
    ranked: List<BehaviorEffect>,
) {
    Column(verticalArrangement = Arrangement.spacedBy(Metrics.gap)) {
        Row(
            modifier = Modifier.fillMaxWidth(),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Box(modifier = Modifier.weight(1f)) {
                SectionHeader(
                    "Behaviour Effects",
                    overline = "What moves your ${outcome.outcomeName.lowercase(Locale.US)}",
                )
            }
            SegmentedPillControl(
                items = Outcome.entries.toList(),
                selection = outcome,
                label = { it.label },
                onSelect = onOutcome,
            )
        }

        if (ranked.isEmpty()) {
            NoopCard {
                Text(
                    "Not enough overlap between your journal answers and " +
                        "${outcome.outcomeName.lowercase(Locale.US)} to measure an effect yet. " +
                        "Keep logging — effects need days both with and without each behaviour.",
                    style = NoopType.subhead,
                    color = Palette.textTertiary,
                )
            }
        } else {
            ranked.forEach { EffectCard(it, outcome) }
        }
    }
}

/** One behaviour-effect card: sentence + with/without StatTiles + significance pill. */
@Composable
private fun EffectCard(e: BehaviorEffect, outcome: Outcome) {
    // Sign-aware tint: did this behaviour move the outcome the GOOD way?
    val movedGood: Boolean? = when {
        e.delta == 0.0 -> null
        else -> (e.delta > 0) == outcome.higherIsBetter
    }
    val tone: StrandTone = when (movedGood) {
        null -> StrandTone.Neutral
        true -> StrandTone.Positive
        false -> if (e.significant) StrandTone.Critical else StrandTone.Warning
    }
    val tintColor = tone.color
    val arrow = if (e.delta > 0) "↑" else if (e.delta < 0) "↓" else "→"
    val deltaText = "$arrow ${String.format(Locale.US, "%.1f", abs(e.delta))}"
    val sentence = effectSentence(e, outcome)

    NoopCard {
        Column(verticalArrangement = Arrangement.spacedBy(Metrics.gap)) {

            // Header: behaviour name (tinted dot) + significance pill.
            Row(
                modifier = Modifier.fillMaxWidth(),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Row(
                    modifier = Modifier.weight(1f),
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(8.dp),
                ) {
                    Box(
                        modifier = Modifier
                            .size(8.dp)
                            .clip(CircleShape)
                            .drawBehind { drawCircle(tintColor) },
                    )
                    Text(
                        e.behavior,
                        style = NoopType.headline,
                        color = Palette.textPrimary,
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis,
                    )
                }
                StatePill(
                    if (e.significant) "SIGNIFICANT" else "EXPLORATORY",
                    tone = if (e.significant) StrandTone.Positive else StrandTone.Neutral,
                    showsDot = false,
                )
            }

            // Plain-English sentence.
            Text(sentence, style = NoopType.body, color = Palette.textSecondary)

            // With / without means as uniform StatTiles.
            Row(horizontalArrangement = Arrangement.spacedBy(Metrics.gap)) {
                StatTile(
                    modifier = Modifier.weight(1f),
                    label = "With",
                    value = outcome.format(e.meanWith),
                    caption = "n = ${e.nWith}",
                    accent = tintColor,
                    delta = deltaText,
                    deltaColor = tintColor,
                )
                StatTile(
                    modifier = Modifier.weight(1f),
                    label = "Without",
                    value = outcome.format(e.meanWithout),
                    caption = "n = ${e.nWithout}",
                    accent = Palette.textPrimary,
                )
            }

            HorizontalDivider(color = Palette.hairline)

            // Effect-size footer: Cohen's d + magnitude word.
            Row(
                modifier = Modifier.fillMaxWidth(),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Overline("Effect size", modifier = Modifier.weight(1f))
                Text(
                    String.format(Locale.US, "d = %.2f", e.cohensD),
                    style = NoopType.captionNumber,
                    color = tintColor,
                )
                Spacer(Modifier.width(6.dp))
                Text(
                    effectMagnitudeWord(e.cohensD),
                    style = NoopType.caption,
                    color = Palette.textTertiary,
                )
            }
        }
    }
}

// MARK: - Metric relationships section

@Composable
private fun RelationshipsSection(rels: List<Relationship>) {
    Column(verticalArrangement = Arrangement.spacedBy(Metrics.gap)) {
        SectionHeader("Metric Relationships", overline = "Pearson r")

        if (rels.isEmpty()) {
            NoopCard {
                Text(
                    "Not enough overlapping history to correlate your metrics yet.",
                    style = NoopType.subhead,
                    color = Palette.textTertiary,
                )
            }
        } else {
            NoopCard {
                Column {
                    rels.forEachIndexed { idx, rel ->
                        RelationshipRow(rel)
                        if (idx < rels.size - 1) {
                            HorizontalDivider(color = Palette.hairline)
                        }
                    }
                }
            }
        }
    }
}

@Composable
private fun RelationshipRow(rel: Relationship) {
    val strength = correlationColor(rel.r)
    val sentence = relationshipSentence(rel)

    Column(
        modifier = Modifier
            .fillMaxWidth()
            .padding(vertical = 11.dp)
            .clearAndSetSemantics { contentDescription = sentence },
        verticalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        Row(
            modifier = Modifier.fillMaxWidth(),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            Text(
                rel.title,
                style = NoopType.headline,
                color = Palette.textPrimary,
                modifier = Modifier.weight(1f),
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
            Text(
                String.format(Locale.US, "r = %+.2f", rel.r),
                style = NoopType.number(16f),
                color = strength,
            )
            StatePill(
                if (rel.significant) "p < 0.05" else "n.s.",
                tone = if (rel.significant) StrandTone.Accent else StrandTone.Neutral,
                showsDot = false,
            )
        }

        // r bar — centred zero, fills left (negative) / right (positive) by |r|.
        RBar(r = rel.r, color = strength)

        Text(sentence, style = NoopType.subhead, color = Palette.textSecondary)
        Text(rel.blurb, style = NoopType.footnote, color = Palette.textTertiary)
    }
}

/**
 * A centred correlation bar: a faint inset track with a centre tick at zero, and a
 * coloured fill that grows left (negative r) or right (positive r) proportional to |r|.
 * Mirrors the macOS RBar (minus the desktop hover tooltip — the exact r value is already
 * printed beside the title, so the bar is never an unexplained coloured shape on phone).
 */
@Composable
private fun RBar(r: Double, color: Color) {
    Box(
        modifier = Modifier
            .fillMaxWidth()
            .height(8.dp)
            .clip(CircleShape)
            .drawBehind {
                val half = size.width / 2f
                val mag = (abs(r).coerceAtMost(1.0)).toFloat() * half
                // Inset track.
                drawLine(
                    color = Palette.surfaceInset,
                    start = Offset(size.height / 2f, size.height / 2f),
                    end = Offset(size.width - size.height / 2f, size.height / 2f),
                    strokeWidth = size.height,
                    cap = StrokeCap.Round,
                )
                // Centre tick.
                drawLine(
                    color = Palette.hairlineStrong,
                    start = Offset(half, 0f),
                    end = Offset(half, size.height),
                    strokeWidth = 1f,
                )
                // Value fill from centre outward.
                if (mag > 0f) {
                    val start = if (r >= 0) Offset(half, size.height / 2f)
                    else Offset(half - mag, size.height / 2f)
                    val end = if (r >= 0) Offset(half + mag, size.height / 2f)
                    else Offset(half, size.height / 2f)
                    drawLine(
                        color = color,
                        start = start,
                        end = end,
                        strokeWidth = size.height,
                        cap = StrokeCap.Round,
                    )
                }
            },
    )
}

// MARK: - Model building + math (simple, honest, no external analytics)

/** Build the per-outcome day maps + ordered series from cached daily metrics. */
private fun buildModel(
    days: List<DailyMetric>,
    behaviours: Map<String, Set<String>>,
): InsightModel {
    val outcomeByDay = mutableMapOf<Outcome, Map<String, Double>>()
    val seriesByOutcome = mutableMapOf<Outcome, List<Pair<String, Double>>>()
    for (o in Outcome.entries) {
        // Oldest → newest; one value per day (DailyMetric PK is (deviceId, day)).
        val series = days.mapNotNull { d -> o.pick(d)?.let { d.day to it } }
        seriesByOutcome[o] = series
        outcomeByDay[o] = series.toMap()
    }
    return InsightModel(behaviours, outcomeByDay, seriesByOutcome)
}

/** Rank behaviour effects for one outcome by |Cohen's d|, significant first. */
private fun rankEffects(model: InsightModel, outcome: Outcome): List<BehaviorEffect> {
    val outcomeDays = model.outcomeByDay[outcome] ?: emptyMap()
    if (outcomeDays.isEmpty()) return emptyList()

    val effects = model.behaviours.mapNotNull { (behaviour, yesDays) ->
        val with = mutableListOf<Double>()
        val without = mutableListOf<Double>()
        for ((day, value) in outcomeDays) {
            if (day in yesDays) with.add(value) else without.add(value)
        }
        // Need both groups to compare; require ≥2 each so a mean/SD is meaningful.
        if (with.size < 2 || without.size < 2) return@mapNotNull null
        BehaviorEffect(
            behavior = behaviour,
            meanWith = with.average(),
            meanWithout = without.average(),
            nWith = with.size,
            nWithout = without.size,
            cohensD = cohensD(with, without),
        )
    }
    return effects.sortedWith(
        compareByDescending<BehaviorEffect> { it.significant }
            .thenByDescending { abs(it.cohensD) },
    )
}

/** The curated metric relationships, computed via Pearson r over aligned day pairs. */
private fun computeRelationships(model: InsightModel): List<Relationship> {
    fun series(o: Outcome) = model.seriesByOutcome[o] ?: emptyList()
    val out = mutableListOf<Relationship>()

    pearsonAligned(series(Outcome.Hrv), series(Outcome.Recovery))?.let { (r, n) ->
        out.add(
            Relationship(
                "hrv-rec", "HRV ↔ Recovery",
                "Heart-rate variability as the engine behind your recovery score.", r, n,
            ),
        )
    }
    pearsonAligned(series(Outcome.Sleep), series(Outcome.Recovery))?.let { (r, n) ->
        out.add(
            Relationship(
                "sleep-rec", "Sleep ↔ Recovery",
                "How closely a high-efficiency night tracks next-morning recovery.", r, n,
            ),
        )
    }
    pearsonAligned(series(Outcome.Rhr), series(Outcome.Recovery))?.let { (r, n) ->
        out.add(
            Relationship(
                "rhr-rec", "Resting HR ↔ Recovery",
                "A lower resting heart rate usually means a higher recovery.", r, n,
            ),
        )
    }
    pearsonLagged(series(Outcome.Recovery), lagDays = 1)?.let { (r, n) ->
        out.add(
            Relationship(
                "rec-lag", "Recovery → Next-day recovery",
                "How much one day's recovery carries into the next.", r, n,
            ),
        )
    }

    return out
}

// MARK: - Statistics (pooled-SD Cohen's d, Pearson r)

/** Cohen's d using pooled standard deviation. 0 when either side lacks spread. */
private fun cohensD(a: List<Double>, b: List<Double>): Double {
    if (a.size < 2 || b.size < 2) return 0.0
    val ma = a.average()
    val mb = b.average()
    val va = variance(a, ma)
    val vb = variance(b, mb)
    val pooled = sqrt(((a.size - 1) * va + (b.size - 1) * vb) / (a.size + b.size - 2).toDouble())
    if (pooled <= 0.0 || !pooled.isFinite()) return 0.0
    return (ma - mb) / pooled
}

/** Sample variance (n-1 denominator) about a known mean. */
private fun variance(xs: List<Double>, mean: Double): Double {
    if (xs.size < 2) return 0.0
    val ss = xs.sumOf { val d = it - mean; d * d }
    return ss / (xs.size - 1).toDouble()
}

/** Pearson r over two (day,value) series aligned on shared days. Returns (r, n) or
 *  null if fewer than 3 overlapping pairs or no variance. */
private fun pearsonAligned(
    xs: List<Pair<String, Double>>,
    ys: List<Pair<String, Double>>,
): Pair<Double, Int>? {
    val ym = ys.toMap()
    val pairs = xs.mapNotNull { (day, x) -> ym[day]?.let { x to it } }
    return pearson(pairs)
}

/** Pearson r of a series against itself shifted forward by [lagDays] days.
 *  Uses index offset on the ordered series (days are oldest → newest). */
private fun pearsonLagged(series: List<Pair<String, Double>>, lagDays: Int): Pair<Double, Int>? {
    if (series.size <= lagDays) return null
    val pairs = (0 until series.size - lagDays).map { i ->
        series[i].second to series[i + lagDays].second
    }
    return pearson(pairs)
}

/** Pearson correlation of paired samples. Null with <3 pairs or no variance. */
private fun pearson(pairs: List<Pair<Double, Double>>): Pair<Double, Int>? {
    val n = pairs.size
    if (n < 3) return null
    val mx = pairs.sumOf { it.first } / n
    val my = pairs.sumOf { it.second } / n
    var sxy = 0.0
    var sxx = 0.0
    var syy = 0.0
    for ((x, y) in pairs) {
        val dx = x - mx
        val dy = y - my
        sxy += dx * dy
        sxx += dx * dx
        syy += dy * dy
    }
    val denom = sqrt(sxx * syy)
    if (denom <= 0.0 || !denom.isFinite()) return null
    return (sxy / denom).coerceIn(-1.0, 1.0) to n
}

/** Rough |r| threshold for "p < 0.05" at n pairs (critical r for a two-tailed test,
 *  approximated by 2 / sqrt(n) — a standard rule-of-thumb). Honest, not exact. */
private fun significanceThreshold(n: Int): Double =
    if (n < 4) 1.1 else (2.0 / sqrt(n.toDouble())).coerceAtMost(1.0)

// MARK: - Text + colour helpers

private fun effectSentence(e: BehaviorEffect, outcome: Outcome): String {
    val dir = when {
        e.delta > 0 -> "higher"
        e.delta < 0 -> "lower"
        else -> "no different"
    }
    val name = outcome.outcomeName.lowercase(Locale.US)
    if (e.delta == 0.0) {
        return "On days you logged ${e.behavior.lowercase(Locale.US)}, your $name was no different."
    }
    val withStr = outcome.format(e.meanWith)
    val withoutStr = outcome.format(e.meanWithout)
    return "On days you logged ${e.behavior.lowercase(Locale.US)}, your $name averaged " +
        "$withStr — $dir than the $withoutStr on days you didn't."
}

private fun effectMagnitudeWord(d: Double): String {
    val m = abs(d)
    return when {
        m < 0.2 -> "negligible"
        m < 0.5 -> "small"
        m < 0.8 -> "moderate"
        else -> "large"
    }
}

private fun strengthWord(r: Double): String {
    val m = abs(r)
    return when {
        m < 0.1 -> "No"
        m < 0.3 -> "A weak"
        m < 0.5 -> "A moderate"
        m < 0.7 -> "A strong"
        else -> "A very strong"
    }
}

private fun relationshipSentence(rel: Relationship): String {
    val dir = if (rel.r > 0) "positive" else if (rel.r < 0) "negative" else "flat"
    return "${strengthWord(rel.r)} $dir relationship " +
        "(r = ${String.format(Locale.US, "%.2f", rel.r)}, n = ${rel.n})."
}

/** Tint a correlation by strength, keyed on the recovery gradient so strong positive
 *  reads mint and strong negative reads red. Maps r∈[-1,1] → 0…1 of the scale. */
private fun correlationColor(r: Double): Color =
    Palette.sample(Palette.recoveryStops, ((r + 1.0) / 2.0).toFloat())
