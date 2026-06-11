package com.noop.ui

import androidx.compose.animation.core.CubicBezierEasing
import androidx.compose.animation.core.Easing
import androidx.compose.animation.core.FastOutSlowInEasing
import androidx.compose.animation.core.LinearOutSlowInEasing
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Shapes
import androidx.compose.material3.Typography
import androidx.compose.material3.darkColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp

// MARK: - Palette (ported verbatim from StrandDesign/Palette.swift §9.1)
//
// Dark-only, instrument-grade. Hex values are exact per the spec — do not substitute.
// Mirrors the macOS StrandPalette enum so the Android port shares one visual language.

object Palette {

    // Surfaces (§9.1)
    val surfaceBase = Color(0xFF060A08)    // near-black, faint green
    val surfaceRaised = Color(0xFF0D1512)  // dark green-black cards
    val surfaceOverlay = Color(0xFF121D18) // raised / popovers / sheets
    val surfaceInset = Color(0xFF0A100D)   // wells / chart insets
    val hairline = Color(0xFF1B2620)       // soft green-grey 1px border
    val hairlineStrong = Color(0xFF27362E) // hover / emphasis border

    // Text (§9.1)
    val textPrimary = Color(0xFFF4F7F5)
    val textSecondary = Color(0xFF8B9690)
    val textTertiary = Color(0xFF6F7A74)

    // Glow (§9.1)
    val glowAmbient = Color(0xFF1B2A3A)

    // Accent — chrome, not data (§9.1)
    val accent = Color(0xFF18C98B)       // health green
    val accentHover = Color(0xFF2FE0A0)
    val accentMuted = Color(0xFF10271F)  // dark-green tint (selected rows)
    val focusRing = Color(0xFF18C98B)
    const val disabledOpacity = 0.45f

    // Recovery gradient — traffic light (low red → high green).
    val recovery000 = Color(0xFFFF4F73) // depleted — pink-red
    val recovery030 = Color(0xFFF5A623) // low — amber
    val recovery055 = Color(0xFFE8C24B) // moderate — gold
    val recovery078 = Color(0xFF18C98B) // primed — health green
    val recovery100 = Color(0xFF2FE6A8) // peak — bright green

    /** Ordered gradient stops (position 0..1 → color) for the recovery scale. */
    val recoveryStops: List<Pair<Float, Color>> = listOf(
        0.00f to recovery000,
        0.30f to recovery030,
        0.55f to recovery055,
        0.78f to recovery078,
        1.00f to recovery100,
    )

    // Strain ramp — ember → magenta (§9.1)
    val strain000 = Color(0xFFE8B04B) // ember / warm gold
    val strain033 = Color(0xFFE8743B) // orange
    val strain066 = Color(0xFFE0476B) // rose-red
    val strain100 = Color(0xFFC13AC1) // magenta

    val strainStops: List<Pair<Float, Color>> = listOf(
        0.00f to strain000,
        0.33f to strain033,
        0.66f to strain066,
        1.00f to strain100,
    )

    // Sleep stages (§9.1)
    val sleepAwake = Color(0xFFE0476B) // rose
    val sleepLight = Color(0xFF5C6FB1) // periwinkle
    val sleepDeep = Color(0xFF2C3A7A)  // deep indigo
    val sleepREM = Color(0xFF5BE0C7)   // mint

    // HR zones (§9.1)
    val zone1 = Color(0xFF4FA9C9)
    val zone2 = Color(0xFF5BD3A0)
    val zone3 = Color(0xFFE8C24B)
    val zone4 = Color(0xFFE8743B)
    val zone5 = Color(0xFFE0476B)

    /** HR zones indexed 1..5; index 0 mirrors zone1 for convenience. */
    val hrZones: List<Color> = listOf(zone1, zone1, zone2, zone3, zone4, zone5)

    // Status (§9.1) — never reused as recovery colors.
    val statusPositive = Color(0xFF18C98B)
    val statusWarning = Color(0xFFF5A623)
    val statusCritical = Color(0xFFFF4F73)

    // Per-metric accents — Apple-Health bars / HRV / energy / risk.
    val metricCyan = Color(0xFF2FC7FF)   // Apple Health bars
    val metricPurple = Color(0xFFA879FF) // HRV / strain-style data
    val metricAmber = Color(0xFFF5A623)  // calories / moderate
    val metricRose = Color(0xFFFF4F73)   // risk / high strain / low recovery

    // MARK: - Sampling helpers (mirror StrandPalette.sample / recoveryColor)

    /** Linear-interpolate two colors in sRGB space (matches StrandPalette.interpolate). */
    private fun lerp(a: Color, b: Color, t: Float): Color {
        val tt = t.coerceIn(0f, 1f)
        return Color(
            red = a.red + (b.red - a.red) * tt,
            green = a.green + (b.green - a.green) * tt,
            blue = a.blue + (b.blue - a.blue) * tt,
            alpha = a.alpha + (b.alpha - a.alpha) * tt,
        )
    }

