package com.noop.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.drawscope.DrawScope
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.noop.data.DailyMetric
import com.noop.data.SleepSession
import org.json.JSONArray
import org.json.JSONObject
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import java.util.TimeZone
import kotlin.math.abs
import kotlin.math.max
import kotlin.math.roundToInt

/**
 * Sleep — Whoop-sleep clarity on the locked Noop component system. Mirrors the macOS
 * SleepView (Strand/Screens/SleepView.swift) section-for-section:
 *
 *   1. HERO "Last night" — the stage breakdown. A Hypnogram when stage minutes are
 *      present (deep / rem / light / awake reconstructed end-to-end), with a footer
 *      of REM / Deep / Light / Awake each "Xh Ym · NN%".
 *   2. A uniform grid of fixed StatTiles, each with a sparkline + "vs typical" caption:
 *      Sleep Performance, Efficiency, Consistency, Hours vs Needed, Restorative,
 *      Respiratory, Sleep Debt.
 *   3. "Stages vs typical" — Deep / REM / Light horizontal bars showing last-night
 *      minutes with a marker at the personal typical (mean).
 *   4. A 14-day asleep-hours trend LineChart.
 *
 * Data wiring is faithful to the macOS screen: the "typical" is the mean across the
 * cached daily metrics; the per-night stage split comes from the latest DailyMetric's
 * deep/rem/light minutes. The macOS export carried a per-night stagesJSON minutes dict;
 * Android's sleepSession.stagesJSON is a verbatim segments array used here only for the
 * onset/wake clock labels + efficiency. Where macOS reconstructed an epoch-level
 * timeline it had none either (durations only), so the hypnogram is the same plausible
 * architecture (deep early, REM later, awake last). No data is fabricated: with no
 * nights the screen shows an honest empty state.
 */
@Composable
fun SleepScreen(vm: AppViewModel) {
    val days by vm.recentDays.collectAsStateWithLifecycle()
    val live by vm.live.collectAsStateWithLifecycle()

    // The latest sleep session (for onset/wake clock + stored efficiency). Loaded once
    // from the repo; the my-whoop daily metrics drive everything else and arrive via the
    // shared recentDays flow.
    var session by remember { mutableStateOf<SleepSession?>(null) }
    LaunchedEffect(Unit) {
        val now = System.currentTimeMillis() / 1000L
        val from = now - 60L * 24L * 60L * 60L // 60-day lookback
        session = runCatching {
            // Merged: imported WHOOP sessions win per night; on-device computed
            // ("my-whoop-noop") sessions gap-fill so strap-only nights still show a clock.
            vm.repo.sleepSessionsMerged("my-whoop", from, now).maxByOrNull { it.startTs }
        }.getOrNull()
    }

    val model = remember(days, session) { buildSleepModel(days, session) }

    ScreenScaffold(title = "Sleep", subtitle = "Last night, read in two seconds.") {
        if (model == null) {
            // While the strap is mid-offload, say so — "No nights" reads as final otherwise (#77).
            if (live.backfilling) SyncingHistoryNote(chunks = live.syncChunksThisSession)
            SleepEmptyState()
        } else {
            Hero(model)
            Spacer(Modifier.height(Metrics.sectionGap - 20.dp))
            MetricGrid(model)
            Spacer(Modifier.height(Metrics.sectionGap - 20.dp))
            StagesVsTypical(model)
            Spacer(Modifier.height(Metrics.sectionGap - 20.dp))
            DurationTrend(model)
        }
    }
}

// MARK: - 1. HERO — stage breakdown

