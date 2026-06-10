package com.noop.protocol

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.time.LocalDate
import java.time.LocalTime
import java.time.ZoneId
import java.time.ZonedDateTime

/**
 * Byte-exact tests for the WHOOP 5.0/MG firmware wake-alarm payload encoder [AlarmPayload]. The
 * expected vectors are the protocol's own wire-format facts (command numbers, field offsets, byte
 * values) modelled on the official app — so a passing test pins the encoder to the claimed layout.
 * (The layout itself is EXPERIMENTAL/unconfirmed on a real strap; the runtime path is gated behind
 * the Experimental opt-in. Adopted from PR #85.)
 */
class AlarmPayloadTest {

    private val utc: ZoneId = ZoneId.of("UTC")

    /** Fixed "now": 2026-06-07 08:00:00 UTC. */
    private fun nowMs(): Long =
        ZonedDateTime.of(LocalDate.of(2026, 6, 7), LocalTime.of(8, 0), utc).toInstant().toEpochMilli()

    private fun bytes(vararg ints: Int): ByteArray = ByteArray(ints.size) { ints[it].toByte() }

    @Test
    fun alarm_headerAndLength() {
        val body = AlarmPayload.build(AlarmPayload.nextWakeEpochMs(18, 30, nowMs(), utc), alarmId = 1)
        assertEquals(20, body.size)        // 2 header + 4 u32 + 2 u16 + 12 haptics
        assertEquals(4.toByte(), body[0])  // REVISION_4
        assertEquals(1.toByte(), body[1])  // alarmId
    }

    @Test
    fun alarm_secondsAreU32Le() {
        val wake = AlarmPayload.nextWakeEpochMs(18, 30, nowMs(), utc)
        val body = AlarmPayload.build(wake)
        val le = (body[2].toLong() and 0xFF) or
            ((body[3].toLong() and 0xFF) shl 8) or
            ((body[4].toLong() and 0xFF) shl 16) or
            ((body[5].toLong() and 0xFF) shl 24)
        assertEquals(wake / 1000L, le)
    }

    @Test
    fun alarm_subsecondsAreU16LeFixedPoint() {
        // 123 ms remainder → (123*32768)/1000 = 4030 → 0x0FBE → LE [BE, 0F]
        val body = AlarmPayload.build(1_700_000_000_000L + 123L)
        val expected = ((123L * 32768L) / 1000L).toInt() // 4030
        val sub = (body[6].toInt() and 0xFF) or ((body[7].toInt() and 0xFF) shl 8)
        assertEquals(expected, sub)
    }

    @Test
    fun alarm_hapticsTailMatchesOfficialAlarmPattern() {
        // [8 effects (47,152,…)][u16 LE loopControl=0][overallLoop=7][durationSeconds=30]
        val body = AlarmPayload.build(AlarmPayload.nextWakeEpochMs(7, 15, nowMs(), utc))
        val tail = body.copyOfRange(body.size - 12, body.size)
        val expected = bytes(47, 152, 0, 0, 0, 0, 0, 0, /*loopCtl*/ 0, 0, /*overall*/ 7, /*dur*/ 30)
        assertArrayEquals(expected, tail)
    }

    @Test
    fun alarm_defaultAlarmIdIsOne() {
        assertEquals(1.toByte(), AlarmPayload.build(nowMs())[1])
    }

    @Test
    fun nextWake_laterToday_staysToday() {
        val wake = AlarmPayload.nextWakeEpochMs(18, 30, nowMs(), utc)
        val zdt = java.time.Instant.ofEpochMilli(wake).atZone(utc)
        assertEquals(LocalDate.of(2026, 6, 7), zdt.toLocalDate())
        assertEquals(18, zdt.hour)
        assertEquals(30, zdt.minute)
        assertTrue(wake > nowMs())
    }

    @Test
    fun nextWake_earlierThanNow_rollsToTomorrow() {
        val wake = AlarmPayload.nextWakeEpochMs(6, 0, nowMs(), utc)
        val zdt = java.time.Instant.ofEpochMilli(wake).atZone(utc)
        assertEquals(LocalDate.of(2026, 6, 8), zdt.toLocalDate())
        assertTrue(wake > nowMs())
    }

    @Test
    fun nextWake_equalToNow_rollsToTomorrow() {
        val wake = AlarmPayload.nextWakeEpochMs(8, 0, nowMs(), utc)
        val zdt = java.time.Instant.ofEpochMilli(wake).atZone(utc)
        assertEquals(LocalDate.of(2026, 6, 8), zdt.toLocalDate())
    }

    @Test
    fun disableAlarm_rev2_isSentinelFF() {
        assertArrayEquals(bytes(0x02, 0xFF), AlarmPayload.disableRev2())
    }
}