    /** Sample a set of (location, color) stops at a normalized position 0..1. */
    fun sample(stops: List<Pair<Float, Color>>, position: Float): Color {
        if (stops.isEmpty()) return Color.Transparent
        if (stops.size == 1) return stops.first().second
        val t = position.coerceIn(0f, 1f)
        var lower = stops.first()
        var upper = stops.last()
        for (i in 0 until stops.size - 1) {
            val a = stops[i]
            val b = stops[i + 1]
            if (t >= a.first && t <= b.first) {
                lower = a; upper = b; break
            }
        }
        val span = upper.first - lower.first
        val localT = if (span > 0f) (t - lower.first) / span else 0f
        return lerp(lower.second, upper.second, localT)
    }

    /** Sample the recovery gradient at a recovery score 0..100. */
    fun recoveryColor(score: Double): Color = sample(recoveryStops, (score / 100.0).toFloat())

    /** Sample the strain gradient at a strain value on the 0..21 Whoop scale. */
    fun strainColor(strain: Double): Color = sample(strainStops, (strain / 21.0).toFloat())

    /** The state word for a recovery score, per spec §9.3. */
    fun recoveryState(score: Double): String = when {
        score < 25 -> "DEPLETED"
        score < 50 -> "LOW"
        score < 70 -> "MODERATE"
        score < 88 -> "PRIMED"
        else -> "PEAK"
    }

    /** HR-zone color for a 1..5 zone index (clamped). */
    fun hrZoneColor(zone: Int): Color = hrZones[zone.coerceIn(1, 5)]

    /** The signature recovery gradient as a horizontal sweep brush (for bars). */
    fun recoveryBrush(): Brush =
        Brush.horizontalGradient(*recoveryStops.toTypedArray())

    /** The strain ramp as a horizontal sweep brush. */
    fun strainBrush(): Brush =
        Brush.horizontalGradient(*strainStops.toTypedArray())
}

// MARK: - Motion (ported from StrandDesign/Motion.swift §9.6)
//
// Physiological motion — breathe / pulse / flow, no cartoon bounce.

object Motion {
    // Durations (ms)
    const val durationFast = 180       // hover/press feedback
    const val durationStandard = 300   // card appear, fades
    const val durationSlow = 900       // ring arc, waveform ignite
    const val breathPeriodMs = 3200    // one breath cycle for ambient pulsing

    // Easings (Compose equivalents of the SwiftUI curves)
    val easeOut: Easing = LinearOutSlowInEasing
    val easeInOut: Easing = FastOutSlowInEasing
    val drawIn: Easing = LinearOutSlowInEasing
    val interactive: Easing = CubicBezierEasing(0.2f, 0.0f, 0.0f, 1.0f)
}

// MARK: - Shared UI tokens (ported Android-side from the StrandDesign contract)

object StrandAlpha {
    const val subtleLine = 0.60f
    const val selectedFill = 0.12f
    const val selectedBorder = 0.55f
    const val chartFillStrong = 0.28f
    const val chartFillSoft = 0.04f
    const val chartMarker = 0.35f
    const val chartShadow = 0.28f
    const val chartLabel = 0.95f
    const val unselectedBar = 0.88f
    const val warningFill = 0.12f
    const val warningBorder = 0.40f
}

// MARK: - Metrics (ported from StrandDesign/Components.swift NoopMetrics)

object Metrics {
    val space2 = 2.dp
    val space4 = 4.dp
    val space6 = 6.dp
    val space8 = 8.dp
    val space10 = 10.dp
    val space12 = 12.dp
    val space14 = 14.dp
    val space16 = 16.dp
    val space18 = 18.dp
    val space24 = 24.dp
    val cardRadius = 16.dp
    val cornerXs = 2.dp
    val cornerSm = 12.dp
    val cornerBadge = 6.dp
    val cornerPill = 50.dp
    val cardPadding = 16.dp
    val gap = 12.dp           // gap between cards
    val sectionGap = 28.dp    // gap between sections
    val screenPadding = 24.dp
    val tileHeight = 104.dp   // every metric tile is this tall
    val chartHeight = 220.dp
    val divider = 1.dp
    val compactChartHeight = chartHeight - 90.dp
    val selectorTopUp = sectionGap - 20.dp
    val iconButton = 36.dp
    val iconSmall = 18.dp
    val selectorPadding = 10.dp
    val selectorSpacing = 8.dp
    val sparkWidthWide = 64.dp
    val sparkWidth = 58.dp
    val sparkHeight = 22.dp
    val stageStripHeight = 34.dp
    val trendStripHeight = 120.dp
    val sparklineHeight = 28.dp
    val segmentBarHeight = 18.dp
    val legendSwatch = 9.dp
    val legendLineWidth = 14.dp
    val legendLineHeight = 3.dp
    val progressHeight = 10.dp
}

// MARK: - Typography (ported from StrandDesign/Typography.swift §9.2)
//
// SF Pro on macOS; on Android we use the platform default (Roboto/system) with
// the same sizes/weights. Numeric/live styles request tabular-ish alignment via
// medium/semibold weights; Compose has no monospacedDigit toggle, so live values
// use Monospace where exact non-reflow alignment is load-bearing.

