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
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.noop.analytics.ReadinessEngine
import com.noop.data.DailyMetric
import com.noop.data.WorkoutRow
import java.time.Instant
import java.time.LocalDate
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import java.util.Locale
import kotlin.math.roundToInt

/**
 * Control Center — the home dashboard. A recovery ring + plain-English synthesis
 * hero, an illness banner when the watch fires, and a tile grid of the day's key
 * metrics — each tile carrying a 14-day sparkline. Ports the macOS TodayView
 * composition (Strand/Screens/TodayView.swift) with the same locked components.
 *
 * Sparkline series are built off the view model's `recentDays` (oldest → newest,
 * all from the my-whoop source). Missing current-day values render as explicit
 * "No Data" states instead of raw dashes, so old imports do not look like today.
 */
@Composable
fun TodayScreen(viewModel: AppViewModel, onSupport: () -> Unit = {}) {
    val today by viewModel.today.collectAsStateWithLifecycle()
    val alert by viewModel.healthAlert.collectAsStateWithLifecycle()
    val days by viewModel.recentDays.collectAsStateWithLifecycle()
    var footer by remember { mutableStateOf(TodayFooterState()) }

    // 14-day trailing calendar window ending on the phone's actual local day.
    // Old imports stay in history, but they do not fill the Today trend tiles.
    val window = remember14(days)

    LaunchedEffect(days) {
        val now = System.currentTimeMillis() / 1000
        val recentCutoff = LocalDate.now()
            .minusDays(13)
            .atStartOfDay(ZoneId.systemDefault())
            .toEpochSecond()
        val whoopWorkouts = viewModel.repo.workouts("my-whoop", 0L, now)
        // Apple Health and Health Connect are separate sources (since #34) — keep them separate in the
        // provenance footer too, so Health Connect data isn't mislabelled under the "Apple Health" pill
        // (issue #53). The recent-workouts list below still unions all sources for a combined feed.
        val appleWorkouts = viewModel.repo.workouts("apple-health", 0L, now)
        val hcWorkouts = viewModel.repo.workouts("health-connect", 0L, now)
        val appleDaysCount = viewModel.repo.appleDaily("apple-health", "0000-01-01", "9999-12-31").size
        val hcDaysCount = viewModel.repo.appleDaily("health-connect", "0000-01-01", "9999-12-31").size
        footer = TodayFooterState(
            recentWorkouts = (viewModel.repo.workouts("my-whoop", recentCutoff, now) +
                viewModel.repo.workouts("apple-health", recentCutoff, now) +
                viewModel.repo.workouts("health-connect", recentCutoff, now))
                .sortedByDescending { it.startTs },
            whoopDays = days.size,
            whoopWorkouts = whoopWorkouts.size,
            appleDays = appleDaysCount,
            appleWorkouts = appleWorkouts.size,
            hcDays = hcDaysCount,
            hcWorkouts = hcWorkouts.size,
        )
    }

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
                    TodayRecoveryRing(today)
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
        ReadinessSection(days)

        // METRICS — uniform tile grid (two columns), each tile with a 14-day sparkline.
        Spacer(Modifier.padding(top = (Metrics.sectionGap - 20.dp) / 2))
        SectionHeader("Key Metrics", overline = "Today", trailing = "14-day trend")
        MetricGrid(today, window)
        TodayWorkoutsSection(footer.recentWorkouts)
        TodaySourcesSection(footer)
    }
}

