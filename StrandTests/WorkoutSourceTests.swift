import XCTest
import WhoopStore
@testable import Strand

/// Pins the pure workout-editing logic: source classification (the macOS read model has no
/// deviceId, so origin is recovered from `source`), the durable dismissed-span filter that keeps a
/// re-detected bout hidden (#107), manual-row validation, and field preservation on edit.
/// Mirrors the Android WorkoutEditingTest case-for-case.
final class WorkoutSourceTests: XCTestCase {

    private func row(start: Int, end: Int, sport: String, source: String,
                     avgHr: Int? = nil, maxHr: Int? = nil, strain: Double? = nil) -> WorkoutRow {
        WorkoutRow(startTs: start, endTs: end, sport: sport, source: source,
                   durationS: Double(end - start), energyKcal: nil, avgHr: avgHr, maxHr: maxHr,
                   strain: strain, distanceM: nil, zonesJSON: nil, notes: nil)
    }

    // MARK: - classify

    func testClassifyOrdersNoopBeforeWhoop() {
        // "my-whoop-noop" contains "whoop" — the -noop suffix MUST win, else a detected bout
        // would be classified as an imported WHOOP row and become un-dismissable.
        XCTAssertEqual(WorkoutSource.classify("my-whoop-noop"), .detected)
        XCTAssertEqual(WorkoutSource.classify("whoop"), .whoop)
        XCTAssertEqual(WorkoutSource.classify("manual"), .manual)
        XCTAssertEqual(WorkoutSource.classify("apple_health"), .apple)
        XCTAssertEqual(WorkoutSource.classify("apple-health"), .apple)
    }

    func testDisplaySportRenamesDetectedToken() {
        XCTAssertEqual(WorkoutSource.displaySport("detected"), "Activity")
        XCTAssertEqual(WorkoutSource.displaySport("Running"), "Running")
    }

    // MARK: - dismissed spans (durable #107 filter)

    func testParseDismissedSpansDropsMalformed() {
        let spans = WorkoutSource.parseDismissedSpans(["100:200", "bad", "5:5", "9:3", "300:400"])
        // "5:5" (zero width) and "9:3" (end<start) and "bad" are dropped.
        XCTAssertEqual(spans.count, 2)
        XCTAssertEqual(spans[0].start, 100); XCTAssertEqual(spans[0].end, 200)
        XCTAssertEqual(spans[1].start, 300); XCTAssertEqual(spans[1].end, 400)
    }

    func testIsDismissedOnlyHidesOverlappingDetectedRows() {
        let spans = WorkoutSource.parseDismissedSpans(["1000:2000"])
        let detectedOverlap = row(start: 1500, end: 2500, sport: "detected", source: "my-whoop-noop")
        let detectedClear = row(start: 3000, end: 4000, sport: "detected", source: "my-whoop-noop")
        let manualOverlap = row(start: 1500, end: 2500, sport: "Running", source: "manual")
        XCTAssertTrue(WorkoutSource.isDismissed(detectedOverlap, spans: spans))
        XCTAssertFalse(WorkoutSource.isDismissed(detectedClear, spans: spans))
        // A manual (or imported) row is NEVER auto-hidden by a dismissed span — only detected bouts.
        XCTAssertFalse(WorkoutSource.isDismissed(manualOverlap, spans: spans))
    }

    func testIsDismissedSurvivesStartTsDrift() {
        // A re-detected bout whose boundary drifted a little still overlaps the dismissed span.
        let spans = WorkoutSource.parseDismissedSpans(["1000:2000"])
        let drifted = row(start: 1040, end: 2030, sport: "detected", source: "my-whoop-noop")
        XCTAssertTrue(WorkoutSource.isDismissed(drifted, spans: spans))
    }

    func testDismissedTokenRoundTrips() {
        let r = row(start: 1700000000, end: 1700003600, sport: "detected", source: "my-whoop-noop")
        let token = WorkoutSource.dismissedToken(for: r)
        XCTAssertEqual(token, "1700000000:1700003600")
        let spans = WorkoutSource.parseDismissedSpans([token])
        XCTAssertTrue(WorkoutSource.isDismissed(r, spans: spans))
    }

    // MARK: - buildManualRow validation

    func testBuildManualRowHappyPath() {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let now = start.addingTimeInterval(3600)
        let r = WorkoutSource.buildManualRow(start: start, durationMin: 45, sport: "  Running ",
                                             avgHr: 150, energyKcal: 540, now: now)
        XCTAssertNotNil(r)
        XCTAssertEqual(r?.sport, "Running")          // trimmed
        XCTAssertEqual(r?.source, "manual")
        XCTAssertEqual(r?.durationS, 45 * 60)
        XCTAssertEqual(r?.endTs, r!.startTs + 45 * 60)
        XCTAssertEqual(r?.avgHr, 150)
        XCTAssertNil(r?.strain)                       // never fabricated without a captured HR window
    }

    func testBuildManualRowRejectsBadInput() {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let now = start.addingTimeInterval(3600)
        XCTAssertNil(WorkoutSource.buildManualRow(start: start, durationMin: 0, sport: "Run", avgHr: nil, energyKcal: nil, now: now))
        XCTAssertNil(WorkoutSource.buildManualRow(start: start, durationMin: 25 * 60, sport: "Run", avgHr: nil, energyKcal: nil, now: now))
        XCTAssertNil(WorkoutSource.buildManualRow(start: start, durationMin: 30, sport: "   ", avgHr: nil, energyKcal: nil, now: now))
        // Future start.
        XCTAssertNil(WorkoutSource.buildManualRow(start: now.addingTimeInterval(60), durationMin: 30, sport: "Run", avgHr: nil, energyKcal: nil, now: now))
        // Out-of-range HR / kcal.
        XCTAssertNil(WorkoutSource.buildManualRow(start: start, durationMin: 30, sport: "Run", avgHr: 10, energyKcal: nil, now: now))
        XCTAssertNil(WorkoutSource.buildManualRow(start: start, durationMin: 30, sport: "Run", avgHr: nil, energyKcal: 99_999, now: now))
    }

    // MARK: - preservingCaptured

    func testPreservingCapturedCarriesUnexposedFieldsOnEdit() {
        // The sheet rebuilds a row from its 5 inputs; an edit must keep the original's captured
        // maxHr/strain (a live-tracked session has real values the sheet never shows).
        let old = row(start: 100, end: 3700, sport: "Workout", source: "manual",
                      avgHr: 130, maxHr: 175, strain: 13.5)
        let rebuilt = row(start: 100, end: 3700, sport: "Running", source: "manual", avgHr: 140)
        let merged = WorkoutSource.preservingCaptured(rebuilt, from: old)
        XCTAssertEqual(merged.sport, "Running")  // edited field kept
        XCTAssertEqual(merged.avgHr, 140)        // edited field kept
        XCTAssertEqual(merged.maxHr, 175)        // carried over from old
        XCTAssertEqual(merged.strain, 13.5)      // carried over from old
    }

    func testPreservingCapturedIsNoOpForFreshAdd() {
        let rebuilt = row(start: 100, end: 3700, sport: "Running", source: "manual", avgHr: 140)
        XCTAssertEqual(WorkoutSource.preservingCaptured(rebuilt, from: nil), rebuilt)
    }
}
