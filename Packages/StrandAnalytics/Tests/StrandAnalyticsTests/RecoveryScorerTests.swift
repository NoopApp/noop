import XCTest
@testable import StrandAnalytics
import WhoopProtocol

final class RecoveryScorerTests: XCTestCase {

    /// A usable (trusted) baseline with a given mean and σ (Gaussian).
    private func baseline(mean: Double, sigma: Double, nValid: Int = 14) -> BaselineState {
        // spread is internal abs-dev units; deviation() multiplies by 1.253 → σ.
        BaselineState(baseline: mean, spread: sigma / 1.253, nValid: nValid,
                      nightsSinceUpdate: 0, status: nValid >= 14 ? .trusted : .provisional)
    }

    func testRecoveryAtBaselineNearPopulationMean() {
        // HRV at baseline, RHR at baseline, no resp, sleepPerf at center → Z≈0 → ~58%.
        let r = RecoveryScorer.recovery(
            hrv: 50, rhr: 55, resp: nil,
            hrvBaseline: baseline(mean: 50, sigma: 6),
            rhrBaseline: baseline(mean: 55, sigma: 3),
            respBaseline: nil,
            sleepPerf: RecoveryScorer.sleepPerfCenter)
        XCTAssertNotNil(r)
        XCTAssertEqual(r!, 57.93, accuracy: 0.5)
    }

    func testRecoveryHigherWhenHRVAboveAndRHRBelow() {
        let good = RecoveryScorer.recovery(
            hrv: 65, rhr: 50, resp: nil,
            hrvBaseline: baseline(mean: 50, sigma: 6.265),
            rhrBaseline: baseline(mean: 55, sigma: 2.506),
            respBaseline: nil,
            sleepPerf: 0.90)!
        let bad = RecoveryScorer.recovery(
            hrv: 40, rhr: 62, resp: nil,
            hrvBaseline: baseline(mean: 50, sigma: 6.265),
            rhrBaseline: baseline(mean: 55, sigma: 2.506),
            respBaseline: nil,
            sleepPerf: 0.70)!
        XCTAssertGreaterThan(good, bad)
        XCTAssertGreaterThan(good, 90)   // matches Python golden ~97
        XCTAssertLessThan(bad, 15)       // matches Python golden ~7
    }

    func testRecoveryClampedToRange() {
        let r = RecoveryScorer.recovery(
            hrv: 200, rhr: 30, resp: nil,
            hrvBaseline: baseline(mean: 50, sigma: 5),
            rhrBaseline: baseline(mean: 55, sigma: 2),
            respBaseline: nil,
            sleepPerf: 1.0)!
        XCTAssertLessThanOrEqual(r, 100.0)
        XCTAssertGreaterThanOrEqual(r, 0.0)
    }

    func testColdStartReturnsNil() {
        let coldHRV = BaselineState(baseline: 50, spread: 5, nValid: 2,
                                    nightsSinceUpdate: 0, status: .calibrating)
        let r = RecoveryScorer.recovery(
            hrv: 60, rhr: 50, resp: nil,
            hrvBaseline: coldHRV, rhrBaseline: nil, respBaseline: nil, sleepPerf: 0.9)
        XCTAssertNil(r)
    }

    func testRespTermDropAndRenormalize() {
        // With resp present vs nil but everything else equal at baseline, the score
        // stays near population mean either way (no driver pushes Z off zero).
        let withResp = RecoveryScorer.recovery(
            hrv: 50, rhr: 55, resp: 100,
            hrvBaseline: baseline(mean: 50, sigma: 6),
            rhrBaseline: baseline(mean: 55, sigma: 3),
            respBaseline: baseline(mean: 100, sigma: 5),
            sleepPerf: RecoveryScorer.sleepPerfCenter)!
        let withoutResp = RecoveryScorer.recovery(
            hrv: 50, rhr: 55, resp: nil,
            hrvBaseline: baseline(mean: 50, sigma: 6),
            rhrBaseline: baseline(mean: 55, sigma: 3),
            respBaseline: baseline(mean: 100, sigma: 5),
            sleepPerf: RecoveryScorer.sleepPerfCenter)!
        XCTAssertEqual(withResp, withoutResp, accuracy: 1e-6)
    }

    func testRespAboveBaselineLowersAndBelowRaisesRecovery() {
        // Pins the resp-into-recovery wiring direction (mirrors the Android BaselineSeedingTest
        // addition): with HRV/RHR pinned at baseline, a nightly respiratory rate above the resp
        // baseline must LOWER recovery and one below it must RAISE it. A nil resp renormalizes
        // to the no-resp score (testRespTermDropAndRenormalize already pins that).
        func score(_ resp: Double?) -> Double {
            RecoveryScorer.recovery(
                hrv: 50, rhr: 55, resp: resp,
                hrvBaseline: baseline(mean: 50, sigma: 6),
                rhrBaseline: baseline(mean: 55, sigma: 3),
                respBaseline: baseline(mean: 14.5, sigma: 1),
                sleepPerf: 0.9)!
        }
        let neutral = score(nil)
        let elevated = score(17.5)
        let lowered = score(12.0)
        XCTAssertLessThan(elevated, neutral, "resp above baseline must lower recovery")
        XCTAssertGreaterThan(lowered, neutral, "resp below baseline must raise recovery")
    }

    func testBandThresholds() {
        XCTAssertEqual(RecoveryScorer.band(20), "red")
        XCTAssertEqual(RecoveryScorer.band(33.9), "red")
        XCTAssertEqual(RecoveryScorer.band(34), "yellow")
        XCTAssertEqual(RecoveryScorer.band(50), "yellow")
        XCTAssertEqual(RecoveryScorer.band(66.9), "yellow")
        XCTAssertEqual(RecoveryScorer.band(67), "green")
        XCTAssertEqual(RecoveryScorer.band(90), "green")
    }

    func testRestingHRLowestRollingMean() {
        // Two 5-min blocks: first averages 60, second averages 50 → resting = 50.
        var hr: [HRSample] = []
        let start = 1000
        for i in 0..<300 { hr.append(HRSample(ts: start + i, bpm: 60)) }        // 0..299 s
        for i in 0..<300 { hr.append(HRSample(ts: start + 300 + i, bpm: 50)) }  // 300..599 s
        let r = RecoveryScorer.restingHR(hr, start: start, end: start + 600)
        XCTAssertEqual(r, 50)
    }

    func testRestingHRNilWhenNoSamples() {
        XCTAssertNil(RecoveryScorer.restingHR([], start: 0, end: 1000))
    }
}
