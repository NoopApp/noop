package com.noop.analytics

import com.noop.data.HrSample
import com.noop.data.SkinTempSample
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Unit tests for the WHOOP 5.0/MG skin-temperature pipeline added in AnalyticsEngine/IntelligenceEngine.
 *
 * Two parts, mirroring the codebase's "test the building block" convention (see BaselineSeedingTest):
 *  1. [AnalyticsEngine.wornNightlySkinTempC] — the new wear-gated nightly-mean logic (the part that
 *     turns raw skin_temp_raw@73 samples into a trustworthy per-night value).
 *  2. The seed→deviation flow over [Baselines.foldHistory]/[Baselines.deviation] with the standard
 *     `skin_temp` config — pinning the honest cold-start gate (<4 nights ⇒ no skinTempDevC) and that a
 *     real elevation surfaces as a positive deviation once seeded. All values APPROXIMATE.
 *
 * Skin-temp raw is u16 centi-°C (°C = raw/100); worn nightly values seen on real hardware were ~33–35 °C,
 * off-wrist/charging ~22–27 °C — which is exactly the contamination the wear-gate excludes.
 */
class SkinTempAnalyticsTest {

    private val dev = "my-whoop"

    private fun session(start: Long, durSec: Long) = DetectedSleep(
        start = start, end = start + durSec, efficiency = 0.9,
        stages = emptyList(), restingHR = 50, avgHRV = 60.0,
    )

    private fun hr(ts: Long, bpm: Int = 55) = HrSample(deviceId = dev, ts = ts, bpm = bpm)
    private fun skin(ts: Long, rawCentiC: Int) = SkinTempSample(deviceId = dev, ts = ts, raw = rawCentiC)

    // ── wornNightlySkinTempC ────────────────────────────────────────────────

    @Test
    fun meanOverWornInBedSamples() {
        val start = 1_000_000L
        val sess = listOf(session(start, 600))
        val hrs = (0 until 600).map { hr(start + it) }
        val temps = (0 until 600).map { skin(start + it, 3400) } // 34.00 °C
        val mean = AnalyticsEngine.wornNightlySkinTempC(sess, hrs, temps)
        assertEquals(34.0, mean!!, 1e-9)
    }

    @Test
    fun excludesSamplesWithoutConcurrentWornHr() {
        // The strap streams HR only on-wrist; skin-temp samples with no concurrent worn BPM are dropped.
        val start = 2_000_000L
        val sess = listOf(session(start, 600))
        val temps = (0 until 600).map { skin(start + it, 3400) }
        assertNull(AnalyticsEngine.wornNightlySkinTempC(sess, emptyList(), temps))
    }

    @Test
    fun excludesDaytimeSamplesOutsideTheSleepSession() {
        // Daytime samples are in worn range (36 °C) AND have worn HR, but fall OUTSIDE the in-bed
        // session window, so only the in-bed 34 °C samples count. Isolates the session-window gate.
        val night = 3_000_000L
        val sess = listOf(session(night, 600))
        val inBedHr = (0 until 600).map { hr(night + it) }
        val inBedTemp = (0 until 600).map { skin(night + it, 3400) }
        val day = night + 10_000
        val dayHr = (0 until 600).map { hr(day + it) }
        val dayTemp = (0 until 600).map { skin(day + it, 3600) } // 36 °C, worn-range, but daytime
        val mean = AnalyticsEngine.wornNightlySkinTempC(sess, inBedHr + dayHr, inBedTemp + dayTemp)
        assertEquals(34.0, mean!!, 1e-9)
    }

    @Test
    fun excludesOnChargerAmbientEvenInBed() {
        // Mid-night on charger: HR still has stray worn-range values but skin temp drifts to ambient
        // (~22 °C) — which passes the strap's looser 20–45 decode gate but is below the worn floor.
        val start = 4_000_000L
        val sess = listOf(session(start, 600))
        val hrs = (0 until 600).map { hr(start + it) }
        val temps = (0 until 600).map { skin(start + it, 2200) } // 22 °C ambient
        assertNull(AnalyticsEngine.wornNightlySkinTempC(sess, hrs, temps))
    }

    @Test
    fun belowMinSamplesIsNull() {
        val start = 5_000_000L
        val sess = listOf(session(start, 100))
        val hrs = (0 until 100).map { hr(start + it) }
        val temps = (0 until 100).map { skin(start + it, 3400) } // only 100 < MIN_SKIN_TEMP_SAMPLES
        assertNull(AnalyticsEngine.wornNightlySkinTempC(sess, hrs, temps))
    }

    @Test
    fun emptyInputsAreNull() {
        assertNull(AnalyticsEngine.wornNightlySkinTempC(emptyList(), emptyList(), emptyList()))
    }

    // ── seed → deviation (skin_temp baseline) ───────────────────────────────

    private val skinCfg = Baselines.metricCfg.getValue("skin_temp")

    @Test
    fun coldStart_belowSeed_baselineNotUsable() {
        // 3 nightly means (< minNightsSeed = 4): still CALIBRATING → skinTempDevC stays null.
        val nights: List<Double?> = listOf(33.5, 33.6, 33.4)
        assertFalse(Baselines.foldHistory(nights, skinCfg).usable)
    }

    @Test
    fun atSeed_usable_elevationShowsPositiveDeviation() {
        // 4 baseline nights ~33.5 °C; a +0.8 °C night surfaces as a clearly positive deviation —
        // the signal IllnessWatch reads as its skin-temp flag (fires at ≥ +0.6 °C).
        val nights: List<Double?> = listOf(33.5, 33.4, 33.6, 33.5)
        val base = Baselines.foldHistory(nights, skinCfg)
        assertTrue("4 valid nights must seed a usable skin-temp baseline", base.usable)
        val dev = Baselines.deviation(34.3, base).delta
        assertTrue("a +0.8 °C night must read as a clear positive deviation, was $dev", dev > 0.5)
    }
}