@Composable
private fun Hero(m: SleepModel) {
    val s = m.stages
    Column(verticalArrangement = Arrangement.spacedBy(Metrics.gap)) {
        SectionHeader(
            "Last night",
            overline = "Sleep",
            trailing = m.clockLabel,
        )
        ChartCard(
            title = "Stage breakdown",
            subtitle = "${durationText(s.total)} in bed · ${m.efficiencyText} efficiency",
            trailing = durationText(s.asleep),
            footer = {
                ChartFooter(
                    listOf(
                        "REM" to "${durationText(s.rem)} · ${pct(s.rem, s.total)}%",
                        "Deep" to "${durationText(s.deep)} · ${pct(s.deep, s.total)}%",
                        "Light" to "${durationText(s.light)} · ${pct(s.light, s.total)}%",
                        "Awake" to "${durationText(s.awake)} · ${pct(s.awake, s.total)}%",
                    ),
                )
            },
        ) {
            // Reconstructed stage architecture: light → deep → light → rem → light → awake.
            val segments = stageSegments(s)
            if (segments.isNotEmpty()) {
                Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
                    Box(modifier = Modifier.fillMaxWidth().height(34.dp)) {
                        Hypnogram(
                            stages = segments,
                            modifier = Modifier.fillMaxWidth().height(34.dp),
                        )
                    }
                    Row(horizontalArrangement = Arrangement.spacedBy(16.dp)) {
                        StageLegend("Deep", Palette.sleepDeep)
                        StageLegend("Light", Palette.sleepLight)
                        StageLegend("REM", Palette.sleepREM)
                        StageLegend("Awake", Palette.sleepAwake)
                    }
                }
            } else {
                Text(
                    "No stage breakdown for the latest night.",
                    style = NoopType.subhead,
                    color = Palette.textTertiary,
                )
            }
        }
    }
}

