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
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.noop.analytics.Baselines
import com.noop.analytics.VitalBands
import com.noop.ble.LiveState
import com.noop.data.DailyMetric
import java.time.LocalDate
import java.time.format.DateTimeFormatter
import java.util.Locale
import kotlin.math.roundToInt

// MARK: - Health Monitor (ported from Strand/Screens/HealthView.swift)
//
// Live heart-rate hero (streaming HR + HR-zone read-out, derived from the strap's
// R-R stream when the HR field reads 0), then a uniform grid of the body's vital
// signs (respiratory rate, blood O2, resting HR, HRV, skin temp) as fixed-height
// StatTiles, each tinted and captioned with its in-range state. Re-skinned to the
// locked NOOP component system: every surface is a NoopCard/StatTile, every chart
// is a Canvas chart — no ad-hoc card heights or paddings.
//
// macOS parity note: live HR zone/%max reads the user's ProfileStore max heart rate,
// matching Settings/onboarding. SpO2 / respiratory / skin-temp are sleep-window
// aggregates, so the "Vital Signs" grid is sourced from today's DailyMetric.

@Composable
fun HealthScreen(vm: AppViewModel, onVitalClick: (String) -> Unit = {}) {
    val context = LocalContext.current
    val profile = remember { ProfileStore.from(context.applicationContext) }
    val live by vm.live.collectAsStateWithLifecycle()
    val today by vm.today.collectAsStateWithLifecycle()
    // Full merged daily history — feeds the personal-baseline banding of the vitals grid.
    val days by vm.recentDays.collectAsStateWithLifecycle()
    val hrMax = profile.hrMax

    // Health Monitor shows live HR too, so it must keep the realtime stream on while it's visible —
    // otherwise leaving the Live page stopped the stream and this page froze (issue #18). Ref-counted
    // in the ViewModel, so handing off between Live and here never drops the stream.
    DisposableEffect(Unit) {
        vm.requestRealtimeHr()
        onDispose { vm.releaseRealtimeHr() }
    }

    val displayHr = displayHr(live)
    val hasLiveHr = displayHr != null

    ScreenScaffold(
        title = "Health Monitor",
        subtitle = "Live vitals, streamed from the strap.",
    ) {
        if (today == null && !hasLiveHr) {
            HealthEmptyState()
        } else {
            // ScreenScaffold applies a 20dp arrangement gap between its direct children;
            // a small top-up reaches the section gap (28dp) used between macOS sections.
            HeartRateSection(live = live, hrMax = hrMax)
            Spacer(Modifier.height(Metrics.sectionGap - 20.dp))
            VitalsSection(
                title = "Vital Signs",
                overline = "Latest readings",
                trailing = null,
                vitals = latestVitals(days, UnitPrefs.temperature(LocalContext.current)),
                onVitalClick = onVitalClick,
            )
        }
    }
}

@Composable
fun VitalSignsScreen(vm: AppViewModel, onVitalClick: (String) -> Unit = {}) {
    val days by vm.recentDays.collectAsStateWithLifecycle()
    var selectedDayOffset by remember { mutableIntStateOf(0) }
    val selectedDay = remember(selectedDayOffset) { LocalDate.now().minusDays(selectedDayOffset.toLong()) }
    val selectedDayKey = remember(selectedDay) { selectedDay.toString() }
    val selectedMetric = remember(days, selectedDayKey) { days.lastOrNull { it.day == selectedDayKey } }
    val tempUnit = UnitPrefs.temperature(LocalContext.current)
    val vitals = remember(selectedMetric, days, tempUnit) {
        selectedMetric?.let { vitalsFor(it, days, tempUnit) }.orEmpty()
    }

    ScreenScaffold(
        title = "Vital Signs",
        subtitle = "Historical vitals from your cached daily metrics.",
    ) {
        RecentDaySelectorBar(selectedOffset = selectedDayOffset, onSelect = { selectedDayOffset = it })
        if (selectedMetric == null || vitals.all { it.value == null }) {
            DataPendingNote(
                title = missingVitalsTitle(selectedDayOffset),
                body = "Try Yesterday or 2 days ago from the bar above if the strap or import did not produce a daily vitals snapshot yet.",
            )
        } else {
            VitalsSection(
                title = "Vital Signs",
                overline = selectedDayLabel(selectedDayOffset),
                trailing = "as of ${selectedMetric.day}",
                vitals = vitals,
                onVitalClick = onVitalClick,
                footer = false,
            )
        }
    }
}

