package com.noop.ui

import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.tween
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
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
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.noop.data.DailyMetric
import java.util.Locale
import kotlin.math.exp
import kotlin.math.min
import kotlin.math.roundToInt
import kotlin.math.sqrt

// MARK: - Stress Monitor (ported from Strand/Screens/StressView.swift)
//
// A Whoop-style "Stress Monitor": one 0–3 number, a band (LOW/MEDIUM/HIGH), and a
// single plain-English line on *why*. The score is a transparent proxy for autonomic
// load, DERIVED from how today's resting HR / HRV sit against a personal 30-day
// baseline (a stored "stress" series, if present, takes priority):
//
//   zRHR = (todayRHR − meanRHR) / sdRHR        // positive when RHR is UP
//   zHRV = (meanHRV − todayHRV) / sdHRV        // positive when HRV is DOWN
//   raw  = zRHR + zHRV                          // combined autonomic load
//   stress = 3 / (1 + e^(−raw))                // 0 calm · 1.5 baseline · 3 high
//
// Bands: 0–1 LOW · 1–2 MEDIUM · 2–3 HIGH. Everything is computed live from
// `recentDays` (+ the stored series) so the math is fully inspectable — see the
// "How this is computed" card at the bottom.
//
// Source priority for today's value:
//   1. A persisted daily `stress` value from the metricSeries store ("my-whoop").
//   2. Otherwise the z-score derivation above.
// Both the hero number and the full trend line share ONE baseline so the line is
// internally comparable.

@Composable
fun StressScreen(vm: AppViewModel) {
    val days by vm.recentDays.collectAsStateWithLifecycle()

    // Stored daily "stress" values (0–3), keyed by day. Loaded once per device; the
    // metricSeries store is the Android analogue of the macOS `repo.series(key:source:)`.
    // We pull a wide range so the whole history is covered.
    var stored by remember { mutableStateOf<Map<String, Double>>(emptyMap()) }
    var storedLoaded by remember { mutableStateOf(false) }
    androidx.compose.runtime.LaunchedEffect(Unit) {
        val rows = runCatching {
            vm.repo.metricSeries("my-whoop", "stress", "0000-01-01", "9999-12-31")
        }.getOrDefault(emptyList())
        stored = rows.associate { it.day to it.value.coerceIn(0.0, 3.0) }
        storedLoaded = true
    }

    // Rebuild the model only when the inputs (days, stored) actually change — the
    // derivation is O(n) over the full history, so we memoize on the inputs.
    val model = remember(days, stored) { StressModel.build(days, stored) }

    ScreenScaffold(
        title = "Stress",
        subtitle = "Autonomic load from HRV and resting heart rate",
    ) {
        when {
            model != null -> StressContent(model)
            !storedLoaded -> StressLoading()
            else -> StressEmpty()
        }
    }
}

// MARK: - Loaded content

@Composable
private fun androidx.compose.foundation.layout.ColumnScope.StressContent(model: StressModel) {
    // 1 · HERO — the gauge + band + one plain-English line, all in one card.
    NoopCard {
        Column(
            modifier = Modifier.fillMaxWidth(),
            verticalArrangement = Arrangement.spacedBy(14.dp),
        ) {
            Row(
                modifier = Modifier.fillMaxWidth(),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Overline("Stress monitor", modifier = Modifier.weight(1f))
                StatePill(model.band.title, tone = model.band.tone, showsDot = true)
            }
            StressGauge(
                score = model.score,
                bandTitle = model.band.title,
                modifier = Modifier.fillMaxWidth(),
            )
            Text(
                model.explanation,
                style = NoopType.subhead,
                color = Palette.textSecondary,
            )
        }
    }

    // 2 · Today's markers — uniform fixed-height tiles, two-up.
    Column(verticalArrangement = Arrangement.spacedBy(Metrics.gap)) {
        SectionHeader("Today", overline = "Markers", trailing = "vs 30-day baseline")
        StressTiles(model)
    }

    // 3 · Trend over the chosen window.
    StressTrendSection(model)

    // 4 · Transparency — how the number is built.
    StressMethodologyCard(model)
}

// MARK: - 2 · Today's tiles (uniform grid)

