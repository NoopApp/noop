package com.noop.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
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
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.noop.analytics.Baselines
import com.noop.analytics.ReadinessEngine
import com.noop.data.AppleDaily
import com.noop.data.DailyMetric
import com.noop.data.WorkoutRow
import com.noop.ingest.HealthConnectImporter
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
    val live by viewModel.live.collectAsStateWithLifecycle()
    var footer by remember { mutableStateOf(TodayFooterState()) }
    var selectedDayOffset by remember { mutableIntStateOf(0) }
    // Anchor offset-0 to the LOGICAL day (rolls at 04:00 local), so between midnight and 4am "Today"
    // still resolves to the prior calendar day's banked row instead of an empty new-calendar-day row
    // that blanks the dashboard (#144). Past offsets count back from this anchor. Presentation-only.
    val todayDate = logicalDayNow()
    val selectedDay = remember(selectedDayOffset, todayDate) { todayDate.minusDays(selectedDayOffset.toLong()) }
    val selectedDayKey = remember(selectedDay) { selectedDay.toString() }
    val historicalMetric = remember(days, selectedDayKey) { days.lastOrNull { it.day == selectedDayKey } }
    val displayMetric = remember(today, historicalMetric, selectedDayOffset) {
        if (selectedDayOffset == 0) today ?: historicalMetric else historicalMetric
    }
    // Keep the explicit calendar date visible alongside Today/Yesterday so the logical-day remap stays
    // honest — between midnight and 04:00 "Today" still points at the prior calendar date, and showing
    // that date makes it obvious which day's row is on screen (#144).
    val dayLabel = remember(selectedDayOffset, selectedDay) {
        val date = selectedDay.format(DateTimeFormatter.ofPattern("EEE, d MMM", Locale.US))
        when (selectedDayOffset) {
            0 -> "Today · $date"
            1 -> "Yesterday · $date"
            else -> date
        }
    }
    val synthesisTitle = remember(selectedDayOffset) {
        when (selectedDayOffset) {
            0 -> "Today's Synthesis"
            1 -> "Yesterday's Synthesis"
            else -> "Synthesis"
        }
    }

    // Display-only unit system + the SI profile weight, read once like every other Settings-backed
    // preference (SharedPreferences isn't reactive — a Settings write triggers recomposition).
    val context = LocalContext.current
    val unitSystem = UnitPrefs.system(context)
    val profileWeightKg = remember { ProfileStore.from(context).weightKg }

    // The newest Apple Health / Health Connect body weight, loaded off the main thread. Null until the
    // load runs or when neither source carries a weight — the Weight tile then falls back to the profile.
    var weightKg by remember { mutableStateOf<Double?>(null) }
    LaunchedEffect(days) {
        weightKg = latestWeightKg(
            viewModel.repo.appleDaily("apple-health", "0000-01-01", "9999-12-31"),
            viewModel.repo.appleDaily("health-connect", "0000-01-01", "9999-12-31"),
        )
    }

    // Steps for the selected day from imported Apple Health / Health Connect data — the Today Steps
    // tile's fallback when the strap itself didn't bank an on-device count. A WHOOP 4.0 DOES count
    // steps (in the official WHOOP app), but NOOP can't yet read them off the strap over Bluetooth, so
    // on a 4.0 the tile shows your imported steps instead of "No Data". Reloads as the day selector
    // moves. On-device WHOOP 5/MG steps still take precedence. (#150)
    var importedStepsForDay by remember { mutableStateOf<Int?>(null) }
    LaunchedEffect(days, selectedDayKey) {
        // Today's steps keep moving after the manual one-shot HC import, so the stored row goes
        // stale within minutes — top it up with ONE live StepsRecord read before the stored-row
        // read below. Best-effort: any HC hiccup just falls through to whatever is stored. (#150)
        if (selectedDayOffset == 0) {
            try {
                HealthConnectImporter.refreshTodaySteps(context, viewModel.repo)
            } catch (_: Exception) { /* best-effort */ }
        }
        importedStepsForDay = stepsForDay(
            viewModel.repo.appleDaily("apple-health", "0000-01-01", "9999-12-31"),
            viewModel.repo.appleDaily("health-connect", "0000-01-01", "9999-12-31"),
            selectedDayKey,
        )
    }

    // Recovery cold-start: recovery is null until the HRV baseline crosses the seed gate
    // (Baselines.minNightsSeed valid nights). Show honest "calibrating — N of 4 nights" progress
    // instead of a bare "No Data" so a new BLE-only user knows scores are coming, not broken. (PR #85)
    val recoveryCalibration: Int? = if (selectedDayOffset == 0) {
        recoveryCalibrationNights(days, displayMetric?.recovery != null)
    } else {
        null
    }

    // 14-day trailing calendar window ending on the phone's actual local day.
    // Old imports stay in history, but they do not fill the Today trend tiles.
    val window = remember14(days, selectedDay)

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
            // fillWorkoutHrFromStrap: imported sessions carry no HR — derive it from strap samples (#77).
            recentWorkouts = viewModel.repo.fillWorkoutHrFromStrap(
                (viewModel.repo.workouts("my-whoop", recentCutoff, now) +
                    viewModel.repo.workouts("apple-health", recentCutoff, now) +
                    viewModel.repo.workouts("health-connect", recentCutoff, now))
                    .sortedByDescending { it.startTs }
            ),
            whoopDays = days.size,
            whoopWorkouts = whoopWorkouts.size,
            appleDays = appleDaysCount,
            appleWorkouts = appleWorkouts.size,
            hcDays = hcDaysCount,
            hcWorkouts = hcWorkouts.size,
        )
    }

    ScreenScaffold(title = "Control Center", subtitle = "Your day, read in full") {
        DaySelectorBar(selectedOffset = selectedDayOffset, onSelect = { selectedDayOffset = it })

        // When there is no daily score yet (today's recovery is null / no history),
        // lead with the "live now, history one import away" note so the empty tiles
        // below are explained rather than just dashed out.
        if (displayMetric?.recovery == null) {
            // While the strap is mid-offload, say so — empty tiles read as final otherwise (#77).
            if (live.backfilling) SyncingHistoryNote(chunks = live.syncChunksThisSession)
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
                SectionHeader(synthesisTitle, overline = dayLabel, trailing = greetingWord())
            }
            IconButton(
                onClick = onSupport,
                modifier = Modifier.size(Metrics.iconButton),
            ) {
                Icon(
                    Icons.Filled.Favorite,
                    contentDescription = "Support NOOP",
                    tint = Palette.textTertiary,
                    modifier = Modifier.size(Metrics.iconSmall),
                )
            }
        }
        Row(horizontalArrangement = Arrangement.spacedBy(Metrics.gap)) {
            NoopCard(modifier = Modifier.weight(1f)) {
                Box(modifier = Modifier.fillMaxWidth(), contentAlignment = Alignment.Center) {
                    TodayRecoveryRing(displayMetric, recoveryCalibration)
                }
            }
            InsightCard(
                modifier = Modifier.weight(1f),
                category = "Charge",
                status = if (recoveryCalibration != null) "Calibrating" else synthesisWord(displayMetric?.recovery),
                detail = if (recoveryCalibration != null) {
                    "Learning your baseline — $recoveryCalibration of ${Baselines.minNightsSeed} nights."
                } else {
                    synthesisDetail(displayMetric)
                },
                statusColor = displayMetric?.recovery?.let { Palette.recoveryColor(it) } ?: Palette.textTertiary,
            )
        }

        // READINESS — on-device training-readiness synthesis (HRV / resting-HR / load).
        // Mirrors the macOS readinessSection: rendered only once there's enough history.
        if (selectedDayOffset == 0) ReadinessSection(days)

        // METRICS — uniform tile grid (two columns), each tile with a 14-day sparkline.
        Spacer(Modifier.height(Metrics.selectorTopUp))
        SectionHeader("Key Metrics", overline = dayLabel, trailing = "14-day trend")
        MetricGrid(displayMetric, window, recoveryCalibration, unitSystem, weightKg, profileWeightKg, importedStepsForDay)
        HeartRateTrendCard(viewModel, days, selectedDay, todayDate)
        TodayWorkoutsSection(footer.recentWorkouts)
        // Honest, dismissible 12-hourly donation ask — a card in the flow, never a dialog.
        DonationNudgeCard()
        // Strap battery only while the link is up AND a real reading exists — a stale % from a
        // dropped connection must not present as live (#159).
        TodaySourcesSection(footer, strapBatteryPct = if (live.connected) live.batteryPct?.roundToInt() else null)
    }
}

