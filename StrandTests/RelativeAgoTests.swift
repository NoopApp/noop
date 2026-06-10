import XCTest
@testable import Strand

/// Unit tests for `relativeAgo`, the pure helper behind the "History synced N ago" sync-status
/// line. Mirrors the Android RelativeAgoTest (ed6a31d) value-for-value so the two apps' labels
/// stay identical. Buckets to just-now / minutes / hours / days; clamps future times.
final class RelativeAgoTests: XCTestCase {

    private let now: TimeInterval = 1_781_000_000

    private func ago(_ sec: TimeInterval) -> String { relativeAgo(now - sec, now: now) }

    func testUnderAMinuteIsJustNow() {
        XCTAssertEqual(ago(0), "just now")
        XCTAssertEqual(ago(59), "just now")
    }

    func testMinutes() {
        XCTAssertEqual(ago(60), "1 min ago")
        XCTAssertEqual(ago(5 * 60), "5 min ago")
        XCTAssertEqual(ago(59 * 60), "59 min ago")
    }

    func testHours() {
        XCTAssertEqual(ago(3600), "1 h ago")
        XCTAssertEqual(ago(23 * 3600), "23 h ago")
    }

    func testDays() {
        XCTAssertEqual(ago(86_400), "1 d ago")
        XCTAssertEqual(ago(3 * 86_400), "3 d ago")
    }

    func testFutureTimestampClampsToJustNow() {
        // Strap-clock skew could put lastSyncedAt slightly in the future; never render negative.
        XCTAssertEqual(relativeAgo(now + 500, now: now), "just now")
    }
}
