import Foundation
import Combine

/// Observable snapshot of the live connection + biometric state, driven by FrameRouter
/// (from decoded frames) and BLEManager (from CoreBluetooth callbacks).
/// `@MainActor` so SwiftUI views observe it safely; mutators are called on the main queue.
@MainActor
public final class LiveState: ObservableObject {
    @Published public var connected: Bool = false
    // NOTE: do NOT auto-clear `pairingHint` when `bonded` flips true. On a 5/MG, `bonded` is also set by
    // the live-HR shortcut (BLEManager — HR over the unbonded standard profile), so clearing the hint
    // there hides the still-accurate "free the strap" guidance from users who are streaming HR but never
    // got the real encrypted bond (issue #69). The genuine bond path clears the hint itself (the
    // CLIENT_HELLO ack), and a fresh connect attempt resets it.
    @Published public var bonded: Bool = false
    /// True ONLY when the link reached a GENUINE encrypted bond — the WHOOP 5/MG CLIENT_HELLO ack, the
    /// WHOOP 4 confirmed-write bond, or a restored already-bonded link. Deliberately NOT set by the
    /// live-HR shortcut that flips `bonded` true when HR streams over the *unbonded* standard profile on
    /// a 5/MG (issue #69) — so `bonded` can be true while `encryptedBond` is false ("Live HR, not fully
    /// paired"). WHOOP 4 always reaches a genuine bond, so the two track together there. Reset on
    /// connect/disconnect. Drives the Live pill's two-state distinction; the encrypted channel (buzz,
    /// alarm, double-tap, history offload) only works when this is true.
    @Published public var encryptedBond: Bool = false
    @Published public var heartRate: Int? = nil
    @Published public var rr: [Int] = []
    @Published public var batteryPct: Double? = nil
    /// Charging flag from the strap's BATTERY_LEVEL events — wire observation: u8 bit0 in the
    /// event payload (4.0 @26 / 5.0 @30), pushed ~every 8 min on captured links. nil until the
    /// first event of a session; cleared on disconnect so a stale flag can't outlive the link.
    /// Flag ONLY — the battery % keeps its family-specific source (#77).
    @Published public var charging: Bool? = nil
    @Published public var lastFrameType: String? = nil
    @Published public var lastEvent: String? = nil
    /// Wrist-wear state from WRIST_ON/WRIST_OFF events. Defaults true so wear-gated features work
    /// before the first event arrives; flipped by FrameRouter on a real event.
    @Published public var worn: Bool = true
    /// Rolling log of human-readable lines for the on-device verification checklist.
    @Published public var log: [String] = []

    /// Fired (live only) when the strap reports a DOUBLE_TAP gesture. Wired by AppModel to the
    /// user's chosen action. Debounced in AppModel.
    public var onDoubleTap: (() -> Void)?
    /// Fired (live only) when wrist-wear changes (true = put on, false = taken off).
    public var onWristChange: ((Bool) -> Void)?

    /// True when the stuck-strap watchdog finds the strap has newer records than us but our frontier
    /// won't advance (likely needs a manual reboot; ~never after high-freq-sync removal). Banner-only.
    @Published public var strapNeedsReboot = false

    /// Wall time (unix seconds) of the last successfully-completed offload (a sync, even if nothing new
    /// came — i.e. caught up). Drives the sync tile + the staleness nudge.
    @Published public var lastSyncedAt: TimeInterval?

    /// Set when an offload ended abnormally (the idle watchdog fired — the strap went quiet mid-sync),
    /// so a stalled history download isn't silent. Cleared by the next successful HISTORY_COMPLETE.
    /// Process-local on purpose (mirrors Android, ed6a31d): the next connect / 15-min tick re-offloads
    /// anyway, so persisting a stale error across launches would outlive its relevance.
    @Published public var lastSyncError: String? = nil

    /// True while a historical offload session is running, so screens can say "Syncing strap
    /// history…" instead of presenting half-loaded data as final (#77).
    @Published public var backfilling = false
    /// Chunks acked during the current offload session — an honest progress signal (total pending is
    /// unknowable from the protocol, so a count, never a percent).
    @Published public var syncChunksThisSession: Int = 0

    /// Optional hook invoked on every battery update (wired by LiveViewModel to the alert monitor).
    /// Kept as a closure so LiveState stays a plain observable snapshot with no alert dependency.
    public var onBatteryUpdate: ((Double) -> Void)?

    /// Number of WHOOP 5/MG ("puffin") frames captured this session (when frame capture is enabled in
    /// Settings → Experimental). Drives the capture status line + export button.
    @Published public var puffinCaptureCount: Int = 0
    /// On-disk location of the current puffin capture file, once anything has been flushed. The
    /// Settings "Export" / "Reveal" actions target this URL.
    @Published public var puffinCaptureURL: URL?

    /// Set when a WHOOP 5/MG strap refuses the encrypted bond on first connect ("Encryption/Authentication
    /// is insufficient") — CoreBluetooth won't start a fresh just-works bond against a strap still bonded to
    /// the official WHOOP app. Surfaced as actionable pairing-mode guidance; cleared once the link bonds.
    @Published public var pairingHint: String? = nil

    /// Set when a connect attempt fails because the strap wiped its bond ("Peer removed pairing
    /// information") — a firmware update, or the official WHOOP app re-bonding it. macOS keeps re-presenting
    /// the now-stale pairing key, so reconnects loop on the same error with no recovery. Carries an
    /// actionable forget-and-re-pair guide; cleared on the next successful connect. (5/MG firmware reset, 2026-06)
    @Published public var reconnectGuide: String? = nil

    public init() {}

    /// Single funnel for battery readings — updates the published value AND notifies the hook,
    /// so both write sites (FrameRouter, BLEManager) drive the alert monitor identically.
    public func setBattery(_ pct: Double) {
        batteryPct = pct
        onBatteryUpdate?(pct)
    }

    public func append(log line: String) {
        log.append(line)
        if log.count > 200 { log.removeFirst(log.count - 200) }
    }
}
