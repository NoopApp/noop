package com.noop.ui

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
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
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.Close
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.mutableStateMapOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.StrokeJoin
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.noop.data.DailyMetric
import java.util.Locale
import kotlin.math.abs
import kotlin.math.sqrt

// MARK: - Compare
//
// The "overlay metrics & draw conclusions" screen, ported from
// Strand/Screens/CompareView.swift. Pick 2–4 metrics from the catalog, choose a time
// window, and read them on a single normalized overlay chart (each metric min–max
// scaled to 0–1 within the window so different units share an axis). Below, every pair
// of selected metrics gets a live Pearson-r correlation read-out with a plain-English
// conclusion.
//
// Data sourcing on Android: macOS reads every metric from the generic `metricSeries`
// long-format store via repo.series(key, source). We mirror that exactly — and, for
// the core daily metrics that also live as columns on the cached `DailyMetric` rows
// (recovery, strain, HRV, RHR, sleep splits, SpO₂, respiration, skin-temp), we fall
// back to deriving the series from repo.days(deviceId) when metricSeries is empty. That
// keeps the screen showing REAL on-device data rather than an empty state when only the
// daily cache (not the generic importer) has populated. Apple-Health body metrics
// (weight/body-fat/etc.) come from metricSeries only — when no importer has run they
// auto-widen to ALL and then show the macOS "no data, widen the range" contract.

// MARK: - Metric catalog (ported from Strand/Data/MetricCatalog.swift)

/** One interrogable metric: how to fetch it (key+source), how to label/format it. */
data class CompareMetric(
    val key: String,
    val title: String,
    val category: String,
    val unit: String,
    val source: String,      // "my-whoop" or "apple-health"
    val decimals: Int,
) {
    val id: String get() = "$source:$key"

    fun format(v: Double): String {
        val n = if (decimals == 0) {
            Math.round(v).toString()
        } else {
            java.lang.String.format(Locale.US, "%.${decimals}f", v)
        }
        return if (unit.isEmpty()) n else "$n $unit"
    }

    /** Unit-aware format (D#103): weight/lean_mass (kg) and skin_temp (°C) convert + relabel via
     *  [UnitFormatter]; everything else (%, bpm, ms, min, …) is unit-agnostic and falls through. */
    fun format(v: Double, system: UnitSystem, temperature: TemperatureUnit): String = when (unit) {
        "kg" -> UnitFormatter.massFromKilograms(v, system)
        "°C" -> UnitFormatter.temperatureFromCelsius(v, temperature, decimals)
        else -> format(v)
    }

    /** Like [format] but for a DIFFERENCE: a temperature delta omits the +32 offset. */
    fun formatDelta(v: Double, system: UnitSystem, temperature: TemperatureUnit): String = when (unit) {
        "kg" -> UnitFormatter.massFromKilograms(v, system)
        "°C" -> UnitFormatter.temperatureDeltaFromCelsius(v, temperature, decimals)
        else -> format(v)
    }

    /** Displayed unit LABEL mapped to the active system (kg→lb, °C→°F); others unchanged. */
    fun displayUnit(system: UnitSystem, temperature: TemperatureUnit): String = when (unit) {
        "kg" -> UnitFormatter.massUnit(system)
        "°C" -> UnitFormatter.temperatureUnit(temperature)
        else -> unit
    }
}

/**
 * Canonical catalog — mirrors MetricCatalog.swift. Keys match exactly what the importers
 * write into metricSeries; [dailyPick], when non-null, is the matching column on
 * [DailyMetric] so a my-whoop metric can be derived from the daily cache as a fallback.
 */
private object CompareCatalog {
    val categories = listOf("Heart", "Recovery", "Sleep", "Strain", "Health")

