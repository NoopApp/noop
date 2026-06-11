import XCTest
@testable import Strand

/// Pins the gating for the #80 low-bandwidth standard-HR note on the Live screen. When the marginal-radio
/// detector trips, BLEManager skips the WHOOP 4 R10/R11 raw burst and live HR rides the standard BLE
/// Heart-Rate profile — LiveState.standardHRMode then carries the explanation string. LiveView only renders
/// the calm inline note when that string is actually present and non-empty; this pins that pure decision so
/// a nil/blank note can never leave an empty banner on screen.
final class StandardHRNoteTests: XCTestCase {

    // A real explanation string → the note renders.
    func testNonEmptyNoteShows() {
        XCTAssertTrue(LiveView.shouldShowStandardHRNote(
            "Standard HR mode (low bandwidth) — your Bluetooth radio couldn't sustain the full stream."))
    }

    // No fallback engaged (the normal full-stream case) → no note.
    func testNilNoteHidden() {
        XCTAssertFalse(LiveView.shouldShowStandardHRNote(nil))
    }

    // An empty string must not render an empty banner.
    func testEmptyNoteHidden() {
        XCTAssertFalse(LiveView.shouldShowStandardHRNote(""))
    }

    // A whitespace-only string is effectively empty → no note.
    func testWhitespaceOnlyNoteHidden() {
        XCTAssertFalse(LiveView.shouldShowStandardHRNote("   \n\t  "))
    }

    // Leading/trailing whitespace around real content still shows (we don't trim what we display, only the
    // emptiness test trims).
    func testPaddedRealContentShows() {
        XCTAssertTrue(LiveView.shouldShowStandardHRNote("  live HR via standard profile  "))
    }
}
