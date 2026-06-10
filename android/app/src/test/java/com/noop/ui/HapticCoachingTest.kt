package com.noop.ui

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Pins the haptic-coaching decision logic (HapticCoaching.kt) — the pure halves of the macOS
 * AppModel.coachZone / evaluateStress / rmssd port, value-for-value, so the two platforms
 * buzz on the same transitions.
 */
class HapticCoachingTest {

    @Test
    fun coachZoneFor_karvonenBands() {
        val max = 200.0
        assertEquals(1, coachZoneFor(100, max))   // 50%
        assertEquals(1, coachZoneFor(119, max))   // <60%
        assertEquals(2, coachZoneFor(120, max))   // 60%
        assertEquals(3, coachZoneFor(140, max))   // 70%
        assertEquals(4, coachZoneFor(160, max))   // 80%
        assertEquals(5, coachZoneFor(180, max))   // 90%
        assertEquals(5, coachZoneFor(200, max))
    }

    @Test
    fun zoneTransitionBuzz_topZoneAndRecoveryOnly() {
        assertNull(zoneTransitionBuzz(previous = -1, zone = 5))   // first sample never buzzes
        assertNull(zoneTransitionBuzz(previous = 3, zone = 3))    // same zone
        assertEquals(3, zoneTransitionBuzz(previous = 4, zone = 5))  // entered max — ease off
        assertNull(zoneTransitionBuzz(previous = 5, zone = 4))    // leaving max alone is silent
        assertEquals(1, zoneTransitionBuzz(previous = 3, zone = 1))  // recovered
        assertNull(zoneTransitionBuzz(previous = 1, zone = 2))    // mid-band wandering is silent
        assertNull(zoneTransitionBuzz(previous = 5, zone = 5))
    }

    @Test
    fun rmssd_matchesDefinition() {
        // Successive diffs 10, -10 → mean square = 100 → rmssd = 10. Mirrors macOS AppModel.rmssd.
        assertEquals(10.0, rmssdOf(listOf(1000, 1010, 1000)), 1e-9)
        assertEquals(0.0, rmssdOf(listOf(1000)), 1e-9)
        assertEquals(0.0, rmssdOf(emptyList()), 1e-9)
    }

    @Test
    fun stressNudge_firesOnlyInTheRestingBandWithRealDropAndRateLimit() {
        // Genuine drop (rmssd 20 vs baseline 50 = 0.4 < 0.6), calm HR, rate limit elapsed.
        assertTrue(stressNudgeShouldFire(rmssd = 20.0, baseline = 50.0, bpm = 70, sinceLastBuzzMs = 1_000_000))
        // No real drop.
        assertFalse(stressNudgeShouldFire(rmssd = 40.0, baseline = 50.0, bpm = 70, sinceLastBuzzMs = 1_000_000))
        // Exercising / out of the resting band.
        assertFalse(stressNudgeShouldFire(rmssd = 20.0, baseline = 50.0, bpm = 120, sinceLastBuzzMs = 1_000_000))
        assertFalse(stressNudgeShouldFire(rmssd = 20.0, baseline = 50.0, bpm = 50, sinceLastBuzzMs = 1_000_000))
        assertFalse(stressNudgeShouldFire(rmssd = 20.0, baseline = 50.0, bpm = null, sinceLastBuzzMs = 1_000_000))
        // Rate-limited (15 min).
        assertFalse(stressNudgeShouldFire(rmssd = 20.0, baseline = 50.0, bpm = 70, sinceLastBuzzMs = 60_000))
        // No baseline yet.
        assertFalse(stressNudgeShouldFire(rmssd = 20.0, baseline = 0.0, bpm = 70, sinceLastBuzzMs = 1_000_000))
    }
}