    val all: List<CompareMetric> = listOf(
        // Heart
        CompareMetric("avg_hr", "Average Heart Rate", "Heart", "bpm", "my-whoop", 0),
        CompareMetric("max_hr", "Max Heart Rate", "Heart", "bpm", "my-whoop", 0),
        CompareMetric("energy_kcal", "Calories", "Heart", "kcal", "my-whoop", 0),
        CompareMetric("vo2max", "VO₂ Max", "Heart", "", "apple-health", 1),
        // Recovery
        CompareMetric("recovery", "Recovery", "Recovery", "%", "my-whoop", 0),
        CompareMetric("hrv", "Heart Rate Variability", "Recovery", "ms", "my-whoop", 0),
        CompareMetric("rhr", "Resting Heart Rate", "Recovery", "bpm", "my-whoop", 0),
        CompareMetric("resp_rate", "Respiratory Rate", "Recovery", "rpm", "my-whoop", 1),
        CompareMetric("spo2", "Blood Oxygen", "Recovery", "%", "my-whoop", 0),
        CompareMetric("skin_temp", "Skin Temperature", "Recovery", "°C", "my-whoop", 1),
        // Sleep
        CompareMetric("sleep_performance", "Sleep Performance", "Sleep", "%", "my-whoop", 0),
        CompareMetric("sleep_total_min", "Asleep Time", "Sleep", "min", "my-whoop", 0),
        CompareMetric("sleep_efficiency", "Sleep Efficiency", "Sleep", "%", "my-whoop", 0),
        CompareMetric("sleep_deep_min", "Deep (SWS) Sleep", "Sleep", "min", "my-whoop", 0),
        CompareMetric("sleep_rem_min", "REM Sleep", "Sleep", "min", "my-whoop", 0),
        CompareMetric("sleep_light_min", "Light Sleep", "Sleep", "min", "my-whoop", 0),
        // Strain
        CompareMetric("strain", "Day Strain", "Strain", "/21", "my-whoop", 1),
        CompareMetric("steps", "Steps", "Strain", "", "apple-health", 0),
        CompareMetric("active_kcal", "Active Energy", "Strain", "kcal", "apple-health", 0),
        // Health / Body
        CompareMetric("weight", "Weight", "Health", "kg", "apple-health", 1),
        CompareMetric("body_fat", "Body Fat", "Health", "%", "apple-health", 1),
        CompareMetric("lean_mass", "Lean Body Mass", "Health", "kg", "apple-health", 1),
        CompareMetric("bmi", "BMI", "Health", "", "apple-health", 1),
    )

    fun inCategory(c: String): List<CompareMetric> = all.filter { it.category == c }

    fun byKey(key: String): CompareMetric? = all.firstOrNull { it.key == key }

    /** Map a my-whoop metric key to the matching DailyMetric column accessor, if any. */
    fun dailyPick(key: String): ((DailyMetric) -> Double?)? = when (key) {
        "recovery" -> { d -> d.recovery }
        "strain" -> { d -> d.strain }
        "hrv" -> { d -> d.avgHrv }
        "rhr" -> { d -> d.restingHr?.toDouble() }
        "resp_rate" -> { d -> d.respRateBpm }
        "spo2" -> { d -> d.spo2Pct }
        "skin_temp" -> { d -> d.skinTempDevC }
        "sleep_total_min" -> { d -> d.totalSleepMin }
        "sleep_efficiency" -> { d -> d.efficiency }
        "sleep_deep_min" -> { d -> d.deepMin }
        "sleep_rem_min" -> { d -> d.remMin }
        "sleep_light_min" -> { d -> d.lightMin }
        else -> null
    }
}

// MARK: - Range control (shared spec — W / M / 3M / 6M / 1Y / ALL)

/** The canonical Strand range window. [days] == null means ALL of history. */
private enum class CompareRange(val label: String, val days: Int?, val phrase: String) {
    Week("W", 7, "the last 7 days"),
    Month("M", 30, "30 days"),
    Quarter("3M", 90, "3 months"),
    Half("6M", 180, "6 months"),
    Year("1Y", 365, "1 year"),
    All("ALL", null, "all history");

    /** This range plus every LARGER range, ascending — the auto-expand search order. */
    val widening: List<CompareRange>
        get() = entries.subList(ordinal, entries.size)
}

// MARK: - Per-series model

/** Distinct, high-legibility categorical series colors (avoid the recovery/strain ramps). */
private val seriesPalette: List<Color> =
    listOf(Palette.accent, Palette.metricCyan, Palette.metricPurple, Palette.metricAmber)

/**
 * One selected metric, resolved over the active window: its descriptor, the windowed
 * (day,value) rows, a stable display color, and its real min/max.
 */
