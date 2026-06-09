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
 * Byte-exact tests for the WHOOP 5.0 (device family GOOSE/MAVERICK) haptic + alarm payload
 * encoders. The expected vectors are the protocol's own wire-format facts (command numbers, field
 * offsets, byte values), confirmed against the official app's behaviour for interoperability — not
 * derived from this implementation:
 *   - notification buzz   (RUN_HAPTIC_PATTERN_MAVERICK = cmd 19)
 *   - SET_ALARM_TIME rev4 (cmd 66); matches GooseSwift AlarmCommandKind.set
 *   - DISABLE_ALARM rev2  (cmd 69)
 *   - RUN_ALARM rev2      (cmd 68)
 * so a passing test confirms agreement with the strap's real protocol, not self-consistency.
 */
class HapticPayloadsTest {

    private val utc: ZoneId = ZoneId.of("UTC")

    /** Fixed "now": 2026-06-07 08:00:00 UTC. */
    private fun nowMs(): Long =
        ZonedDateTime.of(LocalDate.of(2026, 6, 7), LocalTime.of(8, 0), utc).toInstant().toEpochMilli()

    private fun bytes(vararg ints: Int): ByteArray = ByteArray(ints.size) { ints[it].toByte() }

    // ---- MaverickHaptics.notificationBuzz (cmd 19) ----

    @Test
    fun buzz_singleLoop_matchesOfficialNotificationPattern() {
        // NotificationHapticsPattern(47,152,0,0,0,0,0,0, loopControl=0, overallLoop=1)
        // serialized as: [REVISION_1][8 effects][u16 LE loopControl][overallLoop]
        val expected = bytes(0x01, 47, 152, 0, 0, 0, 0, 0, 0, 0x00, 0x00, 0x01)
        assertArrayEquals(expected, MaverickHaptics.notificationBuzz(loops = 1))
    }

    @Test
    fun buzz_loopsGoIntoOverallWaveformLoopControl() {
        val out = MaverickHaptics.notificationBuzz(loops = 2)
        assertEquals(12, out.size)
        assertEquals(0x01.toByte(), out[0]) // REVISION_1
        assertEquals(47.toByte(), out[1])   // waveFormEffect1
        assertEquals(152.toByte(), out[2])  // waveFormEffect2
        assertEquals(0.toByte(), out[9])    // loopControlForEffects LE lo
        assertEquals(0.toByte(), out[10])   // loopControlForEffects LE hi
        assertEquals(2.toByte(), out[11])   // overallWaveformLoopControl
    }

    @Test
    fun buzz_loopsAreClampedToUnsignedByte() {
        assertEquals(0.toByte(), MaverickHaptics.notificationBuzz(-5)[11])
        assertEquals(255.toByte(), MaverickHaptics.notificationBuzz(999)[11])
    }

    // ---- AlarmPayload.build : SET_ALARM_TIME(66) REVISION_4 ----

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
        // AlarmHapticsPattern(47,152,0,0,0,0,0,0, loopControl=0, overallLoop=7, duration=30)
        // serialized as: [8 effects][u16 LE loopControl][overallLoop][durationSeconds]
        val body = AlarmPayload.build(AlarmPayload.nextWakeEpochMs(7, 15, nowMs(), utc))
        val tail = body.copyOfRange(body.size - 12, body.size)
        val expected = bytes(47, 152, 0, 0, 0, 0, 0, 0, /*loopCtl*/ 0, 0, /*overall*/ 7, /*dur*/ 30)
        assertArrayEquals(expected, tail)
    }

    @Test
    fun alarm_defaultAlarmIdIsOne() {
        assertEquals(1.toByte(), AlarmPayload.build(nowMs())[1])
    }

    // ---- nextWakeEpochMs (next future occurrence) ----

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

    // ---- DISABLE_ALARM(69) / RUN_ALARM(68) revision-2 bodies ----

    @Test
    fun disableAlarm_rev2_isSentinelFF() {
        assertArrayEquals(bytes(0x02, 0xFF), AlarmPayload.disableRev2())
    }

    @Test
    fun runAlarm_rev2_carriesAlarmId() {
        assertArrayEquals(bytes(0x02, 0x01), AlarmPayload.runAlarmRev2(1))
    }

    // ---- puffin framing: 4-byte inner-record padding (the real buzz fix, #48) ----

    @Test
    fun buzzFrame_innerPaddedTo4ByteBoundary() {
        // The 12-byte cmd-19 body makes the inner record 15 bytes; puffinCommandFrame MUST pad it to 16
        // (a 4-byte boundary) or the declared length + CRC32 cover the wrong byte count and the strap
        // SILENTLY drops the frame (no COMMAND_RESPONSE, no motor). This pad is what made the buzz fire.
        val frame = Framing.puffinCommandFrame(cmd = 0x13, seq = 9, payload = MaverickHaptics.notificationBuzz(1))
        val declLen = (frame[2].toInt() and 0xFF) or ((frame[3].toInt() and 0xFF) shl 8)
        assertEquals(20, declLen)                        // inner 16 + 4
        assertEquals(28, frame.size)                     // 6 header + 2 crc16 + 16 inner + 4 crc32
        assertEquals(0xAA, frame[0].toInt() and 0xFF)
        assertEquals(35, frame[8].toInt() and 0xFF)      // inner[0] = COMMAND
        assertEquals(9, frame[9].toInt() and 0xFF)       // inner[1] = seq
        assertEquals(0x13, frame[10].toInt() and 0xFF)   // inner[2] = RUN_HAPTIC_PATTERN_MAVERICK
        assertEquals(0x01, frame[11].toInt() and 0xFF)   // payload[0] = REVISION_1
    }

    @Test
    fun puffinFrame_noPadWhenAlreadyAligned() {
        // A 1-byte payload makes the inner record 4 bytes (already aligned) -> no pad, declLen 8.
        val frame = Framing.puffinCommandFrame(cmd = 3, seq = 0, payload = byteArrayOf(1))
        val declLen = (frame[2].toInt() and 0xFF) or ((frame[3].toInt() and 0xFF) shl 8)
        assertEquals(8, declLen)
        assertEquals(16, frame.size)
    }
}
