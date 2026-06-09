package com.noop.notif

/**
 * Small pure policy for repeated call buzzes. The controller owns Android scheduling;
 * this object keeps the cadence testable.
 */
internal data class CallAlertPolicy(
    val repeatIntervalMs: Long = 8_000L,
    val maxBuzzes: Int = 4,
) {
    fun shouldBuzz(active: Boolean, buzzCount: Int, lastBuzzAtMs: Long?, nowMs: Long): Boolean {
        if (!active || buzzCount >= maxBuzzes) return false
        return lastBuzzAtMs == null || nowMs - lastBuzzAtMs >= repeatIntervalMs
    }

    fun nextDelayMs(buzzCount: Int): Long? =
        if (buzzCount < maxBuzzes) repeatIntervalMs else null
}