// MARK: - Derived live HR
//
// HR to display: the reported value when > 0, else derived from the latest R-R
// interval in milliseconds (the strap streams R-R even when its HR field reads 0).

private fun displayHr(live: LiveState): Int? {
    live.heartRate?.let { if (it > 0) return it }
    val lastRr = live.rr.lastOrNull()
    if (lastRr != null && lastRr > 0) return (60_000.0 / lastRr).roundToInt()
    return null
}

private fun hrIsDerived(live: LiveState): Boolean =
    (live.heartRate ?: 0) <= 0 && live.rr.isNotEmpty()

/** HR as a fraction of HR-max (0..1). */
private fun hrFraction(hr: Int?, hrMax: Int): Double {
    if (hr == null || hrMax <= 0) return 0.0
    return (hr.toDouble() / hrMax).coerceIn(0.0, 1.0)
}

/** Current zone 1..5 from %HR-max (WHOOP/Karvonen-style bands: 50/60/70/80/90). */
private fun hrZone(fraction: Double): Int = when {
    fraction < 0.60 -> 1
    fraction < 0.70 -> 2
    fraction < 0.80 -> 3
    fraction < 0.90 -> 4
    else -> 5
}

/** A short HR series for the hero chart. Prefers the accumulated live-HR history (which moves over
 *  time); falls back to per-beat HR from R-R, then to a flat pair while the buffer fills. The old
 *  version derived ONLY from R-R, which is sparse on WHOOP 4, so it sat on a flat 2-point line even
 *  while HR was clearly changing (issue #18). */
private fun hrSeries(history: List<Int>, live: LiveState, hr: Int?): List<Double> {
    if (history.size > 1) return history.map { it.toDouble() }
    val beats = live.rr.takeLast(60).mapNotNull { rr ->
        if (rr > 0) 60_000.0 / rr else null
    }
    if (beats.size > 1) return beats
    if (hr != null) return listOf(hr.toDouble(), hr.toDouble())
    return emptyList()
}

// MARK: - Heart rate hero (live)

