package com.noop.analytics

import com.noop.data.DailyMetric
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Faithful Kotlin port of
 * Packages/StrandAnalytics/Tests/StrandAnalyticsTests/ReadinessEngineTests.swift.
 * Same fixtures (28 baseline days + today), same assertions.
 */
class ReadinessEngineTest {

    private fun d(
        i: Int,
        hrv: Double?,
        rhr: Int?,
        strain: Double?,
        resp: Double? = null,
    ): DailyMetric = DailyMetric(
        deviceId = "test",
        day = "2024-03-%02d".format(i),
        restingHr = rhr,
        avgHrv = hrv,
        strain = strain,
        respRateBpm = resp,
    )

    /** 28 baseline days with gentle variation (so SD > 0), then `today` as day 29. */
    private fun baseline(
        todayHrv: Double?,
        todayRhr: Int?,
        todayStrain: Double?,
        todayResp: Double? = null,
        baseStrain: Double = 10.0,
    ): List<DailyMetric> {
        val days = mutableListOf<DailyMetric>()
        for (i in 1..28) {
            days.add(
                d(
                    i,
                    hrv = if (i % 2 == 0) 62.0 else 58.0,
                    rhr = if (i % 2 == 0) 54 else 50,
                    strain = baseStrain,
                    resp = if (i % 2 == 0) 14.5 else 13.5,
                )
            )
        }
        days.add(d(29, hrv = todayHrv, rhr = todayRhr, strain = todayStrain, resp = todayResp))
        return days
    }

    @Test
    fun insufficientWhenEmpty() {
        assertEquals(ReadinessEngine.Level.INSUFFICIENT, ReadinessEngine.evaluate(emptyList()).level)
    }

    @Test
    fun specifiedTodayDoesNotFallbackToLatestHistoricalDay() {
        val r = ReadinessEngine.evaluate(
            baseline(todayHrv = 72.0, todayRhr = 46, todayStrain = 10.0),
            today = "2026-06-08",
        )

        assertEquals(ReadinessEngine.Level.INSUFFICIENT, r.level)
    }

    @Test
    fun primedWhenSignalsAligned() {
        // Today: HRV well above baseline, resting HR below, load steady.
        val r = ReadinessEngine.evaluate(baseline(todayHrv = 72.0, todayRhr = 46, todayStrain = 10.0))
        assertEquals(ReadinessEngine.Level.PRIMED, r.level)
        assertEquals(ReadinessEngine.Flag.GOOD, r.signals.firstOrNull { it.key == "hrv" }?.flag)
        assertEquals(ReadinessEngine.Flag.GOOD, r.signals.firstOrNull { it.key == "rhr" }?.flag)
        assertEquals(ReadinessEngine.Flag.GOOD, r.signals.firstOrNull { it.key == "acwr" }?.flag)
    }

    @Test
    fun rundownWhenTwoRecoverySignalsDown() {
        // Today: HRV suppressed AND resting HR elevated -> two "bad" recovery signals.
        val r = ReadinessEngine.evaluate(baseline(todayHrv = 50.0, todayRhr = 60, todayStrain = 10.0))
        assertEquals(ReadinessEngine.Level.RUNDOWN, r.level)
    }

    @Test
    fun acwrSpikeStrains() {
        // Recovery signals neutral, but acute load spikes above chronic.
        val days = mutableListOf<DailyMetric>()
        for (i in 1..21) days.add(d(i, hrv = 60.0, rhr = 52, strain = 5.0))
        for (i in 22..28) days.add(d(i, hrv = 60.0, rhr = 52, strain = 15.0))
        days.add(d(29, hrv = 60.0, rhr = 52, strain = 15.0))
        val r = ReadinessEngine.evaluate(days)
        assertEquals(ReadinessEngine.Flag.BAD, r.signals.firstOrNull { it.key == "acwr" }?.flag)
        assertEquals(ReadinessEngine.Level.STRAINED, r.level)
        assertNotNull(r.acwr)
        assertTrue(r.acwr!! > 1.5)
    }

    @Test
    fun respRateRiseFlags() {
        // Today resp rate well above baseline (~14) -> illness-ish watch/bad signal present.
        val r = ReadinessEngine.evaluate(
            baseline(todayHrv = 60.0, todayRhr = 52, todayStrain = 10.0, todayResp = 18.0)
        )
        assertTrue(r.signals.any { it.key == "respRate" })
    }

    @Test
    fun statsHelpers() {
        assertEquals(4.0, ReadinessEngine.mean(listOf(2.0, 4.0, 6.0))!!, 1e-12)
        assertEquals(2.0, ReadinessEngine.sampleSD(listOf(2.0, 4.0, 6.0))!!, 0.0001)
        assertNull(ReadinessEngine.sampleSD(listOf(5.0)))
        assertNull(ReadinessEngine.mean(emptyList()))
    }
}