private data class CompareSeries(
    val metric: CompareMetric,
    val color: Color,
    val rows: List<Pair<String, Double>>,
) {
    val id: String get() = metric.id
    val values: List<Double> get() = rows.map { it.second }
    val realMin: Double get() = values.minOrNull() ?: 0.0
    val realMax: Double get() = values.maxOrNull() ?: 0.0

    /** Min–max normalize a value into 0…1 within this series' window. Flat → mid-line. */
    fun normalized(v: Double): Double {
        val lo = realMin
        val hi = realMax
        if (hi <= lo) return 0.5
        return ((v - lo) / (hi - lo)).coerceIn(0.0, 1.0)
    }
}

// MARK: - Day arithmetic (fixed UTC, deterministic — mirrors compareDayParser/slice)

/** "yyyy-MM-dd" → ordinal day count (days since a fixed epoch), or null if unparseable. */
private fun dayOrdinal(day: String): Long? {
    val parts = day.split("-")
    if (parts.size != 3) return null
    val y = parts[0].toIntOrNull() ?: return null
    val m = parts[1].toIntOrNull() ?: return null
    val d = parts[2].toIntOrNull() ?: return null
    if (m !in 1..12 || d < 1) return null
    // Howard Hinnant's days-from-civil — monotonic proleptic Gregorian day number.
    var yy = y
    var mm = m
    if (mm <= 2) { yy -= 1; mm += 12 }
    val era = (if (yy >= 0) yy else yy - 399) / 400
    val yoe = yy - era * 400
    val doy = (153 * (mm - 3) + 2) / 5 + d - 1
    val doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
    return era.toLong() * 146097L + doe - 719468L
}

// MARK: - Correlation engine (ported from StrandAnalytics/CorrelationEngine.swift)

private data class Correlation(val r: Double, val n: Int)

private object CorrelationEngine {
    /** Inner-join two day-keyed series on the day key → (x, y) pairs sorted by day. */
    fun alignByDay(
        a: List<Pair<String, Double>>,
        b: List<Pair<String, Double>>,
    ): List<Pair<Double, Double>> {
        val mapA = HashMap<String, Double>()
        for ((day, v) in a) mapA[day] = v
        val mapB = HashMap<String, Double>()
        for ((day, v) in b) mapB[day] = v
        val common = mapA.keys.filter { mapB.containsKey(it) }.sorted()
        return common.map { mapA[it]!! to mapB[it]!! }
    }

    /** Pearson r over the pairs. Null when <3 pairs or either variable has zero variance. */
    fun pearson(xy: List<Pair<Double, Double>>): Correlation? {
        val n = xy.size
        if (n < 3) return null
        val nD = n.toDouble()
        var sumX = 0.0
        var sumY = 0.0
        for (p in xy) { sumX += p.first; sumY += p.second }
        val meanX = sumX / nD
        val meanY = sumY / nD
        var sxx = 0.0
        var syy = 0.0
        var sxy = 0.0
        for (p in xy) {
            val dx = p.first - meanX
            val dy = p.second - meanY
            sxx += dx * dx
            syy += dy * dy
            sxy += dx * dy
        }
        if (sxx <= 0.0 || syy <= 0.0) return null
        var r = sxy / (sqrt(sxx) * sqrt(syy))
        if (r > 1.0) r = 1.0
        if (r < -1.0) r = -1.0
        return Correlation(r = r, n = n)
    }
}

// MARK: - Root

/**
 * CompareScreen — overlay 2–4 normalized signals and read their pairwise Pearson
 * correlations. Faithful port of CompareView.swift onto the locked Compose components.
 */
