package com.noop.protocol

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * WHOOP 4.0 **v25** PPG → HR feasibility guard (issue #194, RFC — NOT a live decode). Kotlin mirror of
 * the Swift `Whoop4HistoricalV25PpgTests`, kept in lockstep with the shared `PpgHr` lane.
 *
 * #194 proposed reading the v25 record's optical PPG waveform on an odd byte grid and routing it through
 * the existing [PpgHr] lane to recover HR. The original "60 bpm on 3 resting sessions" evidence was
 * WITHDRAWN by @ryanbr: concatenating N samples/record before autocorrelating manufactures a
 * self-similarity at lag = N, peaking at `60·fs/N` (= 60 bpm at fs=N=24) regardless of the real HR — it
 * reports the record PERIOD, not physiology. The maintainer accepted this and added the boundary-gated
 * [PpgHr] record-rate notch (v2.8.6).
 *
 * This guard pins, against the three REAL v25 frames already in the repo (Whoop4HistoricalV25Test):
 *   1. At ryanbr's start offset (15) the bare autocorrelation's bpm tracks `1440/N` exactly — the artifact.
 *   2. The #194-proposed span (start 25, before gravity@73) yields NO HR through the shipped lane, but the
 *      SAME lane reading from offset 15 still emits a fabricated 60 bpm (the per-record waveforms are
 *      near-identical there, so the boundary jump the notch keys on never fires). So the start byte is
 *      load-bearing and v25→HR must not ship on an unpinned span — held pending a known-HR-≠-60 corpus.
 */
class Whoop4HistoricalV25PpgTest {
    private fun bytes(s: String): ByteArray =
        ByteArray(s.length / 2) { ((s[it * 2].digitToInt(16) shl 4) or s[it * 2 + 1].digitToInt(16)).toByte() }

    // Same three REAL v25 records as Whoop4HistoricalV25Test (faklei, App 1.92, 84 bytes, consecutive sec).
    private val records = listOf(
        "aa50000c2f1900006800007dff2a6a20430900433103007e026502ba026c022eff70f996f879fad6fd8300d6017e0267027201be00290258030e05c507f00c030ead11cb15791500d2553c9003000000d6393716",
        "aa50000c2f1900016800007eff2a6a283e0900a0ad03007a0e880698018bfff5fb61eee9f2a7fa2bfe1af5fdf618fdf0f9c2fb0804510a14046a004dffd0ff6dfdddfd670183014e071a3f9003000000587bbabf",
        "aa50000c2f1900026800007fff2a6a38390900729103003608a2fd0104850d4f1bd21aa60f080d850edb116b0f160b7d063f06ab04d5041704a4045f04f003f5ffd7ff7efe73ffa8b2333e9003010000fa54e5e9",
    ).map { bytes(it) }

    private fun i16(f: ByteArray, off: Int): Int? =
        if (off + 2 <= f.size) ((f[off].toInt() and 0xFF) or (f[off + 1].toInt() shl 8)).toShort().toInt() else null

    private fun u32(f: ByteArray, off: Int): Int =
        (f[off].toInt() and 0xFF) or ((f[off + 1].toInt() and 0xFF) shl 8) or
            ((f[off + 2].toInt() and 0xFF) shl 16) or ((f[off + 3].toInt() and 0xFF) shl 24)

    /** 24 odd-grid i16 PPG samples from `start`. */
    private fun ppg(f: ByteArray, start: Int): List<Int> = (0 until 24).mapNotNull { i16(f, start + it * 2) }

    /** Build the concatenated PpgHr input: every sample of a record shares the record's ts. */
    private fun samples(start: Int): List<PpgHr.Sample> =
        records.flatMap { f -> ppg(f, start).map { PpgHr.Sample(u32(f, 11).toLong(), it) } }

    /** Bare windowed autocorrelation (ryanbr's pre-notch method), exact band of the #194 repro. */
    private fun bareBpm(sig: List<Int>, fs: Int = 24): Int {
        val mean = sig.sum().toDouble() / sig.size
        val x = sig.map { it - mean }
        if (x.sumOf { it * it } == 0.0) return 0
        val lo = maxOf(1, 60 * fs / 220); val hi = minOf(sig.size - 1, 60 * fs / 30)
        var best = lo; var bestV = Double.NEGATIVE_INFINITY
        for (lag in lo..hi) {
            var s = 0.0
            for (k in 0 until x.size - lag) s += x[k] * x[k + lag]
            if (s > bestV) { bestV = s; best = lag }
        }
        return Math.round(fs * 60.0 / best).toInt()
    }

    @Test fun fixtureIsV25Consecutive() {
        val ts = records.map { u32(it, 11) }
        assertEquals(listOf(ts[0], ts[0] + 1, ts[0] + 2), ts)
        for (f in records) {
            assertEquals(25, f[5].toInt() and 0xFF)
            assertEquals(24, ppg(f, 25).size)
        }
    }

    /** The artifact: at offset 15, bare bpm tracks the record period 1440/N exactly (#194, ryanbr). */
    @Test fun concatenationArtifactTracksRecordPeriodNotHr() {
        val start = 15
        for (n in listOf(16, 18, 20, 24, 30)) {
            val sig = records.flatMap { f -> (0 until n).mapNotNull { i16(f, start + it * 2) } }
            assertEquals("N=$n: bare bpm should equal record period 1440/N", 1440 / n, bareBpm(sig))
        }
    }

    /** The #194-proposed start-25 span yields NO HR through the shipped lane. */
    @Test fun proposedSpanEmitsNoHrThroughShippedLane() {
        assertTrue(PpgHr.estimate(samples(25)).isEmpty())
    }

    /** The notch does NOT fully protect: reading from offset 15 the shipped lane still emits a fake 60 bpm
     *  — so the start byte is load-bearing and v25→HR must not ship on an unpinned span. */
    @Test fun notchDoesNotFullyProtectV25SoStartByteIsLoadBearing() {
        val hr = PpgHr.estimate(samples(15))
        assertFalse("offset-15 read should surface the artifact the notch misses", hr.isEmpty())
        assertTrue("surviving artifact is the record-period 60 bpm", hr.all { it.bpm == 60 })
        assertTrue("artifact confidence is low-but-passing, the worst false positive", hr.all { it.conf < 0.5 })
    }
}
