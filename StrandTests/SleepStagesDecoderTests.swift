import XCTest
@testable import Strand

/// Unit tests for SleepStagesDecoder, the dual-shape stagesJSON reader behind the Sleep
/// screen: the stager's persisted per-epoch segment array must parse (and sum to minutes,
/// "wake" → awake), the imported minutes dict must keep working, and garbage must fall
/// through to nil. Mirrors the Android SleepStageSegmentsTest where shapes overlap.
final class SleepStagesDecoderTests: XCTestCase {

    private let segmentJSON = """
    [{"start":1000,"end":1900,"stage":"light"},
     {"start":1900,"end":3700,"stage":"deep"},
     {"start":3700,"end":4000,"stage":"wake"}]
    """
    private let minutesJSON = #"{"light":210,"deep":80,"rem":95,"awake":25}"#

    func testSegmentsParseFromStagerArray() {
        let segs = SleepStagesDecoder.segments(segmentJSON)
        XCTAssertEqual(segs?.count, 3)
        XCTAssertEqual(segs?[1].stage, "deep")
    }

    func testSegmentsNilForMinutesDict() {
        XCTAssertNil(SleepStagesDecoder.segments(minutesJSON))
    }

    func testMinutesFromSegmentsSumsAndMapsWake() {
        let m = SleepStagesDecoder.minutes(segmentJSON)
        XCTAssertEqual(m?.light ?? 0, 15.0, accuracy: 0.001)
        XCTAssertEqual(m?.deep ?? 0, 30.0, accuracy: 0.001)
        XCTAssertEqual(m?.awake ?? 0, 5.0, accuracy: 0.001)
    }

    func testMinutesFromImportedDict() {
        XCTAssertEqual(SleepStagesDecoder.minutes(minutesJSON)?.rem ?? 0, 95.0, accuracy: 0.001)
    }

    func testWakeStringMapsToAwakeStage() {
        XCTAssertEqual(SleepStage(persisted: "wake"), .awake)
        XCTAssertEqual(SleepStage(persisted: "rem"), .rem)
        XCTAssertNil(SleepStage(persisted: "nrem3"))
    }

    func testGarbageNil() {
        XCTAssertNil(SleepStagesDecoder.minutes("not json"))
        XCTAssertNil(SleepStagesDecoder.segments(nil))
    }
}
