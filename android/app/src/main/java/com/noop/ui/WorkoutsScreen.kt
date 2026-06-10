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
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.ChevronLeft
import androidx.compose.material.icons.filled.ChevronRight
import androidx.compose.material.icons.filled.DirectionsBike
import androidx.compose.material.icons.filled.DirectionsRun
import androidx.compose.material.icons.filled.DirectionsWalk
import androidx.compose.material.icons.filled.FitnessCenter
import androidx.compose.material.icons.filled.Pool
import androidx.compose.material.icons.filled.Rowing
import androidx.compose.material.icons.filled.SelfImprovement
import androidx.compose.material.icons.filled.SportsBasketball
import androidx.compose.material.icons.filled.SportsGymnastics
import androidx.compose.material.icons.filled.SportsMartialArts
import androidx.compose.material.icons.filled.SportsSoccer
import androidx.compose.material.icons.filled.SportsTennis
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.Icon
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.OutlinedTextFieldDefaults
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
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
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.noop.data.WorkoutRow
import java.time.Instant
import java.time.LocalDate
import java.time.LocalTime
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import java.util.Locale
import kotlin.math.roundToInt

/**
 * Workouts — the activity log, instrument-grade and uniform. Ports the macOS
 * WorkoutsView (Strand/Screens/WorkoutsView.swift) onto the locked Android component
 * system (NoopCard / StatTile / SectionHeader / SegmentedPillControl / SourceBadge)
 * so every card, tile and row lines up:
 *
 *   - a range pill (7D / 30D / 90D / 1Y / All) that filters the loaded sessions,
 *   - a grid of summary StatTiles (count / time / calories / distance / most-active),
 *   - an "Activity Breakdown" of per-sport NoopCards with an identical internal layout,
 *   - an "All Sessions" NoopCard of fixed-height rows (date · sport · dur · HR · kcal ·
 *     dist · source).
 *
 * Sessions are loaded from BOTH cached sources — `repo.workouts("my-whoop", …)` and
 * `repo.workouts("apple-health", …)` — merged and shown newest first. The windowing is
 * anchored to the LATEST session (not "now"), so an old log still resolves; an empty
 * window auto-widens to the next larger range, exactly like the macOS screen.
 */
@Composable
fun WorkoutsScreen(vm: AppViewModel) {
    var allRows by remember { mutableStateOf<List<WorkoutRow>>(emptyList()) }
    var loaded by remember { mutableStateOf(false) }
    var range by remember { mutableStateOf(WorkoutRange.All) }
    // Bumped after every write (add/edit/delete/re-label/dismiss) so the list reloads.
    var reloadKey by remember { mutableStateOf(0) }
    var selected by remember { mutableStateOf<WorkoutRow?>(null) }
    var editing by remember { mutableStateOf<WorkoutRow?>(null) }
    var adding by remember { mutableStateOf(false) }
    val ctx = LocalContext.current

    // Load all sources. Whole history (epoch → now) per source, newest first.
    LaunchedEffect(reloadKey) {
        val now = System.currentTimeMillis() / 1000
        val whoop = vm.repo.workouts("my-whoop", 0L, now)
        // Detected bouts the analytics pipeline persists under "<id>-noop" — previously
        // invisible. Dismissals are a read-time filter: the IntelligenceEngine wipes and
        // re-derives detected rows every run, so deleting one would just resurrect it.
        val spans = parseDismissedSpans(NoopPrefs.dismissedDetected(ctx))
        val detected = vm.repo.workouts(vm.repo.computedDeviceId("my-whoop"), 0L, now)
            .filterNot { isDismissedDetected(it, spans) }
        // Apple Health export + Health Connect are separate sources (since #34) — include both.
        val apple = vm.repo.workouts("apple-health", 0L, now) +
            vm.repo.workouts("health-connect", 0L, now)
        // Imported sessions (Health Connect / Apple Health) carry no HR of their own — derive
        // avg/max from the strap's samples over each workout's window so they don't show "–" (#77).
        val merged = vm.repo.fillWorkoutHrFromStrap((whoop + detected + apple).sortedByDescending { it.startTs })
        allRows = merged
        loaded = true
        if (reloadKey == 0) range = defaultRange(merged)   // keep the user's range across reloads
    }

    ScreenScaffold(title = "Workouts", subtitle = "Every session, threaded together.") {
        // Retroactive logging is always reachable — including the empty state, where it is
        // the account-free user's only way to get a first workout in.
        AddWorkoutButton { adding = true }
        if (allRows.isEmpty()) {
            EmptyWorkouts(loaded)
        } else {
            // Resolve the effective range + windowed rows + per-sport groups once.
            val resolved = effectiveRange(allRows, range)
            val windowRows = sessions(allRows, resolved)
            val groups = sportGroups(windowRows)
            val fellBack = resolved != range

            RangeBar(
                range = range,
                effectiveRange = resolved,
                rowCount = windowRows.size,
                fellBack = fellBack,
                onSelect = { range = it },
            )
            SummarySection(rows = windowRows, effectiveRange = resolved, groups = groups)
            BreakdownSection(groups)
            ZonesSection(windowRows)
            SessionsSection(windowRows, onSelect = { selected = it })
        }
    }

    selected?.let { row ->
        WorkoutActionsDialog(
            row = row,
            onEdit = { editing = row; selected = null },
            onDelete = { vm.deleteWorkout(row) { reloadKey++ }; selected = null },
            onRelabel = { sport -> vm.relabelDetected(row, sport) { reloadKey++ }; selected = null },
            onDismissBout = { vm.dismissDetected(row) { reloadKey++ }; selected = null },
            onClose = { selected = null },
        )
    }
    if (adding || editing != null) {
        AddEditWorkoutDialog(
            initial = editing,
            onSave = { row ->
                vm.saveManualWorkout(row, replacing = editing) { reloadKey++ }
                adding = false; editing = null
            },
            onCancel = { adding = false; editing = null },
        )
    }
}

