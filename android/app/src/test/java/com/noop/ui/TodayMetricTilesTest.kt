package com.noop.ui

import com.noop.data.AppleDaily
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/**
 * Unit tests for the Today Weight tile logic (issue #107). The Steps and Calories tiles read straight
 * off DailyMetric, so the pure logic worth pinning is the Weight tile's source resolution + unit
 * formatting, which has no daily strap source and falls back to the profile:
 *   - [latestWeightKg] picks the most-recent non-null body weight across the two Apple-side sources.
 *   - [weightTile] prefers that weight, else falls back to the SI profile weight with an honest
 *     "from profile" caption, always formatted through the unit toggle.
 */
class TodayMetricTilesTest {

    private fun appleDay(day: String, weightKg: Double?) =
        AppleDaily(deviceId = "apple-health", day = day, weightKg = weightKg)

    // MARK: latestWeightKg

    @Test
    fun latestWeight_nullWhenNoSourceHasWeight() {
        val apple = listOf(appleDay("2026-01-01", null), appleDay("2026-01-02", null))
        assertNull(latestWeightKg(apple, emptyList()))
    }

    @Test
    fun latestWeight_picksTheMostRecentDay() {
        val apple = listOf(
            appleDay("2026-01-01", 80.0),
            appleDay("2026-01-05", 78.5),
            appleDay("2026-01-03", 79.0),
        )
        assertEquals(78.5, latestWeightKg(apple, emptyList())!!, 1e-9)
    }

    @Test
    fun latestWeight_skipsNullWeightDaysEvenWhenNewer() {
        // A newer day with no weight must not blank out an older real reading.
        val apple = listOf(appleDay("2026-01-02", 81.0), appleDay("2026-01-09", null))
        assertEquals(81.0, latestWeightKg(apple, emptyList())!!, 1e-9)
    }

    @Test
    fun latestWeight_unionsBothSources_mostRecentWins() {
        val apple = listOf(appleDay("2026-01-04", 80.0))
        val healthConnect = listOf(
            AppleDaily(deviceId = "health-connect", day = "2026-01-06", weightKg = 77.0),
        )
        assertEquals(77.0, latestWeightKg(apple, healthConnect)!!, 1e-9)
    }

    // MARK: weightTile

    @Test
    fun weightTile_usesLatestReading_metric() {
        val t = weightTile(latestWeightKg = 74.5, profileWeightKg = 90.0, system = UnitSystem.METRIC)
        assertEquals("74.5 kg", t.value)
        assertEquals("latest", t.caption)
    }

    @Test
    fun weightTile_usesLatestReading_imperial() {
        val t = weightTile(latestWeightKg = 100.0, profileWeightKg = 90.0, system = UnitSystem.IMPERIAL)
        // 100 kg * 2.20462 = 220.462 lb
        assertEquals("220.5 lb", t.value)
        assertEquals("latest", t.caption)
    }

    @Test
    fun weightTile_fallsBackToProfile_withHonestCaption() {
        val t = weightTile(latestWeightKg = null, profileWeightKg = 75.0, system = UnitSystem.METRIC)
        assertEquals("75.0 kg", t.value)
        assertEquals("from profile", t.caption)
    }

    @Test
    fun weightTile_profileFallbackRespectsImperial() {
        val t = weightTile(latestWeightKg = null, profileWeightKg = 75.0, system = UnitSystem.IMPERIAL)
        // 75 kg * 2.20462 = 165.3465 lb
        assertEquals("165.3 lb", t.value)
        assertEquals("from profile", t.caption)
    }
}
