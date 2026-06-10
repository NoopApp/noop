import XCTest
@testable import StrandAnalytics
import WhoopProtocol
import WhoopStore

final class AnalyticsEngineTests: XCTestCase {

    func testVersion() {
        XCTAssertEqual(StrandAnalytics.version, "0.1.0")
    }

    func testDayStringUTC() {
        // 2021-01-01 00:00:00 UTC == 1609459200.
        XCTAssertEqual(AnalyticsEngine.dayString(1_609_459_200), "2021-01-01")
    }

    /// Build a still, low-HR night ending on a known UTC day.
    private func night(endDay: String, hours: Int) -> (start: Int, end: Int,
                                                       hr: [HRSample], rr: [RRInterval],
                                                       gravity: [GravitySample]) {
        // Pick an end timestamp on `endDay` at 06:00 UTC.
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.timeZone = TimeZone(identifier: "UTC")
        fmt.dateFormat = "yyyy-MM-dd"
        let dayMidnight = Int(fmt.date(from: endDay)!.timeIntervalSince1970)
        let end = dayMidnight + 6 * 3600
        let start = end - hours * 3600

        var hr: [HRSample] = []
        var rr: [RRInterval] = []
        var grav: [GravitySample] = []
        for t in start..<end {
            hr.append(HRSample(ts: t, bpm: 50))
            grav.append(GravitySample(ts: t, x: 0, y: 0, z: 1))  // still
        }
        // RR every 2 s at ~1200 ms with tiny oscillation (avoids ectopic rejection).
        var toggle = false
        for t in stride(from: start, to: end, by: 2) {
            rr.append(RRInterval(ts: t, rrMs: toggle ? 1205 : 1195))
            toggle.toggle()
        }
        return (start, end, hr, rr, grav)
    }

    func testAnalyzeDayProducesSleepMetric() {
        let day = "2021-06-15"
        let n = night(endDay: day, hours: 7)
        let profile = UserProfile(weightKg: 75, heightCm: 178, age: 30, sex: "male")
        let result = AnalyticsEngine.analyzeDay(
            day: day, hr: n.hr, rr: n.rr, gravity: n.gravity, profile: profile)

        XCTAssertEqual(result.daily.day, day)
        XCTAssertEqual(result.sleepSessions.count, 1)
        XCTAssertNotNil(result.daily.totalSleepMin)
        XCTAssertGreaterThan(result.daily.totalSleepMin!, 0)
        XCTAssertEqual(result.daily.restingHr, 50)
        XCTAssertNotNil(result.daily.avgHrv)
        XCTAssertEqual(result.daily.avgHrv!, 10.0, accuracy: 1.0)  // RMSSD of ±5 ms oscillation
        // CachedSleepSession rows mirror the detected sessions and carry stage JSON.
        XCTAssertEqual(result.cachedSleep.count, 1)
        XCTAssertNotNil(result.cachedSleep[0].stagesJSON)
        XCTAssertEqual(result.cachedSleep[0].restingHr, 50)
    }

    func testAnalyzeDayColdStartRecoveryNil() {
        // No baselines supplied → recovery is nil (cold-start gate).
        let day = "2021-06-16"
        let n = night(endDay: day, hours: 7)
        let result = AnalyticsEngine.analyzeDay(
            day: day, hr: n.hr, rr: n.rr, gravity: n.gravity,
            profile: UserProfile(age: 30))
        XCTAssertNil(result.daily.recovery)
        XCTAssertNil(result.recovery)
    }

    func testAnalyzeDayWithBaselinesProducesRecovery() {
        let day = "2021-06-17"
        let n = night(endDay: day, hours: 7)
        // Trusted HRV + RHR baselines around the values this night will produce.
        let hrvBase = Baselines.foldHistory(Array(repeating: 10.0, count: 14), cfg: Baselines.hrvCfg)
        let rhrBase = Baselines.foldHistory(Array(repeating: 50.0, count: 14), cfg: Baselines.restingHRCfg)
        XCTAssertTrue(hrvBase.usable)
        let result = AnalyticsEngine.analyzeDay(
            day: day, hr: n.hr, rr: n.rr, gravity: n.gravity,
            profile: UserProfile(age: 30),
            baselines: AnalyticsEngine.ProfileBaselines(hrv: hrvBase, restingHR: rhrBase))
        XCTAssertNotNil(result.recovery)
        XCTAssertEqual(result.daily.recovery, result.recovery)
        XCTAssertGreaterThanOrEqual(result.recovery!, 0)
        XCTAssertLessThanOrEqual(result.recovery!, 100)
    }

