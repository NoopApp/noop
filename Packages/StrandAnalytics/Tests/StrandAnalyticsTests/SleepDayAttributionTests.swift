import XCTest
@testable import StrandAnalytics
import WhoopProtocol

/// Regression for the timezone day-attribution bug: a UTC+8 user's overnight sleep ends in the
/// local morning, whose instant is on the PREVIOUS *UTC* day. The engine used to attribute by UTC
/// day (`dayString`), so the night was filed onto the wrong day and dropped entirely — the strap
/// banked a full, still night with low HR yet NOOP showed no sleep / no HRV (Royce, 2026-06-14,
/// Asia/Manila). Day attribution is now local (`dayString(_, tzOffsetSeconds:)`), matching
/// Repository/WhoopImporter. tzOffsetSeconds=0 keeps UTC behaviour for UTC users + existing tests.
final class SleepDayAttributionTests: XCTestCase {

    // 2026-06-13 00:00:00 UTC.
    private let jun13UTCMidnight = 1_781_308_800
    private let tzPlus8 = 8 * 3_600

    // 1 Hz gravity. still=true → ~constant vector (per-sample Δ≈0 < 0.01g → "still"/sleep);
    // still=false → x alternates by 0.2g (Δ > 0.01g → "active"/awake).
    private func gravity(_ from: Int, _ to: Int, still: Bool) -> [GravitySample] {
        var out: [GravitySample] = []
        var t = from, i = 0
        while t < to {
            let x = still ? 0.02 : (i % 2 == 0 ? 0.0 : 0.2)
            out.append(GravitySample(ts: t, x: x, y: 0.0, z: 1.0))
            t += 1; i += 1
        }
        return out
    }

    private func hr(_ from: Int, _ to: Int, bpm: Int) -> [HRSample] {
        stride(from: from, to: to, by: 1).map { HRSample(ts: $0, bpm: bpm) }
    }

    // R-R ~1 s apart with ±25 ms alternating jitter so RMSSD (avgHRV) is finite/non-zero.
    private func rr(_ from: Int, _ to: Int) -> [RRInterval] {
        var out: [RRInterval] = []
        var t = from, i = 0
        while t < to {
            out.append(RRInterval(ts: t, rrMs: 1000 + (i % 2 == 0 ? 25 : -25)))
            t += 1; i += 1
        }
        return out
    }

    /// A still night that wakes in the local morning of 2026-06-14 (UTC+8) — whose wake instant is
    /// 2026-06-13 22:30 UTC, i.e. the previous UTC day.
    private func makeNight() -> (grav: [GravitySample], hr: [HRSample], rr: [RRInterval]) {
        let sleepStart = jun13UTCMidnight + 14 * 3_600          // 22:00 local Jun13 = 14:00 UTC
        let sleepEnd   = jun13UTCMidnight + 22 * 3_600 + 1_800  // 06:30 local Jun14 = 22:30 UTC Jun13
        let dayBefore  = sleepStart - 3 * 3_600                 // 19:00 local: awake/active
        let dayAfter   = sleepEnd + 2 * 3_600                   // 08:30 local: awake/active

        let grav = gravity(dayBefore, sleepStart, still: false)
                 + gravity(sleepStart, sleepEnd, still: true)
                 + gravity(sleepEnd, dayAfter, still: false)
        let heart = hr(dayBefore, sleepStart, bpm: 70)
                  + hr(sleepStart, sleepEnd, bpm: 44)
                  + hr(sleepEnd, dayAfter, bpm: 70)
        return (grav, heart, rr(sleepStart, sleepEnd))
    }

    func testDayStringLocalShift() {
        // 2026-06-13 22:30 UTC — the wake instant.
        let wake = jun13UTCMidnight + 22 * 3_600 + 1_800
        XCTAssertEqual(AnalyticsEngine.dayString(wake), "2026-06-13")                       // UTC
        XCTAssertEqual(AnalyticsEngine.dayString(wake, tzOffsetSeconds: 0), "2026-06-13")    // offset 0 == UTC
        XCTAssertEqual(AnalyticsEngine.dayString(wake, tzOffsetSeconds: tzPlus8), "2026-06-14") // local +8
    }

    func testNightAttributedToLocalWakeDay() {
        let n = makeNight()
        let res = AnalyticsEngine.analyzeDay(day: "2026-06-14", hr: n.hr, rr: n.rr, gravity: n.grav,
                                             profile: UserProfile(), tzOffsetSeconds: tzPlus8)
        XCTAssertEqual(res.sleepSessions.count, 1, "the local-morning night belongs to 2026-06-14")
        XCTAssertNotNil(res.daily.totalSleepMin)
        XCTAssertGreaterThan(res.daily.totalSleepMin ?? 0, 300, "a full night, not a fragment")
        XCTAssertNotNil(res.daily.avgHrv, "HRV must populate from the matched night")
        XCTAssertNotNil(res.daily.restingHr)
    }

    func testBugReproUTCAttributionMissesIt() {
        // Documents the old behaviour: with UTC attribution (offset 0), the same night is NOT
        // matched to its local wake-day — exactly why sleep/HRV were missing.
        let n = makeNight()
        let res = AnalyticsEngine.analyzeDay(day: "2026-06-14", hr: n.hr, rr: n.rr, gravity: n.grav,
                                             profile: UserProfile(), tzOffsetSeconds: 0)
        XCTAssertEqual(res.sleepSessions.count, 0, "UTC attribution files the night on Jun 13, missing Jun 14")
        XCTAssertNil(res.daily.totalSleepMin)
    }
}
