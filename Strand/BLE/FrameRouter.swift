import Foundation
import WhoopProtocol

/// Pure decode→state router. Takes a COMPLETE (already reassembled) frame, decodes it with
/// WhoopProtocol.parseFrame, and updates LiveState. No CoreBluetooth — fully unit-testable.
@MainActor
public final class FrameRouter {
    private let state: LiveState
    /// Called when the strap pushes an EVENT packet (WHOOP's strap-as-clock catch-up signal). The
    /// BLEManager wires this to a rate-limited requestSync(.strap). nil in pure/unit contexts.
    var onSyncTrigger: (() -> Void)?
    /// Which family's framing to decode with. Set per connection by BLEManager. WHOOP 5.0/MG frames
    /// use the CRC16/offset-8 envelope; the biometric field decode for puffin is still a stub, so
    /// WHOOP 5 custom frames currently surface only their envelope (live HR/battery come from the
    /// standard 0x2A37/0x2A19 profiles instead).
    var family: DeviceFamily = .whoop4

    public init(state: LiveState) {
        self.state = state
    }

    /// Handle one complete frame (bytes including 0xAA SOF and the crc32 trailer).
    public func handle(frame: [UInt8]) {
        let parsed = parseFrame(frame, family: family)
        guard parsed.ok else { return }
        // Reject frames that failed their checksum — never let bad bytes drive state.
        if parsed.crcOK == false { return }

        state.lastFrameType = parsed.typeName

        switch parsed.typeName {
        case "REALTIME_DATA", "REALTIME_RAW_DATA":
            // Reject 0 / out-of-range spikes from realtime streams; AppModel medians the rest.
            // Some firmware exposes live BPM only on the R10/R11 raw stream after acknowledging
            // BLE_REALTIME_HR_ON, so the UI can consume it even though persistence still ignores raw43.
            if let hr = parsed.parsed["heart_rate"]?.intValue, hr >= 30, hr <= 220 {
                state.heartRate = hr
            }
            // The realtime stream usually reports rr_count=0; only update R-R when this frame
            // actually carries intervals, so we don't wipe R-R sourced from the 0x2A37 profile.
            if let rr = parsed.parsed["rr_intervals"]?.intArrayValue, !rr.isEmpty {
                state.rr = rr
            }

        case "COMMAND_RESPONSE":
            if let pct = parsed.parsed["battery_pct"]?.doubleValue {
                state.setBattery(pct)
            }

        case "EVENT":
            if let ev = parsed.parsed["event"]?.stringValue {
                // #92: don't surface the live-HR stream toggle (BLE_REALTIME_HR_ON/OFF) in "Last
                // Event" — it's internal plumbing that fires on every connect and just confuses
                // users. Every other event (wrist, double-tap, battery, bonded…) still shows.
                if !ev.hasPrefix("BLE_REALTIME_HR") {
                    state.lastEvent = ev
                }
                // Strap-pushed event = "I may have new data" → kick a (rate-limited) sync.
                onSyncTrigger?()
                // Belt-and-suspenders: a BLE_BONDED event confirms the link is bonded.
                // (BLEManager also sets bonded=true when the confirmed write succeeds.)
                if ev.hasPrefix("BLE_BONDED") {
                    state.bonded = true
                }
                // BATTERY_LEVEL events carry the only charging flag the strap reports (wire
                // observation: u8 bit0, ~every 8 min on captured links). Flag only — battery %
                // keeps its family-specific source (#77). No freshness gate needed here: this
                // path never sees historical replay (backfill skips handle(frame:), see below).
                if ev.hasPrefix("BATTERY_LEVEL"),
                   let ch = parsed.parsed["battery_charging"]?.intValue {
                    state.charging = (ch != 0)
                }
                // Physical inputs the strap exposes — live only (this path never sees historical
                // replay, which goes through the Backfiller). Event strings are "NAME(rawValue)".
                if ev.hasPrefix("DOUBLE_TAP") {
                    state.onDoubleTap?()
                } else if ev.hasPrefix("WRIST_ON") {
                    if !state.worn { state.worn = true; state.onWristChange?(true) }
                } else if ev.hasPrefix("WRIST_OFF") {
                    if state.worn { state.worn = false; state.onWristChange?(false) }
                }
            }

        default:
            break
        }
    }

    /// Live-gesture freshness window (s). A DOUBLE_TAP / WRIST_ON / WRIST_OFF fires its live handler only
    /// if its event_timestamp is within this of `now` — so a *replayed historical* gesture during a
    /// backfill offload (old ts) is ignored, but a real-time one fires even mid-sync.
    static let liveGestureWindowSeconds = 45

    /// Parse an EVENT frame and fire ONLY the live physical-gesture handlers (double-tap / wrist) iff the
    /// event is recent. Called for offload frames during backfill — where `handle(frame:)` is skipped —
    /// so a real-time gesture still works mid-offload (#69: the 5/MG offload runs for minutes). `now`
    /// MUST be in the SAME clock domain as event_timestamp (the strap's RTC): the caller passes the
    /// strap's own clock-now (BLEManager.strapClockNow), so the gate is robust to a grossly-stale strap
    /// RTC (fix #72) — a live gesture is ~now in the strap's clock, a historical replay is old in it.
    /// Deliberately does NOT touch lastEvent / sync trigger / bonded / battery — those stay on the normal
    /// handle(frame:) path, so backfill UI behaviour is otherwise unchanged.
    func dispatchLiveGestureIfFresh(frame: [UInt8], now: Int = Int(Date().timeIntervalSince1970)) {
        let parsed = parseFrame(frame, family: family)
        guard parsed.ok, parsed.crcOK != false else { return }
        guard parsed.typeName == "EVENT", let ev = parsed.parsed["event"]?.stringValue else { return }
        guard let ts = parsed.parsed["event_timestamp"]?.intValue, ts > 0 else { return }   // fail closed
        guard abs(now - ts) <= FrameRouter.liveGestureWindowSeconds else { return }
        if ev.hasPrefix("DOUBLE_TAP") {
            state.onDoubleTap?()
        } else if ev.hasPrefix("WRIST_ON") {
            if !state.worn { state.worn = true; state.onWristChange?(true) }
        } else if ev.hasPrefix("WRIST_OFF") {
            if state.worn { state.worn = false; state.onWristChange?(false) }
        }
    }
}
