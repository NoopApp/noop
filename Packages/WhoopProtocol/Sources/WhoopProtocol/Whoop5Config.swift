import Foundation

// MARK: - WHOOP 5.0 / MG "R22" feature-flag config (deep-stream unlock)
//
// WHOOP 5.0/MG straps withhold their deep biometric streams (the high-rate "R22" optical/HR/motion
// packets, type 0x2F) from a freshly-connected client. The official app switches them on by writing a
// short burst of persistent feature-flag config values right after the hello handshake — a sequence
// independently documented by two third parties:
//   • judes.club, "Cracking the WHOOP 5 Bluetooth Protocol" (decrypted HCI capture of the official app),
//     whose interactive frame-builder is the byte-level ground truth this file is validated against.
//   • Asherlc/dofek docs/whoop-ble-protocol.md (Android APK decompilation), corroborating the key names,
//     values and the SET_FF_VALUE (0x78) opcode.
//
// Each flag is ONE `SET_CONFIG` (0x78) command whose 40-byte payload is the flag NAME as ASCII, NUL-padded
// to 32 bytes, followed by a one-byte value (itself an ASCII digit: '1' = 0x31 or '2' = 0x32) at offset 32,
// then 7 bytes of zero. The command is built with the normal puffin envelope via `puffinCommandFrame`
// (cmd 0x78, the inner b3 byte 0x01 carried as the first payload byte, exactly like CLIENT_HELLO).
//
// This is reversible — it only changes which data the strap chooses to emit — but it is gated behind an
// explicit opt-in in the app, and on real hardware it can only be written from iOS/Android: macOS
// CoreBluetooth cannot complete the authenticated SMP bond the command characteristic requires.
public enum Whoop5Config {

    /// SET_CONFIG / SET_FF_VALUE command opcode.
    public static let setConfigCmd: UInt8 = 0x78

    /// SET_DEVICE_CONFIG opcode (0x77) — writes ONE persistent device-config value, distinct from the
    /// feature-flag SET_CONFIG (0x78) sequence above. Used for the "Broadcast HR" flag
    /// (`whoop_live_hr_in_adv_ind_pkt`), which makes the strap advertise its heart rate as a standard
    /// 0x180D BLE sensor. Validated on real hardware (paired on a Garmin Edge 840). (#181)
    public static let setDeviceConfigCmd: UInt8 = 0x77

    /// One persistent feature flag and the value the official app writes for it.
    public struct Flag: Equatable, Sendable {
        public let name: String
        public let value: UInt8   // ASCII digit byte: 0x32 = '2', 0x31 = '1'
        public init(_ name: String, _ value: UInt8) { self.name = name; self.value = value }
    }

    /// The exact ordered enable sequence the official app sends, transcribed verbatim from judes.club's
    /// frame-builder `FLAGS` array (values are ASCII '1'/'2'). `enable_r22_packets` is what opens the
    /// type-0x2F biometric stream; the rest tune channel selection, wear detection and sleep behaviour.
    public static let enableR22Sequence: [Flag] = [
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
    ]

    /// The 40-byte SET_CONFIG payload body: flag name as UTF-8/ASCII NUL-padded to 32 bytes, value byte
    /// at offset 32, then 7 zero bytes. (Mirrors judes.club `setConfigPayload(name, value)`.)
    public static func payloadBody(name: String, value: UInt8) -> [UInt8] {
        var p = [UInt8](repeating: 0, count: 40)
        let bytes = Array(name.utf8)
        for i in 0..<min(32, bytes.count) { p[i] = bytes[i] }
        p[32] = value
        return p
    }

    /// The 33-byte SET_DEVICE_CONFIG body: key name as ASCII NUL-padded to 32 bytes, then the value byte
    /// (an ASCII digit, '1' = 0x31 / '0' = 0x30) at offset 32 — NO trailing padding (unlike the 40-byte
    /// feature-flag body). The caller prepends the inner b3 byte (0x01) before sending, like CLIENT_HELLO.
    /// Mirrors the Android `Whoop5Config.deviceConfigBody`; validated on real hardware. (#181)
    public static func deviceConfigBody(name: String, value: UInt8) -> [UInt8] {
        var p = [UInt8](repeating: 0, count: 33)
        let bytes = Array(name.utf8)
        for i in 0..<min(32, bytes.count) { p[i] = bytes[i] }
        p[32] = value
        return p
    }

