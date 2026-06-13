package com.noop.ui

import android.app.DatePickerDialog
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.CalendarMonth
import androidx.compose.material.icons.filled.ChevronLeft
import androidx.compose.material.icons.filled.ChevronRight
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import java.time.LocalDate
import java.time.format.DateTimeFormatter
import java.time.temporal.ChronoUnit
import java.util.Calendar
import java.util.Locale

@Composable
internal fun ThreeDaySelectorBar(
    selectedOffset: Int,
    onSelect: (Int) -> Unit,
) {
    val base = LocalDate.now()
    val blockShape = RoundedCornerShape(Metrics.cornerSm)
    Row(horizontalArrangement = Arrangement.spacedBy(Metrics.selectorSpacing)) {
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
                    .background(
                        if (selected) Palette.accent.copy(alpha = StrandAlpha.selectedFill)
                        else Palette.surfaceInset,
                    )
                    .border(
                        width = Metrics.divider,
                        color = if (selected) {
                            Palette.accent.copy(alpha = StrandAlpha.selectedBorder)
                        } else {
                            Palette.hairline
                        },
                        shape = blockShape,
                    )
                    .clickable { onSelect(offset) }
                    .padding(vertical = Metrics.selectorPadding, horizontal = Metrics.selectorPadding),
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
                    modifier = Modifier.padding(top = Metrics.space2),
                )
            }
        }
    }
}

@Composable
internal fun InsetChartPlaceholder(
    message: String,
    height: Dp = Metrics.compactChartHeight,
) {
    Box(
        modifier = Modifier
            .fillMaxWidth()
            .height(height)
            .clip(RoundedCornerShape(Metrics.cornerSm))
            .background(Palette.surfaceInset),
        contentAlignment = Alignment.Center,
    ) {
        Text(message, style = NoopType.subhead, color = Palette.textTertiary)
    }
}

/**
 * Chevron-navigation day selector that supports any past date via a calendar icon.
 * Left chevron goes older, right goes newer (disabled at today). The center block
 * shows the day label + full date in the accent style, and tapping the calendar icon
 * opens a [DatePickerDialog] clamped to [maxDate = today].
 */
@Composable
internal fun DayNavBar(
    selectedOffset: Int,
    onSelect: (Int) -> Unit,
) {
    val context = LocalContext.current
    val base = LocalDate.now()
    val selectedDay = base.minusDays(selectedOffset.toLong())
    var showPicker by remember { mutableStateOf(false) }

    if (showPicker) {
        DisposableEffect(selectedDay) {
            val cal = Calendar.getInstance().apply {
                set(selectedDay.year, selectedDay.monthValue - 1, selectedDay.dayOfMonth)
            }
            val dialog = DatePickerDialog(
                context,
                { _, year, month, day ->
                    val picked = LocalDate.of(year, month + 1, day)
                    val offset = ChronoUnit.DAYS.between(picked, base).toInt().coerceAtLeast(0)
                    onSelect(offset)
                    showPicker = false
                },
                cal.get(Calendar.YEAR),
                cal.get(Calendar.MONTH),
                cal.get(Calendar.DAY_OF_MONTH),
            ).apply {
                datePicker.maxDate = System.currentTimeMillis()
                setOnDismissListener { showPicker = false }
            }
            dialog.show()
            onDispose { runCatching { dialog.dismiss() } }
        }
    }

    val label = when (selectedOffset) {
        0 -> "Today"
        1 -> "Yesterday"
        else -> selectedDay.format(DateTimeFormatter.ofPattern("EEE d MMM", Locale.US))
    }
    val date = selectedDay.format(DateTimeFormatter.ofPattern("d MMM yyyy", Locale.US))
    val blockShape = RoundedCornerShape(Metrics.cornerSm)

    Row(
        modifier = Modifier.fillMaxWidth(),
        horizontalArrangement = Arrangement.spacedBy(Metrics.selectorSpacing),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        IconButton(onClick = { onSelect(selectedOffset + 1) }) {
            Icon(Icons.Filled.ChevronLeft, contentDescription = "Older day", tint = Palette.textSecondary)
        }
        Column(
            modifier = Modifier
                .weight(1f)
                .clip(blockShape)
                .background(Palette.accent.copy(alpha = StrandAlpha.selectedFill))
                .border(Metrics.divider, Palette.accent.copy(alpha = StrandAlpha.selectedBorder), blockShape)
                .padding(vertical = Metrics.selectorPadding, horizontal = Metrics.selectorPadding),
            horizontalAlignment = Alignment.CenterHorizontally,
        ) {
            Text(label, style = NoopType.caption, color = Palette.textPrimary, maxLines = 1, overflow = TextOverflow.Ellipsis)
            Text(date, style = NoopType.captionNumber, color = Palette.accent, maxLines = 1, overflow = TextOverflow.Ellipsis, modifier = Modifier.padding(top = Metrics.space2))
        }
        IconButton(
            onClick = { if (selectedOffset > 0) onSelect(selectedOffset - 1) },
            enabled = selectedOffset > 0,
        ) {
            Icon(Icons.Filled.ChevronRight, contentDescription = "Newer day", tint = if (selectedOffset > 0) Palette.textSecondary else Palette.textTertiary)
        }
        IconButton(onClick = { showPicker = true }) {
            Icon(Icons.Filled.CalendarMonth, contentDescription = "Pick date", tint = Palette.textSecondary)
        }
    }
}

@Composable
internal fun SparkTailBox(
    modifier: Modifier = Modifier,
    wide: Boolean = false,
    content: @Composable () -> Unit,
) {
    Box(
        modifier = modifier
            .padding(start = Metrics.space8, bottom = Metrics.space2)
            .width(if (wide) Metrics.sparkWidthWide else Metrics.sparkWidth)
            .height(Metrics.sparkHeight),
    ) {
        content()
    }
}