@Composable
private fun StageLegend(label: String, color: Color) {
    Row(
        horizontalArrangement = Arrangement.spacedBy(5.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Box(
            modifier = Modifier
                .height(9.dp)
                .width(9.dp)
                .clip(RoundedCornerShape(2.dp))
                .background(color),
        )
        Text(label, style = NoopType.footnote, color = Palette.textTertiary)
    }
}

// MARK: - 2. Metric grid (uniform fixed-height tiles, each with a sparkline)

@Composable
private fun MetricGrid(m: SleepModel) {
    val tiles = listOf<@Composable (Modifier) -> Unit>(
        { mod ->
            SparkTile(
                mod, "Sleep Performance",
                value = pctValue(m.performance.latest),
                caption = vsTypical(m.performance.latest, m.performance.typical, "%"),
                accent = m.performance.latest?.let { Palette.recoveryColor(it) } ?: Palette.textPrimary,
                spark = m.performance.series, sparkColor = Palette.accent,
            )
        },
        { mod ->
            SparkTile(
                mod, "Efficiency",
                value = pctValue(m.efficiency.latest),
                caption = vsTypical(m.efficiency.latest, m.efficiency.typical, "%"),
                accent = Palette.statusPositive,
                spark = m.efficiency.series, sparkColor = Palette.statusPositive,
            )
        },
        { mod ->
            SparkTile(
                mod, "Consistency",
                value = pctValue(m.consistency.latest),
                caption = vsTypical(m.consistency.latest, m.consistency.typical, "%"),
                accent = m.consistency.latest?.let { Palette.recoveryColor(it) } ?: Palette.textPrimary,
                spark = m.consistency.series, sparkColor = Palette.metricCyan,
            )
        },
        { mod ->
            SparkTile(
                mod, "Hours vs Needed",
                value = pctValue(m.hoursVsNeeded.latest),
                caption = vsTypical(m.hoursVsNeeded.latest, m.hoursVsNeeded.typical, "%"),
                accent = m.hoursVsNeeded.latest?.let { Palette.recoveryColor(minOf(100.0, it)) } ?: Palette.textPrimary,
                spark = m.hoursVsNeeded.series, sparkColor = Palette.accent,
            )
        },
        { mod ->
            SparkTile(
                mod, "Restorative",
                value = pctValue(m.restorative.latest),
                caption = vsTypical(m.restorative.latest, m.restorative.typical, "%"),
                accent = Palette.sleepREM,
                spark = m.restorative.series, sparkColor = Palette.sleepREM,
            )
        },
        { mod ->
            SparkTile(
                mod, "Respiratory",
                value = m.respiratory.latest?.let { String.format(Locale.US, "%.1f", it) } ?: "—",
                caption = vsTypical(m.respiratory.latest, m.respiratory.typical, " rpm", decimals = 1),
                accent = Palette.metricPurple,
                spark = m.respiratory.series, sparkColor = Palette.metricPurple,
            )
        },
        { mod ->
            SparkTile(
                mod, "Sleep Debt",
                value = m.sleepDebt.latest?.let { durationText(it) } ?: "—",
                caption = debtCaption(m.sleepDebt.latest),
                accent = debtColor(m.sleepDebt.latest),
                spark = m.sleepDebt.series, sparkColor = Palette.metricRose,
            )
        },
    )

    Column(verticalArrangement = Arrangement.spacedBy(Metrics.gap)) {
        SectionHeader("Night detail", overline = "Metrics", trailing = "vs typical")
        // Two-up rows keep every tile the same fixed height with no empty cells.
        tiles.chunked(2).forEach { rowTiles ->
            Row(horizontalArrangement = Arrangement.spacedBy(Metrics.gap)) {
                rowTiles.forEach { it(Modifier.weight(1f)) }
                if (rowTiles.size == 1) Spacer(Modifier.weight(1f))
            }
        }
    }
}

// MARK: - 3. Stages vs typical

@Composable
private fun StagesVsTypical(m: SleepModel) {
    val s = m.stages
    Column(verticalArrangement = Arrangement.spacedBy(Metrics.gap)) {
        SectionHeader("Stages vs typical", overline = "Last night", trailing = "marker = your mean")
        NoopCard {
            Column(verticalArrangement = Arrangement.spacedBy(14.dp)) {
                StageRow("Deep", last = s.deep, typical = m.typicalDeepMin, color = Palette.sleepDeep)
                Hairline()
                StageRow("REM", last = s.rem, typical = m.typicalRemMin, color = Palette.sleepREM)
                Hairline()
                StageRow("Light", last = s.light, typical = m.typicalLightMin, color = Palette.sleepLight)
            }
        }
    }
}

@Composable
private fun Hairline() {
    Box(modifier = Modifier.fillMaxWidth().height(1.dp).background(Palette.hairline))
}

/** One stage bar: last-night minutes filled, with a vertical marker at the typical mean. */
@Composable
private fun StageRow(label: String, last: Double, typical: Double?, color: Color) {
    val scaleMax = max(last, typical ?: 0.0) * 1.18
    val scale = if (scaleMax > 0.0) scaleMax else 1.0
    val deltaText: String = run {
        if (typical == null || typical <= 0.0) {
            ""
        } else {
            val diff = last - typical
            val sign = if (diff >= 0) "+" else "−"
            "$sign${durationText(abs(diff))} vs typ"
        }
    }
    Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Overline(label, modifier = Modifier.weight(1f))
            Text(durationText(last), style = NoopType.captionNumber, color = Palette.textPrimary)
            if (deltaText.isNotEmpty()) {
                Text(
                    deltaText,
                    style = NoopType.footnote,
                    color = if (last >= (typical ?: last)) Palette.statusPositive else Palette.statusWarning,
                    modifier = Modifier.padding(start = 8.dp),
                )
            }
        }
        // Track + last-night fill + typical marker.
        val fillFrac = (last / scale).coerceIn(0.0, 1.0).toFloat()
        val markerFrac = typical?.takeIf { it > 0.0 }?.let { (it / scale).coerceIn(0.0, 1.0).toFloat() }
        Box(
            modifier = Modifier
                .fillMaxWidth()
                .height(10.dp)
                .clip(RoundedCornerShape(50))
                .background(Palette.surfaceInset)
                .drawBehind {
                    // last-night fill
                    if (fillFrac > 0f) {
                        drawRoundRectFill(color, fillFrac)
                    }
                    // typical marker
                    if (markerFrac != null) {
                        val x = (size.width * markerFrac).coerceIn(1f, size.width - 1f)
                        drawLine(
                            color = Palette.textPrimary,
                            start = Offset(x, 0f),
                            end = Offset(x, size.height),
                            strokeWidth = 2f,
                            cap = StrokeCap.Round,
                        )
                    }
                },
        )
    }
}

private fun DrawScope.drawRoundRectFill(color: Color, frac: Float) {
    val w = (size.width * frac).coerceAtLeast(size.height)
    val r = size.height / 2f
    drawRoundRect(
        color = color,
        size = Size(w, size.height),
        cornerRadius = CornerRadius(r, r),
    )
}

// MARK: - 4. 14-day asleep-hours trend

