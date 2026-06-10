package com.noop.protocol

import org.junit.Assert.assertEquals
import org.junit.Test

class BackfillCaptureJsonlTest {

    @Test
    fun encodesCaptureRecordAsStableJsonLine() {
        val line = BackfillCaptureJsonl.encode(
            BackfillCaptureRecord(
                capturedAtMs = 1234L,
                sessionId = "whoop5-1234",
                characteristic = "fd4b0005",
                typeName = "METADATA",
                crcOk = true,
                offload = true,
                size = 36,
                parsed = mapOf(
                    "meta_type" to "HISTORY_END(2)",
                    "trim_cursor" to 4512,
                    "rr_intervals" to intArrayOf(801, 802),
                ),
                hex = "aa01",
            ),
        )

        assertEquals(
            "{" +
                "\"captured_at_ms\":1234," +
                "\"session_id\":\"whoop5-1234\"," +
                "\"characteristic\":\"fd4b0005\"," +
                "\"type_name\":\"METADATA\"," +
                "\"crc_ok\":true," +
                "\"offload\":true," +
                "\"size\":36," +
                "\"parsed\":{\"meta_type\":\"HISTORY_END(2)\",\"rr_intervals\":[801,802],\"trim_cursor\":4512}," +
                "\"hex\":\"aa01\"" +
                "}",
            line,
        )
    }

    @Test
    fun escapesStringsAndNullCrc() {
        val line = BackfillCaptureJsonl.encode(
            BackfillCaptureRecord(
                capturedAtMs = 1L,
                sessionId = "s\"1",
                characteristic = "fd4b0003",
                typeName = "type54",
                crcOk = null,
                offload = false,
                size = 2,
                parsed = mapOf("note" to "line\nbreak"),
                hex = "aa\\bb",
            ),
        )

        assertEquals(
            "{" +
                "\"captured_at_ms\":1," +
                "\"session_id\":\"s\\\"1\"," +
                "\"characteristic\":\"fd4b0003\"," +
                "\"type_name\":\"type54\"," +
                "\"crc_ok\":null," +
                "\"offload\":false," +
                "\"size\":2," +
                "\"parsed\":{\"note\":\"line\\nbreak\"}," +
                "\"hex\":\"aa\\\\bb\"" +
                "}",
            line,
        )
    }
}
