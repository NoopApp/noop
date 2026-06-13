import XCTest
@testable import Strand

@MainActor
final class LiveStateRRRecentTests: XCTestCase {
    func testRRRecentAccumulatesPacketsWhileKeepingLatestPacketSeparate() {
        let state = LiveState()

        state.setRRIntervals([810, 805], recentLimit: 4)
        state.setRRIntervals([798, 802, 799], recentLimit: 4)

        XCTAssertEqual(state.rr, [798, 802, 799])
        XCTAssertEqual(state.rrRecent, [805, 798, 802, 799])
        XCTAssertEqual(state.rrPacketsThisSession, 2)
        XCTAssertNotNil(state.lastRRPacketAt)
    }

    func testHeartRateSampleMetadataTracksLiveHeartRateWithoutRR() {
        let state = LiveState()

        state.setHeartRate(72)

        XCTAssertEqual(state.heartRate, 72)
        XCTAssertEqual(state.heartRateSamplesThisSession, 1)
        XCTAssertNotNil(state.lastHeartRateSampleAt)
        XCTAssertTrue(state.rrRecent.isEmpty)
        XCTAssertEqual(
            LiveView.rrEmptyMessage(hasLiveHeartRate: true, activeConnection: true),
            "Heart rate is live; this stream has not delivered R-R intervals yet."
        )
    }

    func testClearBiometricsDropsLiveAndRecentValues() {
        let state = LiveState()
        state.setHeartRate(72)
        state.setRRIntervals([830, 825])

        state.clearBiometrics()

        XCTAssertNil(state.heartRate)
        XCTAssertNil(state.lastHeartRateSampleAt)
        XCTAssertEqual(state.heartRateSamplesThisSession, 0)
        XCTAssertTrue(state.rr.isEmpty)
        XCTAssertTrue(state.rrRecent.isEmpty)
        XCTAssertNil(state.lastRRPacketAt)
        XCTAssertEqual(state.rrPacketsThisSession, 0)
    }
}