@Composable
private fun DurationTrend(m: SleepModel) {
    val pts = m.trendHours
    val avg = m.typicalTotalMin?.let { it / 60.0 }
    Column(verticalArrangement = Arrangement.spacedBy(Metrics.gap)) {
        SectionHeader("Asleep duration", overline = "Trend", trailing = "Last 14 days")
        ChartCard(
            title = "Hours asleep",
            subtitle = "Per night, trailing 14 days",
            trailing = avg?.let { String.format(Locale.US, "%.1f h avg", it) },
            footer = {
                ChartFooter(
                    listOf(
                        "Avg" to (avg?.let { String.format(Locale.US, "%.1f h", it) } ?: "—"),
                        "Min" to (pts.minOrNull()?.let { String.format(Locale.US, "%.1f h", it) } ?: "—"),
                        "Max" to (pts.maxOrNull()?.let { String.format(Locale.US, "%.1f h", it) } ?: "—"),
                        "Nights" to "${pts.size}",
                    ),
                )
            },
        ) {
            if (pts.size >= 2) {
                LineChart(
                    values = pts,
                    modifier = Modifier.fillMaxWidth().height(Metrics.chartHeight - 90.dp),
                    color = Palette.accent,
                    fill = true,
                )
            } else {
                Box(
                    modifier = Modifier
                        .fillMaxWidth()
                        .height(Metrics.chartHeight - 90.dp)
                        .clip(RoundedCornerShape(12.dp))
                        .background(Palette.surfaceInset),
                    contentAlignment = Alignment.Center,
                ) {
                    Text("Not enough nights yet.", style = NoopType.subhead, color = Palette.textTertiary)
                }
            }
        }
    }
}

// MARK: - ChartCard / ChartFooter (local — mirror the macOS ChartCard the screen used)

/**
 * The chart container the macOS screen leaned on: a NoopCard with a header (overline-
 * style title + subtitle + trailing read-out), the chart body, then a footer row of
 * label/value pairs. Kept local so the shared component set stays minimal.
 */
@Composable
private fun ChartCard(
    title: String,
    subtitle: String,
    trailing: String?,
    footer: @Composable () -> Unit,
    chart: @Composable () -> Unit,
) {
    NoopCard(padding = 16.dp) {
        Column(verticalArrangement = Arrangement.spacedBy(14.dp)) {
            Row(verticalAlignment = Alignment.Top) {
                Column(modifier = Modifier.weight(1f)) {
                    Text(title, style = NoopType.headline, color = Palette.textPrimary)
                    Text(subtitle, style = NoopType.footnote, color = Palette.textSecondary)
                }
                if (trailing != null) {
                    Text(trailing, style = NoopType.number(18f), color = Palette.textPrimary)
                }
            }
            chart()
            footer()
        }
    }
}

/** A footer strip of label/value pairs, evenly distributed. */
@Composable
private fun ChartFooter(items: List<Pair<String, String>>) {
    Row(modifier = Modifier.fillMaxWidth()) {
        items.forEach { (label, value) ->
            Column(modifier = Modifier.weight(1f)) {
                Overline(label, color = Palette.textTertiary)
                Text(value, style = NoopType.captionNumber, color = Palette.textPrimary)
            }
        }
    }
}

// MARK: - SparkTile (fixed-height metric tile with a trailing 30-day sparkline)

@Composable
private fun SparkTile(
    modifier: Modifier,
    label: String,
    value: String,
    caption: String?,
    accent: Color,
    spark: List<Double>,
    sparkColor: Color,
) {
    NoopCard(modifier = modifier.height(Metrics.tileHeight), padding = 14.dp) {
        Column(modifier = Modifier.fillMaxWidth()) {
            Overline(label)
            Spacer(Modifier.weight(1f))
            Row(modifier = Modifier.fillMaxWidth(), verticalAlignment = Alignment.Bottom) {
                Column(modifier = Modifier.weight(1f)) {
                    Text(
                        value,
                        style = NoopType.number(24f),
                        color = accent,
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis,
                    )
                    if (caption != null) {
                        Text(
                            caption,
                            style = NoopType.footnote,
                            color = Palette.textTertiary,
                            maxLines = 1,
                            overflow = TextOverflow.Ellipsis,
                            modifier = Modifier.padding(top = 2.dp),
                        )
                    }
                }
                val tail = spark.takeLast(30)
                if (tail.size >= 2) {
                    Box(
                        modifier = Modifier
                            .padding(start = 8.dp, bottom = 2.dp)
                            .width(58.dp)
                            .height(22.dp),
                    ) {
                        Sparkline(values = tail, color = sparkColor)
                    }
                }
            }
        }
    }
}

