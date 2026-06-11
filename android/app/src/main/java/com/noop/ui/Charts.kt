package com.noop.ui

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.gestures.detectHorizontalDragGestures
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.StrokeJoin
import androidx.compose.ui.graphics.drawscope.DrawScope
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.nativeCanvas
import androidx.compose.ui.graphics.toArgb
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import java.util.Locale
import kotlin.math.abs
import kotlin.math.roundToInt

// MARK: - Charts (pure Compose Canvas — dark, instrument-grade, no external library)
//
// Implements the shared chart contract used across the port. Every chart is
// null/empty-safe: with no usable data it renders nothing but a faint baseline
// (or, for the hypnogram, the inset well) so layouts never collapse or crash.
//
//   Sparkline  — tiny inline trend line, no axes
//   LineChart  — line with optional soft gradient fill, height driven by Modifier
//   BarChart   — vertical bars from a zero baseline
//   Hypnogram  — proportional sleep-stage strip (deep / rem / light / awake)

// MARK: - Shared geometry helpers

/** Map a list of values into evenly-spaced points within [bounds], scaling y to the
 *  value range. A flat series (min == max) is centered vertically. Returns an empty
 *  list when there are fewer than two finite points. */
private fun pointsFor(
    values: List<Double>,
    width: Float,
    height: Float,
    topPad: Float,
    bottomPad: Float,
): List<Offset> {
    val clean = values.filter { it.isFinite() }
    if (clean.size < 2 || width <= 0f || height <= 0f) return emptyList()
    return pointsFor(clean, width, height, topPad, bottomPad, clean.min(), clean.max())
}

private fun pointsFor(
    values: List<Double>,
    width: Float,
    height: Float,
    topPad: Float,
    bottomPad: Float,
    minV: Double,
    maxV: Double,
): List<Offset> {
    if (values.size < 2 || width <= 0f || height <= 0f) return emptyList()

    val span = (maxV - minV)
    val usableH = (height - topPad - bottomPad).coerceAtLeast(1f)
    val stepX = if (values.size > 1) width / (values.size - 1) else width

    return values.mapIndexed { i, v ->
        val x = stepX * i
        val norm = if (span > 0.0) ((v - minV) / span).toFloat() else 0.5f
        val y = topPad + (1f - norm) * usableH
        Offset(x, y)
    }
}

/** Draw the faint zero/empty baseline used when there is nothing to plot. */
private fun DrawScope.drawBaseline(color: Color = Palette.hairline) {
    val y = size.height / 2f
    drawLine(
        color = color.copy(alpha = StrandAlpha.subtleLine),
        start = Offset(0f, y),
        end = Offset(size.width, y),
        strokeWidth = 1f,
        cap = StrokeCap.Round,
    )
}

// MARK: - Sparkline

/**
 * Tiny inline line, no axes — for use inside tiles and list rows. Draws a single
 * smooth-capped stroke spanning the full width. Empty/flat data renders a baseline.
 */
@Composable
fun Sparkline(
    values: List<Double>,
    modifier: Modifier = Modifier,
    color: Color = Palette.accent,
) {
    Canvas(
        modifier = modifier
            .fillMaxWidth()
            .height(Metrics.sparklineHeight),
    ) {
        val strokePx = 2f
        val pad = strokePx
        val pts = pointsFor(values, size.width, size.height, pad, pad)
        if (pts.isEmpty()) {
            drawBaseline()
            return@Canvas
        }
        val path = Path().apply {
            moveTo(pts.first().x, pts.first().y)
            for (i in 1 until pts.size) lineTo(pts[i].x, pts[i].y)
        }
        drawPath(
            path = path,
            color = color,
            style = Stroke(width = strokePx, cap = StrokeCap.Round, join = StrokeJoin.Round),
        )
    }
}

// MARK: - LineChart

/**
 * Line chart with an optional soft vertical gradient fill under the curve. Height is
 * taken from [modifier] (e.g. `Modifier.height(Metrics.chartHeight)`). A faint
 * baseline shows when data is empty. No axes/labels — the surrounding card supplies
 * context, keeping the chart instrument-grade.
 */
