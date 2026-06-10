package com.noop.analytics

import org.junit.Assert.assertEquals
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

    // ── resp into the recovery composite ────────────────────────────────────
    // Pins the recovery composite's optional respiratory-rate term without a DB: once a
    // usable resp baseline exists, a nightly respiratory rate ABOVE it must LOWER recovery
    // and one BELOW it must RAISE it; a null resp must renormalize to exactly the score with
    // no resp baseline at all (the term drops out, the remaining weights re-divide).

    private val respCfg = Baselines.metricCfg.getValue("resp")

    private fun recoveryWithResp(resp: Double?, respBaseline: BaselineState?): Double? {
        // Usable hrv/rhr baselines centred on the night's values, so only resp moves the score.
        val hrvBase = Baselines.foldHistory(listOf(58.0, 61.0, 60.0, 59.0), hrvCfg)
        val rhrBase = Baselines.foldHistory(listOf(52.0, 51.0, 53.0, 52.0), rhrCfg)
        return RecoveryScorer.recovery(
            hrv = 59.5,
            rhr = 52.0,
            resp = resp,
            hrvBaseline = hrvBase,
            rhrBaseline = rhrBase,
            respBaseline = respBaseline,
            sleepPerf = 0.9,
        )
    }

    @Test
    fun respAboveBaselineLowersRecovery_belowRaisesIt() {
        // >= minNightsSeed plausible RSA nights seed a usable resp baseline around 14.5 bpm.
        val respBase = Baselines.foldHistory(listOf(14.5, 14.4, 14.6, 14.5, 14.5), respCfg)
        assertTrue("5 plausible nights must seed a usable resp baseline", respBase.usable)
        val neutral = recoveryWithResp(resp = null, respBaseline = respBase)!!
        val elevated = recoveryWithResp(resp = 17.5, respBaseline = respBase)!!
        val lowered = recoveryWithResp(resp = 12.0, respBaseline = respBase)!!
        assertTrue(
            "resp above baseline must lower recovery ($elevated !< $neutral)",
            elevated < neutral,
        )
        assertTrue(
            "resp below baseline must raise recovery ($lowered !> $neutral)",
            lowered > neutral,
        )
    }

    @Test
    fun nullRespRenormalizesToThePreWiringScore() {
        // resp = null with a usable resp baseline must equal the score with NO resp baseline at
        // all — the resp term drops and the remaining weights renormalize identically, so wiring
        // resp into the composite cannot shift any night that lacks an RSA estimate.
        val respBase = Baselines.foldHistory(listOf(14.5, 14.4, 14.6, 14.5, 14.5), respCfg)
        val withBaselineNullResp = recoveryWithResp(resp = null, respBaseline = respBase)!!
        val preWiring = recoveryWithResp(resp = null, respBaseline = null)!!
        assertEquals(preWiring, withBaselineNullResp, 1e-9)
    }
}
