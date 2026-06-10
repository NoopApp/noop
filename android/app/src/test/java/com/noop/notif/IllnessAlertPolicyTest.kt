package com.noop.notif

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Unit tests for [IllnessAlertPolicy], the pure once-per-local-day gate behind the illness
 * early-warning notification (CallAlertPolicy test idiom). The gate is persisted, so the two
 * call sites (app-open AppViewModel + background WhoopConnectionService) can never double-post.
 */
class IllnessAlertPolicyTest {

    @Test
    fun nullAlertNeverNotifies() {
        assertFalse(IllnessAlertPolicy.shouldNotify(null, null, "2026-06-10"))
        assertFalse(IllnessAlertPolicy.shouldNotify(null, "2026-06-09", "2026-06-10"))
    }

    @Test
    fun firstAlertOfTheDayNotifies() {
        assertTrue(IllnessAlertPolicy.shouldNotify("strained", null, "2026-06-10"))
        assertTrue(IllnessAlertPolicy.shouldNotify("strained", "2026-06-09", "2026-06-10"))
    }

    @Test
    fun sameDayRepeatIsSuppressed() {
        assertFalse(IllnessAlertPolicy.shouldNotify("strained", "2026-06-10", "2026-06-10"))
    }
}
