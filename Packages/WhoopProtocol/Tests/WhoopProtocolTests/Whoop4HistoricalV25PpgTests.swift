import XCTest
@testable import WhoopProtocol

/// WHOOP 4.0 **v25** PPG → HR feasibility guard (issue #194, RFC — NOT a live decode).
///
/// #194 proposed reading the v25 record's optical PPG waveform on an odd byte grid and routing it through
/// the existing `PpgHr` lane to recover HR (the way v26/WHOOP-5 does). The original evidence was "60 bpm
/// on 3 resting sessions". @ryanbr then **withdrew** that result: concatenating N samples/record before
/// autocorrelating manufactures a self-similarity at lag = N, which peaks at `60·fs/N` (= 60 bpm at
/// fs=N=24) *regardless of the real HR* — it reports the record PERIOD, not physiology. The maintainer
/// accepted this, audited the shipped v26 lane for the same trap, and added the boundary-gated
/// `PpgHr.removeRecordRateComponent` notch (v2.8.6).
///
/// This test PINS that finding against the three REAL v25 frames already in the repo
/// (`Whoop4HistoricalV25Tests`), and documents two facts a future v25-PPG decoder must respect:
///
///   1. **The bare-autocorrelation "60 bpm" is the concatenation artifact.** At the start offset where
///      ryanbr saw it (15), varying samples-per-record N makes the reported bpm track `1440/N` EXACTLY
///      (16→90 … 24→60 … 30→48) — the record period 60·fs/N, with no stable pulse underneath.
///
///   2. **The v2.8.6 notch does NOT fully neutralise this artifact, so the START BYTE is load-bearing.**
///      Fed through the SHIPPED `PpgHr.derivePpgHr` lane, the #194-proposed span (start 25, before
///      gravity@73) yields NO HR — good — but the SAME lane reading from offset 15 still emits a
///      fabricated 60 bpm at conf ≈ 0.32, because there the per-record waveforms are near-identical
///      (the slow unix tail) so the boundary discontinuity the notch keys on never fires. A v25 decoder
///      that picked a start a few bytes off — entirely possible while the exact span is unpinned — would
///      ship plausible-but-wrong HR. That is precisely why this stays held pending a non-resting,
///      multi-strap, known-HR-≠-60 corpus (#194), and why this guard is executable rather than prose.
///
/// It does NOT wire v25 into the live HR lane.
final class Whoop4HistoricalV25PpgTests: XCTestCase {

    private func bytes(_ s: String) -> [UInt8] {
        var out = [UInt8](); out.reserveCapacity(s.count / 2); var i = s.startIndex
        while i < s.endIndex { let j = s.index(i, offsetBy: 2)
            out.append(UInt8(s[i..<j], radix: 16)!); i = j }
        return out
    }

    // The same three REAL v25 records used by Whoop4HistoricalV25Tests (faklei, App 1.92, 84 bytes,
    // consecutive seconds, resting). Re-stated here so this guard is self-contained.
    private lazy var records = [
        "aa50000c2f1900006800007dff2a6a20430900433103007e026502ba026c022eff70f996f879fad6fd8300d6017e0267027201be00290258030e05c507f00c030ead11cb15791500d2553c9003000000d6393716",
        "aa50000c2f1900016800007eff2a6a283e0900a0ad03007a0e880698018bfff5fb61eee9f2a7fa2bfe1af5fdf618fdf0f9c2fb0804510a14046a004dffd0ff6dfdddfd670183014e071a3f9003000000587bbabf",
        "aa50000c2f1900026800007fff2a6a38390900729103003608a2fd0104850d4f1bd21aa60f080d850edb116b0f160b7d063f06ab04d5041704a4045f04f003f5ffd7ff7efe73ffa8b2333e9003010000fa54e5e9",
    ].map { bytes($0) }

    /// i16 LE at `off`, nil when out of range (mirrors the interpreter readers).
    private func i16(_ f: [UInt8], _ off: Int) -> Int? {
        off + 2 <= f.count ? Int(Int16(bitPattern: UInt16(f[off]) | (UInt16(f[off + 1]) << 8))) : nil
    }
    private func u32(_ f: [UInt8], _ off: Int) -> Int {
        Int(UInt32(f[off]) | (UInt32(f[off + 1]) << 8) | (UInt32(f[off + 2]) << 16) | (UInt32(f[off + 3]) << 24))
    }

