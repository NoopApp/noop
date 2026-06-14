import XCTest
import WhoopStore
@testable import Strand

/// Pins the pure sleep-editing logic added for #281: manual-session build/validation, the manual
/// flag, the durable deleted-span filter (so a re-derived computed night the user removed stays
/// removed, mirroring the dismissed-detected-bout mechanism), and the merge + merge-suggestion logic.
final class SleepSourceTests: XCTestCase {

    private func session(_ start: Int, _ end: Int,
                         stages: String? = nil) -> CachedSleepSession {
        CachedSleepSession(startTs: start, endTs: end, efficiency: nil, restingHr: nil,
                           avgHrv: nil, stagesJSON: stages)
    }

    // MARK: - buildManualSession

    func testBuildManualSessionHappyPath() {
        let bed = Date(timeIntervalSince1970: 1_700_000_000)
        let wake = bed.addingTimeInterval(8 * 3600)        // 8 h in bed
        let now = wake.addingTimeInterval(60)
        let s = SleepSource.buildManualSession(start: bed, end: wake, asleepMin: 7 * 60, now: now)
        let session = try! XCTUnwrap(s)
        XCTAssertEqual(session.startTs, 1_700_000_000)
        XCTAssertEqual(session.endTs, 1_700_000_000 + 8 * 3600)
        // efficiency = asleep / in-bed = 420 / 480 = 0.875 (fraction ≤ 1, as the decoder expects).
        XCTAssertEqual(try XCTUnwrap(session.efficiency), 0.875, accuracy: 0.001)
        XCTAssertTrue(SleepSource.isManual(session))
    }

    func testBuildManualSessionDefaultsAsleepToWholeWindow() {
        let bed = Date(timeIntervalSince1970: 1_700_000_000)
        let wake = bed.addingTimeInterval(3600)
        let s = SleepSource.buildManualSession(start: bed, end: wake, asleepMin: nil,
                                               now: wake.addingTimeInterval(1))
        XCTAssertEqual(try XCTUnwrap(XCTUnwrap(s).efficiency), 1.0, accuracy: 0.001)
    }

    func testBuildManualSessionRejectsBadInput() {
        let bed = Date(timeIntervalSince1970: 1_700_000_000)
        let now = bed.addingTimeInterval(20 * 3600)
        // wake ≤ bed.
        XCTAssertNil(SleepSource.buildManualSession(start: bed, end: bed, asleepMin: nil, now: now))
        XCTAssertNil(SleepSource.buildManualSession(start: bed, end: bed.addingTimeInterval(-60), asleepMin: nil, now: now))
        // future window.
        XCTAssertNil(SleepSource.buildManualSession(start: now.addingTimeInterval(60),
                                                    end: now.addingTimeInterval(3660), asleepMin: nil, now: now))
        // longer than 18 h.
        XCTAssertNil(SleepSource.buildManualSession(start: bed, end: bed.addingTimeInterval(19 * 3600),
                                                    asleepMin: nil, now: bed.addingTimeInterval(20 * 3600)))
        // asleep > in-bed.
        XCTAssertNil(SleepSource.buildManualSession(start: bed, end: bed.addingTimeInterval(3600),
                                                    asleepMin: 120, now: now))
    }

    func testManualFlagOnlyOnManualSessions() {
        // A normal imported/computed stage summary is NOT flagged manual.
        let imported = session(100, 200, stages: "{\"light\":120,\"deep\":40,\"rem\":50,\"awake\":10}")
        XCTAssertFalse(SleepSource.isManual(imported))
        let computedSegments = session(100, 200, stages: "[{\"start\":100,\"end\":200,\"stage\":\"light\"}]")
        XCTAssertFalse(SleepSource.isManual(computedSegments))
        XCTAssertFalse(SleepSource.isManual(session(100, 200, stages: nil)))
    }

    // MARK: - deleted spans (durable #281 filter)

    func testParseDeletedSpansDropsMalformed() {
        let spans = SleepSource.parseDeletedSpans(["100:200", "bad", "5:5", "9:3", "300:400"])
        XCTAssertEqual(spans.count, 2)
        XCTAssertEqual(spans[0].start, 100); XCTAssertEqual(spans[0].end, 200)
        XCTAssertEqual(spans[1].start, 300); XCTAssertEqual(spans[1].end, 400)
    }

