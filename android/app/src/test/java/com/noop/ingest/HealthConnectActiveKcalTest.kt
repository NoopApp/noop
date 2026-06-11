package com.noop.ingest

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/**
 * #117 — crediting an imported exercise session with the active calories burned inside its window.
 * Time-weighted overlap so a per-activity record counts in full while a day-spanning total record
 * only contributes the session's slice.
 */
class HealthConnectActiveKcalTest {

    private fun rec(start: Long, end: Long, kcal: Double) = Triple(start, end, kcal)

    @Test fun noRecordsGivesNull() {
        assertNull(HealthConnectImporter.sumActiveKcalInWindow(emptyList(), 100, 200))
    }

    @Test fun aRecordFullyInsideCountsInFull() {
        val recs = listOf(rec(120, 180, 300.0))
        assertEquals(300.0, HealthConnectImporter.sumActiveKcalInWindow(recs, 100, 200)!!, 0.001)
    }

    @Test fun aRecordExactlyMatchingTheSessionCountsInFull() {
        val recs = listOf(rec(100, 200, 250.0))
        assertEquals(250.0, HealthConnectImporter.sumActiveKcalInWindow(recs, 100, 200)!!, 0.001)
    }

    @Test fun aNonOverlappingRecordIsIgnored() {
        val recs = listOf(rec(300, 400, 500.0))
        assertNull(HealthConnectImporter.sumActiveKcalInWindow(recs, 100, 200))
    }

    @Test fun multiplePerMinuteRecordsInsideAreSummed() {
        val recs = listOf(rec(100, 160, 60.0), rec(160, 200, 40.0))
        assertEquals(100.0, HealthConnectImporter.sumActiveKcalInWindow(recs, 100, 200)!!, 0.001)
    }

    @Test fun aDaySpanningRecordOnlyContributesTheSessionsFraction() {
        // 1440-min day record of 1440 kcal (1 kcal/min); a 60-min session should credit ~60 kcal.
        val dayStart = 0L
        val dayEnd = 86_400L
        val recs = listOf(rec(dayStart, dayEnd, 1440.0))
        val sessionKcal = HealthConnectImporter.sumActiveKcalInWindow(recs, 10_000, 13_600)!! // 3600 s = 60 min
        assertEquals(1440.0 * (3600.0 / 86_400.0), sessionKcal, 0.001) // = 60.0
    }

    @Test fun partialOverlapIsProRated() {
        // Record [150,250] of 100 kcal; session [100,200] overlaps [150,200] = 50 of the 100 s span.
        val recs = listOf(rec(150, 250, 100.0))
        assertEquals(50.0, HealthConnectImporter.sumActiveKcalInWindow(recs, 100, 200)!!, 0.001)
    }
}