// MARK: - Empty state

@Composable
private fun SleepEmptyState() {
    DataPendingNote(
        title = "No nights here yet",
        body = "No nights here yet. Import your WHOOP export in Data Sources to see " +
            "every night, your sleep stages and trends straight away.",
    )
}

// MARK: - Model + derivation (faithful to SleepView.swift)

/** Stage minutes for a single night (mirrors the macOS Stages struct). */
private data class Stages(
    val awake: Double,
    val light: Double,
    val deep: Double,
    val rem: Double,
) {
    /** Total time in bed (includes awake). */
    val total: Double get() = awake + light + deep + rem

    /** Asleep time = total minus awake. */
    val asleep: Double get() = light + deep + rem
}

/** (latest, typical mean, full history) per metric — mirrors the macOS Metric tuple. */
private data class Metric(
    val latest: Double?,
    val typical: Double?,
    val series: List<Double>,
)

/** Everything the screen renders, derived once per data change. */
private data class SleepModel(
    val stages: Stages,
    val clockLabel: String,
    val efficiencyText: String,
    val performance: Metric,
    val efficiency: Metric,
    val consistency: Metric,
    val hoursVsNeeded: Metric,
    val restorative: Metric,
    val respiratory: Metric,
    val sleepDebt: Metric,
    val typicalTotalMin: Double?,
    val typicalDeepMin: Double?,
    val typicalRemMin: Double?,
    val typicalLightMin: Double?,
    val trendHours: List<Double>,
)

/**
 * Build the whole model from the cached daily metrics + the latest sleep session. Returns
 * null when there is no usable latest night (no stage minutes), which renders the empty
 * state. All series are computed in one pass-set here, matching the macOS buildModel().
 */
private fun buildSleepModel(days: List<DailyMetric>, session: SleepSession?): SleepModel? {
    val latest = days.lastOrNull { (it.deepMin ?: 0.0) + (it.remMin ?: 0.0) + (it.lightMin ?: 0.0) > 0.0 }
        ?: return null

    val deep = latest.deepMin ?: 0.0
    val rem = latest.remMin ?: 0.0
    val light = latest.lightMin ?: 0.0
    val asleep = latest.totalSleepMin ?: (deep + rem + light)
    // Awake estimate: prefer (time-in-bed − asleep) implied by efficiency; else from
    // disturbances; matches the macOS "awake minutes" carried in the stagesJSON.
    val effFrac = latest.efficiency?.let { if (it > 1.0) it / 100.0 else it }
    val awake = when {
        effFrac != null && effFrac in 0.01..0.999 -> max(0.0, asleep / effFrac - asleep)
        latest.disturbances != null -> latest.disturbances!! * 6.0
        else -> 0.0
    }
    val stages = Stages(awake = awake, light = light, deep = deep, rem = rem)
    if (stages.total <= 0.0) return null

    // Typical = mean across nights with data (mirrors typicalTotalMin / typicalStageMin).
    val typicalTotalMin = mean(days.mapNotNull { it.totalSleepMin }.filter { it > 0.0 })
    val typicalDeepMin = mean(days.mapNotNull { it.deepMin }.filter { it > 0.0 })
    val typicalRemMin = mean(days.mapNotNull { it.remMin }.filter { it > 0.0 })
    val typicalLightMin = mean(days.mapNotNull { it.lightMin }.filter { it > 0.0 })

    // Personal sleep need (minutes): mean asleep, floored at 7.5h (450 min).
    val needMin = max(450.0, typicalTotalMin ?: 450.0)

    // Per-tile metrics — each a full pass over `days`, exactly as the macOS screen.
    val performance = metric(days) { d ->
        d.totalSleepMin?.takeIf { it > 0.0 && needMin > 0.0 }?.let { minOf(100.0, it / needMin * 100.0) }
    }
    val efficiency = metric(days) { d ->
        d.efficiency?.let { if (it <= 1.0) it * 100.0 else it }
    }
    val consistency = consistencySeries(days)
    val hoursVsNeeded = metric(days) { d ->
        d.totalSleepMin?.takeIf { it > 0.0 && needMin > 0.0 }?.let { it / needMin * 100.0 }
    }
    val restorative = metric(days) { d ->
        val dp = d.deepMin; val rm = d.remMin; val sl = d.totalSleepMin
        if (dp != null && rm != null && sl != null && sl > 0.0) (dp + rm) / sl * 100.0 else null
    }
    val respiratory = metric(days) { it.respRateBpm }
    val sleepDebt = run {
        val series = days.mapNotNull { d ->
            d.totalSleepMin?.takeIf { it > 0.0 && needMin > 0.0 }?.let { max(0.0, needMin - it) }
        }
        Metric(series.lastOrNull(), mean(series), series)
    }

    // 14-day asleep-hours trend (falls back to all nights if the window is too sparse).
    val allHours = days.mapNotNull { it.totalSleepMin?.takeIf { m -> m > 0.0 }?.let { m -> m / 60.0 } }
    val recentHours = allHours.takeLast(14)
    val trendHours = if (recentHours.size >= 2) recentHours else allHours

    return SleepModel(
        stages = stages,
        clockLabel = clockLabel(latest, session),
        efficiencyText = efficiency.latest?.let { "${it.roundToInt()}%" } ?: "—",
        performance = performance,
        efficiency = efficiency,
        consistency = consistency,
        hoursVsNeeded = hoursVsNeeded,
        restorative = restorative,
        respiratory = respiratory,
        sleepDebt = sleepDebt,
        typicalTotalMin = typicalTotalMin,
        typicalDeepMin = typicalDeepMin,
        typicalRemMin = typicalRemMin,
        typicalLightMin = typicalLightMin,
        trendHours = trendHours,
    )
}

