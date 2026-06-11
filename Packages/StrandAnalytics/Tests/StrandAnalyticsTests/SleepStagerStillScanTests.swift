import XCTest
@testable import StrandAnalytics
import WhoopProtocol

/// Pins SleepStager.classifyStill's prefix-sum rolling count to the naive per-record rescan
/// it replaced (the rescan was O(n·window) — at 1 Hz, ~10⁸ array reads per 42 h analysis
/// window; on Android the same loop ran on the main thread and froze the app into ANRs).
/// The two must agree flag-for-flag on every input, including the window-clamping edges
/// (record near the stream start/end, window wider than the whole stream, sub-minimum
/// streams) and the strict-< threshold boundary. Mirror of SleepStagerStillScanTest.kt.
final class SleepStagerStillScanTests: XCTestCase {

    /// The original O(n·window) implementation, kept verbatim as the reference oracle.
    private func naiveClassifyStill(_ grav: [GravitySample], _ deltas: [Double]) -> [Bool] {
        let n = grav.count
        if n < 2 { return [Bool](repeating: false, count: n) }
        let half = SleepStager.windowSize(grav.map { $0.ts }) / 2
        var flags: [Bool] = []
        flags.reserveCapacity(n)
        for i in 0..<n {
            let lo = max(0, i - half)
            let hi = min(n, i + half + 1)
            var stillCount = 0
            for j in lo..<hi where deltas[j] < SleepStager.gravityStillThresholdG { stillCount += 1 }
            flags.append(Double(stillCount) / Double(hi - lo) >= SleepStager.stillFraction)
        }
        return flags
    }

    /// Deterministic LCG so the fixture is reproducible without seeding system randomness.
    private struct LCG {
        var state: UInt64
        mutating func next() -> UInt64 {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return state >> 33
        }
        /// Uniform double in [lo, hi).
        mutating func uniform(_ lo: Double, _ hi: Double) -> Double {
            lo + (hi - lo) * (Double(next() % 1_000_000) / 1_000_000.0)
        }
    }

    /// 1 Hz gravity stream whose per-sample movement alternates between long still and active
    /// spans, so still/active boundaries land at many offsets relative to the rolling window.
    private func mixedStream(n: Int, seed: UInt64) -> ([GravitySample], [Double]) {
        var rnd = LCG(state: seed)
        var grav: [GravitySample] = []
        grav.reserveCapacity(n)
        var active = false
        for i in 0..<n {
            if rnd.next() % 120 == 0 { active.toggle() }
            let jitter = active ? rnd.uniform(0.02, 0.4) : rnd.uniform(0.0, 0.009)
            grav.append(GravitySample(ts: 1_749_513_600 + i, x: i % 2 == 0 ? jitter : 0, y: 0, z: 1.0))
        }
        return (grav, SleepStager.gravityDeltas(grav))
    }

    func testPrefixSumMatchesNaiveRescanMixed1HzStream() {
        let (grav, deltas) = mixedStream(n: 7_200, seed: 42) // 2 h at 1 Hz, window 900 samples
        XCTAssertEqual(naiveClassifyStill(grav, deltas), SleepStager.classifyStill(grav, deltas))
    }

    func testPrefixSumMatchesNaiveRescanWindowWiderThanStream() {
        // 1 Hz stream much shorter than the 15-min window: every record's window clamps to the
        // whole stream on at least one side.
        let (grav, deltas) = mixedStream(n: 300, seed: 7)
        XCTAssertEqual(naiveClassifyStill(grav, deltas), SleepStager.classifyStill(grav, deltas))
    }

    func testPrefixSumMatchesNaiveRescanSparseSampling() {
        // 60 s spacing (the defaultIntervalS regime) → window of 15 samples; exercises the
        // small-window path where the clamped edges dominate.
        var rnd = LCG(state: 11)
        let grav = (0..<200).map { i -> GravitySample in
            GravitySample(ts: 1_749_513_600 + i * 60, x: rnd.uniform(0.0, 0.03), y: 0, z: 1.0)
        }
        let deltas = SleepStager.gravityDeltas(grav)
        XCTAssertEqual(naiveClassifyStill(grav, deltas), SleepStager.classifyStill(grav, deltas))
    }

    func testThresholdBoundaryIsStrictlyBelow() {
        // Deltas exactly AT gravityStillThresholdG are NOT still (strict <). Random fixtures
        // can never hit 0.01 exactly, so a < → <= drift in either the prefix-sum build or the
        // oracle would pass every other test; this pins the operator on a hand-built delta list.
        let n = 16
        let grav = (0..<n).map { GravitySample(ts: 1_749_513_600 + $0, x: 0, y: 0, z: 1.0) }
        let atThreshold = [Double](repeating: SleepStager.gravityStillThresholdG, count: n)
        XCTAssertEqual(naiveClassifyStill(grav, atThreshold), SleepStager.classifyStill(grav, atThreshold))
        XCTAssertEqual(SleepStager.classifyStill(grav, atThreshold), [Bool](repeating: false, count: n))
        let justBelow = [Double](repeating: SleepStager.gravityStillThresholdG - 1e-9, count: n)
        XCTAssertEqual(SleepStager.classifyStill(grav, justBelow), [Bool](repeating: true, count: n))
    }

    func testSmallestStreamsThatReachThePrefixScan() {
        // n == 2 just passes the n < 2 guard (single medianIntervalS gap); n == 3 is the
        // minWindowSamples floor. Every window clamps to the full stream at these sizes.
        for n in 2...3 {
            let (grav, deltas) = mixedStream(n: n, seed: UInt64(n))
            XCTAssertEqual(naiveClassifyStill(grav, deltas), SleepStager.classifyStill(grav, deltas))
        }
    }

    func testSubMinimumStreamsAllFalse() {
        XCTAssertEqual(SleepStager.classifyStill([], []), [])
        let one = [GravitySample(ts: 1_749_513_600, x: 0, y: 0, z: 1.0)]
        XCTAssertEqual(SleepStager.classifyStill(one, SleepStager.gravityDeltas(one)), [false])
    }
}
