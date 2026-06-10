package com.noop.ui

import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * Unit tests for [relativeAgo], the pure helper behind the Live "History synced N ago" sync-status
 * line (B6 sync-status surfacing). Buckets to just-now / minutes / hours / days; clamps future times.
 */
class RelativeAgoTest {

    private val now = 1_781_000_000L

    private fun ago(sec: Long) = relativeAgo(now - sec, now)

    @Test fun underAMinuteIsJustNow() {
        assertEquals("just now", ago(0))
        assertEquals("just now", ago(59))
    }

    @Test fun minutes() {
        assertEquals("1 min ago", ago(60))
        assertEquals("5 min ago", ago(5 * 60))
        assertEquals("59 min ago", ago(59 * 60))
    }

    @Test fun hours() {
        assertEquals("1 h ago", ago(3600))
        assertEquals("23 h ago", ago(23 * 3600))
    }

    @Test fun days() {
        assertEquals("1 d ago", ago(86_400))
        assertEquals("3 d ago", ago(3 * 86_400))
    }

    @Test fun futureTimestampClampsToJustNow() {
        // A strap-clock skew could put lastSyncAt slightly in the future; never render negative.
        assertEquals("just now", relativeAgo(now + 500, now))
    }
}