@Composable
private fun TodayRecoveryRing(day: DailyMetric?) {
    val hasRecovery = day?.recovery != null
    Box(contentAlignment = Alignment.Center) {
        RecoveryRing(
            score = day?.recovery ?: 0.0,
            supporting = if (hasRecovery) ringSupporting(day) else null,
            diameter = 168.dp,
            lineWidth = 13.dp,
            showsLabel = hasRecovery,
        )
        if (!hasRecovery) {
            Column(horizontalAlignment = Alignment.CenterHorizontally) {
                Text(
                    text = NO_DATA,
                    style = NoopType.title2,
                    color = Palette.textTertiary,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
                Text(
                    text = ringSupporting(day),
                    style = NoopType.footnote,
                    color = Palette.textSecondary,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                    modifier = Modifier.padding(top = 4.dp),
                )
            }
        }
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
                value = d?.recovery?.let { "${it.roundToInt()}%" } ?: NO_DATA,
                caption = d?.recovery?.let {
                    Palette.recoveryState(it).lowercase().replaceFirstChar { c -> c.uppercase() }
                },
                accent = d?.recovery?.let { Palette.recoveryColor(it) } ?: Palette.textTertiary,
                spark = w.recovery,
                sparkColor = Palette.accent,
            )
        },
        { m ->
            SparkStatTile(
                modifier = m,
                label = "Day Strain",
                value = d?.strain?.let { String.format(Locale.US, "%.1f", it) } ?: NO_DATA,
                caption = d?.strain?.let { "of 21" },
                accent = d?.strain?.let { Palette.strainColor(it) } ?: Palette.textTertiary,
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
                accent = d?.totalSleepMin?.let { Palette.textPrimary } ?: Palette.textTertiary,
                spark = w.sleepMin,
                sparkColor = Palette.metricPurple,
            )
        },
        { m ->
            SparkStatTile(
                modifier = m,
                label = "HRV",
                value = d?.avgHrv?.let { "${it.roundToInt()}" } ?: NO_DATA,
                caption = d?.avgHrv?.let { "ms" },
                accent = d?.avgHrv?.let { Palette.metricPurple } ?: Palette.textTertiary,
                spark = w.hrv,
                sparkColor = Palette.metricPurple,
            )
        },
        { m ->
            SparkStatTile(
                modifier = m,
                label = "Resting HR",
                value = d?.restingHr?.toString() ?: NO_DATA,
                caption = d?.restingHr?.let { "bpm" },
                accent = d?.restingHr?.let { Palette.metricRose } ?: Palette.textTertiary,
                spark = w.rhr,
                sparkColor = Palette.metricRose,
            )
        },
        { m ->
            SparkStatTile(
                modifier = m,
                label = "Blood Oxygen",
                value = d?.spo2Pct?.let { String.format(Locale.US, "%.0f%%", it) } ?: NO_DATA,
                caption = d?.spo2Pct?.let { "SpO₂" },
                accent = d?.spo2Pct?.let { Palette.metricCyan } ?: Palette.textTertiary,
                spark = w.spo2,
                sparkColor = Palette.metricCyan,
            )
        },
        { m ->
            SparkStatTile(
                modifier = m,
                label = "Respiratory",
                value = d?.respRateBpm?.let { String.format(Locale.US, "%.1f", it) } ?: NO_DATA,
                caption = d?.respRateBpm?.let { "rpm" },
                accent = d?.respRateBpm?.let { Palette.accent } ?: Palette.textTertiary,
                spark = w.resp,
                sparkColor = Palette.accent,
            )
        },
        { m ->
            SparkStatTile(
                modifier = m,
                label = "Steps",
                value = NO_DATA,
                caption = "not connected",
                accent = Palette.textTertiary,
                spark = emptyList(),
                sparkColor = Palette.metricCyan,
            )
        },
        { m ->
            SparkStatTile(
                modifier = m,
                label = "Weight",
                value = NO_DATA,
                caption = "not connected",
                accent = Palette.textTertiary,
                spark = emptyList(),
                sparkColor = Palette.accent,
            )
        },
        { m ->
            SparkStatTile(
                modifier = m,
                label = "Calories",
                value = NO_DATA,
                caption = "not connected",
                accent = Palette.textTertiary,
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

// MARK: - Today footer sections

private data class TodayFooterState(
    val recentWorkouts: List<WorkoutRow> = emptyList(),
    val whoopDays: Int? = null,
    val whoopWorkouts: Int? = null,
    val appleDays: Int? = null,
    val appleWorkouts: Int? = null,
    val hcDays: Int? = null,
    val hcWorkouts: Int? = null,
)

@Composable
private fun TodayWorkoutsSection(workouts: List<WorkoutRow>) {
    if (workouts.isEmpty()) return

    SectionHeader("Last Workouts", overline = "Activity", trailing = "14 days")
    Column(verticalArrangement = Arrangement.spacedBy(Metrics.gap)) {
        workouts.take(4).chunked(2).forEach { rowWorkouts ->
            Row(horizontalArrangement = Arrangement.spacedBy(Metrics.gap)) {
                rowWorkouts.forEach { workout ->
                    StatTile(
                        modifier = Modifier.weight(1f),
                        label = workout.sport,
                        value = workoutDuration(workout),
                        caption = workoutCaption(workout),
                        accent = workout.strain?.let { Palette.strainColor(it) } ?: Palette.textPrimary,
                        delta = workout.energyKcal?.let { "${it.roundToInt()} kcal" },
                        deltaColor = Palette.metricAmber,
                    )
                }
                if (rowWorkouts.size == 1) Spacer(Modifier.weight(1f))
            }
        }
    }
}

@Composable
private fun TodaySourcesSection(footer: TodayFooterState) {
    SectionHeader("Data Sources", overline = "Provenance")
    NoopCard {
        Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
            SourceRow(
                badge = "Whoop",
                tint = Palette.accent,
                present = (footer.whoopDays ?: 0) > 0,
                detail = countDetail(footer.whoopDays, footer.whoopWorkouts, "workouts"),
            )
            Box(
                modifier = Modifier
                    .fillMaxWidth()
                    .height(1.dp)
                    .background(Palette.hairline),
            )
            SourceRow(
                badge = "Apple Health",
                tint = Palette.metricCyan,
                present = (footer.appleDays ?: 0) > 0 || (footer.appleWorkouts ?: 0) > 0,
                detail = countDetail(footer.appleDays, footer.appleWorkouts, "workouts"),
            )
            Box(
                modifier = Modifier
                    .fillMaxWidth()
                    .height(1.dp)
                    .background(Palette.hairline),
            )
            SourceRow(
                badge = "Health Connect",
                tint = Palette.metricPurple,
                present = (footer.hcDays ?: 0) > 0 || (footer.hcWorkouts ?: 0) > 0,
                detail = countDetail(footer.hcDays, footer.hcWorkouts, "workouts"),
            )
        }
    }
}

@Composable
private fun SourceRow(
    badge: String,
    tint: Color,
    present: Boolean,
    detail: String,
) {
    Row(verticalAlignment = Alignment.CenterVertically) {
        SourceBadge(badge, tint = if (present) tint else Palette.textTertiary)
        Spacer(Modifier.weight(1f))
        Text(
            text = if (present) detail else "Not connected",
            style = NoopType.captionNumber,
            color = if (present) Palette.textSecondary else Palette.textTertiary,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
        )
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
private fun ReadinessSection(days: List<DailyMetric>) {
    val todayKey = java.time.LocalDate.now().toString()
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
 * Build the 14-day windows from `recentDays`. Each series drops null days from the
 * trailing calendar window only, so stale imports do not draw a current-day trend.
 */
@Composable
private fun remember14(days: List<com.noop.data.DailyMetric>): Window =
    androidx.compose.runtime.remember(days) {
        // Trailing 14 CALENDAR days ending today — NOT the last 14 stored rows, which on an old import
        // were months-old data shown as a "14-day trend" (issue #23). ISO yyyy-MM-dd sorts chronologically.
        val cutoff = java.time.LocalDate.now().minusDays(13).toString()
        val recent = days.filter { it.day >= cutoff }
        fun series(pick: (DailyMetric) -> Double?): List<Double> = recent.mapNotNull(pick)
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
        ?: return "No metrics yet. Import your WHOOP export or wear the strap to begin."
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
    val hrv = d?.avgHrv?.let { "${it.roundToInt()} ms" } ?: NO_DATA
    val rhr = d?.restingHr?.toString() ?: NO_DATA
    return "HRV $hrv · RHR $rhr"
}

private fun sleepValue(d: DailyMetric?): String {
    val m = d?.totalSleepMin ?: return NO_DATA
    val total = m.roundToInt()
    return "${total / 60}h ${total % 60}m"
}

private const val NO_DATA = "No Data"

private val workoutDateFmt: DateTimeFormatter =
    DateTimeFormatter.ofPattern("d MMM", Locale.US).withZone(ZoneId.systemDefault())

private fun countDetail(days: Int?, workouts: Int?, workoutLabel: String): String {
    if (days == null || workouts == null) return "Counting..."
    return "${grouped(days)} days · ${grouped(workouts)} $workoutLabel"
}

private fun workoutDuration(row: WorkoutRow): String {
    val seconds = row.durationS ?: (row.endTs - row.startTs).coerceAtLeast(0L).toDouble()
    if (seconds <= 0.0) return NO_DATA
    val totalMinutes = (seconds / 60.0).roundToInt()
    return if (totalMinutes >= 60) {
        "${totalMinutes / 60}h ${totalMinutes % 60}m"
    } else {
        "${totalMinutes}m"
    }
}

private fun workoutCaption(row: WorkoutRow): String {
    val date = workoutDateFmt.format(Instant.ofEpochSecond(row.startTs))
    return row.avgHr?.let { "$date · $it bpm" } ?: date
}

private fun grouped(value: Int): String =
    String.format(Locale.US, "%,d", value)
