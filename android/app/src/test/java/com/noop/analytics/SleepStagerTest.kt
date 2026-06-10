package com.noop.analytics

import com.noop.data.GravitySample
import com.noop.data.HrSample
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Pins SleepStager.detectSleep's session gating — ported from the Swift SleepStagerTests
 * (the gating half) plus the #90 regression pair. Android previously had NO detectSleep
 * coverage; the analytics engines must gate identically on both platforms.
 *
 * The #90 bug: a sedentary daytime hour (still gravity, HR at awake resting) passed the old
 * "not elevated above the day median ×1.05" gate and surfaced as an afternoon "sleep".
 * The fix requires a genuine HR drop below the AWAKE reference (median HR over the day's
 * active periods) when one exists; all-still windows keep the old day-median fallback.
 */
class SleepStagerTest {

    private val dev = "test"

    /** Still gravity stream (constant orientation) at 1 Hz. */
    private fun stillGravity(start: Long, durationS: Int): List<GravitySample> =
        (0 until durationS).map { GravitySample(dev, start + it, 0.0, 0.0, 1.0) }

    /** Active gravity stream (0.5 g jumps per sample — clearly moving) at 1 Hz. */
    private fun activeGravity(start: Long, durationS: Int): List<GravitySample> =
        (0 until durationS).map { i ->
            GravitySample(dev, start + i, (i % 2) * 0.5, 0.0, 1.0)
        }

    private fun hrStream(start: Long, durationS: Int, bpm: Int): List<HrSample> =
        (0 until durationS).map { HrSample(dev, start + it, bpm) }

    @Test
    fun detectSleep_findsStillNight() {
        // 90 min still + low HR (50 bpm) → one sleep session (no active runs → awake
        // reference is null → the day-median fallback gate applies and passes).
        val start = 1_000_000L
        val dur = 90 * 60
        val sessions = SleepStager.detectSleep(
            hr = hrStream(start, dur, 50),
            gravity = stillGravity(start, dur),
        )
        assertEquals(1, sessions.size)
        assertEquals(start, sessions[0].start)
        assertTrue(sessions[0].efficiency > 0.5)
        assertEquals(50, sessions[0].restingHR)
    }

    @Test
    fun detectSleep_rejectsShortBout() {
        // Only 30 min still — below minSleepMin (60) → no session.
        val start = 2_000_000L
        val sessions = SleepStager.detectSleep(
            hr = hrStream(start, 30 * 60, 50),
            gravity = stillGravity(start, 30 * 60),
        )
        assertTrue(sessions.isEmpty())
    }

    @Test
    fun detectSleep_emptyGravity() {
        assertTrue(SleepStager.detectSleep(gravity = emptyList()).isEmpty())
    }

    @Test
    fun detectSleep_hrConfirmationRejectsHighHR() {
        // Still gravity but the 90-min "night" runs at 120 bpm against a 4 h active day at
        // 55 bpm — far above any sleep gate → rejected.
        val start = 3_000_000L
        val dayDur = 4 * 60 * 60
        val sleepDur = 90 * 60
        val sessions = SleepStager.detectSleep(
            hr = hrStream(start, dayDur, 55) + hrStream(start + dayDur, sleepDur, 120),
            gravity = activeGravity(start, dayDur) + stillGravity(start + dayDur, sleepDur),
        )
        assertTrue(sessions.isEmpty())
    }

    @Test
    fun detectSleep_rejectsSedentaryDaytimeHourWithoutHRDrop() {
        // #90 regression: an afternoon hour sitting still in a chair. HR (68) shows NO real
        // drop below the awake reference (median 70 over the active day), so the span must
        // be rejected — under the old day-median ×1.05 gate it passed (68 <= ~73.5).
        val start = 5_000_000L
        val dayDur = 4 * 60 * 60
        val chairDur = 65 * 60
        val sessions = SleepStager.detectSleep(
            hr = hrStream(start, dayDur, 70) + hrStream(start + dayDur, chairDur, 68),
            gravity = activeGravity(start, dayDur) + stillGravity(start + dayDur, chairDur),
        )
        assertTrue(sessions.isEmpty())
    }

    @Test
    fun detectSleep_acceptsRealNapWithHRDrop() {
        // Positive control for the #90 gate: same shape, but the still span shows a genuine
        // HR drop (55 vs awake 70 — well over 5% below), so it still detects.
        val start = 6_000_000L
        val dayDur = 4 * 60 * 60
        val napDur = 65 * 60
        val sessions = SleepStager.detectSleep(
            hr = hrStream(start, dayDur, 70) + hrStream(start + dayDur, napDur, 55),
            gravity = activeGravity(start, dayDur) + stillGravity(start + dayDur, napDur),
        )
        assertEquals(1, sessions.size)
    }

    @Test
    fun detectSleep_keepsLongElevatedHrNight() {
        // A genuine multi-hour night whose sleeping HR sits NEAR awake levels (fever/alcohol —
        // exactly the nights the illness watch needs) must NOT be suppressed by the awake-drop
        // gate: spans >= hrAwakeGateMaxMin keep the original not-elevated day-median gate.
        val start = 7_000_000L
        val dayDur = 4 * 60 * 60
        val nightDur = 7 * 60 * 60
        val sessions = SleepStager.detectSleep(
            hr = hrStream(start, dayDur, 70) + hrStream(start + dayDur, nightDur, 68),
            gravity = activeGravity(start, dayDur) + stillGravity(start + dayDur, nightDur),
        )
        assertEquals(1, sessions.size)
    }

    @Test
    fun awakeHR_medianOverActiveRunsOnly() {
        // The reference comes from HR inside "active" periods only, and is null when an
        // all-still window has no active runs.
        val runs = listOf(
            SleepStager.Period(stage = "active", start = 0, end = 1_000),
            SleepStager.Period(stage = "sleep", start = 1_001, end = 5_000),
        )
        val hr = (0 until 100).map { HrSample(dev, it.toLong(), 70) } +       // active: 70
            (2_000 until 2_100).map { HrSample(dev, it.toLong(), 50) }        // sleep: ignored
        assertEquals(70.0, SleepStager.awakeHR(runs, hr)!!, 1e-9)
        val noActive = listOf(SleepStager.Period(stage = "sleep", start = 0, end = 5_000))
        assertEquals(null, SleepStager.awakeHR(noActive, hr))
    }
}
