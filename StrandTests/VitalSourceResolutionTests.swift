import XCTest
import WhoopStore
@testable import Strand

final class VitalSourceResolutionTests: XCTestCase {
    func testMergeDailyFillsOnlyMissingImportedFields() {
        let imported = daily(
            day: "2026-06-12",
            totalSleepMin: 420,
            recovery: nil,
            strain: 8.4,
            spo2Pct: 97,
            skinTempDevC: nil,
            steps: nil
        )
        let computed = daily(
            day: "2026-06-12",
            totalSleepMin: 390,
            recovery: 82,
            strain: 12.6,
            spo2Pct: 95,
            skinTempDevC: 0.3,
            steps: 9_240
        )

        let merged = Repository.mergeDaily(imported: [imported], computed: [computed])

        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged[0].totalSleepMin, 420)
        XCTAssertEqual(merged[0].recovery, 82)
        XCTAssertEqual(merged[0].strain, 8.4)
        XCTAssertEqual(merged[0].spo2Pct, 97)
        XCTAssertEqual(merged[0].skinTempDevC, 0.3)
        XCTAssertEqual(merged[0].steps, 9_240)
    }

    func testAppleHealthCanFillBloodOxygenWhenStrapSourcesAreMissing() {
        let readings = BodyVitalSigns.readings(
            sourceRows: [
                SourcedDailyMetric(metric: daily(day: "2026-06-12", spo2Pct: 98), source: .appleHealth)
            ],
            temperatureUnit: .celsius
        )

        let spo2 = readings.first { $0.key == "spo2" }
        XCTAssertEqual(spo2?.value, 98)
        XCTAssertEqual(spo2?.source, .appleHealth)
        XCTAssertTrue(spo2?.stateCaption.contains("Apple Health") == true)
    }

    func testWhoopBloodOxygenWinsOverAppleHealthForSameDay() {
        let readings = BodyVitalSigns.readings(
            sourceRows: [
                SourcedDailyMetric(metric: daily(day: "2026-06-12", spo2Pct: 96), source: .whoopImport),
                SourcedDailyMetric(metric: daily(day: "2026-06-12", spo2Pct: 99), source: .appleHealth)
            ],
            temperatureUnit: .celsius
        )

        let spo2 = readings.first { $0.key == "spo2" }
        XCTAssertEqual(spo2?.value, 96)
        XCTAssertEqual(spo2?.source, .whoopImport)
    }

    func testAppleHealthDoesNotFillSkinTemperature() {
        let readings = BodyVitalSigns.readings(
            sourceRows: [
                SourcedDailyMetric(metric: daily(day: "2026-06-12", skinTempDevC: 34.2), source: .appleHealth)
            ],
            temperatureUnit: .celsius
        )

        let skin = readings.first { $0.key == "skin" }
        XCTAssertNil(skin?.value)
        XCTAssertNil(skin?.source)
    }

    func testComputedSkinTemperatureShowsComputedCaption() {
        let readings = BodyVitalSigns.readings(
            sourceRows: [
                SourcedDailyMetric(metric: daily(day: "2026-06-12", skinTempDevC: 0.2), source: .noopComputed)
            ],
            temperatureUnit: .celsius
        )

        let skin = readings.first { $0.key == "skin" }
        XCTAssertEqual(skin?.value, 0.2)
        XCTAssertEqual(skin?.source, .noopComputed)
        XCTAssertTrue(skin?.stateCaption.contains("Overnight computed") == true)
    }

    private func daily(
        day: String,
        totalSleepMin: Double? = nil,
        recovery: Double? = nil,
        strain: Double? = nil,
        spo2Pct: Double? = nil,
        skinTempDevC: Double? = nil,
        respRateBpm: Double? = nil,
        steps: Int? = nil
    ) -> DailyMetric {
        DailyMetric(
            day: day,
            totalSleepMin: totalSleepMin,
            efficiency: nil,
            deepMin: nil,
            remMin: nil,
            lightMin: nil,
            disturbances: nil,
            restingHr: nil,
            avgHrv: nil,
            recovery: recovery,
            strain: strain,
            exerciseCount: nil,
            spo2Pct: spo2Pct,
            skinTempDevC: skinTempDevC,
            respRateBpm: respRateBpm,
            steps: steps,
            activeKcalEst: nil
        )
    }
}
