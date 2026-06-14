package com.noop.protocol

// WHOOP 5.0 / MG "R22" feature-flag config (deep-stream unlock) — direct port of the macOS/iOS
// `Whoop5Config` (Packages/WhoopProtocol/Sources/WhoopProtocol/Whoop5Config.swift).
//
// WHOOP 5/MG straps withhold their deep biometric streams (the high-rate "R22" optical/HR/motion
// packets, type 0x2F) from a freshly-connected client. The official app switches them on by writing
// a short burst of persistent feature-flag config values right after the hello handshake — a sequence
// independently documented by two third parties: judes.club's "Cracking the WHOOP 5 Bluetooth
// Protocol" (whose interactive frame-builder is the byte-level ground truth this is validated against)
// and Asherlc/dofek's docs/whoop-ble-protocol.md (Android APK decompilation), which corroborate the
// key names, values and the SET_FF_VALUE (0x78) opcode.
//
// Each flag is one SET_CONFIG (0x78) command whose 40-byte payload is the flag NAME as ASCII,
// NUL-padded to 32 bytes, then a one-byte value (itself an ASCII digit: '1'=0x31 or '2'=0x32) at
// offset 32, then 7 zero bytes. The inner b3 byte (0x01) is carried as the first payload byte ahead
// of the body, exactly like CLIENT_HELLO. Reversible (only changes which data the strap emits), gated
// behind an explicit opt-in, and writable only on real iOS/Android hardware. (#174)
object Whoop5Config {

    /** SET_CONFIG / SET_FF_VALUE command opcode. */
    const val SET_CONFIG_CMD = 0x78

    /** SET_DEVICE_CONFIG opcode (0x77). Writes one persistent device-config value (vs the feature-flag
     *  SET_CONFIG/0x78). Used for the Broadcast-HR flag; validated on real hardware. Keep in lockstep
     *  with the Swift `Whoop5Config.setDeviceConfigCmd`. (#181) */
    const val SET_DEVICE_CONFIG_CMD = 0x77

    /** One persistent feature flag and the value the official app writes for it (ASCII '1'/'2'). */
    data class Flag(val name: String, val value: Int)

    /** The exact ordered enable sequence the official app sends, transcribed verbatim from
     *  judes.club's frame-builder FLAGS array. `enable_r22_packets` opens the type-0x2F biometric
     *  stream; the rest tune channel selection, wear detection and sleep behaviour. Keep in lockstep
     *  with the Swift `Whoop5Config.enableR22Sequence`. */
    val enableR22Sequence: List<Flag> = listOf(
        Flag("enable_r22_packets", 0x32),
        Flag("enable_r22_v2_packets", 0x32),
        Flag("enable_r22_v3_packets", 0x32),
        Flag("enable_r22_v4_packets", 0x31),
        Flag("enable_r22_v5_packets", 0x32),
        Flag("enable_r22_v6_packets", 0x32),
        Flag("enable_r22_v8_packets", 0x32),
        Flag("make_hrfm_visible", 0x32),
        Flag("disable_pip_r26_packets", 0x32),
        Flag("wear_detect_bias", 0x32),
        Flag("hr_ch_switching", 0x32),
        Flag("ir_hw_switching", 0x32),
        Flag("enable_passive_strap_fit_gen5", 0x31),
        Flag("enable_sig11_during_sleep", 0x32),
        Flag("dorset_inhibit_wpt", 0x32),
    )

    /** The 40-byte SET_CONFIG payload body: flag name as ASCII NUL-padded to 32 bytes, value byte at
     *  offset 32, then 7 zero bytes. (Mirrors judes.club `setConfigPayload(name, value)`.) */
    fun payloadBody(name: String, value: Int): ByteArray {
        val p = ByteArray(40)
        val bytes = name.toByteArray(Charsets.US_ASCII)
        for (i in 0 until minOf(32, bytes.size)) p[i] = bytes[i]
        p[32] = (value and 0xFF).toByte()
        return p
    }