@Composable
fun CompareScreen(vm: AppViewModel) {
    val days by vm.recentDays.collectAsStateWithLifecycle()

    val maxSelection = 4
    val minSelection = 2

    // Default starter selection (falls back gracefully if a key is missing).
    val defaultKeys = listOf("recovery", "sleep_performance", "weight")

    var range by remember { mutableStateOf(CompareRange.Year) }
    // Ordered selection (max 4). Drives both the legend order and color mapping.
    val selected = remember {
        val picks = defaultKeys.mapNotNull { CompareCatalog.byKey(it) }
        val seed = if (picks.isEmpty()) CompareCatalog.all.take(2) else picks.take(maxSelection)
        mutableStateListOf<CompareMetric>().apply { addAll(seed) }
    }
    // Full-history series per selected metric id (ascending by day).
    val fullSeries = remember { mutableStateMapOf<String, List<Pair<String, Double>>>() }
    var loadedOnce by remember { mutableStateOf(false) }

    // Load the full history for any selected metric not yet fetched, whenever the
    // selection set or the daily cache changes. Mirrors macOS `.task(id: selectionKey)`.
    val selectionKey = selected.joinToString("|") { it.id }
    LaunchedEffect(selectionKey, days) {
        for (metric in selected) {
            // Always (re)load derived-from-daily my-whoop series when the cache grew;
            // metricSeries-only metrics are loaded once.
            val pick = if (metric.source == "my-whoop") CompareCatalog.dailyPick(metric.key) else null
            val needsLoad = !fullSeries.containsKey(metric.id) ||
                (pick != null && fullSeries[metric.id].isNullOrEmpty())
            if (needsLoad) {
                fullSeries[metric.id] = loadFullSeries(vm, metric, days)
            }
        }
        loadedOnce = true
    }

    // ── Windowing (RELATIVE to each series' latest point, per macOS slice()).
    fun slice(full: List<Pair<String, Double>>, r: CompareRange): List<Pair<String, Double>> {
        val n = r.days ?: return full
        val lastDay = full.lastOrNull()?.first ?: return emptyList()
        val lastOrd = dayOrdinal(lastDay) ?: return emptyList()
        val cutoff = lastOrd - (n - 1)
        return full.filter { (day, _) ->
            val o = dayOrdinal(day) ?: return@filter false
            o >= cutoff
        }
    }

    // The range actually used for a series: the SELECTED range when it holds ≥1 point,
    // else the smallest LARGER range that does (so sparse metrics still overlay).
    fun effectiveRange(full: List<Pair<String, Double>>): CompareRange {
        if (full.isEmpty()) return range
        for (r in range.widening) if (slice(full, r).isNotEmpty()) return r
        return CompareRange.All
    }

    // Selected metrics resolved to windowed rows + stable colors, in pick order.
    val activeSeries: List<CompareSeries> = selected.mapIndexed { idx, metric ->
        val full = fullSeries[metric.id] ?: emptyList()
        val rows = slice(full, effectiveRange(full))
        CompareSeries(
            metric = metric,
            color = seriesPalette[idx % seriesPalette.size],
            rows = rows,
        )
    }

    val anyWidened = selected.any { metric ->
        val full = fullSeries[metric.id] ?: emptyList()
        full.isNotEmpty() && effectiveRange(full) != range
    }

    val rangeCaption: String = run {
        val total = activeSeries.sumOf { it.rows.size }
        val unit = if (total == 1) "reading" else "readings"
        val base = "$total $unit across ${activeSeries.size} · ${range.phrase}"
        if (anyWidened) "$base · sparse widened" else base
    }

    ScreenScaffold(title = "Compare", subtitle = "Overlay signals, draw conclusions.") {

        // ── Metric picker section (chips + range control)
        Column(verticalArrangement = Arrangement.spacedBy(Metrics.gap)) {
            SectionHeader("Metrics", overline = "Overlay 2–4 signals")
            NoopCard {
                Column(verticalArrangement = Arrangement.spacedBy(Metrics.gap)) {
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        SegmentedPillControl(
                            items = CompareRange.entries.toList(),
                            selection = range,
                            label = { it.label },
                            onSelect = { range = it },
                        )
                        Spacer(Modifier.weight(1f))
                        AddMetricMenu(
                            selectedCount = selected.size,
                            maxSelection = maxSelection,
                            isSelected = { m -> selected.any { it.id == m.id } },
                            onToggle = { m ->
                                val existing = selected.firstOrNull { it.id == m.id }
                                if (existing != null) {
                                    selected.remove(existing)
                                } else if (selected.size < maxSelection) {
                                    selected.add(m)
                                }
                            },
                        )
                    }

                    if (selected.size >= minSelection) {
                        Text(
                            rangeCaption,
                            style = NoopType.footnote,
                            color = if (anyWidened) Palette.statusWarning else Palette.textTertiary,
                        )
                    }

                    if (selected.isEmpty()) {
                        Text(
                            "Nothing selected yet.",
                            style = NoopType.subhead,
                            color = Palette.textTertiary,
                        )
                    } else {
                        FlowChips(
                            metrics = selected.toList(),
                            colorFor = { m ->
                                val i = selected.indexOfFirst { it.id == m.id }
                                if (i < 0) Palette.textSecondary else seriesPalette[i % seriesPalette.size]
                            },
                            onRemove = { m -> selected.removeAll { it.id == m.id } },
                        )
                    }
                }
            }
        }

        if (selected.size < minSelection) {
            EmptyNote("Pick at least two metrics above to overlay them and read how they move together.")
        } else {
            val nonEmpty = activeSeries.filter { it.rows.isNotEmpty() }
            if (nonEmpty.isEmpty()) {
                if (loadedOnce) {
                    DataPendingNote(
                        title = "Compare needs at least two metrics with history",
                        body = "Compare needs at least two metrics with history. Import your " +
                            "WHOOP export in Data Sources first.",
                    )
                } else {
                    EmptyNote("Reading your history…")
                }
            } else {
                OverlaySection(nonEmpty, range, anyWidened)
                CorrelationSection(activeSeries, range)
            }
        }
    }
}