@Composable
private fun StressTiles(model: StressModel) {
    val tiles = listOf<@Composable (Modifier) -> Unit>(
        { m ->
            // Today's stress value, with its band as the caption.
            StatTile(
                modifier = m,
                label = "Stress",
                value = String.format(Locale.US, "%.1f", model.score),
                caption = "of 3 · ${model.band.title}",
                accent = StressRamp.color(model.score),
            )
        },
        { m ->
            // Resting HR — an INCREASE is the stressful direction.
            MarkerTile(
                modifier = m,
                label = "Resting HR",
                value = model.rhrToday?.let { "$it bpm" } ?: "—",
                delta = model.rhrDelta,
                accent = Palette.metricRose,
                higherIsStress = true,
            )
        },
        { m ->
            // HRV — a DECREASE is the stressful direction.
            MarkerTile(
                modifier = m,
                label = "HRV",
                value = model.hrvToday?.let { "${it.roundToInt()} ms" } ?: "—",
                delta = model.hrvDelta,
                accent = Palette.metricPurple,
                higherIsStress = false,
            )
        },
        { m ->
            // Estimated calm time — share of recent days spent in the LOW band.
            StatTile(
                modifier = m,
                label = "Calm time",
                value = model.calmTimeValue,
                caption = model.calmTimeCaption,
                accent = StressRamp.CALM,
            )
        },
    )
    Column(verticalArrangement = Arrangement.spacedBy(Metrics.gap)) {
        tiles.chunked(2).forEach { rowTiles ->
            Row(horizontalArrangement = Arrangement.spacedBy(Metrics.gap)) {
                rowTiles.forEach { tile -> tile(Modifier.weight(1f)) }
                if (rowTiles.size == 1) Spacer(Modifier.weight(1f))
            }
        }
    }
}

/**
 * A vs-baseline marker as a fixed-height [StatTile]. The delta is tinted by whether
 * the move is toward stress (warning) or recovery (positive). Mirrors macOS markerTile.
 */
@Composable
private fun MarkerTile(
    label: String,
    value: String,
    delta: Double?,
    accent: Color,
    higherIsStress: Boolean,
    modifier: Modifier = Modifier,
) {
    val deltaText: String
    val deltaColor: Color
    if (delta != null && kotlin.math.abs(delta) >= 0.5) {
        val up = delta > 0
        val isStressful = (up == higherIsStress)
        deltaText = "${if (up) "+" else "−"}${kotlin.math.abs(delta).roundToInt()} vs base"
        deltaColor = if (isStressful) Palette.statusWarning else Palette.statusPositive
    } else {
        deltaText = "at baseline"
        deltaColor = Palette.textTertiary
    }
    StatTile(
        modifier = modifier,
        label = label,
        value = value,
        accent = accent,
        delta = deltaText,
        deltaColor = deltaColor,
    )
}

// MARK: - 3 · Trend (range-controlled)

@Composable
private fun StressTrendSection(model: StressModel) {
    var range by remember { mutableStateOf(StressRange.Month) }
    val points = remember(model, range) { model.windowedTrend(range) }

    Column(verticalArrangement = Arrangement.spacedBy(Metrics.gap)) {
        SectionHeader("Stress Trend", overline = "History", trailing = range.label)
        if (points.size >= 2) {
            val avg = points.average()
            NoopCard {
                Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
                    Row(
                        modifier = Modifier.fillMaxWidth(),
                        verticalAlignment = Alignment.Top,
                    ) {
                        Column(modifier = Modifier.weight(1f)) {
                            Overline("Stress · ${range.label}")
                            Text(
                                "Daily 0–3 proxy",
                                style = NoopType.footnote,
                                color = Palette.textTertiary,
                            )
                        }
                        Text(
                            "avg " + String.format(Locale.US, "%.1f", avg),
                            style = NoopType.captionNumber,
                            color = Palette.textSecondary,
                        )
                    }
                    LineChart(
                        values = points,
                        modifier = Modifier.height(Metrics.chartHeight),
                        color = StressRamp.STEADY,
                        fill = true,
                        selectionEnabled = true,
                    )
                    HorizontalDivider(color = Palette.hairline)
                    Row(modifier = Modifier.fillMaxWidth()) {
                        TrendFooterItem("Today", String.format(Locale.US, "%.1f", model.score))
                        TrendFooterItem("Average", String.format(Locale.US, "%.1f", avg))
                        TrendFooterItem("Days", points.size.toString())
                    }
                }
            }
            // The one segmented control — full width, right-aligned.
            Row(modifier = Modifier.fillMaxWidth()) {
                Spacer(Modifier.weight(1f))
                SegmentedPillControl(
                    items = StressRange.entries,
                    selection = range,
                    label = { it.label },
                    onSelect = { range = it },
                )
            }
        } else {
            NoopCard {
                Box(
                    modifier = Modifier
                        .fillMaxWidth()
                        .height(120.dp),
                    contentAlignment = Alignment.Center,
                ) {
                    Text(
                        "Not enough recent days to chart a trend yet. Keep wearing your strap to populate it.",
                        style = NoopType.subhead,
                        color = Palette.textTertiary,
                        textAlign = TextAlign.Center,
                    )
                }
            }
        }
    }
}

