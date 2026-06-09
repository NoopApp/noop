import Foundation

public struct DecodedField: Codable, Equatable {
    public let off: Int
    public let len: Int
    public let name: String
    public let cat: String
    public let value: ParsedValue?
    public let raw: String
    public let note: String?
}

public struct ParsedFrame: Codable, Equatable {
    public let ok: Bool
    public let typeName: String
    public let seq: Int?
    public let cmdName: String?
    public let crcOK: Bool?
    public let lenBytes: Int
    public let rawHex: String
    public let fields: [DecodedField]
    public let parsed: [String: ParsedValue]
}

// MARK: - low-level readers (LE), nil when out of range (mirrors interpreter._read)

@inline(__always) private func readU8(_ f: [UInt8], _ off: Int) -> Int? {
    off + 1 <= f.count ? Int(f[off]) : nil
}
@inline(__always) private func readU16(_ f: [UInt8], _ off: Int) -> Int? {
    off + 2 <= f.count ? Int(f[off]) | (Int(f[off + 1]) << 8) : nil
}
@inline(__always) private func readU32(_ f: [UInt8], _ off: Int) -> Int? {
    guard off + 4 <= f.count else { return nil }
    return Int(f[off]) | (Int(f[off + 1]) << 8) | (Int(f[off + 2]) << 16) | (Int(f[off + 3]) << 24)
}
@inline(__always) private func readI16(_ f: [UInt8], _ off: Int) -> Int? {
    guard off + 2 <= f.count else { return nil }
    let raw = UInt16(f[off]) | (UInt16(f[off + 1]) << 8)
    return Int(Int16(bitPattern: raw))
}

@inline(__always) private func readF32(_ f: [UInt8], _ off: Int) -> Double? {
    guard off + 4 <= f.count else { return nil }
    let bits = UInt32(f[off]) | (UInt32(f[off + 1]) << 8) | (UInt32(f[off + 2]) << 16) | (UInt32(f[off + 3]) << 24)
    return Double(Float(bitPattern: bits))   // float32 -> Double is exact, no rounding
}

/// Read a schema dtype at off; returns the integer value or nil if out of range.
private func readDType(_ f: [UInt8], _ off: Int, _ dtype: String) -> Int? {
    switch dtype {
    case "u8": return readU8(f, off)
    case "u16": return readU16(f, off)
    case "u32": return readU32(f, off)
    case "i16": return readI16(f, off)
    default: return nil
    }
}

private func hexString(_ bytes: ArraySlice<UInt8>) -> String {
    bytes.map { String(format: "%02x", $0) }.joined()
}

/// Field builder: accumulates annotated fields and a flat parsed dict. Port of Python FB.
final class FieldBuilder {
    let frame: [UInt8]
    var fields: [DecodedField] = []
    var parsed: [String: ParsedValue] = [:]

    init(_ frame: [UInt8]) {
        self.frame = frame
    }

    @discardableResult
    func add(_ off: Int, _ length: Int, _ name: String, _ cat: String,
             value: ParsedValue? = nil, note: String? = nil) -> FieldBuilder {
        let end = min(off + length, frame.count)
        let raw = off <= frame.count ? hexString(frame[max(0, off)..<max(off, end)]) : ""
        fields.append(DecodedField(off: off, len: length, name: name, cat: cat,
                                   value: value, raw: raw, note: note))
        if value != nil && cat != "frame" && cat != "unknown" {
            parsed[name] = value
        }
        return self
    }

    func region(_ start: Int, _ end: Int, _ name: String, _ cat: String, note: String? = nil) {
        if start < end && end <= frame.count {
            add(start, end - start, name, cat, value: .string("[\(end - start) bytes]"), note: note)
        }
    }
}