// MARK: - Series loading

/**
 * Load the full history for [metric] (ascending by day). Mirrors macOS
 * repo.series(key, source) over the generic metricSeries store; for core my-whoop
 * metrics with a matching DailyMetric column, falls back to the daily cache when the
 * generic store is empty so the screen shows real on-device data.
 */
private suspend fun loadFullSeries(
    vm: AppViewModel,
    metric: CompareMetric,
    cachedDays: List<DailyMetric>,
): List<Pair<String, Double>> {
    // Wide window covering all of history (the macOS days = 4000 default).
    val to = todayDay(1)
    val from = todayDay(-4000)
    val generic = vm.repo.metricSeries(metric.source, metric.key, from, to)
        .map { it.day to it.value }
        .sortedBy { it.first }
    if (generic.isNotEmpty()) return generic

    // Fallback: derive from the daily metric cache for my-whoop columns.
    if (metric.source == "my-whoop") {
        val pick = CompareCatalog.dailyPick(metric.key)
        if (pick != null) {
            // Merged: imported WHOOP days win; on-device computed days gap-fill the series.
            val all = vm.repo.daysMerged("my-whoop")
            val derived = if (all.isNotEmpty()) all else cachedDays
            return derived.mapNotNull { d -> pick(d)?.let { d.day to it } }.sortedBy { it.first }
        }
    }
    return emptyList()
}

/** "yyyy-MM-dd" for today offset by [deltaDays], fixed UTC. */
private fun todayDay(deltaDays: Int): String {
    val cal = java.util.Calendar.getInstance(java.util.TimeZone.getTimeZone("UTC"))
    cal.add(java.util.Calendar.DAY_OF_YEAR, deltaDays)
    return String.format(
        Locale.US,
        "%04d-%02d-%02d",
        cal.get(java.util.Calendar.YEAR),
        cal.get(java.util.Calendar.MONTH) + 1,
        cal.get(java.util.Calendar.DAY_OF_MONTH),
    )
}

// MARK: - Add-metric menu (grouped by category, ported from CompareView.addMenu)

@Composable
private fun AddMetricMenu(
    selectedCount: Int,
    maxSelection: Int,
    isSelected: (CompareMetric) -> Boolean,
    onToggle: (CompareMetric) -> Unit,
) {
    var expanded by remember { mutableStateOf(false) }
    val atMax = selectedCount >= maxSelection
    val tint = if (atMax) Palette.textTertiary else Palette.accent

    Box {
        Row(
            modifier = Modifier
                .clip(RoundedCornerShape(50))
                .clickableNoRippleLocal(enabled = !atMax) { expanded = true }
                .padding(horizontal = 8.dp, vertical = 6.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(6.dp),
        ) {
            Icon(
                Icons.Filled.Add,
                contentDescription = "Add a metric to compare",
                tint = tint,
                modifier = Modifier.size(16.dp),
            )
            Text(
                if (atMax) "Max 4" else "Add metric",
                style = NoopType.subhead,
                color = tint,
            )
        }

        DropdownMenu(
            expanded = expanded,
            onDismissRequest = { expanded = false },
            modifier = Modifier.background(Palette.surfaceOverlay),
        ) {
            CompareCatalog.categories.forEach { category ->
                val metrics = CompareCatalog.inCategory(category)
                if (metrics.isNotEmpty()) {
                    Text(
                        category.uppercase(),
                        style = NoopType.overline,
                        color = Palette.textTertiary,
                        modifier = Modifier.padding(horizontal = 12.dp, vertical = 6.dp),
                    )
                    metrics.forEach { metric ->
                        val on = isSelected(metric)
                        val enabled = on || selectedCount < maxSelection
                        DropdownMenuItem(
                            enabled = enabled,
                            onClick = { onToggle(metric) },
                            leadingIcon = {
                                if (on) {
                                    Icon(
                                        Icons.Filled.Check,
                                        contentDescription = null,
                                        tint = Palette.accent,
                                        modifier = Modifier.size(16.dp),
                                    )
                                } else {
                                    Spacer(Modifier.size(16.dp))
                                }
                            },
                            text = {
                                Text(
                                    metric.title,
                                    style = NoopType.body,
                                    color = if (enabled) Palette.textPrimary else Palette.textTertiary,
                                )
                            },
                        )
                    }
                }
            }
        }
    }
}

// MARK: - Selected-metric chips (wrapping flow layout)

/** Removable chips for the active selection, tinted to each series' color. */
@Composable
private fun FlowChips(
    metrics: List<CompareMetric>,
    colorFor: (CompareMetric) -> Color,
    onRemove: (CompareMetric) -> Unit,
) {
    // Two-up rows keep the chips readable on phone widths (mirrors the adaptive grid).
    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
        metrics.chunked(2).forEach { rowChips ->
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                rowChips.forEach { metric ->
                    MetricChip(
                        modifier = Modifier.weight(1f),
                        title = metric.title,
                        color = colorFor(metric),
                        onRemove = { onRemove(metric) },
                    )
                }
                if (rowChips.size == 1) Spacer(Modifier.weight(1f))
            }
        }
    }
}

