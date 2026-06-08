package com.noop.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.border
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
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Favorite
import androidx.compose.material.icons.filled.Warning
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.noop.analytics.ReadinessEngine
import com.noop.data.DailyMetric
import java.util.Locale
import kotlin.math.roundToInt

/**
 * Control Center — the home dashboard. A recovery ring + plain-English synthesis
 * hero, an illness banner when the watch fires, and a tile grid of the day's key
 * metrics — each tile carrying a 14-day sparkline. Ports the macOS TodayView
 * composition (Strand/Screens/TodayView.swift) with the same locked components.
 *
 * Sparkline series are built off the view model's `recentDays` (oldest → newest,
 * all from the my-whoop source). Steps / Weight / Calories have no on-device daily
 * source on Android, so those tiles read "—" with an empty trend until an Apple
 * Health / metricSeries bridge lands — matching the macOS sparse-data contract.
 */
@Composable
fun TodayScreen(viewModel: AppViewModel, onSupport: () -> Unit = {}) {
    val today by viewModel.today.collectAsStateWithLifecycle()
    val alert by viewModel.healthAlert.collectAsStateWithLifecycle()
    val days by viewModel.recentDays.collectAsStateWithLifecycle()
    val todayKey = DashboardDates.todayKey()

    // Actual calendar 14-day window ending today. Old imported history remains in
    // the database, but it must not be presented as today's trend.
    val window = remember14(days, todayKey)

    ScreenScaffold(title = "Control Center", subtitle = "Your day, read in full") {

        // When there is no daily score yet (today's recovery is null / no history),
        // lead with the "live now, history one import away" note so the empty tiles
        // below are explained rather than just dashed out.
        if (today?.recovery == null) {
            DataPendingNote(
                title = "Live now. Your scores are building.",
                body = "Your live heart rate is working from the strap, and recovery, strain " +
                    "and sleep build from it over your next few nights of wear, sharpening as it " +
                    "learns your baseline. Want your full history instantly? Import your WHOOP " +
                    "export in Data Sources and it backfills in about a minute.",
            )
        }

        if (alert != null) IllnessBanner(alert!!)

        // HERO — ring + synthesis read-out, with a subtle always-on support affordance.
        Row(verticalAlignment = Alignment.Top) {
            Box(modifier = Modifier.weight(1f)) {
                SectionHeader("Today's Synthesis", overline = "At a glance", trailing = greetingWord())
            }
            IconButton(
                onClick = onSupport,
                modifier = Modifier.size(36.dp),
            ) {
                Icon(
                    Icons.Filled.Favorite,
                    contentDescription = "Support NOOP",
                    tint = Palette.textTertiary,
                    modifier = Modifier.size(18.dp),
                )
            }
        }
        Row(horizontalArrangement = Arrangement.spacedBy(Metrics.gap)) {
            NoopCard(modifier = Modifier.weight(1f)) {
                Box(modifier = Modifier.fillMaxWidth(), contentAlignment = Alignment.Center) {
                    RecoveryRing(
                        score = today?.recovery ?: 0.0,
                        supporting = ringSupporting(today),
                        diameter = 168.dp,
                        lineWidth = 13.dp,
                    )
                }
            }
            InsightCard(
                modifier = Modifier.weight(1f),
                category = "Recovery",
                status = synthesisWord(today?.recovery),
                detail = synthesisDetail(today),
                statusColor = today?.recovery?.let { Palette.recoveryColor(it) } ?: Palette.textTertiary,
            )
        }

        // READINESS — on-device training-readiness synthesis (HRV / resting-HR / load).
        // Mirrors the macOS readinessSection: rendered only once there's enough history.
        ReadinessSection(days, todayKey)

        // METRICS — uniform tile grid (two columns), each tile with a 14-day sparkline.
        Spacer(Modifier.padding(top = (Metrics.sectionGap - 20.dp) / 2))
        SectionHeader("Key Metrics", overline = "Today", trailing = "14-day trend")
        MetricGrid(today, window)
    }
}

/**
 * The full 14-day metric grid, mirroring the macOS LazyVGrid order:
 * Recovery, Day Strain, Sleep, HRV, Resting HR, Blood Oxygen, Respiratory,
 * Steps, Weight, Calories. Each tile is a fixed-height [SparkStatTile] so the
 * grid tiles perfectly with no empty cells.
 */