@Composable
private fun DaySelectorBar(selectedOffset: Int, onSelect: (Int) -> Unit) {
    ThreeDaySelectorBar(selectedOffset = selectedOffset, onSelect = onSelect)
}

@Composable
private fun TodayRecoveryRing(day: DailyMetric?, calibratingNights: Int? = null) {
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
                    text = if (calibratingNights != null) "Calibrating" else NO_DATA,
                    style = NoopType.title2,
                    color = Palette.textTertiary,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
                Text(
                    text = calibratingNights?.let { "$it of ${Baselines.minNightsSeed} nights" }
                        ?: ringSupporting(day),
                    style = NoopType.footnote,
                    color = Palette.textSecondary,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                    modifier = Modifier.padding(top = Metrics.space4),
                )
            }
        }
    }
}

/**
 * Recent nights carrying a usable nightly HRV — the signal that seeds the recovery baseline. While
 * recovery is still null and this count is in [1, seed), it is the honest "calibrating N of <seed>"
 * progress shown in place of "No Data"; null once recovery exists or no night has data yet. Pure +
 * unit-tested (RecoveryCalibrationTest). Mirrors Baselines.minNightsSeed as the seed gate. (PR #85)
 */
internal fun recoveryCalibrationNights(
    days: List<DailyMetric>,
    hasRecovery: Boolean,
    seed: Int = Baselines.minNightsSeed,
): Int? {
    if (hasRecovery) return null
    // Match the baseline's validity predicate, not just non-null: Baselines.update only advances the
    // recovery seed (nValid) for nights whose avgHrv is within the HRV config bounds, so an implausible
    // out-of-range night must NOT be counted here either — else the displayed N could over-state nValid.
    val cfg = Baselines.hrvCfg
    return days.count { val v = it.avgHrv; v != null && v in cfg.minVal..cfg.maxVal }
        .takeIf { it in 1 until seed }
}

