package com.noop.ui

import com.noop.data.DailyMetric
import java.time.LocalDate
import java.time.ZoneId
import java.time.format.DateTimeParseException

/**
 * Calendar anchors for dashboard surfaces. "Today" and trailing windows are based on
 * the phone's actual local date, not the newest imported row in the local database.
 */
internal object DashboardDates {
    fun todayKey(zone: ZoneId = ZoneId.systemDefault()): String =
        LocalDate.now(zone).toString()

    fun rowForDay(days: List<DailyMetric>, day: String): DailyMetric? =
        days.firstOrNull { it.day == day }

    fun throughDay(days: List<DailyMetric>, day: String): List<DailyMetric> =
        days.filter { it.day <= day }.sortedBy { it.day }

    fun trailingWindow(days: List<DailyMetric>, endDay: String, count: Int): List<DailyMetric> {
        if (count <= 0) return emptyList()
        val end = parseDay(endDay) ?: return emptyList()
        val start = end.minusDays((count - 1).toLong()).toString()
        val endKey = end.toString()
        return days
            .filter { it.day >= start && it.day <= endKey }
            .sortedBy { it.day }
    }

    private fun parseDay(day: String): LocalDate? =
        try {
            LocalDate.parse(day)
        } catch (_: DateTimeParseException) {
            null
        }
}