// MARK: - Add-workout entry point (chip-style, matches RefreshModelsButton's idiom)

@Composable
private fun AddWorkoutButton(onClick: () -> Unit) {
    val shape = RoundedCornerShape(50)
    Row(modifier = Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.End) {
        Row(
            modifier = Modifier
                .clip(shape)
                .background(Palette.surfaceInset)
                .border(1.dp, Palette.hairline, shape)
                .clickable(onClick = onClick)
                .padding(horizontal = 14.dp, vertical = 8.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(6.dp),
        ) {
            Icon(Icons.Filled.Add, contentDescription = null, tint = Palette.accent, modifier = Modifier.size(14.dp))
            Text("Add workout", style = NoopType.caption, color = Palette.accent)
        }
    }
}

// MARK: - Empty / loading state

@Composable
private fun EmptyWorkouts(loaded: Boolean) {
    DataPendingNote(
        title = "No workouts yet",
        body = "No workouts yet. They come from your WHOOP and Apple Health history. " +
            "Import in Data Sources to bring them in.",
    )
}

// MARK: - Range control

@Composable
private fun RangeBar(
    range: WorkoutRange,
    effectiveRange: WorkoutRange,
    rowCount: Int,
    fellBack: Boolean,
    onSelect: (WorkoutRange) -> Unit,
) {
    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
        Row(modifier = Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
            Spacer(Modifier.weight(1f))
            SegmentedPillControl(
                items = WorkoutRange.entries,
                selection = range,
                label = { it.label },
                onSelect = onSelect,
            )
        }
        val unit = if (rowCount == 1) "session" else "sessions"
        val caption = if (fellBack) {
            "$rowCount $unit · sparse — widened to ${effectiveRange.caption}"
        } else {
            "$rowCount $unit · ${effectiveRange.caption}"
        }
        Text(
            caption,
            style = NoopType.footnote,
            color = if (fellBack) Palette.statusWarning else Palette.textTertiary,
            modifier = Modifier.fillMaxWidth(),
        )
    }
}

// MARK: - Summary tiles (uniform StatTiles)

@Composable
private fun SummarySection(
    rows: List<WorkoutRow>,
    effectiveRange: WorkoutRange,
    groups: List<SportGroup>,
) {
    val totalCount = rows.size
    val totalTimeH = rows.mapNotNull { it.durationS }.sum() / 3600.0
    val totalKcal = rows.mapNotNull { it.energyKcal }.sum()
    val totalKm = rows.mapNotNull { it.distanceM }.sum() / 1000.0
    val modal = groups.firstOrNull()

    val tiles = listOf<@Composable (Modifier) -> Unit>(
        { m ->
            StatTile(
                modifier = m,
                label = "Total Workouts",
                value = "$totalCount",
                caption = effectiveRange.caption,
                accent = Palette.accent,
            )
        },
        { m ->
            StatTile(
                modifier = m,
                label = "Total Time",
                value = oneDecimal(totalTimeH) + "h",
                caption = "active",
                accent = Palette.textPrimary,
            )
        },
        { m ->
            StatTile(
                modifier = m,
                label = "Total Calories",
                value = grouped(totalKcal),
                caption = "kcal",
                accent = Palette.metricAmber,
            )
        },
        { m ->
            StatTile(
                modifier = m,
                label = "Total Distance",
                value = oneDecimal(totalKm) + " km",
                caption = "covered",
                accent = Palette.metricCyan,
            )
        },
        { m ->
            StatTile(
                modifier = m,
                label = "Most Active",
                value = modal?.sport ?: "–",
                caption = modal?.let { "${it.count} session${if (it.count == 1) "" else "s"}" },
                accent = Palette.textPrimary,
            )
        },
    )

    // Two-column grid so tile heights stay uniform on phone widths.
    Column(verticalArrangement = Arrangement.spacedBy(Metrics.gap)) {
        tiles.chunked(2).forEach { rowTiles ->
            Row(horizontalArrangement = Arrangement.spacedBy(Metrics.gap)) {
                rowTiles.forEach { tile -> tile(Modifier.weight(1f)) }
                if (rowTiles.size == 1) Spacer(Modifier.weight(1f))
            }
        }
    }
}

