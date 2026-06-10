import XCTest
@testable import StrandAnalytics
import WhoopProtocol

/// Tests SleepStager.respRateFromRR (RSA) on a synthetic R-R series with a KNOWN breathing
/// frequency. WHOOP5 v18 carries no raw resp ADC, so respiratory rate is derived on-device
/// from the R-R stream via respiratory sinus arrhythmia; this pins that the estimator recovers
/// a planted breathing rate and returns NaN on too-little data (honest no-data). The value is
/// an APPROXIMATE on-device estimate, not cloud/clinical respiration. Mirrors the Android
/// RespRateRsaTest vectors value-for-value.
final class RespRateRsaTests: XCTestCase {

    func testRespRateFromRRRecoversKnownBreathingFrequency() {
        // Synthetic RR: mean HR 60 bpm (RR ~1000 ms) with a 0.25 Hz (15 breaths/min)
        // RSA modulation of +/-40 ms. ~7 minutes of beats so multiple 5-min windows.
        let breathHz = 0.25  // 15 breaths/min
        let baseRrMs = 1000.0
        let ampMs = 40.0
        let start = 1_700_000_000
        var rows: [RRInterval] = []
        var tSec = 0.0
        // generate ~420 s of beats
        while tSec < 420.0 {
            let rrMs = baseRrMs + ampMs * sin(2.0 * Double.pi * breathHz * tSec)
            tSec += rrMs / 1000.0
            rows.append(RRInterval(ts: start + Int(tSec), rrMs: Int(rrMs)))
        }
        let end = start + Int(tSec)
        let est = SleepStager.respRateFromRR(rows, start: start, end: end)
        XCTAssertTrue(est.isFinite, "expected finite resp estimate, got \(est)")
        // RSA peak-pick should land within ~3 bpm of the true 15 breaths/min.
        XCTAssertEqual(est, 15.0, accuracy: 3.0)
    }

    func testRespRateFromRRTooFewBeatsIsNaN() {
        let start = 1_700_000_000
        let rows = [
            RRInterval(ts: start + 1, rrMs: 1000),
            RRInterval(ts: start + 2, rrMs: 1000),
            RRInterval(ts: start + 3, rrMs: 1000),
        ]
        XCTAssertTrue(SleepStager.respRateFromRR(rows, start: start, end: start + 10).isNaN)
        XCTAssertTrue(SleepStager.respRateFromRR([], start: start, end: start + 10).isNaN)
    }
}
