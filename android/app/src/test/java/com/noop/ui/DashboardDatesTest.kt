package com.noop.ui

import com.noop.data.DailyMetric
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class DashboardDatesTest {
    private fun day(day: String, recovery: Double = 50.0): DailyMetric =
        DailyMetric(deviceId = "test", day = day, recovery = recovery)

    @Test
    fun rowForDayDoesNotFallbackToNewestImportedDay() {
        val days = listOf(day("2024-04-05"), day("2024-04-06"))

        assertNull(DashboardDates.rowForDay(days, "2026-06-08"))
    }

    @Test
    fun trailingWindowUsesCalendarTodayNotLastStoredRows() {
        val days = listOf(
            day("2024-04-05"),
            day("2024-04-06"),
            day("2026-05-24"),
            day("2026-05-25"),
            day("2026-05-26"),
            day("2026-06-01"),
            day("2026-06-08"),
        )

        val window = DashboardDates.trailingWindow(days, "2026-06-08", 14).map { it.day }

        assertEquals(listOf("2026-05-26", "2026-06-01", "2026-06-08"), window)
    }
}
