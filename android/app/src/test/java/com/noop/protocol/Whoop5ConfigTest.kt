package com.noop.protocol

import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * Byte-parity tests for the WHOOP 5/MG R22 deep-data enable sequence. The golden frame is shared
 * verbatim with the macOS/iOS `Whoop5ConfigTests` and is the exact output of judes.club's documented
 * frame-builder for `enable_r22_packets` at seq=1 — so a mismatch here means Android and Apple would
 * write different bytes to the strap. (#174)
 */
class Whoop5ConfigTest {

    private fun ByteArray.hex() = joinToString("") { "%02x".format(it) }

    @Test
    fun enableR22PacketsGoldenFrame() {
        val frame = Whoop5Config.frame(Whoop5Config.enableR22Sequence[0], seq = 1)
        // Identical to the macOS/iOS golden frame: header aa 01 30 00 00 01, CRC16 eb11, inner
        // [0x23,0x01,0x78,0x01] + "enable_r22_packets" NUL-padded to 32 + value '2' (0x32) + 7 zeros,
        // then CRC32 d2eeb0b7.
        val expected =
            "aa0130000001eb1123017801656e61626c655f7232325f7061636b65747300000000000000000000000000003200000000000000d2eeb0b7"
        assertEquals(expected, frame.hex())
    }

    @Test
    fun sequenceIsFifteenFlagsWithExpectedValues() {
        val seq = Whoop5Config.enableR22Sequence
        assertEquals(15, seq.size)
        assertEquals("enable_r22_packets", seq[0].name)
        assertEquals(0x32, seq[0].value)
        // v4 and the passive-strap-fit flag are the only '1' (0x31) values in the documented set.
        assertEquals(0x31, seq.first { it.name == "enable_r22_v4_packets" }.value)
        assertEquals(0x31, seq.first { it.name == "enable_passive_strap_fit_gen5" }.value)
    }

    @Test
    fun payloadBodyIsAsciiNameNulPaddedWithValueAt32() {
        val body = Whoop5Config.payloadBody("enable_r22_packets", 0x32)
        assertEquals(40, body.size)
        assertEquals("enable_r22_packets", String(body.copyOfRange(0, 18), Charsets.US_ASCII))
        for (i in 18 until 32) assertEquals(0, body[i].toInt())
        assertEquals(0x32, body[32].toInt() and 0xFF)
        for (i in 33 until 40) assertEquals(0, body[i].toInt())
    }

    /** The deep-stream START burst (#278/#276): the sensor-stream "on" commands that actually begin the
     *  type-0x2F stream after the R22 flags. Mirrors the Swift `testDeepStreamStartSequence`. cmd 63 is
     *  the R10/R11 raw-stream framing #278 reported missing. */
    @Test
    fun deepStreamStartSequenceBeginsTheStream() {
        val seq = Whoop5Config.deepStreamStartSequence
        // Official-app order: realtime HR, the R10/R11 raw stream, then IMU/optical/persistent toggles.
        assertEquals(listOf(3, 63, 106, 154, 107, 108, 153), seq.map { it.cmd.rawValue })
        assertEquals(listOf(0x01), seq[1].payload.map { it.toInt() and 0xFF })        // R10/R11 on
        assertEquals(listOf(0x01, 0x01), seq[2].payload.map { it.toInt() and 0xFF })  // revisionBoolean(true)

        val frames = Whoop5Config.deepStreamStartFrames(1)
        assertEquals(7, frames.size)
        assertEquals(listOf(1, 2, 3, 4, 5, 6, 7), frames.map { it[9].toInt() and 0xFF })  // inner seq byte
        // R10/R11 command, byte-for-byte: type(0x23) seq(2) cmd(63) payload(0x01 = on).
        val r = frames[1]
        assertEquals(0x23, r[8].toInt() and 0xFF)
        assertEquals(2, r[9].toInt() and 0xFF)
        assertEquals(63, r[10].toInt() and 0xFF)
        assertEquals(0x01, r[11].toInt() and 0xFF)
    }
}
