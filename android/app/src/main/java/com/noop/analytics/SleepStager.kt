package com.noop.analytics

import com.noop.data.GravitySample
import com.noop.data.HrSample
import com.noop.data.RespSample
import com.noop.data.RrInterval
import kotlin.math.abs
import kotlin.math.ceil
import kotlin.math.exp
import kotlin.math.pow
import kotlin.math.roundToInt
import kotlin.math.roundToLong
import kotlin.math.sqrt

/*
 * SleepStager.kt — sleep/wake detection + APPROXIMATE 4-class staging.
 *
 * Faithful Kotlin port of StrandAnalytics/SleepStager.swift (verified on macOS),
 * itself ported from server/ingest/app/analysis/sleep.py and sleep_features.py.
 *
 * HONEST HEDGING: these stages are APPROXIMATIONS, not PSG-validated, not medical
 * advice. The EEG-free 4-class ceiling is ~65–73% epoch agreement (Walch 2019).
 * Light/deep separation is the weakest link — deep-minute estimates are the least
 * reliable output.
 *
 * Pipeline (30 s epochs):
 *   Stage 0  gravity-stillness sleep/wake spine → in-bed sessions. Cole–Kripke
 *            (te Lindert 30 s) computed as a citable cross-check; HR confirms runs.
 *   Stage 1  per-epoch cardiorespiratory features over a rolling 5-min window
 *            (mean HR, DoG-HR variability, RMSSD/SDNN from RR, resp rate + RRV).
 *   Stage 2  transparent percentile-band classifier → {wake, light, deep, rem}.
 *   Stage 3  median smoothing + physiology re-imposition (no early REM, deep in
 *            the first third of the night).
 *
 * NOTE: frequency-domain HRV features (HF, LF/HF) are omitted (no neurokit2/scipy
 * on-device); the parasympathetic-tone signal is RMSSD only. Respiration rate +
 * RRV are derived from the raw 1 Hz resp channel with a simple peak detector. The
 * classifier seam, percentile bands, smoothing, and physiology rules are
 * reproduced exactly.
 *
 * Types:
 *   - The detected-sleep type is [DetectedSleep] (AnalyticsModels.kt), NOT a Room
 *     entity. Stage segments are [StageSegment] (AnalyticsModels.kt, fields var).
 *   - [HypnogramMetrics] (AnalyticsModels.kt) is returned by [hypnogramMetrics].
 *
 * All `ts` / `start` / `end` are wall-clock unix SECONDS (Long); the Swift source
 * uses Int seconds. Math is done in Double throughout, matching the Swift port.
 */
object SleepStager {

    // ── Stage 0 constants (sleep.py) ─────────────────────────────────────────

    /** Per-sample gravity change (g) at/below which a sample is "still". */
    const val gravityStillThresholdG: Double = 0.01

    /** Rolling stillness window (minutes). */
    const val stillWindowMin: Int = 15

    /** Fraction of still samples to call the window-center "sleep". */
    const val stillFraction: Double = 0.70

    /** Data gap (minutes) that always breaks a run. */
    const val maxGapMin: Int = 20

    /** Runs shorter than this (minutes) are absorbed into neighbours. */
    const val mergeMin: Int = 15

    /** A sleep run must exceed this (minutes) to count as a session. */
    const val minSleepMin: Int = 60

    /** Assumed sample interval (seconds) when not inferable. */
    const val defaultIntervalS: Double = 60.0

    /** Floor on the rolling-window size in samples. */
    const val minWindowSamples: Int = 3

    /** A run is HR-confirmed only if mean HR ≤ baseline × this. */
    const val hrSleepBaselineMult: Double = 1.05

    /** Skip HR refinement (trust gravity) when fewer than this many HR samples. */
    const val hrRefineMinSamples: Int = 30

    /** Consecutive sleep epochs required to declare onset. */
    const val onsetPersistEpochs: Int = 3

    // ── Stage 1–3 constants (sleep_features.py) ──────────────────────────────

    const val epochS: Double = 30.0
    const val featureWindowS: Double = 5 * 60.0
    const val ckCountDivisor: Double = 100.0
    const val ckCountClip: Double = 300.0
    const val moveDeltaThresholdG: Double = 0.01
    const val hrDogSigma1S: Double = 120.0
    const val hrDogSigma2S: Double = 600.0

    const val stageHRLowPct: Double = 25.0
    const val stageHRHighPct: Double = 70.0
    const val stageHRVHighPct: Double = 70.0
    const val stageHRVarHighPct: Double = 65.0
    const val stageRRVHighPct: Double = 65.0
    const val stageRRVLowPct: Double = 50.0
    const val stageWakeMoveFrac: Double = 0.15
    const val stageStillMoveFrac: Double = 0.10

    const val smoothEpochs: Int = 5
    const val noREMAfterOnsetMin: Double = 15.0
    const val deepFirstFraction: Double = 1.0 / 3.0

    /** te Lindert 30 s Cole–Kripke weights [A₋₄..A₊₂]. SI = 0.001·Σ wᵢ·Aᵢ; sleep iff SI<1. */
    val ckWeights: List<Double> = listOf(106.0, 54.0, 58.0, 76.0, 230.0, 74.0, 67.0)
    const val ckScale: Double = 0.001
    const val ckBack: Int = 4
    const val ckFwd: Int = 2

    // ── Gravity deltas ───────────────────────────────────────────────────────

    /**
     * Per-record movement proxy = L2 magnitude of the gravity change vs the
     * previous record. First record → 0. (No dropout sentinel needed: GravitySample
     * always carries finite x/y/z.)
     */
    internal fun gravityDeltas(grav: List<GravitySample>): List<Double> {
        val deltas = ArrayList<Double>(grav.size)
        var prev: GravitySample? = null
        for ((i, r) in grav.withIndex()) {
            if (i == 0) {
                deltas.add(0.0)
            } else {
                val p = prev
                if (p != null) {
                    val dx = p.x - r.x
                    val dy = p.y - r.y
                    val dz = p.z - r.z
                    deltas.add(sqrt(dx * dx + dy * dy + dz * dz))
                } else {
                    deltas.add(0.0)
                }
            }
            prev = r
        }
        return deltas
    }