// MARK: - Activity breakdown (per-sport NoopCards, identical layout)

@Composable
private fun BreakdownSection(groups: List<SportGroup>) {
    Column(verticalArrangement = Arrangement.spacedBy(Metrics.gap)) {
        SectionHeader(
            title = "Activity Breakdown",
            overline = "By sport",
            trailing = "${groups.size} sport${if (groups.size == 1) "" else "s"}",
        )
        groups.forEach { SportCard(it) }
    }
}

@Composable
private fun SportCard(g: SportGroup) {
    NoopCard {
        Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
            // Identical header for every card.
            Row(verticalAlignment = Alignment.CenterVertically) {
                Icon(
                    sportIcon(g.sport),
                    contentDescription = null,
                    tint = Palette.accent,
                    modifier = Modifier.size(18.dp),
                )
                Spacer(Modifier.width(10.dp))
                Text(
                    g.sport,
                    style = NoopType.headline,
                    color = Palette.textPrimary,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                    modifier = Modifier.weight(1f),
                )
                Text("${g.count}", style = NoopType.number(15f), color = Palette.textSecondary)
            }
            CardDivider()
            // Identical 4-up stat strip for every card.
            Row(modifier = Modifier.fillMaxWidth()) {
                MiniStat("Sessions", "${g.count}", Modifier.weight(1f))
                MiniStat("Time", oneDecimal(g.totalTimeH) + "h", Modifier.weight(1f))
                MiniStat("Kcal", grouped(g.totalKcal), Modifier.weight(1f))
                MiniStat("Avg/sess", "${g.avgTimePerSessionMin.roundToInt()}m", Modifier.weight(1f))
            }
        }
    }
}

@Composable
private fun MiniStat(label: String, value: String, modifier: Modifier = Modifier) {
    Column(modifier = modifier, verticalArrangement = Arrangement.spacedBy(3.dp)) {
        Overline(label)
        Text(
            value,
            style = NoopType.number(15f),
            color = Palette.textPrimary,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
        )
    }
}

// MARK: - HR zones (imported per-workout zone split, one card)

@Composable
private fun ZonesSection(rows: List<WorkoutRow>) {
    val z = remember(rows) { zoneSummary(rows) } ?: return
    Column(verticalArrangement = Arrangement.spacedBy(Metrics.gap)) {
        SectionHeader(
            title = "HR Zones",
            overline = "Whoop import",
            trailing = "${z.sessionsWithZones} of ${rows.size} session${if (rows.size == 1) "" else "s"}",
        )
        NoopCard {
            Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
                // Proportional stacked bar — the Hypnogram geometry with zone colors.
                SegmentBar(
                    segments = z.minutes.mapIndexed { i, m ->
                        Palette.hrZoneColor(i + 1) to (m / z.totalMinutes).toFloat()
                    },
                    modifier = Modifier.fillMaxWidth(),
                    height = 24.dp,
                )
                CardDivider()
                // 5-up stat strip, identical rhythm to the sport cards' MiniStat row.
                Row(modifier = Modifier.fillMaxWidth()) {
                    z.minutes.forEachIndexed { i, m ->
                        ZoneStat(i + 1, m, z.totalMinutes, Modifier.weight(1f))
                    }
                }
                Text(
                    "Share of imported zone time, duration-weighted across sessions — approximate.",
                    style = NoopType.footnote,
                    color = Palette.textTertiary,
                )
            }
        }
    }
}

@Composable
private fun ZoneStat(zone: Int, minutes: Double, total: Double, modifier: Modifier = Modifier) {
    Column(modifier = modifier, verticalArrangement = Arrangement.spacedBy(3.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Box(
                Modifier
                    .size(9.dp)
                    .background(Palette.hrZoneColor(zone), RoundedCornerShape(2.dp)),
            )
            Spacer(Modifier.width(5.dp))
            Overline("Z$zone")
        }
        Text(
            "${(minutes / total * 100).roundToInt()}%",
            style = NoopType.number(15f),
            color = Palette.textPrimary,
            maxLines = 1,
        )
        Text(durationLabel(minutes * 60), style = NoopType.footnote, color = Palette.textTertiary, maxLines = 1)
    }
}