@Composable
private fun MetricGrid(d: DailyMetric?, w: Window) {
    val tiles = listOf<@Composable (Modifier) -> Unit>(
        { m ->
            SparkStatTile(
                modifier = m,
                label = "Recovery",
                value = d?.recovery?.let { "${it.roundToInt()}%" } ?: "—",
                caption = d?.recovery?.let {
                    Palette.recoveryState(it).lowercase().replaceFirstChar { c -> c.uppercase() }
                },
                accent = d?.recovery?.let { Palette.recoveryColor(it) } ?: Palette.textPrimary,
                spark = w.recovery,
                sparkColor = Palette.accent,
            )
        },
        { m ->
            SparkStatTile(
                modifier = m,
                label = "Day Strain",
                value = d?.strain?.let { String.format(Locale.US, "%.1f", it) } ?: "—",
                caption = "of 21",
                accent = d?.strain?.let { Palette.strainColor(it) } ?: Palette.textPrimary,
                spark = w.strain,
                sparkColor = Palette.strain066,
            )
        },
        { m ->
            SparkStatTile(
                modifier = m,
                label = "Sleep",
                value = sleepValue(d),
                caption = d?.efficiency?.let { String.format(Locale.US, "%.0f%% eff", it) },
                accent = Palette.textPrimary,
                spark = w.sleepMin,
                sparkColor = Palette.metricPurple,
            )
        },
        { m ->
            SparkStatTile(
                modifier = m,
                label = "HRV",
                value = d?.avgHrv?.let { "${it.roundToInt()}" } ?: "—",
                caption = "ms",
                accent = Palette.metricPurple,
                spark = w.hrv,
                sparkColor = Palette.metricPurple,
            )
        },
        { m ->
            SparkStatTile(
                modifier = m,
                label = "Resting HR",
                value = d?.restingHr?.toString() ?: "—",
                caption = "bpm",
                accent = Palette.metricRose,
                spark = w.rhr,
                sparkColor = Palette.metricRose,
            )
        },
        { m ->
            SparkStatTile(
                modifier = m,
                label = "Blood Oxygen",
                value = d?.spo2Pct?.let { String.format(Locale.US, "%.0f%%", it) } ?: "—",
                caption = "SpO₂",
                accent = Palette.metricCyan,
                spark = w.spo2,
                sparkColor = Palette.metricCyan,
            )
        },
        { m ->
            SparkStatTile(
                modifier = m,
                label = "Respiratory",
                value = d?.respRateBpm?.let { String.format(Locale.US, "%.1f", it) } ?: "—",
                caption = "rpm",
                accent = Palette.accent,
                spark = w.resp,
                sparkColor = Palette.accent,
            )
        },
        { m ->
            // No on-device daily steps source on Android yet — show the empty state.
            SparkStatTile(
                modifier = m,
                label = "Steps",
                value = "—",
                caption = "today",
                accent = Palette.metricCyan,
                spark = emptyList(),
                sparkColor = Palette.metricCyan,
            )
        },
        { m ->
            SparkStatTile(
                modifier = m,
                label = "Weight",
                value = "—",
                caption = "latest",
                accent = Palette.accent,
                spark = emptyList(),
                sparkColor = Palette.accent,
            )
        },
        { m ->
            SparkStatTile(
                modifier = m,
                label = "Calories",
                value = "—",
                caption = "active",
                accent = Palette.metricAmber,
                spark = emptyList(),
                sparkColor = Palette.metricAmber,
            )
        },
    )

    // Two-column grid built from rows so tile heights stay uniform (mirrors the
    // macOS adaptive grid; a fixed 2-up layout reads well on phone widths).
    Column(verticalArrangement = Arrangement.spacedBy(Metrics.gap)) {
        tiles.chunked(2).forEach { rowTiles ->
            Row(horizontalArrangement = Arrangement.spacedBy(Metrics.gap)) {
                rowTiles.forEach { tile -> tile(Modifier.weight(1f)) }
                if (rowTiles.size == 1) Spacer(Modifier.weight(1f))
            }
        }
    }
}

