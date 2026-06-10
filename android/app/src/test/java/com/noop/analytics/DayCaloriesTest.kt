package com.noop.analytics

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Tests Calories.estimateDayCalories — the APPROXIMATE whole-day HR-only energy estimate
 * (Keytel active + Harris–Benedict BMR) that backs DailyMetric.activeKcalEst and the Today
 * Calories tile for BLE-only users. Pure-function tests; no DB. Not cloud/clinical parity.
 */
class DayCaloriesTest {

    private fun hrDay(bpm: Int, n: Int): List<com.noop.data.HrSample> =
        (0 until n).map { com.noop.data.HrSample(deviceId = "test", ts = it.toLong(), bpm = bpm) }

    @Test
    fun dayCalories_emptyIsZero() {
        assertEquals(
            0.0,
            Calories.estimateDayCalories(emptyList(), UserProfile(), hrmax = 190.0, restingHR = 55.0),
            1e-12,
        )
    }

    @Test
    fun dayCalories_matchesBoutFirst() {
        // The day estimate must equal the kcal component of the per-bout model for the
        // same samples (it delegates to estimateBoutCalories), so the two never diverge.
        val profile = UserProfile(weightKg = 80.0, heightCm = 180.0, age = 35.0, sex = "male")
        val hr = hrDay(bpm = 130, n = 600) // 10 min above the active threshold
        val day = Calories.estimateDayCalories(hr, profile, hrmax = 185.0, restingHR = 55.0)
        val bout = Calories.estimateBoutCalories(hr, profile, hrmax = 185.0, restingHR = 55.0).first
        assertEquals(bout, day, 1e-9)
    }

    @Test
    fun dayCalories_restingDayIsLowerThanActiveDay() {
        // A whole day at resting HR burns far less than the same length all-active day,
        // and the resting-day total is positive (BMR floor).
        val profile = UserProfile(weightKg = 70.0, heightCm = 170.0, age = 30.0, sex = "nonbinary")
        // activeThreshold = 55 + 0.30*(185-55) = 94 bpm; 60 < 94 (resting), 150 >= 94 (active).
        val restingDay = Calories.estimateDayCalories(hrDay(60, 3600), profile, hrmax = 185.0, restingHR = 55.0)
        val activeDay = Calories.estimateDayCalories(hrDay(150, 3600), profile, hrmax = 185.0, restingHR = 55.0)
        assertTrue("resting day must burn > 0 (BMR floor)", restingDay > 0.0)
        assertTrue("active day must exceed resting day", activeDay > restingDay)
    }

    @Test
    fun analyzeDay_caloriesIgnoreAdjacentDayHr() {
        // analyzeDay must filter HR to the target UTC day before summing calories — the
        // IntelligenceEngine read window spans ~42h, so adjacent-day HR must NOT inflate the
        // day's activeKcalEst (the critical "full-window double-count" regression).
        val day = "2026-01-02"
        val noon = 1_767_355_200L // 2026-01-02T12:00:00Z
        fun hr(tsOffsetSec: Long, bpm: Int) =
            com.noop.data.HrSample(deviceId = "t", ts = noon + tsOffsetSec, bpm = bpm)
        val inDay = (0 until 600).map { hr(it.toLong(), 120) }
        // Same in-day HR plus 600 samples ~36h earlier (a different UTC day, inside the window).
        val withAdjacent = inDay + (0 until 600).map { hr(-36L * 3_600 - it, 120) }
        val a = AnalyticsEngine.analyzeDay(day = day, hr = inDay, profile = UserProfile()).daily.activeKcalEst
        val b = AnalyticsEngine.analyzeDay(day = day, hr = withAdjacent, profile = UserProfile()).daily.activeKcalEst
        assertNotNull(a)
        assertNotNull(b)
        assertEquals("adjacent-day HR must not change the day's calories", a!!, b!!, 1e-6)
    }

    @Test
    fun analyzeDay_dayHrCoversFullCalendarDay() {
        // Simulate the past-day clip: the night-window HR only reaches midday; the full calendar-day
        // HR also has the afternoon. activeKcalEst must use dayHr when supplied, so the full-day total
        // exceeds the clipped night-window total (the past-day undercount fix).
        val day = "2026-01-02"
        val noon = 1_767_355_200L // 2026-01-02T12:00:00Z
        fun hr(tsOffsetSec: Long, bpm: Int) =
            com.noop.data.HrSample(deviceId = "t", ts = noon + tsOffsetSec, bpm = bpm)
        val nightWindow = (0 until 600).map { hr(it.toLong(), 120) }
        val fullDay = nightWindow + (0 until 600).map { hr(3L * 3_600 + it, 120) }
        val clipped = AnalyticsEngine.analyzeDay(day = day, hr = nightWindow, profile = UserProfile()).daily.activeKcalEst
        val full = AnalyticsEngine.analyzeDay(
            day = day, hr = nightWindow, dayHr = fullDay, profile = UserProfile(),
        ).daily.activeKcalEst
        assertNotNull(clipped)
        assertNotNull(full)
        assertTrue("full calendar-day calories must exceed the clipped night-window total", full!! > clipped!!)
    }

    @Test
    fun analyzeDay_dayHrNullFallsBackToWindowHr() {
        // With no calendar-day stream, the total falls back to the window `hr` — identical to passing
        // that same window explicitly as dayHr (the (dayHr ?: hr) fallback).
        val day = "2026-01-02"
        val noon = 1_767_355_200L
        fun hr(tsOffsetSec: Long, bpm: Int) =
            com.noop.data.HrSample(deviceId = "t", ts = noon + tsOffsetSec, bpm = bpm)
        val window = (0 until 600).map { hr(it.toLong(), 120) }
        val fallback = AnalyticsEngine.analyzeDay(day = day, hr = window, profile = UserProfile()).daily.activeKcalEst
        val explicit = AnalyticsEngine.analyzeDay(day = day, hr = window, dayHr = window, profile = UserProfile()).daily.activeKcalEst
        assertNotNull(fallback)
        assertNotNull(explicit)
        assertEquals(fallback!!, explicit!!, 1e-9)
    }
}
