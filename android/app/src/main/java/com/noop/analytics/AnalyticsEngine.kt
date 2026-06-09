package com.noop.analytics

import com.noop.data.DailyMetric
import com.noop.data.GravitySample
import com.noop.data.HrSample
import com.noop.data.RespSample
import com.noop.data.RrInterval
import com.noop.data.StepSample
import org.json.JSONArray
import org.json.JSONObject
import java.time.Instant
import java.time.ZoneOffset
import java.time.format.DateTimeFormatter

/*
 * AnalyticsEngine.kt — orchestrator producing DailyMetric + sleep-session results.
 *
 * Faithful Kotlin port of StrandAnalytics/AnalyticsEngine.swift (verified on macOS).
 * Same algorithm, same constants, same thresholds; Kotlin-ized types, Double math.
 *
 * Given a day's raw streams + a user profile + personal baselines, it runs the
 * individual analyzers (SleepStager / RecoveryScorer / StrainScorer / WorkoutDetector
 * / Baselines) and assembles a [com.noop.data.DailyMetric] (Room cache shape) plus the
 * detected [DetectedSleep] sessions.
 *
 * This is a PURE function over its inputs — it does NOT touch the database
 * (persistence is wired by IntelligenceEngine). All derived values are APPROXIMATE.
 *
 * All `ts` / `start` / `end` are wall-clock unix SECONDS (Long); the Swift source
 * uses Int seconds.
 */
object AnalyticsEngine {

    // ─────────────────────────────────────────────────────────────────────────
    // Day-string helper (UTC YYYY-MM-DD), mirrors Swift AnalyticsEngine.isoDay.
    // ─────────────────────────────────────────────────────────────────────────

    private val isoDay: DateTimeFormatter =
        DateTimeFormatter.ofPattern("yyyy-MM-dd").withZone(ZoneOffset.UTC)

    /** Format a unix-seconds timestamp as a UTC YYYY-MM-DD day string. */
    fun dayString(ts: Long): String = isoDay.format(Instant.ofEpochSecond(ts))

    /**
     * JSON-encode stage segments to the verbatim array shape the sleepSession cache
     * stores. Mirrors Swift `encodeStages` (JSONEncoder on [StageSegment]); the field
     * order/names (start, end, stage) match the Codable wire shape and the Android
     * SleepScreen reader.
     */
    fun encodeStages(stages: List<StageSegment>): String? {
        return try {
            val arr = JSONArray()
            for (s in stages) {
                val o = JSONObject()
                o.put("start", s.start)
                o.put("end", s.end)
                o.put("stage", s.stage)
                arr.put(o)
            }
            arr.toString()
        } catch (_: Throwable) {
            null
        }
    }