    /// The full puffin command-frame bytes for one feature-flag write, ready to send to the 5/MG
    /// command characteristic. The inner b3 byte (0x01, as SET_CONFIG-class commands require) is carried
    /// as the first payload byte ahead of the 40-byte body — matching the CLIENT_HELLO convention and
    /// byte-for-byte identical to the official app's captured writes.
    public static func frame(flag: Flag, seq: UInt8) -> [UInt8] {
        puffinCommandFrame(cmd: setConfigCmd, seq: seq, payload: [0x01] + payloadBody(name: flag.name, value: flag.value))
    }

    /// Every frame in the enable sequence, sequence-numbered from `firstSeq`. The caller writes these in
    /// order, WITH RESPONSE, spacing them out (the official app pauses ~tens of ms between writes), and
    /// only while the strap is on-wrist — the R22 stream is on-wrist gated.
    public static func enableSequenceFrames(firstSeq: UInt8 = 1) -> [[UInt8]] {
        enableR22Sequence.enumerated().map { idx, flag in
            frame(flag: flag, seq: UInt8((Int(firstSeq) + idx) & 0xFF))
        }
    }

    // MARK: - Sensor-stream START burst (begins the type-0x2F deep stream)
    //
    // The `enableR22Sequence` above only tells the strap WHICH deep packets it MAY emit — it does not
    // start the high-rate stream. That gap is exactly #278: a strap ACKed all 15 R22 flags but never
    // sent a type-0x2F packet, while NOOP's "R10/R11 raw stream" was dropped as "no framing yet". The
    // official app ALSO sends a short burst of sensor-stream commands that actually turn the stream on.
    // The command numbers + payloads below are protocol facts transcribed from the b-nnett/goose 5/MG
    // mapping (`GooseBLEClient.startPhysiologyCapture`) — re-expressed here in NOOP's own code and built
    // with NOOP's existing `puffinCommandFrame` envelope (no goose source is used). cmd 63
    // (SEND_R10_R11_REALTIME) is the raw-stream framing #278 reported missing.

    /// One sensor-stream command in the start burst: a puffin command number + its inner payload bytes.
    public struct StreamStart: Equatable, Sendable {
        public let cmd: UInt8
        public let payload: [UInt8]
        public init(_ cmd: UInt8, _ payload: [UInt8]) { self.cmd = cmd; self.payload = payload }
    }

    /// `[revision=1, enabled]` — the two-byte body the IMU/optical/persistent toggles take.
    public static func revisionBoolean(_ on: Bool) -> [UInt8] { [0x01, on ? 0x01 : 0x00] }

    /// The start burst, in the official app's order: realtime HR, the R10/R11 raw stream, then the
    /// IMU / optical / persistent toggles. Sent AFTER `enableR22Sequence` over the same encrypted command
    /// channel, each as one puffin command WITH RESPONSE. Reversible — it only turns the stream on.
    public static let deepStreamStartSequence: [StreamStart] = [
        StreamStart(3,   [0x01]),                 // TOGGLE_REALTIME_HR on
        StreamStart(63,  [0x01]),                 // SEND_R10_R11_REALTIME on  ← the missing raw stream
        StreamStart(106, revisionBoolean(true)),  // TOGGLE_IMU_MODE on (motion)
        StreamStart(154, revisionBoolean(true)),  // TOGGLE_PERSISTENT_R21 on
        StreamStart(107, revisionBoolean(true)),  // ENABLE_OPTICAL_DATA on (PPG)
        StreamStart(108, revisionBoolean(true)),  // TOGGLE_OPTICAL_MODE on
        StreamStart(153, revisionBoolean(true)),  // TOGGLE_PERSISTENT_R20 on
    ]

    /// Every start-burst command framed with the puffin envelope, sequence-numbered from `firstSeq`.
    public static func deepStreamStartFrames(firstSeq: UInt8 = 1) -> [[UInt8]] {
        deepStreamStartSequence.enumerated().map { idx, s in
            puffinCommandFrame(cmd: s.cmd, seq: UInt8((Int(firstSeq) + idx) & 0xFF), payload: s.payload)
        }
    }
}
