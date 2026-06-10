package com.noop.analytics

/*
 * AnalyticsModels.kt — shared on-device analytics value types.
 *
 * Faithful Kotlin port of the shared model types that the StrandAnalytics Swift
 * package defines and shares across its analyzers:
 *   - StrandAnalytics.swift  → [StrandAnalytics] version marker
 *   - WorkoutDetector.swift  → [UserProfile], [ExerciseSession], [ActivityPoint]
 *   - SleepStager.swift      → [StageSegment], [DetectedSleep], [HypnogramMetrics]
 *   - Baselines.swift        → [MetricCfg], [BaselineStatus], [BaselineState], [Deviation]
 *   - AnalyticsEngine.swift  → [ProfileBaselines], [DayResult]
 *
 * Naming notes (clash avoidance):
 *   - The analytics-internal detected-sleep type is [DetectedSleep] so it does NOT
 *     clash with the Room entity com.noop.data.SleepSession.
 *   - HR-zone display types ([HrZone]/[HrZoneSet]/[TimeInZone]) live in HrZones.kt.
 *   - HRV result type ([HrvAnalyzer.HrvResult]) lives in HrvAnalyzer.kt.
 *
 * All `ts` / `start` / `end` are wall-clock unix SECONDS (Long) to match the
 * com.noop.data layer; the Swift source uses Int seconds.
 *
 * All derived intensity / energy / sleep-stage outputs are APPROXIMATE and not
 * medical advice (see the per-analyzer Swift headers).
 */

/** On-device analytics namespace marker. Mirrors Swift `StrandAnalytics`. */
object StrandAnalytics {
    const val VERSION: String = "0.1.0"
}

// ─────────────────────────────────────────────────────────────────────────────
// UserProfile (WorkoutDetector.swift)
// ─────────────────────────────────────────────────────────────────────────────

/** User profile for HRmax + calorie estimation. Mirrors Swift `UserProfile`. */
data class UserProfile(
    val weightKg: Double = 70.0,
    val heightCm: Double = 170.0,
    val age: Double = 30.0,
    /** "male" | "female" | "nonbinary". */
    val sex: String = "nonbinary",
)

// ─────────────────────────────────────────────────────────────────────────────
// Sleep staging output shapes (SleepStager.swift)
// ─────────────────────────────────────────────────────────────────────────────

/**
 * A contiguous sleep-stage segment. Times are wall-clock unix seconds.
 * Mirrors Swift `StageSegment` (Codable → encoded verbatim into stagesJSON).
 * `start`/`end` are `var` so the stager can extend the trailing segment in place.
 */
data class StageSegment(
    var start: Long,
    var end: Long,
    /** "wake" | "light" | "deep" | "rem". */
    var stage: String,
)

/**
 * A detected sleep session (in-bed span) with APPROXIMATE staging.
 *
 * Named [DetectedSleep] (NOT SleepSession) to avoid clashing with the Room
 * entity com.noop.data.SleepSession. Mirrors Swift `SleepSession` (the analytics
 * shape in SleepStager.swift), one-to-one.
 */
data class DetectedSleep(
    val start: Long,
    val end: Long,
    /** asleep / in-bed in [0, 1] (AASM TST/TIB; asleep = in-bed − wake). */
    val efficiency: Double,
    val stages: List<StageSegment>,
    /** Lowest 5-min rolling-mean HR during the session (bpm), or null. */
    val restingHR: Int?,
    /** Mean RMSSD over 5-min windows across the session (ms), or null. */
    val avgHRV: Double?,
)

/**
 * AASM-style metrics from a session's stage segments.
 * Mirrors Swift `SleepStager.HypnogramMetrics`.
 */
data class HypnogramMetrics(
    val tibS: Double,
    val tstS: Double,
    val sptS: Double,
    val solS: Double,
    /** NaN if no REM. */
    val remLatencyS: Double,
    val wasoS: Double,
    val efficiency: Double,
    val disturbances: Int,
    val deepMin: Double,
    val remMin: Double,
    val lightMin: Double,
    val deepPct: Double,
    val remPct: Double,
    val lightPct: Double,
)

// ─────────────────────────────────────────────────────────────────────────────
// Workout detection output shapes (WorkoutDetector.swift)
// ─────────────────────────────────────────────────────────────────────────────

/**
 * Per-record motion-intensity sample. Mirrors Swift `WorkoutDetector.ActivityPoint`.
 */
data class ActivityPoint(
    val ts: Long,
    val intensity: Double,
)

/**
 * A detected workout window. All intensity fields are APPROXIMATE.
 * Mirrors Swift `ExerciseSession`.
 */
data class ExerciseSession(
    val start: Long,
    val end: Long,
    val avgHR: Double,
    val peakHR: Int,
    val strain: Double?,
    val durationS: Double,
    /** Edwards zone (0–5) time breakdown as % of HR samples; sums to 100. */
    val zoneTimePct: Map<Int, Double>,
    /** Mean Karvonen %HRR over the bout, clamped [0, 100], or null. */
    val avgHRRPct: Double?,
    /** Effective HRmax used for zone math (bpm), or null. */
    val hrmax: Double?,
    /** "caller" | "observed" | "tanaka" | "unknown". */
    val hrmaxSource: String,
    val caloriesKcal: Double?,
    val caloriesKJ: Double?,
)

