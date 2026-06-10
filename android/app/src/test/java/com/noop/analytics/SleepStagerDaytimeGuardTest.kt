package com.noop.analytics

import com.noop.data.GravitySample
import com.noop.data.HrSample
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Tests SleepStager's daytime false-sleep guard (#90). A long, still, sedentary daytime
 * stretch is gravity-indistinguishable from a real nap, so the gravity spine alone
 * misclassifies it as sleep. The guard holds a window whose CENTER falls in the local
 * daytime band [11,20) to a stricter bar — ≥ daytimeMinSleepMin (90 min) AND a genuine
 * resting-HR dip below the day baseline. Overnight windows are UNCHANGED.
 *
 * Faithful Kotlin mirror of the daytime-guard cases in SleepStagerTests.swift; same
 * reference midnight, same thresholds, same scenarios.
 */
class SleepStagerDaytimeGuardTest {

    private val dev = "test"

    /** 2025-06-10 00:00:00 UTC — an arbitrary fixed midnight (ref % 86400 == 0). */
    private val refMidnight = 1_749_513_600L

    /** Unix start at `hourUTC:00:00` on the reference day. With the detector's default
     *  tzOffset=0, local hour == UTC hour. */
    private fun startAtHour(hourUTC: Int): Long = refMidnight + hourUTC * 3_600L

    /** Still gravity (constant orientation) at 1 Hz. */
    private fun stillGravity(start: Long, durationS: Int): List<GravitySample> =
        (0 until durationS).map { GravitySample(deviceId = dev, ts = start + it, x = 0.0, y = 0.0, z = 1.0) }

    /** Active gravity (0.5 g oscillation per sample → clearly moving) at 1 Hz. */
    private fun activeGravity(start: Long, durationS: Int): List<GravitySample> =
        (0 until durationS).map { i ->
            val phase = (i % 2) * 0.5
            GravitySample(deviceId = dev, ts = start + i, x = phase, y = 0.0, z = 1.0)
        }

    private fun hrStream(start: Long, durationS: Int, bpm: Int): List<HrSample> =
        (0 until durationS).map { HrSample(deviceId = dev, ts = start + it, bpm = bpm) }

    @Test
    fun daytimeShortLowHRWindowRejected() {
        // 3 h active context (HR 72) lifts the day HR baseline so the HR test would PASS;
        // the 70-min daytime still window is then rejected purely by the < 90 min gate.
        val dayStart = startAtHour(10)
        val dayDur = 3 * 60 * 60
        val dayGrav = activeGravity(dayStart, dayDur)
        val dayHR = hrStream(dayStart, dayDur, 72)

        val napStart = dayStart + dayDur // 13:00, center 13:35 → daytime band
        val napDur = 70 * 60 // 70 min < 90 min daytime minimum
        val napGrav = stillGravity(napStart, napDur)
        val napHR = hrStream(napStart, napDur, 50)

        val sessions = SleepStager.detectSleep(hr = dayHR + napHR, gravity = dayGrav + napGrav)
        assertTrue("a 70-min daytime still window must be rejected by the guard", sessions.isEmpty())
    }

    @Test
    fun daytimeQualityNapRegisters() {
        // A 120-min daytime nap with a real HR dip (50 vs ~72 baseline) STILL registers.
        val dayStart = startAtHour(10)
        val dayDur = 3 * 60 * 60
        val dayGrav = activeGravity(dayStart, dayDur)
        val dayHR = hrStream(dayStart, dayDur, 72)

        val napStart = dayStart + dayDur // 13:00, center 14:00 → daytime band
        val napDur = 120 * 60 // 120 min ≥ 90 min daytime minimum
        val napGrav = stillGravity(napStart, napDur)
        val napHR = hrStream(napStart, napDur, 50)

        val sessions = SleepStager.detectSleep(hr = dayHR + napHR, gravity = dayGrav + napGrav)
        assertEquals("a 120-min daytime nap with a real HR dip must register", 1, sessions.size)
        // The run begins at/just after the active→still transition (rolling stillness window
        // shifts the boundary a few minutes); its center stays firmly in the daytime band.
        assertTrue(sessions[0].start >= napStart)
        assertTrue(sessions[0].start < napStart + 10 * 60)
        assertEquals(50, sessions[0].restingHR)
    }

    @Test
    fun overnightShortWindowUnchanged() {
        // A 70-min still, low-HR OVERNIGHT window (center ≈03:35, out of band) registers
        // unchanged — only the base 60-min minimum gates it, exactly as before the guard.
        val dayStart = startAtHour(0) // 00:00 active context so a baseline exists
        val dayDur = 3 * 60 * 60
        val dayGrav = activeGravity(dayStart, dayDur)
        val dayHR = hrStream(dayStart, dayDur, 72)

        val sleepStart = dayStart + dayDur // 03:00, center 03:35 → overnight
        val sleepDur = 70 * 60 // 70 min > 60 min base minimum
        val sleepGrav = stillGravity(sleepStart, sleepDur)
        val sleepHR = hrStream(sleepStart, sleepDur, 50)

        val sessions = SleepStager.detectSleep(hr = dayHR + sleepHR, gravity = dayGrav + sleepGrav)
        assertEquals("a 70-min overnight still window must register unchanged", 1, sessions.size)
        assertTrue(sessions[0].start >= sleepStart)
        assertTrue(sessions[0].start < sleepStart + 10 * 60)
    }

    @Test
    fun tzOffsetShiftsWindowIntoDaytimeBand() {
        // The SAME absolute 70-min still window is overnight at tzOffset=0 (registers) but
        // daytime under a +10 h offset (center ≈12:35); with no awake baseline the daytime
        // path can't confirm a dip → rejected. Pins the offset-awareness end-to-end.
        val start = startAtHour(2) // 02:00 UTC, center 02:35
        val dur = 70 * 60
        val grav = stillGravity(start, dur)
        val hr = hrStream(start, dur, 50)

        assertEquals(1, SleepStager.detectSleep(hr = hr, gravity = grav).size)
        val shifted = SleepStager.detectSleep(hr = hr, gravity = grav, tzOffsetSeconds = 10 * 3_600L)
        assertTrue("a +10h offset pushes the window into the daytime band → rejected", shifted.isEmpty())
    }

    @Test
    fun daytimeGuardEmptyInputsNoCrash() {
        // A still daytime stretch with NO HR (baseline null) must return [] cleanly — the
        // daytime path rejects without touching any HR array. Guards the index-out-of-range
        // crash class from the prior attempt.
        val start = startAtHour(13)
        val grav = stillGravity(start, 120 * 60)
        assertTrue(SleepStager.detectSleep(gravity = grav).isEmpty())

        // The pure band/guard helpers tolerate a degenerate zero-length period.
        val p = SleepStager.Period(stage = "sleep", start = start, end = start)
        SleepStager.isDaytimeCenter(p, 0L)
        assertFalse(SleepStager.passesDaytimeGuard(p, null, null))
    }
}
