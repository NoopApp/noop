package com.noop.analytics

import com.noop.data.DailyMetric
import kotlin.math.sqrt

/**
 * On-device "Readiness" intelligence.
 *
 * Synthesizes a handful of established, non-medical sports-science signals from the daily-metrics
 * history into a single readiness read plus the drivers behind it. Everything here is a pure,
 * deterministic function of the rows you pass in — no networking, no strap commands, no state.
 *
 * Faithful Kotlin port of
 * Packages/StrandAnalytics/Sources/StrandAnalytics/ReadinessEngine.swift (verified on macOS).
 * Same windows, same thresholds, same outputs.
 *
 * Signals and their references:
 * - **HRV readiness** — z-score of today's HRV against the personal trailing baseline. A drop of
 *   roughly half a standard deviation flags autonomic fatigue (Plews et al. 2013; Buchheit 2014).
 * - **Resting-HR drift** — elevated resting HR vs baseline is a classic overtraining / illness
 *   signal (Lamberts et al. 2004).
 * - **Respiratory-rate drift** — a rise in sleeping respiratory rate is an early illness signal.
 * - **Training Stress Balance (ACWR)** — acute (7-day) vs chronic (28-day) strain. The 0.8–1.3
 *   band is the "sweet spot"; >1.5 is associated with higher injury risk (Gabbett 2016).
 * - **Training monotony** — mean/SD of daily strain over a week; high monotony (low variety) is
 *   associated with higher strain and illness (Foster 1998).
 *
 * Not medical advice. These are approximations from a consumer strap; they describe trends in
 * *your own* data, nothing more.
 */
object ReadinessEngine {

    // MARK: Output types

    enum class Level {
        PRIMED,       // signals aligned, load supported
        BALANCED,     // nothing notable either way
        STRAINED,     // one meaningful signal down / load high
        RUNDOWN,      // several recovery signals down
        INSUFFICIENT, // not enough history yet
    }

    enum class Flag { GOOD, NEUTRAL, WATCH, BAD }

    data class Signal(
        val key: String,    // "hrv" | "rhr" | "respRate" | "acwr" | "monotony"
        val label: String,  // short human label
        val detail: String, // one-line plain-English read
        val flag: Flag,
    )

    data class Readiness(
        val level: Level,
        val headline: String,
        val summary: String,
        val signals: List<Signal>,
        /** Acute:chronic workload ratio (null if not enough strain history). */
        val acwr: Double?,
        /** Foster training monotony over the last week (null if not enough strain history). */
        val monotony: Double?,
    )

    // MARK: Tunables (named so the thresholds are auditable)

    private const val baselineWindow = 30   // days for HRV / RHR / RR baselines
    private const val minBaseline = 7       // need at least this many baseline nights
    private const val acuteWindow = 7
    private const val chronicWindow = 28
    private const val minChronic = 14       // need at least this much strain history for ACWR

    // Resp-rate signal is sourced from either clean cloud RR or a higher-variance on-device RSA
    // estimate (no source flag on the field), so it uses wider z thresholds than HRV/RHR and a
    // physiologic sanity band. A single noisy RSA night should not reach BAD (which feeds recoveryDown).
    private const val respZWatch = 1.5      // raised vs HRV/RHR (was 1.0) to absorb RSA night-to-night noise
    private const val respZBad = 2.0        // raised vs HRV/RHR (was 1.5) so one off-night can't trigger RUNDOWN
    // Single canonical band, owned by the producer so the stored RSA value can't disagree with this
    // gate (#78): SleepStager.respRateFromRR now NaNs anything outside it before persisting.
    private val respPlausibleRange = SleepStager.respPlausibleRangeBpm // plausible sleeping RR (bpm)

    // MARK: Entry point