// MARK: - All sessions (one NoopCard, uniform fixed-height rows)

@Composable
private fun SessionsSection(rows: List<WorkoutRow>, onSelect: (WorkoutRow) -> Unit) {
    Column(verticalArrangement = Arrangement.spacedBy(Metrics.gap)) {
        SectionHeader(title = "All Sessions", overline = "Log", trailing = "${rows.size} total")
        NoopCard(padding = 0.dp) {
            Column {
                SessionHeaderRow()
                FullDivider()
                rows.forEachIndexed { idx, row ->
                    SessionRow(
                        row = row,
                        background = if (idx % 2 == 1) Palette.surfaceInset.copy(alpha = 0.4f) else Color.Transparent,
                        onSelect = onSelect,
                    )
                    if (idx != rows.lastIndex) FullDivider(alpha = 0.5f)
                }
            }
        }
    }
}

@Composable
private fun SessionHeaderRow() {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .height(34.dp)
            .padding(horizontal = Metrics.cardPadding),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        ColHeader("Date", Modifier.weight(1.4f), TextAlign.Start)
        ColHeader("Sport", Modifier.weight(1.6f), TextAlign.Start)
        ColHeader("Dur", Modifier.weight(1f), TextAlign.End)
        ColHeader("HR", Modifier.weight(0.9f), TextAlign.End)
        ColHeader("Kcal", Modifier.weight(1f), TextAlign.End)
        ColHeader("Src", Modifier.weight(1f), TextAlign.End)
    }
}

@Composable
private fun ColHeader(text: String, modifier: Modifier, align: TextAlign) {
    // Built from the overline style directly (not the Overline composable) so the
    // numeric columns can right-align their headers over the right-aligned cells.
    Text(
        text = text.uppercase(),
        style = NoopType.overline,
        color = Palette.textSecondary,
        textAlign = align,
        maxLines = 1,
        modifier = modifier,
    )
}

@Composable
private fun SessionRow(row: WorkoutRow, background: Color, onSelect: (WorkoutRow) -> Unit) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .background(background)
            .clickable { onSelect(row) }
            .height(48.dp)
            .padding(horizontal = Metrics.cardPadding),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        // Date + time.
        Column(modifier = Modifier.weight(1.4f)) {
            Text(dateLabel(row.startTs), style = NoopType.subhead, color = Palette.textPrimary, maxLines = 1)
            Text(timeLabel(row.startTs), style = NoopType.footnote, color = Palette.textTertiary, maxLines = 1)
        }
        // Sport ("detected" renders as "Activity" — the machine token never shows raw).
        Row(modifier = Modifier.weight(1.6f), verticalAlignment = Alignment.CenterVertically) {
            Icon(
                sportIcon(displaySport(row.sport)),
                contentDescription = null,
                tint = Palette.textSecondary,
                modifier = Modifier.size(14.dp),
            )
            Spacer(Modifier.width(7.dp))
            Text(
                displaySport(row.sport),
                style = NoopType.subhead,
                color = Palette.textPrimary,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
        }
        Cell(durationLabel(row.durationS), Modifier.weight(1f))
        Cell(
            row.avgHr?.toString() ?: "–",
            Modifier.weight(0.9f),
            color = if (row.avgHr != null) Palette.metricRose else null,
        )
        Cell(
            row.energyKcal?.let { grouped(it) } ?: "–",
            Modifier.weight(1f),
            color = if (row.energyKcal != null) Palette.metricAmber else null,
        )
        Box(modifier = Modifier.weight(1f), contentAlignment = Alignment.CenterEnd) {
            val (srcLabel, srcTint) = row.sourceBadge
            SourceBadge(srcLabel, tint = srcTint)
        }
    }
}

@Composable
private fun Cell(text: String, modifier: Modifier, color: Color? = null) {
    Text(
        text,
        style = NoopType.number(13f, androidx.compose.ui.text.font.FontWeight.Normal),
        color = color ?: if (text == "–") Palette.textTertiary else Palette.textPrimary,
        textAlign = TextAlign.End,
        maxLines = 1,
        modifier = modifier,
    )
}

// MARK: - Dividers

@Composable
private fun CardDivider() {
    Box(modifier = Modifier.fillMaxWidth().height(1.dp).background(Palette.hairline))
}

@Composable
private fun FullDivider(alpha: Float = 1f) {
    Box(modifier = Modifier.fillMaxWidth().height(1.dp).background(Palette.hairline.copy(alpha = alpha)))
}

// MARK: - Range model

private enum class WorkoutRange(val label: String, val caption: String, val days: Int?) {
    Week("7D", "last 7 days", 7),
    Month("30D", "last 30 days", 30),
    Quarter("90D", "last 90 days", 90),
    Year("1Y", "last year", 365),
    All("All", "all time", null),
}