/** Build a metric from a per-day transform, keeping only finite values. */
private fun metric(days: List<DailyMetric>, transform: (DailyMetric) -> Double?): Metric {
    val series = days.mapNotNull(transform).filter { it.isFinite() }
    return Metric(series.lastOrNull(), mean(series), series)
}

/**
 * Consistency per day from the rolling bedtime spread — but Android's daily metrics carry
 * no per-night onset timestamp, so a bedtime-variance score isn't reconstructable from the
 * cached `days` alone. We approximate the same intent (steadier nights → higher score) from
 * the trailing-14 spread of total-sleep duration: low duration variability ≈ a consistent
 * routine. Each day's score uses the window ending at that day, matching the macOS rolling
 * shape. Honest note: this is a duration-based proxy, not the onset-spread score.
 */
private fun consistencySeries(days: List<DailyMetric>): Metric {
    val mins = days.mapNotNull { it.totalSleepMin?.takeIf { m -> m > 0.0 } }
    if (mins.size < 3) return Metric(null, null, emptyList())
    val scores = ArrayList<Double>()
    for (i in mins.indices) {
        val lo = max(0, i - 13)
        val window = mins.subList(lo, i + 1)
        if (window.size < 3) continue
        val m = window.average()
        val variance = window.sumOf { (it - m) * (it - m) } / window.size
        val sd = Math.sqrt(variance)
        // 90 min of duration SD maps to a 0 score; tighter routines climb to 100.
        scores.add((100.0 * (1.0 - sd / 90.0)).coerceIn(0.0, 100.0))
    }
    return Metric(scores.lastOrNull(), mean(scores), scores)
}

private fun mean(vals: List<Double>): Double? = if (vals.isEmpty()) null else vals.sum() / vals.size

// MARK: - Stage segment reconstruction (durations only — same architecture as macOS)

/**
 * Lay the stage minutes end-to-end as proportional hypnogram segments: light → deep →
 * light → rem → light → awake (deep early, REM later, awake last). Weights are minutes;
 * the Hypnogram normalizes them to width.
 */
private fun stageSegments(s: Stages): List<Pair<String, Float>> {
    val out = ArrayList<Pair<String, Float>>()
    fun add(name: String, minutes: Double) {
        if (minutes > 0.0) out.add(name to minutes.toFloat())
    }
    add("light", s.light * 0.4)
    add("deep", s.deep)
    add("light", s.light * 0.3)
    add("rem", s.rem)
    add("light", s.light * 0.3)
    add("awake", s.awake)
    return out
}

