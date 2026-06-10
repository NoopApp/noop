package com.noop.ui

import com.noop.data.DailyMetric
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Test

/**
 * Pins the Sleep screen's prefer-imported logic: where the WHOOP export carried a figure
 * verbatim (sleep_performance / sleep_consistency / sleep_need_min / sleep_debt_min in
 * metricSeries), the headline tiles must pass it through unscaled; days the export does
 * not cover keep the on-device APPROXIMATE fallback so sparklines stay continuous across
 * the import horizon.
 */
class SleepImportedFiguresTest {

    private fun day(d: String, asleep: Double?) = DailyMetric(
        deviceId = "my-whoop", day = d, totalSleepMin = asleep,
        deepMin = 80.0, remMin = 90.0, lightMin = 200.0, efficiency = 90.0,
    )

    @Test
    fun importedPerformanceWinsPerDay() {
        val days = listOf(day("2026-06-01", 420.0), day("2026-06-02", 410.0))
        val imported = ImportedSleepSeries(performance = mapOf("2026-06-02" to 85.0))
        val m = buildSleepModel(days, session = null, imported = imported)!!
        assertEquals(85.0, m.performance.latest!!, 1e-9)
    }

    @Test
    fun importedDebtPassesThroughInMinutes() {
        val days = listOf(day("2026-06-01", 420.0), day("2026-06-02", 410.0))
        val imported = ImportedSleepSeries(debtMin = mapOf("2026-06-02" to 60.0))
        val m = buildSleepModel(days, session = null, imported = imported)!!
        assertEquals(60.0, m.sleepDebt.latest!!, 1e-9)
    }

    @Test
    fun hoursVsNeededUsesImportedNeedPerDay() {
        val days = listOf(day("2026-06-01", 400.0))
        val imported = ImportedSleepSeries(needMin = mapOf("2026-06-01" to 480.0))
        val m = buildSleepModel(days, session = null, imported = imported)!!
        assertEquals(400.0 / 480.0 * 100.0, m.hoursVsNeeded.latest!!, 1e-9)
    }

    @Test
    fun uncoveredDaysFallBackToApproximation() {
        // Imported covers only day 1; day 2 (the latest) must use the on-device fallback
        // (asleep / personal need, capped 100; need = max(450, mean asleep) = 450 here).
        val days = listOf(day("2026-06-01", 420.0), day("2026-06-02", 410.0))
        val imported = ImportedSleepSeries(performance = mapOf("2026-06-01" to 85.0))
        val m = buildSleepModel(days, session = null, imported = imported)!!
        assertEquals(410.0 / 450.0 * 100.0, m.performance.latest!!, 1e-9)
        // …and the imported day still carries the verbatim figure inside the series.
        assertEquals(85.0, m.performance.series.first(), 1e-9)
    }

    @Test
    fun importedConsistencyUsedOnlyWhenItCoversTheLatestNight() {
        val days = listOf(day("2026-06-01", 420.0), day("2026-06-02", 410.0))
        // Covers the latest night → verbatim series wins.
        val covered = buildSleepModel(days, null,
            ImportedSleepSeries(consistency = mapOf("2026-06-01" to 70.0, "2026-06-02" to 74.0)))!!
        assertEquals(74.0, covered.consistency.latest!!, 1e-9)
        // Ends before the latest night → the APPROXIMATE duration-spread proxy, never a
        // months-old import-era value presented as "latest".
        val stale = buildSleepModel(days, null,
            ImportedSleepSeries(consistency = mapOf("2026-06-01" to 70.0)))!!
        assertNotEquals(70.0, stale.consistency.latest)
    }

    @Test
    fun emptyImportedReproducesTheApproximateBaseline() {
        val days = listOf(day("2026-06-01", 420.0), day("2026-06-02", 410.0))
        val a = buildSleepModel(days, session = null)!!
        val b = buildSleepModel(days, session = null, imported = ImportedSleepSeries())!!
        assertEquals(a, b)
    }
}