    /// PPG samples at `start` on the odd i16 grid, `count` samples.
    private func ppg(_ f: [UInt8], start: Int, count: Int = 24) -> [Int] {
        (0..<count).compactMap { i16(f, start + $0 * 2) }
    }

    /// Bare windowed autocorrelation (ryanbr's original method): concat → mean-remove → global-peak bpm
    /// over the 30…220 bpm band, using the EXACT band of the #194 repro. NO record-rate notch.
    private func bareBpm(_ sig: [Int], fs: Int = 24) -> Int {
        let mean = Double(sig.reduce(0, +)) / Double(sig.count)
        let x = sig.map { Double($0) - mean }
        guard x.reduce(0, { $0 + $1 * $1 }) != 0 else { return 0 }
        let lo = max(1, 60 * fs / 220), hi = min(sig.count - 1, 60 * fs / 30)   // int trunc, as in the issue
        var best = lo, bestV = -Double.infinity
        for lag in lo...hi {
            var s = 0.0
            for k in 0..<(x.count - lag) { s += x[k] * x[k + lag] }
            if s > bestV { bestV = s; best = lag }
        }
        return Int((Double(fs) * 60 / Double(best)).rounded())
    }

    /// Sanity: these are the v25 fixtures (consecutive seconds) — the inputs #194 used.
    func testFixtureIsV25Consecutive() {
        let ts = records.map { u32($0, 11) }
        XCTAssertEqual(ts, [ts[0], ts[0] + 1, ts[0] + 2], "expected 3 consecutive-second v25 records")
        for f in records {
            XCTAssertEqual(Int(f[5]), 25)
            XCTAssertEqual(ppg(f, start: 25).count, 24, "24 odd-grid i16 samples fit before gravity@73")
        }
    }

    /// The decisive disproof: at ryanbr's offset (15) the bare-autocorrelation "bpm" is the concatenation
    /// artifact, not HR. Vary samples-per-record N and the reported bpm tracks `1440/N` EXACTLY
    /// (16→90 … 24→60 … 30→48), i.e. the record period 60·fs/N. (#194, ryanbr.)
    func testConcatenationArtifactTracksRecordPeriodNotHr() {
        let start = 15
        for N in [16, 18, 20, 24, 30] {
            var sig = [Int]()
            for f in records { sig.append(contentsOf: (0..<N).compactMap { i16(f, start + $0 * 2) }) }
            XCTAssertEqual(bareBpm(sig), 1440 / N,
                           "N=\(N): bare bpm should equal the record period 1440/N (=\(1440 / N)) — the artifact")
        }
    }

    /// The #194-proposed PPG span (start 25, 24 i16 before gravity@73) yields NO HR through the shipped
    /// lane — the specific diff isn't immediately harmful on these resting frames.
    func testProposedSpanEmitsNoHrThroughShippedLane() {
        let recs: [(ts: Int, samples: [Int])] = records.map { (ts: u32($0, 11), samples: ppg($0, start: 25)) }
        XCTAssertTrue(PpgHr.derivePpgHr(records: recs).isEmpty,
                      "the proposed start-25 span must not produce HR through the shipped lane")
    }

    /// THE GUARD THAT MATTERS: the v2.8.6 notch does NOT fully neutralise the v25 artifact — reading from
    /// offset 15 (where the per-record waveforms are near-identical, so the boundary jump the notch keys
    /// on never fires) the SHIPPED lane still emits a fabricated 60 bpm. This pins WHY the start byte is
    /// load-bearing and why v25→HR must not ship on an unpinned span. If a future change makes the notch
    /// reject this too, update the expectation — that would be a strictly safer lane.
    func testNotchDoesNotFullyProtectV25SoStartByteIsLoadBearing() {
        let recs: [(ts: Int, samples: [Int])] = records.map { (ts: u32($0, 11), samples: ppg($0, start: 15)) }
        let hr = PpgHr.derivePpgHr(records: recs)
        XCTAssertFalse(hr.isEmpty, "offset-15 read should surface the artifact the notch misses")
        XCTAssertTrue(hr.allSatisfy { $0.bpm == 60 },
                      "the surviving artifact is the record-period 60 bpm (got \(hr.map(\.bpm)))")
        // It is plausible-looking (conf ~0.32, just over the 0.3 gate) — exactly the dangerous case.
        XCTAssertTrue(hr.allSatisfy { $0.conf < 0.5 },
                      "artifact confidence is low-but-passing, the worst kind of false positive")
    }
}