/** This range plus every larger range, ascending — the auto-expand search order. */
private fun WorkoutRange.widening(): List<WorkoutRange> {
    val order = WorkoutRange.entries
    val i = order.indexOf(this)
    return if (i < 0) listOf(WorkoutRange.All) else order.subList(i, order.size)
}

/** Sessions inside a range, RELATIVE TO THE LATEST session. `All` = everything. */
private fun sessions(all: List<WorkoutRow>, r: WorkoutRange): List<WorkoutRow> {
    val days = r.days ?: return all
    val last = all.maxOfOrNull { it.startTs } ?: return emptyList()
    val cutoff = last - days * 86_400L
    return all.filter { it.startTs >= cutoff }
}

/** The range actually shown: the selected range if it holds ≥1 session, else the
 *  smallest larger range that does — so only an empty window widens. */
private fun effectiveRange(all: List<WorkoutRow>, selected: WorkoutRange): WorkoutRange {
    if (all.isEmpty()) return selected
    for (r in selected.widening()) {
        if (sessions(all, r).isNotEmpty()) return r
    }
    return WorkoutRange.All
}

/** Pick the tightest range that still holds ≥2 sessions; otherwise show All. */
private fun defaultRange(source: List<WorkoutRow>): WorkoutRange {
    val last = source.maxOfOrNull { it.startTs } ?: return WorkoutRange.All
    for (r in WorkoutRange.entries) {
        val days = r.days ?: continue
        val cutoff = last - days * 86_400L
        if (source.count { it.startTs >= cutoff } >= 2) return r
    }
    return WorkoutRange.All
}

// MARK: - Aggregation

private data class SportGroup(
    val sport: String,
    val count: Int,
    val totalTimeS: Double,
    val totalKcal: Double,
) {
    val totalTimeH: Double get() = totalTimeS / 3600.0
    val avgTimePerSessionMin: Double get() = if (count > 0) (totalTimeS / count) / 60.0 else 0.0
}

/** Sessions grouped by sport, ordered by count (desc), then total time. Detected bouts
 *  group under their display name ("Activity"), never the raw "detected" token. */
private fun sportGroups(rows: List<WorkoutRow>): List<SportGroup> =
    rows.groupBy { displaySport(it.sport) }
        .map { (sport, list) ->
            SportGroup(
                sport = sport,
                count = list.size,
                totalTimeS = list.sumOf { it.durationS ?: 0.0 },
                totalKcal = list.sumOf { it.energyKcal ?: 0.0 },
            )
        }
        .sortedWith(compareByDescending<SportGroup> { it.count }.thenByDescending { it.totalTimeS })

/**
 * The Src-column badge (label + tint) for a session. Sessions are loaded by their source's
 * deviceId — "my-whoop" / "apple-health" / "health-connect" — and each row also carries a `source`
 * label ("my-whoop" / "Apple Health" / "health-connect"), so we classify on both. This used to be a
 * binary `isWhoop ? "Whoop" : "Apple"`, which mislabelled EVERY Health Connect workout as "Apple"
 * (#53). "HC" is abbreviated to fit the narrow column (Apple is likewise short for "Apple Health");
 * the Data Sources and Today screens spell out "Health Connect". Tints match those screens: WHOOP
 * accent green, Apple cyan, Health Connect purple.
 */
/**
 * Pure source → short badge label. `internal` + Compose-free so the unit test can pin the three
 * stored origins ("my-whoop" / "apple-health"+"Apple Health" / "health-connect") to their labels
 * without dragging in Palette. This is the classification that used to be a binary
 * `isWhoop ? "Whoop" : "Apple"`, which mislabelled every Health Connect workout as "Apple" (#53).
 * Rows are loaded by deviceId, and also carry a `source` label, so we check both.
 */
internal fun workoutSourceLabel(deviceId: String, source: String): String {
    val id = deviceId.lowercase()
    val src = source.lowercase()
    return when {
        // "-noop" BEFORE the whoop check: the computed id ("my-whoop-noop") contains "whoop",
        // so the old order labelled the engine's detected bouts "Whoop".
        id.endsWith("-noop") || src.endsWith("-noop") -> "Detected"
        // v1.67 live-tracked + retro-logged rows: deviceId "my-whoop", source "manual".
        src == "manual" -> "Manual"
        id == "health-connect" || src.contains("health-connect") -> "HC"
        id.contains("whoop") || src.contains("whoop") -> "Whoop"
        else -> "Apple"
    }
}

// MARK: - Zone parsing/aggregation (internal + Compose-free so the unit test can pin them,
// same pattern as workoutSourceLabel). zonesJSON is a flat one-level numeric object in BOTH
// stored shapes — "zone1".."zone5" (WhoopCsvImporter.zonesJson) and "z1".."z5" (the macOS
// importer's rows) — so an anchored regex is safe, and it keeps org.json (an unmocked
// Android stub in plain-JVM unit tests) out of test-reachable code.

