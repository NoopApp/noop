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
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.ArrowDropDown
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
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
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.noop.data.DailyMetric
import com.noop.data.MoodStore
import com.noop.ingest.NutritionCsvImporter
import java.util.Locale
import kotlin.math.abs
import kotlin.math.roundToInt

// MARK: - Explore (Metric Explorer)
//
// Port of the macOS MetricExplorerView focus: a metric picker → a hero LineChart of
// the chosen metric over a selectable window → a uniform StatTile row of summary
// stats (Average / Min / Max / Latest / Δ vs previous window).
//
// On macOS the catalog is driven by a shared MetricCatalog with per-metric formatters
// and a cross-catalog Pearson correlation sweep. On Android the daily metrics we hold
// are the built-in DailyMetric columns (recovery / strain / hrv / rhr / sleep / spo2 /
// respiratory / efficiency) plus any extra long-format keys in the metricSeries table.
// We expose exactly those as the picker, so there is no faked data: every chartable
// metric maps to a real cached series.
//
// macOS "sparse-window" rule preserved: a window is taken RELATIVE TO THE LATEST data
// point (not "now"); if the selected window holds ≥1 point we show it, and only when it
// holds ZERO points do we auto-widen to the smallest larger range that does. The hero
// always reads the latest available point + "as of <day>".

// MARK: - Window range (W / M / 3M / 6M / 1Y / ALL)

private enum class ExploreRange(val days: Int?, val label: String, val windowName: String) {
    Week(7, "W", "week"),
    Month(30, "M", "month"),
    Quarter(90, "3M", "quarter"),
    Half(180, "6M", "6 months"),
    Year(365, "1Y", "year"),
    All(null, "ALL", "all time");

    /** This range plus every larger range, ascending — the auto-widen search order. */
    val widening: List<ExploreRange>
        get() = entries.dropWhile { it != this }
}

// MARK: - Metric descriptor (Android analogue of MetricCatalog's MetricDescriptor)

/**
 * One chartable metric: how to label/format it, its accent, and where its series comes
 * from. [dailyPick] is non-null for built-in DailyMetric columns; otherwise the series
 * is loaded from the metricSeries table under [seriesKey].
 */
private data class MetricSpec(
    val key: String,
    val title: String,
    val unit: String,
    val category: String,
    val accent: Color,
    val higherIsBetter: Boolean?,
    val decimals: Int = 0,
    val dailyPick: ((DailyMetric) -> Double?)? = null,
    val seriesKey: String? = null,
    /** Source (deviceId) the [seriesKey] lives under when it is NOT the strap's own — e.g. the
     *  nutrition-csv import or the noop-mood check-in write under dedicated source ids (v2.2.0
     *  parity with the macOS MetricCatalog, whose descriptors carry key+source). */
    val seriesSource: String? = null,
) {
    fun format(v: Double): String {
        if (!v.isFinite()) return "—"
        val n = if (decimals == 0) "${v.roundToInt()}" else String.format(Locale.US, "%.${decimals}f", v)
        return if (unit.isEmpty()) n else "$n $unit"
    }
}

/** The built-in DailyMetric-backed metrics, in the macOS ordering (Charge first). */
private val builtInMetrics: List<MetricSpec> = listOf(
    MetricSpec(
        key = "recovery", title = "Charge", unit = "%", category = "Charge",
        accent = Palette.accent, higherIsBetter = true, decimals = 0,
        dailyPick = { it.recovery },
    ),
    MetricSpec(
        key = "strain", title = "Effort", unit = "/100", category = "Effort",
        accent = Palette.strain066, higherIsBetter = null, decimals = 1,
        dailyPick = { it.strain },
    ),
    MetricSpec(
        key = "hrv", title = "HRV", unit = "ms", category = "Charge",
        accent = Palette.metricPurple, higherIsBetter = true, decimals = 0,
        dailyPick = { it.avgHrv },
    ),
    MetricSpec(
        key = "rhr", title = "Resting HR", unit = "bpm", category = "Charge",
        accent = Palette.metricRose, higherIsBetter = false, decimals = 0,
        dailyPick = { it.restingHr?.toDouble() },
    ),
    MetricSpec(
        key = "sleep", title = "Sleep", unit = "h", category = "Rest",
        accent = Palette.metricPurple, higherIsBetter = true, decimals = 1,
        dailyPick = { it.totalSleepMin?.let { m -> m / 60.0 } },
    ),
    MetricSpec(
        key = "efficiency", title = "Sleep Efficiency", unit = "%", category = "Rest",
        accent = Palette.accent, higherIsBetter = true, decimals = 0,
        dailyPick = { it.efficiency },
    ),
    MetricSpec(
        key = "spo2", title = "Blood Oxygen", unit = "%", category = "Health",
        accent = Palette.metricCyan, higherIsBetter = true, decimals = 0,
        dailyPick = { it.spo2Pct },
    ),
    MetricSpec(
        key = "resp", title = "Respiratory Rate", unit = "rpm", category = "Health",
        accent = Palette.accent, higherIsBetter = null, decimals = 1,
        dailyPick = { it.respRateBpm },
    ),
)

