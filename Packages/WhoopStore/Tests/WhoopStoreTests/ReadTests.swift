import XCTest
import WhoopProtocol
@testable import WhoopStore

final class ReadTests: XCTestCase {
    private static let utcDayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    private static func utcDay(_ ts: Int) -> String {
        utcDayFormatter.string(from: Date(timeIntervalSince1970: TimeInterval(ts)))
    }

    private func seeded() async throws -> WhoopStore {
        let store = try await WhoopStore.inMemory()
        try await store.upsertDevice(id: "dev1", mac: nil, name: nil)
        try await store.upsertDevice(id: "other", mac: nil, name: nil)
        let s = Streams(
            hr: [HRSample(ts: 100, bpm: 60), HRSample(ts: 200, bpm: 61),
                 HRSample(ts: 300, bpm: 62)],
            rr: [RRInterval(ts: 100, rrMs: 800), RRInterval(ts: 100, rrMs: 820)],
            events: [WhoopEvent(ts: 150, kind: "BLE_CONNECTION_DOWN(12)",
                                payload: ["k": .int(9)])],
            battery: [BatterySample(ts: 120, soc: 88.0, mv: 3900)])
        _ = try await store.insert(s, deviceId: "dev1")
        // Decoy on another device — must never appear in dev1 reads.
        _ = try await store.insert(Streams(hr: [HRSample(ts: 200, bpm: 99)]), deviceId: "other")
        return store
    }

    func testHrSamplesRangeOrderLimitAndDeviceScope() async throws {
        let store = try await seeded()
        let all = try await store.hrSamples(deviceId: "dev1", from: 0, to: 1000, limit: 100)
        XCTAssertEqual(all, [HRSample(ts: 100, bpm: 60), HRSample(ts: 200, bpm: 61),
                             HRSample(ts: 300, bpm: 62)])
        let windowed = try await store.hrSamples(deviceId: "dev1", from: 150, to: 250, limit: 100)
        XCTAssertEqual(windowed, [HRSample(ts: 200, bpm: 61)])     // inclusive range
        let limited = try await store.hrSamples(deviceId: "dev1", from: 0, to: 1000, limit: 2)
        XCTAssertEqual(limited.count, 2)                            // ascending, first 2
        XCTAssertEqual(limited.first?.ts, 100)
    }

    func testHrBucketsAveragePerBucketOrderedAndDeviceScoped() async throws {
        let store = try await seeded()
        // 200s buckets over dev1's ts 100/200/300 (bpm 60/61/62):
        //   ts100 → bucket 0   → mean 60
        //   ts200, ts300 → bucket 200 → mean (61+62)/2 = 61.5
        let buckets = try await store.hrBuckets(deviceId: "dev1", from: 0, to: 1000, bucketSeconds: 200)
        XCTAssertEqual(buckets, [HRBucket(ts: 0, bpm: 60), HRBucket(ts: 200, bpm: 61.5)])
        // The decoy on "other" (ts200, bpm99) must never bleed into dev1's bucket.
        let other = try await store.hrBuckets(deviceId: "other", from: 0, to: 1000, bucketSeconds: 200)
        XCTAssertEqual(other, [HRBucket(ts: 200, bpm: 99)])
    }

    func testHrSampleDaysFindsCoveredUtcDaysNewestFirst() async throws {
        let store = try await WhoopStore.inMemory()
        let dev = "dev1"
        try await store.upsertDevice(id: dev, mac: nil, name: nil)
        try await store.upsertDevice(id: "other", mac: nil, name: nil)

        let day0 = 1_780_000_000
        let day1 = day0 + 86_400
        try await store.insert(Streams(hr: [
            HRSample(ts: day0 + 10, bpm: 60),
            HRSample(ts: day0 + 20, bpm: 61),
            HRSample(ts: day1 + 10, bpm: 62),
            HRSample(ts: day1 + 20, bpm: 63),
            HRSample(ts: day1 + 30, bpm: 64),
        ]), deviceId: dev)
        try await store.insert(Streams(hr: [
            HRSample(ts: day1 + 40, bpm: 99),
            HRSample(ts: day1 + 50, bpm: 99),
        ]), deviceId: "other")

        let days = try await store.hrSampleDays(deviceId: dev, from: day0, to: day1 + 100,
                                                minSamples: 2, limit: 10)
        XCTAssertEqual(days.map(\.day), [Self.utcDay(day1), Self.utcDay(day0)])
        XCTAssertEqual(days.map(\.sampleCount), [3, 2])
        XCTAssertEqual(days.first?.firstTs, day1 + 10)
        XCTAssertEqual(days.first?.lastTs, day1 + 30)
    }

    func testRrIntervalsReturnsBothTiedRows() async throws {
        let store = try await seeded()
        let rr = try await store.rrIntervals(deviceId: "dev1", from: 0, to: 1000, limit: 100)
        XCTAssertEqual(rr, [RRInterval(ts: 100, rrMs: 800), RRInterval(ts: 100, rrMs: 820)])
    }

    func testEventsDecodePayload() async throws {
        let store = try await seeded()
        let evs = try await store.events(deviceId: "dev1", from: 0, to: 1000, limit: 100)
        XCTAssertEqual(evs, [WhoopEvent(ts: 150, kind: "BLE_CONNECTION_DOWN(12)",
                                        payload: ["k": .int(9)])])
    }

    func testBatterySamples() async throws {
        let store = try await seeded()
        let bat = try await store.batterySamples(deviceId: "dev1", from: 0, to: 1000, limit: 100)
        XCTAssertEqual(bat, [BatterySample(ts: 120, soc: 88.0, mv: 3900)])
    }

    func testStorageStats() async throws {
        let store = try await seeded()
        // Add one of each biometric stream so the count proves all 8 tables are summed.
        _ = try await store.insert(
            Streams(spo2: [SpO2Sample(ts: 400, red: 1, ir: 2)],
                    skinTemp: [SkinTempSample(ts: 400, raw: 930)],
                    resp: [RespSample(ts: 400, raw: 3073)],
                    gravity: [GravitySample(ts: 400, x: 0.1, y: 0.2, z: 0.3)]),
            deviceId: "dev1")
        try await store.enqueueRawBatch(
            RawBatchMeta(batchId: "b1", deviceId: "dev1",
                         clockRef: ClockRef(device: 0, wall: 0), capturedAt: 1,
                         startTs: 0, endTs: 0, frameCount: 1, byteSize: 4),
            frames: [[0xAA, 0x00, 0x01, 0x02]])
        let stats = try await store.storageStats()
        // dev1: 3 hr + 2 rr + 1 event + 1 battery + 1 spo2 + 1 skinTemp + 1 resp + 1 gravity = 11
        // other: 1 hr = 1 → 12 decoded rows across all 8 tables.
        XCTAssertEqual(stats.decodedRows, 12)
        XCTAssertEqual(stats.rawBatches, 1)
        XCTAssertEqual(stats.rawBytes, 4)
    }
}