private val ZONE_KEY = Regex("\"z(?:one)?([1-5])\"\\s*:\\s*(-?[0-9]+(?:\\.[0-9]+)?(?:[eE][+-]?[0-9]+)?)")

/** Zone percentages (0–100) indexed Z1..Z5, or null when the row has no usable zone data. */
internal fun parseZonePercents(zonesJSON: String?): List<Double>? {
    if (zonesJSON.isNullOrBlank()) return null
    val out = MutableList(5) { 0.0 }
    var any = false
    for (m in ZONE_KEY.findAll(zonesJSON)) {
        val v = m.groupValues[2].toDoubleOrNull() ?: continue
        out[m.groupValues[1].toInt() - 1] = v.coerceIn(0.0, 100.0)
        any = true
    }
    return if (any && out.sum() > 0.0) out else null
}

internal data class ZoneSummary(val minutes: List<Double>, val sessionsWithZones: Int) {
    val totalMinutes: Double get() = minutes.sum()
}

/** Duration-weighted zone minutes across [rows] — mirrors the macOS WorkoutZones.summary
 *  (duration-minutes × pct ÷ 100). APPROXIMATE: an on-device aggregate of imported
 *  per-workout percentages, not a WHOOP-computed figure. */
internal fun zoneSummary(rows: List<WorkoutRow>): ZoneSummary? {
    val mins = MutableList(5) { 0.0 }
    var n = 0
    for (r in rows) {
        val p = parseZonePercents(r.zonesJSON) ?: continue
        val durMin = (r.durationS ?: (r.endTs - r.startTs).toDouble()) / 60.0
        if (durMin <= 0.0) continue
        for (i in 0 until 5) mins[i] += durMin * p[i] / 100.0
        n++
    }
    return if (n > 0 && mins.sum() > 0.0) ZoneSummary(mins, n) else null
}

/**
 * The Src-column badge (label + tint). "HC" is abbreviated to fit the narrow column (Apple is
 * likewise short for "Apple Health"); Data Sources / Today spell out "Health Connect". Tints match
 * those screens: WHOOP accent green, Apple cyan, Health Connect purple.
 */
private val WorkoutRow.sourceBadge: Pair<String, Color>
    get() = when (workoutSourceLabel(deviceId, source)) {
        "Detected" -> "Detected" to Palette.metricAmber
        "Manual" -> "Manual" to Palette.metricRose
        "HC" -> "HC" to Palette.metricPurple
        "Whoop" -> "Whoop" to Palette.accent
        else -> "Apple" to Palette.metricCyan
    }

// MARK: - Formatting

private val dateFmt: DateTimeFormatter =
    DateTimeFormatter.ofPattern("d MMM yyyy", Locale.US).withZone(ZoneId.systemDefault())
private val timeFmt: DateTimeFormatter =
    DateTimeFormatter.ofPattern("HH:mm", Locale.US).withZone(ZoneId.systemDefault())

private fun dateLabel(ts: Long): String = dateFmt.format(Instant.ofEpochSecond(ts))
private fun timeLabel(ts: Long): String = timeFmt.format(Instant.ofEpochSecond(ts))

private fun durationLabel(s: Double?): String {
    if (s == null || s <= 0.0) return "–"
    val total = s.roundToInt()
    val h = total / 3600
    val m = (total % 3600) / 60
    return if (h > 0) "${h}h ${m}m" else "${m}m"
}

private fun oneDecimal(v: Double): String = String.format(Locale.US, "%.1f", v)

private fun grouped(v: Double): String = String.format(Locale.US, "%,d", v.roundToInt())

// MARK: - Sport icons (Material equivalents of the SF Symbols used on macOS)

private fun sportIcon(sport: String): ImageVector {
    val s = sport.lowercase()
    return when {
        s.contains("run") -> Icons.Filled.DirectionsRun
        s.contains("walk") || s.contains("hike") -> Icons.Filled.DirectionsWalk
        s.contains("cycl") || s.contains("bike") || s.contains("ride") -> Icons.Filled.DirectionsBike
        s.contains("swim") -> Icons.Filled.Pool
        s.contains("row") -> Icons.Filled.Rowing
        s.contains("yoga") || s.contains("pilates") || s.contains("meditat") -> Icons.Filled.SelfImprovement
        s.contains("strength") || s.contains("weight") || s.contains("lift") -> Icons.Filled.FitnessCenter
        s.contains("box") || s.contains("martial") -> Icons.Filled.SportsMartialArts
        s.contains("hiit") || s.contains("functional") || s.contains("gymnast") -> Icons.Filled.SportsGymnastics
        s.contains("tennis") -> Icons.Filled.SportsTennis
        s.contains("soccer") || s.contains("football") -> Icons.Filled.SportsSoccer
        s.contains("basketball") -> Icons.Filled.SportsBasketball
        else -> Icons.Filled.FitnessCenter
    }
}

