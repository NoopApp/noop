package com.noop.protocol

import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * FIX #72: a grossly-stale strap RTC (the strap sat unused for months, so its clock is months behind)
 * misdates offloaded history. The extractor now corrects type-47/EVENT timestamps by the (wall - device)
 * clock offset when grossly stale, SNAPPED to a 5-min grid so re-syncs dedupe, and is a no-op for a normal
 * clock. Uses the same real worn v18 frame (unix=1780916150) as Whoop5HistoricalDecodeTest. Mirrors the
 * macOS Whoop4HistoricalV24HardwareTests #72 cases.
 */
class HistoricalStreamsClockCorrectionTest {
    private fun bytes(s: String): ByteArray =
        s.chunked(2).map { it.toInt(16).toByte() }.toByteArray()

    private val wornV18 =
        "aa01740001003fb12f1280733d8401b69f266a66460066025a0265020000000000007b0a8d656463ff0012163cf6a439bf2924fd3ed763fe3e3200aa000000000000000000f7000901f10b0007010c020c00000000000000000000000000000000000000000000000100656f1e1e0000009d61a7c00000003e862817"

    @Test fun staleClockShiftsHistoricalTimestampForwardAndSnaps() {
        val device = 1_770_000_000
        val wall = device + 60 * 86_400 + 137                    // ~60 days ahead, +137s exercises snapping
        val st = extractHistoricalStreams(listOf(bytes(wornV18)), device, wall, DeviceFamily.WHOOP5)
        val rawTs = 1_780_916_150L
        val snapped = ((wall - device) + 150) / 300 * 300        // round-half-up; offset > 0
        assertEquals(rawTs + snapped, st.hr.first().ts)
        assertEquals(0L, (st.hr.first().ts - rawTs) % 300)       // landed on the 5-min grid
    }

    @Test fun staleClockCorrectionIsDedupStableAcrossResync() {
        // Realistic re-sync jitter (~seconds, same 5-min bucket) → identical corrected ts → dedupes.
        val device = 1_770_000_000
        val a = extractHistoricalStreams(listOf(bytes(wornV18)), device, device + 60 * 86_400 + 10, DeviceFamily.WHOOP5)
        val b = extractHistoricalStreams(listOf(bytes(wornV18)), device, device + 60 * 86_400 + 13, DeviceFamily.WHOOP5)
        assertEquals(a.hr.first().ts, b.hr.first().ts)
    }

    @Test fun normalClockLeavesHistoricalTimestampUnchanged() {
        val identity = extractHistoricalStreams(listOf(bytes(wornV18)), 0, 0, DeviceFamily.WHOOP5)
        assertEquals(1_780_916_150L, identity.hr.first().ts)
        val drift = extractHistoricalStreams(listOf(bytes(wornV18)), 1_780_000_000, 1_780_003_600, DeviceFamily.WHOOP5) // 1h
        assertEquals(1_780_916_150L, drift.hr.first().ts)
    }
}