@Composable
private fun HeartRateSection(live: LiveState, hrMax: Int) {
    val displayHr = displayHr(live)
    val hasLiveHr = displayHr != null
    val derived = hrIsDerived(live)
    val fraction = hrFraction(displayHr, hrMax)
    val zone = hrZone(fraction)
    // Accumulate the streamed HR over time so the hero chart actually moves (issue #18 — it used to
    // derive from sparse R-R and flat-line). Lives in UI state; resets when you leave the screen.
    val hrHistory = remember { mutableStateListOf<Int>() }
    LaunchedEffect(displayHr) {
        displayHr?.let { if (it in 30..220) {
            hrHistory.add(it)
            if (hrHistory.size > 90) hrHistory.removeAt(0)
        } }
    }
    val series = hrSeries(hrHistory, live, displayHr)
    val zoneColor = Palette.hrZoneColor(zone)

    Column(verticalArrangement = Arrangement.spacedBy(Metrics.gap)) {
        SectionHeader(
            title = "Heart Rate",
            overline = "Live",
            trailing = if (derived) "from R-R" else null,
        )

        NoopCard(padding = 18.dp) {
            Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
                // Card header: title + subtitle on the left, live bpm read-out right.
                Row(
                    modifier = Modifier.fillMaxWidth(),
                    verticalAlignment = Alignment.Top,
                ) {
                    Column(modifier = Modifier.weight(1f)) {
                        Text("Heart Rate", style = NoopType.headline, color = Palette.textPrimary)
                        Text(
                            text = when {
                                derived -> "Estimated from R-R interval"
                                hasLiveHr -> "Streaming live"
                                else -> "Awaiting strap"
                            },
                            style = NoopType.footnote,
                            color = Palette.textSecondary,
                        )
                    }
                    Text(
                        text = if (hasLiveHr) "$displayHr bpm" else "—",
                        style = NoopType.number(15f),
                        color = if (hasLiveHr) zoneColor else Palette.textTertiary,
                    )
                }

                // Hero chart: a tall HR line tinted to the current zone, with a status
                // pill floated top-trailing. Falls back to a big number when R-R is sparse.
                Box(
                    modifier = Modifier
                        .fillMaxWidth()
                        .height(Metrics.chartHeight),
                ) {
                    if (series.size > 1) {
                        LineChart(
                            values = series,
                            modifier = Modifier.fillMaxWidth().height(Metrics.chartHeight),
                            color = zoneColor,
                            fill = true,
                        )
                    } else {
                        Column(
                            modifier = Modifier.fillMaxWidth().height(Metrics.chartHeight),
                            horizontalAlignment = Alignment.CenterHorizontally,
                            verticalArrangement = Arrangement.Center,
                        ) {
                            Text(
                                text = displayHr?.toString() ?: "—",
                                style = NoopType.display(72f),
                                color = if (hasLiveHr) zoneColor else Palette.textTertiary,
                            )
                            Text("bpm", style = NoopType.subhead, color = Palette.textTertiary)
                        }
                    }

                    StatePill(
                        title = zoneLabel(hasLiveHr, zone, fraction),
                        tone = if (hasLiveHr) StrandTone.Accent else StrandTone.Neutral,
                        showsDot = hasLiveHr,
                        pulsing = hasLiveHr,
                        modifier = Modifier.align(Alignment.TopEnd),
                    )
                }

                // Footer read-out row: Zone · % Max · Max HR · State.
                HeartRateFooter(
                    zone = if (hasLiveHr) "Z$zone" else "—",
                    percentMax = if (hasLiveHr) "${(fraction * 100).roundToInt()}%" else "—",
                    maxHr = "$hrMax",
                    state = if (hasLiveHr) "STREAMING" else "IDLE",
                )
            }
        }
    }
}

private fun zoneLabel(hasLiveHr: Boolean, zone: Int, fraction: Double): String {
    if (!hasLiveHr) return "Idle"
    return "Zone $zone · ${(fraction * 100).roundToInt()}%"
}

@Composable
private fun HeartRateFooter(zone: String, percentMax: String, maxHr: String, state: String) {
    Row(modifier = Modifier.fillMaxWidth().padding(top = 4.dp)) {
        FooterStat("Zone", zone, Modifier.weight(1f))
        FooterStat("% Max", percentMax, Modifier.weight(1f))
        FooterStat("Max HR", maxHr, Modifier.weight(1f))
        FooterStat("State", state, Modifier.weight(1f))
    }
}

@Composable
private fun FooterStat(label: String, value: String, modifier: Modifier = Modifier) {
    Column(modifier = modifier, verticalArrangement = Arrangement.spacedBy(2.dp)) {
        Overline(label)
        Text(value, style = NoopType.captionNumber, color = Palette.textPrimary)
    }
}

// MARK: - Vitals grid (uniform StatTiles)