// ─────────────────────────────────────────────────────────────────────────────
// Personal baselines (Baselines.swift)
// ─────────────────────────────────────────────────────────────────────────────

/** Per-metric configuration for the baseline model. Mirrors Swift `MetricCfg`. */
data class MetricCfg(
    /** Physiological lower bound (hard reject below). */
    val minVal: Double,
    /** Physiological upper bound (hard reject above). */
    val maxVal: Double,
    /** σ_floor: minimum dispersion. */
    val floorSpread: Double,
    /** Baseline-center half-life (nights). */
    val halfLifeB: Double,
    /** Spread half-life (nights, slower than center). */
    val halfLifeS: Double,
)

/**
 * Baseline status flags (cold-start → trusted → stale).
 * Mirrors Swift `BaselineStatus` (String-raw-valued enum); [raw] preserves the
 * exact lowercase wire string the Swift `rawValue` used.
 */
enum class BaselineStatus(val raw: String) {
    /** Fewer than MIN_NIGHTS_SEED valid nights; no score yet. */
    CALIBRATING("calibrating"),
    /** Between seed and trust thresholds; usable, higher uncertainty. */
    PROVISIONAL("provisional"),
    /** At least MIN_NIGHTS_TRUST valid nights. */
    TRUSTED("trusted"),
    /** Usable but no update for > STALE_DAYS nights. */
    STALE("stale"),
}

/**
 * Immutable snapshot of a personal baseline for one metric after N nights.
 * Mirrors Swift `BaselineState`.
 */
data class BaselineState(
    /** Robust EWMA center (the personal "mean"). */
    val baseline: Double,
    /**
     * EWMA of absolute deviations, floored at cfg.floorSpread. Multiply by 1.253
     * to approximate Gaussian σ.
     */
    val spread: Double,
    /** Count of valid nights contributing to the state. */
    val nValid: Int,
    /** Consecutive nights with no valid value (staleness tracking). */
    val nightsSinceUpdate: Int,
    /** Cold-start / staleness status. */
    val status: BaselineStatus,
) {
    /** True iff fully trusted (not calibrating or stale). */
    val trusted: Boolean get() = status == BaselineStatus.TRUSTED

    /** True iff at least provisionally usable (nValid ≥ MIN_NIGHTS_SEED). */
    val usable: Boolean
        get() = status == BaselineStatus.PROVISIONAL || status == BaselineStatus.TRUSTED
}

/** Three forms of deviation from a personal baseline. Mirrors Swift `Deviation`. */
data class Deviation(
    /** Robust z-score: (value − baseline) / (1.253 × spread). */
    val z: Double,
    /** Signed physical-units delta: value − baseline. */
    val delta: Double,
    /** Fractional deviation: value / baseline − 1. */
    val ratio: Double,
    /** True iff |z| ≤ 1.0. */
    val inNormalRange: Boolean,
)

// ─────────────────────────────────────────────────────────────────────────────
// Engine orchestration shapes (AnalyticsEngine.swift)
// ─────────────────────────────────────────────────────────────────────────────

/**
 * Baselines passed in by the caller (built from prior nights via Baselines).
 * Mirrors Swift `AnalyticsEngine.ProfileBaselines`.
 */
data class ProfileBaselines(
    val hrv: BaselineState? = null,
    val restingHR: BaselineState? = null,
    val resp: BaselineState? = null,
    val skinTemp: BaselineState? = null,
)

/**
 * The full analysis result for one day. Mirrors Swift `AnalyticsEngine.DayResult`.
 *
 * NOTE: [daily] is the Room entity com.noop.data.DailyMetric (cache shape, with
 * recovery/strain/sleep rolled up). The detected sleep sessions are the analytics
 * [DetectedSleep] shape; persistence to com.noop.data.SleepSession rows is wired
 * by the caller (the engine port maps DetectedSleep → SleepSession when upserting).
 */
data class DayResult(
    /** DailyMetric in the Room cache shape (recovery/strain/sleep rolled up). */
    val daily: com.noop.data.DailyMetric,
    /** Detected sleep sessions (rich, with stage segments). */
    val sleepSessions: List<DetectedSleep>,
    /** Detected workout/exercise sessions. */
    val workouts: List<ExerciseSession>,
    /** Recovery score [0,100] or null (cold-start / no HRV baseline). */
    val recovery: Double?,
    /** Day strain [0,21] or null (insufficient HR samples / invalid HRR). */
    val strain: Double?,
    /**
     * Wear-gated mean in-bed skin temperature (°C) for this night, or null when no worn in-bed
     * samples were available. Baseline-INDEPENDENT (like avgHrv): the caller seeds a personal
     * skin-temp baseline from these nightly means and re-derives [com.noop.data.DailyMetric.skinTempDevC]
     * in a second pass. APPROXIMATE. (PR #85)
     */
    val nightlySkinTempC: Double? = null,
)
