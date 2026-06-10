package com.noop.protocol

import org.junit.Assert.assertEquals
import org.junit.Test

class BackfillCaptureSummaryTest {

    @Test
    fun countsPacketTypesAndRetainsOnlyFirstUnknownSamples() {
        val summary = BackfillCaptureSummary(maxUnknownSamples = 2)

        summary.record("METADATA", true, 36, "fd4b0005", "aa01")
        summary.record("type54", true, 28, "fd4b0005", "aa02")
        summary.record("type54", true, 28, "fd4b0005", "aa03")
        summary.record("type54", true, 28, "fd4b0005", "aa04")
        summary.record("COMMAND_RESPONSE", false, 20, "fd4b0003", "aa05")

        assertEquals(
            "COMMAND_RESPONSE=1, METADATA=1, type54=3",
            summary.countsText(),
        )
        assertEquals(
            "type54(size=28,char=fd4b0005,crc=true,hex=aa02); " +
                "type54(size=28,char=fd4b0005,crc=true,hex=aa03)",
            summary.unknownSamplesText(),
        )
    }

    @Test
    fun reportsNoneWhenNoUnknownSamplesWereCaptured() {
        val summary = BackfillCaptureSummary(maxUnknownSamples = 2)

        summary.record("METADATA", true, 36, "fd4b0005", "aa01")
        summary.record("EVENT", true, 24, "fd4b0005", "aa02")

        assertEquals("EVENT=1, METADATA=1", summary.countsText())
        assertEquals("none", summary.unknownSamplesText())
    }
}
