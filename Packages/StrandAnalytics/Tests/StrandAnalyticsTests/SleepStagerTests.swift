import XCTest
@testable import StrandAnalytics
import WhoopProtocol

final class SleepStagerTests: XCTestCase {

    // MARK: - Cole–Kripke

    func testColeKripkeAllStillIsSleep() {
        // Zero activity → SI = 0 < 1 for every epoch → all sleep.
        let flags = SleepStager.coleKripke([Double](repeating: 0, count: 20))
        XCTAssertTrue(flags.allSatisfy { $0 })
    }

    func testColeKripkeHighActivityIsWake() {
        // A large clipped count at the center weight (230) → SI ≥ 1 → wake.
        // rescaled count of 300 (the clip) at A0: 0.001 * 230 * 300 = 69 ≥ 1.
        var counts = [Double](repeating: 0, count: 9)
        counts[4] = 300
        let flags = SleepStager.coleKripke(counts)
        XCTAssertFalse(flags[4])  // center epoch is wake
    }

    func testRescaleCountsDivideAndClip() {
        XCTAssertEqual(SleepStager.rescaleCounts([200]), [2.0])
        XCTAssertEqual(SleepStager.rescaleCounts([50000]), [300.0])  // clipped
    }

    // MARK: - Gravity stillness spine

    /// Build a still gravity stream (constant orientation) at 1 Hz.
    private func stillGravity(start: Int, durationS: Int) -> [GravitySample] {
        (0..<durationS).map { GravitySample(ts: start + $0, x: 0, y: 0, z: 1.0) }
    }

    /// Build an active gravity stream (oscillating) at 1 Hz.
    private func activeGravity(start: Int, durationS: Int) -> [GravitySample] {
        (0..<durationS).map { i -> GravitySample in
            let phase = Double(i % 2) * 0.5  // 0.5 g jumps per sample → clearly moving
            return GravitySample(ts: start + i, x: phase, y: 0, z: 1.0)
        }
    }

    private func hrStream(start: Int, durationS: Int, bpm: Int) -> [HRSample] {
        (0..<durationS).map { HRSample(ts: start + $0, bpm: bpm) }
    }

    /// Unix start at `hourUTC:00:00` on a fixed reference day. With the detector's default
    /// tzOffset=0, local hour == UTC hour, so this lets a test place a window's center in or
    /// out of the daytime band [11,20) deterministically.
    private func startAtHour(_ hourUTC: Int) -> Int {
        // 2026-06-10 00:00:00 UTC (an arbitrary fixed midnight) + hourUTC hours.
        let refMidnight = 1_749_513_600
        return refMidnight + hourUTC * 3_600
    }
    /// Window anchored at a clear NIGHT hour (center stays out of [11,20) for short windows).
    private func nightStart(_ hourUTC: Int) -> Int { startAtHour(hourUTC) }
    /// Window anchored at a DAYTIME hour (center lands in [11,20) for the durations tested).
    private func daytimeStart(_ hourUTC: Int) -> Int { startAtHour(hourUTC) }

    func testDetectSleepFindsStillNight() {
        // 90 min still + low HR (50 bpm) → one sleep session.
        // Anchored at 02:00 UTC (center 02:45) so the window is OVERNIGHT at the default
        // tzOffset=0 and never trips the daytime false-sleep guard (#90) — a plain still
        // night must always register regardless of the guard.
        let start = nightStart(02)
        let dur = 90 * 60
        let grav = stillGravity(start: start, durationS: dur)
        let hr = hrStream(start: start, durationS: dur, bpm: 50)
        let sessions = SleepStager.detectSleep(hr: hr, gravity: grav)
        XCTAssertEqual(sessions.count, 1)
        let s = sessions[0]
        XCTAssertEqual(s.start, start)
        XCTAssertGreaterThan(s.efficiency, 0.5)
        XCTAssertEqual(s.restingHR, 50)
    }

    func testDetectSleepRejectsShortBout() {
        // Only 30 min still — below MIN_SLEEP_MIN (60) → no session.
        let start = 2_000_000
        let grav = stillGravity(start: start, durationS: 30 * 60)
        let hr = hrStream(start: start, durationS: 30 * 60, bpm: 50)
        XCTAssertTrue(SleepStager.detectSleep(hr: hr, gravity: grav).isEmpty)
    }