@Composable
private fun MetricChip(
    title: String,
    color: Color,
    onRemove: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val shape = RoundedCornerShape(50)
    Row(
        modifier = modifier
            .clip(shape)
            .background(Palette.surfaceOverlay)
            .border(1.dp, color.copy(alpha = 0.4f), shape)
            .padding(horizontal = 11.dp, vertical = 8.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(7.dp),
    ) {
        Box(
            modifier = Modifier
                .size(8.dp)
                .clip(CircleShape)
                .background(color),
        )
        Text(
            title,
            style = NoopType.subhead,
            color = Palette.textPrimary,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
            modifier = Modifier.weight(1f),
        )
        Icon(
            Icons.Filled.Close,
            contentDescription = "Remove $title",
            tint = Palette.textTertiary,
            modifier = Modifier
                .size(18.dp)
                .clip(CircleShape)
                .clickableNoRippleLocal(enabled = true) { onRemove() }
                .padding(3.dp),
        )
    }
}

// MARK: - Overlay chart section

@Composable
private fun OverlaySection(
    series: List<CompareSeries>,
    range: CompareRange,
    anyWidened: Boolean,
) {
    Column(verticalArrangement = Arrangement.spacedBy(Metrics.gap)) {
        SectionHeader("Overlay", overline = range.phrase, trailing = "${series.size} series")
        NoopCard {
            Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
                Overline("Normalized overlay")
                Text(
                    if (anyWidened) {
                        "Each line min–max normalized · sparse series widened past ${range.phrase}"
                    } else {
                        "Each line min–max normalized within ${range.phrase}"
                    },
                    style = NoopType.footnote,
                    color = Palette.textTertiary,
                )

                OverlayChart(
                    series = series,
                    modifier = Modifier
                        .fillMaxWidth()
                        .height(Metrics.chartHeight),
                )

                // Endpoint axis labels (low / high), mirroring the normalized macOS y-axis.
                Row(modifier = Modifier.fillMaxWidth()) {
                    Text("low", style = NoopType.footnote, color = Palette.textTertiary)
                    Spacer(Modifier.weight(1f))
                    Text("high", style = NoopType.footnote, color = Palette.textTertiary)
                }

                HorizontalDivider(color = Palette.hairline)

                // Legend with real per-series min/max.
                Legend(series)
            }
        }
    }
}

/**
 * Multi-line normalized overlay drawn on a Compose Canvas. Each series is min–max
 * scaled into 0…1 within its own window, then placed on a shared day x-axis spanning
 * the union of all days present, so different units share one chart.
 */