/** Proper titles/units/categories for series-backed keys written by the importers and the Mind
 *  check-in — matching the macOS MetricCatalog entries exactly (v2.2.0 parity). seriesKey/
 *  seriesSource are filled in at discovery time. */
private val knownSeriesMetrics: Map<String, MetricSpec> = mapOf(
    "calories_in" to MetricSpec("calories_in", "Calories In", "kcal", "Nutrition",
        Palette.metricAmber, null, 0),
    "protein_g" to MetricSpec("protein_g", "Protein", "g", "Nutrition",
        Palette.metricCyan, null, 0),
    "carbs_g" to MetricSpec("carbs_g", "Carbs", "g", "Nutrition",
        Palette.metricCyan, null, 0),
    "fat_g" to MetricSpec("fat_g", "Fat", "g", "Nutrition",
        Palette.metricCyan, null, 0),
    "mood" to MetricSpec("mood", "Mood", "/5", "Mind",
        Palette.metricPurple, true, 0),
)

// MARK: - A loaded series point (day string + value), oldest first.

private data class SeriesPoint(val day: String, val value: Double)

/** Lightweight ordinal day index for slicing windows without date parsing. The series is
 *  already sorted ascending by day (YYYY-MM-DD), so the trailing N entries are the window;
 *  we slice by RELATIVE-TO-LATEST count, matching the macOS day-distance window closely
 *  enough for the per-day daily cache (one row per day). */
private fun List<SeriesPoint>.windowFor(range: ExploreRange): List<SeriesPoint> {
    val days = range.days ?: return this
    if (isEmpty()) return emptyList()
    return takeLast(days)
}

// MARK: - Summary stats over a window

private data class Stat(val n: Int, val mean: Double, val min: Double, val max: Double)

private fun statOf(values: List<Double>): Stat {
    val v = values.filter { it.isFinite() }
    if (v.isEmpty()) return Stat(0, Double.NaN, Double.NaN, Double.NaN)
    return Stat(v.size, v.sum() / v.size, v.min(), v.max())
}

// MARK: - Screen

