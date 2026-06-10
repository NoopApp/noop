import XCTest
import GRDB
import WhoopProtocol
@testable import WhoopStore

/// v10 migration: WHOOP5 step_motion_counter persistence (macOS parity with Android, #78).
final class StepSampleTests: XCTestCase {
    func testV10CreatesStepTable() async throws {
        let store = try await WhoopStore.inMemory()
        let tables = try await store.tableNames()
        XCTAssertTrue(tables.contains("stepSample"))
    }

    func testStepPrimaryKeyIsDeviceIdTs() async throws {
        let store = try await WhoopStore.inMemory()
        let cols = try await store.primaryKeyColumns("stepSample")
        XCTAssertEqual(cols, ["deviceId", "ts"])
    }

    func testStepInsertRoundTripAndDedup() async throws {
        let store = try await WhoopStore.inMemory()
        let streams = Streams(steps: [
            StepSample(ts: 1_780_916_150, counter: 50),
            StepSample(ts: 1_780_916_151, counter: 51),
        ])
        _ = try await store.insert(streams, deviceId: "my-whoop")
        let n1 = try await store.stepCountForTest()
        XCTAssertEqual(n1, 2)
        // Re-inserting the same (deviceId, ts) is idempotent — ON CONFLICT DO NOTHING.
        _ = try await store.insert(streams, deviceId: "my-whoop")
        let n2 = try await store.stepCountForTest()
        XCTAssertEqual(n2, 2)
    }
}