@Composable
private fun androidx.compose.foundation.layout.RowScope.TrendFooterItem(label: String, value: String) {
    Column(modifier = Modifier.weight(1f)) {
        Overline(label)
        Text(value, style = NoopType.number(18f), color = Palette.textPrimary)
    }
}

// MARK: - 4 · Methodology (transparency)

@Composable
private fun StressMethodologyCard(model: StressModel) {
    NoopCard {
        Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
            Overline("How this is computed")
            Text(
                if (model.usingStored) {
                    "Today's value is your recorded daily stress score (0–3)."
                } else {
                    "Stress is derived from two autonomic signals."
                },
                style = NoopType.body,
                color = Palette.textPrimary,
            )
            Text(
                "We compare today's resting heart rate and HRV to your own 30-day " +
                    "baseline. A higher-than-usual resting HR and a lower-than-usual HRV " +
                    "both push the score up — classic signs the body is activated. The " +
                    "combined shift is mapped onto a 0–3 scale: 0 is calm, 1.5 sits at " +
                    "your baseline, 3 is highly activated.",
                style = NoopType.subhead,
                color = Palette.textSecondary,
            )
            HorizontalDivider(color = Palette.hairline)
            Row(modifier = Modifier.fillMaxWidth()) {
                BandLegend("0–1", "LOW", StressRamp.CALM)
                BandLegend("1–2", "MEDIUM", StressRamp.STEADY)
                BandLegend("2–3", "HIGH", StressRamp.TENSE)
            }
        }
    }
}

@Composable
private fun androidx.compose.foundation.layout.RowScope.BandLegend(range: String, label: String, color: Color) {
    Row(
        modifier = Modifier.weight(1f),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(7.dp),
    ) {
        Box(
            modifier = Modifier
                .size(8.dp)
                .clip(CircleShape)
                .background(color),
        )
        Column(verticalArrangement = Arrangement.spacedBy(1.dp)) {
            Text(label, style = NoopType.captionNumber, color = Palette.textPrimary)
            Text(range, style = NoopType.footnote, color = Palette.textTertiary)
        }
    }
}

// MARK: - Empty / loading states

@Composable
private fun androidx.compose.foundation.layout.ColumnScope.StressLoading() {
    NoopCard {
        Box(
            modifier = Modifier
                .fillMaxWidth()
                .height(160.dp),
            contentAlignment = Alignment.Center,
        ) {
            Text(
                "Reading your heart-rate variability and resting heart rate…",
                style = NoopType.subhead,
                color = Palette.textTertiary,
                textAlign = TextAlign.Center,
            )
        }
    }
}

@Composable
private fun androidx.compose.foundation.layout.ColumnScope.StressEmpty() {
    DataPendingNote(
        title = "No stress history yet",
        body = "No stress history yet. Import your WHOOP export in Data Sources to see it.",
    )
}

// MARK: - Semicircular stress gauge (0–3, blue → mint → amber sweep)
//
// A compact half-dial: cool-blue at 0, mint at the midpoint, amber at 3 — its own
// ramp, never the recovery traffic light. The value + band read inside the bowl.
// Ports macOS StressGauge / StressArc with a sweep gradient over a faint track.

