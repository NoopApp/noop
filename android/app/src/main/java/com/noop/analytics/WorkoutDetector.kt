package com.noop.analytics

import com.noop.data.GravitySample
import com.noop.data.HrSample
import kotlin.math.abs
import kotlin.math.ceil
import kotlin.math.roundToLong
import kotlin.math.sqrt

/*
 * WorkoutDetector.kt — retroactive workout detection from the 1 Hz store.
 *
 * Faithful Kotlin port of StrandAnalytics/WorkoutDetector.swift (verified on macOS),
 * itself ported from server/ingest/app/analysis/exercise.py (+ activity.py, calories.py).
 *
 * A workout is a SUSTAINED window (≥ MIN_EXERCISE_MIN) of elevated HR (above
 * resting + HR_MARGIN_BPM) AND sustained motion (gravity-derived intensity above
 * MOTION_THRESHOLD). Both gates must hold for a sample to count as active.
 *
 * Per detected bout: avg/peak HR, duration, Edwards zone time-%, mean %HRR,
 * strain (StrainScorer), and estimated calories (Keytel 2005 active + revised
 * Harris–Benedict BMR resting, age/sex/weight/height adjusted).
 *
 * All intensity/energy outputs are APPROXIMATE and not medical advice.
 *
 * Types note: [UserProfile], [ExerciseSession] and [ActivityPoint] live in
 * AnalyticsModels.kt (shared value types) and are NOT redefined here. Inputs are
 * the Room entities com.noop.data.HrSample (ts:Long seconds, bpm:Int) and
 * com.noop.data.GravitySample (ts:Long seconds, x/y/z:Double). All `ts`/`start`/`end`
 * are unix SECONDS as Long. The Swift source used Int seconds.
 */
object WorkoutDetector {

    // ---- Constants (exercise.py) ----

    const val minExerciseMin: Double = 5.0
    const val hrMarginBPM: Double = 15.0
    const val motionThreshold: Double = 0.20
    const val motionSmoothS: Double = 10.0
    const val mergeGapS: Double = 150.0
    const val minIntensityZ2Plus: Double = 0.50
    const val alignToleranceS: Double = 5.0
    const val restingPercentile: Double = 10.0

    // ---- Activity series (activity.py) ----

    /**
     * Per-record motion-intensity series: L2 magnitude of the gravity change vs
     * the previous record. First row → 0. Empty input → []. (GravitySample always
     * carries finite x/y/z, so no dropout sentinel is required here.)
     */
    fun activitySeries(gravity: List<GravitySample>): List<ActivityPoint> {
        if (gravity.isEmpty()) return emptyList()
        val rows = gravity.sortedBy { it.ts }
        val series = ArrayList<ActivityPoint>(rows.size)
        var prev: GravitySample? = null
        for ((i, row) in rows.withIndex()) {
            val intensity: Double
            val p = prev
            if (i == 0) {
                intensity = 0.0
            } else if (p != null) {
                val dx = row.x - p.x
                val dy = row.y - p.y
                val dz = row.z - p.z
                intensity = sqrt(dx * dx + dy * dy + dz * dz)
            } else {
                intensity = 0.0
            }
            series.add(ActivityPoint(ts = row.ts, intensity = intensity))
            prev = row
        }
        return series
    }

    // ---- Helpers ----

    /**
     * Sorted (ts, bpm) pairs.
     *
     * Swift `cleanHR` mapped to `(ts: Int, bpm: Double)`; here the Room [HrSample]
     * already carries an Int bpm, so we keep the rows sorted by ts and read bpm as a
     * Double on demand — equivalent and avoids losing the deviceId needed downstream.
     */
    internal fun cleanHR(hr: List<HrSample>): List<HrSample> = hr.sortedBy { it.ts }

    /** Day resting-HR baseline = nearest-rank RESTING_PERCENTILE of bpm values. */
    internal fun deriveRestingHR(hrSeg: List<HrSample>): Double {
        val bpms = hrSeg.map { it.bpm.toDouble() }.sorted()
        require(bpms.isNotEmpty()) { "deriveRestingHR called with empty segment" }
        val rank = maxOf(1, ceil(restingPercentile / 100.0 * bpms.size.toDouble()).toInt())
        return bpms[rank - 1]
    }

