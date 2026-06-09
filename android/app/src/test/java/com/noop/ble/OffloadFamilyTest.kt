package com.noop.ble

import com.noop.protocol.DeviceFamily
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Family-aware offload-plumbing tests. WHOOP 5.0/MG ("puffin", CRC16 envelope) shifts the inner
 * record +4 vs WHOOP 4.0, so the offload-frame type byte and the HISTORY_END `end_data` slice both
 * move. These were the offsets that kept 5.0 history download from ever running on Android even
 * though the decoder was ready (Mac parity). Offsets mirror the Swift BLEManager/Backfiller.
 */
class OffloadFamilyTest {

    // ---- Backfiller.endData : end_data = frame[17:25] (WHOOP4) vs frame[21:29] (WHOOP5/MG) ----

    @Test
    fun endData_whoop4_isFrame17to25() {
        val frame = ByteArray(26)
        for (i in 17 until 25) frame[i] = (i - 16).toByte() // bytes 1..8 at [17..24]
        assertArrayEquals(byteArrayOf(1, 2, 3, 4, 5, 6, 7, 8), Backfiller.endData(frame, DeviceFamily.WHOOP4))
    }

    @Test
    fun endData_whoop5_isFrame21to29() {
        val frame = ByteArray(30)
        for (i in 21 until 29) frame[i] = (i - 20).toByte() // bytes 1..8 at [21..28]
        assertArrayEquals(byteArrayOf(1, 2, 3, 4, 5, 6, 7, 8), Backfiller.endData(frame, DeviceFamily.WHOOP5))
    }

    @Test
    fun endData_defaultsToWhoop4() {
        val frame = ByteArray(26)
        for (i in 17 until 25) frame[i] = (i - 16).toByte()
        assertArrayEquals(Backfiller.endData(frame, DeviceFamily.WHOOP4), Backfiller.endData(frame))
    }

    @Test
    fun endData_tooShort_returnsNull() {
        assertNull(Backfiller.endData(ByteArray(28), DeviceFamily.WHOOP5)) // needs >= 29
        assertNull(Backfiller.endData(ByteArray(24), DeviceFamily.WHOOP4)) // needs >= 25
    }

    // ---- WhoopBleClient.isOffloadFrame : type byte at frame[4] (WHOOP4) vs frame[8] (WHOOP5/MG) ----

    @Test
    fun isOffloadFrame_whoop4_readsByte4() {
        val frame = ByteArray(5).also { it[4] = 47 } // HISTORICAL_DATA at the WHOOP4 type index
        assertTrue(WhoopBleClient.isOffloadFrame(frame, DeviceFamily.WHOOP4))
        // The same frame read as WHOOP5 looks at frame[8] (absent) → not an offload frame.
        assertFalse(WhoopBleClient.isOffloadFrame(frame, DeviceFamily.WHOOP5))
    }

    @Test
    fun isOffloadFrame_whoop5_readsByte8() {
        val frame = ByteArray(9).also { it[8] = 49 } // METADATA at the WHOOP5 type index
        assertTrue(WhoopBleClient.isOffloadFrame(frame, DeviceFamily.WHOOP5))
        // frame[4] == 0 here, so a WHOOP4 read correctly rejects it.
        assertFalse(WhoopBleClient.isOffloadFrame(frame, DeviceFamily.WHOOP4))
    }

    @Test
    fun isOffloadFrame_liveFloodRejected() {
        val realtime = ByteArray(9).also { it[8] = 40 } // REALTIME_DATA — not offload
        assertFalse(WhoopBleClient.isOffloadFrame(realtime, DeviceFamily.WHOOP5))
        val rawFlood = ByteArray(9).also { it[8] = 43 } // REALTIME_RAW_DATA — not offload
        assertFalse(WhoopBleClient.isOffloadFrame(rawFlood, DeviceFamily.WHOOP5))
    }

    @Test
    fun isOffloadFrame_defaultsToWhoop4() {
        val frame = ByteArray(5).also { it[4] = 48 } // EVENT at the WHOOP4 type index
        assertEquals(WhoopBleClient.isOffloadFrame(frame, DeviceFamily.WHOOP4), WhoopBleClient.isOffloadFrame(frame))
    }
}
