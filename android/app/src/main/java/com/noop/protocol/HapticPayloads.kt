package com.noop.protocol

import java.time.Instant
import java.time.LocalTime
import java.time.ZoneId

/**
 * WHOOP 5.0 / MG (device family GOOSE/MAVERICK) haptic + alarm command payload encoders.
 *
 * These are WHOOP 5.0/MG protocol facts — command numbers, field offsets and byte layouts —
 * documented as factual wire-format observations and confirmed against the official app's behaviour
 * for interoperability; no proprietary code is reproduced (see ATTRIBUTION.md / DISCLAIMER.md).
 * Haptics dispatch by device type: GEN_4 → RUN_HAPTICS_PATTERN(79), but GOOSE/MAVERICK
 * (= WHOOP 5.0 / MG) → RUN_HAPTIC_PATTERN_MAVERICK(19) with a different, 12-byte waveform payload.
 * noop's legacy [buzz] sent the Gen-4 command to a 5/MG strap, which silently ignored it — this is
 * the missing piece. The WHOOP 4.0 paths stay in WhoopBleClient unchanged.
 *
 * All multi-byte fields are little-endian. Revision values: REVISION_1=1, REVISION_4=4.
 */

/** The canonical WHOOP waveform-effect pair, used by both the notification buzz and the wake alarm. */
private val WAVEFORM_EFFECTS = byteArrayOf(47, 152.toByte(), 0, 0, 0, 0, 0, 0)

object MaverickHaptics {
    /**
     * 12-byte payload for RUN_HAPTIC_PATTERN_MAVERICK (cmd 19) — a one-shot buzz on a 5/MG strap.
     * Layout (NotificationHapticsPattern serializer):
     * ```
     *   [0]      REVISION_1 = 0x01
     *   [1..8]   waveFormEffect1..8            (47, 152, 0,0,0,0,0,0)
     *   [9..10]  loopControlForEffects  u16 LE (0)
     *   [11]     overallWaveformLoopControl    (repeat count; official notification uses 1)
     * ```
     * [loops] maps to overallWaveformLoopControl. The official "buzz once" notification is loops = 1.
     */
    fun notificationBuzz(loops: Int): ByteArray {
        val overall = loops.coerceIn(0, 255)
        val out = ByteArray(12)
        out[0] = 0x01 // REVISION_1
        System.arraycopy(WAVEFORM_EFFECTS, 0, out, 1, 8)
        out[9] = 0x00 // loopControlForEffects LE lo
        out[10] = 0x00 // loopControlForEffects LE hi
        out[11] = overall.toByte()
        return out
    }
}

object AlarmPayload {
    private const val OVERALL_LOOP: Byte = 7        // overallWaveformLoopControl (alarm pattern)
    private const val DURATION_SECONDS: Byte = 30   // alarmDurationInSeconds

    /**
     * Next future epoch-millis for local wake [hour]:[minute], relative to [nowMs] in [zone].
     * Returns today's occurrence if strictly in the future, otherwise tomorrow's (mirrors the iOS
     * `nextFutureAlarmDate`, which requires candidate > now).
     */
    fun nextWakeEpochMs(hour: Int, minute: Int, nowMs: Long, zone: ZoneId): Long {
        val now = Instant.ofEpochMilli(nowMs).atZone(zone)
        val candidate = now.with(LocalTime.of(hour, minute, 0, 0)) // second + nanos cleared → subseconds 0
        val target = if (candidate.toInstant().toEpochMilli() > nowMs) candidate else candidate.plusDays(1)
        return target.toInstant().toEpochMilli()
    }

    /**
     * SET_ALARM_TIME (cmd 66) REVISION_4 body — 20 bytes; the strap
     * arms its own RTC and fires the wake haptic itself (EVENT STRAP_DRIVEN_ALARM_EXECUTED) even with
     * the phone away. Byte-identical to GooseSwift's AlarmCommandKind.set:
     * ```
     *   [0]      0x04 (REVISION_4)
     *   [1]      alarmId
     *   [2..5]   u32 LE epoch seconds
     *   [6..7]   u16 LE subseconds = (ms % 1000) * 32768 / 1000   (1/32768-s fixed point)
     *   [8..19]  AlarmHapticsPattern: 8 effects + u16 LE loopControl(0) + overallLoop(7) + duration(30)
     * ```
     */
    fun build(wakeEpochMs: Long, alarmId: Int = 1): ByteArray {
        val seconds = wakeEpochMs / 1000L
        val subseconds = ((wakeEpochMs % 1000L) * 32768L) / 1000L // u16 fixed point
        val out = ByteArray(20)
        out[0] = 4 // REVISION_4
        out[1] = alarmId.toByte()
        out[2] = (seconds and 0xFF).toByte()
        out[3] = ((seconds ushr 8) and 0xFF).toByte()
        out[4] = ((seconds ushr 16) and 0xFF).toByte()
        out[5] = ((seconds ushr 24) and 0xFF).toByte()
        out[6] = (subseconds and 0xFF).toByte()
        out[7] = ((subseconds ushr 8) and 0xFF).toByte()
        System.arraycopy(WAVEFORM_EFFECTS, 0, out, 8, 8)
        out[16] = 0x00 // loopControlForEffects LE lo
        out[17] = 0x00 // loopControlForEffects LE hi
        out[18] = OVERALL_LOOP
        out[19] = DURATION_SECONDS
        return out
    }

    /** DISABLE_ALARM (cmd 69) REVISION_2 body `[0x02, 0xFF]` (the 5/MG form). */
    fun disableRev2(): ByteArray = byteArrayOf(0x02, 0xFF.toByte())

    /** RUN_ALARM (cmd 68) REVISION_2 body `[0x02, alarmId]` — fire the stored alarm now. */
    fun runAlarmRev2(alarmId: Int = 1): ByteArray = byteArrayOf(0x02, alarmId.toByte())
}