@Composable
private fun OverlayChart(series: List<CompareSeries>, modifier: Modifier) {
    // Union of all day ordinals present → shared x domain.
    val dayOrds = remember(series) {
        series.flatMap { s -> s.rows.mapNotNull { dayOrdinal(it.first) } }
    }
    val minOrd = dayOrds.minOrNull()
    val maxOrd = dayOrds.maxOrNull()

    Canvas(modifier = modifier) {
        val w = size.width
        val h = size.height
        if (w <= 0f || h <= 0f) return@Canvas

        val topPad = 6f
        val usableH = (h - topPad * 2f).coerceAtLeast(1f)

        // Faint low / mid / high gridlines.
        val gridColor = Palette.hairline.copy(alpha = 0.4f)
        for (f in listOf(0f, 0.5f, 1f)) {
            val y = topPad + (1f - f) * usableH
            drawLine(
                color = gridColor,
                start = Offset(0f, y),
                end = Offset(w, y),
                strokeWidth = 1f,
            )
        }

        if (minOrd == null || maxOrd == null) return@Canvas
        val span = (maxOrd - minOrd).coerceAtLeast(1L).toFloat()

        series.forEach { s ->
            val pts = s.rows.mapNotNull { (day, value) ->
                val ord = dayOrdinal(day) ?: return@mapNotNull null
                val x = if (maxOrd > minOrd) (ord - minOrd).toFloat() / span * w else w / 2f
                val norm = s.normalized(value).toFloat().coerceIn(0f, 1f)
                val y = topPad + (1f - norm) * usableH
                Offset(x, y)
            }
            if (pts.size < 2) {
                // A single point still renders as a dot so the series is visible.
                pts.firstOrNull()?.let { drawCircle(s.color, radius = 3.5f, center = it) }
                return@forEach
            }
            val path = Path().apply {
                moveTo(pts.first().x, pts.first().y)
                for (i in 1 until pts.size) lineTo(pts[i].x, pts[i].y)
            }
            drawPath(
                path = path,
                color = s.color,
                style = Stroke(width = 2.2f, cap = StrokeCap.Round, join = StrokeJoin.Round),
            )
        }
    }
}

@Composable
private fun Legend(series: List<CompareSeries>) {
    // Imperial/Metric display preference (D#103). Only weight/lean mass (kg) and skin temp (°C) in the
    // catalog carry a convertible unit; the min–max labels re-label under the toggle. Display-only.
    val context = LocalContext.current
    val unitSystem = UnitPrefs.system(context)
    val tempUnit = UnitPrefs.temperature(context)
    Column {
        series.forEachIndexed { idx, s ->
            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(vertical = 7.dp),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(10.dp),
            ) {
                Box(
                    modifier = Modifier
                        .width(14.dp)
                        .height(3.dp)
                        .clip(RoundedCornerShape(2.dp))
                        .background(s.color),
                )
                Text(
                    s.metric.title,
                    style = NoopType.subhead,
                    color = Palette.textPrimary,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                    modifier = Modifier.weight(1f),
                )
                Text(
                    "${s.metric.format(s.realMin, unitSystem, tempUnit)} – " +
                        s.metric.format(s.realMax, unitSystem, tempUnit),
                    style = NoopType.captionNumber,
                    color = Palette.textSecondary,
                )
            }
            if (idx < series.size - 1) HorizontalDivider(color = Palette.hairline)
        }
    }
}

// MARK: - Pairwise correlation section

private data class PairResult(
    val a: CompareSeries,
    val b: CompareSeries,
    val r: Double,
    val n: Int,
) {
    val id: String get() = "${a.id}~${b.id}"
}

/** The pairwise Pearson scan over the non-empty series — strongest relationships first. */
private fun computePairResults(series: List<CompareSeries>): List<PairResult> {
    val s = series.filter { it.rows.isNotEmpty() }
    if (s.size < 2) return emptyList()
    val out = ArrayList<PairResult>()
    for (i in 0 until s.size - 1) {
        for (j in i + 1 until s.size) {
            val pairs = CorrelationEngine.alignByDay(s[i].rows, s[j].rows)
            if (pairs.size < 3) continue
            val c = CorrelationEngine.pearson(pairs) ?: continue
            out.add(PairResult(a = s[i], b = s[j], r = c.r, n = c.n))
        }
    }
    out.sortByDescending { abs(it.r) }
    return out
}

