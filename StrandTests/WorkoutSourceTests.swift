import XCTest
import WhoopStore
@testable import Strand

/// Pins the workout-origin classification to the real stored `source` values, mirroring the
/// Android WorkoutSourceLabelTest + WorkoutEditingTest. The regressions: "manual" rows showed
/// an "Apple" badge, and the engine's "my-whoop-noop" bouts (had they been surfaced) a "Whoop"
/// badge. relabel/dismiss semantics are pinned by the same cases as the Kotlin suite.
final class WorkoutSourceTests: XCTestCase {

    func testClassifiesStoredSources() {
        XCTAssertEqual(WorkoutSource.classify("whoop"), .whoop)            // WhoopImporter
        XCTAssertEqual(WorkoutSource.classify("apple_health"), .apple)     // AppleHealthImport
        XCTAssertEqual(WorkoutSource.classify("manual"), .manual)          // AppModel.endWorkout
        XCTAssertEqual(WorkoutSource.classify("my-whoop-noop"), .detected) // IntelligenceEngine
        XCTAssertEqual(WorkoutSource.classify(""), .apple)                 // unknown falls back
    }

    func testNoopSuffixWinsOverWhoop() {
        // "my-whoop-noop" contains "whoop" — order matters or detected bouts badge as Whoop.
        XCTAssertEqual(WorkoutSource.classify("MY-WHOOP-NOOP"), .detected)
    }

    func testDisplaySportMapsTokenOnly() {
        XCTAssertEqual(WorkoutSource.displaySport("detected"), "Activity")
        XCTAssertEqual(WorkoutSource.displaySport("Running"), "Running")
    }

    func testBuildManualRowHappyPath() {
        let now = Date(timeIntervalSince1970: 2_000_000)
        let row = WorkoutSource.buildManualRow(start: Date(timeIntervalSince1970: 1_000_000),
                                               durationMin: 45, sport: " Running ",
                                               avgHr: 150, energyKcal: 500, now: now)
        XCTAssertNotNil(row)
        XCTAssertEqual(row?.source, "manual")
        XCTAssertEqual(row?.sport, "Running")
        XCTAssertEqual(row?.endTs, 1_000_000 + 45 * 60)
        XCTAssertEqual(row?.durationS ?? 0, 2700, accuracy: 1e-9)
        XCTAssertNil(row?.strain)
        XCTAssertNil(row?.zonesJSON)
    }

    func testBuildManualRowRejectsInvalid() {
        let now = Date(timeIntervalSince1970: 2_000_000)
        let start = Date(timeIntervalSince1970: 1_000_000)
        XCTAssertNil(WorkoutSource.buildManualRow(start: start, durationMin: 0, sport: "Running",
                                                  avgHr: nil, energyKcal: nil, now: now))
        XCTAssertNil(WorkoutSource.buildManualRow(start: start, durationMin: 25 * 60, sport: "Running",
                                                  avgHr: nil, energyKcal: nil, now: now))
        XCTAssertNil(WorkoutSource.buildManualRow(start: start, durationMin: 45, sport: "  ",
                                                  avgHr: nil, energyKcal: nil, now: now))
        XCTAssertNil(WorkoutSource.buildManualRow(start: Date(timeIntervalSince1970: 3_000_000),
                                                  durationMin: 45, sport: "Running",
                                                  avgHr: nil, energyKcal: nil, now: now))
        XCTAssertNil(WorkoutSource.buildManualRow(start: start, durationMin: 45, sport: "Running",
                                                  avgHr: 10, energyKcal: nil, now: now))
        XCTAssertNil(WorkoutSource.buildManualRow(start: start, durationMin: 45, sport: "Running",
                                                  avgHr: nil, energyKcal: -1, now: now))
    }

    func testDismissedSpanOverlapAndCodec() {
        let spans = WorkoutSource.parseDismissedSpans(["100:200", "junk", "5:", ":7", "9:3"])
        XCTAssertEqual(spans.count, 1)
        XCTAssertEqual(spans.first?.start, 100)
        XCTAssertEqual(spans.first?.end, 200)

        func row(_ start: Int, _ end: Int, source: String, sport: String) -> WorkoutRow {
            WorkoutRow(startTs: start, endTs: end, sport: sport, source: source,
                       durationS: nil, energyKcal: nil, avgHr: nil, maxHr: nil, strain: nil,
                       distanceM: nil, zonesJSON: nil, notes: nil)
        }
        let detected = row(150, 250, source: "my-whoop-noop", sport: "detected")
        XCTAssertTrue(WorkoutSource.isDismissed(detected, spans: [(100, 200)]))
        XCTAssertFalse(WorkoutSource.isDismissed(detected, spans: [(250, 300)]))  // touching ≠ overlap
        XCTAssertFalse(WorkoutSource.isDismissed(detected, spans: [(50, 150)]))   // touching ≠ overlap
        let manual = row(150, 250, source: "manual", sport: "Running")
        XCTAssertFalse(WorkoutSource.isDismissed(manual, spans: [(100, 200)]))    // never hides non-detected
    }
}