public func parseFrame(_ frame: [UInt8]) -> ParsedFrame {
    let rawHex = frame.map { String(format: "%02x", $0) }.joined()
    if frame.count < 8 || frame[0] != 0xAA {
        return ParsedFrame(ok: false, typeName: "INVALID/FRAGMENT", seq: nil, cmdName: nil,
                           crcOK: nil, lenBytes: frame.count, rawHex: rawHex,
                           fields: [], parsed: [:])
    }

    let schema = loadSchema()
    let check = verifyFrame(frame)
    let length = check.length
    let crcOK = check.crc32OK

    let t = Int(frame[4])
    let typeName = schema.typeName(t)
    let seq = Int(frame[5])

    let fb = FieldBuilder(frame)
    // envelope
    fb.add(0, 1, "SOF", "frame", value: .string("0xAA"))
    fb.add(1, 2, "length", "frame", value: length.map { .int($0) })
    fb.add(3, 1, "crc8", "frame", value: .string(String(format: "0x%02X", frame[3])))
    fb.add(4, 1, "packet_type", "frame", value: .string(typeName))
    fb.add(5, 1, "seq", "frame", value: .int(Int(frame[5])))

    let spec = schema.packet(forType: t)
    if spec == nil {
        fb.add(6, 1, "cmd", "cmd", value: frame.count > 6 ? .int(Int(frame[6])) : nil)
        if let length = length { fb.region(7, length, "payload", "unknown") }
    } else {
        // static fields from schema
        for fld in spec!.fields {
            guard let dtype = fld.dtype else { continue }
            guard let val = readDType(frame, fld.off, dtype) else { continue }
            let value: ParsedValue
            if let enumKey = fld.`enum` {
                value = .string(schema.enumName(enumKey, val))
            } else {
                value = .int(val)
            }
            fb.add(fld.off, fld.len, fld.name, fld.cat, value: value, note: fld.note)
        }
        // per-type post-hook for irregular fields (populated in PostHooks.swift by B7)
        if let postName = spec!.post, let hook = postHooks[postName] {
            hook(fb, frame, length, schema)
        }
    }

    // crc32 trailer field
    if let length = length, length + 4 <= frame.count {
        let crcVal = UInt32(frame[length]) | (UInt32(frame[length + 1]) << 8)
            | (UInt32(frame[length + 2]) << 16) | (UInt32(frame[length + 3]) << 24)
        fb.add(length, 4, "crc32", "frame", value: .string(String(format: "0x%08X", crcVal)),
               note: check.crc32OK == true ? "OK" : "MISMATCH")
    }

    let cmdByte = frame.count > 6 ? Int(frame[6]) : 0
    let cmdName = (t == 35 || t == 36) ? schema.enumName("CommandNumber", cmdByte) : nil

    return ParsedFrame(ok: true, typeName: typeName, seq: seq, cmdName: cmdName,
                       crcOK: crcOK, lenBytes: frame.count, rawHex: rawHex,
                       fields: fb.fields, parsed: fb.parsed)
}

/// Family-aware frame parsing.
///
/// `whoop4` behaves EXACTLY like the no-family `parseFrame(_:)` above (back-compat). `whoop5`
/// parses the Whoop 5.0 envelope (see `verifyFrame(_:family:)` for the layout): the SOF/length/
/// header-CRC live in the first 8 bytes, the inner `[type][seq][cmd][data…]` starts at offset 8,
/// and the 4-byte CRC32 trailer closes the frame. "Puffin" types 38/56 are aliased onto their base
/// names (COMMAND_RESPONSE / METADATA) via `canonicalTypeName`.
public func parseFrame(_ frame: [UInt8], family: DeviceFamily) -> ParsedFrame {
    switch family {
    case .whoop4:
        return parseFrame(frame)
    case .whoop5:
        return parseFrameWhoop5(frame)
    }
}

