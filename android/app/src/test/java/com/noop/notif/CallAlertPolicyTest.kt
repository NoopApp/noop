package com.noop.notif

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class CallAlertPolicyTest {
    private val policy = CallAlertPolicy(repeatIntervalMs = 8_000L, maxBuzzes = 4)

    @Test
    fun buzzesImmediatelyForActiveCall() {
        assertTrue(policy.shouldBuzz(active = true, buzzCount = 0, lastBuzzAtMs = null, nowMs = 1_000L))
    }

    @Test
    fun throttlesUntilRepeatInterval() {
        assertFalse(policy.shouldBuzz(active = true, buzzCount = 1, lastBuzzAtMs = 1_000L, nowMs = 8_999L))
        assertTrue(policy.shouldBuzz(active = true, buzzCount = 1, lastBuzzAtMs = 1_000L, nowMs = 9_000L))
    }

    @Test
    fun stopsAfterMaxBuzzesOrInactiveCall() {
        assertFalse(policy.shouldBuzz(active = true, buzzCount = 4, lastBuzzAtMs = 1_000L, nowMs = 20_000L))
        assertFalse(policy.shouldBuzz(active = false, buzzCount = 0, lastBuzzAtMs = null, nowMs = 1_000L))
        assertEquals(null, policy.nextDelayMs(buzzCount = 4))
    }
}
