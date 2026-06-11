import Foundation

/// The HISTORICAL_DATA record frames in `rawFrames` that FAIL decode — a genuine CRC failure, or an
/// unmapped firmware layout whose envelope parsed but yielded no usable biometrics. These are the
/// records the strap is about to free once we ack the trim, so without an archive they are lost
/// forever while the UI reports a clean sync (#77 / #91).
///
/// Console (type-50, `frame[typeIndex] == 0x32`) frames are strap-side debug-log text that decode to
/// zero rows BY DESIGN and are never returned. 5/MG v26 (raw PPG block, hist_version 26) is also
/// skipped: it is known-and-unstored by design, not lost biometric data. Only genuine type-47
/// record frames whose payload would otherwise be silently dropped are returned.
///
/// Used by the Backfiller/BLEManager to archive undecodable history BEFORE acking the trim. Mirrors
/// the Android rejectedHistoricalRecords so one mapping toolchain re-ingests both archives.
public func rejectedHistoricalRecords(_ rawFrames: [[UInt8]], family: DeviceFamily) -> [[UInt8]] {
    // The type byte sits at the inner-record start: frame[4] on WHOOP 4.0, frame[8] on WHOOP 5/MG
    // (the puffin envelope is 4 bytes longer). hist_version sits one byte past the type+seq+cmd
    // header — frame[5] (4.0) / frame[9] (5/MG) — same shift.
    let typeIndex = family == .whoop5 ? 8 : 4
    let versionIndex = family == .whoop5 ? 9 : 5
    return rawFrames.filter { f in
        // Only genuine HISTORICAL_DATA records (47). Console (50) and METADATA frames have a
        // different type byte, so they never pass this gate — they are excluded by construction.
        guard f.count > typeIndex, Int(f[typeIndex]) == 47 else { return false }
        if family == .whoop5, f.count > versionIndex, Int(f[versionIndex]) == 26 { return false }  // v26 PPG: skipped by design
        let p = parseFrame(f, family: family)
        // Envelope/CRC reject: parse failed outright or the CRC32 trailer mismatched.
        if !p.ok || p.crcOK == false { return true }
        // Unmapped layout: the envelope parsed but no usable biometrics decoded — exactly the rows
        // extractHistoricalStreams skips (it requires both `unix` and a non-startup `heart_rate`).
        return p.parsed["unix"]?.intValue == nil || p.parsed["heart_rate"]?.intValue == nil
    }
}

/// Turn historical (offload) parsed frames into datastore rows. Port of
/// interpreter.extract_historical_streams.
///
/// HR/R-R come from REALTIME_RAW_DATA (type 43) headers — the canonical stream
/// during a historical backfill, where type-40 frames are absent.
/// EVENT and COMMAND_RESPONSE handling is identical to extractStreams.
/// CRC-failed and non-ok frames are skipped.
public func extractHistoricalStreams(_ parsed: [ParsedFrame],
                                     deviceClockRef: Int, wallClockRef: Int) -> Streams {
    func wall(_ deviceTs: Int?) -> Int? {
        guard let d = deviceTs else { return nil }
        return wallClockRef + (d - deviceClockRef)
    }
    // FIX #72: type-47 `unix` and EVENT `event_timestamp` are the strap RTC's own real-unix seconds.
    // When the strap RTC is grossly stale (it sat unused for months, so its clock is months behind),
    // those land far in the past — live HR works but all offloaded history is misdated. Correct them by
    // the (wall - device) clock offset, but ONLY when the strap is grossly stale, and SNAPPED to a 5-min
    // grid so the same record re-syncs to the SAME corrected ts (offloaded rows dedupe by (deviceId, ts);
    // an un-snapped, slightly-different offset on re-sync would duplicate every row). For a normal or
    // identity clockRef the offset is ~0 (< threshold) → rawTs is returned unchanged (current behavior).
    let staleThreshold = 86_400          // 1 day
    let snapGranularity = 300            // 5 min
    let clockOffset = wallClockRef - deviceClockRef
    func correctedWall(_ rawTs: Int) -> Int {
        guard abs(clockOffset) > staleThreshold else { return rawTs }
        // sign-aware round-half-up snap to the nearest `snapGranularity`
        let snapped = (clockOffset >= 0
            ? (clockOffset + snapGranularity / 2)
            : (clockOffset - snapGranularity / 2)) / snapGranularity * snapGranularity
        return rawTs + snapped
    }
    var out = Streams()
    for r in parsed {
        if !r.ok || r.crcOK == false { continue }
        let p = r.parsed
        switch r.typeName {
        case "HISTORICAL_DATA":
            // type-47 carries the strap RTC's real-unix seconds. Correct for a grossly-stale RTC
            // (FIX #72); a normal strap is unchanged (offset < threshold).
            guard let rawTs = p["unix"]?.intValue else { continue }
            let ts = correctedWall(rawTs)
            if let bpm = p["heart_rate"]?.intValue, bpm != 0 {  // skip startup hr=0
                out.hr.append(HRSample(ts: ts, bpm: bpm))
            }
            if let rrs = p["rr_intervals"]?.intArrayValue {
                for rr in rrs { out.rr.append(RRInterval(ts: ts, rrMs: rr)) }
            }
            if let red = p["spo2_red"]?.intValue {
                out.spo2.append(SpO2Sample(ts: ts, red: red, ir: p["spo2_ir"]?.intValue ?? 0))
            }
            if let raw = p["skin_temp_raw"]?.intValue {
                out.skinTemp.append(SkinTempSample(ts: ts, raw: raw))
            }
            // step_motion_counter@57 is the WHOOP5 cumulative u16 counter — decoded but, until now,
            // dropped on macOS (Android persists it). APPROXIMATE; semantics unverified vs the app (#78).
            if let c = p["step_motion_counter"]?.intValue {
                out.steps.append(StepSample(ts: ts, counter: c))
            }
            if let raw = p["resp_rate_raw"]?.intValue {
                out.resp.append(RespSample(ts: ts, raw: raw))
            }
            if let gx = p["gravity_x"]?.doubleValue {
                out.gravity.append(GravitySample(ts: ts, x: gx,
                    y: p["gravity_y"]?.doubleValue ?? 0, z: p["gravity_z"]?.doubleValue ?? 0))
            }
        case "REALTIME_RAW_DATA":
            let ts = wall(p["timestamp"]?.intValue)
            if let ts = ts, let bpm = p["heart_rate"]?.intValue {
                out.hr.append(HRSample(ts: ts, bpm: bpm))
            }
            if let ts = ts, let rrs = p["rr_intervals"]?.intArrayValue {
                for rr in rrs { out.rr.append(RRInterval(ts: ts, rrMs: rr)) }
            }
        case "EVENT":
            // EVENT carries the strap RTC's real-unix seconds. Correct for a grossly-stale RTC
            // (FIX #72); a normal strap is unchanged (offset < threshold).
            guard let rawTs = p["event_timestamp"]?.intValue else { continue }
            let ts = correctedWall(rawTs)
            let kind = p["event"]?.stringValue ?? ""
            if kind.hasPrefix("BATTERY_LEVEL") { appendBattery(&out, ts: ts, p: p) }  // "BATTERY_LEVEL(3)"
            var payload = p
            payload.removeValue(forKey: "event")
            payload.removeValue(forKey: "event_timestamp")
            out.events.append(WhoopEvent(ts: ts, kind: kind, payload: payload))
        case "COMMAND_RESPONSE":
            // No device timestamp on COMMAND_RESPONSE → stamp battery at wallClockRef.
            appendBattery(&out, ts: wallClockRef, p: p)
        default:
            continue
        }
    }
    return out
}