    /**
     * Value whose ts is nearest to [ts] within [tol] seconds, else null. Ties go
     * to the later timestamp (matches the Python <= behaviour).
     */
    internal fun nearest(sortedTs: List<Long>, values: List<Double>, ts: Long, tol: Double): Double? {
        if (sortedTs.isEmpty()) return null
        // bisect_left
        var lo = 0
        var hi = sortedTs.size
        while (lo < hi) {
            val mid = (lo + hi) / 2
            if (sortedTs[mid] < ts) lo = mid + 1 else hi = mid
        }
        val i = lo
        var bestV: Double? = null
        var bestD = tol
        for (j in intArrayOf(i - 1, i)) {
            if (j in sortedTs.indices) {
                val d = abs((sortedTs[j] - ts).toDouble())
                if (d <= bestD) {
                    bestD = d
                    bestV = values[j]
                }
            }
        }
        return bestV
    }

    /** Trailing rolling mean (over window_s) of intensities (all finite here). */
    internal fun smoothedIntensity(motion: List<ActivityPoint>, windowS: Double): List<Double> {
        val ts = motion.map { it.ts }
        val raw = motion.map { if (it.intensity.isFinite()) it.intensity else 0.0 }
        val out = ArrayList<Double>(motion.size)
        var lo = 0
        var running = 0.0
        for (i in motion.indices) {
            running += raw[i]
            while ((ts[i] - ts[lo]).toDouble() > windowS) {
                running -= raw[lo]
                lo += 1
            }
            out.add(running / (i - lo + 1).toDouble())
        }
        return out
    }

    /** Per-bout Edwards zone breakdown (%) + mean %HRR. APPROXIMATE. */
    internal fun boutIntensity(
        hrSeries: List<HrSample>,
        restingHR: Double,
        maxHR: Double,
    ): Pair<Map<Int, Double>, Double?> {
        if (hrSeries.isEmpty() || maxHR <= restingHR) return emptyMap<Int, Double>() to null
        val hrReserve = maxHR - restingHR
        val zoneCounts = HashMap<Int, Int>()
        for (z in 0..5) zoneCounts[z] = 0
        val hrrVals = ArrayList<Double>(hrSeries.size)
        for (r in hrSeries) {
            val bpm = r.bpm.toDouble()
            val z = StrainScorer.zoneWeight(bpm, restingHR, hrReserve)
            zoneCounts[z] = (zoneCounts[z] ?: 0) + 1
            hrrVals.add(StrainScorer.pctHRR(bpm, restingHR, hrReserve))
        }
        val n = hrSeries.size.toDouble()
        val zonePct = HashMap<Int, Double>()
        for ((z, c) in zoneCounts) {
            zonePct[z] = round1(c.toDouble() / n * 100.0)
        }
        val avgHRR = round1(hrrVals.sum() / n)
        return zonePct to avgHRR
    }

    /** Round to one decimal place. All inputs here are non-negative (matches Swift `.rounded()`). */
    private fun round1(v: Double): Double = (v * 10).roundToLong() / 10.0

    // ---- Public API ----