private func parseFrameWhoop5(_ frame: [UInt8]) -> ParsedFrame {
    let rawHex = frame.map { String(format: "%02x", $0) }.joined()
    // Minimum whoop5 frame: 8 header bytes + 1 inner (type) + 4 CRC32 trailer.
    if frame.count < 12 || frame[0] != 0xAA {
        return ParsedFrame(ok: false, typeName: "INVALID/FRAGMENT", seq: nil, cmdName: nil,
                           crcOK: nil, lenBytes: frame.count, rawHex: rawHex,
                           fields: [], parsed: [:])
    }

    let schema = loadSchema()
    let check = verifyFrame(frame, family: .whoop5)
    let declaredLength = check.length            // payload + 4 (CRC32)
    let crcOK = check.crc32OK

    // Inner record starts at offset 8: [type][seq][cmd][data…].
    let innerStart = 8
    let t = Int(frame[innerStart])
    let typeName = canonicalTypeName(t, schema: schema)
    let seq = frame.count > innerStart + 1 ? Int(frame[innerStart + 1]) : nil

    let fb = FieldBuilder(frame)
    // envelope
    fb.add(0, 1, "SOF", "frame", value: .string("0xAA"))
    fb.add(1, 1, "format", "frame", value: .int(Int(frame[1])))
    fb.add(2, 2, "length", "frame", value: declaredLength.map { .int($0) })
    fb.add(4, 2, "header", "frame", value: .string(hexFrameSlice(frame, 4, 6)))
    let hdrCRC = UInt16(frame[6]) | (UInt16(frame[7]) << 8)
    fb.add(6, 2, "crc16", "frame", value: .string(String(format: "0x%04X", hdrCRC)),
           note: check.crc8OK == true ? "OK" : "MISMATCH")
    fb.add(innerStart, 1, "packet_type", "frame", value: .string(typeName))
    if let seq = seq { fb.add(innerStart + 1, 1, "seq", "frame", value: .int(seq)) }

    // WHOOP 5.0 field offsets are the WHOOP 4.0 layout shifted by +4: the inner record starts at
    // byte 8 here vs byte 4 on 4.0, so every field sits at its 4.0 offset + `delta`. Verified on real
    // hardware for REALTIME_DATA (type 40) — HR, R-R and the unix timestamp land exactly at +4 (HR
    // matched the standard 2A37 profile to ~0.4 bpm). We reuse the 4.0 schema with that shift.
    let cmdByte = frame.count > innerStart + 2 ? Int(frame[innerStart + 2]) : 0
    let delta = innerStart - 4                       // = 4
    let payloadEnd = declaredLength.map { ($0 + 8) - 4 }   // start of CRC32 trailer
    let spec = schema.packet(forType: t)
    if spec == nil {
        fb.add(innerStart + 2, 1, "cmd", "cmd",
               value: frame.count > innerStart + 2 ? .int(cmdByte) : nil)
        if let payloadEnd = payloadEnd, innerStart + 3 < payloadEnd, payloadEnd <= frame.count {
            fb.region(innerStart + 3, payloadEnd, "payload", "unknown")
        }
    } else {
        // Static schema fields at the 4.0 offset + delta.
        for fld in spec!.fields {
            guard let dtype = fld.dtype, let val = readDType(frame, fld.off + delta, dtype) else { continue }
            let value: ParsedValue = fld.`enum`.map { .string(schema.enumName($0, val)) } ?? .int(val)
            fb.add(fld.off + delta, fld.len, fld.name, fld.cat, value: value, note: fld.note)
        }
        if spec!.post == "realtime_data" {
            // Verified variable-length extension: REALTIME_DATA R-R intervals (rr_count @13+delta,
            // intervals @14+delta…), the same shape as 4.0 shifted by +4.
            let rrn = readDType(frame, 13 + delta, "u8") ?? 0
            var rrs: [Int] = []
            for i in 0..<rrn {
                let off = 14 + delta + i * 2
                if let v = readDType(frame, off, "u16"), v > 0 {
                    fb.add(off, 2, "rr[\(i)]", "rr", value: .int(v), note: "ms")
                    rrs.append(v)
                }
            }
            fb.parsed["rr_intervals"] = .intArray(rrs)
        } else if spec!.post == "historical_data" {
            decodeWhoop5Historical(frame, fb: fb, payloadEnd: payloadEnd)
        } else if spec!.post == "metadata" {
            decodeWhoop5Metadata(frame, fb: fb)
        } else if spec!.post == "command_response" {
            decodeWhoop5CommandResponse(frame, fb: fb, schema: schema, payloadEnd: payloadEnd)
        } else if spec!.post == "event" {
            decodeWhoop5Event(frame, fb: fb, schema: schema)
        } else if let payloadEnd = payloadEnd, innerStart + 3 < payloadEnd, payloadEnd <= frame.count {
            // Other types: static fields decoded above; the remaining variable body is kept raw —
            // its 4.0 post-hook awaits per-type 5.0 hardware verification before we apply it at +4.
            fb.region(innerStart + 3, payloadEnd, "payload", "unknown")
        }
    }

    // crc32 trailer field
    if let payloadEnd = payloadEnd, payloadEnd + 4 <= frame.count {
        let crcVal = UInt32(frame[payloadEnd]) | (UInt32(frame[payloadEnd + 1]) << 8)
            | (UInt32(frame[payloadEnd + 2]) << 16) | (UInt32(frame[payloadEnd + 3]) << 24)
        fb.add(payloadEnd, 4, "crc32", "frame",
               value: .string(String(format: "0x%08X", crcVal)),
               note: check.crc32OK == true ? "OK" : "MISMATCH")
    }

    let cmdName = (t == 35 || t == 36 || t == PuffinPacketType.puffinCommandResponse)
        ? schema.enumName("CommandNumber", cmdByte) : nil

    return ParsedFrame(ok: true, typeName: typeName, seq: seq, cmdName: cmdName,
                       crcOK: crcOK, lenBytes: frame.count, rawHex: rawHex,
                       fields: fb.fields, parsed: fb.parsed)
}

