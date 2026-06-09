package com.noop.widget

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test

/**
 * Pins the widget push-throttle contract, especially the #82 regression: with live HR streaming,
 * the first heart-rate sample must push IMMEDIATELY (key change), not wait out the refresh window —
 * and unchanged data must still refresh once per window so the displayed HR ticks along.
 */
class PushGateTests {

    private fun snap(
        recovery: Int? = null,
        hr: Int? = null,
        battery: Int? = null,
        connected: Boolean = true,
        at: Long = 0L,
    ) = WidgetSnapshot(recoveryPct = recovery, heartRate = hr, batteryPct = battery, connected = connected, updatedAtMs = at)

    @Before
    fun reset() = PushGate.resetForTest()

    @Test
    fun firstSnapshotIsAdmitted() {
        assertTrue(PushGate.admit(snap(at = 1_000)))
    }

    @Test
    fun unchangedSnapshotWithinWindowIsRejected() {
        PushGate.markPushed(snap(at = 1_000))
        assertFalse(PushGate.admit(snap(at = 2_000)))
    }

    @Test
    fun firstHeartRateSampleIsAdmittedImmediately() {
        // The #82 case: connect-era push had no HR; the moment HR starts streaming the widget must
        // update right away rather than sitting on "—" until the 60s refresh.
        PushGate.markPushed(snap(hr = null, at = 1_000))
        assertTrue(PushGate.admit(snap(hr = 72, at = 2_000)))
    }

    @Test
    fun hrValueChangeAloneWaitsForRefreshWindow() {
        PushGate.markPushed(snap(hr = 72, at = 1_000))
        assertFalse(PushGate.admit(snap(hr = 73, at = 2_000)))            // within window: rejected
        assertTrue(PushGate.admit(snap(hr = 73, at = 1_000 + 60_000)))    // window elapsed: admitted
    }

    @Test
    fun batteryIsBucketedInFivePercentSteps() {
        PushGate.markPushed(snap(battery = 80, at = 1_000))
        assertFalse(PushGate.admit(snap(battery = 82, at = 2_000)))  // same 5% bucket
        assertTrue(PushGate.admit(snap(battery = 86, at = 2_000)))   // bucket changed
    }

    @Test
    fun recoveryChangeIsAdmittedImmediately() {
        PushGate.markPushed(snap(recovery = null, at = 1_000))
        assertTrue(PushGate.admit(snap(recovery = 67, at = 2_000)))
    }

    @Test
    fun connectionFlipIsAdmittedImmediately() {
        PushGate.markPushed(snap(connected = true, at = 1_000))
        assertTrue(PushGate.admit(snap(connected = false, at = 2_000)))
    }
}
