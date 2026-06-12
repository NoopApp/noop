import XCTest
@testable import Strand
import WhoopProtocol
import WhoopStore

/// `RawHistoryArchive.replay` re-decodes the durable reject archive through the CURRENT decoder and
/// inserts whatever now decodes — the only path by which already-acked banked history backfills after
/// a newly-landed layout (e.g. WHOOP 4.0 v25). These are three REAL v25 records a pre-v25 build had
/// archived as undecodable; under the current decoder each yields a gravity sample.
final class RawHistoryArchiveReplayTests: XCTestCase {

    /// Minimal BackfillStoreWriting that only records how many gravity samples were handed to insert.
    private final class CaptureStore: BackfillStoreWriting {
        private(set) var insertedGravity = 0
        @discardableResult
        func insert(_ streams: Streams, deviceId: String) async throws
            -> (hr: Int, rr: Int, events: Int, battery: Int,
                spo2: Int, skinTemp: Int, resp: Int, gravity: Int) {
            insertedGravity += streams.gravity.count
            return (0, 0, 0, 0, 0, 0, 0, streams.gravity.count)
        }
        func enqueueRawBatch(_ meta: RawBatchMeta, frames: [[UInt8]]) async throws {}
        func setCursor(_ name: String, _ value: Int) async throws {}
        func cursor(_ name: String) async throws -> Int? { nil }
    }

    private func bytes(_ s: String) -> [UInt8] {
        var out = [UInt8](); out.reserveCapacity(s.count / 2); var i = s.startIndex
        while i < s.endIndex { let j = s.index(i, offsetBy: 2)
            out.append(UInt8(s[i..<j], radix: 16)!); i = j }
        return out
    }

    func testReplayDecodesArchivedV25IntoGravityRows() async throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("noop-replay-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let archive = RawHistoryArchive(directory: dir)
        // Real WHOOP 4.0 v25 records (84 B each, 1 Hz) — undecodable on pre-v25 builds.
        let frames = [
            "aa50000c2f190013390000140d2b6a4075010068a2010032fdbcfd98fdd3fdccfd47ffb00366064f073e06c103d3016cffa2fc87fa2ffae5fdbe03140675060c0510012dff1bfec0018f3c500500010068dc8f44",
            "aa50000c2f190014390000150d2b6a487001003ab301008dfd6afdaffda9fdaffd68fddbfb0dfc09fd77fe89fe62febffec9fe91ff0bff81ff5fff3e00d600790078ff3dff4bff801d553c5005010000d7c016b3",
            "aa50000c2f190015390000160d2b6a586b01006d8f0100a3ff94ffc4ffbcffbeff22004a009400cb0048005d006b004400d700130115013301f20088001d0031ffd9fe5eff75ff0048933c50050001008bdf2c2c",
        ].map(bytes)

        // Archive durably, then confirm read-back + replay recover gravity.
        if case .failed = archive.archive(frames, trim: 70476, family: .whoop4) {
            return XCTFail("archive write should not fail")
        }
        XCTAssertEqual(archive.readAll().count, 3, "every archived line should read back")

        let store = CaptureStore()
        let rows = await archive.replay(into: store, deviceId: "test")
        XCTAssertEqual(rows, 3, "all three v25 records should retro-decode to a gravity sample")
        XCTAssertEqual(store.insertedGravity, 3, "decoded gravity should be forwarded to the store")
    }

    func testReplayOnEmptyArchiveIsNoOp() async throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("noop-replay-empty-\(UUID().uuidString)", isDirectory: true)
        let archive = RawHistoryArchive(directory: dir)
        XCTAssertEqual(archive.readAll().count, 0)
        let rows = await archive.replay(into: CaptureStore(), deviceId: "test")
        XCTAssertEqual(rows, 0)
    }
}