// MARK: - Row actions (manual: edit/delete · detected: re-label/dismiss · imported: read-only)

@Composable
private fun WorkoutActionsDialog(
    row: WorkoutRow,
    onEdit: () -> Unit,
    onDelete: () -> Unit,
    onRelabel: (String) -> Unit,
    onDismissBout: () -> Unit,
    onClose: () -> Unit,
) {
    var pickingSport by remember { mutableStateOf(false) }
    AlertDialog(
        onDismissRequest = onClose,
        containerColor = Palette.surfaceOverlay,
        title = {
            Text(
                "${displaySport(row.sport)} · ${dateLabel(row.startTs)}",
                style = NoopType.headline, color = Palette.textPrimary,
            )
        },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
                when {
                    pickingSport -> {
                        Text("What was this activity?", style = NoopType.subhead, color = Palette.textSecondary)
                        Spacer(Modifier.height(4.dp))
                        // The re-labelled copy becomes a first-class manual workout and the
                        // engine's dedupe stops re-deriving a detected bout over this span.
                        Column {
                            MANUAL_SPORTS.forEach { sport ->
                                Text(
                                    sport, style = NoopType.body, color = Palette.textPrimary,
                                    modifier = Modifier
                                        .fillMaxWidth()
                                        .clickable { onRelabel(sport) }
                                        .padding(vertical = 6.dp),
                                )
                            }
                        }
                    }
                    isManualWorkout(row) -> {
                        ActionRow("Edit workout", Palette.textPrimary, onEdit)
                        ActionRow("Delete workout", Palette.statusCritical, onDelete)
                    }
                    isDetectedWorkout(row) -> {
                        Text(
                            "NOOP detected this bout from your heart rate — duration and calories are approximate.",
                            style = NoopType.footnote, color = Palette.textTertiary,
                        )
                        Spacer(Modifier.height(4.dp))
                        ActionRow("Label this activity…", Palette.textPrimary) { pickingSport = true }
                        ActionRow("Dismiss from the log", Palette.statusCritical, onDismissBout)
                    }
                    else -> {
                        Text(
                            "Imported workouts are read-only — they mirror the source you imported them from.",
                            style = NoopType.footnote, color = Palette.textTertiary,
                        )
                    }
                }
            }
        },
        confirmButton = {},
        dismissButton = {
            TextButton(onClick = onClose) {
                Text("Close", style = NoopType.subhead, color = Palette.textSecondary)
            }
        },
    )
}

@Composable
private fun ActionRow(label: String, color: Color, onClick: () -> Unit) {
    Text(
        label, style = NoopType.body, color = color,
        modifier = Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(10.dp))
            .clickable(onClick = onClick)
            .padding(vertical = 10.dp, horizontal = 4.dp),
    )
}

// MARK: - Add / edit a manual workout (retroactive; strain stays null — no captured HR window)