/// Decode a WHOOP 5.0 HISTORICAL_DATA (type 47) DSP biometric record.
///
/// The layout version is carried in the byte at frame[9] — the inner record's seq slot, which the
/// historical packet reuses for its layout version exactly as WHOOP 4.0 does (version at frame[5],
/// +4 here). Real WHOOP 5 hardware on the latest firmware emits **version 18**, captured 2026-06-08
/// and unlocked via the HISTORICAL_DATA_RESULT chunk-ack handshake (see docs §5).
///
/// v18 is NOT the repo's 4.0 v24 layout shifted by +4 — that firmware revision is not what this
/// device emits, and a naive +4 decodes to garbage (HR 0, gravity overflow). Every offset below is
/// read directly off real frames at its absolute 5.0 position and cross-checked physiologically:
///   • unix monotonic at +1 s,  • rr_count matches the number of valid R-R intervals (100%),
///   • 60000/mean(R-R) ≈ heart_rate (88%, the rest being HR-averaging cases),  • |gravity| ≈ 1 g
///     (100% of 500 records).
/// PPG / SpO₂ / skin-temp live further in the 124-byte record but lack on-device ground truth, so
/// they are left as a raw region rather than guessed (project rule: real captures, never invented
/// offsets).
private func decodeWhoop5Historical(_ frame: [UInt8], fb: FieldBuilder, payloadEnd: Int?) {
    let version = frame.count > 9 ? Int(frame[9]) : -1
    fb.parsed["hist_version"] = .int(version)
    fb.add(9, 1, "hist_version", "meta", value: .int(version))
    if version == 26 {
        decodeWhoop5HistoricalV26(frame, fb: fb)
        return
    }
    guard version == 18 else {
        // Unknown historical layout — describe it faithfully without inventing offsets.
        if let payloadEnd = payloadEnd, 11 < payloadEnd, payloadEnd <= frame.count {
            fb.region(11, payloadEnd, "HISTORICAL_DATA v\(version) (unmapped layout)", "unknown")
        }
        return
    }
    if let unix = readDType(frame, 15, "u32") {
        fb.add(15, 4, "unix", "time", value: .int(unix), note: "real unix seconds")
    }
    if let hr = readDType(frame, 22, "u8") {
        fb.add(22, 1, "heart_rate", "hr", value: .int(hr), note: "bpm")
    }
    let rrn = readDType(frame, 23, "u8") ?? 0
    fb.add(23, 1, "rr_count", "rr", value: .int(rrn))
    var rrs: [Int] = []
    for i in 0..<min(rrn, 4) {
        let off = 24 + i * 2
        if let v = readDType(frame, off, "u16"), v > 0 {
            fb.add(off, 2, "rr[\(i)]", "rr", value: .int(v), note: "ms")
            rrs.append(v)
        }
    }
    fb.parsed["rr_intervals"] = .intArray(rrs)
    for (name, off) in [("gravity_x", 45), ("gravity_y", 49), ("gravity_z", 53)] {
        if let d = readF32(frame, off) {
            fb.add(off, 4, name, "accel", value: .double(d), note: "g")
        }
    }
    // Per-second biometric fields beyond HR/gravity. Each is gated to a physically-real range and was
    // cross-validated against real v18 frames (worn vs off-wrist), so a wrong offset on an unmapped
    // firmware revision stores nothing rather than garbage (the data is the arbiter). Fields the report
    // listed but that did NOT decode consistently on this device's firmware (cardiac_flags@33,
    // state_bitfield@81, perfusion@69/71) are deliberately left in the raw region pending more captures.
    if let d = readF32(frame, 41), d.isFinite, (0...8).contains(d) {
        fb.add(41, 4, "dynamic_acceleration", "accel", value: .double(d), note: "g, gravity-removed magnitude")
    }
    if let raw = readDType(frame, 57, "u16") {
        // Cumulative motion/step counter — monotonic across a stream (validated downstream), no midnight
        // reset. Single-frame value is unbounded so it carries no physical gate here.
        fb.add(57, 2, "step_motion_counter", "activity", value: .int(raw), note: "cumulative motion counter")
    }
    if let wear = readDType(frame, 63, "u8"), (0...2).contains(wear) {
        fb.add(63, 1, "motion_wear_quality", "quality", value: .int(wear), note: "0=still/good, 1, 2=poor contact")
    }
    if let raw = readDType(frame, 73, "u16") {
        let celsius = Double(raw) / 100.0
        if (20...45).contains(celsius) {
            fb.add(73, 2, "skin_temperature", "temp", value: .double(celsius),
                   note: "°C, raw thermistor (AS6221); off-wrist reads ambient, not the cloud's calibrated summary")
        }
    }
    // The remaining bytes (perfusion, cardiac block, AFE mode register, sleep FSM) are not yet
    // ground-truth-mapped on this firmware; keep them as one honest raw region.
    if let payloadEnd = payloadEnd, 75 < payloadEnd, payloadEnd <= frame.count {
        fb.region(75, payloadEnd, "unmapped (perfusion/cardiac/AFE-mode/sleep-state)", "unknown")
    }
}