@Composable
private fun VitalsSection(
    title: String,
    overline: String,
    trailing: String? = null,
    vitals: List<Vital>,
    onVitalClick: (String) -> Unit,
    footer: Boolean = true,
) {
    // Temperature display preference (D#103). Skin temp is stored in °C; the toggle re-labels it to °F.
    // Display-only — banding still runs on the stored °C value.
    Column(verticalArrangement = Arrangement.spacedBy(Metrics.gap)) {
        SectionHeader(title = title, overline = overline, trailing = trailing)

        // A uniform 2-column grid of fixed-height tiles. The macOS LazyVGrid is
        // adaptive(min: 168); on phones two columns is the faithful equivalent.
        vitals.chunked(2).forEach { rowVitals ->
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.spacedBy(Metrics.gap),
            ) {
                rowVitals.forEach { v ->
                    VitalTile(
                        modifier = Modifier
                            .weight(1f)
                            .clickable { onVitalClick(v.key) }
                            .semantics { contentDescription = v.accessibilityText },
                        vital = v,
                        value = v.formattedValue ?: "—",
                        caption = v.asOfLabel ?: v.stateCaption,
                        accent = v.accent,
                    )
                }
                // Pad an odd final row so the tile keeps half-width, matching the grid.
                if (rowVitals.size == 1) Spacer(Modifier.weight(1f))
            }
        }

        if (footer) {
            Text(
                text = "SpO₂, respiratory rate and skin temperature are sleep-window " +
                    "aggregates from your most recent imported day; resting HR and HRV update daily. " +
                    "Once NOOP has 14 nights of history, in-range compares each vital to your own " +
                    "baseline (approximate — not medical advice); until then typical adult ranges apply.",
                style = NoopType.footnote,
                color = Palette.textTertiary,
            )
        }
    }
}

// MARK: - Vital model

private data class Vital(
    val key: String,
    val label: String,
    val unit: String,
    val value: Double?,
    val format: (Double) -> String,
    val deltaText: String? = null,
    val readingDay: String? = null,
    val asOfLabel: String? = null,
    /** Personal-baseline banding (population fallback until 14 trusted nights). */
    val banding: VitalBands.Result,
    /** The metric's category colour (used only when in range). */
    val metricColor: Color,
) {
    /** Value with its unit appended, or null when no data. */
    val formattedValue: String? = value?.let { "${format(it)} $unit" }

    /** Colour communicates state: in-range = the metric's category colour,
     *  out-of-range = warning amber, no data = tertiary. */
    val accent: Color = when (banding.band) {
        VitalBands.Band.NO_DATA -> Palette.textTertiary
        VitalBands.Band.IN_RANGE -> metricColor
        VitalBands.Band.OUT_OF_RANGE -> Palette.statusWarning
    }

    /** The in-range caption that stands in for a StatePill inside the fixed-height tile.
     *  The wording says which yardstick judged it: your baseline vs typical ranges. */
    val stateCaption: String = when {
        banding.band == VitalBands.Band.NO_DATA -> "No data"
        banding.basis == VitalBands.Basis.PERSONAL ->
            if (banding.band == VitalBands.Band.IN_RANGE) "In your range" else "Off your baseline"
        else ->
            if (banding.band == VitalBands.Band.IN_RANGE) "In typical range" else "Outside typical range"
    }

    val accessibilityText: String =
        formattedValue?.let {
            listOfNotNull("$label: $it", asOfLabel, stateCaption).joinToString(", ")
        } ?: "$label: no data"
}

/** Build the vitals, banded against the user's OWN trailing baseline once 14 trusted
 *  nights exist (population ranges before that — VitalBands does the deciding). */
