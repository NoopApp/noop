package com.noop.ui

import com.noop.data.WorkoutRow
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Pins every pure helper behind the Workouts add/edit/re-label/dismiss flows
 * (WorkoutEditing.kt). The load-bearing contract is relabeledWorkout's survival property:
 * the copy must land under deviceId "my-whoop" / source "manual" with the span preserved,
 * so IntelligenceEngine's overlap-dedupe suppresses re-derivation of the same bout while
 * the sport="detected" wipe can no longer touch it.
 */
class WorkoutEditingTest {

    @Test
    fun buildManualWorkout_happyPath() {
        val r = buildManualWorkout(
            startSec = 1_000_000, durationMin = 45, sport = " Running ",
            avgHr = 150, energyKcal = 500.0, nowSec = 2_000_000,
        )!!
        assertEquals("my-whoop", r.deviceId)
        assertEquals("manual", r.source)
        assertEquals("Running", r.sport)
        assertEquals(1_000_000L + 45 * 60, r.endTs)
        assertEquals(2700.0, r.durationS!!, 1e-9)
        assertEquals(150, r.avgHr)
        assertNull(r.strain)
        assertNull(r.zonesJSON)
    }

    @Test
    fun buildManualWorkout_rejectsInvalid() {
        assertNull(buildManualWorkout(1_000_000, 0, "Running", nowSec = 2_000_000))        // dur <= 0
        assertNull(buildManualWorkout(1_000_000, 25 * 60, "Running", nowSec = 2_000_000))  // > 24 h
        assertNull(buildManualWorkout(1_000_000, 45, "  ", nowSec = 2_000_000))            // blank sport
        assertNull(buildManualWorkout(3_000_000, 45, "Running", nowSec = 2_000_000))       // future start
        assertNull(buildManualWorkout(0, 45, "Running", nowSec = 2_000_000))               // zero start
        assertNull(buildManualWorkout(1_000_000, 45, "Running", avgHr = 10, nowSec = 2_000_000))
        assertNull(buildManualWorkout(1_000_000, 45, "Running", avgHr = 300, nowSec = 2_000_000))
        assertNull(buildManualWorkout(1_000_000, 45, "Running", energyKcal = -1.0, nowSec = 2_000_000))
        assertNull(buildManualWorkout(1_000_000, 45, "Running", energyKcal = 50_000.0, nowSec = 2_000_000))
    }

    @Test
    fun relabeledWorkout_movesPkKeepsMetrics() {
        val det = WorkoutRow(
            deviceId = "my-whoop-noop", startTs = 10, endTs = 20, sport = "detected",
            source = "my-whoop-noop", durationS = 10.0, energyKcal = 80.0,
            avgHr = 140, maxHr = 170, strain = 9.1,
        )
        val m = relabeledWorkout(det, " Cycling ")
        assertEquals("my-whoop", m.deviceId)
        assertEquals("manual", m.source)
        assertEquals("Cycling", m.sport)
        // Span preserved — this is what keeps the engine's overlap-dedupe suppressing the bout.
        assertEquals(det.startTs, m.startTs)
        assertEquals(det.endTs, m.endTs)
        assertEquals(det.strain, m.strain)
        assertEquals(det.energyKcal, m.energyKcal)
        assertEquals(det.avgHr, m.avgHr)
        assertEquals(det.maxHr, m.maxHr)
    }

    @Test
    fun classificationPredicates() {
        val det = WorkoutRow("my-whoop-noop", 10, 20, "detected", "my-whoop-noop")
        val manual = WorkoutRow("my-whoop", 10, 20, "Running", "manual")
        val imported = WorkoutRow("my-whoop", 10, 20, "Running", "my-whoop")
        assertTrue(isDetectedWorkout(det))
        assertFalse(isDetectedWorkout(manual))
        // sport "detected" under a NON-noop id is not the engine's (defensive).
        assertFalse(isDetectedWorkout(det.copy(deviceId = "my-whoop")))
        assertTrue(isManualWorkout(manual))
        assertFalse(isManualWorkout(imported))
    }

    @Test
    fun dismissedSpans_overlapAndCodec() {
        assertEquals(listOf(100L to 200L), parseDismissedSpans(setOf("100:200", "junk", "5:", ":7", "9:3")))
        val det = WorkoutRow("my-whoop-noop", 150, 250, "detected", "my-whoop-noop")
        assertTrue(isDismissedDetected(det, listOf(100L to 200L)))
        assertFalse(isDismissedDetected(det, listOf(250L to 300L)))  // touching endpoint ≠ overlap
        assertFalse(isDismissedDetected(det, listOf(50L to 150L)))   // touching endpoint ≠ overlap
        val manual = det.copy(deviceId = "my-whoop", sport = "Running", source = "manual")
        assertFalse(isDismissedDetected(manual, listOf(100L to 200L)))  // never hides non-detected
    }

    @Test
    fun displaySport_mapsTokenOnly() {
        assertEquals("Activity", displaySport("detected"))
        assertEquals("Running", displaySport("Running"))
    }

    @Test
    fun preservingCaptured_keepsUnexposedFieldsOnEdit() {
        // A v1.67 live-tracked session has captured strain/maxHr/zones the edit dialog never
        // shows; rebuilding the row from the dialog inputs must not wipe them.
        val live = WorkoutRow(
            "my-whoop", 1_000, 4_000, "Running", "manual",
            durationS = 3_000.0, energyKcal = 420.0, avgHr = 142, maxHr = 171,
            strain = 12.4, distanceM = 5_200.0, zonesJSON = "{\"zone1\":10}", notes = "tempo",
        )
        val rebuilt = buildManualWorkout(
            startSec = 1_000, durationMin = 50, sport = "Cycling",
            avgHr = 140, energyKcal = 400.0, nowSec = 10_000,
        )!!
        val edited = preservingCaptured(rebuilt, live)
        // Dialog-owned fields take the new values…
        assertEquals("Cycling", edited.sport)
        assertEquals(140, edited.avgHr)
        assertEquals(400.0, edited.energyKcal!!, 1e-9)
        // …captured fields survive verbatim.
        assertEquals(171, edited.maxHr)
        assertEquals(12.4, edited.strain!!, 1e-9)
        assertEquals(5_200.0, edited.distanceM!!, 1e-9)
        assertEquals("{\"zone1\":10}", edited.zonesJSON)
        assertEquals("tempo", edited.notes)
        // Fresh add (old == null) stays honest: nothing fabricated.
        val added = preservingCaptured(rebuilt, null)
        assertNull(added.strain)
        assertNull(added.maxHr)
    }
}
