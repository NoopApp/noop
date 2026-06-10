package com.noop.analytics

import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Pins the cold-start gate the BLE-only recovery fix depends on: nightly HRV/RHR
 * values harvested from offloaded nights must, once they cross Baselines.minNightsSeed
 * (4 distinct valid nights), produce a usable HRV baseline so RecoveryScorer.recovery
 * stops returning null. Mirrors the in-memory union foldHistory the patched
 * IntelligenceEngine.analyzeRecent performs (imported history is empty for a BLE-only
 * user, so the computed nightly values alone must seed the baseline).
 */
class BaselineSeedingTest {

    private val hrvCfg = Baselines.metricCfg.getValue("hrv")
    private val rhrCfg = Baselines.metricCfg.getValue("resting_hr")

    @Test
    fun foldHistory_belowSeed_isNotUsable_recoveryNull() {
        // 3 valid nights (< minNightsSeed = 4): still CALIBRATING, not usable.
        val hrvNights: List<Double?> = listOf(58.0, 61.0, 60.0)
        val rhrNights: List<Double?> = listOf(52.0, 51.0, 53.0)
        val hrvBase = Baselines.foldHistory(hrvNights, hrvCfg)
        val rhrBase = Baselines.foldHistory(rhrNights, rhrCfg)
        assertFalse("3 nights must not be a usable HRV baseline", hrvBase.usable)
        val score = RecoveryScorer.recovery(
            hrv = 60.0,
            rhr = 52.0,
            resp = null,
            hrvBaseline = hrvBase,
            rhrBaseline = rhrBase,
            respBaseline = null,
            sleepPerf = 0.9,
        )
        assertNull("recovery must be null while HRV baseline is unusable (cold-start)", score)
    }

    @Test
    fun foldHistory_atSeed_isUsable_recoveryNonNull() {
        // 4 valid nights (== minNightsSeed): PROVISIONAL -> usable -> a real score.
        val hrvNights: List<Double?> = listOf(58.0, 61.0, 60.0, 59.0)
        val rhrNights: List<Double?> = listOf(52.0, 51.0, 53.0, 52.0)
        val hrvBase = Baselines.foldHistory(hrvNights, hrvCfg)
        val rhrBase = Baselines.foldHistory(rhrNights, rhrCfg)
        assertTrue("4 nights must be a usable HRV baseline", hrvBase.usable)
        val score = RecoveryScorer.recovery(
            hrv = 60.0,
            rhr = 52.0,
            resp = null,
            hrvBaseline = hrvBase,
            rhrBaseline = rhrBase,
            respBaseline = null,
            sleepPerf = 0.9,
        )
        assertNotNull("recovery must be non-null once HRV baseline is usable", score)
        assertTrue("recovery must be in [0,100]", score!! in 0.0..100.0)
    }

    @Test
    fun foldHistory_nullNights_skipAndHold_doNotCount() {
        // Missing nights (null) are skip-and-hold: 3 valid + 2 null still < seed.
        val hrvNights: List<Double?> = listOf(58.0, null, 61.0, null, 60.0)
        val hrvBase = Baselines.foldHistory(hrvNights, hrvCfg)
        assertFalse("null nights must not advance nValid toward the seed gate", hrvBase.usable)
    }
}
