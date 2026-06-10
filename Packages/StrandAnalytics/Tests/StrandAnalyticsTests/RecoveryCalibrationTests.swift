import XCTest
@testable import StrandAnalytics

/// Unit tests for `RecoveryScorer.calibrationNights`, the pure helper behind the Today recovery
/// cold-start "Calibrating — N of 4 nights" affordance. Recovery is nil until the HRV baseline
/// crosses the seed gate (Baselines.minNightsSeed valid nights); this surfaces honest progress
/// instead of a bare empty state. Mirrors the Android RecoveryCalibrationTest case-for-case.
final class RecoveryCalibrationTests: XCTestCase {

    private let seed = Baselines.minNightsSeed // 4

    func testNilWhenRecoveryAlreadyExists() {
        XCTAssertNil(RecoveryScorer.calibrationNights(nightlyHrv: [55.0, 60.0], hasRecovery: true))
    }

    func testNilWhenNoNightHasHrvYet() {
        XCTAssertNil(RecoveryScorer.calibrationNights(nightlyHrv: [nil, nil], hasRecovery: false))
    }

    func testCountsNightsCarryingHrvBelowSeed() {
        XCTAssertEqual(RecoveryScorer.calibrationNights(nightlyHrv: [55.0, nil, 61.0], hasRecovery: false), 2)
    }

    func testOneNightReportsOne() {
        XCTAssertEqual(RecoveryScorer.calibrationNights(nightlyHrv: [58.0], hasRecovery: false), 1)
    }

    func testNilAtOrAboveSeedDoesNotClaimCalibrating() {
        // At/above the seed gate the baseline should be usable; if recovery is still nil it's
        // some other gap, so we must NOT show a misleading "calibrating 4 of 4".
        let nights: [Double?] = (1...seed).map { 55.0 + Double($0) }
        XCTAssertNil(RecoveryScorer.calibrationNights(nightlyHrv: nights, hasRecovery: false))
    }

    func testIgnoresNilHrvNights() {
        XCTAssertEqual(RecoveryScorer.calibrationNights(nightlyHrv: [55.0, nil, nil, 60.0], hasRecovery: false), 2)
    }

    func testIgnoresOutOfRangeHrvNights() {
        // A physiologically implausible avgHrv (outside the HRV config bounds 5...250) does not
        // advance the recovery seed in Baselines.update, so it must not be counted here either —
        // only the in-range night does. Keeps the displayed N in step with the real nValid.
        XCTAssertEqual(RecoveryScorer.calibrationNights(nightlyHrv: [55.0, 4.0, 999.0], hasRecovery: false), 1)
    }
}
