package com.noop.ui

import org.junit.Assert.assertEquals
import org.junit.Test

class SettingsStatusTest {

    @Test
    fun strapStatus_showsSearchingWhileRescanRunsEvenWhenAlreadyConnected() {
        assertEquals(
            "Searching...",
            strapStatusTitle(bonded = true, connected = true, scanning = true),
        )
        assertEquals(
            "Scanning for your WHOOP. Keep the strap nearby and leave NOOP open.",
            strapStatusDetail(bonded = true, connected = true, scanning = true),
        )
    }
}