@Composable
private fun AddEditWorkoutDialog(
    initial: WorkoutRow?,
    onSave: (WorkoutRow) -> Unit,
    onCancel: () -> Unit,
) {
    val zone = remember { ZoneId.systemDefault() }
    val initialStart = initial?.let { Instant.ofEpochSecond(it.startTs).atZone(zone) }
    var date by remember { mutableStateOf(initialStart?.toLocalDate() ?: LocalDate.now(zone)) }
    var timeMinutes by remember {
        mutableStateOf(initialStart?.let { it.hour * 60 + it.minute } ?: (LocalTime.now(zone).hour * 60))
    }
    var durationText by remember {
        mutableStateOf(initial?.durationS?.let { (it / 60).roundToInt().toString() } ?: "45")
    }
    var sport by remember { mutableStateOf(initial?.sport ?: "Running") }
    var sportMenu by remember { mutableStateOf(false) }
    var hrText by remember { mutableStateOf(initial?.avgHr?.toString() ?: "") }
    var kcalText by remember { mutableStateOf(initial?.energyKcal?.let { it.roundToInt().toString() } ?: "") }

    val today = LocalDate.now(zone)
    val startSec = date.atTime(timeMinutes / 60, timeMinutes % 60).atZone(zone).toEpochSecond()
    val built = buildManualWorkout(
        startSec = startSec,
        durationMin = durationText.toIntOrNull() ?: 0,
        sport = sport,
        avgHr = hrText.trim().toIntOrNull(),          // blank → null (optional field)
        energyKcal = kcalText.trim().toDoubleOrNull(), // blank → null (optional field)
    )
    val dateFmtLocal = remember { DateTimeFormatter.ofPattern("EEE d MMM", Locale.US) }

    AlertDialog(
        onDismissRequest = onCancel,
        containerColor = Palette.surfaceOverlay,
        title = {
            Text(
                if (initial == null) "Add workout" else "Edit workout",
                style = NoopType.headline, color = Palette.textPrimary,
            )
        },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
                // Date: ◀ day ▶ stepper, clamped to today (retro entries only — no future workouts).
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Text("Date", style = NoopType.body, color = Palette.textPrimary)
                    Spacer(Modifier.weight(1f))
                    Icon(
                        Icons.Filled.ChevronLeft, contentDescription = "Previous day",
                        tint = Palette.accent,
                        modifier = Modifier.size(22.dp).clickable { date = date.minusDays(1) },
                    )
                    Text(
                        date.format(dateFmtLocal), style = NoopType.number(15f),
                        color = Palette.textPrimary,
                        modifier = Modifier.padding(horizontal = 8.dp),
                    )
                    Icon(
                        Icons.Filled.ChevronRight, contentDescription = "Next day",
                        tint = if (date < today) Palette.accent else Palette.textTertiary,
                        modifier = Modifier.size(22.dp).clickable { if (date < today) date = date.plusDays(1) },
                    )
                }
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Text("Start time", style = NoopType.body, color = Palette.textPrimary)
                    Spacer(Modifier.weight(1f))
                    TimeChip(minutes = timeMinutes, accessibilityLabel = "Workout start time",
                        onPicked = { timeMinutes = it })
                }
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Text("Sport", style = NoopType.body, color = Palette.textPrimary)
                    Spacer(Modifier.weight(1f))
                    Box {
                        Text(
                            sport, style = NoopType.number(15f), color = Palette.accent,
                            modifier = Modifier
                                .clip(RoundedCornerShape(50))
                                .background(Palette.surfaceInset)
                                .border(1.dp, Palette.hairline, RoundedCornerShape(50))
                                .clickable { sportMenu = true }
                                .padding(horizontal = 12.dp, vertical = 6.dp),
                        )
                        DropdownMenu(expanded = sportMenu, onDismissRequest = { sportMenu = false }) {
                            MANUAL_SPORTS.forEach { s ->
                                DropdownMenuItem(
                                    text = { Text(s, style = NoopType.body) },
                                    onClick = { sport = s; sportMenu = false },
                                )
                            }
                        }
                    }
                }
                OutlinedTextField(
                    value = durationText,
                    onValueChange = { durationText = it.filter(Char::isDigit).take(4) },
                    label = { Text("Duration (min)", style = NoopType.footnote, color = Palette.textSecondary) },
                    keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number),
                    singleLine = true,
                    colors = workoutFieldColors(),
                    shape = RoundedCornerShape(14.dp),
                    modifier = Modifier.fillMaxWidth(),
                )
                OutlinedTextField(
                    value = hrText,
                    onValueChange = { hrText = it.filter(Char::isDigit).take(3) },
                    label = { Text("Avg HR (optional)", style = NoopType.footnote, color = Palette.textSecondary) },
                    keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number),
                    singleLine = true,
                    colors = workoutFieldColors(),
                    shape = RoundedCornerShape(14.dp),
                    modifier = Modifier.fillMaxWidth(),
                )
                OutlinedTextField(
                    value = kcalText,
                    onValueChange = { kcalText = it.filter(Char::isDigit).take(5) },
                    label = { Text("Calories (optional)", style = NoopType.footnote, color = Palette.textSecondary) },
                    keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number),
                    singleLine = true,
                    colors = workoutFieldColors(),
                    shape = RoundedCornerShape(14.dp),
                    modifier = Modifier.fillMaxWidth(),
                )
            }
        },
        confirmButton = {
            TextButton(onClick = { built?.let(onSave) }, enabled = built != null) {
                Text("Save", style = NoopType.headline,
                    color = if (built != null) Palette.accent else Palette.textTertiary)
            }
        },
        dismissButton = {
            TextButton(onClick = onCancel) {
                Text("Cancel", style = NoopType.subhead, color = Palette.textSecondary)
            }
        },
    )
}

@Composable
private fun workoutFieldColors() = OutlinedTextFieldDefaults.colors(
    focusedTextColor = Palette.textPrimary,
    unfocusedTextColor = Palette.textPrimary,
    disabledTextColor = Palette.textTertiary,
    cursorColor = Palette.accent,
    focusedBorderColor = Palette.accent,
    unfocusedBorderColor = Palette.hairline,
    disabledBorderColor = Palette.hairline,
    focusedContainerColor = Palette.surfaceInset,
    unfocusedContainerColor = Palette.surfaceInset,
    disabledContainerColor = Palette.surfaceInset,
)