    func testDeletedTokenRoundTripsAndOverlaps() {
        let token = SleepSource.deletedToken(startTs: 1_700_000_000, endTs: 1_700_028_800)
        XCTAssertEqual(token, "1700000000:1700028800")
        let spans = SleepSource.parseDeletedSpans([token])
        // A re-derived computed night whose boundary drifted a little still overlaps the deleted span.
        XCTAssertTrue(SleepSource.isDeleted(startTs: 1_700_000_400, endTs: 1_700_028_000, spans: spans))
        // A genuinely different (non-overlapping) night is NOT hidden.
        XCTAssertFalse(SleepSource.isDeleted(startTs: 1_700_100_000, endTs: 1_700_120_000, spans: spans))
    }

    // MARK: - merge

    func testMergeCombinesWindowAndStageMinutes() {
        // Two halves of one night with a 20-min gap. Each carries a stage summary.
        let a = session(1_000, 4_600, stages: "{\"light\":40,\"deep\":15,\"rem\":5,\"awake\":0}")  // 60 min
        let b = session(5_800, 9_400, stages: "{\"light\":30,\"deep\":10,\"rem\":20,\"awake\":0}")  // 60 min
        let merged = SleepSource.merge(a, b)
        XCTAssertEqual(merged.startTs, 1_000)
        XCTAssertEqual(merged.endTs, 9_400)
        XCTAssertTrue(SleepSource.isManual(merged))
        // in-bed = (9400-1000)/60 = 140 min; asleep stage min = (40+15+5)+(30+10+20)=120 → eff ≈ 0.857.
        XCTAssertEqual(try XCTUnwrap(merged.efficiency), 120.0 / 140.0, accuracy: 0.01)
    }

    func testMergeIsOrderIndependent() {
        let a = session(5_000, 9_000, stages: "{\"light\":50,\"deep\":0,\"rem\":0,\"awake\":0}")
        let b = session(1_000, 4_000, stages: "{\"light\":40,\"deep\":0,\"rem\":0,\"awake\":0}")
        let m1 = SleepSource.merge(a, b)
        let m2 = SleepSource.merge(b, a)
        XCTAssertEqual(m1.startTs, 1_000); XCTAssertEqual(m1.endTs, 9_000)
        XCTAssertEqual(m1.startTs, m2.startTs); XCTAssertEqual(m1.endTs, m2.endTs)
    }

    // MARK: - suggestedMerges

    func testSuggestedMergesFindsAdjacentCloseBlocks() {
        // Two blocks 20 min apart (mergeable), then a third 3 h later (not adjacent).
        let a = session(1_000, 4_600)
        let b = session(5_800, 9_400)                 // 20-min gap from a
        let c = session(9_400 + 3 * 3600, 9_400 + 4 * 3600)  // 3 h gap from b
        let suggestions = SleepSource.suggestedMerges([c, a, b])  // unsorted input
        XCTAssertEqual(suggestions.count, 1)
        XCTAssertEqual(suggestions[0].first.startTs, 1_000)
        XCTAssertEqual(suggestions[0].second.startTs, 5_800)
        XCTAssertEqual(suggestions[0].gapSeconds, 1_200)
    }

    func testSuggestedMergesRespectsThreshold() {
        // 90-min gap exceeds the default 60-min threshold → not suggested.
        let a = session(1_000, 4_600)
        let b = session(4_600 + 90 * 60, 4_600 + 150 * 60)
        XCTAssertTrue(SleepSource.suggestedMerges([a, b]).isEmpty)
        // …but raising the threshold surfaces it.
        XCTAssertEqual(SleepSource.suggestedMerges([a, b], gapThreshold: 120 * 60).count, 1)
    }

    func testSuggestedMergesSkipsContainedBlock() {
        // b sits fully inside a (a containment artefact, not an adjacent split) → not suggested.
        let a = session(1_000, 9_000)
        let b = session(3_000, 4_000)
        XCTAssertTrue(SleepSource.suggestedMerges([a, b]).isEmpty)
    }
}
