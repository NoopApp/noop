import XCTest
import GRDB
import WhoopProtocol
@testable import WhoopStore

/// v12 migration + COALESCE read: PPG-derived HR from the WHOOP 5.0 v26 optical buffer (#156).
final class PpgHrSampleTests: XCTestCase {
    func testV12CreatesPpgHrTable() async throws {
        let store = try await WhoopStore.inMemory()
        let tables = try await store.tableNames()
        XCTAssertTrue(tables.contains("ppgHrSample"))
    }

    func testPpgHrPrimaryKeyIsDeviceIdTs() async throws {
        let store = try await WhoopStore.inMemory()
        let cols = try await store.primaryKeyColumns("ppgHrSample")
        XCTAssertEqual(cols, ["deviceId", "ts"])
    }

    func testPpgHrInsertRoundTripAndDedup() async throws {
        let store = try await WhoopStore.inMemory()
        let streams = Streams(ppgHr: [
            PpgHrSample(ts: 1_780_916_150, bpm: 62.5, conf: 0.81),
            PpgHrSample(ts: 1_780_916_151, bpm: 63.0, conf: 0.79),
        ])
        _ = try await store.insert(streams, deviceId: "my-whoop")
        let n1 = try await store.ppgHrCountForTest()
        XCTAssertEqual(n1, 2)
        // Re-inserting the same (deviceId, ts) is idempotent — ON CONFLICT DO NOTHING.
        _ = try await store.insert(streams, deviceId: "my-whoop")
        let n2 = try await store.ppgHrCountForTest()
        XCTAssertEqual(n2, 2)
    }

    /// hrBuckets COALESCEs: a measured second wins, a PPG-only second fills the gap.
    func testHrBucketsCoalescesPpgWhereNoMeasuredHr() async throws {
        let store = try await WhoopStore.inMemory()
        let dev = "my-whoop"
        let base = 1_780_000_000
        // Measured hr at t=base (90 bpm); PPG at base (will be IGNORED — measured wins) and at base+1
        // (no measured → used). Same bucket so the average reflects which rows were included.
        try await store.insert(Streams(hr: [HRSample(ts: base, bpm: 90)]), deviceId: dev)
        try await store.insert(Streams(ppgHr: [
            PpgHrSample(ts: base, bpm: 60, conf: 0.9),       // shadowed by measured 90
            PpgHrSample(ts: base + 1, bpm: 70, conf: 0.9),   // fills the gap
        ]), deviceId: dev)

        // One wide bucket covering both seconds → mean of {90 (measured), 70 (ppg)} = 80, NOT
        // including the shadowed 60. If the COALESCE were wrong the mean would shift.
        let buckets = try await store.hrBuckets(deviceId: dev, from: base, to: base + 10, bucketSeconds: 60)
        XCTAssertEqual(buckets.count, 1)
        XCTAssertEqual(buckets[0].bpm, 80.0, accuracy: 0.001)
    }

    func testHrSamplesCoalescesPpgWhereNoMeasuredHr() async throws {
        let store = try await WhoopStore.inMemory()
        let dev = "my-whoop"
        let base = 1_780_000_000
        try await store.insert(Streams(hr: [HRSample(ts: base, bpm: 90)]), deviceId: dev)
        try await store.insert(Streams(ppgHr: [
            PpgHrSample(ts: base, bpm: 60.2, conf: 0.9),
            PpgHrSample(ts: base + 1, bpm: 70.6, conf: 0.9),
        ]), deviceId: dev)

        let samples = try await store.hrSamples(deviceId: dev, from: base, to: base + 10, limit: 10)
        XCTAssertEqual(samples, [
            HRSample(ts: base, bpm: 90),
            HRSample(ts: base + 1, bpm: 71),
        ])
    }

    func testHrSampleDaysCountsPpgFallbackOnlyWhenMeasuredIsMissing() async throws {
        let store = try await WhoopStore.inMemory()
        let dev = "my-whoop"
        let base = 1_780_000_000
        try await store.insert(Streams(hr: [HRSample(ts: base, bpm: 90)]), deviceId: dev)
        try await store.insert(Streams(ppgHr: [
            PpgHrSample(ts: base, bpm: 60, conf: 0.9),
            PpgHrSample(ts: base + 1, bpm: 70, conf: 0.9),
        ]), deviceId: dev)

        let days = try await store.hrSampleDays(deviceId: dev, from: base, to: base + 10,
                                                minSamples: 1, limit: 10)
        XCTAssertEqual(days.count, 1)
        XCTAssertEqual(days[0].sampleCount, 2)
    }

    /// With no PPG rows at all, hrBuckets is unchanged from the measured-only behaviour.
    func testHrBucketsUnchangedWithoutPpg() async throws {
        let store = try await WhoopStore.inMemory()
        let dev = "my-whoop"
        let base = 1_780_000_000
        try await store.insert(Streams(hr: [
            HRSample(ts: base, bpm: 100),
            HRSample(ts: base + 1, bpm: 110),
        ]), deviceId: dev)
        let buckets = try await store.hrBuckets(deviceId: dev, from: base, to: base + 10, bucketSeconds: 60)
        XCTAssertEqual(buckets.count, 1)
        XCTAssertEqual(buckets[0].bpm, 105.0, accuracy: 0.001)
    }
}
