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
        XCTAssertEqual(Repository.dailyMetricValue(row, key: "sleep_performance") ?? -1, 69.39, accuracy: 0.01)
        XCTAssertEqual(Repository.dailyMetricValue(row, key: "asleep_min"), 407)
        XCTAssertEqual(Repository.dailyMetricValue(row, key: "in_bed_min") ?? -1, 459.37, accuracy: 0.01)
        XCTAssertEqual(Repository.dailyMetricValue(row, key: "restorative_min"), 43.5)
        XCTAssertEqual(Repository.dailyMetricValue(row, key: "restorative_pct") ?? -1, 10.69, accuracy: 0.01)
        XCTAssertEqual(Repository.dailyMetricValue(row, key: "hours_vs_needed_pct") ?? -1, 84.79, accuracy: 0.01)
        XCTAssertEqual(Repository.dailyMetricValue(row, key: "sleep_need_min"), 480)
        XCTAssertEqual(Repository.dailyMetricValue(row, key: "sleep_debt_min"), 73)
        XCTAssertEqual(Repository.dailyMetricValue(row, key: "deep_min"), 13.5)
        XCTAssertEqual(Repository.dailyMetricValue(row, key: "rem_min"), 30)
        XCTAssertEqual(Repository.dailyMetricValue(row, key: "core_min"), 363.5)
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