    /** The device-config write body: key name as ASCII NUL-padded to 32 bytes, then the value byte (an
     *  ASCII digit, e.g. '1'=0x31 / '0'=0x30). 33 bytes, no trailing padding (unlike the 40-byte
     *  feature-flag body). The caller prepends the b3 byte (0x01) before sending, like CLIENT_HELLO.
     *  Validated for whoop_live_hr_in_adv_ind_pkt on real hardware (paired on a Garmin Edge 840).
     *  Keep in lockstep with the Swift `Whoop5Config.deviceConfigBody`. (#181) */
    fun deviceConfigBody(name: String, value: Int): ByteArray {
        val b = ByteArray(33)
        val bytes = name.toByteArray(Charsets.US_ASCII)
        for (i in 0 until minOf(32, bytes.size)) b[i] = bytes[i]
        b[32] = (value and 0xFF).toByte()
        return b
    }

    /** The full puffin command-frame bytes for one feature-flag write (b3=0x01 ahead of the body),
     *  ready to send to the 5/MG command characteristic. Byte-for-byte identical to the official
     *  app's captured writes and to the Swift `Whoop5Config.frame`. */
    fun frame(flag: Flag, seq: Int): ByteArray =
        Framing.puffinCommandFrame(
            cmd = SET_CONFIG_CMD,
            seq = seq,
            payload = byteArrayOf(0x01) + payloadBody(flag.name, flag.value),
        )

    // Sensor-stream START burst — begins the type-0x2F deep stream (#278/#276). The R22 flags above only
    // configure WHICH deep packets the strap may emit; they don't start the stream (a strap ACKed all 15
    // flags but sent no type-0x2F). The official app ALSO sends this short burst of sensor-stream commands
    // to turn the stream on. Command numbers + payloads are protocol facts from the b-nnett/goose 5/MG
    // mapping (startPhysiologyCapture), built with NOOP's own puffin envelope. cmd 63 is the missing
    // R10/R11 raw-stream framing. Keep in lockstep with the Swift `Whoop5Config.deepStreamStartSequence`.

    /** [revision=1, enabled] — the two-byte body the IMU/optical/persistent toggles take. */
    fun revisionBoolean(on: Boolean): ByteArray = byteArrayOf(1, (if (on) 1 else 0).toByte())

    /** One sensor-stream command: the puffin command + its inner payload bytes. */
    class StreamStart(val cmd: CommandNumber, val payload: ByteArray)

    /** The start burst, in the official app's order: realtime HR, the R10/R11 raw stream, then the
     *  IMU/optical/persistent toggles. Sent AFTER enableR22Sequence, each as one puffin command WITH
     *  RESPONSE. Reversible — it only turns the stream on. */
    val deepStreamStartSequence: List<StreamStart> = listOf(
        StreamStart(CommandNumber.TOGGLE_REALTIME_HR, byteArrayOf(0x01)),
        StreamStart(CommandNumber.SEND_R10_R11_REALTIME, byteArrayOf(0x01)),
        StreamStart(CommandNumber.TOGGLE_IMU_MODE, revisionBoolean(true)),
        StreamStart(CommandNumber.TOGGLE_PERSISTENT_R21, revisionBoolean(true)),
        StreamStart(CommandNumber.ENABLE_OPTICAL_DATA, revisionBoolean(true)),
        StreamStart(CommandNumber.TOGGLE_OPTICAL_MODE, revisionBoolean(true)),
        StreamStart(CommandNumber.TOGGLE_PERSISTENT_R20, revisionBoolean(true)),
    )

    /** Every start-burst command framed with the puffin envelope, sequence-numbered from firstSeq. */
    fun deepStreamStartFrames(firstSeq: Int = 1): List<ByteArray> =
        deepStreamStartSequence.mapIndexed { idx, s ->
            Framing.puffinCommandFrame(cmd = s.cmd.rawValue, seq = (firstSeq + idx) and 0xFF, payload = s.payload)
        }
}