    /**
     * Analyze one day's streams into a [DayResult].
     *
     * @param day the calendar day (UTC) this metric is for; a sleep session is
     *   attributed to the day its `end` falls on (a night ending that morning).
     * @param hr/rr/resp/gravity the day's raw streams (the wider window around the
     *   night may be passed; sleep detection finds the in-bed span itself).
     * @param profile user profile (age/sex/weight/height) for HRmax + calories.
     * @param baselines personal baselines for recovery normalization.
     * @param maxHROverride explicit HRmax (bpm) to use for strain/zones; null →
     *   Tanaka from profile.age.
     */
    fun analyzeDay(
        day: String,
        hr: List<HrSample> = emptyList(),
        rr: List<RrInterval> = emptyList(),
        resp: List<RespSample> = emptyList(),
        gravity: List<GravitySample> = emptyList(),
        steps: List<StepSample> = emptyList(),
        // Calendar-day-scoped overrides for the ADDITIVE daily totals (steps + activeKcalEst) ONLY.
        // When null, the totals fall back to the same window the rest of the analysis uses (preserving
        // the pure-function contract). The caller (IntelligenceEngine) supplies a full
        // [midnightUtc(day), midnightUtc(day)+86400) read here so a PAST day's late hours — which fall
        // outside the ~42h night-detection window when the current UTC time-of-day is before noon — are
        // still counted. Sleep / recovery / strain / workouts keep using hr/rr/resp/gravity/steps.
        dayHr: List<HrSample>? = null,
        daySteps: List<StepSample>? = null,
        profile: UserProfile,
        baselines: ProfileBaselines = ProfileBaselines(),
        maxHROverride: Double? = null,
    ): DayResult {

        // ── Sleep detection + staging ─────────────────────────────────────────
        val allSessions = SleepStager.detectSleep(hr = hr, rr = rr, resp = resp, gravity = gravity)
        // Sessions attributed to `day` = those whose end falls on `day` (UTC).
        val matched = allSessions.filter { dayString(it.end) == day }

        // ── Daily sleep aggregates (AASM, in-bed weighted) ────────────────────
        var deepS = 0.0
        var remS = 0.0
        var lightS = 0.0
        var tstS = 0.0
        var inBedS = 0.0
        var effWeighted = 0.0
        var disturbances = 0
        for (s in matched) {
            val m = SleepStager.hypnogramMetrics(s)
            val inBed = (s.end - s.start).toDouble()
            inBedS += inBed
            effWeighted += s.efficiency * inBed
            deepS += m.deepMin * 60.0
            remS += m.remMin * 60.0
            lightS += m.lightMin * 60.0
            tstS += m.tstS
            disturbances += m.disturbances
        }
        val efficiency = if (inBedS > 0) effWeighted / inBedS else 0.0

        // Daily resting HR = lowest per-session resting HR across matched sessions.
        val restingHRDaily: Int? = matched.mapNotNull { it.restingHR }.minOrNull()
        // Daily avg HRV = in-bed-weighted mean of per-session avg HRV.
        val avgHRVDaily: Double? = run {
            val pairs = matched.mapNotNull { s ->
                s.avgHRV?.let { it to (s.end - s.start).toDouble() }
            }
            if (pairs.isEmpty()) {
                null
            } else {
                val total = pairs.sumOf { it.first * it.second }
                val weight = pairs.sumOf { it.second }
                if (weight > 0) total / weight else null
            }
        }

        // Nightly APPROXIMATE respiratory rate (breaths/min) from the R-R stream via
        // RSA. WHOOP5 v18 carries no raw resp ADC, so this is an on-device estimate,
        // NOT a cloud/clinical respiration value. Per matched in-bed session, estimate
        // over [start, end]; the night's value = median of finite per-session
        // estimates; null only when no session yields a finite estimate.
        val respRateDaily: Double? = run {
            val perSession = matched
                .map { SleepStager.respRateFromRR(rr, it.start, it.end) }
                .filter { it.isFinite() }
            if (perSession.isEmpty()) null else HrvAnalyzer.median(perSession)
        }

        // sleepStart/sleepEnd available for callers wiring sleep_start/end columns.
        @Suppress("UNUSED_VARIABLE") val sleepStart = matched.minOfOrNull { it.start }
        @Suppress("UNUSED_VARIABLE") val sleepEnd = matched.maxOfOrNull { it.end }

        // ── Recovery ──────────────────────────────────────────────────────────
        var recovery: Double? = null
        val hrvVal = avgHRVDaily
        val rhrVal = restingHRDaily
        val hrvBase = baselines.hrv
        if (hrvVal != null && rhrVal != null && hrvBase != null) {
            // Sleep-performance proxy = in-bed-weighted efficiency (0..1).
            val sleepPerf = if (matched.isEmpty()) null else efficiency
            recovery = RecoveryScorer.recovery(
                hrv = hrvVal,
                rhr = rhrVal.toDouble(),
                resp = null, // raw resp not aggregated to a nightly scalar here
                hrvBaseline = hrvBase,
                rhrBaseline = baselines.restingHR,
                respBaseline = baselines.resp,
                sleepPerf = sleepPerf,
            )
        }

        // ── Strain (day cardiovascular load over the full HR window) ──────────
        val effMaxHR: Double? = maxHROverride
            ?: if (profile.age > 0) StrainScorer.tanakaHRmax(profile.age) else null
        val restForStrain = restingHRDaily?.toDouble() ?: StrainScorer.defaultRestingHR
        val strain = StrainScorer.strain(
            hr = hr,
            maxHR = effMaxHR,
            restingHR = restForStrain,
            sex = profile.sex,
        )

        // ── Workouts ──────────────────────────────────────────────────────────
        val workouts = WorkoutDetector.detect(
            hr = hr,
            gravity = gravity,
            restingHR = restingHRDaily?.toDouble(),
            maxHR = maxHROverride,
            age = if (profile.age > 0) profile.age else null,
            profile = profile,
        )

        // ── Steps (APPROXIMATE) ───────────────────────────────────────────────
        // step_motion_counter@57 is a CUMULATIVE u16 running counter. The daily total is the SUM of
        // positive consecutive deltas across the day's samples (already ts-ASC from the DAO). u16
        // wraparound: a negative delta means the counter rolled past 65535, so add 65536. The day's
        // ~42h read window may include adjacent-day samples, so filter to dayString(ts)==day first.
        // ESTIMATE only — not cloud/clinical parity.
        val stepsTotal: Int? = run {
            // Prefer the full-calendar-day stream for the additive total; fall back to the
            // night-window stream when the caller didn't supply one (pure-function callers/tests).
            val sorted = (daySteps ?: steps).filter { dayString(it.ts) == day }.sortedBy { it.ts }
            if (sorted.size < 2) return@run null
            // A firmware reboot resets the counter and is byte-indistinguishable from a u16 wrap.
            // A genuine wrap yields a SMALL corrected delta (the steps since the last record); a
            // reset-from-low yields a huge one. Cap each corrected delta so a reboot can't inject
            // tens of thousands of phantom steps (30k steps between two history records is
            // implausible for any reasonable sampling cadence). Heuristic — partial, since a reset
            // from a HIGH prior count still looks like a small wrap; tune once @57's cadence is
            // validated on hardware.
            val maxStepDelta = 30_000
            var total = 0L
            for (i in 1 until sorted.size) {
                var delta = sorted[i].counter - sorted[i - 1].counter
                if (delta < 0) delta += 65_536 // u16 wraparound
                if (delta in 1..maxStepDelta) total += delta // drop implausible deltas as resets
            }
            if (total > 0L) total.coerceAtMost(Int.MAX_VALUE.toLong()).toInt() else null
        }

        // ── Daily calories (APPROXIMATE, HR-only whole-day estimate) ──────────
        // Whole-day active+resting energy from the full HR window, using the same resting/active
        // per-second model the per-workout estimate uses (resting BMR below activeThreshold, Keytel
        // active above). effMaxHR + restingHRDaily are the same effective HRmax / resting baseline
        // strain uses. Null when there is no HR. A heart-rate ESTIMATE — not cloud/clinical parity.
        // Whole-day additive totals (steps above, calories here) are summed over the full UTC
        // calendar day supplied by the caller (dayHr / daySteps), NOT the ~42h sleep-detection
        // window — which, anchored to the current time-of-day, would drop a past day's late hours
        // and double-count seconds shared with adjacent days. Fall back to the night-window hr for
        // pure-function callers that don't supply dayHr. Strain keeps the full window (bounded log).
        val dayHrFiltered = (dayHr ?: hr).filter { dayString(it.ts) == day }
        val activeKcalEst: Double? = if (dayHrFiltered.isEmpty()) {
            null
        } else {
            Calories.estimateDayCalories(
                hrSamples = dayHrFiltered,
                profile = profile,
                hrmax = effMaxHR,
                restingHR = restingHRDaily?.toDouble(),
            )
        }

        // ── Assemble DailyMetric ──────────────────────────────────────────────
        // deviceId is stamped by the caller (IntelligenceEngine persists under
        // "<deviceId>-noop"); use the imported source id as a placeholder here so
        // the value type is complete. The caller copies with its computed id.
        val daily = DailyMetric(
            deviceId = "",
            day = day,
            totalSleepMin = if (matched.isEmpty()) null else tstS / 60.0,
            efficiency = if (matched.isEmpty()) null else efficiency,
            deepMin = if (matched.isEmpty()) null else deepS / 60.0,
            remMin = if (matched.isEmpty()) null else remS / 60.0,
            lightMin = if (matched.isEmpty()) null else lightS / 60.0,
            disturbances = if (matched.isEmpty()) null else disturbances,
            restingHr = restingHRDaily,
            avgHrv = avgHRVDaily,
            recovery = recovery,
            strain = strain,
            exerciseCount = workouts.size,
            spo2Pct = null,
            skinTempDevC = null,
            respRateBpm = respRateDaily,
            steps = stepsTotal,
            activeKcalEst = activeKcalEst,
        )

        return DayResult(
            daily = daily,
            sleepSessions = matched,
            workouts = workouts,
            recovery = recovery,
            strain = strain,
        )
    }
}
