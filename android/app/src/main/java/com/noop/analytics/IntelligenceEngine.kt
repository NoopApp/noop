package com.noop.analytics

import com.noop.data.DailyMetric
import com.noop.data.SleepSession
import com.noop.data.WhoopRepository
import com.noop.data.WorkoutRow

/*
 * IntelligenceEngine.kt — on-device "intelligence": computes recovery / day-strain /
 * sleep from the raw strap streams using the same model shape WHOOP uses (HRV vs
 * personal baseline ~60%, resting HR ~20%, sleep ~15%, respiration ~5%; strain 0–21
 * from cardiovascular load).
 *
 * Faithful Kotlin port of Strand/Data/IntelligenceEngine.swift (verified on macOS).
 * Same windows, same thresholds, same persistence model:
 *   - For each recent day with >= MIN_HR_SAMPLES (200) HR samples, read a generous
 *     window of raw streams from the imported source ("my-whoop"), run
 *     AnalyticsEngine.analyzeDay against baselines folded from repo.days, and PERSIST
 *     the DailyMetric + sleep sessions under "<deviceId>-noop" (the computed source).
 *   - The repository merges these UNDER any imported "my-whoop" rows, so a real WHOOP
 *     import always wins; this only fills the days the strap collected but no import
 *     covered.
 *
 * This is what makes NOOP independent of WHOOP's cloud — for any day the strap
 * collected raw data with NOOP connected, NOOP scores it itself rather than relying on
 * the values WHOOP computed in the imported CSV.
 *
 * Stateless object (no ObservableObject equivalent here): the Compose layer observes
 * the repository's reactive day flow, so this engine just computes + persists, then the
 * caller (AppViewModel) lets the flow refresh the UI. All `ts` are unix SECONDS (Long).
 */
object IntelligenceEngine {

    /** Minimum HR samples in a day's window before it is worth scoring. */
    const val MIN_HR_SAMPLES: Int = 200

    /** Read cap per stream read — matches the Swift 200_000 bound. */
    const val STREAM_LIMIT: Int = 200_000

    private const val SECONDS_PER_DAY: Long = 86_400L

    /** Summary of one scored day (for logging / a future on-device intelligence screen). */
    data class Computed(
        val day: String,
        val recovery: Double?,
        val strain: Double?,
        val sleepMin: Double?,
        val hrv: Double?,
        val rhr: Int?,
    )