@Composable
fun LineChart(
    values: List<Double>,
    modifier: Modifier,
    color: Color = Palette.accent,
    fill: Boolean = true,
    selectionEnabled: Boolean = true,
    dragSelectionEnabled: Boolean = true,
) {
    val cleanValues = remember(values) { values.filter { it.isFinite() } }
    var selectedIndex by remember(cleanValues) { mutableIntStateOf(-1) }
    val interactiveModifier = if (selectionEnabled) {
        Modifier
            .pointerInput(cleanValues) {
                detectTapGestures(
                    onTap = { offset ->
                        if (cleanValues.size >= 2 && size.width > 0) {
                            selectedIndex = nearestIndexForX(
                                count = cleanValues.size,
                                width = size.width.toFloat(),
                                x = offset.x,
                            )
                        }
                    },
                )
            }
            .then(
                if (dragSelectionEnabled) {
                    Modifier.pointerInput(cleanValues) {
                        detectHorizontalDragGestures(
                            onDragStart = { start ->
                                if (cleanValues.size < 2 || size.width <= 0f) return@detectHorizontalDragGestures
                                selectedIndex = nearestIndexForX(
                                    count = cleanValues.size,
                                    width = size.width.toFloat(),
                                    x = start.x,
                                )
                            },
                            onHorizontalDrag = { change, _ ->
                                if (cleanValues.size < 2 || size.width <= 0f) return@detectHorizontalDragGestures
                                selectedIndex = nearestIndexForX(
                                    count = cleanValues.size,
                                    width = size.width.toFloat(),
                                    x = change.position.x,
                                )
                                change.consume()
                            },
                        )
                    }
                } else {
                    Modifier
                },
            )
    } else {
        Modifier
    }

    Box(
        modifier = modifier
            .fillMaxWidth()
            .then(interactiveModifier),
    ) {
        Canvas(modifier = Modifier.fillMaxSize()) {
            val strokePx = 2.5f
            val topPad = strokePx + 4f
            val bottomPad = strokePx + 4f
            val pts = pointsFor(cleanValues, size.width, size.height, topPad, bottomPad)
            if (pts.isEmpty()) {
                drawBaseline()
                return@Canvas
            }

            // Soft gradient fill under the curve.
            if (fill) {
                val fillPath = Path().apply {
                    moveTo(pts.first().x, size.height)
                    lineTo(pts.first().x, pts.first().y)
                    for (i in 1 until pts.size) lineTo(pts[i].x, pts[i].y)
                    lineTo(pts.last().x, size.height)
                    close()
                }
                drawPath(
                    path = fillPath,
                    brush = Brush.verticalGradient(
                        colors = listOf(
                            color.copy(alpha = StrandAlpha.chartFillStrong),
                            color.copy(alpha = StrandAlpha.chartFillSoft),
                            Color.Transparent,
                        ),
                        startY = 0f,
                        endY = size.height,
                    ),
                )
            }

            // The line itself.
            val linePath = Path().apply {
                moveTo(pts.first().x, pts.first().y)
                for (i in 1 until pts.size) lineTo(pts[i].x, pts[i].y)
            }
            drawPath(
                path = linePath,
                color = color,
                style = Stroke(width = strokePx, cap = StrokeCap.Round, join = StrokeJoin.Round),
            )

            // Tap-to-pinpoint: vertical marker + dot + value text.
            if (selectionEnabled && selectedIndex in pts.indices) {
                val p = pts[selectedIndex]
                drawLine(
                    color = color.copy(alpha = StrandAlpha.chartMarker),
                    start = Offset(p.x, 0f),
                    end = Offset(p.x, size.height),
                    strokeWidth = 1.5f,
                    cap = StrokeCap.Round,
                )
                drawCircle(color = color, radius = 5f, center = p)
                drawCircle(color = Palette.surfaceBase.copy(alpha = StrandAlpha.chartShadow), radius = 9f, center = p)
                drawCircle(color = color, radius = 4.5f, center = p)
                drawContext.canvas.nativeCanvas.apply {
                    val paint = android.graphics.Paint().apply {
                        isAntiAlias = true
                        textSize = 30f
                        this.color = color.copy(alpha = StrandAlpha.chartLabel).toArgb()
                        typeface = android.graphics.Typeface.create(
                            android.graphics.Typeface.DEFAULT,
                            android.graphics.Typeface.BOLD,
                        )
                    }
                    val label = formatLineValue(cleanValues[selectedIndex])
                    drawText(label, 8f, 32f, paint)
                }
            }
        }
    }
}

data class LineSeries(
    val values: List<Double>,
    val color: Color,
)