/**
 * The full 14-day metric grid, mirroring the macOS LazyVGrid order:
 * Charge, Effort, Rest, HRV, Resting HR, Blood Oxygen, Respiratory,
 * Steps, Weight, Calories. Each tile is a fixed-height [SparkStatTile] so the
 * grid tiles perfectly with no empty cells.
 */
@Composable
private fun MetricGrid(
    d: DailyMetric?,
    w: Window,
    recoveryCalibration: Int? = null,
    unitSystem: UnitSystem = UnitSystem.METRIC,
    latestWeightKg: Double? = null,
    profileWeightKg: Double = 75.0,
    importedStepsForDay: Int? = null,
) {
    val tiles = listOf<@Composable (Modifier) -> Unit>(
        { m ->
            SparkStatTile(
                modifier = m,
                label = "Charge",
                value = d?.recovery?.let { "${it.roundToInt()}%" }
                    ?: recoveryCalibration?.let { "$it/${Baselines.minNightsSeed}" } ?: NO_DATA,
                caption = d?.recovery?.let {
                    Palette.recoveryState(it).lowercase().replaceFirstChar { c -> c.uppercase() }
                } ?: recoveryCalibration?.let { "Calibrating" },
                accent = d?.recovery?.let { Palette.recoveryColor(it) } ?: Palette.textTertiary,
                spark = w.recovery,
                sparkColor = Palette.accent,
            )
        },
        { m ->
            SparkStatTile(
                modifier = m,
                label = "Effort",
                value = d?.strain?.let { String.format(Locale.US, "%.1f", it) } ?: NO_DATA,
                caption = d?.strain?.let { "of 100" },
                accent = d?.strain?.let { Palette.strainColor(it) } ?: Palette.textTertiary,
                spark = w.strain,
                sparkColor = Palette.strain066,
            )
        },
        { m ->
            SparkStatTile(
                modifier = m,
                label = "Rest",
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
            // Steps: prefer the on-device WHOOP 5/MG @57 counter (DailyMetric.steps); if the strap
            // didn't supply one — e.g. a WHOOP 4.0, which counts steps in the official WHOOP app but
            // doesn't expose them to NOOP over Bluetooth — fall back to the steps imported from Apple
            // Health / Health Connect for the day, instead of "No Data". (#107, #150)
            val steps = d?.steps ?: importedStepsForDay
            SparkStatTile(
                modifier = m,
                label = "Steps",
                value = steps?.let { intString(it.toDouble()) } ?: NO_DATA,
                caption = steps?.let { "steps" }, // neutral: the day selector can show past days
                accent = steps?.let { Palette.metricCyan } ?: Palette.textTertiary,
                spark = emptyList(),
                sparkColor = Palette.metricCyan,
            )
        },
        { m ->
            // Latest Apple Health / Health Connect body weight, else the SI profile weight (#107). The
            // caption stays honest — "from profile" only when we fell back. Always shown in the user's
            // chosen units via the shared UnitFormatter (matches AppleHealthScreen's weight tile).
            val weight = weightTile(latestWeightKg, profileWeightKg, unitSystem)
            SparkStatTile(
                modifier = m,
                label = "Weight",
                value = weight.value,
                caption = weight.caption,
                accent = Palette.accent,
                spark = emptyList(),
                sparkColor = Palette.accent,
            )
        },
        { m ->
            // On-device APPROXIMATE whole-day active+resting energy from HR alone (DailyMetric
            // .activeKcalEst). A heart-rate estimate, not cloud/clinical parity — shown rounded. (#107)
            SparkStatTile(
                modifier = m,
                label = "Calories",
                value = d?.activeKcalEst?.let { "${intString(it)} kcal" } ?: NO_DATA,
                caption = d?.activeKcalEst?.let { "active · est." },
                accent = d?.activeKcalEst?.let { Palette.metricAmber } ?: Palette.textTertiary,
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

// MARK: - Heart-rate trend (today's continuous HR off the strap's own ~1Hz history)
//
// A full-width 24h HR trend, plotted from 5-minute bucket means of the strap's hrSample history
// (offloaded even while the app was closed, so the day reads continuously). Hidden until there are at
// least two buckets, so a strap-only user with no wear today sees nothing rather than an empty chart.
// Mirrors the macOS TodayView.heartRateTrendSection. LineChart spaces points by index (no time axis),
// so the buckets — being uniform 5-min means in time order — read as an even left-to-right day curve.

@Composable
private fun HeartRateTrendCard(
    viewModel: AppViewModel,
    days: List<DailyMetric>,
    selectedDay: LocalDate,
    today: LocalDate,
) {
    // "Today" here is the LOGICAL day (rolls at 04:00 local), so in the small hours after midnight the
    // trend keeps the evening's curve — window start at the logical day's own midnight, "since midnight"
    // subtitle, "Today" label — rather than blanking to an empty new-calendar-day axis (#144).
    var buckets by remember { mutableStateOf<List<Double>>(emptyList()) }
    // Re-load when the day list changes (a sync/import updates it), and on first composition.
    LaunchedEffect(days, selectedDay, today) {
        val zone = ZoneId.systemDefault()
        val start = selectedDay.atStartOfDay(zone).toEpochSecond()
        val nextStart = selectedDay.plusDays(1).atStartOfDay(zone).toEpochSecond()
        val now = System.currentTimeMillis() / 1000
        val end = if (selectedDay == today) now else (nextStart - 1)
        buckets = viewModel.repo.hrBuckets("my-whoop", start, end, 300L).map { it.avgBpm }
    }
    if (buckets.size < 2) return

    val latest = buckets.last().roundToInt()
    val min = buckets.min().roundToInt()
    val max = buckets.max().roundToInt()
    val avg = buckets.average().roundToInt()

    val selectedLabel = when (selectedDay) {
        today -> "Today"
        today.minusDays(1) -> "Yesterday"
        else -> selectedDay.format(DateTimeFormatter.ofPattern("d MMM", Locale.US))
    }

    SectionHeader("Heart Rate", overline = selectedLabel)
    NoopCard {
        Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
            // Header — mirrors the macOS ChartCard (title + subtitle, trailing read-out).
            Row(verticalAlignment = Alignment.Top) {
                Column(modifier = Modifier.weight(1f)) {
                    Overline("Beats per minute")
                    val subtitle = if (selectedDay == today) {
                        "5-minute average | since midnight"
                    } else {
                        "5-minute average | selected day"
                    }
                    Text(
                        subtitle,
                        style = NoopType.footnote,
                        color = Palette.textTertiary,
                    )
                }
                Text("$latest bpm", style = NoopType.chartValueLarge, color = Palette.metricRose)
            }
            LineChart(
                values = buckets,
                modifier = Modifier.height(Metrics.chartHeight),
                color = Palette.metricRose,
                fill = true,
                selectionEnabled = true,
            )
            Box(
                modifier = Modifier
                    .fillMaxWidth()
                    .height(Metrics.divider)
                    .background(Palette.hairline),
            )
            Row(modifier = Modifier.fillMaxWidth()) {
                listOf("Min" to min, "Avg" to avg, "Max" to max).forEach { (label, value) ->
                    Column(modifier = Modifier.weight(1f)) {
                        Overline(label, color = Palette.textTertiary)
                        Text("$value", style = NoopType.bodyNumber, color = Palette.textPrimary)
                    }
                }
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
private fun TodaySourcesSection(footer: TodayFooterState, strapBatteryPct: Int? = null) {
    SectionHeader("Data Sources", overline = "Provenance")
    NoopCard {
        Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
            SourceRow(
                badge = "Whoop",
                tint = Palette.accent,
                // A live battery reading means the strap IS connected, even before the first banked
                // night — don't contradict it with "Not connected" (#159).
                present = (footer.whoopDays ?: 0) > 0 || strapBatteryPct != null,
                detail = countDetail(footer.whoopDays, footer.whoopWorkouts, "workouts"),
                batteryPct = strapBatteryPct,
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
    batteryPct: Int? = null,
) {
    Row(verticalAlignment = Alignment.CenterVertically) {
        SourceBadge(badge, tint = if (present) tint else Palette.textTertiary)
        // Compact strap-battery readout beside the source badge — same pill + tone bands as the
        // Settings Strap section; absent entirely when there's no live reading (#159).
        batteryPct?.let { pct ->
            Spacer(Modifier.width(8.dp))
            StatePill(title = "$pct%", tone = batteryPillTone(pct), showsDot = false)
        }
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
    // Logical day (rolls at 04:00 local), so readiness keeps reading the evening's row in the small
    // hours instead of an empty new-calendar-day row (#144). Mirrors the Today-row resolution.
    val todayKey = logicalDayKeyNow()
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
    NoopCard(modifier = modifier.height(Metrics.tileHeight), padding = Metrics.space14) {
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
                        style = NoopType.tileValueLarge,
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
                            modifier = Modifier.padding(top = Metrics.space2),
                        )
                    }
                }
                if (spark.size >= 2) {
                    // Sparkline forces fillMaxWidth + a fixed height internally, so we
                    // bound it in a sized Box to keep it a compact inline trend.
                    SparkTailBox(wide = true) {
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
    val shape = RoundedCornerShape(Metrics.cornerSm)
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .background(Palette.statusWarning.copy(alpha = StrandAlpha.warningFill), shape)
            .border(Metrics.divider, Palette.statusWarning.copy(alpha = StrandAlpha.warningBorder), shape)
            .padding(Metrics.space14),
        horizontalArrangement = Arrangement.spacedBy(Metrics.space10),
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
private fun remember14(days: List<com.noop.data.DailyMetric>, anchorDay: LocalDate): Window =
    androidx.compose.runtime.remember(days, anchorDay) {
        // Trailing 14 CALENDAR days ending today — NOT the last 14 stored rows, which on an old import
        // were months-old data shown as a "14-day trend" (issue #23). ISO yyyy-MM-dd sorts chronologically.
        val cutoff = anchorDay.minusDays(13).toString()
        val end = anchorDay.toString()
        val recent = days.filter { it.day >= cutoff && it.day <= end }
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
        rec < 50 -> "Charge is low"
        rec < 70 -> "Charge is steady"
        else -> "Charge is strong"
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

// MARK: - Steps / Weight / Calories tile logic (issue #107)
//
// Steps and Calories read straight off today's DailyMetric (the on-device WHOOP5 derivations); the
// pure helpers below back the Weight tile, which has no daily strap source and instead falls back to
// the user's profile weight. Kept pure + file-internal so TodayMetricTilesTest is the oracle.

/** The Weight tile's display string and an honest caption ("from profile" only on fallback). */
internal data class WeightTileText(val value: String, val caption: String?)

/**
 * The newest body weight across the two Apple-side sources (apple-health + health-connect), or null
 * when neither carries one. Days are ISO `yyyy-MM-dd`, which sorts chronologically, so the lexically
 * greatest day with a non-null `weightKg` is the most recent — no date parsing needed. (#107)
 */
internal fun latestWeightKg(apple: List<AppleDaily>, healthConnect: List<AppleDaily>): Double? =
    (apple + healthConnect)
        .filter { it.weightKg != null }
        .maxByOrNull { it.day }
        ?.weightKg

/**
 * Steps for [dayKey] from the imported Apple Health / Health Connect daily aggregates, or null when
 * neither source carries a step total for that day. Backs the Today Steps-tile fallback for straps
 * NOOP can't read steps off over Bluetooth — notably the WHOOP 4.0, which DOES count steps (in the
 * official WHOOP app) but doesn't expose them to NOOP — so on a 4.0 the tile shows imported steps
 * rather than "No Data". On-device WHOOP 5/MG steps (DailyMetric.steps) still take precedence at the
 * call site. When both sources report the same day, the larger (most-complete) total wins so we never
 * sum and double-count. Mirrors the macOS TodayView, which already falls back to imported steps. (#150)
 */
internal fun stepsForDay(apple: List<AppleDaily>, healthConnect: List<AppleDaily>, dayKey: String): Int? =
    (apple + healthConnect)
        .filter { it.day == dayKey }
        .mapNotNull { it.steps }
        .maxOrNull()

/**
 * Resolve the Weight tile text: prefer the latest Apple/Health-Connect weight, else fall back to the
 * SI profile weight with a "from profile" caption so the source stays honest. Both are formatted
 * through the shared [UnitFormatter] so the Imperial/Metric toggle reaches this tile too. (#107)
 */
internal fun weightTile(latestWeightKg: Double?, profileWeightKg: Double, system: UnitSystem): WeightTileText =
    if (latestWeightKg != null) {
        WeightTileText(UnitFormatter.massFromKilograms(latestWeightKg, system), "latest")
    } else {
        WeightTileText(UnitFormatter.massFromKilograms(profileWeightKg, system), "from profile")
    }

/** Group-separated integer display from a Double (e.g. 12 345 steps), matching the Apple Health tiles. */
private fun intString(v: Double): String {
    val n = v.roundToInt()
    return if (kotlin.math.abs(n) >= 1000) String.format(Locale.US, "%,d", n) else "$n"
}

private const val NO_DATA = "No Data"

private val workoutDateFmt: DateTimeFormatter =
    DateTimeFormatter.ofPattern("d MMM", Locale.US).withZone(ZoneId.systemDefault())
private val workoutTimeFmt: DateTimeFormatter =
    DateTimeFormatter.ofPattern("HH:mm", Locale.US).withZone(ZoneId.systemDefault())

private fun countDetail(days: Int?, workouts: Int?, workoutLabel: String): String {
    if (days == null || workouts == null) return "Counting..."
    return "${grouped(days)} days · ${grouped(workouts)} $workoutLabel"
}

/** Same bands as the Settings Strap battery pill, so the % reads the same colour everywhere (#159). */
private fun batteryPillTone(pct: Int): StrandTone = when {
    pct <= 15 -> StrandTone.Critical
    pct <= 30 -> StrandTone.Warning
    else -> StrandTone.Positive
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

/** "d MMM · HH:mm–HH:mm" (#157); start-only when the end isn't after the start (zero/unknown span). */
private fun workoutCaption(row: WorkoutRow): String {
    val date = workoutDateFmt.format(Instant.ofEpochSecond(row.startTs))
    val start = workoutTimeFmt.format(Instant.ofEpochSecond(row.startTs))
    return if (row.endTs > row.startTs) {
        "$date · $start–${workoutTimeFmt.format(Instant.ofEpochSecond(row.endTs))}"
    } else {
        "$date · $start"
    }
}

private fun grouped(value: Int): String =
    String.format(Locale.US, "%,d", value)