/// Decode a WHOOP 5.0 type-47 **version-26** record — the high-rate optical PPG buffer.
///
/// Unlike the v18 per-second summary, v26 is a 24 Hz waveform: **24 little-endian i16 samples at bytes
/// [27:75]**, one record per second (`unix` u32 LE @15, the same slot v18 uses). It was verified to be
/// an OPTICAL PPG trace — not IMU/motion — using the heart rate as *internal* ground truth (no external
/// reference): the concatenated waveform's autocorrelation peaks at the HR (lag 14 = 102.9 bpm vs a
/// measured 101.7 bpm), trough-detection gives a 563 ms inter-beat interval (≈106 bpm), the pulse stays
/// HR-locked even when the wrist is still, and its amplitude is not motion-driven. (Reproduce with
/// `tools/linux-capture/analyze_v26_waveform.py`; see docs §5.)
///
/// The samples are raw AC-coupled ADC counts — PPG has no absolute unit — so they are exposed verbatim
/// as `ppg_waveform` with NO invented scale. The bytes before [27] (header + a block index) and the
/// footer after [75] are not mapped; SpO₂/skin-temp have no internal proxy and are left untouched.
private func decodeWhoop5HistoricalV26(_ frame: [UInt8], fb: FieldBuilder) {
    // Optical channel index @21: the strap time-multiplexes 26 optical channels, sweeping 1→26 in
    // ~40-frame blocks (one channel per block, revisited ~20 min later). Verified against a 22 h overnight
    // corpus — frame[21] takes exactly 26 distinct values (1–26), and on our own two real fixtures reads
    // 1 then 2. An earlier read at frame[12] (the 0x41/0x46 "two channels") was a high-entropy counter byte
    // mistaken for the channel during a short 2-burst capture. Gate to 1…26 so a wrong offset stores nothing.
    if let ch = readDType(frame, 21, "u8"), (1...26).contains(ch) {
        fb.add(21, 1, "ppg_channel", "ppg", value: .int(ch),
               note: "time-multiplexed optical channel 1–26 (40-frame blocks)")
    }
    if let unix = readDType(frame, 15, "u32") {
        fb.add(15, 4, "unix", "time", value: .int(unix), note: "real unix seconds")
    }
    var samples: [Int] = []
    for off in stride(from: 27, to: 75, by: 2) {
        guard let v = readI16(frame, off) else { break }
        samples.append(v)
    }
    if !samples.isEmpty {
        fb.add(27, samples.count * 2, "ppg_waveform", "ppg", value: .intArray(samples),
               note: "optical PPG @24 Hz, LE-i16 ADC counts")
        fb.parsed["ppg_sample_count"] = .int(samples.count)
    }
}