private fun vitalsFor(
    d: DailyMetric?,
    days: List<DailyMetric>,
    tempUnit: TemperatureUnit = TemperatureUnit.CELSIUS,
): List<Vital> {
    val todayKey = d?.day
    // History strictly before the displayed day, oldest→newest (recentDays is already
    // oldest→newest); calendar-padded so wear gaps count as missing nights (a stale
    // baseline then falls back to the population range).
    val history = days.filter { row -> todayKey == null || row.day < todayKey }
    fun series(selector: (DailyMetric) -> Double?): List<Double?> =
        VitalBands.calendarSeries(history.map { it.day to selector(it) })
    fun previous(selector: (DailyMetric) -> Double?): Double? =
        history.asReversed().asSequence().mapNotNull(selector).firstOrNull()
    fun deltaText(current: Double?, previous: Double?, decimals: Int = 1): String? {
        if (current == null || previous == null) return null
        val diff = current - previous
        val sign = if (diff >= 0.0) "+" else "-"
        val mag = kotlin.math.abs(diff)
        val num = if (decimals == 0) mag.roundToInt().toString()
        else String.format(Locale.US, "%.${decimals}f", mag)
        return "($sign$num)"
    }

    // Skin temp is bimodal: CSV imports store ABSOLUTE °C, the on-device pipeline a ±°C
    // DEVIATION — partition the history to the displayed value's kind and pick the matching
    // config + population fallback (±0.6 °C mirrors the illness watch's flag threshold).
    // This also fixes the live bug where a strap-computed +0.2 °C deviation read
    // "Out of range" against the 33–36 absolute band.
    val skin = d?.skinTempDevC
    // Track which kind the value is so the temperature converter picks the right rule: an ABSOLUTE
    // reading uses the full C→F formula (×9/5 + 32); a ±DEVIATION must omit the offset.
    val skinIsAbsolute = skin?.let { VitalBands.isAbsoluteSkinTemp(it) } ?: true
    val skinResult: VitalBands.Result = if (skin == null) {
        VitalBands.Result(VitalBands.Band.NO_DATA, VitalBands.Basis.POPULATION, 0)
    } else {
        VitalBands.band(
            value = skin,
            history = VitalBands.skinTempHistory(skin, series { it.skinTempDevC }),
            populationRange = if (skinIsAbsolute) 33.0..36.0 else -0.6..0.6,
            cfg = if (skinIsAbsolute) Baselines.metricCfg.getValue("skin_temp") else VitalBands.skinTempDeviationCfg,
        )
    }
    // Resolve the skin-temp label + converter once, honouring the °C/°F preference. `Vital.formattedValue`
    // appends `unit`, so strip the trailing " °C/°F" the formatter adds.
    val skinUnitLabel = UnitFormatter.temperatureUnit(tempUnit)
    val skinFormat: (Double) -> String = { c ->
        val full = if (skinIsAbsolute) {
            UnitFormatter.temperatureFromCelsius(c, tempUnit, decimals = 1)
        } else {
            UnitFormatter.temperatureDeltaFromCelsius(c, tempUnit, decimals = 1)
        }
        full.removeSuffix(" $skinUnitLabel")
    }
    val previousSkin = history.asReversed().asSequence()
        .mapNotNull { row -> row.skinTempDevC?.takeIf { VitalBands.isAbsoluteSkinTemp(it) == skinIsAbsolute } }
        .firstOrNull()
    return listOf(
        Vital(
            key = "resp", label = "Resp Rate", unit = "rpm",
            value = d?.respRateBpm, format = { String.format("%.1f", it) },
            deltaText = deltaText(d?.respRateBpm, previous { it.respRateBpm }),
            readingDay = todayKey,
            asOfLabel = asOfLabel(todayKey),
            banding = VitalBands.band(d?.respRateBpm, series { it.respRateBpm }, 12.0..20.0, Baselines.respCfg),
            metricColor = Palette.metricCyan,
        ),
        Vital(
            key = "spo2", label = "Blood O₂", unit = "%",
            value = d?.spo2Pct, format = { String.format("%.0f", it) },
            deltaText = deltaText(d?.spo2Pct, previous { it.spo2Pct }, decimals = 0),
            readingDay = todayKey,
            asOfLabel = asOfLabel(todayKey),
            // Population-only on purpose: an absolute <95% floor is meaningful regardless
            // of personal baseline (no "spo2" MetricCfg exists).
            banding = VitalBands.band(d?.spo2Pct, emptyList(), 95.0..100.0, null),
            metricColor = Palette.metricCyan,
        ),
        Vital(
            key = "rhr", label = "Resting HR", unit = "bpm",
            value = d?.restingHr?.toDouble(), format = { it.roundToInt().toString() },
            deltaText = deltaText(d?.restingHr?.toDouble(), previous { it.restingHr?.toDouble() }, decimals = 0),
            readingDay = todayKey,
            asOfLabel = asOfLabel(todayKey),
            banding = VitalBands.band(
                d?.restingHr?.toDouble(), series { it.restingHr?.toDouble() }, 40.0..60.0,
                Baselines.restingHRCfg,
            ),
            metricColor = Palette.metricRose,
        ),
        Vital(
            key = "hrv", label = "HRV", unit = "ms",
            value = d?.avgHrv, format = { it.roundToInt().toString() },
            deltaText = deltaText(d?.avgHrv, previous { it.avgHrv }, decimals = 0),
            readingDay = todayKey,
            asOfLabel = asOfLabel(todayKey),
            banding = VitalBands.band(d?.avgHrv, series { it.avgHrv }, 40.0..120.0, Baselines.hrvCfg),
            metricColor = Palette.metricPurple,
        ),
        Vital(
            key = "skin", label = "Skin Temp", unit = skinUnitLabel,
            value = skin, format = skinFormat,
            deltaText = deltaText(skin, previousSkin),
            readingDay = todayKey,
            asOfLabel = asOfLabel(todayKey),
            banding = skinResult, metricColor = Palette.metricAmber,
        ),
    )
}

