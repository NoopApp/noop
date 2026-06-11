package com.noop.analytics

import com.noop.data.GravitySample
import org.junit.Assert.assertEquals
import org.junit.Test
import kotlin.random.Random

/**
 * Pins SleepStager.classifyStill's prefix-sum rolling count to the naive per-record rescan
 * it replaced (the rescan was O(n·window) — at 1 Hz that froze the app into ANRs once a few
 * nights of offloaded history accumulated). The two must agree flag-for-flag on every input,
 * including the window-clamping edges (record near the stream start/end, window wider than
 * the whole stream, sub-minimum streams) and the strict-< threshold boundary.
 */
class SleepStagerStillScanTest {

    private val dev = "test"

    /** The original O(n·window) implementation, kept verbatim as the reference oracle. */
    private fun naiveClassifyStill(grav: List<GravitySample>, deltas: List<Double>): List<Boolean> {
        val n = grav.size
        if (n < 2) return List(n) { false }
        val half = SleepStager.windowSize(grav.map { it.ts }) / 2
        val flags = ArrayList<Boolean>(n)
        for (i in 0 until n) {
            val lo = maxOf(0, i - half)
            val hi = minOf(n, i + half + 1)
            var stillCount = 0
            for (j in lo until hi) {
                if (deltas[j] < SleepStager.gravityStillThresholdG) stillCount += 1
            }
            flags.add(stillCount.toDouble() / (hi - lo).toDouble() >= SleepStager.stillFraction)
        }
        return flags
    }

    /** 1 Hz gravity stream whose per-sample movement alternates between long still and active spans. */
    private fun mixedStream(n: Int, seed: Int): Pair<List<GravitySample>, List<Double>> {
        val rnd = Random(seed)
        val grav = ArrayList<GravitySample>(n)
        var x = 0.0
        for (i in 0 until n) {
            // Toggle activity in pseudo-random spans so still/active boundaries land at many
            // different offsets relative to the rolling window.
            if (rnd.nextInt(120) == 0) x = if (x == 0.0) 0.5 else 0.0
            val jitter = if (x > 0.0) rnd.nextDouble(0.02, 0.4) else rnd.nextDouble(0.0, 0.009)
            grav.add(GravitySample(dev, 1_749_513_600L + i, if (i % 2 == 0) jitter else 0.0, 0.0, 1.0))
        }
        return Pair(grav, SleepStager.gravityDeltas(grav))
    }

    @Test
    fun prefixSumMatchesNaiveRescan_mixed1HzStream() {
        val (grav, deltas) = mixedStream(n = 7_200, seed = 42) // 2 h at 1 Hz, window 900 samples
        assertEquals(naiveClassifyStill(grav, deltas), SleepStager.classifyStill(grav, deltas))
    }

    @Test
    fun prefixSumMatchesNaiveRescan_windowWiderThanStream() {
        // 1 Hz stream much shorter than the 15-min window: every record's window clamps to the
        // whole stream on at least one side.
        val (grav, deltas) = mixedStream(n = 300, seed = 7)
        assertEquals(naiveClassifyStill(grav, deltas), SleepStager.classifyStill(grav, deltas))
    }

    @Test
    fun prefixSumMatchesNaiveRescan_sparseSampling() {
        // 60 s spacing (the defaultIntervalS regime) → window of 15 samples; exercises the
        // small-window path where the clamped edges dominate.
        val rnd = Random(11)
        val grav = (0 until 200).map { i ->
            GravitySample(dev, 1_749_513_600L + i * 60L, rnd.nextDouble(0.0, 0.03), 0.0, 1.0)
        }
        val deltas = SleepStager.gravityDeltas(grav)
        assertEquals(naiveClassifyStill(grav, deltas), SleepStager.classifyStill(grav, deltas))
    }

    @Test
    fun thresholdBoundaryIsStrictlyBelow() {
        // Deltas exactly AT gravityStillThresholdG are NOT still (strict <). Random fixtures
        // can never hit 0.01 exactly, so a < → <= drift in either the prefix-sum build or the
        // oracle would pass every other test; this pins the operator on a hand-built delta list.
        val n = 16
        val grav = (0 until n).map { GravitySample(dev, 1_749_513_600L + it, 0.0, 0.0, 1.0) }
        val atThreshold = List(n) { SleepStager.gravityStillThresholdG }
        assertEquals(naiveClassifyStill(grav, atThreshold), SleepStager.classifyStill(grav, atThreshold))
        assertEquals(List(n) { false }, SleepStager.classifyStill(grav, atThreshold))
        val justBelow = List(n) { SleepStager.gravityStillThresholdG - 1e-9 }
        assertEquals(List(n) { true }, SleepStager.classifyStill(grav, justBelow))
    }

    @Test
    fun smallestStreamsThatReachThePrefixScan() {
        // n == 2 just passes the n < 2 guard (single medianIntervalS gap); n == 3 is the
        // minWindowSamples floor. Every window clamps to the full stream at these sizes.
        for (n in 2..3) {
            val (grav, deltas) = mixedStream(n = n, seed = n)
            assertEquals(naiveClassifyStill(grav, deltas), SleepStager.classifyStill(grav, deltas))
        }
    }

    @Test
    fun subMinimumStreamsAllFalse() {
        assertEquals(emptyList<Boolean>(), SleepStager.classifyStill(emptyList(), emptyList()))
        val one = listOf(GravitySample(dev, 1_749_513_600L, 0.0, 0.0, 1.0))
        assertEquals(listOf(false), SleepStager.classifyStill(one, SleepStager.gravityDeltas(one)))
    }
}
