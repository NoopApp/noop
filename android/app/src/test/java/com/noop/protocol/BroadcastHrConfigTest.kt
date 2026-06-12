package com.noop.protocol

import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * Golden test for the "Broadcast HR" device-config write — the strap is made to advertise its heart
 * rate as a standard BLE HR sensor (0x180D + live HR in the advertisement) by setting the device
 * config whoop_live_hr_in_adv_ind_pkt via SET_DEVICE_CONFIG (0x77). The body is the key name ASCII
 * NUL-padded to 32 bytes, then the value byte (ASCII digit) — 33 bytes, no trailing padding.
 * Validated on real hardware (paired on a Garmin Edge 840).
 */
class BroadcastHrConfigTest {
    @Test
    fun deviceConfigBodyIsNameNullPaddedThenAsciiValue() {
        val body = Whoop5Config.deviceConfigBody("whoop_live_hr_in_adv_ind_pkt", 0x31)
        assertEquals(33, body.size)
        assertEquals(
            "whoop_live_hr_in_adv_ind_pkt",
            body.copyOfRange(0, 28).toString(Charsets.US_ASCII),
        )
        for (i in 28 until 32) assertEquals("null pad @$i", 0, body[i].toInt())
        assertEquals("ASCII '1' value @32", '1'.code, body[32].toInt())
    }

    @Test
    fun disableUsesAsciiZero() {
        assertEquals('0'.code, Whoop5Config.deviceConfigBody("whoop_live_hr_in_adv_ind_pkt", 0x30)[32].toInt())
    }
}