    /** Median spacing between consecutive timestamps, restricted to (0, 300 s). */
    internal fun medianIntervalS(times: List<Long>): Double {
        if (times.size < 2) return defaultIntervalS
        val gaps = ArrayList<Double>(times.size)
        for (i in 0 until times.size - 1) {
            val g = (times[i + 1] - times[i]).toDouble()
            if (g > 0 && g < 300) gaps.add(g)
        }
        if (gaps.isEmpty()) return defaultIntervalS
        gaps.sort()
        return maxOf(gaps[gaps.size / 2], 1.0)
    }

    internal fun windowSize(times: List<Long>): Int {
        val interval = medianIntervalS(times)
        return maxOf(minWindowSamples, (stillWindowMin * 60 / interval).toInt())
    }

    /** Per-record sleep flags from a rolling fraction of "still" samples. */
    internal fun classifyStill(grav: List<GravitySample>, deltas: List<Double>): List<Boolean> {
        val n = grav.size
        if (n < 2) return List(n) { false }
        val half = windowSize(grav.map { it.ts }) / 2
        val flags = ArrayList<Boolean>(n)
        for (i in 0 until n) {
            val lo = maxOf(0, i - half)
            val hi = minOf(n, i + half + 1)
            var stillCount = 0
            for (j in lo until hi) {
                if (deltas[j] < gravityStillThresholdG) stillCount += 1
            }
            flags.add(stillCount.toDouble() / (hi - lo).toDouble() >= stillFraction)
        }
        return flags
    }

    /** A contiguous sleep/active run. `stage` ∈ {"sleep", "active"}. */
    internal data class Period(val stage: String, val start: Long, val end: Long)

    /**
     * Collapse per-record flags into contiguous runs, breaking on class change
     * or a gap > maxGapMin minutes.
     */
    internal fun buildRuns(grav: List<GravitySample>, flags: List<Boolean>): List<Period> {
        val n = grav.size
        if (n == 0) return emptyList()
        val times = grav.map { it.ts }
        val maxGapS = (maxGapMin * 60).toLong()
        val periods = ArrayList<Period>()
        var runStart = 0
        for (i in 1..n) {
            val atEnd = (i == n)
            val close: Boolean
            if (atEnd) {
                close = true
            } else {
                val classChanged = flags[i] != flags[runStart]
                val gapExceeded = (times[i] - times[i - 1]) > maxGapS
                close = classChanged || gapExceeded
            }
            if (close) {
                periods.add(
                    Period(
                        stage = if (flags[runStart]) "sleep" else "active",
                        start = times[runStart],
                        end = times[i - 1],
                    )
                )
                runStart = i
            }
        }
        return periods
    }

    /** Absorb runs shorter than mergeMin minutes into their neighbours. */
    internal fun mergePeriods(periods: List<Period>, mergeMinutes: Int = mergeMin): List<Period> {
        if (periods.isEmpty()) return emptyList()
        val pending = periods.toMutableList()
        val thresholdS = (mergeMinutes * 60).toLong()
        val merged = ArrayList<Period>()
        var i = 0
        while (i < pending.size) {
            val current = pending[i]
            val tooShort = (current.end - current.start) < thresholdS
            if (!tooShort) {
                merged.add(current)
                i += 1
                continue
            }

            val hasPrev = i > 0 && merged.isNotEmpty()
            val hasNext = i + 1 < pending.size
            val bridgesSame = hasPrev && hasNext && pending[i - 1].stage == pending[i + 1].stage

            if (bridgesSame) {
                val prev = merged.removeAt(merged.size - 1)
                merged.add(Period(stage = prev.stage, start = prev.start, end = pending[i + 1].end))
                i += 2
            } else if (hasNext) {
                pending[i + 1] = Period(
                    stage = pending[i + 1].stage,
                    start = current.start,
                    end = pending[i + 1].end,
                )
                i += 1
            } else if (hasPrev) {
                val prev = merged.removeAt(merged.size - 1)
                merged.add(Period(stage = prev.stage, start = prev.start, end = current.end))
                i += 1
            } else {
                i += 1
            }
        }
        return merged
    }

    // ── HR refinement ────────────────────────────────────────────────────────

    private inline fun <T> rowsBetween(rows: List<T>, start: Long, end: Long, ts: (T) -> Long): List<T> =
        rows.filter { ts(it) in start..end }

    /** Day HR baseline = median bpm over all HR samples; null if none. */
    internal fun hrBaseline(hr: List<HrSample>): Double? {
        val vals = hr.map { it.bpm.toDouble() }
        if (vals.isEmpty()) return null
        return HrvAnalyzer.median(vals)
    }

    internal fun confirmSleepWithHR(p: Period, hr: List<HrSample>, baseline: Double?): Boolean {
        if (baseline == null) return true
        val seg = rowsBetween(hr, p.start, p.end) { it.ts }
        if (seg.size < hrRefineMinSamples) return true
        val meanHR = seg.sumOf { it.bpm }.toDouble() / seg.size.toDouble()
        return meanHR <= baseline * hrSleepBaselineMult
    }

    // ── detectSleep (public) ──────────────────────────────────────────────────

    /**
     * Detect sleep sessions from biometric streams. Empty/absent gravity → [].
     * Gravity-only input degrades gracefully (HR/RR/resp refinements skipped).
     */
    fun detectSleep(
        hr: List<HrSample> = emptyList(),
        rr: List<RrInterval> = emptyList(),
        resp: List<RespSample> = emptyList(),
        gravity: List<GravitySample>,
    ): List<DetectedSleep> {
        val grav = gravity.sortedBy { it.ts }
        if (grav.size < 2) return emptyList()

        val hrS = hr.sortedBy { it.ts }
        val rrS = rr.sortedBy { it.ts }
        val respS = resp.sortedBy { it.ts }

        val deltas = gravityDeltas(grav)
        val flags = classifyStill(grav, deltas)
        var runs = buildRuns(grav, flags)
        runs = mergePeriods(runs)

        val baseline = hrBaseline(hrS)
        val minSleepS = (minSleepMin * 60).toLong()

        val sessions = ArrayList<DetectedSleep>()
        for (p in runs) {
            if (p.stage != "sleep") continue
            if ((p.end - p.start) <= minSleepS) continue
            if (!confirmSleepWithHR(p, hrS, baseline)) continue
            val stages = stageSession(start = p.start, end = p.end, grav = grav,
                hr = hrS, rr = rrS, resp = respS)
            val eff = efficiency(start = p.start, end = p.end, stages = stages)
            val resting = sessionRestingHR(start = p.start, end = p.end, hr = hrS)
            val avgHrv = sessionAvgHRV(start = p.start, end = p.end, rr = rrS)
            sessions.add(
                DetectedSleep(
                    start = p.start, end = p.end, efficiency = eff,
                    stages = stages, restingHR = resting, avgHRV = avgHrv,
                )
            )
        }
        sessions.sortBy { it.start }
        return sessions
    }