    func testDetectSleepEmptyGravity() {
        XCTAssertTrue(SleepStager.detectSleep(gravity: []).isEmpty)
    }

    func testDetectSleepHRConfirmationRejectsHighHR() {
        // Still gravity but HR is well above the day median*1.05. The daytime is
        // long (4 h) and low-HR (55) so the day median stays ~55; the still 90-min
        // "night" runs at 120 bpm, which exceeds 55*1.05 → the run is HR-rejected.
        let start = 3_000_000
        let sleepDur = 90 * 60
        let dayDur = 4 * 60 * 60
        let dayGrav = activeGravity(start: start, durationS: dayDur)
        let dayHR = hrStream(start: start, durationS: dayDur, bpm: 55)
        let nightGrav = stillGravity(start: start + dayDur, durationS: sleepDur)
        let nightHR = hrStream(start: start + dayDur, durationS: sleepDur, bpm: 120)
        let sessions = SleepStager.detectSleep(hr: dayHR + nightHR, gravity: dayGrav + nightGrav)
        // The still run's mean HR (120) >> median(55)*1.05 → rejected.
        XCTAssertTrue(sessions.isEmpty)
    }

    // MARK: - Daytime false-sleep guard (#90)

    /// A 70-min still, LOW-HR daytime window is rejected: even though its HR dips, it is
    /// shorter than the daytime minimum (90 min), so it's the dominant false-positive a
    /// sedentary daytime stretch produces. The preceding active block lifts the day HR
    /// baseline so the HR test would otherwise PASS — proving the rejection is the duration
    /// gate, not the HR gate.
    func testDaytimeShortLowHRWindowRejected() {
        let dayStart = daytimeStart(10)           // 10:00 active context
        let dayDur = 3 * 60 * 60                   // 3 h awake, moving, HR 72
        let dayGrav = activeGravity(start: dayStart, durationS: dayDur)
        let dayHR = hrStream(start: dayStart, durationS: dayDur, bpm: 72)

        let napStart = dayStart + dayDur           // 13:00, center 13:35 → daytime band
        let napDur = 70 * 60                        // 70 min < 90 min daytime minimum
        let napGrav = stillGravity(start: napStart, durationS: napDur)
        let napHR = hrStream(start: napStart, durationS: napDur, bpm: 50)

        let sessions = SleepStager.detectSleep(hr: dayHR + napHR, gravity: dayGrav + napGrav)
        XCTAssertTrue(sessions.isEmpty, "a 70-min daytime still window must be rejected by the guard")
    }

    /// A 120-min still, genuine-dip daytime nap STILL registers: ≥ 90 min AND its resting HR
    /// (50) sits clearly below the day HR baseline (~72), the cardiac signature of a real nap.
    /// The guard must not suppress legitimate daytime sleep.
    func testDaytimeQualityNapRegisters() {
        let dayStart = daytimeStart(10)            // 10:00 active context, HR 72
        let dayDur = 3 * 60 * 60
        let dayGrav = activeGravity(start: dayStart, durationS: dayDur)
        let dayHR = hrStream(start: dayStart, durationS: dayDur, bpm: 72)

        let napStart = dayStart + dayDur            // 13:00, center 14:00 → daytime band
        let napDur = 120 * 60                        // 120 min ≥ 90 min daytime minimum
        let napGrav = stillGravity(start: napStart, durationS: napDur)
        let napHR = hrStream(start: napStart, durationS: napDur, bpm: 50)

        let sessions = SleepStager.detectSleep(hr: dayHR + napHR, gravity: dayGrav + napGrav)
        XCTAssertEqual(sessions.count, 1, "a 120-min daytime nap with a real HR dip must register")
        // The run begins at/just after the active→still transition (the rolling stillness window
        // shifts the boundary by a few minutes), and its center is firmly in the daytime band.
        XCTAssertGreaterThanOrEqual(sessions[0].start, napStart)
        XCTAssertLessThan(sessions[0].start, napStart + 10 * 60)
        XCTAssertEqual(sessions[0].restingHR, 50)
    }

