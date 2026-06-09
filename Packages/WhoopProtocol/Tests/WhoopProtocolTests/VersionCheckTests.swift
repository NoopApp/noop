import XCTest
@testable import WhoopProtocol

/// Pins the version comparison behind "Check for updates" — headline being the string-compare trap
/// (`1.40` > `1.39`, `1.10` > `1.9`), plus the demo suffix and a leading "v".
final class VersionCheckTests: XCTestCase {

    func testNewer() {
        XCTAssertTrue(VersionCheck.isNewer("1.40", than: "1.39"))   // the trap: "1.40" < "1.39" as strings
        XCTAssertTrue(VersionCheck.isNewer("1.10", than: "1.9"))    // and "1.10" < "1.9" as strings
        XCTAssertTrue(VersionCheck.isNewer("2.0", than: "1.39"))
        XCTAssertTrue(VersionCheck.isNewer("1.39.1", than: "1.39"))
        XCTAssertTrue(VersionCheck.isNewer("v1.40", than: "1.39"))
    }

    func testNotNewer() {
        XCTAssertFalse(VersionCheck.isNewer("1.39", than: "1.39"))      // equal
        XCTAssertFalse(VersionCheck.isNewer("1.38", than: "1.39"))
        XCTAssertFalse(VersionCheck.isNewer("1.9", than: "1.10"))
        XCTAssertFalse(VersionCheck.isNewer("1.39-demo", than: "1.39"))
        XCTAssertFalse(VersionCheck.isNewer("garbage", than: "1.39"))   // unparseable → no false alarm
    }
}