@Composable
private fun StressGauge(
    score: Double,
    bandTitle: String,
    modifier: Modifier = Modifier,
    diameter: Dp = 240.dp,
) {
    val fraction = (score / 3.0).toFloat().coerceIn(0f, 1f)
    val animated by animateFloatAsState(
        targetValue = fraction,
        animationSpec = tween(Motion.durationSlow, easing = Motion.drawIn),
        label = "stressArc",
    )
    val tipColor = StressRamp.color(score)
    val lineWidthDp = 16.dp

    // The arc occupies the top half of its box; the readout sits inside the bowl, so
    // the component's height is roughly half the diameter plus the stroke + readout.
    val componentHeight = diameter / 2 + lineWidthDp + 30.dp

    Box(
        modifier = modifier
            .height(componentHeight)
            .semantics {
                contentDescription = "Stress ${String.format(Locale.US, "%.1f", score)} of 3, $bandTitle"
            },
        contentAlignment = Alignment.TopCenter,
    ) {
        Box(
            modifier = Modifier
                .size(diameter)
                .drawBehind {
                    val stroke = lineWidthDp.toPx()
                    // Bowl opens upward: center on the bottom-middle, radius inset by the stroke.
                    val radius = (min(size.width, size.height) - stroke) / 2f
                    val arcSize = Size(radius * 2f, radius * 2f)
                    // Arc box top-left so the arc spans the top half over a center at the bottom.
                    val topLeft = Offset(size.width / 2f - radius, size.height - radius)
                    val sweepStroke = Stroke(width = stroke, cap = StrokeCap.Round)

                    // Background track (full 180° semicircle).
                    drawArc(
                        color = Palette.surfaceInset,
                        startAngle = 180f,
                        sweepAngle = 180f,
                        useCenter = false,
                        topLeft = topLeft,
                        size = arcSize,
                        style = sweepStroke,
                    )
                    // Subtle ghost of the full ramp under the track.
                    drawArc(
                        brush = StressRamp.sweepBrush(),
                        startAngle = 180f,
                        sweepAngle = 180f,
                        useCenter = false,
                        topLeft = topLeft,
                        size = arcSize,
                        style = sweepStroke,
                        alpha = 0.16f,
                    )
                    // Value arc swept to the current fraction.
                    if (animated > 0.001f) {
                        drawArc(
                            brush = StressRamp.sweepBrush(),
                            startAngle = 180f,
                            sweepAngle = 180f * animated,
                            useCenter = false,
                            topLeft = topLeft,
                            size = arcSize,
                            style = sweepStroke,
                        )
                        // Soft bloom under the fill, tinted to the sampled stress color.
                        drawArc(
                            color = tipColor,
                            startAngle = 180f,
                            sweepAngle = 180f * animated,
                            useCenter = false,
                            topLeft = topLeft,
                            size = arcSize,
                            style = Stroke(width = stroke * 1.6f, cap = StrokeCap.Round),
                            alpha = 0.22f,
                        )
                    }
                },
        )

        // Center readout (number + band), tucked into the semicircle.
        Column(
            modifier = Modifier.padding(top = diameter / 2 - 56.dp),
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.spacedBy(2.dp),
        ) {
            Text(
                String.format(Locale.US, "%.1f", score),
                style = NoopType.display(54f),
                color = Palette.textPrimary,
            )
            Text(
                "of 3 · $bandTitle",
                style = NoopType.overline,
                color = tipColor,
            )
        }
    }
}

// MARK: - Stress band

private enum class StressBand(val title: String, val tone: StrandTone) {
    Low("LOW", StrandTone.Positive),
    Medium("MEDIUM", StrandTone.Warning),
    High("HIGH", StrandTone.Critical);

    companion object {
        fun forScore(score: Double): StressBand = when {
            score < 1.0 -> Low
            score < 2.0 -> Medium
            else -> High
        }
    }
}

// MARK: - Stress ramp (its own scale: calm blue → balanced mint → tense amber)
//
// Deliberately distinct from the recovery ramp — low stress reads cool/blue, rising
// stress warms toward amber. Never the red→green recovery traffic light.

private object StressRamp {
    val CALM = Color(0xFF4FA9C9)   // cool blue — low
    val STEADY = Color(0xFF5BD3A0) // mint — balanced
    val TENSE = Color(0xFFE8C24B)  // amber — high

