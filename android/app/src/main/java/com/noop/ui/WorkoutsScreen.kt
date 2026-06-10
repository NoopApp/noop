package com.noop.ui

import androidx.compose.foundation.background
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
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.DirectionsBike
import androidx.compose.material.icons.filled.DirectionsRun
import androidx.compose.material.icons.filled.DirectionsWalk
import androidx.compose.material.icons.filled.FitnessCenter
import androidx.compose.material.icons.filled.MoreVert
import androidx.compose.material.icons.filled.Pool
import androidx.compose.material.icons.filled.Rowing
import androidx.compose.material.icons.filled.SelfImprovement
import androidx.compose.material.icons.filled.SportsBasketball
import androidx.compose.material.icons.filled.SportsGymnastics
import androidx.compose.material.icons.filled.SportsMartialArts
import androidx.compose.material.icons.filled.SportsSoccer
import androidx.compose.material.icons.filled.SportsTennis
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.OutlinedTextFieldDefaults
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.runtime.collectAsState
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalContext
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
 * Sessions are loaded by the ViewModel from EVERY cached source — strap ("my-whoop": imported +
 * manual), Apple Health / Health Connect, and the on-device DETECTED bouts under "my-whoop-noop" —
 * merged newest first, with dismissed detected bouts filtered out (#107). Each row carries a source
 * badge (Whoop / Apple / HC / Detected / Manual) and an overflow menu to edit, re-label, dismiss or
 * delete. The windowing is anchored to the LATEST session (not "now"), so an old log still resolves;
 * an empty window auto-widens to the next larger range, exactly like the macOS screen.
 */
@Composable
fun WorkoutsScreen(vm: AppViewModel) {
    // The ViewModel owns the loaded rows now (ALL sources incl. detected, dismissed-filtered) so a
    // mutation (add / edit / relabel / dismiss / delete) republishes the list and the screen updates.
    val allRows by vm.workouts.collectAsState()
    var loaded by remember { mutableStateOf(false) }
    var range by remember { mutableStateOf(WorkoutRange.All) }
    // Pick the default range ONCE on first non-empty load; later mutations must not fight a range the
    // user chose. Mirrors macOS, which sets the default only in `.task` / first onAppear.
    var didPickDefaultRange by remember { mutableStateOf(false) }

    // The manual add/edit dialog target: Some(null) = add, Some(row) = edit, null = closed.
    var dialog by remember { mutableStateOf<DialogTarget?>(null) }

    LaunchedEffect(Unit) {
        vm.loadWorkouts()
        loaded = true
    }
    LaunchedEffect(allRows) {
        if (!didPickDefaultRange && allRows.isNotEmpty()) {
            range = defaultRange(allRows)
            didPickDefaultRange = true
        }
    }

    ScreenScaffold(title = "Workouts", subtitle = "Every session, threaded together.") {
        if (allRows.isEmpty()) {
            EmptyWorkouts(loaded, onAdd = { dialog = DialogTarget(null) })
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
                onAdd = { dialog = DialogTarget(null) },
            )
            SummarySection(rows = windowRows, effectiveRange = resolved, groups = groups)
            BreakdownSection(groups)
            ZonesSection(windowRows)
            SessionsSection(
                rows = windowRows,
                onEdit = { dialog = DialogTarget(it) },
                onRelabel = { row, sport -> vm.relabelDetected(row, sport) },
                onDismiss = { vm.dismissDetected(it) },
                onDelete = { vm.deleteWorkout(it) },
            )
        }
    }

    dialog?.let { target ->
        ManualWorkoutDialog(
            editing = target.editing,
            onDismiss = { dialog = null },
            onSave = { row, replacing ->
                vm.saveManualWorkout(row, replacing)
                dialog = null
            },
        )
    }
}

/** Drives the manual add/edit dialog. [editing] null = add a new workout, non-null = edit it. */
private data class DialogTarget(val editing: WorkoutRow?)

// MARK: - Empty / loading state

@Composable
private fun EmptyWorkouts(loaded: Boolean, onAdd: () -> Unit) {
    Column(verticalArrangement = Arrangement.spacedBy(16.dp)) {
        DataPendingNote(
            title = "No workouts yet",
            body = "No workouts yet. They come from your WHOOP and Apple Health history. " +
                "Import in Data Sources to bring them in — or add one you tracked elsewhere.",
        )
        if (loaded) AddWorkoutButton(onAdd)
    }
}

