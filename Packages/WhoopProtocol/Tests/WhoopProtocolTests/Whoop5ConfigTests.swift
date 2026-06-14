import XCTest
@testable import WhoopProtocol

/// WHOOP 5.0/MG "R22" feature-flag enable sequence (deep-stream unlock).
///
/// These pin the byte-level encoding against the publicly-documented protocol (judes.club's
/// frame-builder + Asherlc/dofek's APK decompilation). The golden `enable_r22_packets` frame below was
/// produced independently from judes.club's `setConfigPayload`/`command` algorithm and confirmed to match
/// what NOOP's own `puffinCommandFrame` emits — so a regression in either the framing or the flag table
/// will fail here, with no hardware needed.
final class Whoop5ConfigTests: XCTestCase {

    private func hex(_ b: [UInt8]) -> String { b.map { String(format: "%02x", $0) }.joined(separator: " ") }

    func testPayloadBodyIsAsciiNameNulPaddedWithValueAt32() {
        let body = Whoop5Config.payloadBody(name: "enable_r22_packets", value: 0x32)
        XCTAssertEqual(body.count, 40)
        XCTAssertEqual(Array(body[0..<18]), Array("enable_r22_packets".utf8))
        // bytes 18..<32 are zero padding
        XCTAssertTrue(body[18..<32].allSatisfy { $0 == 0 })
        XCTAssertEqual(body[32], 0x32, "value byte is the ASCII digit at offset 32")
        XCTAssertTrue(body[33..<40].allSatisfy { $0 == 0 })
    }

    /// Golden vector: the full SET_CONFIG frame for enable_r22_packets, seq=1, must equal the bytes the
    /// documented algorithm produces (envelope 0xAA/CRC16-Modbus + inner [0x23,seq,0x78,0x01]+40-byte body
    /// + CRC32). This is the load-bearing encoding assertion.
    func testEnableR22PacketsGoldenFrame() {
        let frame = Whoop5Config.frame(flag: Whoop5Config.Flag("enable_r22_packets", 0x32), seq: 1)
        let expected = "aa 01 30 00 00 01 eb 11 23 01 78 01 65 6e 61 62 6c 65 5f 72 32 32 5f 70 61 63 6b 65 74 73 00 00 00 00 00 00 00 00 00 00 00 00 00 00 32 00 00 00 00 00 00 00 d2 ee b0 b7"
        XCTAssertEqual(hex(frame), expected)
    }

    /// The built frame must round-trip through NOOP's own 5.0 frame verifier (CRC16 header + CRC32 tail),
    /// proving the strap-side integrity checks would accept it.
    func testEnableR22PacketsFrameVerifies() {
        let frame = Whoop5Config.frame(flag: Whoop5Config.Flag("enable_r22_packets", 0x32), seq: 7)
        let check = verifyFrame(frame, family: .whoop5)
        XCTAssertTrue(check.ok, "SET_CONFIG frame must pass whoop5 CRC verification")
    }

    func testEnableSequenceIsFifteenFlagsWithDistinctSeqs() {
        let frames = Whoop5Config.enableSequenceFrames(firstSeq: 1)
        XCTAssertEqual(frames.count, 15)
        XCTAssertEqual(Whoop5Config.enableR22Sequence.first?.name, "enable_r22_packets")
        // seq byte lives at inner offset 1 (frame offset 9): 1,2,3,…,15 for this sequence
        let seqs = frames.map { $0[9] }
        XCTAssertEqual(seqs, Array(1...15))
        // v4 is the one flag whose value is ASCII '1' (0x31), per the documented table
        let v4 = Whoop5Config.enableR22Sequence.first { $0.name == "enable_r22_v4_packets" }
        XCTAssertEqual(v4?.value, 0x31)
    }

    /// Broadcast-HR device-config body (#181): key name ASCII NUL-padded to 32 bytes, then the value
    /// byte (ASCII digit) at offset 32 — 33 bytes total, no trailing padding. Mirrors the Android
    /// `BroadcastHrConfigTest`. Validated on real hardware (paired on a Garmin Edge 840).
    func testDeviceConfigBodyIsNameNullPaddedThenAsciiValue() {
        let body = Whoop5Config.deviceConfigBody(name: "whoop_live_hr_in_adv_ind_pkt", value: 0x31)
        XCTAssertEqual(body.count, 33)
        let name = Array("whoop_live_hr_in_adv_ind_pkt".utf8)   // 28 bytes
        XCTAssertEqual(Array(body[0..<name.count]), name)
        for i in name.count..<32 { XCTAssertEqual(body[i], 0, "expected NUL pad at \(i)") }
        XCTAssertEqual(body[32], 0x31, "value byte should be ASCII '1'")
        XCTAssertEqual(Whoop5Config.deviceConfigBody(name: "whoop_live_hr_in_adv_ind_pkt", value: 0x30)[32], 0x30)
    }

    /// The deep-stream START burst (#278/#276): the sensor-stream "on" commands that actually begin the
    /// type-0x2F stream after the R22 flags. Command numbers transcribed from b-nnett/goose's 5/MG
    /// mapping, built with NOOP's own puffin envelope. cmd 63 (payload [0x01]) is the R10/R11 raw-stream
    /// framing #278 reported missing as "no WHOOP 5/MG framing for this command yet".
    func testDeepStreamStartSequence() {
        let seq = Whoop5Config.deepStreamStartSequence
        // Official-app order: realtime HR, the R10/R11 raw stream, then IMU/optical/persistent toggles.
        XCTAssertEqual(seq.map { $0.cmd }, [3, 63, 106, 154, 107, 108, 153])
        XCTAssertEqual(seq[0].payload, [0x01])         // TOGGLE_REALTIME_HR on
        XCTAssertEqual(seq[1].payload, [0x01])         // SEND_R10_R11_REALTIME on
        XCTAssertEqual(seq[2].payload, [0x01, 0x01])   // revisionBoolean(true)

        let frames = Whoop5Config.deepStreamStartFrames(firstSeq: 1)
        XCTAssertEqual(frames.count, 7)
        // seq byte at inner offset 1 (frame offset 9): 1…7, distinct and incrementing
        XCTAssertEqual(frames.map { $0[9] }, Array(1...7))
        // every frame is a well-formed puffin command envelope (CRC16 header + CRC32 payload)
        for f in frames { XCTAssertTrue(verifyFrame(f, family: .whoop5).ok, "start-burst frame must pass whoop5 CRC verification") }

        // The R10/R11 raw-stream command, byte-for-byte: type(0x23) seq(2) cmd(63) payload(0x01 = on).
        let r10r11 = frames[1]
        XCTAssertEqual(r10r11[8], 0x23, "inner packet type = COMMAND")
        XCTAssertEqual(r10r11[9], 2,    "seq")
        XCTAssertEqual(r10r11[10], 63,  "command number = SEND_R10_R11_REALTIME")
        XCTAssertEqual(r10r11[11], 0x01, "payload = on")
    }
}