    /** asleep / in-bed in [0, 1]; asleep = in-bed − wake. */
    internal fun efficiency(start: Long, end: Long, stages: List<StageSegment>): Double {
        val inBed = (end - start).toDouble()
        if (inBed <= 0) return 0.0
        val wake = stages.filter { it.stage == "wake" }.sumOf { (it.end - it.start).toDouble() }
        val asleep = maxOf(0.0, inBed - wake)
        return minOf(1.0, asleep / inBed)
    }

    // ── Stage 1–3: staging over a 30 s epoch grid ────────────────────────────

    /** First persistent-sleep epoch (onset) and last sleep epoch (final wake). */
    internal fun onsetAndFinalWake(ckFlags: List<Boolean>): Pair<Int, Int> {
        val n = ckFlags.size
        if (n == 0) return Pair(0, 0)
        var onset: Int? = null
        var run = 0
        for ((i, s) in ckFlags.withIndex()) {
            run = if (s) run + 1 else 0
            if (run >= onsetPersistEpochs) {
                onset = i - onsetPersistEpochs + 1
                break
            }
        }
        var final: Int? = null
        for (i in n - 1 downTo 0) {
            if (ckFlags[i]) {
                final = i
                break
            }
        }
        val o = onset ?: 0
        var f = final ?: (n - 1)
        if (f < o) f = n - 1
        return Pair(o, f)
    }

    /** Build a 30 s hypnogram for [start, end] and return StageSegments. */
    internal fun stageSession(
        start: Long, end: Long, grav: List<GravitySample>,
        hr: List<HrSample>, rr: List<RrInterval>, resp: List<RespSample>,
    ): List<StageSegment> {
        val gSeg = rowsBetween(grav, start, end) { it.ts }
        if (gSeg.size < 2) return listOf(StageSegment(start = start, end = end, stage = "light"))

        val gDeltas = gravityDeltas(gSeg)
        val gTimes = gSeg.map { it.ts }

        val hrSeg = rowsBetween(hr, start, end) { it.ts }
        val rrSeg = rowsBetween(rr, start, end) { it.ts }
        val respSeg = rowsBetween(resp, start, end) { it.ts }

        val grid = buildEpochGrid(
            start = start.toDouble(), end = end.toDouble(),
            gravTimes = gTimes, gravDeltas = gDeltas,
            hr = hrSeg, rr = rrSeg, resp = respSeg,
        )
        if (grid.nEpochs == 0) return listOf(StageSegment(start = start, end = end, stage = "light"))

        val rescaled = rescaleCounts(grid.counts)
        val ckFlags = coleKripke(rescaled)
        val (onsetIdx, finalWakeIdx) = onsetAndFinalWake(ckFlags)

        val dogHR = dogHRVariability(grid.hr)
        val feats = extractFeatures(grid = grid, ckFlags = ckFlags, dogHR = dogHR,
            onsetIdx = onsetIdx, finalWakeIdx = finalWakeIdx)

        var labels = classifyEpochs(feats)
        labels = smoothLabels(labels)
        labels = reimposePhysiology(labels, features = feats,
            onsetIdx = onsetIdx, finalWakeIdx = finalWakeIdx)

        // Pre-onset and post-final-wake epochs are not sleep → force wake.
        val mutLabels = labels.toMutableList()
        for (i in mutLabels.indices) {
            if (i < onsetIdx || i > finalWakeIdx) mutLabels[i] = "wake"
        }

        // Merge consecutive same-stage epochs into segments tiling [start, end].
        val segments = ArrayList<StageSegment>()
        for ((i, stage) in mutLabels.withIndex()) {
            val segStart = grid.edges[i].roundToLong()
            val segEnd = grid.edges[i + 1].roundToLong()
            val last = segments.lastOrNull()
            if (last != null && last.stage == stage) {
                segments[segments.size - 1].end = segEnd
            } else {
                segments.add(StageSegment(start = segStart, end = segEnd, stage = stage))
            }
        }
        if (segments.isNotEmpty()) segments[segments.size - 1].end = end
        return segments
    }

    // ── Epoch grid ────────────────────────────────────────────────────────────

    internal class EpochGrid(
        val start: Double,
        val end: Double,
        val edges: List<Double>,
        /** per-epoch summed |Δgravity| (raw, pre-rescale). */
        val counts: List<Double>,
        /** scale-robust per-epoch moving-sample fraction. */
        val moveFrac: List<Double>,
        /** per-epoch mean HR (bpm) or NaN. */
        val hr: List<Double>,
        /** per-epoch RR intervals (ms). */
        val rr: List<List<Double>>,
        /** per-epoch raw respiration samples. */
        val resp: List<List<Double>>,
    ) {
        val nEpochs: Int get() = counts.size
        fun epochMid(i: Int): Double = edges[i] + epochS / 2.0
    }

