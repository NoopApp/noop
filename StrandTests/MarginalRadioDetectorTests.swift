import XCTest
@testable import Strand

/// Pins the #80 marginal-radio fallback decision: a flaky Bluetooth radio (2016 Mac / OpenCore) drops
/// the WHOOP 4 link the instant NOOP arms the R10/R11 raw realtime burst, loops on rescan, and re-arms.
/// MarginalRadioDetector watches for CONSECUTIVE arm-then-quick-timeout cycles and, after the threshold,
/// tells BLEManager to skip the heavy arm and ride the low-bandwidth 0x2A37 standard HR profile instead.
/// Pure value type → no CoreBluetooth seam needed.
final class MarginalRadioDetectorTests: XCTestCase {

    // Two consecutive arm-then-quick-timeout cycles trip the fallback; the trip is reported exactly once.
    func testTripsAfterTwoConsecutiveArmTimeouts() {
        var d = MarginalRadioDetector()        // default tripThreshold=2, window=20s
        XCTAssertFalse(d.connectionEnded(wasArmed: true, secondsSinceArm: 3, timedOut: true),
                       "one arm-then-timeout is noise, not yet a trip")
        XCTAssertFalse(d.tripped)
        XCTAssertTrue(d.connectionEnded(wasArmed: true, secondsSinceArm: 4, timedOut: true),
                      "second consecutive arm-then-timeout trips the fallback")
        XCTAssertTrue(d.tripped)
        // Already tripped → no second "freshly tripped" signal (caller must log/surface only once).
        XCTAssertFalse(d.connectionEnded(wasArmed: true, secondsSinceArm: 2, timedOut: true))
        XCTAssertTrue(d.tripped)
    }

    // A single drop must never trip — links die for benign reasons. Below threshold stays untripped.
    func testSingleDropDoesNotTrip() {
        var d = MarginalRadioDetector()
        XCTAssertFalse(d.connectionEnded(wasArmed: true, secondsSinceArm: 1, timedOut: true))
        XCTAssertFalse(d.tripped)
        XCTAssertEqual(d.consecutiveArmTimeouts, 1)
    }

    // A drop that lands LONG after arming is an unrelated late flap, not the arm burst choking the radio.
    // It must break the streak rather than count toward a trip (don't mis-trip a healthy radio).
    func testTimeoutOutsideWindowBreaksStreak() {
        var d = MarginalRadioDetector(tripThreshold: 2, quickTimeoutWindow: 20)
        XCTAssertFalse(d.connectionEnded(wasArmed: true, secondsSinceArm: 5, timedOut: true))
        XCTAssertEqual(d.consecutiveArmTimeouts, 1)
        // 120s after arming: the heavy stream clearly survived the arm — this drop is unrelated.
        XCTAssertFalse(d.connectionEnded(wasArmed: true, secondsSinceArm: 120, timedOut: true))
        XCTAssertEqual(d.consecutiveArmTimeouts, 0, "a late drop resets the arm-timeout streak")
        XCTAssertFalse(d.tripped)
    }

    // An intentional / non-timeout disconnect (timedOut:false) must never count toward the streak.
    func testIntentionalDisconnectDoesNotCount() {
        var d = MarginalRadioDetector()
        XCTAssertFalse(d.connectionEnded(wasArmed: true, secondsSinceArm: 2, timedOut: true))
        XCTAssertFalse(d.connectionEnded(wasArmed: true, secondsSinceArm: 2, timedOut: false))
        XCTAssertEqual(d.consecutiveArmTimeouts, 0, "a clean (non-timeout) close resets suspicion")
        // ...and now it takes two fresh arm-timeouts again to trip.
        XCTAssertFalse(d.connectionEnded(wasArmed: true, secondsSinceArm: 2, timedOut: true))
        XCTAssertTrue(d.connectionEnded(wasArmed: true, secondsSinceArm: 2, timedOut: true))
        XCTAssertTrue(d.tripped)
    }

    // A drop where we never armed the burst (wasArmed:false — e.g. already in standard-HR mode) can't be
    // blamed on the arm and must reset the streak.
    func testUnarmedDropResetsStreak() {
        var d = MarginalRadioDetector()
        XCTAssertFalse(d.connectionEnded(wasArmed: true, secondsSinceArm: 2, timedOut: true))
        XCTAssertEqual(d.consecutiveArmTimeouts, 1)
        XCTAssertFalse(d.connectionEnded(wasArmed: false, secondsSinceArm: nil, timedOut: true))
        XCTAssertEqual(d.consecutiveArmTimeouts, 0)
    }

    // A timeout with no arm timestamp (secondsSinceArm == nil) can't be classified as quick → no count.
    func testNilSinceArmDoesNotCount() {
        var d = MarginalRadioDetector()
        XCTAssertFalse(d.connectionEnded(wasArmed: true, secondsSinceArm: nil, timedOut: true))
        XCTAssertEqual(d.consecutiveArmTimeouts, 0)
        XCTAssertFalse(d.tripped)
    }

    // reset() clears everything — used when the user re-opens Live / taps Start HR, or on a clean
    // user-initiated disconnect, so a transient radio hiccup isn't a permanent sentence.
    func testResetClearsState() {
        var d = MarginalRadioDetector()
        _ = d.connectionEnded(wasArmed: true, secondsSinceArm: 2, timedOut: true)
        _ = d.connectionEnded(wasArmed: true, secondsSinceArm: 2, timedOut: true)
        XCTAssertTrue(d.tripped)
        d.reset()
        XCTAssertFalse(d.tripped)
        XCTAssertEqual(d.consecutiveArmTimeouts, 0)
        // After reset it takes the full threshold again to re-trip.
        XCTAssertFalse(d.connectionEnded(wasArmed: true, secondsSinceArm: 2, timedOut: true))
        XCTAssertFalse(d.tripped)
    }

    // A custom higher threshold (e.g. 3) requires that many consecutive cycles.
    func testCustomThreshold() {
        var d = MarginalRadioDetector(tripThreshold: 3, quickTimeoutWindow: 20)
        XCTAssertFalse(d.connectionEnded(wasArmed: true, secondsSinceArm: 1, timedOut: true))
        XCTAssertFalse(d.connectionEnded(wasArmed: true, secondsSinceArm: 1, timedOut: true))
        XCTAssertFalse(d.tripped)
        XCTAssertTrue(d.connectionEnded(wasArmed: true, secondsSinceArm: 1, timedOut: true))
        XCTAssertTrue(d.tripped)
    }
}