@Composable
fun TrendsExploreScreen(vm: AppViewModel) {
    val deviceId = "my-whoop"
    val recentDays by vm.recentDays.collectAsStateWithLifecycle()

    // Extra long-format keys from the metricSeries table (anything beyond the built-ins) — from the
    // strap source AND the dedicated import/check-in sources, which write under their OWN deviceIds
    // (nutrition-csv, noop-mood) and were invisible to a strap-only key scan (v2.2.0 parity).
    var extraKeys by remember { mutableStateOf<List<Pair<String, String?>>>(emptyList()) }
    LaunchedEffect(deviceId) {
        val strap = runCatching { vm.repo.metricKeys(deviceId) }.getOrDefault(emptyList())
            .map { it to null as String? }
        val sourced = listOf(NutritionCsvImporter.SOURCE_ID, MoodStore.MOOD_DEVICE_ID).flatMap { src ->
            runCatching { vm.repo.metricKeys(src) }.getOrDefault(emptyList()).map { it to (src as String?) }
        }
        extraKeys = strap + sourced
    }

    // The full picker: built-ins first, then any extra metricSeries keys not already covered.
    // Known import/check-in keys get their proper titles/units/categories (matching the macOS
    // MetricCatalog); anything else falls back to a prettified key under "Other".
    val metrics = remember(extraKeys) {
        val builtInKeys = builtInMetrics.map { it.key }.toSet()
        val extras = extraKeys
            .filter { (k, _) -> k !in builtInKeys }
            .distinctBy { (k, src) -> "$src:$k" }
            .map { (k, src) ->
                val known = knownSeriesMetrics[k]
                known?.copy(seriesKey = k, seriesSource = src) ?: MetricSpec(
                    key = k,
                    title = k.replace('_', ' ').replaceFirstChar { c -> c.uppercase() },
                    unit = "",
                    category = "Other",
                    accent = Palette.metricCyan,
                    higherIsBetter = null,
                    decimals = 1,
                    seriesKey = k,
                    seriesSource = src,
                )
            }
        builtInMetrics + extras
    }

    var selectedKey by remember { mutableStateOf(builtInMetrics.first().key) }
    var range by remember { mutableStateOf(ExploreRange.Month) }
    val selected = metrics.firstOrNull { it.key == selectedKey } ?: metrics.first()

    // Build the full ascending series for the selected metric. Built-ins come straight off
    // the reactive recentDays; metricSeries-backed metrics are loaded on demand.
    var seriesKeyLoaded by remember { mutableStateOf<String?>(null) }
    var loadedSeries by remember { mutableStateOf<List<SeriesPoint>>(emptyList()) }
    LaunchedEffect(selected.key, recentDays) {
        val pick = selected.dailyPick
        if (pick != null) {
            loadedSeries = recentDays.mapNotNull { d ->
                pick(d)?.takeIf { it.isFinite() }?.let { SeriesPoint(d.day, it) }
            }
            seriesKeyLoaded = selected.key
        } else if (selected.seriesKey != null) {
            // Series-backed metrics live under their own source id when imported/checked-in
            // (nutrition-csv, noop-mood) — read from that source, else the strap's (v2.2.0 parity).
            val rows = runCatching {
                vm.repo.metricSeries(selected.seriesSource ?: deviceId, selected.seriesKey, "0000-00-00", "9999-99-99")
            }.getOrDefault(emptyList())
            loadedSeries = rows.map { SeriesPoint(it.day, it.value) }
            seriesKeyLoaded = selected.key
        } else {
            loadedSeries = emptyList()
            seriesKeyLoaded = selected.key
        }
    }

    // Resolve the active window with the macOS sparse-widen rule.
    val series = if (seriesKeyLoaded == selected.key) loadedSeries else emptyList()
    val effectiveRange = remember(series, range) {
        if (series.isEmpty()) range
        else range.widening.firstOrNull { series.windowFor(it).isNotEmpty() } ?: ExploreRange.All
    }
    val windowed = remember(series, effectiveRange) { series.windowFor(effectiveRange) }
    val fellBack = effectiveRange != range

    ScreenScaffold(title = "Explore", subtitle = "Every signal, one tap deep.") {

        // Nothing to explore until history is imported — lead with the verbatim note so
        // the empty picker/chart below is explained.
        if (series.isEmpty()) {
            DataPendingNote(
                title = "Import your history first",
                body = "Import your history first. A WHOOP export in Data Sources fills " +
                    "every metric you can explore here in about a minute.",
            )
        }

        // METRIC PICKER — a dropdown replacing the old horizontal chip row.
        MetricDropdown(
            metrics = metrics,
            selected = selected,
            onSelect = { selectedKey = it },
        )

        // RANGE BAR — overline + title + the one segmented window control, with a caption
        // that flags a sparse auto-widen.
        Row(verticalAlignment = Alignment.Top) {
            Column(modifier = Modifier.weight(1f)) {
                Overline(selected.category)
                Text(selected.title, style = NoopType.title2, color = Palette.textPrimary)
            }
            SegmentedPillControl(
                items = ExploreRange.entries.toList(),
                selection = range,
                label = { it.label },
                onSelect = { range = it },
            )
        }
        Text(
            text = rangeCaption(series, windowed, range, effectiveRange, fellBack),
            style = NoopType.footnote,
            color = if (fellBack) Palette.statusWarning else Palette.textTertiary,
        )

        // HERO CHART — line over the window + latest "as of" read-out in the card.
        HeroChartCard(
            metric = selected,
            windowed = windowed,
            latest = series.lastOrNull(),
            effectiveRange = effectiveRange,
            range = range,
            fellBack = fellBack,
        )

        // STAT ROW — Average / Min / Max / Latest / Δ vs previous window.
        StatRow(
            metric = selected,
            series = series,
            windowed = windowed,
            effectiveRange = effectiveRange,
        )
    }
}