    /**
     * Compute on-device scores for each of the last [maxDays] that actually has raw HR
     * data, persisting them under the computed "<importedDeviceId>-noop" source.
     *
     * Personal baselines (HRV / resting HR) are folded from the imported nightly history
     * (via [WhoopRepository.days]), so even the first live night can be scored against
     * the user's norm.
     *
     * @param repo the local store.
     * @param profile body profile (age/sex/weight/height + HRmax override) for HRmax,
     *   zones, calories. Defaults to a neutral [UserProfile] when the caller has none.
     * @param maxDays number of trailing days to consider (default 21).
     * @param importedDeviceId the source id the raw strap data is stored under
     *   ("my-whoop"). Computed scores are written under "<importedDeviceId>-noop".
     * @param maxHROverride explicit HRmax (bpm); null → Tanaka from profile.age.
     * @param nowSeconds wall-clock now (unix seconds); injectable for tests/determinism.
     * @return the per-day [Computed] summaries (newest first), mirroring the Swift `out`.
     */
    suspend fun analyzeRecent(
        repo: WhoopRepository,
        profile: UserProfile = UserProfile(),
        maxDays: Int = 21,
        importedDeviceId: String = "my-whoop",
        maxHROverride: Double? = null,
        nowSeconds: Long = System.currentTimeMillis() / 1000L,
    ): List<Computed> {
        val hrvCfg = Baselines.metricCfg["hrv"] ?: return emptyList()
        val rhrCfg = Baselines.metricCfg["resting_hr"] ?: return emptyList()
        val skinCfg = Baselines.metricCfg["skin_temp"] ?: return emptyList()
        val respCfg = Baselines.metricCfg["resp"] ?: return emptyList()

        val computedId = importedDeviceId + "-noop"

        // Device wall-clock offset (seconds east of UTC) for the sleep detector's daytime
        // false-sleep guard (#90): the stager places each window's center on the LOCAL clock so
        // only genuinely-daytime windows face the stricter nap bar. getOffset(nowMillis) folds in
        // the current DST state (a DST boundary inside a single window is a negligible edge case
        // for an hour-of-day band). Computed once per run.
        val tzOffsetSeconds =
            java.util.TimeZone.getDefault().getOffset(nowSeconds * 1_000L) / 1_000L

        // ── Pass 1: detect + aggregate each offloaded night, scoring against the
        // imported-only baseline. For a BLE-only user repo.days(importedDeviceId) is
        // empty, so the HRV baseline is NOT usable and res.recovery is null here — but
        // the per-night avgHrv/restingHr are computed WITHOUT any baseline dependency
        // (SleepStager + AnalyticsEngine), so we harvest them to SEED the baseline and
        // re-score in pass 2. Collected oldest-first to match foldHistory's replay order.
        // foldHistory winsorizes outliers. days() is oldest-first (Swift ascending).
        val hist = repo.days(importedDeviceId)
        val hrvBase1 = Baselines.foldHistory(hist.map { it.avgHrv }, hrvCfg)
        val rhrBase1 = Baselines.foldHistory(hist.map { it.restingHr?.toDouble() }, rhrCfg)
        val baselines1 = ProfileBaselines(hrv = hrvBase1, restingHR = rhrBase1)

        // Keep each night's small DayResult (daily metrics + detected sessions), NOT the raw
        // streams: every field except recovery is baseline-independent, so pass 2 only re-scores
        // the cheap recovery composite. The raw hr/rr/... lists are freed after each analyzeDay,
        // keeping memory bounded over a full multi-night offload history.
        val scoredNights = ArrayList<DayResult>()

        // In-memory nightly values harvested in pass 1, used to seed the pass-2 baseline.
        // Keyed by day so the union with imported history de-dupes cleanly per UTC day.
        val nightlyHrvByDay = LinkedHashMap<String, Double?>()
        val nightlyRhrByDay = LinkedHashMap<String, Double?>()
        // Wear-gated nightly skin-temp means (on-device only — imported rows carry the deviation, not
        // the raw mean, so the skin-temp baseline is seeded purely from these). (PR #85)
        val nightlySkinByDay = LinkedHashMap<String, Double?>()
        // On-device RSA respiration estimates, unioned with imported respRateBpm below to seed the
        // resp baseline the recovery composite's wResp=0.05 term scores against.
        val nightlyRespByDay = LinkedHashMap<String, Double?>()

        for (offset in 0 until maxDays) {
            val dayStart = nowSeconds - offset * SECONDS_PER_DAY
            val day = AnalyticsEngine.dayString(dayStart)
            // Read a generous window around the night that ends on `day`; the stager finds
            // the span. (30 h before, 12 h after — matches the Swift window.)
            val from = dayStart - 30 * 3_600L
            val to = dayStart + 12 * 3_600L

            val hr = repo.hrSamples(importedDeviceId, from, to, STREAM_LIMIT)
            if (hr.size < MIN_HR_SAMPLES) continue // need real raw data, not a stray sample
            val rr = repo.rrIntervals(importedDeviceId, from, to, STREAM_LIMIT)
            val resp = repo.respSamples(importedDeviceId, from, to, STREAM_LIMIT)
            val grav = repo.gravitySamples(importedDeviceId, from, to, STREAM_LIMIT)
            val steps = repo.stepSamples(importedDeviceId, from, to, STREAM_LIMIT)
            val skin = repo.skinTempSamples(importedDeviceId, from, to, STREAM_LIMIT)

            // Calendar-day window for the ADDITIVE daily totals (steps + calories). The night window
            // above is anchored to the current UTC time-of-day and ends at dayStart+12h, so for a PAST
            // day whose late hours sit after that bound those hours are never read and the totals
            // undercount. Read exactly [midnightUtc(day), midnightUtc(day)+86400) and hand it to
            // analyzeDay's dayHr/daySteps, which use it ONLY for those totals. Same STREAM_LIMIT; the
            // MIN_HR_SAMPLES gate above stays on the night window so empty days are still skipped.
            // (the DAO range is inclusive, so end at +86400-1s; analyzeDay also filters to the day.)
            val dayMidnight = midnightUtc(dayStart)
            val dayEnd = dayMidnight + SECONDS_PER_DAY - 1
            val dayHr = repo.hrSamples(importedDeviceId, dayMidnight, dayEnd, STREAM_LIMIT)
            val daySteps = repo.stepSamples(importedDeviceId, dayMidnight, dayEnd, STREAM_LIMIT)

            val res = AnalyticsEngine.analyzeDay(
                day = day,
                hr = hr,
                rr = rr,
                resp = resp,
                gravity = grav,
                steps = steps,
                dayHr = dayHr,
                daySteps = daySteps,
                skinTemp = skin,
                profile = profile,
                baselines = baselines1,
                maxHROverride = maxHROverride,
                tzOffsetSeconds = tzOffsetSeconds,
            )

            // Harvest the baseline-independent nightly aggregates (a day with no detected
            // sleep yields null → recorded as a missing night, i.e. skip-and-hold). The raw
            // streams (hr/rr/...) go out of scope here and are freed before the next night.
            nightlyHrvByDay[day] = res.daily.avgHrv
            nightlyRhrByDay[day] = res.daily.restingHr?.toDouble()
            nightlySkinByDay[day] = res.nightlySkinTempC
            nightlyRespByDay[day] = res.daily.respRateBpm
            scoredNights.add(res)
        }

        // ── Seed the baseline from the UNION of imported nightly history + the nightly
        // values just computed. This is the recovery fix: the "-noop" nightly avgHrv/
        // restingHr that already exist (and are re-derived identically here) finally feed
        // the baseline, so a BLE-only user crosses Baselines.minNightsSeed (4 valid nights)
        // and recovery lights up. We fold over the in-memory pass-1 values rather than
        // re-reading repo.days(computedId) to avoid a read-before-persist ordering hazard.
        // Chronological (oldest-first) replay: a day present in both takes the computed value.
        val histHrvByDay = LinkedHashMap<String, Double?>()
        val histRhrByDay = LinkedHashMap<String, Double?>()
        val histRespByDay = LinkedHashMap<String, Double?>()
        for (d in hist) {
            histHrvByDay[d.day] = d.avgHrv
            histRhrByDay[d.day] = d.restingHr?.toDouble()
            histRespByDay[d.day] = d.respRateBpm
        }
        // Imported (cloud) nightly values WIN per day (putIfAbsent): the on-device estimate
        // only fills days the import doesn't cover, so an import user's baseline is unchanged.
        for ((day, v) in nightlyHrvByDay) histHrvByDay.putIfAbsent(day, v)
        for ((day, v) in nightlyRhrByDay) histRhrByDay.putIfAbsent(day, v)
        // NOT putIfAbsent for resp: Java's putIfAbsent treats a key mapped to NULL as absent, so
        // an imported day whose respRateBpm is blank would be replaced by the RSA estimate —
        // diverging from the Swift mirror (key-absence check), which keeps the imported day as a
        // missing night. Match Swift: only fill days the import does not cover AT ALL.
        for ((day, v) in nightlyRespByDay) if (day !in histRespByDay) histRespByDay[day] = v
        val hrvSeq = histHrvByDay.entries.sortedBy { it.key }.map { it.value }
        val rhrSeq = histRhrByDay.entries.sortedBy { it.key }.map { it.value }
        val respSeq = histRespByDay.entries.sortedBy { it.key }.map { it.value }
        val hrvBase2 = Baselines.foldHistory(hrvSeq, hrvCfg)
        val rhrBase2 = Baselines.foldHistory(rhrSeq, rhrCfg)
        // Resp baseline mixes imported (cloud) values with on-device RSA estimates — acceptable: the
        // z-score is scale-tolerant, foldHistory winsorizes, and respRateBpm already carries no source
        // flag anywhere else (the illness gate treats it the same way). Gated on `usable` because
        // RecoveryScorer includes the resp term whenever a baseline object is present — a CALIBRATING
        // (<4-night) baseline would let one noisy RSA night move recovery (mirrors the skin-temp
        // use-site gate; honest cold-start).
        val respBase2 = Baselines.foldHistory(respSeq, respCfg).takeIf { it.usable }
        // Skin-temp baseline is on-device-only (imported rows carry skinTempDevC, not the raw mean),
        // so fold purely over the pass-1 nightly means in chronological order. (PR #85)
        val skinSeq = nightlySkinByDay.entries.sortedBy { it.key }.map { it.value }
        val skinBase2 = Baselines.foldHistory(skinSeq, skinCfg)
        val baselines2 = ProfileBaselines(
            hrv = hrvBase2, restingHR = rhrBase2, resp = respBase2, skinTemp = skinBase2,
        )

        // Real (non-detected) workouts in the scored window, used to de-duplicate detected bouts so a
        // user who BOTH has real sessions AND wears the strap doesn't see the same session twice (the
        // per-day mergeDaily precedence does not cover the workout table). Covers BOTH directions of
        // the cross-source duplicate (#107): the strap source carries imported WHOOP rows AND manual /
        // re-labelled rows (both under [importedDeviceId]); apple-health / health-connect carry Health
        // imports — a detected bout overlapping ANY of them is skipped below.
        val windowStart = nowSeconds - maxDays.toLong() * SECONDS_PER_DAY - 30 * 3_600L
        val realWorkouts = repo.workouts(importedDeviceId, windowStart, nowSeconds) +
            repo.workouts("apple-health", windowStart, nowSeconds) +
            repo.workouts("health-connect", windowStart, nowSeconds)

        // ── Pass 2: re-score every offloaded night against the now-seeded baseline. Only the
        // recovery composite is recomputed (cheap, baseline-dependent); every other field was
        // already computed in pass 1 and is baseline-independent, so the heavy sleep / strain /
        // workout / RSA analysis runs ONCE per night. recovery stays null until the HRV
        // baseline is usable (>= minNightsSeed valid nights) — honest cold-start.
        val out = ArrayList<Computed>()
        val dailies = ArrayList<DailyMetric>()
        val sleepRows = ArrayList<SleepSession>()
        val workoutRows = ArrayList<WorkoutRow>()

        for (res in scoredNights) {
            val recovery = recomputeRecovery(res.daily, baselines2)
            val skinTempDevC = recomputeSkinTempDev(res.nightlySkinTempC, baselines2.skinTemp)

            out.add(
                Computed(
                    day = res.daily.day,
                    recovery = recovery,
                    strain = res.daily.strain,
                    sleepMin = res.daily.totalSleepMin,
                    hrv = res.daily.avgHrv,
                    rhr = res.daily.restingHr,
                ),
            )
            // Stamp the computed source id + the re-scored recovery & skin-temp deviation onto the row.
            dailies.add(res.daily.copy(deviceId = computedId, recovery = recovery, skinTempDevC = skinTempDevC))
            // Map the rich DetectedSleep sessions → Room SleepSession cache rows.
            for (s in res.sleepSessions) {
                sleepRows.add(
                    SleepSession(
                        deviceId = computedId,
                        startTs = s.start,
                        endTs = s.end,
                        efficiency = s.efficiency,
                        restingHr = s.restingHR,
                        avgHrv = s.avgHRV,
                        stagesJSON = AnalyticsEngine.encodeStages(s.stages),
                    ),
                )
            }
            // Persist the detected workouts the pipeline already computes (previously discarded).
            // Skip any bout overlapping a real imported workout so import+wear users don't
            // double-count. sport="detected"; energyKcal is the APPROXIMATE Keytel/BMR total.
            for (s in res.workouts) {
                if (realWorkouts.any { w -> s.start < w.endTs && w.startTs < s.end }) continue
                workoutRows.add(
                    WorkoutRow(
                        deviceId = computedId,
                        startTs = s.start,
                        endTs = s.end,
                        sport = "detected",
                        source = computedId,
                        durationS = s.durationS,
                        energyKcal = s.caloriesKcal,
                        avgHr = s.avgHR.toInt(),
                        maxHr = s.peakHR,
                        strain = s.strain,
                    ),
                )
            }
        }

        // Persist the computed scores under the dedicated "-noop" source so the WHOLE
        // dashboard (Today / Recovery / Strain / Sleep / Trends) reads them. The repository
        // merges these UNDER any imported "my-whoop" rows, so a real WHOOP import always wins;
        // this only fills the days the strap collected but no import covered.
        if (dailies.isNotEmpty()) repo.upsertDailyMetrics(dailies)
        if (sleepRows.isNotEmpty()) repo.upsertSleepSessions(sleepRows)
        // Make re-detection idempotent across runs: clear the prior computed detected workouts
        // in the scored window (a bout's startTs can drift as more HR arrives, which would
        // otherwise orphan stale rows under the (deviceId,startTs,sport) key), then re-insert.
        repo.deleteComputedWorkouts(computedId, "detected", windowStart, nowSeconds)
        if (workoutRows.isNotEmpty()) repo.upsertWorkouts(workoutRows)

        return out
    }