    /**
     * Detect workouts from the 1 Hz HR + gravity store.
     *
     * @param hr heart-rate stream (required; empty → []).
     * @param gravity gravity stream (required; empty → []).
     * @param restingHR day resting-HR baseline (bpm). null → derived as the 10th
     *   percentile of the day's HR.
     * @param maxHR HRmax (bpm). null → estimated via StrainScorer.estimateHRmax.
     * @param age used only for the Tanaka fallback when maxHR is null.
     * @param profile when provided, per-bout calories are estimated.
     */
    fun detect(
        hr: List<HrSample>,
        gravity: List<GravitySample>,
        restingHR: Double? = null,
        maxHR: Double? = null,
        age: Double? = null,
        profile: UserProfile? = null,
    ): List<ExerciseSession> {
        val hrSeg = cleanHR(hr)
        val motion = activitySeries(gravity)
        if (hrSeg.isEmpty() || motion.isEmpty()) return emptyList()

        val restHR = restingHR ?: deriveRestingHR(hrSeg)
        val hrFloor = restHR + hrMarginBPM

        val effMaxHR: Double?
        val hrmaxSource: String
        if (maxHR != null) {
            effMaxHR = maxHR
            hrmaxSource = "caller"
        } else {
            val (est, src) = StrainScorer.estimateHRmax(hrSeg.map { it.bpm.toDouble() }, age)
            effMaxHR = if (est == 0.0) null else est
            hrmaxSource = src
        }

        val hrTs = hrSeg.map { it.ts }
        val hrBpm = hrSeg.map { it.bpm.toDouble() }
        val smooth = smoothedIntensity(motion, motionSmoothS)

        // Walk the gravity timeline; flag samples where BOTH gates hold.
        val activeTs = ArrayList<Long>()
        for (idx in motion.indices) {
            val p = motion[idx]
            val inten = smooth[idx]
            if (inten <= motionThreshold) continue
            val bpm = nearest(hrTs, hrBpm, p.ts, alignToleranceS) ?: continue
            if (bpm <= hrFloor) continue
            activeTs.add(p.ts)
        }
        if (activeTs.isEmpty()) return emptyList()

        // Group contiguous active samples into runs, merging gaps < MERGE_GAP_S.
        val runs = ArrayList<Pair<Long, Long>>()
        var runStart = activeTs[0]
        var prev = activeTs[0]
        for (k in 1 until activeTs.size) {
            val ts = activeTs[k]
            if ((ts - prev).toDouble() > mergeGapS) {
                runs.add(runStart to prev)
                runStart = ts
            }
            prev = ts
        }
        runs.add(runStart to prev)

        val minDurS = minExerciseMin * 60.0
        val sessions = ArrayList<ExerciseSession>()
        for ((start, end) in runs) {
            // Onset latency tolerance equal to the smoothing window.
            if ((end - start).toDouble() < minDurS - motionSmoothS) continue
            val window = hrSeg.filter { it.ts in start..end }
            if (window.isEmpty()) continue
            val bpms = window.map { it.bpm.toDouble() }

            var zonePct: Map<Int, Double> = emptyMap()
            var avgHRR: Double? = null
            val m = effMaxHR
            if (m != null && m > restHR) {
                val (zp, ah) = boutIntensity(window, restHR, m)
                zonePct = zp
                avgHRR = ah
            }

            // Intensity qualification: require ≥ MIN_INTENSITY_Z2PLUS in zone 2+.
            if (zonePct.isNotEmpty()) {
                val z2plus = (2..5).sumOf { zonePct[it] ?: 0.0 } / 100.0
                if (z2plus < minIntensityZ2Plus) continue
            }

            var kcal: Double? = null
            var kj: Double? = null
            if (profile != null) {
                val (k, j) = Calories.estimateBoutCalories(window, profile, effMaxHR, restHR)
                kcal = k
                kj = j
            }

            val avg = bpms.sum() / bpms.size.toDouble()
            val peak = window.maxOf { it.bpm }
            val strain = StrainScorer.strain(window, effMaxHR, restHR)

            sessions.add(
                ExerciseSession(
                    start = start,
                    end = end,
                    avgHR = avg,
                    peakHR = peak,
                    strain = strain,
                    durationS = (end - start).toDouble(),
                    zoneTimePct = zonePct,
                    avgHRRPct = avgHRR,
                    hrmax = effMaxHR,
                    hrmaxSource = hrmaxSource,
                    caloriesKcal = kcal,
                    caloriesKJ = kj,
                )
            )
        }
        return sessions
    }
}

/**
 * HR-based calorie estimation (Keytel 2005 active + revised Harris–Benedict BMR).
 * APPROXIMATE — not laboratory calorimetry, not medical advice.
 *
 * Faithful port of the `Calories` enum that ships inside WorkoutDetector.swift.
 */
object Calories {

    /** Sex-specific BMR + active-EE coefficients. Mirrors Swift `Calories.Coeffs`. */
    data class Coeffs(
        val restingAlpha: Double,
        val restingWeight: Double,
        /** Applied to height in METRES. */
        val restingHeight: Double,
        val restingAge: Double,
        val workoutHR: Double,
        val workoutWeight: Double,
        val workoutAge: Double,
        val workoutAlpha: Double,
    )

