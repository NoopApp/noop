package com.noop.ingest

import com.noop.data.DailyMetric
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Pins the #112 fix: the Health Connect backfill skips any day the strap already covers, where
 * "cover" means EITHER a raw "my-whoop" daily row OR a computed "my-whoop-noop" row (the derived
 * recovery/strain/sleep source IntelligenceEngine writes). For a strap-only WHOOP user there are
 * no raw "my-whoop" rows, so the computed source is the ONLY thing marking their days as owned —
 * unioning the two day-sets is what stops the sparse HC row (recovery/strain/stages = null) from
 * shadowing a computed day and blanking Today / regressing Sleep stages.
 *
 * Covers the pure [HealthConnectImporter.coveredDaySet] mapper + the union semantics the importer
 * applies to it. No Room / Context / Health Connect client needed.
 */
class HealthConnectCoveredDaysTest {

    private fun row(deviceId: String, day: String) = DailyMetric(deviceId = deviceId, day = day)

    @Test
    fun coveredDaySetIsTheDistinctDaysOfTheRows() {
        val rows = listOf(
            row("my-whoop-noop", "2026-06-08"),
            row("my-whoop-noop", "2026-06-09"),
            row("my-whoop-noop", "2026-06-09"), // duplicate day collapses
        )
        assertEquals(setOf("2026-06-08", "2026-06-09"), HealthConnectImporter.coveredDaySet(rows))
    }

    @Test
    fun emptyRowsGiveEmptyCoverage() {
        assertTrue(HealthConnectImporter.coveredDaySet(emptyList()).isEmpty())
    }

    /**
     * The strap-only case that regressed in #112: NO raw "my-whoop" rows, but the computed
     * "my-whoop-noop" source covers today. The union must include today so HC does NOT backfill
     * (and shadow) it — while a day the strap never covered stays open for gap-fill.
     */
    @Test
    fun computedSourceCoversAStrapOnlyUsersDays() {
        val rawDays = HealthConnectImporter.coveredDaySet(emptyList()) // strap-only: no raw rows
        val computedDays = HealthConnectImporter.coveredDaySet(
            listOf(
                row("my-whoop-noop", "2026-06-09"),
                row("my-whoop-noop", "2026-06-10"),
            )
        )
        val covered = rawDays + computedDays

        // Strap-covered days are owned -> HC must skip them.
        assertTrue("2026-06-09 in covered", "2026-06-09" in covered)
        assertTrue("2026-06-10 in covered", "2026-06-10" in covered)
        // A day the strap never covered stays open for HC gap-fill.
        assertFalse("2026-06-07 not in covered", "2026-06-07" in covered)
    }

    /**
     * A real (non-strap-only) WHOOP user has raw "my-whoop" rows too; the union of raw + computed
     * covers both, and any day neither source has is still left open for Health Connect.
     */
    @Test
    fun unionOfRawAndComputedCoversBothAndLeavesGapsOpen() {
        val rawDays = HealthConnectImporter.coveredDaySet(
            listOf(row("my-whoop", "2026-06-05"), row("my-whoop", "2026-06-06"))
        )
        val computedDays = HealthConnectImporter.coveredDaySet(
            listOf(row("my-whoop-noop", "2026-06-06"), row("my-whoop-noop", "2026-06-07"))
        )
        val covered = rawDays + computedDays

        assertEquals(setOf("2026-06-05", "2026-06-06", "2026-06-07"), covered)
        assertFalse("2026-06-08 left open for gap-fill", "2026-06-08" in covered)
    }
}