    func testAnalyzeDayNoMatchingNight() {
        // A night ending on a different day → no sleep attributed to `day`.
        let n = night(endDay: "2021-06-18", hours: 7)
        let result = AnalyticsEngine.analyzeDay(
            day: "2021-06-19", hr: n.hr, rr: n.rr, gravity: n.gravity,
            profile: UserProfile(age: 30))
        XCTAssertEqual(result.sleepSessions.count, 0)
        XCTAssertNil(result.daily.totalSleepMin)
        XCTAssertEqual(result.daily.exerciseCount, 0)
    }

    func testAnalyzeDayDailyMetricRoundTripsThroughCodable() throws {
        // The produced DailyMetric must encode/decode (it's the WhoopStore cache shape).
        let day = "2021-06-20"
        let n = night(endDay: day, hours: 7)
        let result = AnalyticsEngine.analyzeDay(
            day: day, hr: n.hr, rr: n.rr, gravity: n.gravity, profile: UserProfile(age: 30))
        let data = try JSONEncoder().encode(result.daily)
        let decoded = try JSONDecoder().decode(DailyMetric.self, from: data)
        XCTAssertEqual(decoded, result.daily)
    }

    func testAnalyzeDayPopulatesParityFields() throws {
        // The Android-parity computations must land on the DailyMetric when the streams are
        // supplied: RSA respiration from RR, daily steps from the cumulative @57 counter,
        // whole-day HR-only calories, and the wear-gated skin-temp deviation (usable baseline).
        let day = "2021-06-21"
        let n = night(endDay: day, hours: 7)
        // RSA-modulated RR replacing the square-wave fixture: mean 1200 ms (HR 50), ±40 ms at
        // 0.25 Hz — a planted 15 breaths/min the estimator must recover.
        var rr: [RRInterval] = []
        var tSec = 0.0
        while tSec < Double(n.end - n.start) {
            let rrMs = 1200.0 + 40.0 * sin(2.0 * Double.pi * 0.25 * tSec)
            tSec += rrMs / 1000.0
            rr.append(RRInterval(ts: n.start + Int(tSec), rrMs: Int(rrMs)))
        }
        // Worn in-bed skin temp at 34 °C across the whole night (raw = °C × 128, Swift scale).
        let skin = (0..<(n.end - n.start)).map { SkinTempSample(ts: n.start + $0, raw: 4352) }
        // Step counter: morning movement after wake, inside the same UTC day → 250 steps.
        let steps = [StepSample(ts: n.end + 600, counter: 100),
                     StepSample(ts: n.end + 1200, counter: 350)]
        let skinBase = Baselines.foldHistory([33.5, 33.4, 33.6, 33.5],
                                             cfg: Baselines.metricCfg["skin_temp"]!)
        XCTAssertTrue(skinBase.usable)
        let result = AnalyticsEngine.analyzeDay(
            day: day, hr: n.hr, rr: rr, gravity: n.gravity, steps: steps, skinTemp: skin,
            profile: UserProfile(age: 30),
            baselines: AnalyticsEngine.ProfileBaselines(skinTemp: skinBase))
        XCTAssertEqual(result.sleepSessions.count, 1)
        XCTAssertEqual(result.daily.steps, 250)
        XCTAssertGreaterThan(try XCTUnwrap(result.daily.activeKcalEst), 0)
        // RSA respiration recovered from the in-bed RR (≈15 bpm planted, ±3 tolerance).
        XCTAssertEqual(try XCTUnwrap(result.daily.respRateBpm), 15.0, accuracy: 3.0)
        // Wear-gated nightly mean (34 °C plateau) + a positive deviation vs the ~33.5 °C baseline.
        XCTAssertEqual(try XCTUnwrap(result.nightlySkinTempC), 34.0, accuracy: 1e-9)
        XCTAssertGreaterThan(try XCTUnwrap(result.daily.skinTempDevC), 0.2)
    }

    func testAnalyzeDayWithoutNewStreamsLeavesParityFieldsNil() {
        // Pure-function contract: callers that don't supply steps/skinTemp (all pre-existing
        // call sites and tests) get nil steps + nil skinTempDevC — never a fabricated value.
        let day = "2021-06-22"
        let n = night(endDay: day, hours: 7)
        let result = AnalyticsEngine.analyzeDay(
            day: day, hr: n.hr, rr: n.rr, gravity: n.gravity, profile: UserProfile(age: 30))
        XCTAssertNil(result.daily.steps)
        XCTAssertNil(result.daily.skinTempDevC)
        XCTAssertNil(result.nightlySkinTempC)
    }
}
