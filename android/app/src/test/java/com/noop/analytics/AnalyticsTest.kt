package com.noop.analytics

import com.noop.data.DailyMetric
import com.noop.data.GravitySample
import com.noop.data.HrSample
import com.noop.data.RrInterval
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class AnalyticsTest {

    // --- Hrv.rmssd ----------------------------------------------------------

    @Test
    fun rmssd_knownVector() {
        // rr = [800, 810, 790, 805, 795]
        // diffs = [10, -20, 15, -10] -> squares = [100, 400, 225, 100]
        // sum = 825, n = 4, mean = 206.25, sqrt(206.25) = 14.361406616...
        val rr = listOf(800, 810, 790, 805, 795)
        assertEquals(14.361406616, Hrv.rmssd(rr), 1e-6)
    }

    @Test
    fun rmssd_constantIntervalsIsZero() {
        assertEquals(0.0, Hrv.rmssd(listOf(1000, 1000, 1000)), 1e-12)
    }

    @Test
    fun rmssd_tooFewSamplesIsZero() {
        assertEquals(0.0, Hrv.rmssd(emptyList()), 1e-12)
        assertEquals(0.0, Hrv.rmssd(listOf(1000)), 1e-12)
    }

    @Test
    fun rmssd_twoSamples() {
        // diff = 50 -> square = 2500 -> mean = 2500 -> sqrt = 50
        assertEquals(50.0, Hrv.rmssd(listOf(900, 950)), 1e-9)
    }

    // --- Zones --------------------------------------------------------------

    @Test
    fun zone_ladder() {
        val max = 190
        assertEquals(5, Zones.zone((max * 0.95).toInt(), max))  // 180 -> 0.947 -> z5
        assertEquals(4, Zones.zone((max * 0.82).toInt(), max))  // 155 -> 0.815 -> z4
        assertEquals(3, Zones.zone((max * 0.72).toInt(), max))  // 136 -> 0.715 -> z3
        assertEquals(2, Zones.zone((max * 0.62).toInt(), max))  // 117 -> 0.615 -> z2
        assertEquals(1, Zones.zone((max * 0.50).toInt(), max))  // 95  -> 0.5   -> z1
    }

    @Test
    fun zone_exactBoundaries() {
        // hrMax = 100 makes pct == hr/100 exactly.
        assertEquals(5, Zones.zone(90, 100))
        assertEquals(4, Zones.zone(80, 100))
        assertEquals(3, Zones.zone(70, 100))
        assertEquals(2, Zones.zone(60, 100))
        assertEquals(1, Zones.zone(59, 100))
    }

    @Test
    fun zone_invalidMaxFallsBackToZoneOne() {
        assertEquals(1, Zones.zone(120, 0))
        assertEquals(1, Zones.zone(120, -10))
    }

    @Test
    fun hrMaxTanaka_roundsCorrectly() {
        // 208 - 0.7*30 = 187.0 -> 187
        assertEquals(187, Zones.hrMaxTanaka(30))
        // 208 - 0.7*25 = 190.5 -> 191 (round half up)
        assertEquals(191, Zones.hrMaxTanaka(25))
        // 208 - 0.7*45 = 176.5 -> 177
        assertEquals(177, Zones.hrMaxTanaka(45))
    }

    // --- IllnessWatch -------------------------------------------------------

    private fun day(
        d: String,
        restingHr: Int? = null,
        avgHrv: Double? = null,
        skinTempDevC: Double? = null,
        respRateBpm: Double? = null,
    ): DailyMetric = DailyMetric(
        deviceId = "test",
        day = d,
        restingHr = restingHr,
        avgHrv = avgHrv,
        skinTempDevC = skinTempDevC,
        respRateBpm = respRateBpm,
    )

    @Test
    fun illness_tooFewDaysReturnsNull() {
        val days = (0 until 10).map { day("2026-01-%02d".format(it + 1), restingHr = 50, avgHrv = 60.0) }
        assertNull(IllnessWatch.evaluate(days))
    }

    @Test
    fun illness_clearBaselineReturnsNull() {
        // 31 stable days: recent == baseline, no anomalies.
        val days = (0 until 31).map {
            day("2026-01-%02d".format(it + 1), restingHr = 50, avgHrv = 60.0, skinTempDevC = 0.0, respRateBpm = 14.0)
        }
        assertNull(IllnessWatch.evaluate(days))
    }

    @Test
    fun illness_twoFlagsRaisesBanner() {
        // 31 calm days, then 2 strained recent days appended (33 total).
        // evaluate() uses takeLast(2) as recent and takeLast(31).dropLast(3) as baseline,
        // so the 2 strained days are "recent" and the calm days form the baseline.
        val baseline = (0 until 31).map {
            day("2026-01-%02d".format(it + 1), restingHr = 50, avgHrv = 60.0, skinTempDevC = 0.0, respRateBpm = 14.0)
        }
        val recent = listOf(
            // RHR +8, HRV -25% (45/60), skin temp +0.8 -> three flags
            day("2026-02-01", restingHr = 58, avgHrv = 45.0, skinTempDevC = 0.8, respRateBpm = 14.0),
            day("2026-02-02", restingHr = 58, avgHrv = 45.0, skinTempDevC = 0.8, respRateBpm = 14.0),
        )
        val days = baseline + recent
        val msg = IllnessWatch.evaluate(days)
        assertNotNull(msg)
        assertTrue(msg!!.contains("resting HR"))
        assertTrue(msg.contains("HRV"))
        assertTrue(msg.contains("skin temp"))
    }

    @Test
    fun illness_singleFlagReturnsNull() {
        // Only resting HR elevated in the recent 2 days -> one flag -> null.
        val baseline = (0 until 31).map {
            day("2026-01-%02d".format(it + 1), restingHr = 50, avgHrv = 60.0, skinTempDevC = 0.0, respRateBpm = 14.0)
        }
        val recent = listOf(
            day("2026-02-01", restingHr = 60, avgHrv = 60.0, skinTempDevC = 0.0, respRateBpm = 14.0),
            day("2026-02-02", restingHr = 60, avgHrv = 60.0, skinTempDevC = 0.0, respRateBpm = 14.0),
        )
        assertNull(IllnessWatch.evaluate(baseline + recent))
    }

    @Test
    fun illness_noisyRsaRespSingleOffNightDoesNotFire() {
        // Baseline resp ~15 bpm with realistic RSA night-to-night noise (alternating 14/16, sd>0),
        // stable RHR/HRV/skin-temp so resp is the ONLY candidate flag. Recent two days: one quiet
        // night at baseline and one +3 bpm RSA spike -> recent 2-day mean ~16.5, only ~+1.5 over
        // baseline ~15, below the +2.5 margin -> resp must NOT flag, so evaluate() returns null.
        val baseline = (0 until 31).map {
            day(
                "2026-01-%02d".format(it + 1),
                restingHr = 50, avgHrv = 60.0, skinTempDevC = 0.0,
                respRateBpm = if (it % 2 == 0) 14.0 else 16.0,
            )
        }
        val recent = listOf(
            day("2026-02-01", restingHr = 50, avgHrv = 60.0, skinTempDevC = 0.0, respRateBpm = 15.0),
            day("2026-02-02", restingHr = 50, avgHrv = 60.0, skinTempDevC = 0.0, respRateBpm = 18.0),
        )
        assertNull(IllnessWatch.evaluate(baseline + recent))
    }

    @Test
    fun illness_sustainedRespRiseStillFires() {
        // Same ~15 bpm plausible baseline, but BOTH recent nights are genuinely elevated (~18.5),
        // ~+3.5 over baseline (>= +2.5 margin) -> resp flags. Paired with an elevated RHR so two
        // flags fire and a banner is produced; assert it mentions respiration.
        val baseline = (0 until 31).map {
            day(
                "2026-01-%02d".format(it + 1),
                restingHr = 50, avgHrv = 60.0, skinTempDevC = 0.0,
                respRateBpm = if (it % 2 == 0) 14.0 else 16.0,
            )
        }
        val recent = listOf(
            day("2026-02-01", restingHr = 58, avgHrv = 60.0, skinTempDevC = 0.0, respRateBpm = 18.0),
            day("2026-02-02", restingHr = 58, avgHrv = 60.0, skinTempDevC = 0.0, respRateBpm = 19.0),
        )
        val msg = IllnessWatch.evaluate(baseline + recent)
        assertNotNull(msg)
        assertTrue(msg!!.contains("respiration"))
    }

    @Test
    fun illness_implausibleRespOutlierDoesNotFire() {
        // Degenerate RSA windows can yield implausible resp values. A baseline ~15 with recent
        // nights pinned at ~35 bpm (outside the 8-25 sanity band) must NOT fire the resp flag.
        val baseline = (0 until 31).map {
            day(
                "2026-01-%02d".format(it + 1),
                restingHr = 50, avgHrv = 60.0, skinTempDevC = 0.0,
                respRateBpm = if (it % 2 == 0) 14.0 else 16.0,
            )
        }
        val recent = listOf(
            day("2026-02-01", restingHr = 50, avgHrv = 60.0, skinTempDevC = 0.0, respRateBpm = 35.0),
            day("2026-02-02", restingHr = 50, avgHrv = 60.0, skinTempDevC = 0.0, respRateBpm = 35.0),
        )
        assertNull(IllnessWatch.evaluate(baseline + recent))
    }

    // --- sessionAvgHRV ectopic cleaning (#262/#235) -------------------------

    @Test
    fun sessionAvgHrv_rejectsEctopicSpikes() {
        // A 5-min window of steady ~900 ms beats (≈67 bpm) with a +600 ms ectopic
        // spike every 15th beat — the shape of PPG-derived 0x2A37 RR on a WHOOP 5/MG.
        // rMSSD is built from SUCCESSIVE differences, so the spikes would inflate the
        // session HRV if left in. cleanRR's Malik ectopic rejection drops them, so the
        // cleaned series is steady → HRV ≈ 0. Pre-fix (rangeFilter only) this path
        // returned ~200 ms; this guards against regression.
        val start = 1000L
        val end = start + 300
        val rr = (0 until 300).map { i ->
            RrInterval(deviceId = "d", ts = start + i, rrMs = if (i % 15 == 0) 1500 else 900)
        }
        val hrv = SleepStager.sessionAvgHRV(start, end, rr)
        assertNotNull(hrv)
        assertTrue("ectopic spikes must be rejected before rMSSD", hrv!! < 50.0)
    }

    // --- #304 sleep day-boundary attribution --------------------------------

    /**
     * Regression for #304: a night that falls asleep before midnight and wakes in the small hours
     * must attribute to the LOCAL day its wake falls on — even when that wake crosses UTC midnight,
     * so the UTC end-day is a different calendar date. With the device offset supplied, the night is
     * counted ONCE on the local day (the day the dashboard's logical day surfaces) with its real
     * duration — not dropped onto the adjacent UTC day where it bled into / was hidden behind the
     * previous night. Mirrors AnalyticsEngineTests.testAnalyzeDayAttributesPreMidnightNightToLocalWakeDay.
     */
    @Test
    fun analyzeDay_attributesPreMidnightNightToLocalWakeDay() {
        // Sydney (UTC+10). Onset 23:30 on the 14th LOCAL, wake 03:30 on the 15th LOCAL (before the
        // 04:00 logical-day rollover). In UTC the wake is 17:30 on the 14th, so the UTC end-day (14th)
        // differs from the LOCAL end-day (15th) — the exact split that misfiled the night pre-fix.
        val offset = 10 * 3_600L
        // 2026-06-14 00:00:00 UTC. Anchor the night off this fixed midnight so the wake (17:30 UTC on
        // the 14th) is a deterministic epoch, independent of the host timezone. The session center then
        // sits at ~01:30 LOCAL — outside the [11,20) daytime band — so the overnight path is taken.
        val utc20260614 = 1_781_395_200L
        val wakeUtc = utc20260614 + 17 * 3_600L + 30 * 60L     // 17:30 UTC on the 14th
        val onsetUtc = wakeUtc - 4 * 3_600L                     // 4 h earlier (23:30 local on the 14th)

        // Sanity: the UTC end-day and the LOCAL end-day really are different calendar dates.
        assertEquals("2026-06-14", AnalyticsEngine.dayString(wakeUtc))
        assertEquals("2026-06-15", AnalyticsEngine.dayString(wakeUtc, offset))

        // Still, low-HR night with oscillating RR (avoids ectopic rejection), 1 Hz streams.
        val hr = (onsetUtc until wakeUtc).map { HrSample(deviceId = "d", ts = it, bpm = 50) }
        val grav = (onsetUtc until wakeUtc).map { GravitySample(deviceId = "d", ts = it, x = 0.0, y = 0.0, z = 1.0) }
        val rr = ArrayList<RrInterval>()
        var t = onsetUtc
        var toggle = false
        while (t < wakeUtc) {
            rr.add(RrInterval(deviceId = "d", ts = t, rrMs = if (toggle) 1205 else 1195))
            toggle = !toggle
            t += 2
        }
        val profile = UserProfile(weightKg = 75.0, heightCm = 178.0, age = 30.0, sex = "male")

        // Attributed to the LOCAL wake-day (15th) when the offset is supplied: ONE session, ~4 h.
        val onLocalDay = AnalyticsEngine.analyzeDay(
            day = "2026-06-15", hr = hr, rr = rr, gravity = grav,
            profile = profile, tzOffsetSeconds = offset,
        )
        assertEquals("2026-06-15", onLocalDay.daily.day)
        assertEquals(1, onLocalDay.sleepSessions.size)
        assertNotNull(onLocalDay.daily.totalSleepMin)
        assertEquals(4.0 * 60, onLocalDay.daily.totalSleepMin!!, 60.0)  // ~4 h in bed, slack for trimming

        // And NOT onto the UTC end-day (14th): asking for the 14th with the same offset finds nothing,
        // so the night can no longer surface on the wrong day / behind the previous night (#304).
        val onUtcDay = AnalyticsEngine.analyzeDay(
            day = "2026-06-14", hr = hr, rr = rr, gravity = grav,
            profile = profile, tzOffsetSeconds = offset,
        )
        assertEquals(0, onUtcDay.sleepSessions.size)
        assertNull(onUtcDay.daily.totalSleepMin)
    }
}
