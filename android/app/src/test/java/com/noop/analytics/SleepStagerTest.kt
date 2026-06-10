package com.noop.analytics

import com.noop.data.GravitySample
import com.noop.data.HrSample
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Pins SleepStager.detectSleep's base session gating — a port of the Swift SleepStagerTests
 * gating cases (Android previously had NO base detectSleep coverage; the daytime false-sleep
 * guard has its own SleepStagerDaytimeGuardTest). Fixtures mirror the Swift suite, including
 * its overnight anchoring: with the default tzOffsetSeconds = 0, local hour == UTC hour, so a
 * window anchored at 02:00 UTC stays out of the daytime band [11, 20) and never trips the
 * guard — a plain still night must always register regardless of it.
 */
class SleepStagerTest {

    private val dev = "test"

    /** 2026-06-10 00:00:00 UTC (the Swift suite's fixed reference midnight). */
    private val refMidnight = 1_749_513_600L

    private fun startAtHour(hourUtc: Int): Long = refMidnight + hourUtc * 3_600L

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
        // 90 min still + low HR (50 bpm), anchored at 02:00 (center 02:45 — overnight at the
        // default tzOffset, so the daytime guard never applies) → one sleep session.
        val start = startAtHour(2)
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
        // Only 30 min still — below minSleepMin (60) → no session (duration gate, pre-guard).
        val start = startAtHour(2)
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
        // Still gravity but the 90-min overnight "night" runs at 120 bpm against a 4 h active
        // day at 55 bpm: day median ~55, and 120 > 55 × 1.05 → the run is HR-rejected.
        // Anchored so the still span's center stays out of the daytime band.
        val start = startAtHour(17)
        val dayDur = 4 * 60 * 60
        val sleepDur = 90 * 60
        val sessions = SleepStager.detectSleep(
            hr = hrStream(start, dayDur, 55) + hrStream(start + dayDur, sleepDur, 120),
            gravity = activeGravity(start, dayDur) + stillGravity(start + dayDur, sleepDur),
        )
        assertTrue(sessions.isEmpty())
    }
}
