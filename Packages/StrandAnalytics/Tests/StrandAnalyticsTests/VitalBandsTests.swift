import XCTest
@testable import StrandAnalytics

/// Pins VitalBands — the Health Monitor's personal-baseline banding. Mirrors the Android
/// VitalBandsTest case-for-case (identical numbers), so the two platforms can never band
/// the same vital differently.
final class VitalBandsTests: XCTestCase {

    private let hrvCfg = Baselines.hrvCfg
    private let hrvPop: ClosedRange<Double> = 40...120

    func testNullValueIsNoData() {
        let r = VitalBands.band(value: nil, history: [50.0], populationRange: hrvPop, cfg: hrvCfg)
        XCTAssertEqual(r.band, .noData)
    }

    // THE MOTIVATING CASE: a personal-normal HRV of 35 ms, population says 40-120.
    func testLowHrvBelow14NightsPopulationOutOfRange() {
        let r = VitalBands.band(value: 35, history: Array(repeating: 35.0, count: 10),
                                populationRange: hrvPop, cfg: hrvCfg)
        XCTAssertEqual(r.band, .outOfRange)
        XCTAssertEqual(r.basis, .population)
        XCTAssertEqual(r.nights, 10)
    }

    func testLowHrvAt14NightsPersonalInRange() {
        let r = VitalBands.band(value: 35, history: Array(repeating: 35.0, count: 14),
                                populationRange: hrvPop, cfg: hrvCfg)
        XCTAssertEqual(r.band, .inRange)
        XCTAssertEqual(r.basis, .personal)
        XCTAssertEqual(r.nights, 14)
    }

    func testPersonalBigDeviationOutOfRange() {
        let r = VitalBands.band(value: 70, history: Array(repeating: 35.0, count: 30),
                                populationRange: hrvPop, cfg: hrvCfg)
        XCTAssertEqual(r.band, .outOfRange)
        XCTAssertEqual(r.basis, .personal)
    }

    func testPersonalJustInside2SigmaInRange() {
        let hist: [Double?] = Array(repeating: 35.0, count: 30)
        let state = Baselines.foldHistory(hist, cfg: hrvCfg)
        let edge = state.baseline + 1.99 * 1.253 * state.spread   // strictly inside 2σ
        XCTAssertEqual(VitalBands.band(value: edge, history: hist,
                                       populationRange: hrvPop, cfg: hrvCfg).band, .inRange)
    }

    func testImplausibleValueAlwaysOutOfRangeEvenWithTrustedBaseline() {
        // hrv cfg bounds 5-250: 300 is implausible regardless of personal spread.
        let r = VitalBands.band(value: 300, history: Array(repeating: 35.0, count: 30),
                                populationRange: hrvPop, cfg: hrvCfg)
        XCTAssertEqual(r.band, .outOfRange)
        XCTAssertEqual(r.basis, .population)
    }

    func testNilCfgSpo2StaysPopulationOnly() {
        let r = VitalBands.band(value: 93, history: [], populationRange: 95...100, cfg: nil)
        XCTAssertEqual(r.band, .outOfRange)
        XCTAssertEqual(r.basis, .population)
    }

    func testNilNightsDoNotCountTowardTrust() {
        let hist: [Double?] = Array(repeating: 35.0, count: 13) + Array(repeating: nil, count: 10)
        // 13 valid nights → provisional even after 10 trailing skips — still not personal.
        let r = VitalBands.band(value: 35, history: hist, populationRange: hrvPop, cfg: hrvCfg)
        XCTAssertEqual(r.basis, .population)
    }

    func testStaleBaselineFallsBackToPopulation() {
        // 20 valid nights then 20 missing: status stale (>14 missing) → population.
        let hist: [Double?] = Array(repeating: 35.0, count: 20) + Array(repeating: nil, count: 20)
        let r = VitalBands.band(value: 35, history: hist, populationRange: hrvPop, cfg: hrvCfg)
        XCTAssertEqual(r.basis, .population)
    }

    func testSkinTempHistoryPartitionsMixedSemantics() {
        let mixed: [Double?] = [34.1, 0.2, nil, 33.8, -0.1]
        XCTAssertEqual(VitalBands.skinTempHistory(matching: 0.3, in: mixed), [nil, 0.2, nil, nil, -0.1])
        XCTAssertEqual(VitalBands.skinTempHistory(matching: 34.0, in: mixed), [34.1, nil, nil, 33.8, nil])
    }

    func testCalendarSeriesPadsMissingDays() {
        let rows: [(day: String, value: Double?)] = [("2026-06-01", 50.0), ("2026-06-04", 52.0)]
        XCTAssertEqual(VitalBands.calendarSeries(rows), [50.0, nil, nil, 52.0])
    }

    func testCalendarSeriesDropsMalformedKeysEmptyIsEmpty() {
        XCTAssertEqual(VitalBands.calendarSeries([]), [])
        let rows: [(day: String, value: Double?)] = [("not-a-date", 1.0), ("2026-06-01", 50.0)]
        XCTAssertEqual(VitalBands.calendarSeries(rows), [50.0])
    }
}