    /**
     * Evaluate readiness from daily metrics. [days] may be in any order; the most recent day is
     * treated as "today" unless [today] (a YYYY-MM-DD string) is given.
     */
    fun evaluate(days: List<DailyMetric>, today: String? = null): Readiness {
        val sorted = days.sortedBy { it.day }
        // When an explicit [today] is given (the dashboard passes the device's real local day key), use
        // the row for THAT day and nothing else: a stale historical import has no row for today, so the
        // readiness card reads "insufficient" rather than synthesizing off the newest stored — possibly
        // months-old — row (issue #23/#24). With no [today] (live-strap default callers) fall back to the
        // most recent row exactly as before, so nothing wearing the strap nightly changes.
        val latest = if (today != null) sorted.firstOrNull { it.day == today } else sorted.lastOrNull()
        if (latest == null) {
            return Readiness(
                level = Level.INSUFFICIENT,
                headline = "Readiness",
                summary = "Wear the strap for a few nights and your readiness read will appear here.",
                signals = emptyList(), acwr = null, monotony = null,
            )
        }
        val history = sorted.filter { it.day < latest.day }   // everything before today

        val signals = mutableListOf<Signal>()

        // HRV readiness ------------------------------------------------------
        val hrvSignal = zSignal(
            value = latest.avgHrv,
            baseline = history.takeLast(baselineWindow).mapNotNull { it.avgHrv },
            key = "hrv", label = "HRV",
            higherIsBetter = true,
            goodText = "above your baseline — well recovered",
            neutralText = "in your normal range",
            watchText = "a touch below baseline",
            badText = "suppressed — a sign of autonomic fatigue",
        )
        if (hrvSignal != null) signals.add(hrvSignal)

        // Resting-HR drift ---------------------------------------------------
        val rhrSignal = zSignal(
            value = latest.restingHr?.toDouble(),
            baseline = history.takeLast(baselineWindow).mapNotNull { it.restingHr?.toDouble() },
            key = "rhr", label = "Resting HR",
            higherIsBetter = false,
            goodText = "at or below baseline",
            neutralText = "in your normal range",
            watchText = "running a little high",
            badText = "elevated — overtraining or illness can do this",
        )
        if (rhrSignal != null) signals.add(rhrSignal)

        // Respiratory-rate drift (illness early signal) ----------------------
        // respRateBpm may be a clean cloud value OR a higher-variance on-device RSA estimate
        // (WHOOP5 BLE-only) and carries no source flag, so gate conservatively for BOTH: keep the
        // minBaseline + sd>0 guard, only act on physiologically plausible sleeping-RR (~8-25 bpm),
        // and use wider resp-only z thresholds (WATCH 1.5 / BAD 2.0) so a single noisy night can't
        // reach BAD (which would feed recoveryDown), while a sustained genuine rise still flags.
        val rr = latest.respRateBpm
        if (rr != null && rr in respPlausibleRange) {
            val base = history.takeLast(baselineWindow).mapNotNull { it.respRateBpm }
            val m = mean(base)
            val sd = sampleSD(base)
            if (base.size >= minBaseline && m != null && m in respPlausibleRange && sd != null && sd > 0) {
                val z = (rr - m) / sd
                if (z >= respZBad) {
                    signals.add(
                        Signal(
                            key = "respRate", label = "Respiratory rate",
                            detail = "up vs baseline — sometimes an early sign of getting sick", flag = Flag.BAD,
                        )
                    )
                } else if (z >= respZWatch) {
                    signals.add(
                        Signal(
                            key = "respRate", label = "Respiratory rate",
                            detail = "slightly raised vs baseline", flag = Flag.WATCH,
                        )
                    )
                }
            }
        }

        // Training Stress Balance (ACWR) + monotony --------------------------
        val strainSeries = sorted.mapNotNull { it.strain }
        var acwr: Double? = null
        var monotony: Double? = null
        if (strainSeries.size >= minChronic) {
            val acute = mean(strainSeries.takeLast(acuteWindow))!!
            val chronic = mean(strainSeries.takeLast(chronicWindow))!!
            if (chronic > 0) {
                val ratio = acute / chronic
                acwr = ratio
                signals.add(acwrSignal(ratio))
            }
            // Foster monotony over the last week of strain.
            val week = strainSeries.takeLast(acuteWindow)
            val sd = sampleSD(week)
            val m = mean(week)
            if (week.size >= 4 && sd != null && sd > 0 && m != null) {
                val mono = m / sd
                monotony = mono
                if (mono >= 2.0) {
                    signals.add(
                        Signal(
                            key = "monotony", label = "Training variety",
                            detail = "low — similar strain every day raises strain/illness risk", flag = Flag.WATCH,
                        )
                    )
                }
            }
        }

        val (level, headline, summary) = synthesize(
            signals = signals,
            hasHistory = history.isNotEmpty() || acwr != null,
        )
        return Readiness(
            level = level, headline = headline, summary = summary,
            signals = signals, acwr = acwr, monotony = monotony,
        )
    }