    internal fun buildEpochGrid(
        start: Double, end: Double,
        gravTimes: List<Long>, gravDeltas: List<Double>,
        hr: List<HrSample>, rr: List<RrInterval>, resp: List<RespSample>,
    ): EpochGrid {
        if (end <= start) {
            return EpochGrid(
                start = start, end = end, edges = listOf(start), counts = emptyList(),
                moveFrac = emptyList(), hr = emptyList(), rr = emptyList(), resp = emptyList(),
            )
        }
        val nEpochs = maxOf(1, ceil((end - start) / epochS).toInt())
        val edges = DoubleArray(nEpochs + 1) { start + it.toDouble() * epochS }
        edges[nEpochs] = maxOf(edges[nEpochs], end)

        val counts = DoubleArray(nEpochs)
        val moveN = IntArray(nEpochs)
        val gravN = IntArray(nEpochs)
        val hrSum = DoubleArray(nEpochs)
        val hrCnt = IntArray(nEpochs)
        val rrBuckets = Array(nEpochs) { ArrayList<Double>() }
        val respBuckets = Array(nEpochs) { ArrayList<Double>() }

        fun idx(ts: Double): Int? {
            if (ts < start || ts >= end) {
                if (ts == end) return nEpochs - 1
                return null
            }
            val i = ((ts - start) / epochS).toInt()
            return minOf(i, nEpochs - 1)
        }

        for (k in gravTimes.indices) {
            val i = idx(gravTimes[k].toDouble()) ?: continue
            counts[i] += gravDeltas[k]
            gravN[i] += 1
            if (gravDeltas[k] >= moveDeltaThresholdG) moveN[i] += 1
        }
        for (r in hr) {
            val i = idx(r.ts.toDouble()) ?: continue
            hrSum[i] += r.bpm.toDouble()
            hrCnt[i] += 1
        }
        for (r in rr) {
            val i = idx(r.ts.toDouble()) ?: continue
            rrBuckets[i].add(r.rrMs.toDouble())
        }
        for (r in resp) {
            val i = idx(r.ts.toDouble()) ?: continue
            respBuckets[i].add(r.raw.toDouble())
        }

        val hrMean = List(nEpochs) { if (hrCnt[it] > 0) hrSum[it] / hrCnt[it].toDouble() else Double.NaN }
        // No gravity coverage → 1.0 (treat as moving; conservative).
        val moveFrac = List(nEpochs) { if (gravN[it] > 0) moveN[it].toDouble() / gravN[it].toDouble() else 1.0 }

        return EpochGrid(
            start = start, end = end, edges = edges.toList(), counts = counts.toList(),
            moveFrac = moveFrac, hr = hrMean,
            rr = rrBuckets.map { it.toList() }, resp = respBuckets.map { it.toList() },
        )
    }

    // ── Cole–Kripke ────────────────────────────────────────────────────────────

    internal fun rescaleCounts(counts: List<Double>): List<Double> =
        counts.map { minOf(it / ckCountDivisor, ckCountClip) }

    internal fun coleKripke(rescaled: List<Double>): List<Boolean> {
        val n = rescaled.size
        val flags = ArrayList<Boolean>(n)
        for (i in 0 until n) {
            var si = 0.0
            for ((k, w) in ckWeights.withIndex()) {
                val j = i - ckBack + k
                val a = if (j in 0 until n) rescaled[j] else 0.0
                si += w * a
            }
            si *= ckScale
            flags.add(si < 1.0)
        }
        return flags
    }

    // ── Walch difference-of-Gaussians HR variability ─────────────────────────

    internal fun gaussianKernel(sigmaS: Double, dtS: Double = epochS): List<Double> {
        val sigma = maxOf(sigmaS / dtS, 1e-6) // σ in epochs
        val radius = maxOf(1, ceil(3 * sigma).toInt())
        val k = ArrayList<Double>(2 * radius + 1)
        for (x in -radius..radius) {
            k.add(exp(-0.5 * (x.toDouble() / sigma).pow(2)))
        }
        val sum = k.sum()
        return k.map { it / sum }
    }

    /** Same-length convolution with reflect padding (edge-stable). */
    internal fun convolveReflect(x: List<Double>, kernel: List<Double>): List<Double> {
        val r = kernel.size / 2
        if (r == 0 || x.isEmpty()) return x
        // Reflect padding: numpy 'reflect' mirrors WITHOUT repeating the edge sample.
        val padded = ArrayList<Double>(x.size + 2 * r)
        for (i in 0 until r) padded.add(x[r - i]) // x[r], x[r-1], ... x[1]
        padded.addAll(x)
        for (i in 0 until r) padded.add(x[x.size - 2 - i]) // x[n-2], x[n-3], ...
        // Valid convolution, then take the first x.count outputs.
        val out = ArrayList<Double>(x.size)
        val m = kernel.size
        // np.convolve(padded, kernel, 'valid') has length padded.count - m + 1.
        for (i in 0..(padded.size - m)) {
            var acc = 0.0
            for (j in 0 until m) acc += padded[i + j] * kernel[m - 1 - j]
            out.add(acc)
            if (out.size == x.size) break
        }
        return out
    }

    /**
     * DoG-filtered HR (σ1=120 s minus σ2=600 s). NaNs linearly interpolated first;
     * all-NaN → zeros.
     */
    internal fun dogHRVariability(hrPerEpoch: List<Double>): List<Double> {
        val n = hrPerEpoch.size
        if (n == 0) return emptyList()
        val maskIdx = (0 until n).filter { !hrPerEpoch[it].isNaN() }
        if (maskIdx.isEmpty()) return List(n) { 0.0 }

        // Linear interpolation over the grid (numpy.interp semantics: clamp at edges).
        val filled = DoubleArray(n)
        val first = maskIdx.first()
        val last = maskIdx.last()
        for (i in 0 until n) {
            if (!hrPerEpoch[i].isNaN()) {
                filled[i] = hrPerEpoch[i]
                continue
            }
            // find surrounding known points
            if (i <= first) {
                filled[i] = hrPerEpoch[first]
                continue
            }
            if (i >= last) {
                filled[i] = hrPerEpoch[last]
                continue
            }
            var lo = first
            var hi = last
            for (m in maskIdx) {
                if (m <= i) lo = m
                if (m >= i) {
                    hi = m
                    break
                }
            }
            if (hi == lo) {
                filled[i] = hrPerEpoch[lo]
            } else {
                val frac = (i - lo).toDouble() / (hi - lo).toDouble()
                filled[i] = hrPerEpoch[lo] + frac * (hrPerEpoch[hi] - hrPerEpoch[lo])
            }
        }

        val k1 = gaussianKernel(sigmaS = hrDogSigma1S)
        val k2 = gaussianKernel(sigmaS = hrDogSigma2S)
        val g1 = convolveReflect(filled.toList(), k1)
        val g2 = convolveReflect(filled.toList(), k2)
        return List(n) { g1[it] - g2[it] }
    }

