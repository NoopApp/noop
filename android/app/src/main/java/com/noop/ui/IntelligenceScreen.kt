package com.noop.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.AutoAwesome
import androidx.compose.material3.Icon
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
import com.noop.data.DailyMetric
import java.util.Calendar
import java.util.Locale
import kotlin.math.roundToInt

/**
 * Intelligence — NOOP's own recovery / strain / sleep scores, presented with the
 * WHOOP-model explanation so the read-out is legible rather than a black box.
 *
 * Ports macOS Strand/Screens/IntelligenceView.swift. The macOS build runs an
 * on-device IntelligenceEngine that recomputes these scores from the strap's raw
 * streams (HR, R-R, accelerometer) using the WHOOP model shape. That raw-compute
 * port is later work on Android; until it lands this screen reads the cached
 * `DailyMetric` values the strap/store already provide and shows the same model
 * explainer + per-day breakdown — matching the macOS sparse-data contract of
 * surfacing real data with an honest note, never a fabricated score.
 */
@Composable
fun IntelligenceScreen(vm: AppViewModel) {
    val days by vm.recentDays.collectAsStateWithLifecycle()
    val live by vm.live.collectAsStateWithLifecycle()

    // Newest first for the per-day list (macOS ForEach renders most-recent at top).
    val ordered = remember(days) { days.reversed() }

    ScreenScaffold(
        title = "Intelligence",
        subtitle = "Recovery, strain and sleep — scored with the model, explained in plain terms.",
    ) {
        ExplainerCard()
        ModelBreakdownCard()

        if (ordered.isEmpty()) {
            // While the strap is mid-offload, say so — an empty list reads as final otherwise (#77).
            if (live.backfilling) SyncingHistoryNote(chunks = live.syncChunksThisSession)
            EmptyNote()
        } else {
            SectionHeader(
                title = "By Day",
                overline = "Recent",
                trailing = "${ordered.size} ${if (ordered.size == 1) "day" else "days"}",
            )
            ordered.forEach { day -> DayCard(day) }
        }
    }
}

// MARK: - Explainer (ported from IntelligenceView.explainerCard)

@Composable
private fun ExplainerCard() {
    NoopCard(padding = 20.dp) {
        Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
            Row(
                horizontalArrangement = Arrangement.spacedBy(10.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Icon(
                    Icons.Filled.AutoAwesome,
                    contentDescription = null,
                    tint = Palette.accent,
                    modifier = Modifier.size(20.dp),
                )
                Text("How this works", style = NoopType.headline, color = Palette.textPrimary)
            }
            Text(
                "Recovery weighs your heart-rate variability against your personal baseline " +
                    "(~60%), resting heart rate (~20%), sleep performance (~15%) and respiration " +
                    "(~5%). Day strain is a 0–21 cardiovascular load from time spent in each " +
                    "heart-rate zone. Sleep is staged from movement and heart rate. The full " +
                    "on-device recompute from the strap's raw streams is a later port; the scores " +
                    "below are read from each day's cached metrics.",
                style = NoopType.subhead,
                color = Palette.textSecondary,
            )
        }
    }
}

// MARK: - Empty note

@Composable
private fun EmptyNote() {
    NoopCard(padding = 20.dp) {
        Row(
            horizontalArrangement = Arrangement.spacedBy(10.dp),
            verticalAlignment = Alignment.Top,
        ) {
            Icon(
                Icons.Filled.AutoAwesome,
                contentDescription = null,
                tint = Palette.accent,
                modifier = Modifier.size(18.dp),
            )
            Text(
                "No scored days yet. Sync your strap to collect raw streams — recovery, " +
                    "strain and sleep are scored once a day's data is in.",
                style = NoopType.subhead,
                color = Palette.textSecondary,
            )
        }
    }
}

// MARK: - Model weighting breakdown
//
// Makes the recovery formula concrete: the four weighted inputs plus the 0–21
// strain scale. Pure presentation of the model the macOS engine uses — no per-day
// data, so it's always legible even before any day is scored.

@Composable
private fun ModelBreakdownCard() {
    NoopCard(padding = 20.dp) {
        Column(verticalArrangement = Arrangement.spacedBy(14.dp)) {
            Overline("Recovery model")
            WeightRow("Heart-rate variability", "~60%", 0.60f, Palette.metricPurple)
            WeightRow("Resting heart rate", "~20%", 0.20f, Palette.metricRose)
            WeightRow("Sleep performance", "~15%", 0.15f, Palette.metricCyan)
            WeightRow("Respiration", "~5%", 0.05f, Palette.accent)

            Row(
                modifier = Modifier.fillMaxWidth().padding(top = 2.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Text(
                    "Day strain",
                    style = NoopType.subhead,
                    color = Palette.textSecondary,
                    modifier = Modifier.weight(1f),
                )
                Text(
                    "0–21 scale",
                    style = NoopType.captionNumber,
                    color = Palette.metricCyan,
                )
            }
        }
    }
}

@Composable
private fun WeightRow(label: String, percent: String, fraction: Float, color: Color) {
    Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text(
                label,
                style = NoopType.subhead,
                color = Palette.textPrimary,
                modifier = Modifier.weight(1f),
            )
            Text(percent, style = NoopType.captionNumber, color = color)
        }
        Meter(fraction = fraction, color = color)
    }
}

