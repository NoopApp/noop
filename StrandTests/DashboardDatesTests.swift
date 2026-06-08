import XCTest
@testable import NOOP
import WhoopStore

final class DashboardDatesTests: XCTestCase {
    private func day(_ day: String, recovery: Double = 50) -> DailyMetric {
        DailyMetric(
            day: day,
            totalSleepMin: nil,
            efficiency: nil,
            deepMin: nil,
            remMin: nil,
            lightMin: nil,
            disturbances: nil,
            restingHr: nil,
            avgHrv: nil,
            recovery: recovery,
            strain: nil,
            exerciseCount: nil,
            spo2Pct: nil,
            skinTempDevC: nil,
            respRateBpm: nil
        )
    }

    func testRowForDayDoesNotFallbackToNewestImportedDay() {
        let days = [day("2024-04-05"), day("2024-04-06")]

        XCTAssertNil(DashboardDates.row(for: days, day: "2026-06-08"))
    }

    func testTrailingWindowUsesCalendarTodayNotLastStoredRows() {
        let days = [
            day("2024-04-05"),
            day("2024-04-06"),
            day("2026-05-24"),
            day("2026-05-25"),
            day("2026-05-26"),
            day("2026-06-01"),
            day("2026-06-08"),
        ]

        let window = DashboardDates.trailingWindow(days, ending: "2026-06-08", count: 14).map(\.day)

        XCTAssertEqual(window, ["2026-05-26", "2026-06-01", "2026-06-08"])
    }
}