    // ── Respiration rate + RRV (raw 1 Hz) ────────────────────────────────────

    /**
     * Estimate respiratory rate (breaths/min) and RRV (s) from a raw resp window.
     * Detrend → peak-pick (≥2 s apart) → breath intervals (1.5–12 s) → rate =
     * 60/median interval, RRV = std of intervals. (NaN, NaN) when too few samples.
     *
     * Faithful port of sleep_features.resp_rate_and_rrv using a simple local-maxima
     * peak finder. Returned as a Pair(rate, rrv).
     */
    internal fun respRateAndRRV(respRaw: List<Double>, dtS: Double = 1.0): Pair<Double, Double> {
        val nan = Double.NaN
        if (respRaw.size < 8) return Pair(nan, nan)
        val mean = respRaw.sum() / respRaw.size.toDouble()
        val x = respRaw.map { it - mean }
        if (x.all { abs(it) < 1e-12 }) return Pair(nan, nan)

        val std = standardDeviation(x)
        if (std <= 0) return Pair(nan, nan)

        val minDistance = maxOf(2, (2.0 / dtS).roundToInt())
        val peaks = findPeaks(x, distance = minDistance, height = 0.0)
        if (peaks.size < 3) return Pair(nan, nan)

        val intervals = ArrayList<Double>()
        for (i in 1 until peaks.size) {
            val iv = (peaks[i] - peaks[i - 1]).toDouble() * dtS
            if (iv in 1.5..12.0) intervals.add(iv)
        }
        if (intervals.size < 2) return Pair(nan, nan)
        val rate = 60.0 / HrvAnalyzer.median(intervals)
        val rrv = standardDeviation(intervals) // population std (numpy default)
        return Pair(rate, rrv)
    }

    // ── Respiration rate from R-R (RSA) — WHOOP5 on-wire path ────────────────

    /** RSA tachogram resample rate (Hz). 4 Hz is the standard HRV resample grid. */
    private const val rsaResampleHz: Double = 4.0

    /** Moving-mean detrend window for the RSA tachogram (seconds). */
    private const val rsaDetrendWindowS: Double = 8.0

    /** Minimum spacing between breath peaks on the tachogram (seconds) → ≤24 bpm. */
    private const val rsaMinPeakDistanceS: Double = 2.5

    /** Per-window length for the per-window rate estimate (seconds). */
    private const val rsaWindowS: Double = 300.0

    /** Physiologic breath-interval band (seconds): 0.1–0.4 Hz = 6–24 breaths/min. */
    private const val rsaMinBreathIntervalS: Double = 2.5  // 24 bpm
    private const val rsaMaxBreathIntervalS: Double = 10.0 // 6 bpm

    /**
     * THE canonical plausible sleeping-respiratory-rate band (bpm). The RSA peak-pick above can yield
     * 6–8 bpm at its noise floor, but every consumer (ReadinessEngine illness/readiness) only acts on
     * 8–25 — so a sub-8 estimate used to be persisted-then-silently-ignored. respRateFromRR now clamps
     * its output to this band (NaN outside it), and ReadinessEngine references this same range, so the
     * stored value can never disagree with what's acted on. (#78) */
    val respPlausibleRangeBpm: ClosedFloatingPointRange<Double> = 8.0..25.0