/** The "Add workout" pill — opens the manual add dialog. Shown on both the populated screen
 *  (in the range bar) and the empty state, so a user with no imports can still log a session. */
@Composable
private fun AddWorkoutButton(onAdd: () -> Unit) {
    Row(
        modifier = Modifier
            .clip(RoundedCornerShape(50))
            .background(Palette.accentMuted)
            .clickable(onClick = onAdd)
            .padding(horizontal = 14.dp, vertical = 8.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Icon(Icons.Filled.Add, contentDescription = null, tint = Palette.accent, modifier = Modifier.size(16.dp))
        Spacer(Modifier.width(6.dp))
        Text("Add workout", style = NoopType.subhead, color = Palette.accent)
    }
}

// MARK: - Range control

@Composable
private fun RangeBar(
    range: WorkoutRange,
    effectiveRange: WorkoutRange,
    rowCount: Int,
    fellBack: Boolean,
    onSelect: (WorkoutRange) -> Unit,
    onAdd: () -> Unit,
) {
    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
        Row(modifier = Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
            AddWorkoutButton(onAdd)
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
    // Imperial/Metric display preference (D#103). Distances are stored in metres; the toggle re-labels
    // them. Read here so a change recomposes the tiles. Display-only — nothing stored changes.
    val unitSystem = UnitPrefs.system(LocalContext.current)
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
                value = UnitFormatter.distanceFromKilometers(totalKm, unitSystem),
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
private fun SessionsSection(
    rows: List<WorkoutRow>,
    onEdit: (WorkoutRow) -> Unit,
    onRelabel: (WorkoutRow, String) -> Unit,
    onDismiss: (WorkoutRow) -> Unit,
    onDelete: (WorkoutRow) -> Unit,
) {
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
                        onEdit = onEdit,
                        onRelabel = onRelabel,
                        onDismiss = onDismiss,
                        onDelete = onDelete,
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
        // Trailing spacer column over the per-row overflow menu, so headers line up with the cells.
        Spacer(Modifier.width(32.dp))
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
private fun SessionRow(
    row: WorkoutRow,
    background: Color,
    onEdit: (WorkoutRow) -> Unit,
    onRelabel: (WorkoutRow, String) -> Unit,
    onDismiss: (WorkoutRow) -> Unit,
    onDelete: (WorkoutRow) -> Unit,
) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .background(background)
            .height(48.dp)
            .padding(start = Metrics.cardPadding),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        // Date + time.
        Column(modifier = Modifier.weight(1.4f)) {
            Text(dateLabel(row.startTs), style = NoopType.subhead, color = Palette.textPrimary, maxLines = 1)
            Text(timeLabel(row.startTs), style = NoopType.footnote, color = Palette.textTertiary, maxLines = 1)
        }
        // Sport ("detected" reads as "Activity").
        Row(modifier = Modifier.weight(1.6f), verticalAlignment = Alignment.CenterVertically) {
            Icon(
                sportIcon(row.sport),
                contentDescription = null,
                tint = Palette.textSecondary,
                modifier = Modifier.size(14.dp),
            )
            Spacer(Modifier.width(7.dp))
            Text(
                WorkoutEditing.displaySport(row.sport),
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
        RowActionsMenu(row, onEdit, onRelabel, onDismiss, onDelete)
    }
}

/**
 * Per-row overflow menu. A DETECTED bout can be re-labelled (becomes a real manual session that
 * survives re-detection) or dismissed (durably hidden so it doesn't come back). A MANUAL session can
 * be edited or deleted. Imported WHOOP / Apple rows are read-only — we never rewrite imported history
 * — but can be duplicated as an editable manual copy. (#107)
 */
@Composable
private fun RowActionsMenu(
    row: WorkoutRow,
    onEdit: (WorkoutRow) -> Unit,
    onRelabel: (WorkoutRow, String) -> Unit,
    onDismiss: (WorkoutRow) -> Unit,
    onDelete: (WorkoutRow) -> Unit,
) {
    var open by remember { mutableStateOf(false) }
    var relabelOpen by remember { mutableStateOf(false) }
    Box {
        IconButton(onClick = { open = true }, modifier = Modifier.size(32.dp)) {
            Icon(Icons.Filled.MoreVert, contentDescription = "Workout actions",
                tint = Palette.textTertiary, modifier = Modifier.size(18.dp))
        }
        DropdownMenu(expanded = open, onDismissRequest = { open = false }) {
            when (WorkoutEditing.classify(row.source)) {
                WorkoutSource.DETECTED -> {
                    DropdownMenuItem(
                        text = { Text("Re-label as…", style = NoopType.body, color = Palette.textPrimary) },
                        onClick = { open = false; relabelOpen = true },
                    )
                    DropdownMenuItem(
                        text = { Text("Edit details…", style = NoopType.body, color = Palette.textPrimary) },
                        onClick = { open = false; onEdit(row) },
                    )
                    DropdownMenuItem(
                        text = { Text("Dismiss (not a workout)", style = NoopType.body, color = Palette.statusCritical) },
                        onClick = { open = false; onDismiss(row) },
                    )
                }
                WorkoutSource.MANUAL -> {
                    DropdownMenuItem(
                        text = { Text("Edit…", style = NoopType.body, color = Palette.textPrimary) },
                        onClick = { open = false; onEdit(row) },
                    )
                    DropdownMenuItem(
                        text = { Text("Delete", style = NoopType.body, color = Palette.statusCritical) },
                        onClick = { open = false; onDelete(row) },
                    )
                }
                WorkoutSource.WHOOP, WorkoutSource.APPLE -> {
                    DropdownMenuItem(
                        text = { Text("Duplicate as manual…", style = NoopType.body, color = Palette.textPrimary) },
                        onClick = { open = false; onEdit(row.copy(source = "manual", sport = WorkoutEditing.displaySport(row.sport))) },
                    )
                }
            }
        }
        // Sub-menu of common sports for re-labelling a detected bout.
        DropdownMenu(expanded = relabelOpen, onDismissRequest = { relabelOpen = false }) {
            WorkoutEditing.relabelSports.forEach { sport ->
                DropdownMenuItem(
                    text = { Text(sport, style = NoopType.body, color = Palette.textPrimary) },
                    onClick = { relabelOpen = false; onRelabel(row, sport) },
                )
            }
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

// MARK: - Manual workout add / edit dialog
//
// Five inputs — sport, start (date-time, here entered as minutes-ago for simplicity on phone),
// duration, average HR, calories — validated by WorkoutEditing.buildManualRow (the same honest-row
// rules the engine uses). Editing carries the original's captured maxHr/strain/route over via
// preservingCaptured so changing sport/duration never wipes them. Android mirror of macOS
// ManualWorkoutSheet (the macOS sheet uses a DatePicker; on phone we take "minutes ago" to keep the
// dialog to plain numeric fields — the persisted startTs is identical).

@Composable
private fun ManualWorkoutDialog(
    editing: WorkoutRow?,
    onDismiss: () -> Unit,
    onSave: (row: WorkoutRow, replacing: WorkoutRow?) -> Unit,
) {
    val nowSec = System.currentTimeMillis() / 1000
    // Pre-fill from the edited row ("detected" shown as "Activity" so a re-label starts clean).
    var sport by remember { mutableStateOf(editing?.let { WorkoutEditing.displaySport(it.sport) } ?: "") }
    var minsAgo by remember {
        mutableStateOf(editing?.let { ((nowSec - it.startTs) / 60).coerceAtLeast(0).toString() } ?: "60")
    }
    var durationMin by remember {
        mutableStateOf(
            editing?.let { (((it.durationS ?: (it.endTs - it.startTs).toDouble()) / 60).roundToInt()).coerceAtLeast(1).toString() }
                ?: "45",
        )
    }
    var avgHr by remember { mutableStateOf(editing?.avgHr?.toString() ?: "") }
    var kcal by remember { mutableStateOf(editing?.energyKcal?.let { it.roundToInt().toString() } ?: "") }

    // Build the validated row (null disables Save). Start = now − minsAgo. Captured fields preserved.
    val built: WorkoutRow? = run {
        val mins = minsAgo.trim().toLongOrNull()
        val dur = durationMin.trim().toIntOrNull()
        val hrText = avgHr.trim()
        val kText = kcal.trim()
        // A typed-but-unparseable number is invalid (e.g. "abc" in Avg HR) — reject before building.
        val hr: Int? = if (hrText.isEmpty()) null else hrText.toIntOrNull()
        val k: Double? = if (kText.isEmpty()) null else kText.toDoubleOrNull()
        if (mins == null || mins < 0 || dur == null) return@run null
        if (hrText.isNotEmpty() && hr == null) return@run null
        if (kText.isNotEmpty() && k == null) return@run null
        // A manual workout ALWAYS lives under the strap source (where live-tracked sessions land), so
        // a "duplicate as manual" of an imported apple-health/whoop row never writes back to it.
        val base = WorkoutEditing.buildManualRow(
            deviceId = "my-whoop",
            startSeconds = nowSec - mins * 60,
            durationMin = dur,
            sport = sport,
            avgHr = hr,
            energyKcal = k,
            nowSeconds = nowSec,
        ) ?: return@run null
        WorkoutEditing.preservingCaptured(base, editing)
    }

    AlertDialog(
        onDismissRequest = onDismiss,
        containerColor = Palette.surfaceOverlay,
        title = {
            Text(if (editing == null) "Add Workout" else "Edit Workout",
                style = NoopType.title2, color = Palette.textPrimary)
        },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
                DialogField("Sport", sport, onChange = { sport = it }, placeholder = "e.g. Running")
                DialogField("Started (minutes ago)", minsAgo, onChange = { minsAgo = it }, numeric = true)
                DialogField("Duration (minutes)", durationMin, onChange = { durationMin = it }, numeric = true)
                DialogField("Avg HR (bpm, optional)", avgHr, onChange = { avgHr = it }, numeric = true)
                DialogField("Calories (kcal, optional)", kcal, onChange = { kcal = it }, numeric = true)
                if (built == null) {
                    Text(
                        "Enter a sport, a positive duration (≤ 24h), and valid HR (25–250) / calories (0–20,000).",
                        style = NoopType.footnote, color = Palette.statusWarning,
                    )
                }
            }
        },
        confirmButton = {
            // Pass `replacing` only when editing an existing MANUAL or DETECTED row (the repo replaces
            // it: a manual key change deletes the stale row; a detected original is durably dismissed).
            // Duplicating an imported WHOOP/Apple row is a pure ADD — never pass it, or a changed key
            // would delete the imported original.
            val replacing = editing?.takeIf {
                val c = WorkoutEditing.classify(it.source)
                c == WorkoutSource.MANUAL || c == WorkoutSource.DETECTED
            }
            TextButton(onClick = { built?.let { onSave(it, replacing) } }, enabled = built != null) {
                Text(if (editing == null) "Add" else "Save",
                    style = NoopType.body, color = if (built != null) Palette.accent else Palette.textTertiary)
            }
        },
        dismissButton = {
            TextButton(onClick = onDismiss) {
                Text("Cancel", style = NoopType.body, color = Palette.textSecondary)
            }
        },
    )
}

@Composable
private fun DialogField(
    label: String,
    value: String,
    onChange: (String) -> Unit,
    placeholder: String = "",
    numeric: Boolean = false,
) {
    OutlinedTextField(
        value = value,
        onValueChange = onChange,
        label = { Text(label, style = NoopType.footnote) },
        placeholder = { if (placeholder.isNotEmpty()) Text(placeholder, style = NoopType.body, color = Palette.textTertiary) },
        singleLine = true,
        keyboardOptions = if (numeric) KeyboardOptions(keyboardType = KeyboardType.Number) else KeyboardOptions.Default,
        colors = workoutFieldColors(),
        modifier = Modifier.fillMaxWidth(),
    )
}

@Composable
private fun workoutFieldColors() = OutlinedTextFieldDefaults.colors(
    focusedTextColor = Palette.textPrimary,
    unfocusedTextColor = Palette.textPrimary,
    cursorColor = Palette.accent,
    focusedBorderColor = Palette.accent,
    unfocusedBorderColor = Palette.hairline,
    focusedLabelColor = Palette.accent,
    unfocusedLabelColor = Palette.textSecondary,
    focusedContainerColor = Palette.surfaceInset,
    unfocusedContainerColor = Palette.surfaceInset,
)

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
    get() = when (WorkoutEditing.classify(source)) {
        // Detected (on-device auto-detector) is honestly labelled so a duplicate is recognisable +
        // removable (#107); manual = user-logged. Both classify on `source` BEFORE the import labels.
        WorkoutSource.DETECTED -> "Detected" to Palette.metricPurple
        WorkoutSource.MANUAL -> "Manual" to Palette.statusWarning
        else -> when (workoutSourceLabel(deviceId, source)) {
            "HC" -> "HC" to Palette.metricPurple
            "Whoop" -> "Whoop" to Palette.accent
            else -> "Apple" to Palette.metricCyan
        }
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