@Composable
private fun VitalTile(
    vital: Vital,
    modifier: Modifier = Modifier,
    value: String = vital.formattedValue ?: "—",
    caption: String = vital.stateCaption,
    accent: Color = vital.accent,
) {
    NoopCard(modifier = modifier.height(Metrics.tileHeight), padding = 14.dp) {
        Column {
            Overline(vital.label)
            if (vital.deltaText != null) {
                Text(vital.deltaText, style = NoopType.footnote, color = Palette.textTertiary)
            } else {
                Spacer(Modifier.height(16.dp))
            }
            Spacer(Modifier.weight(1f))
            Text(
                text = value,
                style = NoopType.number(26f),
                color = accent,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
            Text(
                text = caption,
                style = NoopType.footnote,
                color = Palette.textTertiary,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
                modifier = Modifier.padding(top = 2.dp),
            )
        }
    }
}

private data class VitalDetailModel(
    val key: String,
    val title: String,
    val unit: String,
    val color: Color,
    val points: List<Pair<String, Double>>,
    val format: (Double) -> String,
)

@Composable
fun VitalDetailScreen(vm: AppViewModel, key: String) {
    val days by vm.recentDays.collectAsStateWithLifecycle()
    val tempUnit = UnitPrefs.temperature(LocalContext.current)
    val detail = remember(days, key, tempUnit) { buildVitalDetail(days, key, tempUnit) }
    var range by remember { mutableStateOf(VitalDetailRange.MONTH) }

    ScreenScaffold(
        title = detail?.title ?: "Vital Signs",
        subtitle = "Historical trend from cached daily metrics.",
    ) {
        if (detail == null || detail.points.size < 2) {
            DataPendingNote(
                title = "Not enough history yet",
                body = "This vital needs at least two historical readings before NOOP can chart it.",
            )
            return@ScreenScaffold
        }

        val filteredPoints = remember(detail, range) { filterVitalPoints(detail.points, range) }
        if (filteredPoints.size < 2) {
            DataPendingNote(
                title = "Not enough history in this range",
                body = "Try a longer interval like 3M, 6M, or ALL to see this vital’s trend.",
            )
            return@ScreenScaffold
        }

        val values = filteredPoints.map { it.second }
        val latest = filteredPoints.last()
        val min = values.minOrNull()
        val max = values.maxOrNull()
        val avg = values.average()

        SectionHeader(detail.title, overline = "Vital Signs", trailing = "${filteredPoints.size} readings")
        NoopCard {
            Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
                Row(verticalAlignment = Alignment.Top) {
                    Column(modifier = Modifier.weight(1f)) {
                        Overline("Latest")
                        Text(
                            text = "${detail.format(latest.second)} ${detail.unit}".trim(),
                            style = NoopType.number(22f),
                            color = detail.color,
                        )
                        Text(
                            text = "as of ${latest.first}",
                            style = NoopType.footnote,
                            color = Palette.textTertiary,
                        )
                    }
                }
                SegmentedPillControl(
                    items = VitalDetailRange.entries,
                    selection = range,
                    label = { it.label },
                    onSelect = { range = it },
                )
                LineChart(
                    values = values,
                    modifier = Modifier.height(Metrics.chartHeight),
                    color = detail.color,
                    fill = true,
                )
                Box(
                    modifier = Modifier
                        .fillMaxWidth()
                        .height(1.dp)
                        .background(Palette.hairline),
                )
                Row(modifier = Modifier.fillMaxWidth()) {
                    listOf(
                        "Min" to min,
                        "Avg" to avg,
                        "Max" to max,
                    ).forEach { (label, metric) ->
                        Column(modifier = Modifier.weight(1f)) {
                            Overline(label, color = Palette.textTertiary)
                            Text(
                                text = metric?.let { "${detail.format(it)} ${detail.unit}".trim() } ?: "—",
                                style = NoopType.bodyNumber,
                                color = Palette.textPrimary,
                            )
                        }
                    }
                }
            }
        }
    }
}

