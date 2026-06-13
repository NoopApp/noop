import XCTest
import WhoopStore
@testable import Strand

@MainActor
final class ResolvedSeriesFallbackTests: XCTestCase {
    func testDailyMetricFallbackProjectsComputedValues() {
        let row = DailyMetric(
            day: "2026-06-13",
            totalSleepMin: 407,
            efficiency: 0.886,
            deepMin: 13.5,
            remMin: 30,
            lightMin: 363.5,
            disturbances: 25,
            restingHr: 53,
            avgHrv: 107.5,
            recovery: nil,
            strain: 31.19,
            exerciseCount: 0,
            spo2Pct: nil,
            skinTempDevC: nil,
            respRateBpm: 10.4,
            steps: 8123,
            activeKcalEst: 3464.8
        )

        XCTAssertEqual(Repository.dailyMetricValue(row, key: "strain"), 31.19)
        XCTAssertEqual(Repository.dailyMetricValue(row, key: "hrv"), 107.5)
        XCTAssertEqual(Repository.dailyMetricValue(row, key: "rhr"), 53)
        XCTAssertEqual(Repository.dailyMetricValue(row, key: "resp_rate"), 10.4)
        XCTAssertEqual(Repository.dailyMetricValue(row, key: "steps"), 8123)
        XCTAssertEqual(Repository.dailyMetricValue(row, key: "active_kcal"), 3464.8)
    }

    func testEfficiencyFallbackNormalizesFractionsToPercent() {
        let fractional = DailyMetric(
            day: "2026-06-13",
            totalSleepMin: nil,
            efficiency: 0.886,
            deepMin: nil,
            remMin: nil,
            lightMin: nil,
            disturbances: nil,
            restingHr: nil,
            avgHrv: nil,
            recovery: nil,
            strain: nil,
            exerciseCount: nil
        )
        let percent = DailyMetric(
            day: "2026-06-13",
            totalSleepMin: nil,
            efficiency: 88.6,
            deepMin: nil,
            remMin: nil,
            lightMin: nil,
            disturbances: nil,
            restingHr: nil,
            avgHrv: nil,
            recovery: nil,
            strain: nil,
            exerciseCount: nil
        )

        XCTAssertEqual(Repository.dailyMetricValue(fractional, key: "sleep_efficiency") ?? -1, 88.6, accuracy: 0.001)
        XCTAssertEqual(Repository.dailyMetricValue(percent, key: "sleep_efficiency") ?? -1, 88.6, accuracy: 0.001)
    }
}