    /**
     * Recompute ONLY the recovery composite for an already-analyzed day against a (possibly
     * freshly-seeded) baseline. Inputs are the baseline-independent values already on [daily]
     * (avgHrv / restingHr / efficiency == sleepPerf), so pass 2 avoids re-running the expensive
     * sleep / strain / workout / RSA pipeline. Mirrors the recovery gate in
     * AnalyticsEngine.analyzeDay exactly (null on missing HRV/RHR or an unusable HRV baseline).
     */
    private fun recomputeRecovery(daily: DailyMetric, baselines: ProfileBaselines): Double? {
        val hrvVal = daily.avgHrv ?: return null
        val rhrVal = daily.restingHr ?: return null
        val hrvBase = baselines.hrv ?: return null
        return RecoveryScorer.recovery(
            hrv = hrvVal,
            rhr = rhrVal.toDouble(),
            resp = daily.respRateBpm, // term drops + renormalizes when null / no usable baseline
            hrvBaseline = hrvBase,
            rhrBaseline = baselines.restingHR,
            respBaseline = baselines.resp,
            sleepPerf = daily.efficiency,
        )
    }

    /**
     * Re-derive the skin-temperature deviation (°C) for a night against the freshly-seeded personal
     * baseline, mirroring the avgHrv→recovery re-score. Null when the night had no wear-gated mean or
     * the skin-temp baseline isn't usable yet (< minNightsSeed) — honest cold-start. Rounded to 2 dp
     * to match the imported/demo precision. APPROXIMATE. (PR #85)
     */
    private fun recomputeSkinTempDev(nightly: Double?, base: BaselineState?): Double? {
        val v = nightly ?: return null
        val b = base?.takeIf { it.usable } ?: return null
        return Math.round(Baselines.deviation(v, b).delta * 100.0) / 100.0
    }

    /**
     * Floor a unix-seconds timestamp to 00:00:00 of its UTC calendar day. AnalyticsEngine.dayString
     * uses UTC, so UTC midnight = ts - floorMod(ts, 86400). floorMod is correct for any sign.
     */
    internal fun midnightUtc(ts: Long): Long = ts - Math.floorMod(ts, SECONDS_PER_DAY)
}