object NoopType {
    private val sans = FontFamily.Default
    private val monoFamily = FontFamily.Monospace

    /** Display 64–80 / Semibold — the recovery ring number. */
    fun display(size: Float = 72f) = TextStyle(
        fontFamily = sans, fontWeight = FontWeight.SemiBold, fontSize = size.sp,
    )

    val title1 = TextStyle(fontFamily = sans, fontWeight = FontWeight.Bold, fontSize = 28.sp)
    val title2 = TextStyle(fontFamily = sans, fontWeight = FontWeight.SemiBold, fontSize = 22.sp)
    val headline = TextStyle(fontFamily = sans, fontWeight = FontWeight.SemiBold, fontSize = 17.sp)
    val body = TextStyle(fontFamily = sans, fontWeight = FontWeight.Normal, fontSize = 15.sp)
    val subhead = TextStyle(fontFamily = sans, fontWeight = FontWeight.Normal, fontSize = 13.sp)
    val caption = TextStyle(fontFamily = sans, fontWeight = FontWeight.Normal, fontSize = 12.sp)
    val footnote = TextStyle(fontFamily = sans, fontWeight = FontWeight.Normal, fontSize = 11.sp)

    /** Overline 11 / Semibold, +0.8 tracking, ALL-CAPS at use site. */
    val overline = TextStyle(
        fontFamily = sans, fontWeight = FontWeight.SemiBold, fontSize = 11.sp,
        letterSpacing = 0.8.sp,
    )

    /** Mono 13 — raw / log views. */
    val mono = TextStyle(fontFamily = monoFamily, fontWeight = FontWeight.Normal, fontSize = 13.sp)

    /** A numeric style at an arbitrary size (Monospace so live values don't reflow). */
    fun number(size: Float, weight: FontWeight = FontWeight.SemiBold) = TextStyle(
        fontFamily = monoFamily, fontWeight = weight, fontSize = size.sp,
    )

    fun mono(size: Float, weight: FontWeight = FontWeight.Normal) = TextStyle(
        fontFamily = monoFamily, fontWeight = weight, fontSize = size.sp,
    )

    val bodyNumber = TextStyle(fontFamily = monoFamily, fontWeight = FontWeight.Normal, fontSize = 15.sp)
    val captionNumber = TextStyle(fontFamily = monoFamily, fontWeight = FontWeight.Medium, fontSize = 12.sp)
    val metricInline = number(15f)
    val chartValue = number(18f)
    val chartValueLarge = number(22f)
    val tileValue = number(24f)
    val tileValueLarge = number(26f)

    const val overlineTracking = 0.8f
}

// MARK: - Material3 bridge

private val NoopColorScheme = darkColorScheme(
    primary = Palette.accent,
    onPrimary = Palette.surfaceBase,
    primaryContainer = Palette.accentMuted,
    onPrimaryContainer = Palette.accentHover,
    secondary = Palette.metricPurple,
    onSecondary = Palette.surfaceBase,
    background = Palette.surfaceBase,
    onBackground = Palette.textPrimary,
    surface = Palette.surfaceRaised,
    onSurface = Palette.textPrimary,
    surfaceVariant = Palette.surfaceOverlay,
    onSurfaceVariant = Palette.textSecondary,
    outline = Palette.hairline,
    outlineVariant = Palette.hairlineStrong,
    error = Palette.statusCritical,
    onError = Palette.surfaceBase,
)

private val NoopMaterialTypography = Typography(
    displayLarge = NoopType.display(72f),
    titleLarge = NoopType.title1,
    titleMedium = NoopType.title2,
    titleSmall = NoopType.headline,
    bodyLarge = NoopType.body,
    bodyMedium = NoopType.subhead,
    bodySmall = NoopType.caption,
    labelLarge = NoopType.headline,
    labelMedium = NoopType.caption,
    labelSmall = NoopType.overline,
)

private val NoopShapes = Shapes(
    extraSmall = RoundedCornerShape(8.dp),
    small = RoundedCornerShape(12.dp),
    medium = RoundedCornerShape(Metrics.cardRadius),
    large = RoundedCornerShape(20.dp),
    extraLarge = RoundedCornerShape(28.dp),
)

/**
 * NoopTheme — dark, instrument-grade. Always dark regardless of system setting
 * (the design system is dark-only), but `isSystemInDarkTheme` is read so the
 * status-bar contract is satisfied on devices that key off it.
 */
@Composable
fun NoopTheme(content: @Composable () -> Unit) {
    // The design system is dark-only; we always apply the dark scheme regardless of
    // the system setting. `isSystemInDarkTheme` is referenced so status-bar tooling
    // that keys off it stays satisfied.
    isSystemInDarkTheme()
    MaterialTheme(
        colorScheme = NoopColorScheme,
        typography = NoopMaterialTypography,
        shapes = NoopShapes,
        content = content,
    )
}