// MARK: - Readiness card (ported from TodayView.swift readinessSection)
//
// On-device training-readiness synthesis. Calls the analytics ReadinessEngine over the
// view model's day history and renders the macOS card: a colored level dot + headline,
// an optional acute:chronic "load X.XX" read-out, the plain-English summary, then one
// row per driving signal (a small flag-colored dot + label + detail). The whole card is
// suppressed until there is enough history (level == INSUFFICIENT), matching macOS.

@Composable
private fun ReadinessSection(days: List<DailyMetric>, todayKey: String) {
    val readiness = remember(days, todayKey) { ReadinessEngine.evaluate(days, today = todayKey) }
    if (readiness.level == ReadinessEngine.Level.INSUFFICIENT) return

    SectionHeader("Readiness", overline = "Should you push today?")
    NoopCard {
        Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
            // Headline row: level dot + headline, then the ACWR load read-out.
            Row(verticalAlignment = Alignment.CenterVertically) {
                Box(
                    modifier = Modifier
                        .size(10.dp)
                        .clip(CircleShape)
                        .background(readinessColor(readiness.level)),
                )
                Spacer(Modifier.width(10.dp))
                Text(
                    readiness.headline,
                    style = NoopType.headline,
                    color = Palette.textPrimary,
                    modifier = Modifier.weight(1f),
                )
                readiness.acwr?.let { acwr ->
                    Text(
                        "load ${String.format(Locale.US, "%.2f", acwr)}",
                        style = NoopType.captionNumber,
                        color = Palette.textTertiary,
                    )
                }
            }

            // Plain-English summary.
            Text(
                readiness.summary,
                style = NoopType.subhead,
                color = Palette.textSecondary,
            )

            // Per-signal rows: flag dot + fixed-width label + detail.
            if (readiness.signals.isNotEmpty()) {
                Box(
                    modifier = Modifier
                        .fillMaxWidth()
                        .height(1.dp)
                        .background(Palette.hairline),
                )
                readiness.signals.forEach { signal ->
                    Row(verticalAlignment = Alignment.Top) {
                        Box(
                            modifier = Modifier
                                .padding(top = 5.dp)
                                .size(7.dp)
                                .clip(CircleShape)
                                .background(flagColor(signal.flag)),
                        )
                        Spacer(Modifier.width(8.dp))
                        Text(
                            signal.label,
                            style = NoopType.caption,
                            color = Palette.textSecondary,
                            modifier = Modifier.width(104.dp),
                        )
                        Text(
                            signal.detail,
                            style = NoopType.caption,
                            color = Palette.textTertiary,
                            modifier = Modifier.weight(1f),
                        )
                    }
                }
            }
        }
    }
}

/** Level → color, mirroring TodayView.readinessColor. */
private fun readinessColor(level: ReadinessEngine.Level): Color = when (level) {
    ReadinessEngine.Level.PRIMED -> Palette.accent
    ReadinessEngine.Level.BALANCED -> Palette.statusPositive
    ReadinessEngine.Level.STRAINED -> Palette.statusWarning
    ReadinessEngine.Level.RUNDOWN -> Palette.metricRose
    ReadinessEngine.Level.INSUFFICIENT -> Palette.textTertiary
}

/** Flag → color, mirroring TodayView.flagColor. */
private fun flagColor(flag: ReadinessEngine.Flag): Color = when (flag) {
    ReadinessEngine.Flag.GOOD -> Palette.accent
    ReadinessEngine.Flag.NEUTRAL -> Palette.textTertiary
    ReadinessEngine.Flag.WATCH -> Palette.statusWarning
    ReadinessEngine.Flag.BAD -> Palette.metricRose
}

// MARK: - SparkStatTile
//
// A fixed-height metric tile: overline label, big value + caption, and a 14-day
// Sparkline anchored along the bottom edge. Mirrors the macOS StatTile-with-sparkline
// while reusing the locked surfaces/typography (NoopCard, Overline, NoopType). Built
// here rather than mutating the shared StatTile so other screens keep the plain tile.