    private val stops: List<Pair<Float, Color>> = listOf(
        0.00f to CALM,
        0.50f to STEADY,
        1.00f to TENSE,
    )

    /** Sample the ramp at a 0–3 stress score. */
    fun color(score: Double): Color = Palette.sample(stops, (score / 3.0).toFloat())

    /** Horizontal sweep brush over the full ramp (for arc strokes / fills). */
    fun sweepBrush(): Brush = Brush.horizontalGradient(*stops.toTypedArray())
}

// MARK: - Trend range (the W/M/3M/6M/1Y/ALL window, mirroring ExploreRange)

private enum class StressRange(val label: String, val days: Int?) {
    Week("W", 7),
    Month("M", 30),
    Quarter("3M", 90),
    Half("6M", 180),
    Year("1Y", 365),
    All("ALL", null),
}

// MARK: - Stress model (transparent: stored value OR z-score derivation)

private class StressModel private constructor(
    val score: Double,            // 0–3 (today)
    val band: StressBand,
    val explanation: String,
    val rhrToday: Int?,
    val hrvToday: Double?,
    val rhrDelta: Double?,        // today − baseline mean (bpm)
    val hrvDelta: Double?,        // today − baseline mean (ms)
    val fullTrend: List<TrendPoint>, // entire daily proxy history, oldest → newest
    val calmTimeValue: String,
    val calmTimeCaption: String,
    val usingStored: Boolean,     // true when today's value came from the stored series
) {
    data class TrendPoint(val day: String, val value: Double)

    /** The full daily proxy trend, sliced to the selected trailing window (count-based,
     *  matching the day budget). Falls back to ALL when the trailing slice has < 2 points. */
    fun windowedTrend(range: StressRange): List<Double> {
        val all = fullTrend.map { it.value }
        val days = range.days ?: return all
        val slice = fullTrend.takeLast(days).map { it.value }
        return if (slice.size >= 2) slice else all
    }

    companion object {
        /** Build from oldest→newest daily metrics plus any stored "stress" series.
         *  Returns null only when there is no usable signal at all. */
        fun build(days: List<DailyMetric>, stored: Map<String, Double>): StressModel? {
            val today = days.lastOrNull() ?: return null

            // Baseline window: up to 30 days ending the day BEFORE today, so "today" is
            // measured against its own recent past rather than itself.
            val history = if (days.size > 1) days.dropLast(1) else emptyList()
            val baseline = history.takeLast(30)

            val rhrBase = baseline.mapNotNull { it.restingHr?.toDouble() }
            val hrvBase = baseline.mapNotNull { it.avgHrv }

            val meanRHR = mean(rhrBase)
            val sdRHR = std(rhrBase, meanRHR)
            val meanHRV = mean(hrvBase)
            val sdHRV = std(hrvBase, meanHRV)

            val rhrT = today.restingHr?.toDouble()
            val hrvT = today.avgHrv

            val derivedAvailable = (rhrT != null && meanRHR != null) || (hrvT != null && meanHRV != null)
            val storedToday = stored[today.day]
            if (storedToday == null && !derivedAvailable) return null

            val derivedToday: Double? = if (derivedAvailable) {
                squash(rawScore(rhrT, meanRHR, sdRHR, hrvT, meanHRV, sdHRV))
            } else {
                null
            }

            val s = storedToday ?: derivedToday ?: 1.5
            val usingStored = storedToday != null
            val band = StressBand.forScore(s)
            val rhrDelta = if (rhrT != null && meanRHR != null) rhrT - meanRHR else null
            val hrvDelta = if (hrvT != null && meanHRV != null) hrvT - meanHRV else null
            val explanation = explanation(band, rhrDelta, hrvDelta)

            // Full daily proxy history: stored value if present for the day, else the
            // z-score derivation against the SAME baseline so the line is comparable.
            val pts = ArrayList<TrendPoint>()
            for (d in days) {
                val v = stored[d.day]
                if (v != null) {
                    pts.add(TrendPoint(d.day, v.coerceIn(0.0, 3.0)))
                    continue
                }
                val dRHR = d.restingHr?.toDouble()
                val dHRV = d.avgHrv
                if ((dRHR == null || meanRHR == null) && (dHRV == null || meanHRV == null)) continue
                pts.add(TrendPoint(d.day, squash(rawScore(dRHR, meanRHR, sdRHR, dHRV, meanHRV, sdHRV))))
            }

            // "Calm time": share of the last 30 charted days that sat in the LOW band.
            val recent = pts.takeLast(30)
            val calmValue: String
            val calmCaption: String
            if (recent.isEmpty()) {
                calmValue = "—"
                calmCaption = "needs history"
            } else {
                val calm = recent.count { it.value < 1.0 }
                val pct = (calm.toDouble() / recent.size * 100).roundToInt()
                calmValue = "$pct%"
                calmCaption = "low-stress days · ${recent.size}d"
            }

            return StressModel(
                score = s,
                band = band,
                explanation = explanation,
                rhrToday = today.restingHr,
                hrvToday = hrvT,
                rhrDelta = rhrDelta,
                hrvDelta = hrvDelta,
                fullTrend = pts,
                calmTimeValue = calmValue,
                calmTimeCaption = calmCaption,
                usingStored = usingStored,
            )
        }

        // MARK: Stress math (pure helpers, ported from StressMath)

        private fun mean(xs: List<Double>): Double? =
            if (xs.isEmpty()) null else xs.sum() / xs.size

        /** Population standard deviation; 0 when there's no spread. */
        private fun std(xs: List<Double>, m: Double?): Double {
            if (m == null || xs.size <= 1) return 0.0
            val v = xs.sumOf { (it - m) * (it - m) } / xs.size
            return sqrt(v)
        }

        /** Combined autonomic z-score. RHR-up and HRV-down both push it positive. */
        private fun rawScore(
            rhrToday: Double?, meanRHR: Double?, sdRHR: Double,
            hrvToday: Double?, meanHRV: Double?, sdHRV: Double,
        ): Double {
            var sum = 0.0
            if (rhrToday != null && meanRHR != null && sdRHR > 0.0001) {
                sum += (rhrToday - meanRHR) / sdRHR        // up = stress
            }
            if (hrvToday != null && meanHRV != null && sdHRV > 0.0001) {
                sum += (meanHRV - hrvToday) / sdHRV        // down = stress
            }
            return sum
        }

        /** Logistic squash of the raw z-sum onto 0–3 (baseline 0 → 1.5). */
        private fun squash(raw: Double): Double =
            (3.0 / (1.0 + exp(-raw))).coerceIn(0.0, 3.0)

        private fun explanation(band: StressBand, rhrDelta: Double?, hrvDelta: Double?): String {
            val rhrUp = (rhrDelta ?: 0.0) > 1.0
            val hrvDn = (hrvDelta ?: 0.0) < -1.0
            val hrvUp = (hrvDelta ?: 0.0) > 1.0
            val rhrDn = (rhrDelta ?: 0.0) < -1.0
            return when (band) {
                StressBand.High -> when {
                    rhrUp && hrvDn -> "Resting HR is elevated and HRV is below your baseline — both classic signs of high activation. Prioritise rest, hydration and an easy day."
                    hrvDn -> "HRV has dropped well below your baseline, pointing to elevated stress or fatigue. Ease off and give your body time to recover."
                    rhrUp -> "Resting heart rate is running high versus your norm — your body is under load today. Keep effort light."
                    else -> "Your autonomic markers are skewed toward stress today. Treat it as a recovery-focused day."
                }
                StressBand.Medium -> when {
                    rhrUp || hrvDn -> "Slightly off baseline — ${if (rhrUp) "resting HR is a touch high" else "HRV is a little low"} — so you're moderately activated. Nothing alarming; just don't overreach."
                    else -> "You're sitting around your typical autonomic baseline — moderate stress, a normal, balanced day."
                }
                StressBand.Low -> when {
                    rhrDn && hrvUp -> "Resting heart rate is low and HRV is up — your nervous system looks well-recovered and calm. A great day to push if you want to."
                    hrvUp -> "HRV is above baseline, a sign of a relaxed, well-recovered nervous system. Stress is low."
                    else -> "Resting heart rate and HRV are sitting at or below baseline — low physiological stress. You're in a calm, recovered state."
                }
            }
        }
    }
}