// MARK: - Formatting helpers (mirror SleepView.swift)

private fun pct(minutes: Double, total: Double): Int =
    if (total > 0.0) (minutes / total * 100.0).roundToInt() else 0

private fun pctValue(v: Double?): String = v?.let { "${it.roundToInt()}%" } ?: "—"

/** "+12% vs typical" / "−0.4 rpm vs typical" — the latest-vs-mean caption every tile carries. */
private fun vsTypical(latest: Double?, typical: Double?, suffix: String, decimals: Int = 0): String {
    if (latest == null || typical == null || typical == 0.0) return "vs typical —"
    val diff = latest - typical
    val sign = if (diff >= 0) "+" else "−"
    val mag = abs(diff)
    val num = if (decimals == 0) "${mag.roundToInt()}" else String.format(Locale.US, "%.${decimals}f", mag)
    return "$sign$num$suffix vs typical"
}

private fun debtCaption(debt: Double?): String {
    if (debt == null) return "vs need"
    return if (debt < 15.0) "On target" else "Below need"
}

private fun debtColor(debt: Double?): Color = when {
    debt == null -> Palette.textPrimary
    debt < 15.0 -> Palette.statusPositive
    debt < 60.0 -> Palette.statusWarning
    else -> Palette.statusCritical
}

private fun durationText(minutes: Double): String {
    val m = max(0, minutes.roundToInt())
    return if (m < 60) "${m}m" else "${m / 60}h ${m % 60}m"
}

/** "Wed 4 Jun · 22:50–06:48" style trailing label from the session clock, when available. */
private fun clockLabel(latest: DailyMetric, session: SleepSession?): String {
    val timeFmt = SimpleDateFormat("HH:mm", Locale.US)
    val dateFmt = SimpleDateFormat("EEE d MMM", Locale.US)
    if (session != null) {
        val onset = Date(session.startTs * 1000L)
        val wake = Date(session.endTs * 1000L)
        return "${dateFmt.format(onset)} · ${timeFmt.format(onset)}–${timeFmt.format(wake)}"
    }
    // Fall back to the daily metric's day string (YYYY-MM-DD), formatted to "EEE d MMM".
    return runCatching {
        val parser = SimpleDateFormat("yyyy-MM-dd", Locale.US).apply { timeZone = TimeZone.getTimeZone("UTC") }
        parser.parse(latest.day)?.let { dateFmt.format(it) }
    }.getOrNull() ?: latest.day
}

/**
 * Best-effort sum of a sleepSession stagesJSON. Android's stagesJSON is a verbatim
 * segments array (not the macOS minutes dict), so this is unused for the primary stage
 * split (which comes from the daily metric) but kept available for an onset-aware future.
 * Tolerant of both an object {light,deep,rem,awake} (minutes) and an array of segments.
 */
@Suppress("unused")
private fun parseStagesJson(json: String?): Stages? {
    if (json.isNullOrBlank()) return null
    return runCatching {
        val trimmed = json.trim()
        if (trimmed.startsWith("{")) {
            val o = JSONObject(trimmed)
            Stages(
                awake = o.optDouble("awake", 0.0),
                light = o.optDouble("light", 0.0),
                deep = o.optDouble("deep", 0.0),
                rem = o.optDouble("rem", 0.0),
            ).takeIf { it.total > 0.0 }
        } else if (trimmed.startsWith("[")) {
            val arr = JSONArray(trimmed)
            var a = 0.0; var l = 0.0; var d = 0.0; var r = 0.0
            for (i in 0 until arr.length()) {
                val seg = arr.optJSONObject(i) ?: continue
                val stage = seg.optString("stage", seg.optString("type", "")).lowercase()
                val durMin = (seg.optDouble("durationMin", Double.NaN)).let {
                    if (it.isNaN()) seg.optDouble("duration", 0.0) / 60.0 else it
                }
                when (stage) {
                    "awake", "wake" -> a += durMin
                    "light" -> l += durMin
                    "deep", "sws" -> d += durMin
                    "rem" -> r += durMin
                }
            }
            Stages(a, l, d, r).takeIf { it.total > 0.0 }
        } else {
            null
        }
    }.getOrNull()
}