/// Decode WHOOP 5.0 METADATA (type 49) chunk fields so the historical-offload state machine can act
/// on them. `meta_type` is already added by the static-schema walk (4.0 @6 → 5.0 @10); a HISTORY_END
/// additionally carries the chunk's `unix` and `trim_cursor`, which `classifyHistoricalMeta` needs to
/// drive the `HISTORICAL_DATA_RESULT` ack. Offsets are the 4.0 metadata post-hook positions + 4,
/// verified on real WHOOP 5 HISTORY_END frames (trim decodes consistently across a whole capture).
/// `end_data` to echo back in the ack is `frame[21..29]` (trim u32 + next u32).
private func decodeWhoop5Metadata(_ frame: [UInt8], fb: FieldBuilder) {
    if let unix = readDType(frame, 11, "u32") { fb.add(11, 4, "unix", "time", value: .int(unix)) }
    if let ss = readDType(frame, 15, "u16") { fb.add(15, 2, "subsec", "time", value: .int(ss)) }
    if let trim = readDType(frame, 21, "u32") {
        fb.add(21, 4, "trim_cursor", "meta", value: .int(trim), note: "ack with this to advance")
    }
}

/// Build the WHOOP 5.0 historical-offload ack (`HISTORICAL_DATA_RESULT`, cmd 23) for one HISTORY_END
/// chunk. `endData` is the chunk's verbatim 8-byte trim block (`frame[21..29]`); the payload is
/// `[0x01] + endData`, framed as a puffin COMMAND. This is the WHOOP 5 image of `ackHistoricalChunk`
/// in `BLEManager`, and the byte-for-byte twin of the Python `build_history_ack` proven on hardware.
public func whoop5HistoricalAckFrame(endData: [UInt8], seq: UInt8) -> [UInt8] {
    puffinCommandFrame(cmd: 23, seq: seq, payload: [0x01] + endData)
}

/// Decode a WHOOP 5.0 COMMAND_RESPONSE (type 36) — battery %, history data-range, firmware version.
///
/// The response command is at frame[10] (the 4.0 frame[6] + 4) and its payload at frame[11]. WHOOP 5
/// reuses the 4.0 command NUMBERS, but the response PAYLOADS differ from 4.0 — so each field below is
/// mapped from a real WHOOP 5 capture (firmware 50.38.1.0), not ported on faith. Commands that return
/// a short stub on this firmware (REPORT_VERSION_INFO / GET_EXTENDED_BATTERY_INFO) or aren't served
/// (GET_CLOCK — unneeded, since realtime + historical carry real unix) are intentionally left undecoded.
private func decodeWhoop5CommandResponse(_ frame: [UInt8], fb: FieldBuilder, schema: Schema, payloadEnd: Int?) {
    guard let payloadEnd = payloadEnd, 11 < payloadEnd, payloadEnd <= frame.count else { return }
    let respCmd = Int(frame[10])
    let name = schema.enumName("CommandNumber", respCmd)   // e.g. "GET_BATTERY_LEVEL(26)"
    let pay = Array(frame[11..<payloadEnd])
    fb.region(11, payloadEnd, "response payload", "cmd")
    if name.hasPrefix("GET_BATTERY_LEVEL"), pay.count >= 3 {
        // Direct percent at pay[2] (47% confirmed against the app) — the 4.0 deci-percent ÷10 is gone.
        fb.add(11 + 2, 1, "battery_pct", "battery", value: .double(Double(pay[2])), note: "%")
    } else if name.hasPrefix("GET_DATA_RANGE"), pay.count >= 7 {
        // The long response carries record cursors + real-unix timestamps as 4-byte-aligned u32s from
        // pay[3]; the history window is their min/max. (A short ack response also exists — no
        // timestamps — so this no-ops on it.)
        var oldest = UInt32.max, newest: UInt32 = 0
        var o = 3
        while o + 4 <= pay.count {
            let v = UInt32(pay[o]) | (UInt32(pay[o + 1]) << 8) | (UInt32(pay[o + 2]) << 16) | (UInt32(pay[o + 3]) << 24)
            if v >= 1_600_000_000 && v <= 1_800_000_000 { oldest = min(oldest, v); newest = max(newest, v) }
            o += 4
        }
        if newest > 0 {
            fb.parsed["history_oldest"] = .int(Int(oldest))
            fb.parsed["history_newest"] = .int(Int(newest))
        }
    } else if respCmd == 145, pay.count >= 26 {
        // GET_HELLO info block. We surface the two user-facing fields the app shows — the device NAME
        // (the model-style label the strap calls itself) and the firmware VERSION — and deliberately never
        // read the session token (also in this response). Both offsets are anchored to a real
        // 50.38.1.0 capture: the name is printable ASCII at pay[16]; the version is 4 bytes at pay[93],
        // after the (fixed-width on this firmware) name+token region. Re-verify the version offset
        // across firmwares; the guards (printable name / pay[93]==50 "5.0" generation) fail closed.
        var nameBytes: [UInt8] = []
        var i = 16
        while i < pay.count, pay[i] != 0, (32...126).contains(pay[i]), nameBytes.count < 24 {
            nameBytes.append(pay[i]); i += 1
        }
        if nameBytes.count >= 6 {
            fb.parsed["device_name"] = .string(String(decoding: nameBytes, as: UTF8.self))
        }
        if pay.count >= 97, pay[93] == 50 {
            fb.parsed["fw_version"] = .string("\(pay[93]).\(pay[94]).\(pay[95]).\(pay[96])")
        }
    }
}

