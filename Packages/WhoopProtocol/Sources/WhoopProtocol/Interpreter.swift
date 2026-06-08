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
    // Optical channels (PPG green/red-IR, SpO₂ red/IR, skin-temp, ambient) sit past offset 57 but
    // are not yet ground-truth-mapped; keep them as one honest raw region.
    if let payloadEnd = payloadEnd, 57 < payloadEnd, payloadEnd <= frame.count {
        fb.region(57, payloadEnd, "unmapped optical (PPG/SpO₂/skin-temp)", "unknown")
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

@inline(__always)
private func hexFrameSlice(_ f: [UInt8], _ start: Int, _ end: Int) -> String {
    guard start >= 0, end <= f.count, start < end else { return "" }
    return f[start..<end].map { String(format: "%02x", $0) }.joined()
}

// Post-hook registry (populated in PostHooks.swift by Task B7).
// name -> (FieldBuilder, frame, length, schema) -> Void
typealias PostHook = (FieldBuilder, [UInt8], Int?, Schema) -> Void
var postHooks: [String: PostHook] = [:]
