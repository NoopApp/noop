import XCTest
@testable import StrandImport

final class AppleHealthImporterTests: XCTestCase {

    private let fixtureName = "sample_health_data.xml"

    private func parsed() throws -> AppleHealthImportResult {
        let data = Fixtures.data(fixtureName)
        XCTAssertFalse(data.isEmpty, "\(fixtureName) fixture missing")
        return try AppleHealthImporter().importXML(data: data)
    }

    // MARK: - Type filtering

    func testOnlyRelevantTypesIngested() throws {
        let r = try parsed()
        let types = Set(r.samples.map { $0.type })
        // BodyMass is now a relevant (body-composition) type -> included.
        XCTAssertTrue(types.contains("BodyMass"))
        XCTAssertTrue(types.contains("HeartRate"))
        XCTAssertTrue(types.contains("RestingHeartRate"))
        XCTAssertTrue(types.contains("OxygenSaturation"))
        XCTAssertTrue(types.contains("RespiratoryRate"))
        XCTAssertTrue(types.contains("StepCount"))
        XCTAssertTrue(types.contains("SleepAnalysis"))
        // An irrelevant type stays excluded.
        XCTAssertFalse(types.contains("DietaryWater"))
    }

    // MARK: - OxygenSaturation ×100

    func testOxygenSaturationFractionScaledToPercent() throws {
        let r = try parsed()
        let spo2 = r.samples.first { $0.type == "OxygenSaturation" }
        XCTAssertNotNil(spo2)
        // Raw value 0.97 -> 97.0
        XCTAssertEqual(try XCTUnwrap(spo2?.value), 97.0, accuracy: 1e-9)
        XCTAssertEqual(spo2?.valueString, "0.97")
    }

    // MARK: - Dates -> UTC

    func testDatesNormalizedToUTC() throws {
        let r = try parsed()
        let hr = r.samples.first { $0.type == "HeartRate" }
        XCTAssertNotNil(hr)
        // 2024-01-02 08:00:00 +0100 -> 07:00:00 UTC.
        XCTAssertEqual(hr?.start, Fixtures.utc(2024, 1, 2, 7, 0, 0))
        XCTAssertEqual(hr?.end, Fixtures.utc(2024, 1, 2, 7, 0, 0))
        XCTAssertEqual(hr?.tzOffsetMin, 60)
        XCTAssertEqual(hr?.value, 61)
        XCTAssertEqual(hr?.unit, "count/min")
        XCTAssertEqual(hr?.sourceName, "Apple Watch")
    }

