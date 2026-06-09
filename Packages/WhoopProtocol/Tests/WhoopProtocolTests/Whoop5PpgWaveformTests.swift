import XCTest
@testable import WhoopProtocol

/// WHOOP 5.0 type-47 **version-26** record — the high-rate optical PPG buffer.
///
/// v26 is the high-rate sibling of the v18 per-second summary: **24 little-endian i16 samples at bytes
/// [27:75]**, one record per second (`unix` u32 LE @15, the same slot v18 uses). It was verified to be
/// an OPTICAL PPG trace — not IMU/motion — using HR as *internal* ground truth (no external reference):
/// the concatenated waveform's autocorrelation peaks at the heart rate (lag 14 = 102.9 bpm vs a measured
/// 101.7 bpm), trough-detection gives a 563 ms inter-beat interval (≈106 bpm), the pulse stays HR-locked
/// even when the wrist is still, and its amplitude is not motion-driven. See
/// `tools/linux-capture/analyze_v26_waveform.py` and `BLE_REVERSE_ENGINEERING.md` §5.
///
/// Samples are raw AC-coupled ADC counts — PPG has no absolute unit — so they are exposed verbatim with
/// no invented scale. Real type-47 frames carry no device name / serial / token, so the fixture is real.
final class Whoop5PpgWaveformTests: XCTestCase {

    private func bytes(_ s: String) -> [UInt8] {
        var out = [UInt8](); out.reserveCapacity(s.count / 2); var i = s.startIndex
        while i < s.endIndex { let j = s.index(i, offsetBy: 2)
            out.append(UInt8(s[i..<j], radix: 16)!); i = j }
        return out
    }

    // Real v26 record (unix 1780917232; a clean PPG upstroke from −1432 toward 0).
    private let v26Hex =
        "aa015000010035412f1a80ad418401f0a3266aae470100c3c5050068faccfa8dfb46fc8bfd4c" +
        "febafedafe6dff56ffd5fffbff37ff6afce5f9d7f8dffa5efc98fddbfe5afe84fe15ff5cff40" +
        "5fb33c50080101006cb67c17"

    private let expectedWaveform = [
        -1432, -1332, -1139, -954, -629, -436, -326, -294, -147, -170, -43, -5,
        -201, -918, -1563, -1833, -1313, -930, -616, -293, -422, -380, -235, -164,
    ]

    func testV26DecodesAsHistoricalData() {
        let f = parseFrame(bytes(v26Hex), family: .whoop5)
        XCTAssertEqual(f.typeName, "HISTORICAL_DATA")
        XCTAssertEqual(f.crcOK, true)
        XCTAssertEqual(f.parsed["hist_version"]?.intValue, 26)
    }

    func testV26PpgWaveformAndUnix() {
        let p = parseFrame(bytes(v26Hex), family: .whoop5).parsed
        XCTAssertEqual(p["unix"]?.intValue, 1780917232)        // real unix, same @15 slot as v18
        XCTAssertEqual(p["ppg_sample_count"]?.intValue, 24)
        XCTAssertEqual(p["ppg_waveform"]?.intArrayValue, expectedWaveform)
        XCTAssertEqual(p["ppg_channel"]?.intValue, 1)          // channel index @21 (1 of the 26-channel sweep)
        XCTAssert((1...26).contains(p["ppg_channel"]!.intValue!))   // guard-lock: never out of the 1…26 range
    }

    /// A second real v26 frame from the NEXT optical channel in the sweep, captured in a separate 40 s
    /// burst ~19 min later. The strap time-multiplexes 26 channels (`@21` = 1…26), one per ~40-frame block.
    /// This frame reads channel `2` (the first read `1`) — consecutive steps of the sweep. (An earlier
    /// decode read `frame[12]` = 0x41/0x46 and mistook a high-entropy counter byte for the channel; those
    /// values are out of the 1…26 range, which the guard now rejects.) Both channels' waveforms
    /// autocorrelate to the heart rate (lag 14 ≈ 103 bpm); the physical LED mapping stays unclaimed.
    private let v26HexChannel46 =
        "aa015000010035412f1a803546840178a8266af54802004ca006007dfde1fde4fe9904" +
        "5009f40d7f0b380c5109e9013dff0dff19fd6efedafe8efe8cfca0fe98014002c9039f05" +
        "30059201d8abbe3d50080001006b6cb5a5"

    func testV26SecondChannelDecodes() {
        let p = parseFrame(bytes(v26HexChannel46), family: .whoop5).parsed
        XCTAssertEqual(p["hist_version"]?.intValue, 26)
        XCTAssertEqual(p["unix"]?.intValue, 1780918392)
        XCTAssertEqual(p["ppg_channel"]?.intValue, 2)          // next channel in the 1…26 sweep (first frame read 1)
        XCTAssertEqual(p["ppg_sample_count"]?.intValue, 24)
        // Still a smooth pulsatile trace (guards the [27:75] bounds on the other channel too).
        let w = p["ppg_waveform"]!.intArrayValue!
        let range = w.max()! - w.min()!
        let meanStep = zip(w, w.dropFirst()).map { abs($1 - $0) }.reduce(0, +) / (w.count - 1)
        XCTAssertLessThan(meanStep * 4, range)
    }

    func testV26WaveformIsSmoothNotNoise() {
        // A PPG pulse moves smoothly sample-to-sample, so the mean step is a small fraction of the
        // record's range — distinguishing a real decoded waveform from random/garbage bytes, and
        // guarding the [27:75] sample bounds.
        let w = parseFrame(bytes(v26Hex), family: .whoop5).parsed["ppg_waveform"]!.intArrayValue!
        let range = w.max()! - w.min()!
        let meanStep = zip(w, w.dropFirst()).map { abs($1 - $0) }.reduce(0, +) / (w.count - 1)
        XCTAssertLessThan(meanStep * 4, range)
    }
}
