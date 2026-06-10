package com.noop.ui

import com.noop.data.WorkoutRow

// MARK: - Manual workout editing / detected-bout helpers (pure, JVM-testable)
//
// All the logic behind the Workouts add/edit/re-label/dismiss flows lives here as plain
// functions (the workoutSourceLabel / recoveryCalibrationNights pattern) so WorkoutEditingTest
// can pin every branch without Robolectric. The composables only collect input and call these.

/** Sports offered by the manual add/edit sheet — names chosen to hit sportIcon's mappings.
 *  Sport names are DATA (stored in the workout table), not UI literals — they stay English. */
internal val MANUAL_SPORTS = listOf(
    "Running", "Cycling", "Walking", "Hiking", "Swimming", "Strength Training", "Yoga",
    "Pilates", "Rowing", "HIIT", "Boxing", "Tennis", "Soccer", "Basketball", "Skiing",
    "Climbing", "Dance", "Golf", "Workout",
)

internal fun isManualWorkout(row: WorkoutRow): Boolean = row.source == "manual"

internal fun isDetectedWorkout(row: WorkoutRow): Boolean =
    row.sport == "detected" && row.deviceId.endsWith("-noop")

/** Sport cell text: the machine token "detected" reads as "Activity". */
internal fun displaySport(sport: String): String = if (sport == "detected") "Activity" else sport

/**
 * Build a retroactive manual workout under the strap source (deviceId "my-whoop", source
 * "manual" — exactly where v1.67's live-tracked sessions live, AppViewModel.endWorkout).
 * Null when the input cannot make an honest row. strain/zones stay null: no captured HR
 * window exists for a retro entry, and APPROXIMATE figures are never fabricated.
 */
internal fun buildManualWorkout(
    startSec: Long,
    durationMin: Int,
    sport: String,
    avgHr: Int? = null,
    energyKcal: Double? = null,
    deviceId: String = "my-whoop",
    nowSec: Long = System.currentTimeMillis() / 1000L,
): WorkoutRow? {
    if (durationMin <= 0 || durationMin > 24 * 60) return null
    if (sport.isBlank()) return null
    if (startSec <= 0 || startSec > nowSec) return null
    if (avgHr != null && avgHr !in 25..250) return null
    if (energyKcal != null && (energyKcal < 0.0 || energyKcal > 20_000.0)) return null
    return WorkoutRow(
        deviceId = deviceId, startTs = startSec, endTs = startSec + durationMin * 60L,
        sport = sport.trim(), source = "manual", durationS = durationMin * 60.0,
        energyKcal = energyKcal, avgHr = avgHr,
    )
}

/**
 * Re-label a detected bout as a real sport: COPY it to the strap source as a manual row (the
 * detected original is deleted by the caller). Survives IntelligenceEngine.analyzeRecent: the
 * engine wipes + re-derives only sport="detected" rows under "-noop" and SKIPS any re-derived
 * bout overlapping a "my-whoop" row (the existing overlap dedupe) — which this copy now is.
 */
internal fun relabeledWorkout(
    detected: WorkoutRow,
    sport: String,
    strapDeviceId: String = "my-whoop",
): WorkoutRow = detected.copy(deviceId = strapDeviceId, sport = sport.trim(), source = "manual")

/** Dismissed-span codec: NoopPrefs stores "startTs:endTs" strings; malformed entries are dropped. */
internal fun parseDismissedSpans(raw: Set<String>): List<Pair<Long, Long>> =
    raw.mapNotNull { s ->
        val i = s.indexOf(':')
        if (i <= 0) return@mapNotNull null
        val a = s.substring(0, i).toLongOrNull() ?: return@mapNotNull null
        val b = s.substring(i + 1).toLongOrNull() ?: return@mapNotNull null
        if (b > a) a to b else null
    }

/** Read-time filter: a detected row overlapping a dismissed span is hidden (the engine
 *  re-derives detected rows each run, so a plain delete would resurrect them). */
internal fun isDismissedDetected(row: WorkoutRow, spans: List<Pair<Long, Long>>): Boolean =
    isDetectedWorkout(row) && spans.any { (s, e) -> row.startTs < e && s < row.endTs }