    val male = Coeffs(
        restingAlpha = 88.362, restingWeight = 13.397, restingHeight = 479.9,
        restingAge = 5.677, workoutHR = 0.6309, workoutWeight = 0.1988,
        workoutAge = 0.2017, workoutAlpha = -55.0969,
    )
    val female = Coeffs(
        restingAlpha = 447.593, restingWeight = 9.247, restingHeight = 309.8,
        restingAge = 4.33, workoutHR = 0.4472, workoutWeight = -0.1263,
        workoutAge = 0.0740, workoutAlpha = -20.4022,
    )
    val nonbinary = Coeffs(
        restingAlpha = 267.9775, restingWeight = 11.322, restingHeight = 394.85,
        restingAge = 5.0035, workoutHR = 0.53905, workoutWeight = 0.03625,
        workoutAge = 0.13785, workoutAlpha = -37.74955,
    )

    const val activeHRRFraction: Double = 0.30
    const val workoutDivisor: Double = 251.04 // 60 s/min × 4.184 kJ/kcal

    fun resolveCoeffs(sex: String): Coeffs = when (sex.lowercase()) {
        "male" -> male
        "female" -> female
        "nonbinary" -> nonbinary
        else -> nonbinary
    }

    fun restingKcalPerS(c: Coeffs, weightKg: Double, heightCm: Double, age: Double): Double {
        val heightM = heightCm / 100.0
        val bmr = c.restingAlpha + c.restingWeight * weightKg + c.restingHeight * heightM - c.restingAge * age
        return maxOf(0.0, bmr) / 86_400.0
    }

    fun activeKcalPerS(c: Coeffs, hr: Double, hrmax: Double, weightKg: Double, age: Double): Double {
        val eeKjMin = c.workoutHR * minOf(hr, hrmax) + c.workoutWeight * weightKg +
            c.workoutAge * age + c.workoutAlpha
        return maxOf(0.0, eeKjMin) / workoutDivisor
    }

    /**
     * Estimate (kcal, kJ) for a workout bout. Each HR sample = 1 second of data.
     *
     * @param hrSamples the bout's HR samples (one second each).
     * @param profile weight/height/age/sex for the BMR + active-EE coefficients.
     * @param hrmax effective HRmax (bpm); null → 220.
     * @param restingHR resting HR (bpm); null → 60.
     */
    fun estimateBoutCalories(
        hrSamples: List<HrSample>,
        profile: UserProfile,
        hrmax: Double?,
        restingHR: Double?,
    ): Pair<Double, Double> {
        val weightKg = if (profile.weightKg > 0) profile.weightKg else 70.0
        val heightCm = if (profile.heightCm > 0) profile.heightCm else 170.0
        val age = if (profile.age > 0) profile.age else 30.0
        val coeffs = resolveCoeffs(profile.sex)

        val effHRmax = hrmax ?: 220.0
        val effResting = restingHR ?: 60.0
        val activeThreshold = effResting + activeHRRFraction * (effHRmax - effResting)

        val restingRate = restingKcalPerS(coeffs, weightKg, heightCm, age)

        var totalKcal = 0.0
        for (s in hrSamples) {
            val bpm = s.bpm.toDouble()
            totalKcal += if (bpm < activeThreshold) {
                restingRate
            } else {
                activeKcalPerS(coeffs, bpm, effHRmax, weightKg, age)
            }
        }
        return totalKcal to (totalKcal * 4.184)
    }

    /**
     * APPROXIMATE whole-day total energy estimate (kcal) from the full day's HR
     * samples. Identical per-second model as [estimateBoutCalories]: below the
     * activeThreshold (resting + 30% HRR) a sample burns the resting BMR rate, above
     * it the Keytel active rate. Each HR sample = 1 second of data (1 Hz strap). This
     * is an on-device estimate from heart rate alone — NOT laboratory calorimetry,
     * NOT Apple/WHOOP cloud parity, NOT medical advice.
     *
     * @param hrSamples the whole day's HR samples (one second each).
     * @param profile weight/height/age/sex for the BMR + active-EE coefficients.
     * @param hrmax effective HRmax (bpm); null → 220.
     * @param restingHR resting HR (bpm); null → 60.
     * @return total estimated kcal for the day (>= 0).
     */
    fun estimateDayCalories(
        hrSamples: List<HrSample>,
        profile: UserProfile,
        hrmax: Double?,
        restingHR: Double?,
    ): Double {
        if (hrSamples.isEmpty()) return 0.0
        return estimateBoutCalories(hrSamples, profile, hrmax, restingHR).first
    }
}
