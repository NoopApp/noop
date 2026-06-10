package com.noop.ingest

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Pins WhoopCsvImporter.parseCycleSeries: physiological_cycles.csv → long-format
 * metricSeries rows for the four export-verbatim sleep figures, under the SAME keys the
 * macOS WhoopImporter writes (sleep_performance / sleep_consistency are 0–100 %,
 * sleep_need_min / sleep_debt_min are minutes), attributed to the cycle-local day.
 */
class WhoopCycleSeriesTest {

    @Test
    fun mapsTheFourSleepFigureColumns() {
        val csv = """
            Cycle start time,Cycle end time,Cycle timezone,Sleep performance %,Sleep consistency %,Sleep need (min),Sleep debt (min)
            2026-06-01 22:30:00,2026-06-02 21:00:00,UTC+02:00,85,88,480,60
        """.trimIndent().toByteArray()
        val rows = WhoopCsvImporter.parseCycleSeries(CsvTable.fromData(csv), "my-whoop")
        assertEquals(4, rows.size)
        assertTrue(rows.all { it.deviceId == "my-whoop" && it.day == "2026-06-01" })
        assertEquals(85.0, rows.first { it.key == "sleep_performance" }.value, 1e-9)
        assertEquals(88.0, rows.first { it.key == "sleep_consistency" }.value, 1e-9)
        assertEquals(480.0, rows.first { it.key == "sleep_need_min" }.value, 1e-9)
        assertEquals(60.0, rows.first { it.key == "sleep_debt_min" }.value, 1e-9)
    }

    @Test
    fun blankCellsProduceNoRowAndTimestamplessRowsAreSkipped() {
        val csv = """
            Cycle start time,Cycle end time,Cycle timezone,Sleep performance %,Sleep consistency %,Sleep need (min),Sleep debt (min)
            2026-06-01 22:30:00,2026-06-02 21:00:00,UTC+02:00,,88,,
            ,,UTC+02:00,85,88,480,60
        """.trimIndent().toByteArray()
        val rows = WhoopCsvImporter.parseCycleSeries(CsvTable.fromData(csv), "my-whoop")
        assertEquals(1, rows.size)
        assertEquals("sleep_consistency", rows.single().key)
        assertEquals(88.0, rows.single().value, 1e-9)
    }
}