    func testNegativeOffsetDateParsing() {
        let p = HealthDateParser()
        let result = p.parse("2024-06-01 14:30:00 -0500")
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.0, Fixtures.utc(2024, 6, 1, 19, 30, 0)) // +5h to UTC
        XCTAssertEqual(result?.1, -300)
    }

    // MARK: - Sleep enums

    func testSleepAnalysisStagesMapped() throws {
        let r = try parsed()
        XCTAssertEqual(r.sleepIntervals.count, 3)
        let stages = r.sleepIntervals.map { $0.stage }
        XCTAssertEqual(stages, [.asleepCore, .asleepDeep, .awake])

        let core = r.sleepIntervals[0]
        XCTAssertEqual(core.start, Fixtures.utc(2024, 1, 1, 22, 15, 0)) // 23:15 +0100
        XCTAssertEqual(core.end, Fixtures.utc(2024, 1, 1, 23, 15, 0))
    }

    func testSleepStageMappingTable() {
        XCTAssertEqual(SleepStage.from(rawValue: "HKCategoryValueSleepAnalysisInBed"), .inBed)
        XCTAssertEqual(SleepStage.from(rawValue: "HKCategoryValueSleepAnalysisAsleep"), .asleepUnspecified)
        XCTAssertEqual(SleepStage.from(rawValue: "HKCategoryValueSleepAnalysisAsleepCore"), .asleepCore)
        XCTAssertEqual(SleepStage.from(rawValue: "HKCategoryValueSleepAnalysisAsleepDeep"), .asleepDeep)
        XCTAssertEqual(SleepStage.from(rawValue: "HKCategoryValueSleepAnalysisAsleepREM"), .asleepREM)
        XCTAssertEqual(SleepStage.from(rawValue: "HKCategoryValueSleepAnalysisAwake"), .awake)
        XCTAssertEqual(SleepStage.from(rawValue: "garbage"), .unknown)
    }

    // MARK: - Correlation dedupe

    func testCorrelationChildNotDoubleCounted() throws {
        let r = try parsed()
        // The HeartRate value 61 appears once top-level AND once inside the
        // Correlation; only one should survive.
        let hrCount = r.samples.filter { $0.type == "HeartRate" && $0.value == 61 }.count
        XCTAssertEqual(hrCount, 1, "Correlation-nested record was double-counted")
    }

    func testDedupeOnIdenticalKey() throws {
        // Two identical records at top level should collapse to one.
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <HealthData>
         <Record type="HKQuantityTypeIdentifierHeartRate" sourceName="W" unit="count/min" startDate="2024-01-02 08:00:00 +0000" endDate="2024-01-02 08:00:00 +0000" value="70"/>
         <Record type="HKQuantityTypeIdentifierHeartRate" sourceName="W" unit="count/min" startDate="2024-01-02 08:00:00 +0000" endDate="2024-01-02 08:00:00 +0000" value="70"/>
        </HealthData>
        """
        let r = try AppleHealthImporter().importXML(data: Data(xml.utf8))
        XCTAssertEqual(r.samples.filter { $0.type == "HeartRate" }.count, 1)
    }

    // MARK: - Workouts

    func testWorkoutParsed() throws {
        let r = try parsed()
        XCTAssertEqual(r.workouts.count, 1)
        let w = r.workouts[0]
        XCTAssertEqual(w.activityType, "Running")
        XCTAssertEqual(w.durationS, 45 * 60)              // 45 min -> seconds
        XCTAssertEqual(w.distanceM!, 8050, accuracy: 0.5) // 8.05 km -> ~8050 m
        XCTAssertEqual(w.energyKcal, 540)
        XCTAssertEqual(w.start, Fixtures.utc(2024, 1, 2, 16, 0, 0)) // 17:00 +0100
        XCTAssertEqual(w.tzOffsetMin, 60)
    }

    // MARK: - Prefix stripping

    func testStripPrefix() {
        XCTAssertEqual(HealthXMLDelegate.stripPrefix("HKQuantityTypeIdentifierHeartRate"), "HeartRate")
        XCTAssertEqual(HealthXMLDelegate.stripPrefix("HKCategoryTypeIdentifierSleepAnalysis"), "SleepAnalysis")
        XCTAssertEqual(HealthXMLDelegate.stripPrefix("HKWorkoutActivityTypeRunning"), "Running")
        XCTAssertEqual(HealthXMLDelegate.stripPrefix("AlreadyClean"), "AlreadyClean")
    }

    // MARK: - Summary

    func testSummary() throws {
        let r = try parsed()
        XCTAssertEqual(r.summary.sourceKind, .appleHealth)
        XCTAssertGreaterThan(r.summary.recordCount, 0)
        XCTAssertEqual(r.summary.recordCount, r.samples.count + r.workouts.count)
        XCTAssertNotNil(r.summary.earliest)
        XCTAssertNotNil(r.summary.latest)
        XCTAssertLessThanOrEqual(r.summary.earliest!, r.summary.latest!)
        XCTAssertEqual(r.summary.countsByCategory["Workout"], 1)
    }

    // MARK: - Unknown elements tolerated

    func testUnknownElementsTolerated() throws {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <HealthData>
         <SomeFutureElement foo="bar"><Nested/></SomeFutureElement>
         <Record type="HKQuantityTypeIdentifierHeartRate" sourceName="W" unit="count/min" startDate="2024-01-02 08:00:00 +0000" endDate="2024-01-02 08:00:00 +0000" value="80">
          <UnknownChild key="x" value="y"/>
         </Record>
        </HealthData>
        """
        let r = try AppleHealthImporter().importXML(data: Data(xml.utf8))
        XCTAssertEqual(r.samples.count, 1)
        XCTAssertEqual(r.samples[0].value, 80)
    }
}