@Composable
private fun RecentDaySelectorBar(selectedOffset: Int, onSelect: (Int) -> Unit) {
    val base = LocalDate.now()
    val blockShape = RoundedCornerShape(12.dp)
    Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        listOf(2, 1, 0).forEach { offset ->
            val day = base.minusDays(offset.toLong())
            val selected = selectedOffset == offset
            val label = when (offset) {
                0 -> "Today"
                1 -> "Yesterday"
                else -> "2 days ago"
            }
            val date = day.format(DateTimeFormatter.ofPattern("d MMM", Locale.US))
            Column(
                modifier = Modifier
                    .weight(1f)
                    .clip(blockShape)
                    .background(if (selected) Palette.accent.copy(alpha = 0.12f) else Palette.surfaceInset)
                    .border(
                        width = 1.dp,
                        color = if (selected) Palette.accent.copy(alpha = 0.55f) else Palette.hairline,
                        shape = blockShape,
                    )
                    .clickable { onSelect(offset) }
                    .padding(vertical = 10.dp, horizontal = 10.dp),
                horizontalAlignment = Alignment.CenterHorizontally,
            ) {
                Text(
                    text = label,
                    style = NoopType.caption,
                    color = if (selected) Palette.textPrimary else Palette.textSecondary,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
                Text(
                    text = date,
                    style = NoopType.captionNumber,
                    color = if (selected) Palette.accent else Palette.textTertiary,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                    modifier = Modifier.padding(top = 2.dp),
                )
            }
        }
    }
}

private fun latestVitals(days: List<DailyMetric>, tempUnit: TemperatureUnit): List<Vital> {
    val emptyByKey = vitalsFor(null, days, tempUnit).associateBy { it.key }
    return listOf(
        latestVital("resp", days, tempUnit, emptyByKey) { it.respRateBpm != null },
        latestVital("spo2", days, tempUnit, emptyByKey) { it.spo2Pct != null },
        latestVital("rhr", days, tempUnit, emptyByKey) { it.restingHr != null },
        latestVital("hrv", days, tempUnit, emptyByKey) { it.avgHrv != null },
        latestVital("skin", days, tempUnit, emptyByKey) { it.skinTempDevC != null },
    )
}

private fun latestVital(
    key: String,
    days: List<DailyMetric>,
    tempUnit: TemperatureUnit,
    emptyByKey: Map<String, Vital>,
    hasValue: (DailyMetric) -> Boolean,
): Vital {
    val row = days.asReversed().firstOrNull(hasValue)
    return row
        ?.let { latestRow -> vitalsFor(latestRow, days, tempUnit).firstOrNull { it.key == key } }
        ?.copy(asOfLabel = asOfLabel(row.day))
        ?: emptyByKey.getValue(key)
}

private fun selectedDayLabel(offset: Int): String = when (offset) {
    0 -> "Today"
    1 -> "Yesterday"
    else -> "2 days ago"
}

private fun missingVitalsTitle(offset: Int): String = when (offset) {
    0 -> "We didn't get today's data"
    1 -> "We didn't get yesterday's data"
    else -> "We didn't get data from 2 days ago"
}