// MARK: - Metric picker dropdown

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun MetricDropdown(
    metrics: List<MetricSpec>,
    selected: MetricSpec,
    onSelect: (String) -> Unit,
) {
    var expanded by remember { mutableStateOf(false) }
    val shape = RoundedCornerShape(Metrics.cornerSm)

    // Group by category for visual section dividers inside the menu.
    val grouped = remember(metrics) { metrics.groupBy { it.category } }

    Box {
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .clip(shape)
                .background(Palette.surfaceInset)
                .border(Metrics.divider, Palette.accent.copy(alpha = StrandAlpha.selectedBorder), shape)
                .clickable { expanded = true }
                .padding(horizontal = 14.dp, vertical = 12.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(10.dp),
        ) {
            Box(
                modifier = Modifier
                    .height(10.dp)
                    .width(10.dp)
                    .clip(RoundedCornerShape(50))
                    .background(selected.accent),
            )
            Column(modifier = Modifier.weight(1f)) {
                Overline(selected.category)
                Text(selected.title, style = NoopType.headline, color = Palette.textPrimary)
            }
            Icon(Icons.Filled.ArrowDropDown, contentDescription = "Pick metric", tint = Palette.textSecondary)
        }

        DropdownMenu(
            expanded = expanded,
            onDismissRequest = { expanded = false },
            modifier = Modifier.background(Palette.surfaceRaised),
        ) {
            grouped.entries.forEachIndexed { groupIdx, (category, items) ->
                if (groupIdx > 0) {
                    Box(modifier = Modifier.fillMaxWidth().height(Metrics.divider).background(Palette.hairline))
                }
                DropdownMenuItem(
                    text = { Overline(category) },
                    onClick = {},
                    enabled = false,
                )
                items.forEach { metric ->
                    DropdownMenuItem(
                        text = {
                            Row(
                                verticalAlignment = Alignment.CenterVertically,
                                horizontalArrangement = Arrangement.spacedBy(10.dp),
                            ) {
                                Box(
                                    modifier = Modifier
                                        .height(8.dp)
                                        .width(8.dp)
                                        .clip(RoundedCornerShape(50))
                                        .background(metric.accent),
                                )
                                Text(
                                    metric.title,
                                    style = NoopType.body,
                                    color = if (metric.key == selected.key) Palette.accent else Palette.textPrimary,
                                )
                            }
                        },
                        onClick = {
                            onSelect(metric.key)
                            expanded = false
                        },
                    )
                }
            }
        }
    }
}

// MARK: - Hero chart card

@Composable
private fun HeroChartCard(
    metric: MetricSpec,
    windowed: List<SeriesPoint>,
    latest: SeriesPoint?,
    effectiveRange: ExploreRange,
    range: ExploreRange,
    fellBack: Boolean,
) {
    val heroValue = latest?.let { metric.format(it.value) } ?: "—"
    val asOf = latest?.let { "as of ${it.day}" } ?: "no readings yet"
    val subtitle = if (fellBack) {
        "Sparse — widened to ${effectiveRange.windowName} · ${windowed.size} readings"
    } else {
        "${windowed.size} readings · ${range.windowName}"
    }
    NoopCard {
        Column(verticalArrangement = Arrangement.spacedBy(Metrics.gap)) {
            Row(verticalAlignment = Alignment.Top) {
                Column(modifier = Modifier.weight(1f)) {
                    Overline(metric.title)
                    Text(subtitle, style = NoopType.footnote, color = Palette.textTertiary)
                }
                Column(horizontalAlignment = Alignment.End) {
                    Text(heroValue, style = NoopType.number(20f), color = metric.accent)
                    Text(asOf, style = NoopType.footnote, color = Palette.textTertiary)
                }
            }

            if (windowed.size >= 2) {
                LineChart(
                    values = windowed.map { it.value },
                    modifier = Modifier.height(Metrics.chartHeight),
                    color = metric.accent,
                    fill = true,
                    selectionEnabled = true,
                )
            } else {
                Box(
                    modifier = Modifier
                        .fillMaxWidth()
                        .height(Metrics.chartHeight),
                    contentAlignment = Alignment.Center,
                ) {
                    Text(
                        if (windowed.isEmpty()) {
                            "No ${metric.title.lowercase()} recorded yet. Sync your strap to populate this trend."
                        } else {
                            "Only one reading in range — widen the window to see a trend."
                        },
                        style = NoopType.subhead,
                        color = Palette.textTertiary,
                    )
                }
            }

            // Footer chips, mirroring the macOS ChartFooter (Window / Points / Latest).
            Row(horizontalArrangement = Arrangement.spacedBy(Metrics.sectionGap)) {
                ChartFootItem("Window", effectiveRange.label)
                ChartFootItem("Points", "${windowed.size}")
                ChartFootItem("Latest", heroValue)
            }
        }
    }
}

@Composable
private fun ChartFootItem(label: String, value: String) {
    Column {
        Overline(label, color = Palette.textTertiary)
        Text(value, style = NoopType.captionNumber, color = Palette.textSecondary)
    }
}