    // MARK: Signal builders

    /** Build a z-score signal for a metric where the baseline is the trailing window. */
    private fun zSignal(
        value: Double?, baseline: List<Double>,
        key: String, label: String, higherIsBetter: Boolean,
        goodText: String, neutralText: String,
        watchText: String, badText: String,
    ): Signal? {
        if (value == null || baseline.size < minBaseline) return null
        val m = mean(baseline) ?: return null
        val sd = sampleSD(baseline) ?: return null
        if (sd <= 0) return null
        // Orient z so positive always means "better".
        val z = (if (higherIsBetter) (value - m) else (m - value)) / sd
        val flag: Flag
        val text: String
        when {
            z >= 0.5 -> { flag = Flag.GOOD; text = goodText }
            z >= -0.5 -> { flag = Flag.NEUTRAL; text = neutralText }
            z >= -1.0 -> { flag = Flag.WATCH; text = watchText }
            else -> { flag = Flag.BAD; text = badText }
        }
        return Signal(key = key, label = label, detail = text, flag = flag)
    }

    private fun acwrSignal(ratio: Double): Signal {
        val pct = String.format("%.2f", ratio)
        return when {
            ratio < 0.8 -> Signal(
                key = "acwr", label = "Training load",
                detail = "ramping down (acute:chronic $pct) — room to build", flag = Flag.WATCH,
            )
            ratio < 1.3 -> Signal(
                key = "acwr", label = "Training load",
                detail = "in the sweet spot (acute:chronic $pct)", flag = Flag.GOOD,
            )
            ratio < 1.5 -> Signal(
                key = "acwr", label = "Training load",
                detail = "building fast (acute:chronic $pct) — watch fatigue", flag = Flag.WATCH,
            )
            else -> Signal(
                key = "acwr", label = "Training load",
                detail = "spiking (acute:chronic $pct) — higher injury risk", flag = Flag.BAD,
            )
        }
    }

    // MARK: Synthesis

    private fun synthesize(signals: List<Signal>, hasHistory: Boolean): Triple<Level, String, String> {
        if (!hasHistory || signals.isEmpty()) {
            return Triple(
                Level.INSUFFICIENT, "Readiness",
                "A few more nights of data and your readiness read will sharpen.",
            )
        }
        val bad = signals.filter { it.flag == Flag.BAD }
        val watch = signals.filter { it.flag == Flag.WATCH }
        val good = signals.filter { it.flag == Flag.GOOD }
        val recoveryDown = signals.any { it.key in listOf("hrv", "rhr", "respRate") && it.flag == Flag.BAD }
        val loadHigh = signals.any { it.key == "acwr" && it.flag == Flag.BAD }

        if (bad.size >= 2 || (recoveryDown && loadHigh)) {
            return Triple(
                Level.RUNDOWN, "Run down",
                "Several signals are down at once. Treat today as recovery — easy movement, real sleep tonight.",
            )
        }
        if (recoveryDown || loadHigh || bad.size >= 1) {
            return Triple(
                Level.STRAINED, "Strained",
                "One of your signals is flagging. You can train, but keep it controlled and bank the recovery.",
            )
        }
        if (good.size >= 2 && watch.isEmpty()) {
            return Triple(
                Level.PRIMED, "Primed",
                "Your signals are aligned and your load is supported. A harder session is well backed today.",
            )
        }
        return Triple(
            Level.BALANCED, "Balanced",
            "Nothing's flagging. Train to feel — your body's holding steady.",
        )
    }

    // MARK: Stats helpers

    fun mean(xs: List<Double>): Double? =
        if (xs.isEmpty()) null else xs.sum() / xs.size

    /** Sample standard deviation (n-1). null for fewer than 2 points. */
    fun sampleSD(xs: List<Double>): Double? {
        if (xs.size < 2) return null
        val m = mean(xs) ?: return null
        val ss = xs.fold(0.0) { acc, x -> acc + (x - m) * (x - m) }
        return sqrt(ss / (xs.size - 1))
    }
}
