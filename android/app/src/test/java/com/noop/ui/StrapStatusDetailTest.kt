package com.noop.ui

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Guards the Settings → Strap status detail copy, in particular that an in-flight scan takes
 * precedence over bonded/connected so the user gets "Searching…" feedback the moment Re-scan is
 * tapped (issue #1). The button's `enabled = !live.scanning` relies on the same scanning flag, so
 * a regression here is the visible half of "Re-scan does nothing".
 */
class StrapStatusDetailTest {

    @Test
    fun scanning_takesPrecedence_overEveryOtherState() {
        // Even when already bonded + connected, an active scan must say "Searching…".
        assertTrue(
            strapStatusDetail(bonded = true, connected = true, scanning = true)
                .startsWith("Searching for your WHOOP"),
        )
        assertTrue(
            strapStatusDetail(bonded = false, connected = false, scanning = true)
                .startsWith("Searching for your WHOOP"),
        )
    }

    @Test
    fun nonScanning_branches_areUnchanged() {
        assertEquals(
            "Your strap is paired and sending data. Open Live for a real-time heart rate.",
            strapStatusDetail(bonded = true, connected = true, scanning = false),
        )
        assertEquals(
            "Connected. Finishing the secure pairing handshake…",
            strapStatusDetail(bonded = false, connected = true, scanning = false),
        )
        assertEquals(
            "Previously paired but not currently connected. Re-scan to reconnect.",
            strapStatusDetail(bonded = true, connected = false, scanning = false),
        )
        assertEquals(
            "No strap connected. Put your WHOOP nearby and tap Re-scan to pair.",
            strapStatusDetail(bonded = false, connected = false, scanning = false),
        )
    }
}