    /// A 70-min still, low-HR OVERNIGHT window registers unchanged: its center (≈03:35) is
    /// outside the daytime band, so the guard never applies and only the base 60-min minimum
    /// gates it. This pins that the guard leaves overnight detection exactly as it was.
    func testOvernightShortWindowUnchanged() {
        let dayStart = nightStart(00)               // 00:00 active context so a baseline exists
        let dayDur = 3 * 60 * 60                     // moving, HR 72
        let dayGrav = activeGravity(start: dayStart, durationS: dayDur)
        let dayHR = hrStream(start: dayStart, durationS: dayDur, bpm: 72)

        let sleepStartTs = dayStart + dayDur         // 03:00, center 03:35 → overnight
        let sleepDur = 70 * 60                         // 70 min > 60 min base minimum
        let sleepGrav = stillGravity(start: sleepStartTs, durationS: sleepDur)
        let sleepHR = hrStream(start: sleepStartTs, durationS: sleepDur, bpm: 50)

        let sessions = SleepStager.detectSleep(hr: dayHR + sleepHR, gravity: dayGrav + sleepGrav)
        XCTAssertEqual(sessions.count, 1, "a 70-min overnight still window must register unchanged")
        // Begins at/just after the active→still transition; center stays out of the daytime band.
        XCTAssertGreaterThanOrEqual(sessions[0].start, sleepStartTs)
        XCTAssertLessThan(sessions[0].start, sleepStartTs + 10 * 60)
    }

    /// The guard is offset-aware: the SAME absolute window that is overnight at tzOffset=0
    /// becomes daytime under a +10 h offset and is then held to the stricter bar. With no
    /// preceding awake block there is no HR baseline, so the daytime path rejects it (it can't
    /// confirm a real dip) — while at offset 0 the identical 70-min still window registers.
    func testTzOffsetShiftsWindowIntoDaytimeBand() {
        let start = nightStart(02)                   // 02:00 UTC, center 02:35
        let dur = 70 * 60
        let grav = stillGravity(start: start, durationS: dur)
        let hr = hrStream(start: start, durationS: dur, bpm: 50)

        // offset 0: overnight → registers.
        XCTAssertEqual(SleepStager.detectSleep(hr: hr, gravity: grav).count, 1)
        // +10 h: local center ≈ 12:35 → daytime band → stricter bar; no awake baseline → rejected.
        let shifted = SleepStager.detectSleep(hr: hr, gravity: grav, tzOffsetSeconds: 10 * 3_600)
        XCTAssertTrue(shifted.isEmpty, "a +10h offset pushes the window into the daytime band → rejected")
    }

    /// Guards against the index-out-of-range crash class from the prior attempt: no candidate
    /// at all (single still day, no HR) must return [] cleanly, not trap on empty median /
    /// first/last accesses inside the daytime path.
    func testDaytimeGuardEmptyInputsNoCrash() {
        // A still daytime stretch with NO HR at all → baseline nil → daytime path returns false
        // without touching any HR array; must not crash and must yield no sessions.
        let start = daytimeStart(13)
        let grav = stillGravity(start: start, durationS: 120 * 60)
        XCTAssertTrue(SleepStager.detectSleep(gravity: grav).isEmpty)
        // And the pure band/guard helpers tolerate a degenerate zero-length period.
        let p = SleepStager.Period(stage: "sleep", start: start, end: start)
        _ = SleepStager.isDaytimeCenter(p, tzOffsetSeconds: 0)
        XCTAssertFalse(SleepStager.passesDaytimeGuard(p, restingHR: nil, baseline: nil))
    }

    // MARK: - Staging output integrity