// MARK: - Stat tile row

@Composable
private fun StatRow(
    metric: MetricSpec,
    series: List<SeriesPoint>,
    windowed: List<SeriesPoint>,
    effectiveRange: ExploreRange,
) {
    val values = windowed.map { it.value }
    val s = statOf(values)
    val latest = series.lastOrNull()

    // Δ vs the previous equal-length window (by point count), tinted by higherIsBetter.
    val prev = remember(series, windowed) { previousWindow(series, windowed) }
    val prevStat = statOf(prev.map { it.value })
    val hasDelta = s.n > 0 && prevStat.n > 0
    val delta = if (hasDelta) s.mean - prevStat.mean else Double.NaN
    val deltaText = if (hasDelta) signed(metric, delta) else "—"
    val pctChange = if (hasDelta && prevStat.mean != 0.0) {
        ((s.mean - prevStat.mean) / abs(prevStat.mean)) * 100.0
    } else null
    val deltaColor: Color = run {
        val better = metric.higherIsBetter
        if (!hasDelta || delta == 0.0 || better == null) Palette.textTertiary
        else if ((delta > 0) == better) Palette.statusPositive else Palette.statusCritical
    }
    val deltaCaption = when {
        hasDelta -> "vs prev ${effectiveRange.windowName}"
        effectiveRange == ExploreRange.All -> "all history"
        else -> "no prior ${effectiveRange.windowName}"
    }

    Column(verticalArrangement = Arrangement.spacedBy(Metrics.gap)) {
        SectionHeader("Summary", overline = "Over the visible window", trailing = "${s.n} pts")

        Row(horizontalArrangement = Arrangement.spacedBy(Metrics.gap)) {
            StatTile(
                modifier = Modifier.weight(1f),
                label = "Average",
                value = if (s.n > 0) metric.format(s.mean) else "—",
                caption = "${s.n} days",
                accent = metric.accent,
            )
            StatTile(
                modifier = Modifier.weight(1f),
                label = "Min",
                value = if (s.n > 0) metric.format(s.min) else "—",
                accent = Palette.textPrimary,
            )
            StatTile(
                modifier = Modifier.weight(1f),
                label = "Max",
                value = if (s.n > 0) metric.format(s.max) else "—",
                accent = Palette.textPrimary,
            )
        }
        Row(horizontalArrangement = Arrangement.spacedBy(Metrics.gap)) {
            StatTile(
                modifier = Modifier.weight(1f),
                label = "Latest",
                value = latest?.let { metric.format(it.value) } ?: "—",
                caption = latest?.day,
                accent = metric.accent,
            )
            StatTile(
                modifier = Modifier.weight(1f),
                label = "Δ vs prev",
                value = deltaText,
                caption = deltaCaption,
                accent = Palette.textPrimary,
                delta = pctChange?.let { "${if (it >= 0) "+" else ""}${String.format(Locale.US, "%.1f", it)}%" },
                deltaColor = deltaColor,
            )
            // Pad the row to three columns so tiles keep equal width with the row above.
            Spacer(Modifier.weight(1f))
        }
    }
}

// MARK: - Window / formatting helpers

/** The window immediately preceding [windowed] (equal length, by point count). */
private fun previousWindow(
    series: List<SeriesPoint>,
    windowed: List<SeriesPoint>,
): List<SeriesPoint> {
    val size = windowed.size
    if (size == 0 || series.size <= size) return emptyList()
    val firstDay = windowed.firstOrNull()?.day ?: return emptyList()
    val lo = series.indexOfFirst { it.day == firstDay }
    if (lo <= 0) return emptyList()
    val prevLo = (lo - size).coerceAtLeast(0)
    return series.subList(prevLo, lo)
}

private fun signed(metric: MetricSpec, delta: Double): String {
    val sign = if (delta >= 0) "+" else "−"
    return sign + metric.format(abs(delta))
}

private fun rangeCaption(
    series: List<SeriesPoint>,
    windowed: List<SeriesPoint>,
    range: ExploreRange,
    effectiveRange: ExploreRange,
    fellBack: Boolean,
): String {
    if (series.isEmpty()) return "—"
    val n = windowed.size
    val unit = if (n == 1) "reading" else "readings"
    return if (fellBack) "$n $unit · sparse — widened to ${effectiveRange.windowName}"
    else "$n $unit · ${range.windowName}"
}

// MARK: - Small interaction helper (clickable row, default ripple)

private fun Modifier.clickableRow(onClick: () -> Unit): Modifier =
    this.clickable(onClick = onClick)