@Composable
private fun SparkStatTile(
    label: String,
    value: String,
    modifier: Modifier = Modifier,
    caption: String? = null,
    accent: Color = Palette.textPrimary,
    spark: List<Double> = emptyList(),
    sparkColor: Color = Palette.accent,
) {
    NoopCard(modifier = modifier.height(Metrics.tileHeight), padding = 14.dp) {
        Column(modifier = Modifier.fillMaxWidth()) {
            Overline(label)
            Spacer(Modifier.weight(1f))
            Row(
                modifier = Modifier.fillMaxWidth(),
                verticalAlignment = Alignment.Bottom,
            ) {
                Column(modifier = Modifier.weight(1f)) {
                    Text(
                        value,
                        style = NoopType.number(26f),
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
                if (spark.size >= 2) {
                    // Sparkline forces fillMaxWidth + a fixed height internally, so we
                    // bound it in a sized Box to keep it a compact inline trend.
                    Box(
                        modifier = Modifier
                            .padding(start = 8.dp, bottom = 2.dp)
                            .width(64.dp)
                            .height(22.dp),
                    ) {
                        Sparkline(values = spark, color = sparkColor)
                    }
                }
            }
        }
    }
}

// MARK: - Illness banner (ported from HealthAlertBanner.swift)

@Composable
private fun IllnessBanner(message: String) {
    val shape = RoundedCornerShape(12.dp)
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .background(Palette.statusWarning.copy(alpha = 0.12f), shape)
            .border(1.dp, Palette.statusWarning.copy(alpha = 0.4f), shape)
            .padding(14.dp),
        horizontalArrangement = Arrangement.spacedBy(10.dp),
        verticalAlignment = Alignment.Top,
    ) {
        Icon(Icons.Filled.Warning, contentDescription = null, tint = Palette.statusWarning)
        Text(message, style = NoopType.subhead, color = Palette.textPrimary)
    }
}

// MARK: - 14-day sparkline windows (built from recentDays)

/** The trailing-window series for each tile, oldest → newest. */
private data class Window(
    val recovery: List<Double>,
    val strain: List<Double>,
    val sleepMin: List<Double>,
    val hrv: List<Double>,
    val rhr: List<Double>,
    val spo2: List<Double>,
    val resp: List<Double>,
)

/**
 * Build the 14-day windows from `recentDays`, anchored to the phone's actual local
 * today. Each series drops null metric values within that calendar window only.
 */
@Composable
private fun remember14(days: List<com.noop.data.DailyMetric>, todayKey: String): Window =
    androidx.compose.runtime.remember(days, todayKey) {
        val window = DashboardDates.trailingWindow(days, todayKey, 14)
        fun series(pick: (DailyMetric) -> Double?): List<Double> {
            return window.mapNotNull(pick)
        }
        Window(
            recovery = series { it.recovery },
            strain = series { it.strain },
            sleepMin = series { it.totalSleepMin },
            hrv = series { it.avgHrv },
            rhr = series { it.restingHr?.toDouble() },
            spo2 = series { it.spo2Pct },
            resp = series { it.respRateBpm },
        )
    }

// MARK: - Derived text (ported from TodayView.swift)

private fun greetingWord(): String {
    val h = java.util.Calendar.getInstance().get(java.util.Calendar.HOUR_OF_DAY)
    return when {
        h < 12 -> "Good morning"
        h < 17 -> "Good afternoon"
        else -> "Good evening"
    }
}

private fun synthesisWord(score: Double?): String {
    if (score == null) return "No Data"
    return when {
        score < 25 -> "Depleted"
        score < 50 -> "Low"
        score < 70 -> "Steady"
        score < 88 -> "Primed"
        else -> "Peak"
    }
}

private fun synthesisDetail(d: DailyMetric?): String {
    val rec = d?.recovery
        ?: return "No metrics yet. Sync your strap to begin."
    val recPart = when {
        rec < 50 -> "Recovery is low"
        rec < 70 -> "Recovery is steady"
        else -> "Recovery is strong"
    }
    val sleepPart = d.totalSleepMin?.let { mins ->
        if (mins / 60.0 >= 7) " and sleep was consistent" else " but sleep ran short"
    } ?: ""
    return "$recPart$sleepPart."
}

private fun ringSupporting(d: DailyMetric?): String {
    val hrv = d?.avgHrv?.let { "${it.roundToInt()} ms" } ?: "— ms"
    val rhr = d?.restingHr?.toString() ?: "—"
    return "HRV $hrv · RHR $rhr"
}

private fun sleepValue(d: DailyMetric?): String {
    val m = d?.totalSleepMin ?: return "—"
    val total = m.roundToInt()
    return "${total / 60}h ${total % 60}m"
}