    func testStagesTileSessionExactly() {
        let start = 4_000_000
        let dur = 90 * 60
        let grav = stillGravity(start: start, durationS: dur)
        let hr = hrStream(start: start, durationS: dur, bpm: 50)
        let s = SleepStager.detectSleep(hr: hr, gravity: grav)[0]
        XCTAssertFalse(s.stages.isEmpty)
        // Segments must be contiguous and span exactly [start, end].
        XCTAssertEqual(s.stages.first!.start, s.start)
        XCTAssertEqual(s.stages.last!.end, s.end)
        for i in 0..<(s.stages.count - 1) {
            XCTAssertEqual(s.stages[i].end, s.stages[i + 1].start)
        }
        // Every stage label is one of the four valid classes.
        for seg in s.stages {
            XCTAssertTrue(["wake", "light", "deep", "rem"].contains(seg.stage))
        }
    }

    func testEfficiencyComputation() {
        // A 1000 s session with 100 s of wake → efficiency = 0.9.
        let stages = [
            StageSegment(start: 0, end: 100, stage: "wake"),
            StageSegment(start: 100, end: 1000, stage: "light"),
        ]
        let eff = SleepStager.efficiency(start: 0, end: 1000, stages: stages)
        XCTAssertEqual(eff, 0.9, accuracy: 1e-9)
    }

    // MARK: - Hypnogram metrics

    func testHypnogramMetricsAASM() {
        // SOL 60 s, then light 540 s, deep 300 s, wake 60 s (disturbance), rem 240 s.
        let stages = [
            StageSegment(start: 0, end: 60, stage: "wake"),       // pre-onset latency
            StageSegment(start: 60, end: 600, stage: "light"),    // 540 s
            StageSegment(start: 600, end: 900, stage: "deep"),    // 300 s
            StageSegment(start: 900, end: 960, stage: "wake"),    // WASO 60 s
            StageSegment(start: 960, end: 1200, stage: "rem"),    // 240 s
        ]
        let session = SleepSession(start: 0, end: 1200, efficiency: 0.95,
                                   stages: stages, restingHR: 50, avgHRV: 60)
        let m = SleepStager.hypnogramMetrics(session)
        XCTAssertEqual(m.tibS, 1200, accuracy: 1e-9)
        XCTAssertEqual(m.tstS, 540 + 300 + 240, accuracy: 1e-9)  // 1080
        XCTAssertEqual(m.solS, 60, accuracy: 1e-9)
        XCTAssertEqual(m.wasoS, 60, accuracy: 1e-9)
        XCTAssertEqual(m.disturbances, 1)
        XCTAssertEqual(m.deepMin, 5.0, accuracy: 1e-9)
        XCTAssertEqual(m.remMin, 4.0, accuracy: 1e-9)
        XCTAssertEqual(m.lightMin, 9.0, accuracy: 1e-9)
        // Percentages sum to ~100.
        XCTAssertEqual(m.deepPct + m.remPct + m.lightPct, 100.0, accuracy: 1e-6)
    }

    func testHypnogramREMLatency() {
        let stages = [
            StageSegment(start: 0, end: 300, stage: "light"),   // onset at 0
            StageSegment(start: 300, end: 600, stage: "rem"),   // first REM at 300
        ]
        let session = SleepSession(start: 0, end: 600, efficiency: 1.0,
                                   stages: stages, restingHR: nil, avgHRV: nil)
        let m = SleepStager.hypnogramMetrics(session)
        XCTAssertEqual(m.remLatencyS, 300, accuracy: 1e-9)
    }

    // MARK: - Respiration helper

    func testRespRateFromSyntheticBreathing() {
        // Synthesize a clean 0.25 Hz breathing wave (15 br/min) over 60 s at 1 Hz.
        let n = 60
        let resp = (0..<n).map { i -> Double in sin(2 * Double.pi * 0.25 * Double(i)) * 10 + 100 }
        let (rate, rrv) = SleepStager.respRateAndRRV(resp)
        XCTAssertFalse(rate.isNaN)
        XCTAssertEqual(rate, 15.0, accuracy: 2.0)  // ~15 breaths/min
        XCTAssertGreaterThanOrEqual(rrv, 0)
    }

    func testRespRateTooFewSamples() {
        let (rate, rrv) = SleepStager.respRateAndRRV([1, 2, 3])
        XCTAssertTrue(rate.isNaN)
        XCTAssertTrue(rrv.isNaN)
    }
}
