import XCTest
@testable import WhoopProtocol

/// type-47 HISTORICAL_DATA from a **real WHOOP 4** (firmware 41.17.6.0), captured over BlueZ on
/// 2026-06-08 with the tool's new 4.0 offload handshake (`whoop_capture.py --model whoop4
/// --history-ack`, which walks the trim cursor by echoing each HISTORY_END as a
/// HISTORICAL_DATA_RESULT(23) — the 4.0 image of the whoop5 handshake).
///
/// **Firmware-drift check (the point of this test):** the WHOOP 5 surprised us by emitting a
/// version-18 historical record, not the documented v24 (see `Whoop5HistoricalTests`). The question
/// was whether this older-firmware WHOOP 4 still emits the documented **v24**, or had likewise drifted.
/// It has NOT: all 1704 type-47 frames in the capture decoded as v24, CRC-valid, so the documented
/// decoder is confirmed on a second device + generation. `HistoricalV24Tests` proves the v24 layout
/// against a synthetic record; this proves the same decoder on a real on-wrist frame.
///
/// Real type-47 records carry no device name / serial / session token (only biometrics + timestamp),
/// so a real frame is a safe committed fixture.
final class Whoop4HistoricalV24HardwareTests: XCTestCase {

    // Real on-wrist v24 record: version 24, HR 109, two R-R intervals, gravity ~1 g.
    private let realV24Hex =
        "aa6400a12f18054c1c0a023ed0266a5037805418016d022b0234020000000000006b07ff00" +
        "85593c1f65cebed7b3e63eb85a5f3f000080401f65cebed7b3e63eb85a5f3f500264025d03" +
        "640229014009010c020c00000000000f0001c4020000000000008fdeb278"

    private func bytes(_ s: String) -> [UInt8] {
        var out = [UInt8](); out.reserveCapacity(s.count / 2); var i = s.startIndex
        while i < s.endIndex { let j = s.index(i, offsetBy: 2)
            out.append(UInt8(s[i..<j], radix: 16)!); i = j }
        return out
    }

    func testRealWhoop4RecordIsV24() {
        let out = parseFrame(bytes(realV24Hex))
        XCTAssertTrue(out.ok)
        XCTAssertEqual(out.typeName, "HISTORICAL_DATA")
        XCTAssertEqual(out.crcOK, true)                       // real captured frame, CRC intact
        XCTAssertEqual(out.parsed["hist_version"]?.intValue, 24)   // NOT drifted (cf. WHOOP 5 → v18)
    }

    func testRealWhoop4BiometricsCrossCheck() {
        let p = parseFrame(bytes(realV24Hex)).parsed
        XCTAssertEqual(p["unix"]?.intValue, 1780928574)      // real unix, 2026-06-08
        XCTAssertEqual(p["heart_rate"]?.intValue, 109)
        XCTAssertEqual(p["rr_count"]?.intValue, 2)
        let rr = p["rr_intervals"]?.intArrayValue ?? []
        XCTAssertEqual(rr, [555, 564])
        // Physiological cross-check: 60000 / mean(R-R) ≈ heart_rate.
        let mean = Double(rr.reduce(0, +)) / Double(rr.count)
        XCTAssertEqual(60000.0 / mean, 109, accuracy: 3)
    }

    func testRealWhoop4GravityIsUnitVector() {
        let p = parseFrame(bytes(realV24Hex)).parsed
        guard case .double(let gx)? = p["gravity_x"],
              case .double(let gy)? = p["gravity_y"],
              case .double(let gz)? = p["gravity_z"] else {
            return XCTFail("gravity components must decode as unrounded .double")
        }
        let mag = (gx * gx + gy * gy + gz * gz).squareRoot()
        XCTAssertEqual(mag, 1.0, accuracy: 0.1)              // |g| ≈ 1 g confirms the accel mapping
    }

    func testRealWhoop4FeedsHistoricalStreams() {
        let out = parseFrame(bytes(realV24Hex))
        let st = extractHistoricalStreams([out], deviceClockRef: 0, wallClockRef: 0)
        XCTAssertEqual(st.hr, [HRSample(ts: 1780928574, bpm: 109)])
        XCTAssertEqual(st.rr.map { $0.rrMs }, [555, 564])
        XCTAssertEqual(st.gravity.first?.unit, "g")
    }

    // MARK: - Unmapped-firmware-version fallback (#30: no-sleep on unsupported firmware)

    func testUnmappedVersionFallsBackToV24WhenPhysicallyValid() {
        // The same real record, but with its version byte (frame[5]) relabeled to one the schema does
        // NOT map (25). Because firmware versions overwhelmingly share the v24 DSP layout, the fallback
        // should decode it via that layout — and accept it, since the result is physically valid
        // (|gravity| ≈ 1 g, HR plausible). Without this, the record would yield no gravity → no sleep.
        var f = bytes(realV24Hex)
        f[5] = 25
        let p = parseFrame(f).parsed
        XCTAssertEqual(p["hist_version"]?.intValue, 25)
        XCTAssertEqual(p["heart_rate"]?.intValue, 109)            // decoded via the v24 fallback
        XCTAssertEqual(p["rr_intervals"]?.intArrayValue ?? [], [555, 564])
        guard case .double(let gx)? = p["gravity_x"],
              case .double(let gy)? = p["gravity_y"],
              case .double(let gz)? = p["gravity_z"] else { return XCTFail("gravity must decode") }
        XCTAssertEqual((gx * gx + gy * gy + gz * gz).squareRoot(), 1.0, accuracy: 0.1)
    }

    func testUnmappedVersionRejectedWhenV24LayoutDoesNotFit() {
        // Unmapped version AND the v24 gravity offsets (40/44/48) wiped → |gravity| = 0, not ~1 g, so the
        // v24 layout clearly doesn't fit this firmware. The fallback must REJECT it (store nothing
        // garbage) while still surfacing the version, so the Backfiller can log it for manual mapping.
        var f = bytes(realV24Hex)
        f[5] = 25
        for i in 40..<52 { f[i] = 0 }
        let p = parseFrame(f).parsed
        XCTAssertEqual(p["hist_version"]?.intValue, 25)          // version still surfaced (diagnostic)
        XCTAssertNil(p["heart_rate"])                            // rejected → nothing decoded
        XCTAssertNil(p["gravity_x"])
    }
}
