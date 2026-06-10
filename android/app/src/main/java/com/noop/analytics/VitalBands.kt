package com.noop.analytics

import kotlin.math.abs

/*
 * VitalBands.kt — personal-baseline banding for the Health Monitor's vital tiles.
 * Faithful Kotlin port of StrandAnalytics/VitalBands.swift.
 *
 * In-range is judged against the user's OWN trailing baseline (Baselines' Winsorized EWMA)
 * once it is trusted (>= minNightsTrust = 14 valid nights and not stale); until then — and
 * when the baseline has gone stale after a wear gap — the fixed population range is the
 * fallback. MetricCfg's physiological bounds stay an absolute outer guard either way
 * (deliberately NOT the population range: that would resurrect the false positive being
 * fixed, e.g. a perfectly normal personal HRV of 35 ms vs the 40–120 population band).
 * Outputs are APPROXIMATE and not medical advice.
 */
object VitalBands {

    enum class Band(val raw: String) {
        IN_RANGE("inRange"), OUT_OF_RANGE("outOfRange"), NO_DATA("noData")
    }

    enum class Basis(val raw: String) { PERSONAL("personal"), POPULATION("population") }

    data class Result(val band: Band, val basis: Basis, val nights: Int)

    /** |z| at or below this is in-range vs the personal baseline (~95% of the user's own
     *  normal nights; |z| <= 1 would flag ~32% — too noisy for a passive tile). */
    const val sigmaK: Double = 2.0

    /**
     * Band [value] for one vital. [history] is nightly values oldest→newest EXCLUDING the
     * displayed day (null = missing night; use [calendarSeries] to pad wear gaps). A null
     * [cfg] disables the personal path entirely (SpO₂ stays population-only).
     */
    fun band(
        value: Double?,
        history: List<Double?>,
        populationRange: ClosedFloatingPointRange<Double>,
        cfg: MetricCfg?,
    ): Result {
        if (value == null) return Result(Band.NO_DATA, Basis.POPULATION, 0)
        if (cfg == null) {
            return Result(
                if (populationRange.contains(value)) Band.IN_RANGE else Band.OUT_OF_RANGE,
                Basis.POPULATION, 0,
            )
        }
        val state = Baselines.foldHistory(history, cfg)
        // Absolute-plausibility outer guard: outside the physiological bounds is
        // out-of-range no matter what the personal spread says.
        if (!(cfg.minVal <= value && value <= cfg.maxVal)) {
            return Result(Band.OUT_OF_RANGE, Basis.POPULATION, state.nValid)
        }
        if (state.trusted) {   // >= 14 valid nights and not stale
            val z = Baselines.deviation(value, state).z
            return Result(
                if (abs(z) <= sigmaK) Band.IN_RANGE else Band.OUT_OF_RANGE,
                Basis.PERSONAL, state.nValid,
            )
        }
        return Result(
            if (populationRange.contains(value)) Band.IN_RANGE else Band.OUT_OF_RANGE,
            Basis.POPULATION, state.nValid,
        )
    }

    // MARK: - Skin temp (mixed semantics: absolute °C from CSV import vs ±°C deviation on-device)

    /** Values >= 20 °C read as absolute skin temperature; smaller magnitudes as deviations.
     *  The WHOOP CSV export stores absolute °C in the skin-temp column while the on-device
     *  pipeline stores a deviation — a merged series is bimodal, so the displayed value
     *  picks which kind its history keeps. Heuristic but physically safe. */
    fun isAbsoluteSkinTemp(v: Double): Boolean = v >= 20.0

    /** Keep only history entries of the SAME kind as the displayed [value]
     *  (others become null = missing nights) so the baseline isn't bimodal. */
    fun skinTempHistory(value: Double, history: List<Double?>): List<Double?> {
        val absolute = isAbsoluteSkinTemp(value)
        return history.map { v ->
            if (v != null && isAbsoluteSkinTemp(v) == absolute) v else null
        }
    }

    /** Deviation-semantics config for on-device skin-temp rows (±°C around the personal mean). */
    val skinTempDeviationCfg = MetricCfg(
        minVal = -8.0, maxVal = 8.0, floorSpread = 0.3, halfLifeB = 14.0, halfLifeS = 21.0,
    )

    // MARK: - Calendar padding

    /** Calendar-align (day, value) rows ("yyyy-MM-dd" keys) into a nightly series with null
     *  for missing days, so Baselines staleness sees wear gaps. Malformed keys are dropped. */
    fun calendarSeries(rows: List<Pair<String, Double?>>): List<Double?> {
        val parsed = rows.mapNotNull { (day, v) ->
            runCatching { java.time.LocalDate.parse(day) }.getOrNull()?.let { it to v }
        }
        val first = parsed.minOfOrNull { it.first } ?: return emptyList()
        val last = parsed.maxOfOrNull { it.first } ?: return emptyList()
        val byDay = parsed.associate { it.first to it.second }
        val out = ArrayList<Double?>()
        var d = first
        while (!d.isAfter(last)) {
            out.add(byDay[d])
            d = d.plusDays(1)
        }
        return out
    }
}