@Composable
private fun CorrelationSection(series: List<CompareSeries>, range: CompareRange) {
    // A stable fingerprint of the windowed series content; the scan recomputes only when
    // that content changes (selection / range / data updates), never on unrelated recompose.
    val key = series.joinToString("|") { s ->
        "${s.id}:${s.rows.size}:${s.rows.firstOrNull()?.first ?: ""}>${s.rows.lastOrNull()?.first ?: ""}"
    }
    val pairs = remember(key) { computePairResults(series) }

    Column(verticalArrangement = Arrangement.spacedBy(Metrics.gap)) {
        SectionHeader(
            "How They Move Together",
            overline = "Pearson r · ${range.phrase}",
            trailing = if (pairs.isEmpty()) null else "${pairs.size} pairs",
        )

        if (pairs.isEmpty()) {
            NoopCard {
                Text(
                    "Not enough overlapping days between these metrics in ${range.phrase}. Widen the range.",
                    style = NoopType.subhead,
                    color = Palette.textTertiary,
                )
            }
        } else {
            pairs.forEach { PairCard(it) }
        }
    }
}

@Composable
private fun PairCard(p: PairResult) {
    val tint = correlationColor(p.r)
    NoopCard {
        Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
            Row(
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(10.dp),
            ) {
                Row(horizontalArrangement = Arrangement.spacedBy(3.dp)) {
                    Box(modifier = Modifier.size(8.dp).clip(CircleShape).background(p.a.color))
                    Box(modifier = Modifier.size(8.dp).clip(CircleShape).background(p.b.color))
                }
                Text(
                    "${p.a.metric.title} ↔ ${p.b.metric.title}",
                    style = NoopType.headline,
                    color = Palette.textPrimary,
                    maxLines = 2,
                    overflow = TextOverflow.Ellipsis,
                    modifier = Modifier.weight(1f),
                )
                Text("r = ${signedR(p.r)}", style = NoopType.number(18f), color = tint)
            }

            Text(insightSentence(p), style = NoopType.subhead, color = Palette.textSecondary)

            Text(
                "${p.n} overlapping days · ${strengthWord(p.r)} ${directionWord(p.r)} correlation"
                    .replace("  ", " "),
                style = NoopType.footnote,
                color = Palette.textTertiary,
            )
        }
    }
}

// MARK: - Insight language (ported from CompareView)

private fun insightSentence(p: PairResult): String {
    val head = ("${p.a.metric.title} ↔ ${p.b.metric.title}: r = ${signedR(p.r)} " +
        "(${strengthWord(p.r)} ${directionWord(p.r)}) over ${p.n} shared days.")
        .replace("  ", " ").replace(" )", ")")
    if (abs(p.r) < 0.3) {
        return "$head No clear relationship — they move largely independently."
    }
    val aT = p.a.metric.title.lowercase()
    val bT = p.b.metric.title.lowercase()
    val verb = if (p.r < 0) "tends to fall" else "tends to rise"
    return "$head When $aT rises, $bT $verb — a ${strengthWord(p.r)} ${directionWord(p.r)} link."
}

private fun signedR(r: Double): String {
    val sign = if (r >= 0) "+" else "−"
    return sign + java.lang.String.format(Locale.US, "%.2f", abs(r))
}

private fun strengthWord(r: Double): String {
    val a = abs(r)
    return when {
        a < 0.1 -> "negligible"
        a < 0.3 -> "weak"
        a < 0.5 -> "moderate"
        a < 0.7 -> "strong"
        else -> "very strong"
    }
}

private fun directionWord(r: Double): String {
    if (abs(r) < 0.1) return ""
    return if (r >= 0) "positive" else "negative"
}

private fun correlationColor(r: Double): Color {
    val base = if (r >= 0) Palette.statusPositive else Palette.statusCritical
    return base.copy(alpha = 0.55f + 0.45f * abs(r).coerceAtMost(1.0).toFloat())
}

// MARK: - Empty-state note (replaces the macOS ComingSoon placeholder inline)

@Composable
private fun EmptyNote(text: String) {
    NoopCard {
        Text(
            text,
            style = NoopType.subhead,
            color = Palette.textTertiary,
            modifier = Modifier.fillMaxWidth(),
        )
    }
}

// MARK: - Local interaction helper (clickable without ripple, optionally disabled)

@Composable
private fun Modifier.clickableNoRippleLocal(enabled: Boolean, onClick: () -> Unit): Modifier {
    val interaction = remember { MutableInteractionSource() }
    return this.then(
        Modifier.clickable(
            enabled = enabled,
            indication = null,
            interactionSource = interaction,
            onClick = onClick,
        ),
    )
}