    /**
     * APPROXIMATE respiratory rate (breaths/min) from the R-R interval stream via
     * respiratory sinus arrhythmia (RSA), for use when no raw resp ADC channel is
     * available (WHOOP5 v18 wire is RR-only; resp ADC is WHOOP4 / cloud-only).
     *
     * This is an ON-DEVICE ESTIMATE, NOT a cloud/clinical respiration measurement.
     * It recovers the breathing-modulation of beat-to-beat timing, which tracks but
     * does not equal a chest-band / capnography rate.
     *
     * Pipeline (per matched in-bed session [start, end], unix SECONDS):
     *   1. Restrict RR rows to ts in [start, end]; range-filter the RR values
     *      (HrvAnalyzer.rangeFilter) to drop dropouts/ectopics.
     *   2. Reconstruct beat times by cumulatively summing the kept RR intervals
     *      from the first in-bed beat, yielding an (irregular) tachogram
     *      t_k = Σ rr, value_k = rr_k (ms).
     *   3. Resample the tachogram onto a uniform ~4 Hz grid by linear interpolation.
     *   4. Detrend: subtract a centered moving mean (rsaDetrendWindowS).
     *   5. Per ~5-min window: findPeaks (min distance rsaMinPeakDistanceS) on the
     *      detrended grid, keep peak-to-peak intervals in the 6–24 bpm band, rate =
     *      60 / median(intervals). Take the median across windows.
     * Returns NaN when too few intervals survive (honest no-data).
     */
    internal fun respRateFromRR(rr: List<RrInterval>, start: Long, end: Long): Double {
        val nan = Double.NaN
        if (end <= start) return nan

        // 1. In-bed RR rows in chronological order, range-filtered.
        val inBed = rr.asSequence()
            .filter { it.ts in start..end }
            .sortedBy { it.ts }
            .map { it.rrMs.toDouble() }
            .toList()
        val filtered = HrvAnalyzer.rangeFilter(inBed)
        if (filtered.size < 30) return nan // need enough beats for any RSA estimate

        // 2. Reconstruct beat times (seconds from session start) by cumulative sum.
        val beatTimes = DoubleArray(filtered.size)
        var acc = 0.0
        for (i in filtered.indices) {
            acc += filtered[i] / 1000.0
            beatTimes[i] = acc
        }
        val totalSpanS = beatTimes[beatTimes.size - 1]
        if (totalSpanS < rsaWindowS / 2.0) return nan // < ~2.5 min of beats

        // 3. Resample onto a uniform grid by linear interpolation.
        val dt = 1.0 / rsaResampleHz
        val nGrid = (totalSpanS / dt).toInt() + 1
        if (nGrid < 8) return nan
        val grid = DoubleArray(nGrid)
        var seg = 0
        for (g in 0 until nGrid) {
            val t = g * dt
            // advance segment so beatTimes[seg] <= t <= beatTimes[seg+1]
            while (seg < beatTimes.size - 2 && beatTimes[seg + 1] < t) seg += 1
            val t0 = beatTimes[seg]
            val t1 = beatTimes[seg + 1]
            val v0 = filtered[seg]
            val v1 = filtered[seg + 1]
            grid[g] = if (t1 <= t0) v0 else {
                val frac = ((t - t0) / (t1 - t0)).coerceIn(0.0, 1.0)
                v0 + frac * (v1 - v0)
            }
        }

        // 4. Detrend: subtract a centered moving mean (removes slow LF/baseline drift).
        val halfW = maxOf(1, (rsaDetrendWindowS * rsaResampleHz / 2.0).roundToInt())
        val detrended = DoubleArray(nGrid)
        for (i in 0 until nGrid) {
            val lo = maxOf(0, i - halfW)
            val hi = minOf(nGrid - 1, i + halfW)
            var sum = 0.0
            for (j in lo..hi) sum += grid[j]
            val mean = sum / (hi - lo + 1).toDouble()
            detrended[i] = grid[i] - mean
        }
        if (standardDeviation(detrended.toList()) <= 1e-9) return nan // flat → no RSA

        // 5. Per ~5-min window peak-pick → 60/median(breath interval); median across.
        val minDistSamples = maxOf(2, (rsaMinPeakDistanceS * rsaResampleHz).roundToInt())
        val windowSamples = maxOf(minDistSamples * 3, (rsaWindowS * rsaResampleHz).roundToInt())
        val perWindowRates = ArrayList<Double>()
        var w = 0
        while (w < nGrid) {
            val wEnd = minOf(nGrid, w + windowSamples)
            if (wEnd - w >= minDistSamples * 3) {
                val winSeg = ArrayList<Double>(wEnd - w)
                for (k in w until wEnd) winSeg.add(detrended[k])
                // findPeaks with height = 0.0 selects the positive RSA peaks (one per
                // breath) on the zero-mean detrended tachogram.
                val peaks = findPeaks(winSeg, distance = minDistSamples, height = 0.0)
                if (peaks.size >= 3) {
                    val intervals = ArrayList<Double>(peaks.size - 1)
                    for (i in 1 until peaks.size) {
                        val ivS = (peaks[i] - peaks[i - 1]).toDouble() * dt
                        if (ivS in rsaMinBreathIntervalS..rsaMaxBreathIntervalS) intervals.add(ivS)
                    }
                    if (intervals.size >= 2) {
                        val med = HrvAnalyzer.median(intervals)
                        if (med > 0.0) perWindowRates.add(60.0 / med)
                    }
                }
            }
            w += windowSamples
        }
        if (perWindowRates.isEmpty()) return nan
        // Reject estimates outside the canonical consumer band (NaN = "no usable estimate") so the
        // persisted value never silently disagrees with ReadinessEngine's plausibility gate. (#78)
        val median = HrvAnalyzer.median(perWindowRates)
        return if (median in respPlausibleRangeBpm) median else nan
    }

    /**
     * Local-maxima peak finder mirroring scipy.find_peaks(distance, height):
     * a sample is a peak if strictly greater than both neighbours and ≥ height;
     * peaks closer than `distance` are resolved by keeping the taller.
     */
    internal fun findPeaks(x: List<Double>, distance: Int, height: Double): List<Int> {
        val n = x.size
        if (n < 3) return emptyList()
        val candidates = ArrayList<Int>()
        var i = 1
        while (i < n - 1) {
            if (x[i] > x[i - 1] && x[i] >= height) {
                // handle flat plateaus: find right edge of the plateau
                var j = i
                while (j + 1 < n && x[j + 1] == x[i]) j += 1
                if (j + 1 < n && x[j + 1] < x[i]) {
                    candidates.add((i + j) / 2) // plateau midpoint
                }
                i = j + 1
            } else {
                i += 1
            }
        }
        if (distance <= 1 || candidates.isEmpty()) return candidates
        // Enforce minimum distance: greedily keep tallest, scipy-style.
        val byHeight = candidates.sortedByDescending { x[it] }
        val keep = BooleanArray(candidates.size) { true }
        val indexOf = HashMap<Int, Int>(candidates.size)
        for ((off, c) in candidates.withIndex()) indexOf[c] = off
        for (p in byHeight) {
            val pi = indexOf[p] ?: continue
            if (!keep[pi]) continue
            for ((qi, q) in candidates.withIndex()) {
                if (qi != pi && keep[qi]) {
                    if (abs(q - p) < distance) keep[qi] = false
                }
            }
        }
        return candidates.filterIndexed { off, _ -> keep[off] }.sorted()
    }

    // ── Per-epoch features ──────────────────────────────────────────────────

    internal class EpochFeatures(
        val index: Int,
        val midTs: Double,
        /** rescaled Cole–Kripke activity count. */
        val count: Double,
        val moveFrac: Double,
        val ckSleep: Boolean,
        /** mean HR over the feature window. */
        val hr: Double,
        /** Walch DoG-HR windowed std. */
        val hrVar: Double,
        /** ms. */
        val rmssd: Double,
        /** ms. */
        val sdnn: Double,
        /** breaths/min. */
        val respRate: Double,
        /** respiratory-rate variability (s). */
        val rrv: Double,
        /** normalized time since onset, 0..1. */
        val clock: Double,
    )

