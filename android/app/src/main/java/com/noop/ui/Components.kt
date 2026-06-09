package com.noop.ui

import androidx.compose.animation.animateColorAsState
import androidx.compose.animation.core.RepeatMode
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.tween
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.AutoGraph
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.drawscope.DrawScope
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import kotlin.math.cos
import kotlin.math.min
import kotlin.math.sin

// MARK: - Locked component system (ported from StrandDesign/Components.swift + StrandCard.swift)
//
// Every screen composes ONLY these. Fixed dimensions + one spacing scale guarantee
// the uniform, instrument-grade look from the reference.

// MARK: - NoopCard — the one card surface (surface.raised, 16pt radius, hairline border)

@Composable
fun NoopCard(
    modifier: Modifier = Modifier,
    padding: Dp = Metrics.cardPadding,
    content: @Composable () -> Unit,
) {
    val shape = RoundedCornerShape(Metrics.cardRadius)
    Box(
        modifier = modifier
            .fillMaxWidth()
            .clip(shape)
            .background(Palette.surfaceRaised)
            .border(1.dp, Palette.hairline, shape)
            .padding(padding),
    ) {
        content()
    }
}

// MARK: - DataPendingNote — the shared "what shows now vs what needs an import" banner
//
// A NoopCard with a leading AutoGraph glyph, a bold title and a body line. Every data
// screen drops one of these in its empty/partial state so the user always knows what is
// live now and what an import will backfill. Copy is passed verbatim by the call site.

@Composable
fun DataPendingNote(title: String, body: String, modifier: Modifier = Modifier) {
    NoopCard(modifier = modifier, padding = 18.dp) {
        Row(
            horizontalArrangement = Arrangement.spacedBy(12.dp),
            verticalAlignment = Alignment.Top,
        ) {
            Icon(
                Icons.Filled.AutoGraph,
                contentDescription = null,
                tint = Palette.accent,
                modifier = Modifier.size(20.dp),
            )
            Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
                Text(title, style = NoopType.headline, color = Palette.textPrimary)
                Text(body, style = NoopType.subhead, color = Palette.textSecondary)
            }
        }
    }
}

// MARK: - Overline label (ALL-CAPS, semibold, +0.8 tracking, secondary)

@Composable
fun Overline(text: String, modifier: Modifier = Modifier, color: Color = Palette.textSecondary) {
    Text(
        text = text.uppercase(),
        style = NoopType.overline,
        color = color,
        modifier = modifier,
    )
}

// MARK: - Section header

@Composable
fun SectionHeader(
    title: String,
    overline: String? = null,
    trailing: String? = null,
    modifier: Modifier = Modifier,
) {
    Row(
        modifier = modifier.fillMaxWidth(),
        verticalAlignment = Alignment.Top,
    ) {
        Column(modifier = Modifier.weight(1f)) {
            if (overline != null) Overline(overline)
            Text(title, style = NoopType.title2, color = Palette.textPrimary)
        }
        if (trailing != null) {
            Text(trailing, style = NoopType.footnote, color = Palette.textSecondary)
        }
    }
}

// MARK: - StrandTone (ported from StrandDesign/StatePill.swift)

enum class StrandTone(val color: Color) {
    Neutral(Palette.textSecondary),
    Accent(Palette.accent),
    Positive(Palette.statusPositive),
    Warning(Palette.statusWarning),
    Critical(Palette.statusCritical),
}

// MARK: - ConnectionDot — tiny status dot with optional breathing pulse halo

@Composable
fun ConnectionDot(
    tone: StrandTone = StrandTone.Positive,
    pulsing: Boolean = false,
    size: Dp = 9.dp,
    modifier: Modifier = Modifier,
) {
    val transition = rememberInfiniteTransition(label = "dot")
    val scale by transition.animateFloat(
        initialValue = 1.0f,
        targetValue = if (pulsing) 2.4f else 1.0f,
        animationSpec = infiniteRepeatable(
            animation = tween(Motion.breathPeriodMs, easing = Motion.easeInOut),
            repeatMode = RepeatMode.Reverse,
        ),
        label = "dotScale",
    )
    val haloAlpha by transition.animateFloat(
        initialValue = 0.5f,
        targetValue = if (pulsing) 0.0f else 0.5f,
        animationSpec = infiniteRepeatable(
            animation = tween(Motion.breathPeriodMs, easing = Motion.easeInOut),
            repeatMode = RepeatMode.Reverse,
        ),
        label = "dotHalo",
    )
    Box(
        modifier = modifier.size(size),
        contentAlignment = Alignment.Center,
    ) {
        if (pulsing) {
            Box(
                modifier = Modifier
                    .size(size)
                    .drawBehind {
                        drawCircleScaled(tone.color, scale, haloAlpha)
                    },
            )
        }
        Box(
            modifier = Modifier
                .size(size)
                .clip(CircleShape)
                .background(tone.color),
        )
    }
}