/** A thin, rounded proportional meter on the inset well. */
@Composable
private fun Meter(fraction: Float, color: Color) {
    val shape = RoundedCornerShape(50)
    Box(
        modifier = Modifier
            .fillMaxWidth()
            .height(6.dp)
            .clip(shape)
            .background(Palette.surfaceInset),
    ) {
        Box(
            modifier = Modifier
                .fillMaxWidth(fraction.coerceIn(0f, 1f))
                .height(6.dp)
                .clip(shape)
                .background(color),
        )
    }
}

// MARK: - Per-day card (ported from IntelligenceView.dayCard)
//
// Header = the day + a NOOP-computed source badge; a row of the five headline
// scores (Recovery / Strain / Sleep / HRV / RHR) tinted to the design-system metric
// colors, then a thin strain meter for at-a-glance load.

@Composable
private fun DayCard(d: DailyMetric) {
    NoopCard(padding = 18.dp) {
        Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text(
                    prettyDay(d.day),
                    style = NoopType.headline,
                    color = Palette.textPrimary,
                    modifier = Modifier.weight(1f),
                )
                SourceBadge("NOOP-computed")
            }

            Row(modifier = Modifier.fillMaxWidth()) {
                DayStat(
                    "Recovery",
                    d.recovery?.let { "${it.roundToInt()}%" } ?: "—",
                    d.recovery?.let { recoveryStatColor(it) } ?: Palette.textSecondary,
                    Modifier.weight(1f),
                )
                DayStat(
                    "Strain",
                    d.strain?.let { String.format(Locale.US, "%.1f", it) } ?: "—",
                    Palette.metricCyan,
                    Modifier.weight(1f),
                )
                DayStat(
                    "Sleep",
                    sleepValue(d.totalSleepMin),
                    Palette.metricPurple,
                    Modifier.weight(1f),
                )
                DayStat(
                    "HRV",
                    d.avgHrv?.let { "${it.roundToInt()}" } ?: "—",
                    Palette.metricPurple,
                    Modifier.weight(1f),
                )
                DayStat(
                    "RHR",
                    d.restingHr?.toString() ?: "—",
                    Palette.metricRose,
                    Modifier.weight(1f),
                )
            }

            // Strain load meter (0–21), tinted along the strain ramp.
            d.strain?.let { s ->
                Meter(
                    fraction = (s / 21.0).toFloat(),
                    color = Palette.strainColor(s),
                )
            }
        }
    }
}

@Composable
private fun DayStat(label: String, value: String, color: Color, modifier: Modifier = Modifier) {
    Column(modifier = modifier, verticalArrangement = Arrangement.spacedBy(3.dp)) {
        Text(
            label.uppercase(),
            style = NoopType.footnote,
            color = Palette.textTertiary,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
        )
        Text(
            value,
            style = NoopType.number(19f),
            color = color,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
        )
    }
}

// MARK: - Derived helpers

/** Recovery-band status color, mirroring IntelligenceView.recoveryColor (67 / 34 cuts). */
private fun recoveryStatColor(r: Double): Color = when {
    r >= 67 -> Palette.statusPositive
    r >= 34 -> Palette.statusWarning
    else -> Palette.statusCritical
}

private fun sleepValue(totalMin: Double?): String {
    val m = totalMin ?: return "—"
    val total = m.roundToInt()
    return "${total / 60}h ${total % 60}m"
}

/** "YYYY-MM-DD" → "Mon 5 Jun"; falls back to the raw key if it doesn't parse. */
private fun prettyDay(day: String): String {
    return try {
        val parts = day.split("-")
        val y = parts[0].toInt()
        val mo = parts[1].toInt()
        val da = parts[2].toInt()
        val cal = Calendar.getInstance().apply { set(y, mo - 1, da) }
        val dow = arrayOf("Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat")[
            cal.get(Calendar.DAY_OF_WEEK) - 1,
        ]
        val month = arrayOf(
            "Jan", "Feb", "Mar", "Apr", "May", "Jun",
            "Jul", "Aug", "Sep", "Oct", "Nov", "Dec",
        )[mo - 1]
        "$dow $da $month"
    } catch (_: Exception) {
        day
    }
}
