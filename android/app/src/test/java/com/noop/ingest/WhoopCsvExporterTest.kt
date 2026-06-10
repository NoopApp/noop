package com.noop.ingest

import com.noop.data.DailyMetric
import com.noop.data.JournalEntry
import com.noop.data.SleepSession
import com.noop.data.WorkoutRow
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.util.zip.ZipInputStream

/**
 * THE round-trip contract: serialize with WhoopCsvExporter, re-parse with the REAL
 * WhoopCsvImporter parse functions, assert data-class equality. If these stay green the
 * exported zip is re-importable by NOOP itself (Android side; the macOS suite mirrors it).
 */
class WhoopCsvExporterTest {

    @Test
    fun cyclesRoundTripThroughRealImporter() {
        val daily = listOf(
            DailyMetric(
                deviceId = "my-whoop", day = "2026-06-01", totalSleepMin = 420.0, efficiency = 92.3,
                deepMin = 95.0, remMin = 115.0, lightMin = 210.0, disturbances = 35, restingHr = 52,
                avgHrv = 68.4, recovery = 72.0, strain = 12.5, exerciseCount = null,
                spo2Pct = 96.0, skinTempDevC = 33.1, respRateBpm = 14.2,
            ),
        )
        val series = mapOf(
            "2026-06-01" to mapOf(
                "sleep_performance" to 85.0, "sleep_consistency" to 88.0,
                "sleep_need_min" to 480.0, "sleep_debt_min" to 60.0,
            ),
        )
        val csv = WhoopCsvExporter.cyclesCsv(daily, series, mapOf("2026-06-01" to "import"))
        val table = CsvTable.fromData(csv.toByteArray())
        // exerciseCount/steps/etc. have no WHOOP CSV columns — they re-import as null by design.
        assertEquals(daily, WhoopCsvImporter.parseCycles(table, "my-whoop"))
        // The four sleep figures land back as metricSeries rows under the same keys.
        assertEquals(4, WhoopCsvImporter.parseCycleSeries(table, "my-whoop").size)
    }

    @Test
    fun workoutSportWithCommaQuoteNewlineSurvives() {
        val w = WorkoutRow(
            deviceId = "my-whoop", startTs = 1_750_000_000L, endTs = 1_750_003_600L,
            sport = "Run, \"tempo\"\nintervals", source = "my-whoop", durationS = 3600.0,
            energyKcal = 540.0, avgHr = 158, maxHr = 182, strain = 11.2, distanceM = 8000.0,
            zonesJSON = """{"zone1":10.0,"zone2":20.0,"zone3":40.0,"zone4":20.0,"zone5":10.0}""",
            notes = null,
        )
        val table = CsvTable.fromData(WhoopCsvExporter.workoutsCsv(listOf(w)).toByteArray())
        val back = WhoopCsvImporter.parseWorkouts(table, "my-whoop").single()
        assertEquals(w.sport, back.sport)
        assertEquals(w.startTs, back.startTs)
        assertEquals(w.endTs, back.endTs)
        assertEquals(w.strain!!, back.strain!!, 1e-9)
        assertEquals(w.energyKcal!!, back.energyKcal!!, 1e-9)
        assertEquals(w.avgHr, back.avgHr)
        assertEquals(w.maxHr, back.maxHr)
        assertEquals(w.distanceM!!, back.distanceM!!, 1e-9)
    }

    @Test
    fun sleepsRoundTripBothStageShapes() {
        // Android-import shape [{stage,min}] — minutes survive exactly.
        val imported = SleepSession(
            deviceId = "my-whoop", startTs = 1_750_000_000L, endTs = 1_750_030_000L,
            efficiency = 91.0, restingHr = null, avgHrv = null,
            stagesJSON = """[{"stage":"light","min":210.0},{"stage":"deep","min":95.0},""" +
                """{"stage":"rem","min":115.0},{"stage":"awake","min":35.0}]""",
        )
        // On-device stager shape [{start,end,stage}] — minutes derived from the spans.
        val computed = SleepSession(
            deviceId = "my-whoop-noop", startTs = 2_000_000_000L, endTs = 2_000_007_200L,
            efficiency = null, restingHr = null, avgHrv = null,
            stagesJSON = """[{"start":2000000000,"end":2000003600,"stage":"light"},""" +
                """{"start":2000003600,"end":2000007200,"stage":"deep"}]""",
        )
        val table = CsvTable.fromData(
            WhoopCsvExporter.sleepsCsv(listOf(imported, computed)).toByteArray(),
        )
        val back = WhoopCsvImporter.parseSleeps(table, "my-whoop").sessions.sortedBy { it.startTs }
        assertEquals(2, back.size)
        assertEquals(imported.startTs, back[0].startTs)
        assertEquals(imported.endTs, back[0].endTs)
        // The importer rebuilds [{stage,min}] — decode and compare minutes.
        val m0 = WhoopCsvExporter.stageMinutes(back[0].stagesJSON)
        assertEquals(210.0, m0.light!!, 1e-6)
        assertEquals(95.0, m0.deep!!, 1e-6)
        assertEquals(115.0, m0.rem!!, 1e-6)
        val m1 = WhoopCsvExporter.stageMinutes(back[1].stagesJSON)
        assertEquals(60.0, m1.light!!, 1e-6)
        assertEquals(60.0, m1.deep!!, 1e-6)
    }

    @Test
    fun journalRoundTripIncludingFalseAnswersAndCommaNotes() {
        val rows = listOf(
            JournalEntry(deviceId = "my-whoop", day = "2026-06-01",
                question = "Any alcohol?", answeredYes = false, notes = null),
            JournalEntry(deviceId = "my-whoop", day = "2026-06-01",
                question = "Caffeine, after 4pm?", answeredYes = true, notes = "one, big \"mug\""),
        )
        val table = CsvTable.fromData(WhoopCsvExporter.journalCsv(rows).toByteArray())
        val back = WhoopCsvImporter.parseJournal(table, "my-whoop").sortedBy { it.question }
        assertEquals(2, back.size)
        assertEquals("Any alcohol?", back[0].question)
        assertEquals(false, back[0].answeredYes)
        assertEquals("2026-06-01", back[0].day)
        assertEquals("Caffeine, after 4pm?", back[1].question)
        assertEquals(true, back[1].answeredYes)
        assertEquals("one, big \"mug\"", back[1].notes)
    }

    @Test
    fun utcTimestampParsesBackToSameEpoch() {
        val ts = 1_751_234_567L
        assertEquals(ts, WhoopTime.parseEpochSeconds(WhoopCsvExporter.utc(ts), 0))
    }

    @Test
    fun numbersAreLocaleProof() {
        assertEquals("72", WhoopCsvExporter.num(72.0))
        assertEquals("68.4", WhoopCsvExporter.num(68.4))
        assertEquals("", WhoopCsvExporter.num(null as Double?))
        assertTrue(!WhoopCsvExporter.num(12345.678).contains(","))
    }

    @Test
    fun zipBytesReadBackByName() {
        val zip = WhoopCsvExporter.zipBytes(
            linkedMapOf(
                "a.csv" to "x,y\r\n".toByteArray(),
                "noop_metric_series.json" to "[]".toByteArray(),
            ),
        )
        val names = ArrayList<String>()
        ZipInputStream(zip.inputStream()).use { zis ->
            var e = zis.nextEntry
            while (e != null) { names.add(e.name); e = zis.nextEntry }
        }
        assertEquals(listOf("a.csv", "noop_metric_series.json"), names)
    }
}
