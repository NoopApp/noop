import XCTest
@testable import WhoopProtocol

/// WHOOP 5.0 ("puffin") EVENT (type 48) decode, verified against real captured frames.
///
/// The 5.0 inner record starts at byte 8 (vs 4.0's byte 4), so the static schema fields sit at their
/// 4.0 offset + 4: `event` (u8/EventNumber) at frame[10] and `event_timestamp` (u32 real unix) at
/// frame[12] — already surfaced by the `parseFrameWhoop5` static walk. The per-event BATTERY_LEVEL
/// payload follows the same +4 rule: 4.0's soc@17/mv@21/charge@26 become 5.0's soc@21/mv@25/charge@30.
/// Unlike the 5.0 COMMAND_RESPONSE (which switched to a DIRECT percent), the EVENT battery keeps 4.0's
/// deci-percent (÷10) — verified by a clean monotonic discharge across the capture (49.9 → 47.7 %).
///
/// Drift guard: event NAMES come only from the shared `EventNumber` schema. Numbers the firmware emits
/// that the schema does not name (e.g. 123) MUST stay raw `0x7B(123)` — never borrowed from another
/// enum (`CommandNumber` 123 is `SELECT_WRIST`) and never invented. All fixtures are real frames,
/// verified to carry no device name / serial / token (battery + simple events do not).
final class Whoop5EventTests: XCTestCase {

    private func bytes(_ s: String) -> [UInt8] {
        var out = [UInt8](); var i = s.startIndex
        while i < s.endIndex {
            let j = s.index(i, offsetBy: 2)
            out.append(UInt8(s[i..<j], radix: 16)!); i = j
        }
        return out
    }

    /// Real BATTERY_LEVEL(3) event, soc payload `02 f3 01 …`: u16@21 = 0x01f3 = 499 → 49.9 %,
    /// mv u16@25 = 0x0ef9 = 3833 mV, charge u8@30 = 0 (worn, not charging).
    private let batteryEventHex =
        "aa01240001002eb130350300a589266a5118140002f3010000f90e00000000340806003500000000358eb56f"

    func testBatteryLevelEventDecodesPayload() {
        let f = parseFrame(bytes(batteryEventHex), family: .whoop5)
        XCTAssertEqual(f.typeName, "EVENT")
        XCTAssertEqual(f.crcOK, true)
        XCTAssertEqual(f.parsed["event"]?.stringValue, "BATTERY_LEVEL(3)")
        XCTAssertEqual(f.parsed["event_timestamp"]?.intValue, 1780910501)
        XCTAssertEqual(f.parsed["battery_pct"]?.doubleValue, 49.9)   // deci-percent ÷10, like 4.0
        XCTAssertEqual(f.parsed["battery_mV"]?.intValue, 3833)
        XCTAssertEqual(f.parsed["battery_charging"]?.intValue, 0)
    }

    /// Real DOUBLE_TAP(14) event — a simple event with no payload. The static +4 walk alone must
    /// surface the event name and real-unix timestamp (regression guard for the basic path).
    private let doubleTapHex = "aa0110000100208130340e008089266a3d2a000030b8df92"

    func testSimpleEventDecodesNameAndTimestamp() {
        let f = parseFrame(bytes(doubleTapHex), family: .whoop5)
        XCTAssertEqual(f.typeName, "EVENT")
        XCTAssertEqual(f.crcOK, true)
        XCTAssertEqual(f.parsed["event"]?.stringValue, "DOUBLE_TAP(14)")
        XCTAssertEqual(f.parsed["event_timestamp"]?.intValue, 1780910464)
        XCTAssertNil(f.parsed["battery_pct"])   // not a battery event
    }

    /// Real type-48 frame whose event byte is 123 — a number the `EventNumber` schema does not name.
    /// It must render as raw `0x7B(123)`, NOT a name pulled from `CommandNumber` (123 = SELECT_WRIST)
    /// or invented. No battery / command keys may leak onto a non-battery event.
    private let unknownEventHex =
        "aa011800010022e130f67b002688266a00000800010100020200000076843ad3"

    func testUnknownEventNumberStaysRaw() {
        let f = parseFrame(bytes(unknownEventHex), family: .whoop5)
        XCTAssertEqual(f.typeName, "EVENT")
        XCTAssertEqual(f.crcOK, true)
        XCTAssertEqual(f.parsed["event"]?.stringValue, "0x7B(123)")
        XCTAssertNil(f.parsed["battery_pct"])
        XCTAssertNil(f.parsed["battery_mV"])
        XCTAssertNil(f.parsed["clock"])
    }
}