@Composable
fun MultiLineChart(
    series: List<LineSeries>,
    modifier: Modifier,
) {
    val cleanSeries = remember(series) {
        series.map { it.copy(values = it.values.filter { value -> value.isFinite() }) }
            .filter { it.values.size >= 2 }
    }

    Canvas(modifier = modifier.fillMaxWidth()) {
        if (cleanSeries.isEmpty()) {
            drawBaseline()
            return@Canvas
        }

        val allValues = cleanSeries.flatMap { it.values }
        val minV = allValues.minOrNull() ?: return@Canvas
        val maxV = allValues.maxOrNull() ?: return@Canvas
        val strokePx = 2.5f
        val topPad = strokePx + 4f
        val bottomPad = strokePx + 4f

        cleanSeries.forEach { line ->
            val pts = pointsFor(line.values, size.width, size.height, topPad, bottomPad, minV, maxV)
            if (pts.isEmpty()) return@forEach
            val path = Path().apply {
                moveTo(pts.first().x, pts.first().y)
                for (i in 1 until pts.size) lineTo(pts[i].x, pts[i].y)
            }
            drawPath(
                path = path,
                color = line.color,
                style = Stroke(width = strokePx, cap = StrokeCap.Round, join = StrokeJoin.Round),
            )
        }
    }
}

private fun nearestIndexForX(count: Int, width: Float, x: Float): Int {
    if (count <= 1 || width <= 0f) return 0
    val step = width / (count - 1)
    val clampedX = x.coerceIn(0f, width)
    val raw = (clampedX / step).roundToInt()
    return raw.coerceIn(0, count - 1)
}

private fun formatLineValue(value: Double): String {
    if (!value.isFinite()) return "-"
    val rounded = value.roundToInt().toDouble()
    return if (abs(value - rounded) < 0.05) {
        rounded.toInt().toString()
    } else {
        String.format(Locale.US, "%.1f", value)
    }
}

private fun nearestBarIndexForX(count: Int, width: Float, x: Float): Int {
    if (count <= 1 || width <= 0f) return 0
    val slot = width / count
    val clampedX = x.coerceIn(0f, width)
    return (clampedX / slot).toInt().coerceIn(0, count - 1)
}

// MARK: - BarChart

/**
 * Vertical bars from a zero baseline. Bars are scaled to the maximum value so the
 * tallest fills the plot height. Negative/non-finite values are treated as zero.
 * Empty data renders a faint baseline.
 */
@Composable
fun BarChart(
    values: List<Double>,
    modifier: Modifier,
    color: Color = Palette.accent,
    selectionEnabled: Boolean = false,
) {
    val cleanValues = remember(values) { values.map { if (it.isFinite() && it > 0.0) it else 0.0 } }
    var selectedIndex by remember(cleanValues) { mutableIntStateOf(-1) }

    Box(
        modifier = modifier
            .fillMaxWidth()
            .then(
                if (selectionEnabled) {
                    Modifier.pointerInput(cleanValues) {
                        detectTapGestures(
                            onTap = { offset ->
                                if (cleanValues.isNotEmpty() && size.width > 0) {
                                    selectedIndex = nearestBarIndexForX(
                                        count = cleanValues.size,
                                        width = size.width.toFloat(),
                                        x = offset.x,
                                    )
                                }
                            },
                        )
                    }
                } else {
                    Modifier
                },
            ),
    ) {
        Canvas(modifier = Modifier.fillMaxSize()) {
            val clean = cleanValues
            val maxV = clean.maxOrNull() ?: 0.0
            if (clean.isEmpty() || maxV <= 0.0 || size.width <= 0f || size.height <= 0f) {
                drawBaseline()
                return@Canvas
            }

            val topPad = 4f
            val usableH = (size.height - topPad).coerceAtLeast(1f)
            val slot = size.width / clean.size
            val barWidth = (slot * 0.64f).coerceAtLeast(1f)
            val capRadius = (barWidth / 2f)

            clean.forEachIndexed { i, v ->
                val norm = (v / maxV).toFloat().coerceIn(0f, 1f)
                val barHeight = (norm * usableH).coerceAtLeast(if (v > 0.0) 1f else 0f)
                if (barHeight <= 0f) return@forEachIndexed
                val cx = slot * i + slot / 2f
                val left = cx - barWidth / 2f
                val top = size.height - barHeight
                drawLine(
                    color = if (selectionEnabled && i == selectedIndex) color else color.copy(alpha = StrandAlpha.unselectedBar),
                    start = Offset(cx, size.height),
                    end = Offset(cx, (top + capRadius).coerceAtMost(size.height)),
                    strokeWidth = barWidth,
                    cap = StrokeCap.Round,
                )
                @Suppress("UNUSED_EXPRESSION") left
            }

            if (selectionEnabled && selectedIndex in clean.indices) {
                drawContext.canvas.nativeCanvas.apply {
                    val paint = android.graphics.Paint().apply {
                        isAntiAlias = true
                        textSize = 30f
                        this.color = color.copy(alpha = StrandAlpha.chartLabel).toArgb()
                        typeface = android.graphics.Typeface.create(
                            android.graphics.Typeface.DEFAULT,
                            android.graphics.Typeface.BOLD,
                        )
                    }
                    drawText(formatLineValue(clean[selectedIndex]), 8f, 32f, paint)
                }
            }
        }
    }
}