private fun DrawScope.drawCircleScaled(
    color: Color,
    scale: Float,
    alpha: Float,
) {
    drawCircle(color = color, radius = (size.minDimension / 2f) * scale, alpha = alpha)
}

// MARK: - StatePill — rounded pill with optional leading dot + tinted label

@Composable
fun StatePill(
    title: String,
    tone: StrandTone = StrandTone.Neutral,
    showsDot: Boolean = true,
    pulsing: Boolean = false,
    modifier: Modifier = Modifier,
) {
    val shape = RoundedCornerShape(50)
    Row(
        modifier = modifier
            .clip(shape)
            .background(tone.color.copy(alpha = 0.12f))
            .border(1.dp, tone.color.copy(alpha = 0.28f), shape)
            .padding(horizontal = 10.dp, vertical = 5.dp)
            .semantics { contentDescription = title },
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(6.dp),
    ) {
        if (showsDot) ConnectionDot(tone = tone, pulsing = pulsing, size = 7.dp)
        Text(title, style = NoopType.overline.copy(letterSpacing = 0.4.sp), color = tone.color)
    }
}

// MARK: - SourceBadge

@Composable
fun SourceBadge(text: String, tint: Color = Palette.accent, modifier: Modifier = Modifier) {
    val shape = RoundedCornerShape(50)
    Text(
        text = text.uppercase(),
        style = NoopType.overline.copy(fontSize = 10.sp, letterSpacing = 0.5.sp),
        color = tint,
        modifier = modifier
            .clip(shape)
            .background(tint.copy(alpha = 0.14f))
            .border(1.dp, tint.copy(alpha = 0.30f), shape)
            .padding(horizontal = 8.dp, vertical = 3.dp),
    )
}

// MARK: - StatTile — uniform fixed-height metric tile

