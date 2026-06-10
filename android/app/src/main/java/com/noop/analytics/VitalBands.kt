package com.noop.analytics

import kotlin.math.abs

/*
 * VitalBands.kt — personal-baseline banding for the Health Monitor's vital tiles.
 * Faithful Kotlin port of StrandAnalytics/VitalBands.swift (verified on macOS).
 *
 * In-range is judged against the user's OWN trailing baseline (the Winsorized EWMA the rest
 * of [Baselines] builds) once it is trusted — minNightsTrust (14) valid nights and not stale.
 * Until then, and again whenever a wear gap makes the baseline stale, the fixed population
 * range is the fallback.
 *
 * MetricCfg's physiological bounds stay an absolute outer guard either way. They are
 * deliberately NOT used as the in-range band: that would resurrect the exact false positive
 * this fixes — a perfectly normal personal HRV of 35 ms reading permanently out-of-range
 * against the 40–120 population band. The bounds only catch values implausible for any human.
 *
 * Outputs are APPROXIMATE and not medical advice.
 */
object VitalBands {

    enum class Band(val raw: String) {
        IN_RANGE("inRange"), OUT_OF_RANGE("outOfRange"), NO_DATA("noData")
    }

    /** How the band was judged — drives the tile's caption wording. */
    enum class Basis(val raw: String) { PERSONAL("personal"), POPULATION("population") }

    data class Result(val band: Band, val basis: Basis, val nights: Int)

    /** |z| at or below this is in-range vs the personal baseline (~95% of the user's own
     *  normal nights; the |z| <= 1 of [Baselines.deviation] would flag ~32% — too noisy for
     *  a passive tile). */
    const val sigmaK: Double = 2.0

    /**
     * Band a single vital [value].
     *
     * [history] is nightly values oldest→newest EXCLUDING the displayed day (null = missing
     * night; run [calendarSeries] first to pad real wear gaps so staleness sees them).
     * [populationRange] is the typical-adult fallback used until the baseline is trusted.
     * A null [cfg] disables the personal path entirely (SpO₂ stays population-only — there is
     * no SpO₂ MetricCfg and an absolute floor is meaningful regardless of personal history).
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
        // Absolute-plausibility outer guard: a value outside the physiological bounds is
        // out-of-range no matter how wide the personal spread happens to be.
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

    // ── Skin temp (mixed semantics: absolute °C from CSV import vs ±°C on-device deviation) ──

    /** A skin-temp value >= 20 °C is read as ABSOLUTE skin temperature; smaller magnitudes as a
     *  ±°C deviation. The WHOOP CSV export stores absolute °C while the on-device pipeline stores
     *  a deviation — a merged series is bimodal, so the displayed value picks which kind its
     *  history keeps. Heuristic but physically safe: no real wrist temp is below 20 °C and no
     *  real deviation reaches ±20 °C. */
    fun isAbsoluteSkinTemp(v: Double): Boolean = v >= 20.0

    /** Keep only history entries of the SAME kind (absolute vs deviation) as the displayed
     *  [value]; entries of the other kind become null (missing nights) so the baseline isn't
     *  folded across two incompatible scales. */
    fun skinTempHistory(value: Double, history: List<Double?>): List<Double?> {
        val absolute = isAbsoluteSkinTemp(value)
        return history.map { v ->
            if (v != null && isAbsoluteSkinTemp(v) == absolute) v else null
        }
    }

    /** Deviation-semantics config for on-device skin-temp rows: ±°C around the personal mean,
     *  guarded to a physically sane ±8 °C. (The standard `skin_temp` config in [Baselines] is
     *  the ABSOLUTE-°C one, used for CSV-imported rows.) */
    val skinTempDeviationCfg = MetricCfg(
        minVal = -8.0, maxVal = 8.0, floorSpread = 0.3, halfLifeB = 14.0, halfLifeS = 21.0,
    )

    // ── Calendar padding ────────────────────────────────────────────────────────────────────

    /** Calendar-align (day, value) rows keyed "yyyy-MM-dd" into a nightly series with null for
     *  every absent day, so the baseline's staleness logic sees real wear gaps (otherwise a user
     *  returning after months would be banded against an ancient still-"trusted" baseline).
     *  Malformed keys are dropped; last write wins for a duplicated day. */
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
