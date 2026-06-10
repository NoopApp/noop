package com.noop.protocol

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Test

/**
 * The unmapped-firmware-version fallback for WHOOP 4.0 type-47 records (#30/#77).
 *
 * macOS shipped this (PostHooks "historical_data") but Android dropped any unmapped version entirely
 * (`histVersionLayout(version) ?: return null`), so a WHOOP 4 on newer firmware decoded to ZERO rows
 * on Android — the offload "completed" while every record was silently discarded. Now Android falls
 * back to the canonical v24 layout for an unmapped version, accepting it ONLY when it decodes to
 * physically-real data (|gravity| ≈ 1 g + plausible HR), so it can never store garbage.
 */
class HistoricalFallbackTest {

    // Real on-wrist WHOOP 4.0 v24 record (HR 109, two R-R, gravity ~1 g) — the same hardware frame the
    // macOS Whoop4HistoricalV24HardwareTests uses. version byte is frame[5] = 0x18 (24).
    private val realV24Hex =
        "aa6400a12f18054c1c0a023ed0266a5037805418016d022b0234020000000000006b07ff00" +
        "85593c1f65cebed7b3e63eb85a5f3f000080401f65cebed7b3e63eb85a5f3f500264025d03" +
        "640229014009010c020c00000000000f0001c4020000000000008fdeb278"

    private fun bytes(s: String): ByteArray =
        ByteArray(s.length / 2) { ((s[it * 2].digitToInt(16) shl 4) or s[it * 2 + 1].digitToInt(16)).toByte() }

    /** Recompute the body CRC32 (over inner bytes frame[4 until length]) and write it LE into the
     *  trailer at frame[length..length+4], so a frame mutated in the test still validates. */
    private fun repairCrc32(frame: ByteArray) {
        val length = (frame[1].toInt() and 0xFF) or ((frame[2].toInt() and 0xFF) shl 8)
        val crc = Crc.crc32(frame.copyOfRange(4, length))
        frame[length] = (crc and 0xFF).toByte()
        frame[length + 1] = ((crc shr 8) and 0xFF).toByte()
        frame[length + 2] = ((crc shr 16) and 0xFF).toByte()
        frame[length + 3] = ((crc shr 24) and 0xFF).toByte()
    }

    @Test
    fun mappedV24RecordStillDecodes() {
        val p = decodeHistorical(bytes(realV24Hex), DeviceFamily.WHOOP4)
        assertNotNull(p)
        assertEquals(24, p!!["hist_version"])
        assertEquals(109, p["heart_rate"])
    }

    @Test
    fun unmappedVersionFallsBackToV24WhenPhysicallyReal() {
        // The #77 case: a real v24-layout record whose firmware reports an UNMAPPED version. Android
        // used to drop it; it must now decode via the v24 fallback (HR + data present), not return null.
        val frame = bytes(realV24Hex)
        frame[5] = 99.toByte()           // unmapped version (not in {5,7,9,12,24})
        repairCrc32(frame)
        val p = decodeHistorical(frame, DeviceFamily.WHOOP4)
        assertNotNull("unmapped-but-v24-compatible record must decode via fallback, not drop", p)
        assertEquals(99, p!!["hist_version"])
        assertEquals(109, p["heart_rate"])
        @Suppress("UNCHECKED_CAST")
        assertEquals("R-R intervals must survive the fallback", 2, (p["rr_intervals"] as List<Int>).size)
    }

    @Test
    fun unmappedVersionWithNonPhysicalDataIsStillDropped() {
        // Same unmapped version, but the gravity block is zeroed so the v24 guess yields a non-physical
        // |gravity| — the plausibility gate must reject it (return null) rather than store garbage.
        val frame = bytes(realV24Hex)
        frame[5] = 99.toByte()
        for (i in 40 until 52) frame[i] = 0   // zero gravity x/y/z (offsets 40/44/48) → |g| = 0
        repairCrc32(frame)
        assertNull(decodeHistorical(frame, DeviceFamily.WHOOP4))
    }
}
