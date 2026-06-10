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
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.material.icons.Icons
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
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.noop.data.WorkoutRow
import java.time.Instant
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

    // Load both sources once. Whole history (epoch → now) per source, newest first.
    LaunchedEffect(Unit) {
        val now = System.currentTimeMillis() / 1000
        val whoop = vm.repo.workouts("my-whoop", 0L, now)
        // Apple Health export + Health Connect are separate sources (since #34) — include both.
        val apple = vm.repo.workouts("apple-health", 0L, now) +
            vm.repo.workouts("health-connect", 0L, now)
        // Imported sessions (Health Connect / Apple Health) carry no HR of their own — derive
        // avg/max from the strap's samples over each workout's window so they don't show "–" (#77).
        val merged = vm.repo.fillWorkoutHrFromStrap((whoop + apple).sortedByDescending { it.startTs })
        allRows = merged
        loaded = true
        range = defaultRange(merged)
    }

    ScreenScaffold(title = "Workouts", subtitle = "Every session, threaded together.") {
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
            SessionsSection(windowRows)
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

// MARK: - All sessions (one NoopCard, uniform fixed-height rows)

@Composable
private fun SessionsSection(rows: List<WorkoutRow>) {
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
private fun SessionRow(row: WorkoutRow, background: Color) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .background(background)
            .height(48.dp)
            .padding(horizontal = Metrics.cardPadding),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        // Date + time.
        Column(modifier = Modifier.weight(1.4f)) {
            Text(dateLabel(row.startTs), style = NoopType.subhead, color = Palette.textPrimary, maxLines = 1)
            Text(timeLabel(row.startTs), style = NoopType.footnote, color = Palette.textTertiary, maxLines = 1)
        }
        // Sport.
        Row(modifier = Modifier.weight(1.6f), verticalAlignment = Alignment.CenterVertically) {
            Icon(
                sportIcon(row.sport),
                contentDescription = null,
                tint = Palette.textSecondary,
                modifier = Modifier.size(14.dp),
            )
            Spacer(Modifier.width(7.dp))
            Text(
                row.sport,
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

/** Sessions grouped by sport, ordered by count (desc), then total time. */
private fun sportGroups(rows: List<WorkoutRow>): List<SportGroup> =
    rows.groupBy { it.sport }
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
        id == "health-connect" || src.contains("health-connect") -> "HC"
        id.contains("whoop") || src.contains("whoop") -> "Whoop"
        else -> "Apple"
    }
}

/**
 * The Src-column badge (label + tint). "HC" is abbreviated to fit the narrow column (Apple is
 * likewise short for "Apple Health"); Data Sources / Today spell out "Health Connect". Tints match
 * those screens: WHOOP accent green, Apple cyan, Health Connect purple.
 */
private val WorkoutRow.sourceBadge: Pair<String, Color>
    get() = when (workoutSourceLabel(deviceId, source)) {
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
