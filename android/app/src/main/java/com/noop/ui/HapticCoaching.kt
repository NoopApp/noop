package com.noop.ui

// MARK: - Haptic-coaching decision logic (pure, JVM-testable)
//
// Ports of macOS AppModel.coachZone / AppModel.evaluateStress / AppModel.rmssd, split into
// plain functions (the workoutSourceLabel / WorkoutEditing pattern) so HapticCoachingTest can
// pin every branch without Robolectric. AppViewModel only collects input and calls these.

/** Current zone 1…5 from %HR-max (WHOOP/Karvonen-style bands: 50/60/70/80/90). */
internal fun coachZoneFor(hr: Int, maxHR: Double): Int {
    val pct = hr / maxHR
    return when {
        pct >= 0.9 -> 5
        pct >= 0.8 -> 4
        pct >= 0.7 -> 3
        pct >= 0.6 -> 2
        else -> 1
    }
}

/**
 * Buzz loops for a zone transition, or null for no buzz: 3 loops on entering the top zone
 * (ease off), 1 loop on dropping back to recovery. `previous == -1` (no prior zone — first
 * sample after enable/connect) never buzzes; nor does staying in the same zone.
 */
internal fun zoneTransitionBuzz(previous: Int, zone: Int): Int? = when {
    previous == -1 || zone == previous -> null
    zone == 5 && previous < 5 -> 3
    zone <= 1 && previous > 1 -> 1
    else -> null
}

/** RMSSD (ms) over an R-R window. Port of macOS AppModel.rmssd. */
internal fun rmssdOf(rr: List<Int>): Double {
    if (rr.size < 2) return 0.0
    var sum = 0.0
    var n = 0
    for (i in 1 until rr.size) {
        val d = (rr[i] - rr[i - 1]).toDouble()
        sum += d * d
        n += 1
    }
    return if (n > 0) kotlin.math.sqrt(sum / n) else 0.0
}

/**
 * Should the resting stress nudge fire? Conservative on purpose (it rarely false-fires):
 * RMSSD well below the slow baseline (×0.6) while HR sits in the resting band (55–100 —
 * not a workout), rate-limited to once per 15 minutes. Port of macOS evaluateStress's gate.
 */
internal fun stressNudgeShouldFire(
    rmssd: Double,
    baseline: Double,
    bpm: Int?,
    sinceLastBuzzMs: Long,
): Boolean {
    if (rmssd <= 0.0 || baseline <= 0.0) return false
    if (bpm == null || bpm < 55 || bpm > 100) return false
    if (sinceLastBuzzMs <= 900_000L) return false
    return rmssd < baseline * 0.6
}
