package com.noop.ui

import com.noop.data.DismissedWorkout
import com.noop.data.WorkoutRow

/*
 * WorkoutEditing.kt — pure, Compose-free workout-editing logic (manual add/edit, detected-bout
 * re-label / dismiss). Kotlin mirror of macOS Strand/Data/WorkoutSource.swift, kept free of Room /
 * Compose so the unit test can pin it without an instrumented harness.
 *
 * Android's WorkoutRow carries deviceId; we still classify on `source` to stay byte-for-byte aligned
 * with the macOS read model (which has no deviceId), so a cache moved between platforms classifies
 * the same way.
 */

/** Origin of a workout row, classified from its stored `source` column. */
enum class WorkoutSource { WHOOP, APPLE, DETECTED, MANUAL }

object WorkoutEditing {

    /**
     * Classify a row's origin from its `source`. Order matters: the computed detected source
     * "<id>-noop" also contains "whoop", so the "-noop" suffix is checked FIRST — otherwise a
     * detected bout would read as an imported WHOOP row and become un-dismissable.
     */
    fun classify(source: String): WorkoutSource {
        val s = source.lowercase()
        return when {
            s.endsWith("-noop") -> WorkoutSource.DETECTED // BEFORE whoop: "my-whoop-noop" contains "whoop"
            s == "manual" -> WorkoutSource.MANUAL
            s.contains("whoop") -> WorkoutSource.WHOOP
            else -> WorkoutSource.APPLE
        }
    }

    /** Sport-cell text. The detector stores the machine token "detected"; show it as "Activity". */
    fun displaySport(sport: String): String = if (sport == "detected") "Activity" else sport

    // MARK: - Dismissed detected bouts (durable across re-detection)

    /**
     * Read-time filter: a DETECTED row is hidden when it OVERLAPS any dismissed marker's
     * [startTs, endTs] span. Span-overlap (not an exact-key match) survives the small startTs drift a
     * bout's boundary can take as more HR arrives, matching the macOS dismissed-span semantics exactly.
     * Imported / manual rows are never auto-hidden (the user deletes those outright). Half-open overlap
     * test: `row.start < span.end && span.start < row.end`. (#107)
     */
    fun isDismissed(row: WorkoutRow, markers: List<DismissedWorkout>): Boolean =
        classify(row.source) == WorkoutSource.DETECTED &&
            markers.any { row.startTs < it.endTs && it.startTs < row.endTs }

    /** The durable marker for a detected [row] (caller inserts it into `dismissedWorkout`). */
    fun dismissedMarker(row: WorkoutRow): DismissedWorkout =
        DismissedWorkout(deviceId = row.deviceId, startTs = row.startTs, endTs = row.endTs)

    /**
     * Filter dismissed detected bouts out of a loaded list. Centralised so every caller agrees,
     * exactly like macOS Repository.workoutRows applies the span filter once.
     */
    fun filterDismissed(rows: List<WorkoutRow>, markers: List<DismissedWorkout>): List<WorkoutRow> {
        if (markers.isEmpty()) return rows
        return rows.filter { !isDismissed(it, markers) }
    }

    // MARK: - Building / preserving rows

    /**
     * Carry the captured fields the add/edit sheet does NOT expose (maxHr, strain, distanceM,
     * zonesJSON, notes, routePolyline) over from the row being edited. A live-tracked session has real
     * captured strain/maxHr/route; rebuilding from the sheet's inputs alone would wipe them on an edit.
     * No-op for a fresh add (old == null).
     */
    fun preservingCaptured(row: WorkoutRow, old: WorkoutRow?): WorkoutRow {
        if (old == null) return row
        return row.copy(
            maxHr = old.maxHr,
            strain = old.strain,
            distanceM = old.distanceM,
            zonesJSON = old.zonesJSON,
            notes = old.notes,
            routePolyline = old.routePolyline,
        )
    }

    /**
     * Build a retroactive manual workout (source "manual", written under the strap [deviceId] by the
     * caller — where live sessions land). Returns null when the input can't make an honest row.
     * strain/zones stay null: with no captured HR window an APPROXIMATE strain is never fabricated.
     * Mirrors macOS WorkoutSource.buildManualRow validation bound-for-bound.
     *
     * @param startSeconds workout start, unix seconds.
     * @param nowSeconds wall-clock now (unix seconds); injectable for tests.
     */
    fun buildManualRow(
        deviceId: String,
        startSeconds: Long,
        durationMin: Int,
        sport: String,
        avgHr: Int?,
        energyKcal: Double?,
        nowSeconds: Long = System.currentTimeMillis() / 1000L,
    ): WorkoutRow? {
        if (durationMin <= 0 || durationMin > 24 * 60) return null
        val trimmed = sport.trim()
        if (trimmed.isEmpty() || startSeconds > nowSeconds || startSeconds <= 0) return null
        if (avgHr != null && avgHr !in 25..250) return null
        if (energyKcal != null && (energyKcal < 0 || energyKcal > 20_000)) return null
        return WorkoutRow(
            deviceId = deviceId,
            startTs = startSeconds,
            endTs = startSeconds + durationMin * 60L,
            sport = trimmed,
            source = "manual",
            durationS = durationMin * 60.0,
            energyKcal = energyKcal,
            avgHr = avgHr,
            maxHr = null,
            strain = null,
            distanceM = null,
            zonesJSON = null,
            notes = null,
            routePolyline = null,
        )
    }

    /** Common sports offered when re-labelling a detected bout (the user can fine-tune via Edit). */
    val relabelSports: List<String> = listOf(
        "Running", "Walking", "Cycling", "Strength Training", "Swimming", "Rowing", "Yoga", "HIIT",
    )
}