@Composable
fun StatTile(
    label: String,
    value: String,
    modifier: Modifier = Modifier,
    caption: String? = null,
    accent: Color = Palette.textPrimary,
    delta: String? = null,
    deltaColor: Color = Palette.textTertiary,
) {
    NoopCard(modifier = modifier.height(Metrics.tileHeight), padding = 14.dp) {
        Column {
            Overline(label)
            Spacer(Modifier.weight(1f))
            Text(
                value,
                style = NoopType.number(26f),
                color = accent,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
            Row(
                modifier = Modifier.fillMaxWidth().padding(top = 2.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                if (caption != null) {
                    Text(
                        caption, style = NoopType.footnote, color = Palette.textTertiary,
                        maxLines = 1, overflow = TextOverflow.Ellipsis,
                        modifier = Modifier.weight(1f, fill = false),
                    )
                }
                Spacer(Modifier.weight(1f))
                if (delta != null) {
                    Text(delta, style = NoopType.captionNumber, color = deltaColor)
                }
            }
        }
    }
}

// MARK: - InsightCard

@Composable
fun InsightCard(
    category: String,
    status: String,
    detail: String,
    modifier: Modifier = Modifier,
    statusColor: Color = Palette.accent,
) {
    NoopCard(modifier = modifier, padding = 18.dp) {
        Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
            Overline(category)
            Text(status, style = NoopType.title1, color = statusColor)
            Text(detail, style = NoopType.subhead, color = Palette.textSecondary)
        }
    }
}

// MARK: - SegmentedPillControl — the ONE segmented control

@Composable
fun <T> SegmentedPillControl(
    items: List<T>,
    selection: T,
    label: (T) -> String,
    onSelect: (T) -> Unit,
    modifier: Modifier = Modifier,
) {
    val outerShape = RoundedCornerShape(50)
    Row(
        modifier = modifier
            .clip(outerShape)
            .background(Palette.surfaceInset)
            .border(1.dp, Palette.hairline, outerShape)
            .padding(3.dp),
        horizontalArrangement = Arrangement.spacedBy(4.dp),
    ) {
        items.forEach { item ->
            val selected = item == selection
            val bg by animateColorAsState(
                if (selected) Palette.accent else Color.Transparent,
                tween(Motion.durationFast), label = "segBg",
            )
            Text(
                text = label(item),
                style = NoopType.captionNumber,
                color = if (selected) Palette.surfaceBase else Palette.textSecondary,
                modifier = Modifier
                    .clip(RoundedCornerShape(50))
                    .background(bg)
                    .clickableNoRipple { onSelect(item) }
                    .padding(horizontal = 11.dp, vertical = 6.dp),
            )
        }
    }
}

// MARK: - RecoveryRing (ported from StrandDesign/RecoveryRing.swift §9.3) — THE signature component
//
// A 240° open gauge arc (gap at bottom), thick rounded-cap stroke filled with a
// sweep gradient sampling the recovery gradient, filled to score/100 over a faint
// track. Soft outer bloom scaled by score, a luminous leading bead at the tip, a
// draw-in animation when the value changes. Center shows the big number, a state
// word tinted to the sampled color, and an optional supporting line.

@Composable
fun RecoveryRing(
    score: Double,
    modifier: Modifier = Modifier,
    supporting: String? = null,
    diameter: Dp = 240.dp,
    lineWidth: Dp = 16.dp,
    showsLabel: Boolean = true,
) {
    val fraction = (score / 100.0).toFloat().coerceIn(0f, 1f)
    val tipColor = Palette.recoveryColor(score)
    val stateWord = Palette.recoveryState(score)

    val startDeg = 150f          // lower-left
    val spanDeg = 240f           // 240° open gauge, gap centered at bottom

    val animatedFraction by animateFloatAsState(
        targetValue = fraction,
        animationSpec = tween(Motion.durationSlow, easing = Motion.drawIn),
        label = "ringFill",
    )
    val breathe = rememberInfiniteTransition(label = "bloom")
    val bloomPulse by breathe.animateFloat(
        initialValue = 0.78f, targetValue = 1.0f,
        animationSpec = infiniteRepeatable(
            tween(Motion.breathPeriodMs, easing = Motion.easeInOut), RepeatMode.Reverse,
        ),
        label = "bloomPulse",
    )
    val bloomOpacity = (0.18f + 0.37f * fraction) * bloomPulse

    val sweep = Brush.sweepGradient(
        // Sweep gradient starts at 3 o'clock by default; we rotate the gauge so the
        // gradient walks low→high along the arc. Stops map color order of recovery.
        *Palette.recoveryStops.toTypedArray(),
    )

    Box(
        modifier = modifier.size(diameter),
        contentAlignment = Alignment.Center,
    ) {
        // Arc + bloom + bead drawn on a single canvas-backed box.
        Box(
            modifier = Modifier
                .size(diameter)
                .drawBehind {
                    val stroke = lineWidth.toPx()
                    val radius = (min(size.width, size.height) - stroke) / 2f
                    val center = Offset(size.width / 2f, size.height / 2f)
                    val topLeft = Offset(center.x - radius, center.y - radius)
                    val arcSize = Size(radius * 2f, radius * 2f)
                    val sweepStroke = Stroke(width = stroke, cap = StrokeCap.Round)

                    // Faint full-span track.
                    drawArc(
                        color = Palette.hairline.copy(alpha = 0.55f),
                        startAngle = startDeg,
                        sweepAngle = spanDeg,
                        useCenter = false,
                        topLeft = topLeft,
                        size = arcSize,
                        style = sweepStroke,
                    )

                    // Filled gradient arc.
                    if (animatedFraction > 0.001f) {
                        drawArc(
                            brush = sweep,
                            startAngle = startDeg,
                            sweepAngle = spanDeg * animatedFraction,
                            useCenter = false,
                            topLeft = topLeft,
                            size = arcSize,
                            style = sweepStroke,
                        )

                        // Luminous leading bead at the fill tip.
                        val tipAngle = Math.toRadians((startDeg + spanDeg * animatedFraction).toDouble())
                        val bead = Offset(
                            center.x + radius * cos(tipAngle).toFloat(),
                            center.y + radius * sin(tipAngle).toFloat(),
                        )
                        drawCircle(
                            color = tipColor.copy(alpha = 0.7f),
                            radius = stroke * 1.2f,
                            center = bead,
                        )
                        drawCircle(
                            color = Color.White,
                            radius = stroke * 0.31f,
                            center = bead,
                        )
                    }

                    // Outer bloom — a soft, lower-opacity wide arc.
                    if (animatedFraction > 0.001f) {
                        drawArc(
                            brush = sweep,
                            startAngle = startDeg,
                            sweepAngle = spanDeg * animatedFraction,
                            useCenter = false,
                            topLeft = topLeft,
                            size = arcSize,
                            style = Stroke(width = stroke * 1.6f, cap = StrokeCap.Round),
                            alpha = bloomOpacity,
                        )
                    }
                },
        )

        if (showsLabel) {
            // Mirror the macOS read-out sizing: display number ≈ diameter * 0.30.
            val numberSp = diameter.value * 0.30f
            Column(horizontalAlignment = Alignment.CenterHorizontally) {
                Text(
                    text = score.toInt().toString(),
                    style = NoopType.display(numberSp),
                    color = Palette.textPrimary,
                )
                Text(
                    text = stateWord,
                    style = NoopType.overline,
                    color = tipColor,
                )
                if (supporting != null) {
                    Text(
                        text = supporting,
                        style = NoopType.footnote,
                        color = Palette.textSecondary,
                        textAlign = TextAlign.Center,
                        modifier = Modifier.padding(top = 4.dp),
                    )
                }
            }
        }
    }
}

// MARK: - ScreenScaffold (ported from Strand/Screens/ScreenScaffold.swift)
//
// Standard scrollable screen container: a title + optional subtitle header over the
// dark surface, then a left-aligned content column with 28dp screen padding.

@Composable
fun ScreenScaffold(
    title: String,
    subtitle: String? = null,
    modifier: Modifier = Modifier,
    content: @Composable ColumnScope.() -> Unit,
) {
    Column(
        modifier = modifier
            .fillMaxWidth()
            .background(Palette.surfaceBase)
            .verticalScroll(rememberScrollState())
            .padding(28.dp),
        verticalArrangement = Arrangement.spacedBy(20.dp),
    ) {
        Column(verticalArrangement = Arrangement.spacedBy(2.dp)) {
            Text(title, style = NoopType.title1, color = Palette.textPrimary)
            if (subtitle != null) {
                Text(subtitle, style = NoopType.subhead, color = Palette.textSecondary)
            }
        }
        content()
    }
}

// MARK: - Stepper field (Compose has no Stepper — tabular value + round −/+ buttons)
//
// The canonical profile editor used by both Settings and onboarding. Reuse this
// rather than forking sliders or bespoke button sizes, so every numeric profile
// field reads and behaves identically across the app.

@Composable
fun StepperField(
    value: String,
    accessibility: String,
    unit: String? = null,
    valueColor: Color = Palette.textPrimary,
    onMinus: () -> Unit,
    onPlus: () -> Unit,
) {
    Row(
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(8.dp),
        modifier = Modifier.semantics { contentDescription = accessibility },
    ) {
        Text(
            value,
            style = NoopType.bodyNumber,
            color = valueColor,
            modifier = Modifier.widthIn(min = 44.dp),
        )
        if (unit != null) {
            Text(unit, style = NoopType.caption, color = Palette.textTertiary)
        }
        StepperButton(symbol = "−", onClick = onMinus, label = "Decrease $accessibility")
        StepperButton(symbol = "+", onClick = onPlus, label = "Increase $accessibility")
    }
}

@Composable
fun StepperButton(symbol: String, onClick: () -> Unit, label: String) {
    Box(
        modifier = Modifier
            .size(30.dp)
            .clip(RoundedCornerShape(8.dp))
            .background(Palette.surfaceInset)
            .border(1.dp, Palette.hairline, RoundedCornerShape(8.dp))
            .clickable(onClick = onClick)
            .semantics { contentDescription = label },
        contentAlignment = Alignment.Center,
    ) {
        Text(symbol, style = NoopType.body.copy(fontWeight = FontWeight.SemiBold), color = Palette.textPrimary)
    }
}

// MARK: - Small interaction helper (clickable without ripple, for pill segments)

@Composable
private fun Modifier.clickableNoRipple(onClick: () -> Unit): Modifier =
    this.clickable(
        indication = null,
        interactionSource = remember { MutableInteractionSource() },
        onClick = onClick,
    )