    internal fun extractFeatures(
        grid: EpochGrid, ckFlags: List<Boolean>, dogHR: List<Double>,
        onsetIdx: Int, finalWakeIdx: Int,
    ): List<EpochFeatures> {
        val n = grid.nEpochs
        val rescaled = rescaleCounts(grid.counts)
        val halfW = (featureWindowS / epochS / 2).roundToInt()
        val span = maxOf(1, finalWakeIdx - onsetIdx).toDouble()

        val feats = ArrayList<EpochFeatures>(n)
        for (i in 0 until n) {
            val lo = maxOf(0, i - halfW)
            val hi = minOf(n, i + halfW + 1)

            val winHR = (lo until hi).map { grid.hr[it] }.filter { !it.isNaN() }
            val hrMean = if (winHR.isEmpty()) Double.NaN else winHR.sum() / winHR.size.toDouble()

            val winDog = (lo until hi).map { if (dogHR.isEmpty()) 0.0 else dogHR[it] }
            val hrVar = if (winDog.size >= 2) standardDeviation(winDog) else Double.NaN

            // RMSSD/SDNN over the pooled RR window (range-filtered, like the
            // Python per-epoch hrv_from_rr which uses RAW range-filtered RR).
            val winRR = ArrayList<Double>()
            for (j in lo until hi) winRR.addAll(grid.rr[j])
            val filteredRR = HrvAnalyzer.rangeFilter(winRR)
            val rmssd = if (filteredRR.size >= 5) (HrvAnalyzer.rmssdRaw(filteredRR) ?: Double.NaN) else Double.NaN
            val sdnn = if (filteredRR.size >= 5) (HrvAnalyzer.sdnnRaw(filteredRR) ?: Double.NaN) else Double.NaN

            val winResp = ArrayList<Double>()
            for (j in lo until hi) winResp.addAll(grid.resp[j])
            val (respRate, rrv) = respRateAndRRV(winResp)

            val clock = minOf(1.0, maxOf(0.0, (i - onsetIdx).toDouble() / span))

            feats.add(
                EpochFeatures(
                    index = i, midTs = grid.epochMid(i), count = rescaled[i],
                    moveFrac = grid.moveFrac[i],
                    ckSleep = if (i < ckFlags.size) ckFlags[i] else true,
                    hr = hrMean, hrVar = hrVar, rmssd = rmssd, sdnn = sdnn,
                    respRate = respRate, rrv = rrv, clock = clock,
                )
            )
        }
        return feats
    }

    // ── Percentile helper ─────────────────────────────────────────────────────

    /** numpy-style linear-interpolated percentile over finite values; null if none. */
    internal fun percentile(values: List<Double>, pct: Double): Double? {
        val vals = values.filter { it.isFinite() }.sorted()
        if (vals.isEmpty()) return null
        return percentileSorted(vals, pct)
    }

    /**
     * Linear-interpolated percentile of an already-sorted sequence (numpy-style).
     * Inlined from Swift `StrainScorer.percentile` (not yet ported to Kotlin); same
     * algorithm so a later StrainScorer port stays consistent.
     */
    private fun percentileSorted(sortedValues: List<Double>, pct: Double): Double {
        val n = sortedValues.size
        if (n == 0) return 0.0
        if (n == 1) return sortedValues[0]
        val position = (pct / 100.0) * (n - 1).toDouble()
        val lower = position.toInt()
        val upper = minOf(lower + 1, n - 1)
        val frac = position - lower.toDouble()
        return sortedValues[lower] + frac * (sortedValues[upper] - sortedValues[lower])
    }

    // ── Classifier seam (Stage 2) ─────────────────────────────────────────────

    internal fun classifyEpochs(features: List<EpochFeatures>): List<String> {
        val n = features.size
        if (n == 0) return emptyList()

        // Session-relative reference distributions over SLEEP-PERIOD epochs.
        val sleepFeats = if (features.any { it.ckSleep }) features.filter { it.ckSleep } else features
        val hrLo = percentile(sleepFeats.map { it.hr }, stageHRLowPct)
        val hrHi = percentile(sleepFeats.map { it.hr }, stageHRHighPct)
        val rmssdHi = percentile(sleepFeats.map { it.rmssd }, stageHRVHighPct)
        val hrvarHi = percentile(sleepFeats.map { it.hrVar }, stageHRVarHighPct)
        val rrvHi = percentile(sleepFeats.map { it.rrv }, stageRRVHighPct)
        val rrvLo = percentile(sleepFeats.map { it.rrv }, stageRRVLowPct)

        return features.map {
            classifyOne(it, hrLo = hrLo, hrHi = hrHi, rmssdHi = rmssdHi,
                hrvarHi = hrvarHi, rrvHi = rrvHi, rrvLo = rrvLo)
        }
    }

    internal fun classifyOne(
        f: EpochFeatures, hrLo: Double?, hrHi: Double?,
        rmssdHi: Double?, hrvarHi: Double?, rrvHi: Double?, rrvLo: Double?,
    ): String {
        val hasHR = f.hr.isFinite()
        val hrLow = hasHR && hrLo != null && f.hr <= hrLo
        val hrHigh = hasHR && hrHi != null && f.hr >= hrHi

        // NOTE: HF omitted (no neurokit2). Parasympathetic tone = RMSSD only.
        val parasympHigh = f.rmssd.isFinite() && rmssdHi != null && f.rmssd >= rmssdHi

        val hrvarHigh = f.hrVar.isFinite() && hrvarHi != null && f.hrVar >= hrvarHi
        val cardiacActivated = hrHigh || hrvarHigh

        val rrvIrregular = f.rrv.isFinite() && rrvHi != null && f.rrv >= rrvHi
        // Missing respiration (NaN RRV) treated as "regular" (pro-deep bias).
        val rrvRegular = (!f.rrv.isFinite()) || (rrvLo != null && f.rrv <= rrvLo)

        val still = f.moveFrac <= stageStillMoveFrac
        val moving = f.moveFrac >= stageWakeMoveFrac

        // WAKE: sustained motion + activated cardiac (or no HR to vet motion).
        if (moving && (cardiacActivated || !hasHR)) return "wake"
        // DEEP: still + high parasympathetic tone + low HR + regular respiration.
        if (still && parasympHigh && hrLow && rrvRegular) return "deep"
        // REM: still body + activated cardiac + irregular respiration.
        if (still && cardiacActivated && rrvIrregular) return "rem"
        // REM fallback when respiration unavailable: require BOTH cardiac signals.
        if (still && hrHigh && hrvarHigh && !f.rrv.isFinite()) return "rem"
        return "light"
    }

    // ── Post-processing (Stage 3) ─────────────────────────────────────────────

