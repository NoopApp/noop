package com.noop.ui

import com.noop.data.JournalEntry
import org.junit.Assert.assertEquals
import org.junit.Test
import java.time.LocalDate

/**
 * Pins the pure journal-logging helpers (JournalLog.kt). Mirrored by the macOS
 * JournalLogicTests so the two platforms merge catalogs and entries identically —
 * question strings are opaque exact-match keys to the effects engines on both sides.
 */
class JournalLogTest {

    private fun e(dev: String, day: String, q: String, yes: Boolean) =
        JournalEntry(deviceId = dev, day = day, question = q, answeredYes = yes)

    @Test
    fun nativeWinsOnCollision() {
        val imported = listOf(e("my-whoop", "2026-06-09", "Did you drink any alcohol?", false))
        val native = listOf(e("noop-journal", "2026-06-09", "Did you drink any alcohol?", true))
        val merged = mergeJournalEntries(imported, native)
        assertEquals(1, merged.size)
        assertEquals(true, merged[0].answeredYes)
        assertEquals("noop-journal", merged[0].deviceId)
    }

    @Test
    fun disjointKeysUnionAndSort() {
        val imported = listOf(e("my-whoop", "2026-06-09", "B?", true))
        val native = listOf(
            e("noop-journal", "2026-06-10", "A?", false),
            e("noop-journal", "2026-06-09", "A?", true),
        )
        val merged = mergeJournalEntries(imported, native)
        assertEquals(3, merged.size)
        // Sorted day ASC then question ASC — matches the DAO/Swift read order.
        assertEquals(listOf("A?", "B?", "A?"), merged.map { it.question })
        assertEquals(listOf("2026-06-09", "2026-06-09", "2026-06-10"), merged.map { it.day })
    }

    @Test
    fun importedCasingWinsInCatalog() {
        val cat = mergeJournalCatalog(listOf("DID YOU DRINK ANY ALCOHOL?"), emptyList())
        assertEquals("DID YOU DRINK ANY ALCOHOL?", cat[0])
        // The starter alcohol question deduped case-insensitively: 9 starters survive + 1 imported.
        assertEquals(STARTER_JOURNAL_QUESTIONS.size, cat.size)
    }

    @Test
    fun customsAppendAndBlanksDrop() {
        val cat = mergeJournalCatalog(emptyList(), listOf("  ", "Did you nap?", "did you NAP?"))
        assertEquals(STARTER_JOURNAL_QUESTIONS, cat.take(STARTER_JOURNAL_QUESTIONS.size))
        assertEquals("Did you nap?", cat.last())
        assertEquals(STARTER_JOURNAL_QUESTIONS.size + 1, cat.size)
    }

    @Test
    fun dayKeyTodayAndYesterday() {
        val today = LocalDate.of(2026, 6, 10)
        assertEquals("2026-06-10", journalDayKey(0, today))
        assertEquals("2026-06-09", journalDayKey(1, today))
        // Month boundary.
        assertEquals("2025-12-31", journalDayKey(1, LocalDate.of(2026, 1, 1)))
    }
}
