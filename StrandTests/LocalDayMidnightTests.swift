import XCTest
@testable import Strand
import StrandAnalytics

/// #277 — IntelligenceEngine's LOCAL-midnight floor used to re-bucket daily metrics by the device's
/// local calendar day (the bucket the dashboard reads). Mirrors the Android
/// LocalDayBucketingTest.midnightLocal_* cases byte-for-byte in logic/constants.
@MainActor
final class LocalDayMidnightTests: XCTestCase {

    func testMidnightLocalFloorsToLocalMidnightWestOfUTC() {
        // UTC-4: local 21:00 on 2021-06-15 == 01:00 UTC 2021-06-16 == 1623805200. Local midnight is
        // 2021-06-15 00:00 local == 04:00 UTC == 1623729600.
        let offset = -4 * 3600
        let tsUtc = 1_623_805_200
        XCTAssertEqual(IntelligenceEngine.midnightLocal(tsUtc, offsetSec: offset), 1_623_729_600)
        // The floored value, re-keyed under the same offset, is the local day.
        XCTAssertEqual(
            AnalyticsEngine.dayString(IntelligenceEngine.midnightLocal(tsUtc, offsetSec: offset),
                                      offsetSec: offset),
            "2021-06-15")
    }

    func testMidnightLocalOffsetZeroEqualsMidnightUtc() {
        // floorMod-based local floor with offset 0 must equal the legacy UTC midnight floor for any sign.
        for ts in [1_609_459_200, 1_609_459_200 + 45_000, 0, 86_399, -1, -86_401] {
            XCTAssertEqual(IntelligenceEngine.midnightLocal(ts, offsetSec: 0),
                           IntelligenceEngine.midnightUtc(ts),
                           "midnightLocal(offset=0) must equal midnightUtc for ts=\(ts)")
        }
    }

    func testMidnightLocalNegativeOffsetSignCorrect() {
        // The floored local midnight must be <= ts and land exactly on a local-day boundary
        // (ts+offset divisible by 86400). Guards floorMod sign for negative offsets/timestamps.
        let offset = -5 * 3600 // UTC-5
        for ts in [1_623_805_200, 1_600_000_000, 100] {
            let mid = IntelligenceEngine.midnightLocal(ts, offsetSec: offset)
            let mod = ((mid + offset) % 86_400 + 86_400) % 86_400
            XCTAssertEqual(mod, 0, "must land on a local-day boundary")
            XCTAssertLessThanOrEqual(mid, ts, "midnight floor must not exceed ts")
            XCTAssertLessThan(ts - mid, 86_400, "floor must be within the same local day")
        }
    }
}
