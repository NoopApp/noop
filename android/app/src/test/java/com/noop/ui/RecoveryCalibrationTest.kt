package com.noop.ui

import com.noop.analytics.Baselines
import com.noop.data.DailyMetric
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/**
 * Unit tests for [recoveryCalibrationNights], the pure helper behind the Today recovery cold-start
 * "Calibrating — N of 4 nights" affordance. Recovery is null until the HRV baseline crosses the seed
 * gate (Baselines.minNightsSeed valid nights); this surfaces honest progress instead of "No Data".
 */
class RecoveryCalibrationTest {

    private val seed = Baselines.minNightsSeed // 4

    private fun day(d: String, hrv: Double?) = DailyMetric(deviceId = "my-whoop-noop", day = d, avgHrv = hrv)

    @Test
    fun nullWhenRecoveryAlreadyExists() {
        val days = listOf(day("2026-01-01", 55.0), day("2026-01-02", 60.0))
        assertNull(recoveryCalibrationNights(days, hasRecovery = true))
    }

    @Test
    fun nullWhenNoNightHasHrvYet() {
        val days = listOf(day("2026-01-01", null), day("2026-01-02", null))
        assertNull(recoveryCalibrationNights(days, hasRecovery = false))
    }

    @Test
    fun countsNightsCarryingHrvBelowSeed() {
        val days = listOf(day("2026-01-01", 55.0), day("2026-01-02", null), day("2026-01-03", 61.0))
        assertEquals(2, recoveryCalibrationNights(days, hasRecovery = false))
    }

    @Test
    fun oneNightReportsOne() {
        assertEquals(1, recoveryCalibrationNights(listOf(day("2026-01-01", 58.0)), hasRecovery = false))
    }

    @Test
    fun nullAtOrAboveSeed_doesNotClaimCalibrating() {
        // At/above the seed gate, the baseline should be usable; if recovery is still null it's some
        // other gap, so we must NOT show a misleading "calibrating 4 of 4".
        val days = (1..seed).map { day("2026-01-0$it", 55.0 + it) }
        assertNull(recoveryCalibrationNights(days, hasRecovery = false))
    }

    @Test
    fun ignoresNullHrvNights() {
        val days = listOf(
            day("2026-01-01", 55.0), day("2026-01-02", null),
            day("2026-01-03", null), day("2026-01-04", 60.0),
        )
        assertEquals(2, recoveryCalibrationNights(days, hasRecovery = false))
    }

    @Test
    fun ignoresOutOfRangeHrvNights() {
        // A physiologically implausible avgHrv (outside the HRV config bounds 5..250) does NOT advance
        // the recovery seed in Baselines.update, so it must not be counted here either — only the
        // in-range night does. Keeps the displayed N in step with the real nValid.
        val days = listOf(
            day("2026-01-01", 55.0),    // valid
            day("2026-01-02", 4.0),     // below minVal (5.0) → not a seed night
            day("2026-01-03", 999.0),   // above maxVal (250.0) → not a seed night
        )
        assertEquals(1, recoveryCalibrationNights(days, hasRecovery = false))
    }
}