// MARK: - Hypnogram

/**
 * Proportional sleep-stage strip. [stages] is an ordered list of (stageName,
 * fractionOfWidth) where fractions are taken as relative weights and normalized to
 * fill the available width. Stage names are matched case-insensitively to the
 * design-system sleep palette:
 *
 *   "deep"  → Palette.sleepDeep      "rem"   → Palette.sleepREM
 *   "light" → Palette.sleepLight     "awake" → Palette.sleepAwake
 *
 * Unknown names fall back to the light tone. Empty/zero-weight input renders the
 * inset well so the row keeps its height.
 */
@Composable
fun Hypnogram(
    stages: List<Pair<String, Float>>,
    modifier: Modifier,
) {
    Canvas(
        modifier = modifier
            .fillMaxWidth()
            .height(Metrics.segmentBarHeight),
    ) {
        val w = size.width
        val h = size.height
        if (w <= 0f || h <= 0f) return@Canvas

        // Inset well background so the strip reads as a recessed track.
        drawRoundedTrack(Palette.surfaceInset)

        val weights = stages.map { it.second }.map { if (it.isFinite() && it > 0f) it else 0f }
        val total = weights.sum()
        if (stages.isEmpty() || total <= 0f) {
            // Baseline-only state: leave the inset well visible.
            return@Canvas
        }

        var x = 0f
        val gap = if (stages.size > 1) 1.5f else 0f
        stages.forEachIndexed { i, (name, _) ->
            val frac = weights[i] / total
            val segW = (w * frac)
            if (segW <= 0f) return@forEachIndexed
            val drawW = (segW - if (i < stages.size - 1) gap else 0f).coerceAtLeast(0f)
            if (drawW > 0f) {
                drawSegment(
                    color = stageColor(name),
                    left = x,
                    width = drawW,
                    height = h,
                )
            }
            x += segW
        }
    }
}

// MARK: - SegmentBar

/**
 * Generic proportional color strip (the Hypnogram geometry with caller-supplied colors).
 * [segments] is an ordered list of (color, weight); weights are normalized to fill the
 * width. Zero/NaN weights are skipped. Empty/zero input renders the inset well so rows
 * keep their height.
 */
@Composable
fun SegmentBar(
    segments: List<Pair<Color, Float>>,
    modifier: Modifier,
    height: Dp = Metrics.segmentBarHeight,
) {
    Canvas(modifier = modifier.fillMaxWidth().height(height)) {
        val w = size.width
        val h = size.height
        if (w <= 0f || h <= 0f) return@Canvas
        drawRoundedTrack(Palette.surfaceInset)
        val weights = segments.map { it.second }.map { if (it.isFinite() && it > 0f) it else 0f }
        val total = weights.sum()
        if (segments.isEmpty() || total <= 0f) return@Canvas
        var x = 0f
        val gap = if (segments.size > 1) 1.5f else 0f
        segments.forEachIndexed { i, (color, _) ->
            val frac = weights[i] / total
            val segW = w * frac
            if (segW <= 0f) return@forEachIndexed
            val drawW = (segW - if (i < segments.size - 1) gap else 0f).coerceAtLeast(0f)
            if (drawW > 0f) drawSegment(color = color, left = x, width = drawW, height = h)
            x += segW
        }
    }
}

private fun DrawScope.drawRoundedTrack(color: Color) {
    drawLine(
        color = color,
        start = Offset(0f, size.height / 2f),
        end = Offset(size.width, size.height / 2f),
        strokeWidth = size.height,
        cap = StrokeCap.Round,
    )
}

private fun DrawScope.drawSegment(color: Color, left: Float, width: Float, height: Float) {
    val cap = (height / 2f).coerceAtMost(width / 2f)
    drawLine(
        color = color,
        start = Offset(left + cap, height / 2f),
        end = Offset((left + width - cap).coerceAtLeast(left + cap), height / 2f),
        strokeWidth = height,
        cap = StrokeCap.Round,
    )
}

/** Map a stage name to its design-system sleep tone (case-insensitive). */
private fun stageColor(name: String): Color = when (name.trim().lowercase()) {
    "deep" -> Palette.sleepDeep
    "rem" -> Palette.sleepREM
    "light" -> Palette.sleepLight
    "awake", "wake" -> Palette.sleepAwake
    else -> Palette.sleepLight
}
