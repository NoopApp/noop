package com.noop.ui

import com.noop.data.WorkoutRow
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/**
 * Pins the Workouts HR-zone card's parsing/aggregation to the real stored shapes:
 *   - WhoopCsvImporter.zonesJson → {"zone1".."zone5"} (this platform's own rows)
 *   - the macOS importer/backfill → {"z1".."z5"} (same data, other platform's key shape)
 * Percentages are 0–100 of each workout's duration and may sum to less than 100
 * (below-Z1 time is not exported).
 */
class WorkoutZonesTest {

    @Test
    fun parsesAndroidKeyShape() {
        assertEquals(
            listOf(10.0, 20.0, 30.0, 25.0, 15.0),
            parseZonePercents("""{"zone1":10.0,"zone2":20.0,"zone3":30.0,"zone4":25.0,"zone5":15.0}"""),
        )
    }

    @Test
    fun parsesMacKeyShape_missingZonesAreZero() {
        assertEquals(listOf(12.5, 0.0, 0.0, 0.0, 4.5), parseZonePercents("""{"z1":12.5,"z5":4.5}"""))
    }

    @Test
    fun rejectsNullBlankEmptyAndAllZero() {
        assertNull(parseZonePercents(null))
        assertNull(parseZonePercents(""))
        assertNull(parseZonePercents("{}"))
        assertNull(parseZonePercents("""{"zone1":0}"""))
    }

    @Test
    fun summaryIsDurationWeighted_andSkipsZonelessRows() {
        fun row(start: Long, durS: Double, zones: String?) = WorkoutRow(
            deviceId = "my-whoop", startTs = start, endTs = start + durS.toLong(),
            sport = "Running", source = "my-whoop", durationS = durS, zonesJSON = zones,
        )
        val s = zoneSummary(
            listOf(
                row(0, 3600.0, """{"zone1":100}"""),     // 60 min all Z1
                row(10_000, 1800.0, """{"z5":100}"""),   // 30 min all Z5 (mac shape)
                row(20_000, 1800.0, null),                  // zoneless — excluded
            ),
        )!!
        assertEquals(2, s.sessionsWithZones)
        assertEquals(60.0, s.minutes[0], 1e-9)
        assertEquals(30.0, s.minutes[4], 1e-9)
        assertEquals(90.0, s.totalMinutes, 1e-9)
    }
}