/// Decode a WHOOP 5.0 EVENT (type 48) per-event payload.
///
/// `event` (u8 @10, EventNumber) and `event_timestamp` (u32 @12, real unix) are already set by the
/// static +4 walk. This hook adds the BATTERY_LEVEL payload, which follows the same +4 rule as the
/// rest of the 5.0 layout: 4.0's soc@17 / mv@21 / charge@26 become soc@21 / mv@25 / charge@30. Unlike
/// the 5.0 COMMAND_RESPONSE (which switched to a DIRECT percent), the EVENT battery keeps 4.0's
/// deci-percent (÷10) — confirmed by a clean monotonic discharge across a real capture (49.9 → 47.7 %).
/// The same range guards as the 4.0 `event` post-hook fail closed.
///
/// Event NAMES come only from the shared `EventNumber` schema, so an unnamed number the firmware emits
/// (e.g. 123) stays the raw `0x7B(123)` set by the static walk and gets no payload here — never a name
/// borrowed from another enum (`CommandNumber` 123 is `SELECT_WRIST`) or invented. Other events'
/// payloads (EXTENDED_BATTERY_INFORMATION, STRAP_CONDITION_REPORT) lack on-device 5.0 ground truth and
/// are intentionally left raw rather than ported from 4.0 on faith.
private func decodeWhoop5Event(_ frame: [UInt8], fb: FieldBuilder, schema: Schema) {
    guard let evVal = readDType(frame, 10, "u8") else { return }
    guard schema.enums["EventNumber"]?[String(evVal)] == "BATTERY_LEVEL" else { return }
    if let raw = readDType(frame, 21, "u16"), raw <= 1100 {
        fb.add(21, 2, "battery_pct", "battery", value: .double(Double(raw) / 10), note: "%")
    }
    if let mv = readDType(frame, 25, "u16"), (3000...4300).contains(mv) {
        fb.add(25, 2, "battery_mV", "battery", value: .int(mv), note: "mV")
    }
    if let ch = readDType(frame, 30, "u8"), ch <= 1 {
        fb.add(30, 1, "battery_charging", "battery", value: .int(ch & 1))
    }
}

@inline(__always)
private func hexFrameSlice(_ f: [UInt8], _ start: Int, _ end: Int) -> String {
    guard start >= 0, end <= f.count, start < end else { return "" }
    return f[start..<end].map { String(format: "%02x", $0) }.joined()
}

// Post-hook registry (populated in PostHooks.swift by Task B7).
// name -> (FieldBuilder, frame, length, schema) -> Void
typealias PostHook = (FieldBuilder, [UInt8], Int?, Schema) -> Void
var postHooks: [String: PostHook] = [:]
