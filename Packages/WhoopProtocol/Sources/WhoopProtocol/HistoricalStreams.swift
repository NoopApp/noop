import Foundation

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