private fun asOfLabel(day: String?): String? {
    if (day.isNullOrBlank()) return null
    val date = runCatching { LocalDate.parse(day) }.getOrNull() ?: return "as of $day"
    val today = LocalDate.now()
    return when (date) {
        today -> "as of today"
        today.minusDays(1) -> "as of yesterday"
        else -> "as of ${date.format(DateTimeFormatter.ofPattern("d MMM", Locale.US))}"
    }
}

private enum class VitalDetailRange(val label: String, val days: Long?) {
    WEEK("W", 7),
    MONTH("M", 30),
    THREE_MONTH("3M", 90),
    SIX_MONTH("6M", 180),
    ALL("ALL", null),
}

private fun filterVitalPoints(
    points: List<Pair<String, Double>>,
    range: VitalDetailRange,
): List<Pair<String, Double>> {
    val windowDays = range.days ?: return points
    val latestDate = points.lastOrNull()?.first?.let { runCatching { LocalDate.parse(it) }.getOrNull() }
        ?: return points.takeLast(windowDays.toInt())
    val cutoff = latestDate.minusDays(windowDays - 1)
    val filtered = points.filter { (day, _) ->
        runCatching { LocalDate.parse(day) }.getOrNull()?.let { !it.isBefore(cutoff) } ?: false
    }
    return filtered.ifEmpty { points.takeLast(windowDays.toInt()) }
}

private fun buildVitalDetail(
    days: List<DailyMetric>,
    key: String,
    tempUnit: TemperatureUnit,
): VitalDetailModel? {
    return when (key) {
    "resp" -> VitalDetailModel(
        key = key,
        title = "Respiratory Rate",
        unit = "rpm",
        color = Palette.metricCyan,
        points = days.mapNotNull { it.respRateBpm?.let { value -> it.day to value } },
        format = { String.format(Locale.US, "%.1f", it) },
    )
    "spo2" -> VitalDetailModel(
        key = key,
        title = "Blood Oxygen",
        unit = "%",
        color = Palette.metricCyan,
        points = days.mapNotNull { it.spo2Pct?.let { value -> it.day to value } },
        format = { String.format(Locale.US, "%.0f", it) },
    )
    "rhr" -> VitalDetailModel(
        key = key,
        title = "Resting Heart Rate",
        unit = "bpm",
        color = Palette.metricRose,
        points = days.mapNotNull { it.restingHr?.toDouble()?.let { value -> it.day to value } },
        format = { it.roundToInt().toString() },
    )
    "hrv" -> VitalDetailModel(
        key = key,
        title = "Heart Rate Variability",
        unit = "ms",
        color = Palette.metricPurple,
        points = days.mapNotNull { it.avgHrv?.let { value -> it.day to value } },
        format = { it.roundToInt().toString() },
    )
    "skin" -> {
        val latest = days.asReversed().asSequence().mapNotNull { it.skinTempDevC }.firstOrNull() ?: return null
        val absolute = VitalBands.isAbsoluteSkinTemp(latest)
        val unit = UnitFormatter.temperatureUnit(tempUnit)
        val format: (Double) -> String = { c ->
            val full = if (absolute) {
                UnitFormatter.temperatureFromCelsius(c, tempUnit, decimals = 1)
            } else {
                UnitFormatter.temperatureDeltaFromCelsius(c, tempUnit, decimals = 1)
            }
            full.removeSuffix(" $unit")
        }
        VitalDetailModel(
            key = key,
            title = "Skin Temperature",
            unit = unit,
            color = Palette.metricAmber,
            points = days.mapNotNull { row ->
                row.skinTempDevC
                    ?.takeIf { VitalBands.isAbsoluteSkinTemp(it) == absolute }
                    ?.let { value -> row.day to value }
            },
            format = format,
        )
    }
    else -> null
    }
}

// MARK: - Empty state

@Composable
private fun HealthEmptyState() {
    DataPendingNote(
        title = "No biometrics yet",
        body = "No biometrics yet. Import your WHOOP export (and Apple Health if you " +
            "have it) in Data Sources to fill this in.",
    )
}