    internal fun smoothLabels(labels: List<String>, window: Int = smoothEpochs): List<String> {
        val n = labels.size
        if (n == 0 || window <= 1) return labels
        var w = window
        if (w % 2 == 0) w += 1
        val half = w / 2
        val out = ArrayList<String>(n)
        for (i in 0 until n) {
            val lo = maxOf(0, i - half)
            val hi = minOf(n, i + half + 1)
            val counts = HashMap<String, Int>()
            val order = ArrayList<String>()
            for (idx in lo until hi) {
                val s = labels[idx]
                if (counts[s] == null) order.add(s)
                counts[s] = (counts[s] ?: 0) + 1
            }
            val best = counts.values.maxOrNull()
            if (best == null) { out.add(labels[i]); continue }
            val winners = order.filter { counts[it] == best } // insertion order preserved
            out.add(if (winners.contains(labels[i])) labels[i] else winners[0])
        }
        return out
    }

    internal fun reimposePhysiology(
        labels: List<String>, features: List<EpochFeatures>,
        onsetIdx: Int, finalWakeIdx: Int,
    ): List<String> {
        val out = labels.toMutableList()
        val noREMEpochs = (noREMAfterOnsetMin * 60.0 / epochS).roundToInt()
        for ((i, f) in features.withIndex()) {
            if (i < onsetIdx || i > finalWakeIdx) continue
            if (out[i] == "rem" && (i - onsetIdx) < noREMEpochs) out[i] = "light"
            if (out[i] == "deep" && f.clock > deepFirstFraction) out[i] = "light"
        }
        return out
    }

    // ── Per-session HR / HRV ─────────────────────────────────────────────────

    /** Lowest 5-min rolling-mean HR during the session (bpm), or null. */
    internal fun sessionRestingHR(start: Long, end: Long, hr: List<HrSample>): Int? {
        val seg = hr.filter { it.ts in start..end }
        if (seg.isEmpty()) return null
        val windowS = 5 * 60L
        val means = ArrayList<Double>()
        var t = start
        while (t < end) {
            val win = seg.filter { it.ts >= t && it.ts < t + windowS }
            if (win.isNotEmpty()) means.add(win.sumOf { it.bpm }.toDouble() / win.size.toDouble())
            t += windowS
        }
        val m = means.minOrNull()
        if (m != null) return m.roundToInt()
        val all = seg.sumOf { it.bpm }.toDouble() / seg.size.toDouble()
        return all.roundToInt()
    }

    /**
     * Mean RMSSD over 5-min tumbling windows across the session (ms), or null.
     * Uses the same range-filter + ≥2-valid-interval rule as hrv.rmssd().
     */
    internal fun sessionAvgHRV(start: Long, end: Long, rr: List<RrInterval>): Double? {
        val seg = rr.filter { it.ts in start..end }
        if (seg.isEmpty()) return null
        val windowS = 5 * 60L
        val vals = ArrayList<Double>()
        var t = start
        while (t < end) {
            val bucket = seg.filter { it.ts >= t && it.ts < t + windowS }.map { it.rrMs.toDouble() }
            val filtered = HrvAnalyzer.rangeFilter(bucket)
            if (filtered.size >= 2) {
                val r = HrvAnalyzer.rmssdRaw(filtered)
                if (r != null) vals.add(r)
            }
            t += windowS
        }
        if (vals.isEmpty()) return null
        return vals.sum() / vals.size.toDouble()
    }

    // ── AASM hypnogram metrics ───────────────────────────────────────────────

    /** AASM-style metrics from a session's stage segments. */
    fun hypnogramMetrics(session: DetectedSleep): HypnogramMetrics {
        val segs = session.stages.sortedBy { it.start }
        val tib = maxOf(0.0, (session.end - session.start).toDouble())

        fun dur(s: StageSegment): Double = (s.end - s.start).toDouble()
        val sleepSegs = segs.filter { it.stage == "light" || it.stage == "deep" || it.stage == "rem" }
        val tst = sleepSegs.sumOf { dur(it) }
        val deepS = segs.filter { it.stage == "deep" }.sumOf { dur(it) }
        val remS = segs.filter { it.stage == "rem" }.sumOf { dur(it) }
        val lightS = segs.filter { it.stage == "light" }.sumOf { dur(it) }

        val onset: Double
        val sptEnd: Double
        val sol: Double
        val first = sleepSegs.firstOrNull()
        val last = sleepSegs.lastOrNull()
        if (first != null && last != null) {
            onset = first.start.toDouble()
            sptEnd = last.end.toDouble()
            sol = maxOf(0.0, onset - session.start.toDouble())
        } else {
            onset = session.end.toDouble()
            sptEnd = session.end.toDouble()
            sol = tib
        }

        val remSegs = segs.filter { it.stage == "rem" }
        val remLatency = remSegs.firstOrNull()?.let { it.start.toDouble() - onset } ?: Double.NaN

        var waso = 0.0
        var disturbances = 0
        for (s in segs) {
            if (s.stage != "wake") continue
            val w0 = maxOf(s.start.toDouble(), onset)
            val w1 = minOf(s.end.toDouble(), sptEnd)
            if (w1 > w0) {
                waso += (w1 - w0)
                disturbances += 1
            }
        }

        val se = if (tib > 0) tst / tib else 0.0
        fun pct(x: Double): Double = if (tst > 0) x / tst * 100.0 else 0.0

        return HypnogramMetrics(
            tibS = tib, tstS = tst, sptS = maxOf(0.0, sptEnd - onset), solS = sol,
            remLatencyS = remLatency, wasoS = waso, efficiency = minOf(1.0, se),
            disturbances = disturbances, deepMin = deepS / 60.0, remMin = remS / 60.0,
            lightMin = lightS / 60.0, deepPct = pct(deepS), remPct = pct(remS), lightPct = pct(lightS),
        )
    }

    // ── Small stats helpers ───────────────────────────────────────────────────

    /** Population standard deviation (numpy default, ddof=0). */
    internal fun standardDeviation(values: List<Double>): Double {
        if (values.isEmpty()) return 0.0
        val mean = values.sum() / values.size.toDouble()
        var ss = 0.0
        for (v in values) {
            val d = v - mean
            ss += d * d
        }
        return sqrt(ss / values.size.toDouble())
    }
}
