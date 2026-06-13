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
    }

    func testClearBiometricsDropsLiveAndRecentValues() {
        let state = LiveState()
        state.heartRate = 72
        state.setRRIntervals([830, 825])

        state.clearBiometrics()

        XCTAssertNil(state.heartRate)
        XCTAssertTrue(state.rr.isEmpty)
        XCTAssertTrue(state.rrRecent.isEmpty)
    }
}
