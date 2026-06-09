import Foundation
import CoreBluetooth
import WhoopProtocol
import WhoopStore

/// CoreBluetooth engine for the WHOOP 4.0: scan-by-service → connect → discover →
/// BOND (one confirmed write) → subscribe → reassemble char-05 frames → FrameRouter.
/// Cannot run in the simulator; verified manually on-device (Task C6).
@MainActor
public final class BLEManager: NSObject, ObservableObject {

    // MARK: GATT UUIDs (authoritative, from FINDINGS.md)
    static let customService   = CBUUID(string: "61080001-8d6d-82b8-614a-1c8cb0f8dcc6")
    static let whoop5Service   = CBUUID(string: "fd4b0001-cce1-4033-93ce-002d5875f58a") // WHOOP 5.0 / MG
    static let cmdWriteChar    = CBUUID(string: "61080002-8d6d-82b8-614a-1c8cb0f8dcc6") // CMD → strap
    static let cmdNotifyChar   = CBUUID(string: "61080003-8d6d-82b8-614a-1c8cb0f8dcc6") // responses
    static let eventNotifyChar = CBUUID(string: "61080004-8d6d-82b8-614a-1c8cb0f8dcc6") // events
    static let dataNotifyChar  = CBUUID(string: "61080005-8d6d-82b8-614a-1c8cb0f8dcc6") // data (frag)
    // WHOOP 5.0 / MG ("puffin") characteristics under the fd4b service. EXPERIMENTAL — see the
    // whoop5 connect path in didDiscoverCharacteristics. fd4b0002 takes the static CLIENT_HELLO.
    static let whoop5CmdWriteChar = CBUUID(string: "fd4b0002-cce1-4033-93ce-002d5875f58a")
    static let whoop5NotifyChars: [CBUUID] = [
        CBUUID(string: "fd4b0003-cce1-4033-93ce-002d5875f58a"),
        CBUUID(string: "fd4b0004-cce1-4033-93ce-002d5875f58a"),
        CBUUID(string: "fd4b0005-cce1-4033-93ce-002d5875f58a"),
        CBUUID(string: "fd4b0007-cce1-4033-93ce-002d5875f58a"),
    ]
    static let heartRateService = CBUUID(string: "180D")
    static let heartRateChar    = CBUUID(string: "2A37") // HR + R-R (works unbonded)
    static let batteryService   = CBUUID(string: "180F")
    static let batteryChar      = CBUUID(string: "2A19")

    static let restoreID = "com.openwhoop.ble.central"

    // MARK: Published state
    public let state: LiveState
    private let router: FrameRouter
    private var collector: Collector?

    // MARK: Upload / server sync — REMOVED for Strand (standalone, fully on-device).

    // MARK: Backfill
    private var backfiller: Backfiller?
    /// True while a historical offload session is in progress (frames route to Backfiller).
    private var backfilling = false
    /// Safety-net detector: strap reports newer data than us AND our frontier frozen 10 min ⇒ flag for
    /// reboot. behindGapSeconds avoids false positives when off-wrist / caught up. Insurance only.
    private var stuckDetector = StuckStrapDetector(stuckAfterSeconds: 600, behindGapSeconds: 300)
    /// Newest record unix the strap reports having (from the GET_DATA_RANGE response); refreshed each
    /// offload. Compared against our frontier to tell "stuck" from "off-wrist/caught-up".
    private var strapNewestTs: Int?
    /// Fires if the strap goes silent mid-offload; re-armed on every frame during backfill.
    private var backfillTimeout: DispatchWorkItem?
    /// Periodic opportunistic upload while connected. Without it, upload only fires at connect +
    /// backfill-exit, so during a long live session decoded rows pile up locally and the server
    /// (dashboard) lags. Started on bond, cancelled on disconnect.
    private var uploadTimer: DispatchSourceTimer?
    static let uploadIntervalSeconds = 30
    /// Periodic re-trigger of the type-47 historical offload. This is the PRIMARY continuous metric
    /// source (mirrors how WHOOP syncs): the strap's 14-day biometric store is re-offloaded every
    /// `backfillIntervalSeconds` while connected+bonded, rather than once per connect. Started on
    /// bond, cancelled on disconnect. Plain SEND_HISTORICAL_DATA returns the type-47 store (no
    /// high-freq-sync), so each periodic tick just routes through requestSync(.periodic) → beginBackfill
    /// (SEND_HISTORICAL_DATA + watchdog), subject to the BackfillPolicy floor.
    private var backfillTimer: DispatchSourceTimer?
    // The timer fires this often, but BackfillPolicy.periodicFloorSeconds is the real floor (a recent
    // event-triggered sync defers the next periodic tick). 900s = 15 min, matching WHOOP.
    static let backfillIntervalSeconds = 900
    /// Keep-alive: re-arm realtime, poll battery, and bounce a stalled link so streaming
    /// never silently dies. Started on bond, cancelled on disconnect.
    private var keepAliveTimer: DispatchSourceTimer?
    static let keepAliveIntervalSeconds = 30
    private var keepAliveTick = 0
    /// Last time ANY notification arrived — drives the liveness watchdog.
    private var lastDataAt = Date()
    /// True while the Live screen wants the (heavy) realtime stream; keep-alive re-arms it.
    private var wantsRealtime = false
    /// Last-offload-attempt time (unix seconds), persisted so the rate limiter survives relaunch
    /// (matches WHOOP's DATA_SYNC_WORKER_LAST_WORK_TIME watermark).
    static let backfillLastAtKey = "backfillLastAt"
    /// Prevents a second backfill from starting on a same-process reconnect to the same strap.
    private var backfillStarted = false
    /// Runs the connect handshake EXACTLY ONCE per connection. `didWriteValueFor` re-fires on every
    /// `.withResponse` write (the bond write, every SEND_HISTORICAL, every HISTORY_END ack); without
    /// this guard those re-entries re-blasted hello/SET_CLOCK at the strap mid-offload and stopped it
    /// from streaming type-47 — THE iOS "won't serve" root cause. Reset on disconnect.
    private var connectHandshakeDone = false
    /// Re-entrancy guard for captureRawAccel: true while a bounded on-demand window is running.
    /// A second tap is a no-op until the active capture's asyncAfter block fires and clears this.
    private var rawCaptureInFlight = false
    /// Ordered queue of frames awaiting drain through the serial Backfiller task.
    private var backfillFrameQueue: [[UInt8]] = []
    /// True while the drain task is running (prevents a second drain task from launching).
    private var backfillDraining = false
    /// Keep each main-actor drain slice small enough that SwiftUI can process input/paint between slices.
    private static let backfillDrainBatchSize = 12

    /// Records WHOOP 5/MG puffin frames to a JSON file for protocol mapping. Passive (read-only on the
    /// strap) and gated by the Settings → Experimental "Record puffin frames" toggle; a no-op for
    /// WHOOP 4.0 and when the toggle is off. Lazy so it shares `state` after init. (Cherry-picked from
    /// @j0b-dev's PR #20.)
    private lazy var puffinRecorder = PuffinFrameRecorder(state: state)

    /// Force the puffin capture buffer to disk so the Settings export/reveal targets a current file.
    public func flushPuffinCaptures() { puffinRecorder.flush() }

    // MARK: CoreBluetooth
    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    /// Peripheral captured during `willRestoreState`; cleared in `didConnect`.
    /// Non-nil signals that `centralManagerDidUpdateState` should reconnect this
    /// specific peripheral rather than starting a fresh scan.
    private var restoredPeripheral: CBPeripheral?
    private var cmdCharacteristic: CBCharacteristic?
    private var cmdNotifyCharacteristic: CBCharacteristic?
    private var eventNotifyCharacteristic: CBCharacteristic?
    private var dataNotifyCharacteristic: CBCharacteristic?
    private var heartRateCharacteristic: CBCharacteristic?
    private var batteryCharacteristic: CBCharacteristic?
    /// EXPERIMENTAL WHOOP 5.0/MG puffin notify chars (fd4b0003/4/5/7), remembered at discovery so we
    /// can re-subscribe them AFTER bonding — the strap refuses them ("Authentication is insufficient")
    /// until the link is encrypted (issue #17).
    private var whoop5NotifyCharacteristics: [CBCharacteristic] = []
    private var reassembler = Reassembler()
    private var seq: UInt8 = 0
    private var didBond = false
    /// WHOOP 5/MG only: realtime HR has been armed (puffin TOGGLE_REALTIME_HR sent) once for this
    /// connection, so the post-bond callback re-firing on later `.withResponse` writes doesn't re-send it.
    private var whoop5RealtimeArmed = false
    /// Once-per-connection guard for the 5/MG offload kick (connectHandshakeDone + requestSync +
    /// startBackfillTimer). Stops the HISTORY_END acks re-entering didWriteValueFor from re-triggering
    /// the offload mid-stream (the 5/MG twin of the WHOOP4 connectHandshakeDone ack-storm guard).
    private var whoop5SessionStarted = false
    /// Backfill ACKs can arrive hundreds or thousands of times in one offload. Keep the strap log
    /// readable and avoid forcing SwiftUI to auto-scroll on every ACK row.
    private var historicalAckLogCounter = 0
    private var clockRequested = false
    private var intentionalDisconnect = false
    /// The strap family the user chose to pair. Drives which service we scan for
    /// and which service we discover after connecting. Hydrated from the persisted
    /// pick so restoration/reconnect after a relaunch target the right strap.
    private var selectedModel: WhoopModel = .persisted
    private var lastStandardHRLogAt: Date?

    /// Stable device id; matches the server's existing device for sync parity. Overridable.
    let deviceId: String
    /// Captured (device↔wall) correlation from GET_CLOCK; nil until the response lands.
    private(set) var clockRef: ClockRef?

    public init(state: LiveState, deviceId: String = "my-whoop") {
        self.state = state
        self.deviceId = deviceId
        self.router = FrameRouter(state: state)
        // WhoopStore.init is now async, so it can't run here.
        // bootstrapStore() is called once the CBCentralManager reaches poweredOn
        // (see centralManagerDidUpdateState), which guarantees the store is ready
        // before any BLE data arrives.
        self.collector = nil
        super.init()
        state.lastSyncedAt = UserDefaults.standard.object(forKey: "lastSyncedAt") as? Double
        // Restore identifier + background-capable central (foundation for M3 state restoration).
        // Strand (macOS desktop): no state-restoration identifier (iOS background feature).
        central = CBCentralManager(delegate: self, queue: .main)
        // Strap-as-clock: an incoming EVENT packet kicks a rate-limited catch-up sync.
        router.onSyncTrigger = { [weak self] in self?.requestSync(.strap) }
    }

    /// Build the WhoopStore + Collector + Backfiller asynchronously. Safe to call multiple
    /// times — bails out early if the collector is already initialised.
    func bootstrapStore() async {
        guard collector == nil else { return }
        guard let path = try? StorePaths.defaultDatabasePath() else { return }
        guard let store = try? await WhoopStore(path: path) else { return }
        try? await store.upsertDevice(id: deviceId, mac: nil, name: "WHOOP 4.0")
        // Research toggle — OFF by default. When disabled the app is decoded-only and never
        // persists raw frames. Flip "enableRawCapture" in UserDefaults to capture raw again.
        let enableRawCapture = UserDefaults.standard.bool(forKey: "enableRawCapture")
        collector = Collector(store: store, deviceId: deviceId,
                              enableRawCapture: enableRawCapture)
        backfiller = Backfiller(store: store, deviceId: deviceId,
                                ackTrim: { [weak self] trim, endData in
                                    self?.ackHistoricalChunk(trim: trim, endData: endData)
                                },
                                enableRawCapture: enableRawCapture,
                                log: { [weak self] s in self?.log(s) })
        // Strand: no server uploader/sync — all data stays on-device.
    }

    /// Designated initializer for testing and preview use: accepts a pre-built Collector.
    init(state: LiveState, deviceId: String = "my-whoop", collector: Collector?) {
        self.state = state
        self.deviceId = deviceId
        self.router = FrameRouter(state: state)
        self.collector = collector
        super.init()
        state.lastSyncedAt = UserDefaults.standard.object(forKey: "lastSyncedAt") as? Double
        // Strand (macOS desktop): no state-restoration identifier (iOS background feature).
        central = CBCentralManager(delegate: self, queue: .main)
        // Strap-as-clock: an incoming EVENT packet kicks a rate-limited catch-up sync.
        router.onSyncTrigger = { [weak self] in self?.requestSync(.strap) }
    }

    // MARK: Public API
    public func connect(model: WhoopModel = .persisted) {
        intentionalDisconnect = false
        selectedModel = model
        // Frame the inbound stream for the chosen family (WHOOP 4.0 CRC8 vs WHOOP 5.0 CRC16/puffin)
        // and tell the router which decoder to use. Fresh per connection so no stale bytes carry over.
        reassembler = Reassembler(family: model.deviceFamily)
        router.family = model.deviceFamily
        guard central.state == .poweredOn else {
            log("Bluetooth not powered on (state=\(central.state.rawValue)); cannot scan yet")
            return
        }
        if let p = peripheral, p.state == .connected {
            state.connected = true
            p.delegate = self
            log("Already connected to \(model.displayName) — refreshing services and notifications")
            discoverPrimaryServices(on: p)
            enableLiveNotifications(reason: "manual refresh")
            return
        }
        if let p = central.retrieveConnectedPeripherals(withServices: [model.scanService]).first {
            log("Found existing \(model.displayName) connection \(p.identifier) — attaching")
            preparePeripheral(p)
            if p.state == .connected {
                state.connected = true
                discoverPrimaryServices(on: p)
                enableLiveNotifications(reason: "attached connection")
            } else {
                central.connect(p, options: nil)
            }
            return
        }
        log("Scanning for \(model.displayName)…")
        central.scanForPeripherals(
            withServices: [model.scanService],
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: false]
        )
    }

    public func disconnect() {
        intentionalDisconnect = true
        if let p = peripheral {
            central.cancelPeripheralConnection(p)
        }
        central.stopScan()
    }

    /// Switch which strap we'll connect to next: drop the current strap and clear the **sticky** bond
    /// state so a newly-picked model bonds fresh. `bonded` deliberately survives a disconnect (it means
    /// "this strap is paired"), but that left a user with BOTH a WHOOP 4 and a 5/MG unable to switch —
    /// `bonded` stayed true from the first strap, which hid the strap picker and kept the scan pointed at
    /// the old family's service. Call this when the user changes the strap selection.
    public func prepareForModelSwitch() {
        disconnect()
        state.connected = false
        state.bonded = false
    }

    /// Apply the raw-outbox retention policy (24h synced window / 50MB unsynced cap).
    /// Called when the app enters the background; no-op without a concrete store.
    public func pruneRaw() {
        Task { @MainActor in await collector?.prune() }
    }

    /// Light storage summary for the UI (decoded rows, raw batches, raw bytes). nil without a store.
    public func storageStats() async -> (decodedRows: Int, rawBatches: Int, rawBytes: Int)? {
        await collector?.storageStats()
    }

    /// Capture raw accelerometer (type-43 IMU) frames on demand for a bounded window, then stop.
    /// Persists raw even when the global research toggle is off (that's the point: on-demand, not
    /// 24/7). The Collector's window auto-expires at its deadline so a dropped stop can't leak raw.
    public func captureRawAccel(seconds: TimeInterval = 30) {
        guard !rawCaptureInFlight else {
            log("Raw-accel capture: already in flight — ignoring")
            return
        }
        rawCaptureInFlight = true
        let secs = RawCaptureWindow.clamp(seconds)
        collector?.beginRawCapture(seconds: secs)
        send(.startRawData, payload: [0x01])
        send(.toggleIMUMode, payload: [0x01])
        log("Raw-accel capture: started for \(secs)s")
        DispatchQueue.main.asyncAfter(deadline: .now() + secs) { [weak self] in
            guard let self else { return }
            // Only stop the raw stream if the 24/7 research toggle is OFF.  When it's ON, the
            // continuous stream must keep running — we just flush/upload the bounded window we
            // captured without halting the wider session.
            if !UserDefaults.standard.bool(forKey: "enableRawCapture") {
                self.send(.stopRawData, payload: [0x01])
            }
            self.rawCaptureInFlight = false
            Task { @MainActor in
                await self.collector?.endRawCapture()
            }
            self.log("Raw-accel capture: stopped + flushed")
        }
    }

    /// Send a command to the WHOOP strap.
    /// - Parameters:
    ///   - command: The command to send.
    ///   - payload: Command payload bytes (default `[0x00]`).
    ///   - writeType: BLE write type; defaults to `.withoutResponse` so all existing call
    ///     sites are unaffected. Pass `.withResponse` for acked commands (e.g. historicalDataResult).
    public func send(_ command: WhoopCommand, payload: [UInt8] = [0x00],
                     writeType: CBCharacteristicWriteType = .withoutResponse) {
        guard state.connected, let p = peripheral, p.state == .connected, let ch = cmdCharacteristic else {
            let reason = state.connected ? "command characteristic unavailable" : "not connected"
            log("send(\(command.label)) ignored — \(reason)")
            return
        }
        // WHOOP 5.0/MG uses puffin (CRC16) command framing, not the WHOOP4 frame. The realtime-HR toggle
        // is hardware-confirmed (issue #17 — a 5/MG owner saw live HR over a public build), which proves
        // the strap does act on puffin-framed commands. We now also send haptics (buzz) on that same
        // proven transport — experimental: the strap may or may not honor that specific command, but it's
        // no longer a blind guess. Everything else stays dropped (the offload commands need the held
        // historical-offload work). WHOOP 4.0 is unaffected.
        if selectedModel.deviceFamily == .whoop5 {
            // Allowlist: live (toggle HR, buzz) + the two historical-offload commands. SEND_HISTORICAL_DATA
            // triggers the offload; HISTORICAL_DATA_RESULT acks each HISTORY_END to walk the trim cursor.
            // Both flow through the same puffinCommandFrame transport that toggle/buzz already use.
            guard command == .toggleRealtimeHR || command == .runHapticsPattern
                || command == .sendHistoricalData || command == .historicalDataResult else {
                log("send(\(command.label)) skipped — no WHOOP 5/MG framing for this command yet")
                return
            }
            // WHOOP 5/MG haptics differ from WHOOP 4.0 on BOTH the opcode AND the payload (#48, decoded
            // from the working "maverick" app's binary). Opcode: 0x13, not RUN_HAPTICS_PATTERN=79 (a real-MG
            // capture showed the strap rejecting 79 with COMMAND_RESPONSE result=0x03). Payload: the maverick
            // haptic body [0x01, effects(8), loopControl(u16 LE), overallLoop] — here the "notify" preset
            // (effects 47,152), NOT the 4.0 [patternId, loops, …]. puffinCommandFrame pads the inner to a
            // 4-byte boundary, which this 12-byte payload needs. WHOOP 4.0 is untouched (79 + its own frame).
            let isHaptics = command == .runHapticsPattern
            let puffinCmd: UInt8 = isHaptics ? 0x13 : command.rawValue
            let puffinPayload: [UInt8] = isHaptics ? [0x01, 47, 152, 0, 0, 0, 0, 0, 0, 0, 0, 0] : payload
            seq = seq &+ 1
            let frame = puffinCommandFrame(cmd: puffinCmd, seq: seq, payload: puffinPayload)
            p.writeValue(Data(frame), for: ch, type: writeType)
            let cmdNote = isHaptics ? " cmd=0x13" : ""
            if command == .historicalDataResult {
                historicalAckLogCounter += 1
                if historicalAckLogCounter == 1 || historicalAckLogCounter.isMultiple(of: 25) {
                    log("→ \(command.label) ack #\(historicalAckLogCounter) payload=\(hex(puffinPayload)) (puffin)")
                }
                return
            }
            log("→ \(command.label) payload=\(hex(puffinPayload)) (puffin\(cmdNote))")
            return
        }
        seq = seq &+ 1
        let frame = command.frame(seq: seq, payload: payload)
        p.writeValue(Data(frame), for: ch, type: writeType)
        log("→ \(command.label) payload=\(hex(payload))")
    }

    /// Ask CoreBluetooth for the current Battery Level value when the standard profile is present.
    /// WHOOP 5/MG exposes live battery through 0x2A19, while WHOOP 4 can also answer the legacy
    /// proprietary command path.
    public func refreshBattery() {
        guard state.connected, let p = peripheral, p.state == .connected else {
            log("refreshBattery ignored — not connected")
            return
        }

        if let batteryCharacteristic {
            if batteryCharacteristic.properties.contains(.read) {
                p.readValue(for: batteryCharacteristic)
                log("Reading standard Battery Level")
            } else {
                log("Battery Level read unavailable; waiting for notifications")
            }
        } else {
            log("Battery Level characteristic unavailable")
        }

        if selectedModel.deviceFamily == .whoop4 {
            send(.getBatteryLevel, payload: [0x00])
        }
    }

    /// Ack one HISTORY_END chunk so the strap may trim it. Confirmed write — the strap forgets
    /// the chunk once this lands (link-layer half of safe-trim; decoded + raw already persisted).
    ///
    /// High-freq-sync ack form (matches re/sync_openwhoop.py, which pulled 762 type-47 records):
    /// HISTORICAL_DATA_RESULT(23) payload = `[0x01] + end_data`, where end_data is the verbatim
    /// 8 bytes of the HISTORY_END metadata.data[10:18] (trim u32 at [10:14] + next u32 at [14:18]).
    /// The `trim` argument (= end_data first u32) is already persisted as the strap_trim cursor by
    /// the Backfiller; it is passed here only for logging.
    func ackHistoricalChunk(trim: UInt32, endData: [UInt8]) {
        send(.historicalDataResult, payload: [0x01] + endData, writeType: .withResponse)
    }

    // MARK: Backfill helpers

    /// Start a historical-offload session: tell the store machine to begin, flip the routing
    /// flag, kick the strap with sendHistoricalData, and arm the idle timeout.
    @discardableResult
    private func beginBackfill() -> Bool {
        // Never offload before the connect handshake has run: a racing foreground/restore trigger
        // firing SEND_HISTORICAL ahead of hello/SET_CLOCK was part of the storm that stopped serving.
        guard connectHandshakeDone else {
            log("Backfill: deferred — connect handshake not done yet")
            return false
        }
        guard let backfiller else {
            // Store not ready yet. Do NOT force live HR — the type-47 backfill is the metric
            // source. Just log; the next periodic backfill tick will run once the store is ready.
            log("Backfill: store not ready — deferring to next periodic tick")
            return false
        }
        // Capture the family at begin() (not init): selectedModel is reliably set by connect() before any
        // backfill starts, whereas bootstrapStore() can build the Backfiller before the family is known.
        backfiller.begin(family: selectedModel.deviceFamily)
        backfilling = true
        historicalAckLogCounter = 0
        // Payload MUST be [0x00], NOT empty: verified on-device that this strap serves type-47 only with
        // [0x00] (empty → 0 frames on a clean stable link with ~2k records pending); the Mac ground-truth
        // offload (re/sync_openwhoop.py, re/diagnose_biometrics.py) uses [0x00] too. Plain offload — the
        // strap streams HISTORY_START → type-47 records → HISTORY_END (acked) … → HISTORY_COMPLETE.
        send(.sendHistoricalData, payload: [0x00], writeType: .withResponse)
        armBackfillTimeout()
        log("Backfill: session started — historical offload requested")
        return true
    }

    /// Feed a frame to the Backfiller preserving exact arrival order. Frames are appended
    /// synchronously (delegate order) and drained sequentially in small slices, so START /
    /// data / END chunk assembly is never reordered while the UI still gets time to paint.
    private func routeBackfillFrame(_ frame: [UInt8]) {
        backfillFrameQueue.append(frame)
        guard !backfillDraining else { return }
        backfillDraining = true
        Task { @MainActor in await drainBackfillFrames() }
    }

    private func drainBackfillFrames() async {
        while !backfillFrameQueue.isEmpty {
            let count = min(Self.backfillDrainBatchSize, backfillFrameQueue.count)
            let batch = Array(backfillFrameQueue.prefix(count))
            backfillFrameQueue.removeFirst(count)

            for f in batch {
                await backfiller?.ingest(f)
                afterBackfillIngest()
                if !backfilling {
                    backfillFrameQueue.removeAll(keepingCapacity: true)
                    break
                }
            }

            if !backfillFrameQueue.isEmpty {
                await Task.yield()
            }
        }
        backfillDraining = false
    }

    /// Called after every Backfiller.ingest completes. If the Backfiller has consumed all
    /// historical data (isBackfilling drops to false), exit the backfill session cleanly.
    private func afterBackfillIngest() {
        guard backfilling, backfiller?.isBackfilling == false else { return }
        exitBackfilling(reason: "HISTORY_COMPLETE")
    }

    /// True when a frame is part of the historical offload (HISTORICAL_DATA=47, EVENT=48,
    /// METADATA=49 / puffin METADATA=56, CONSOLE_LOGS=50) rather than the live stream (REALTIME_DATA=40,
    /// REALTIME_RAW_DATA=43). The live type-43 raw flood streams continuously and unprompted on
    /// this firmware, so the backfill idle-watchdog must NOT be re-armed by it — only by genuine
    /// offload progress — otherwise the session can neither complete nor time out.
    static func isOffloadFrame(_ frame: [UInt8], family: DeviceFamily) -> Bool {
        // The type byte sits at the inner-record start: frame[4] on WHOOP 4.0, frame[8] on WHOOP 5/MG
        // (the puffin envelope is 4 bytes longer). Reading frame[4] for a puffin frame misclassifies
        // EVERY offload frame as live-flood and routes nothing to the Backfiller.
        let typeIndex = family == .whoop5 ? 8 : 4
        guard frame.count > typeIndex else { return false }
        switch frame[typeIndex] {
        case 47, 48, 49, 50, 56: return true   // HISTORICAL_DATA / EVENT / METADATA / CONSOLE_LOGS
        default: return false              // 40 REALTIME_DATA, 43 REALTIME_RAW_DATA (live flood)
        }
    }

    /// Re-arm the idle watchdog. Called on every offload frame during backfill so the timer resets
    /// as long as the strap keeps sending HISTORY; if the strap goes silent the timer fires and we
    /// exit the session (the durable strap_trim cursor means the next session resumes where we left
    /// off). Timeout is generous (60 s, not 20 s): the unstoppable ~2/s type-43 raw flood eats BLE
    /// airtime, so genuine offload frames can arrive in bursts with multi-second lulls between chunks
    /// — a short watchdog cut sessions short mid-drain. Longer = more records drained per session.
    static let backfillIdleTimeoutSeconds = 60
    private func armBackfillTimeout() {
        backfillTimeout?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.backfiller?.timeoutFired()
            self.exitBackfilling(reason: "timeout")
        }
        backfillTimeout = item
        DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(BLEManager.backfillIdleTimeoutSeconds), execute: item)
    }

    /// Tear down the backfill session. Does NOT auto-start live HR: the periodic type-47 backfill
    /// is the primary metric source now, mirroring how WHOOP syncs. Live HR is opt-in only (the
    /// manual "Start HR" button in LiveView). Between backfills the Collector sees only the live
    /// type-43 flood, which extractStreams ignores — the data comes from the next periodic offload.
    private func exitBackfilling(reason: String) {
        guard backfilling else { return }
        backfilling = false
        backfillTimeout?.cancel()
        backfillTimeout = nil
        backfillFrameQueue.removeAll()
        log("Backfill: session ended — reason=\(reason)")
        if reason == "HISTORY_COMPLETE" {
            state.lastSyncedAt = Date().timeIntervalSince1970
            UserDefaults.standard.set(state.lastSyncedAt, forKey: "lastSyncedAt")
        }
        checkStrapLiveness()         // safety-net: strap ahead of us AND our frontier frozen ⇒ stuck?
    }

    /// After an offload, judge liveness: stuck = strap reports records newer than our frontier AND our
    /// frontier (max persisted HR ts) hasn't advanced for the detector window. Off-wrist / caught up
    /// (strap not ahead) is NOT stuck. On stuck: attempt recovery (defensive EXIT + SET_CLOCK) and raise
    /// the surface. Best-effort; reads the frontier via the Collector (which owns the concrete store).
    private func checkStrapLiveness() {
        let strapNewest = strapNewestTs
        Task { @MainActor in
            let frontier = await collector?.latestHRSampleTs()
            let front: Int? = frontier ?? nil
            let now = Date().timeIntervalSince1970
            let stuck = stuckDetector.observe(strapNewestTs: strapNewest,
                                              ourFrontierTs: front,
                                              now: now)
            state.strapNeedsReboot = stuck
            if stuck {
                log("Watchdog: behind + frontier frozen — recovery (exit high-freq + SET_CLOCK)")
                send(.exitHighFreqSync, payload: [0x00])
                send(.setClock, payload: BLEManager.setClockPayload())
            }
        }
    }

    /// Pure decision: should the periodic timer kick off another historical offload? Only when
    /// connected + bonded and NOT already mid-backfill. Extracted so the gate is unit-testable
    /// without a CoreBluetooth seam. Note this intentionally does NOT consult `backfillStarted`
    /// (that flag guards the once-per-connect INITIAL kick); the periodic re-trigger is separate.
    static func shouldRunPeriodicBackfill(connected: Bool, bonded: Bool, backfilling: Bool) -> Bool {
        connected && bonded && !backfilling
    }

    /// Start (or restart) the periodic backfill timer. Each tick re-runs the type-47 historical
    /// offload while connected+bonded and not already backfilling — the primary metric sync.
    // MARK: - Keep-alive (always-ping + liveness watchdog)

    /// Enable live HR and remember we want it re-armed by keep-alive.
    /// Some WHOOP firmware acknowledges TOGGLE_REALTIME_HR but only emits usable live samples once
    /// the R10/R11 realtime stream is also on. Keep that stream scoped to the Live tab and stop it
    /// on disappear so it does not permanently compete with historical offload.
    public func startRealtime() {
        wantsRealtime = true
        enableLiveNotifications(reason: "start realtime")
        send(.sendR10R11Realtime, payload: [0x01])
        send(.toggleRealtimeHR, payload: [0x01])
    }
    /// Stop the Live-tab realtime streams. The lightweight 0x2A37 HR keeps recording if firmware emits it.
    public func stopRealtime() {
        wantsRealtime = false
        send(.toggleRealtimeHR, payload: [0x00])
        send(.sendR10R11Realtime, payload: [0x00])
    }

    private func startKeepAlive() {
        keepAliveTimer?.cancel()
        let s = BLEManager.keepAliveIntervalSeconds
        let t = DispatchSource.makeTimerSource(queue: .main)
        t.schedule(deadline: .now() + .seconds(s), repeating: .seconds(s))
        t.setEventHandler { [weak self] in self?.keepAliveFire() }
        t.resume()
        keepAliveTimer = t
    }

    private func keepAliveFire() {
        guard state.connected, didBond else { return }
        enableLiveNotifications(reason: "keepalive")
        // Liveness watchdog: if NOTHING has arrived for a while, the stream/link stalled.
        // Bounce the connection — the auto-rescan on disconnect re-bonds and resumes streaming.
        if Date().timeIntervalSince(lastDataAt) > 120 {
            log("No data for >120s — bouncing link to resume streaming")
            if let p = peripheral { central.cancelPeripheralConnection(p) }
            return
        }
        guard !backfilling else { return }            // never poke the strap mid-offload
        // The command pings below are WHOOP4-framed; a 5/MG link drops them at the send() guard, so
        // skip them for 5/MG (it keeps the experimental strap log clean — re-subscribe + the 120s
        // bounce above are what keep a 5/MG link healthy).
        guard selectedModel.deviceFamily == .whoop4 else { return }
        if wantsRealtime {
            send(.sendR10R11Realtime, payload: [0x01])
            send(.toggleRealtimeHR, payload: [0x01])
        }   // re-arm so it can't lapse
        keepAliveTick += 1
        if keepAliveTick % 2 == 0 { send(.getBatteryLevel, payload: []) }  // ~every 60s
    }

    private func startBackfillTimer() {
        backfillTimer?.cancel()
        let interval = BLEManager.backfillIntervalSeconds
        let t = DispatchSource.makeTimerSource(queue: .main)
        t.schedule(deadline: .now() + .seconds(interval), repeating: .seconds(interval))
        t.setEventHandler { [weak self] in self?.triggerPeriodicBackfill() }
        t.resume()
        backfillTimer = t
    }

    /// The single gated entry point for every historical-offload kick. Applies the connection/state
    /// gate AND the BackfillPolicy rate-limiter for the trigger. On a go: records the attempt time
    /// (persisted) and starts the offload.
    func requestSync(_ trigger: BackfillTrigger) {
        guard BLEManager.shouldRunPeriodicBackfill(
            connected: state.connected, bonded: state.bonded, backfilling: backfilling) else { return }
        let now = Date().timeIntervalSince1970
        let last = UserDefaults.standard.object(forKey: BLEManager.backfillLastAtKey) as? Double
        guard BackfillPolicy.shouldRun(trigger: trigger, now: now, lastBackfillAt: last) else {
            log("Backfill: \(trigger) skipped (rate-limited; last \(last.map { Int(now - $0) } ?? -1)s ago)")
            return
        }
        if beginBackfill() {
            UserDefaults.standard.set(now, forKey: BLEManager.backfillLastAtKey)
        }
    }

    /// Periodic-timer callback: routes through the rate-limited requestSync entry point.
    private func triggerPeriodicBackfill() {
        requestSync(.periodic)
    }

    // MARK: Helpers
    private static let logTimeFormatter: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss"; return f
    }()

    private func log(_ s: String) {
        state.append(log: "[\(timestamp())] \(s)")
    }
    private func timestamp() -> String {
        BLEManager.logTimeFormatter.string(from: Date())
    }
    private func hex(_ bytes: [UInt8]) -> String {
        bytes.map { String(format: "%02x", $0) }.joined()
    }

    private func preparePeripheral(_ p: CBPeripheral) {
        peripheral = p
        p.delegate = self
        resetCharacteristics()
    }

    private func discoverPrimaryServices(on p: CBPeripheral) {
        p.discoverServices([
            selectedModel.scanService, BLEManager.heartRateService, BLEManager.batteryService,
        ])
    }

    private func resetCharacteristics() {
        cmdCharacteristic = nil
        cmdNotifyCharacteristic = nil
        eventNotifyCharacteristic = nil
        dataNotifyCharacteristic = nil
        heartRateCharacteristic = nil
        batteryCharacteristic = nil
        whoop5NotifyCharacteristics.removeAll()
    }

    private func enableLiveNotifications(reason: String) {
        guard let p = peripheral, p.state == .connected else { return }
        let chars = [
            cmdNotifyCharacteristic,
            eventNotifyCharacteristic,
            dataNotifyCharacteristic,
            heartRateCharacteristic,
            batteryCharacteristic,
        ].compactMap { $0 }
        for c in chars where !c.isNotifying {
            requestNotify(c, on: p, reason: reason)
        }
    }

    private func requestNotify(_ c: CBCharacteristic, on p: CBPeripheral, reason: String) {
        guard c.properties.contains(.notify) || c.properties.contains(.indicate) else {
            log("Notify unavailable \(c.uuid) (\(reason))")
            return
        }
        if c.isNotifying {
            log("Notify already active \(c.uuid) (\(reason))")
            return
        }
        p.setNotifyValue(true, for: c)
        log("Notify requested \(c.uuid) (\(reason))")
    }

    // MARK: Alarm API (M6 — additive; does NOT touch connect/offload/sync flows)

    /// Arm the strap's firmware alarm for `date` (UTC).
    ///
    /// Sequence: SET_CLOCK first to ensure the strap RTC is UTC-correct, then SET_ALARM_TIME.
    /// The strap will buzz at `date` even if the app is backgrounded or force-quit
    /// (event STRAP_DRIVEN_ALARM_EXECUTED=57). This is the guaranteed fixed-time fallback path —
    /// the smart-wake layer (`SmartAlarmController`) fires on top of this if conditions are met,
    /// but this firmware alarm always fires as the safety net.
    ///
    /// On-device verification needed: confirm the strap ACKs SET_ALARM_TIME and that the
    /// alarm persists across BLE disconnect (cannot be verified in the simulator).
    func armStrapAlarm(at date: Date) {
        // Clamp rather than trap: an out-of-range alarm date (pre-1970 / post-2106) must not crash.
        let epochSec = UInt32(clamping: Int64(date.timeIntervalSince1970))
        send(.setClock, payload: BLEManager.setClockPayload())
        send(.setAlarmTime, payload: WhoopCommand.setAlarmPayload(epochSec: epochSec))
        // Log the wake time in the user's LOCAL zone. `Date` prints in UTC by default, so an alarm
        // for (say) 07:00 in New York logged as "11:00:00 +0000" reads like a timezone bug — but it
        // isn't: SET_ALARM_TIME carries the absolute instant of the chosen local time, and the strap
        // fires at that instant regardless of how its UTC RTC is labelled.
        let localFmt = DateFormatter()
        localFmt.dateFormat = "EEE HH:mm zzz"
        log("Alarm: armed for \(localFmt.string(from: date)) — your local wake time (sent as UTC epoch \(epochSec))")
    }

    /// Disarm the currently-armed firmware alarm.
    func disableStrapAlarm() {
        send(.disableAlarm, payload: [0x01])
        log("Alarm: disarmed")
    }

    /// Request the currently-armed alarm time from the strap (response arrives on cmd-notify char).
    /// Parsing the reply is optional/bonus — the raw bytes will appear in the BLE log.
    func getStrapAlarm() {
        send(.getAlarmTime, payload: [0x01])
        log("Alarm: requested current alarm time")
    }

    /// Fire an immediate alarm buzz on the strap for testing.
    ///
    /// Uses RUN_HAPTICS_PATTERN (cmd 79) with patternId=2, 3 loops — the same pattern the official
    /// WHOOP app uses for alarms (verified: patternId=2, observed for interoperability), plus RUN_ALARM
    /// (cmd 68) as a belt-and-suspenders. patternId=2 gives the characteristic graduated alarm buzz.
    ///
    /// Alternative waveform form (12-byte):
    ///   [wfe1=47, wfe2=152, 0,0,0,0,0,0, loop u16=0, overall_loop=7, dur=30]
    /// — note for future refinement; the preset id=2 form is simpler and confirmed to buzz on-device.
    ///
    /// Haptic firing cannot be verified in the simulator (no strap motor). Test on-device only.
    func testAlarmBuzz() {
        send(.runHapticsPattern, payload: [2, 3, 0, 0, 0])  // patternId=2, 3 loops
        send(.runAlarm, payload: [0x01])
        log("Alarm: test buzz fired (patternId=2, runAlarm)")
    }

    /// Parse a standard BLE Heart Rate Measurement (0x2A37) via the pure StandardHeartRate parser.
    private func parseStandardHR(_ data: [UInt8]) {
        guard let m = StandardHeartRate.parse(data) else {
            log("HR notify parse failed: \(hex(data))")
            return
        }
        let now = Date()
        if lastStandardHRLogAt.map({ now.timeIntervalSince($0) >= 30 }) ?? true {
            lastStandardHRLogAt = now
            let plausibility = (30...220).contains(m.hr) ? "" : " ignored"
            log("HR notify: \(m.hr) bpm\(plausibility), rr=\(m.rr.count)")
        }
        // R-R: the standard profile is the RELIABLE source (the custom REALTIME_DATA stream
        // usually reports rr_count=0), so always surface intervals when present.
        if !m.rr.isEmpty { state.rr = m.rr }
        // HR: the standard 0x2A37 profile is the RELIABLE source (BLE-standard, ~1Hz). Let it
        // drive the value whenever it's physiologically plausible; reject 0/garbage (off-wrist).
        // AppModel medians these into a stable display value.
        if m.hr >= 30 && m.hr <= 220 { state.heartRate = m.hr }
        // Record it continuously — independent of the realtime stream or the open screen.
        collector?.ingestStandardHR(hr: m.hr, rr: m.rr, at: Int(Date().timeIntervalSince1970))
    }
}

// MARK: - CBCentralManagerDelegate
extension BLEManager: CBCentralManagerDelegate {
    public func centralManagerDidUpdateState(_ central: CBCentralManager) {
        log("Central state: \(central.state.rawValue) (5 = poweredOn)")
        guard central.state == .poweredOn else { return }
        // Bootstrap the async store once on first poweredOn (idempotent if already set).
        Task { @MainActor in await bootstrapStore() }
        if let p = restoredPeripheral {
            log("poweredOn with restored peripheral — reconnecting \(p.identifier)")
            if p.state != .connected {
                central.connect(p, options: nil)
            } else {
                discoverPrimaryServices(on: p)
            }
        } else {
            connect()
        }
    }

    public func centralManager(_ central: CBCentralManager,
                               didDiscover peripheral: CBPeripheral,
                               advertisementData: [String: Any],
                               rssi RSSI: NSNumber) {
        let name = (advertisementData[CBAdvertisementDataLocalNameKey] as? String) ?? peripheral.name ?? "unknown"
        log("Discovered \(name) (rssi \(RSSI)) — connecting")
        central.stopScan()
        preparePeripheral(peripheral)
        central.connect(peripheral, options: nil)
    }

    public func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        restoredPeripheral = nil
        preparePeripheral(peripheral)
        state.connected = true
        lastDataAt = Date()
        log("Connected — discovering services")
        discoverPrimaryServices(on: peripheral)
    }

    public func centralManager(_ central: CBCentralManager,
                               didDisconnectPeripheral peripheral: CBPeripheral,
                               error: Error?) {
        Task { @MainActor in await collector?.flush() }
        state.connected = false
        didBond = false
        whoop5RealtimeArmed = false
        whoop5SessionStarted = false
        clockRequested = false
        connectHandshakeDone = false
        // Reset backfill state so the next connect starts a fresh offload.
        backfillStarted = false
        backfilling = false
        backfillTimeout?.cancel()
        backfillTimeout = nil
        backfillFrameQueue.removeAll()
        backfillDraining = false
        uploadTimer?.cancel()
        uploadTimer = nil
        backfillTimer?.cancel()
        backfillTimer = nil
        keepAliveTimer?.cancel()
        keepAliveTimer = nil
        resetCharacteristics()
        puffinRecorder.flush()   // persist any buffered puffin capture frames before reconnect
        Task { @MainActor in await collector?.flushStandardHR() }   // persist any buffered 0x2A37 HR
        if !intentionalDisconnect {
            log("Disconnected\(error.map { " — \($0.localizedDescription)" } ?? ""); rescanning in 3s")
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                guard let self, !self.intentionalDisconnect else { return }
                self.connect()
            }
        } else {
            log("Disconnected (intentional)")
        }
    }

    public func centralManager(_ central: CBCentralManager,
                               didFailToConnect peripheral: CBPeripheral,
                               error: Error?) {
        log("Failed to connect\(error.map { " — \($0.localizedDescription)" } ?? "")")
    }

    /// State restoration entry point (M3 background collection).
    /// Stores the restored peripheral and — if already connected — immediately
    /// re-discovers services so `cmdCharacteristic` is re-acquired and
    /// notifications are re-routed without user interaction.
    public func centralManager(_ central: CBCentralManager,
                               willRestoreState dict: [String: Any]) {
        guard let peripherals = dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral],
              let p = peripherals.first else {
            log("Restore: no peripherals in state dict")
            return
        }
        self.peripheral = p
        self.restoredPeripheral = p
        p.delegate = self
        resetCharacteristics()
        // Collection only runs post-bond, so a restored link was already bonded;
        // seed those flags now. `didWriteValueFor` won't re-fire on its own.
        state.bonded = true
        didBond = true
        // clockRef is nil in the fresh process after restore, so we must re-request it.
        // Reset the flag so the post-restore didWriteValueFor issues exactly one getClock.
        clockRequested = false
        // Ensure the store is ready before restored BLE data arrives (idempotent; no-op if already built).
        Task { @MainActor in await bootstrapStore() }
        if p.state == .connected {
            state.connected = true
            log("Restored CONNECTED peripheral \(p.identifier) — re-discovering services")
            discoverPrimaryServices(on: p)
        } else {
            state.connected = false
            log("Restored DISCONNECTED peripheral \(p.identifier) — reconnect on poweredOn")
            if central.state == .poweredOn { central.connect(p, options: nil) }
        }
    }
}

// MARK: - CBPeripheralDelegate
extension BLEManager: CBPeripheralDelegate {
    public func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if let error {
            log("Service discovery failed: \(error.localizedDescription)")
            return
        }
        guard let services = peripheral.services else { return }
        log("Services discovered: \(services.map { $0.uuid.uuidString }.joined(separator: ", "))")
        for s in services {
            switch s.uuid {
            case BLEManager.customService:
                peripheral.discoverCharacteristics(
                    [BLEManager.cmdWriteChar, BLEManager.cmdNotifyChar,
                     BLEManager.eventNotifyChar, BLEManager.dataNotifyChar], for: s)
            case BLEManager.heartRateService:
                peripheral.discoverCharacteristics([BLEManager.heartRateChar], for: s)
            case BLEManager.batteryService:
                peripheral.discoverCharacteristics([BLEManager.batteryChar], for: s)
            case BLEManager.whoop5Service:
                // EXPERIMENTAL WHOOP 5.0/MG path: discover the puffin command + notify characteristics
                // so we can send CLIENT_HELLO and receive frames. Live HR/battery still arrive over the
                // standard 0x2A37/0x2A19 profiles (discovered alongside this); this custom path is
                // unverified on MG hardware.
                log("WHOOP 5/MG detected — discovering puffin characteristics (experimental).")
                peripheral.discoverCharacteristics(
                    [BLEManager.whoop5CmdWriteChar] + BLEManager.whoop5NotifyChars, for: s)
            default: break
            }
        }
    }

    public func peripheral(_ peripheral: CBPeripheral,
                           didDiscoverCharacteristicsFor service: CBService,
                           error: Error?) {
        if let error {
            log("Characteristic discovery failed for \(service.uuid): \(error.localizedDescription)")
            return
        }
        guard let chars = service.characteristics else { return }
        for c in chars {
            switch c.uuid {
            case BLEManager.cmdWriteChar:
                cmdCharacteristic = c
                // THE BONDING TRICK: one confirmed write triggers just-works bonding.
                // GET_BATTERY_LEVEL is benign and what the Mac prototype uses.
                seq = seq &+ 1
                let bondFrame = WhoopCommand.getBatteryLevel.frame(seq: seq, payload: [0x00])
                log("Bonding: confirmed write GET_BATTERY_LEVEL to 61080002")
                peripheral.writeValue(Data(bondFrame), for: c, type: .withResponse)
            case BLEManager.whoop5CmdWriteChar:
                // EXPERIMENTAL WHOOP 5.0/MG: a 5/MG strap starts a session with the static CLIENT_HELLO
                // frame, not the WHOOP4 confirmed-write bond. We write it UNacknowledged (it is a
                // complete framed command), so the WHOOP4 didWriteValueFor bond+handshake path never
                // fires for a 5/MG strap. Live HR/battery come from the standard profiles; this just
                // opens the puffin session. Unverified on real MG hardware.
                cmdCharacteristic = c
                if let hello = selectedModel.deviceFamily.clientHello {
                    // CONTRIBUTOR FIX (issue #17 — diagnosed from the logs, unverified on hardware here):
                    // write CLIENT_HELLO with .withResponse so CoreBluetooth runs just-works bonding when
                    // the link needs authenticating, AND so didWriteValueFor fires. That callback is where
                    // we mark the link established and (re)subscribe the puffin notify chars — the strap
                    // rejects them with "Authentication is insufficient" until the connection is encrypted,
                    // and the old .withoutResponse write never triggered bonding, so it hung forever at
                    // "Finishing the secure pairing handshake…".
                    log("WHOOP 5/MG: writing CLIENT_HELLO to fd4b0002 with response (to trigger bonding, experimental).")
                    state.pairingHint = nil   // fresh attempt; clear any stale pairing-mode guidance
                    peripheral.writeValue(Data(hello), for: c, type: .withResponse)
                }
                // The realtime-HR stream is armed POST-bond (in didWriteValueFor / startRealtime) with
                // puffin framing — not here. Writing it pre-bond on an unauthenticated link did nothing.
            case BLEManager.cmdNotifyChar,
                 BLEManager.eventNotifyChar,
                 BLEManager.dataNotifyChar,
                 BLEManager.heartRateChar,
                 BLEManager.batteryChar:
                switch c.uuid {
                case BLEManager.cmdNotifyChar: cmdNotifyCharacteristic = c
                case BLEManager.eventNotifyChar: eventNotifyCharacteristic = c
                case BLEManager.dataNotifyChar: dataNotifyCharacteristic = c
                case BLEManager.heartRateChar: heartRateCharacteristic = c
                case BLEManager.batteryChar:
                    batteryCharacteristic = c
                    if c.properties.contains(.read) {
                        peripheral.readValue(for: c)
                    }
                default: break
                }
                requestNotify(c, on: peripheral, reason: "discovery")
            default:
                // WHOOP 5.0/MG puffin notify characteristics (fd4b0003/0004/0005/0007). Retain them but DO
                // NOT subscribe yet — on an unauthenticated link the strap rejects them with "Authentication
                // is insufficient", which (per a 5/MG owner's verified flow, issue #17) also wedges the bond.
                // didWriteValueFor subscribes them once the CLIENT_HELLO .withResponse write confirms.
                if BLEManager.whoop5NotifyChars.contains(c.uuid) {
                    whoop5NotifyCharacteristics.append(c)
                }
            }
        }
    }

    /// Confirmed-write completion = bonding succeeded (no error).
    public func peripheral(_ peripheral: CBPeripheral,
                           didWriteValueFor characteristic: CBCharacteristic,
                           error: Error?) {
        if let error = error {
            log("Confirmed write failed: \(error.localizedDescription)")
            // WHOOP 5/MG first connect: CoreBluetooth won't start a fresh just-works bond against a strap
            // still bonded to the official WHOOP app, so the CLIENT_HELLO .withResponse write fails with
            // "Encryption/Authentication is insufficient" and the link never authenticates. Surface
            // actionable pairing-mode guidance instead of failing silently (issue #17).
            if selectedModel.deviceFamily == .whoop5, !didBond {
                let d = error.localizedDescription.lowercased()
                if d.contains("encryption") || d.contains("authentication") {
                    state.pairingHint = "Close the official WHOOP app (or turn its phone's Bluetooth off), put the strap in pairing mode — blue LEDs flashing — then reconnect."
                    log("WHOOP 5/MG: bond refused — the strap is likely still paired to the WHOOP app. Put it in pairing mode (blue LEDs) with the WHOOP app closed, then reconnect.")
                }
            }
            return
        }

        // EXPERIMENTAL WHOOP 5.0/MG (issue #17): the CLIENT_HELLO is now a .withResponse write, so this
        // fires once the strap acks it — after just-works bonding if the link needed authenticating.
        // Treat that as the link being established: mark bonded (which clears the "Finishing the secure
        // pairing handshake…" status) and re-subscribe the puffin notify chars + standard HR/battery,
        // which the strap refused before the link was encrypted. Do NOT run the WHOOP4 command handshake
        // below — a 5/MG strap rejects WHOOP4-framed commands (the send() guard drops them anyway).
        if selectedModel.deviceFamily == .whoop5 {
            if !didBond {
                didBond = true
                state.bonded = true
                state.pairingHint = nil
                log("WHOOP 5/MG: CLIENT_HELLO acked — link established; subscribing notify chars (experimental).")
            }
            for c in whoop5NotifyCharacteristics where !c.isNotifying {
                requestNotify(c, on: peripheral, reason: "post-bond puffin")
            }
            enableLiveNotifications(reason: "post-bond 5/MG")   // standard HR/battery that failed pre-bond
            // Arm realtime HR with puffin framing — the verified step that makes a bonded 5/MG strap start
            // streaming (issue #17). Once per connection; keep-alive skips 5/MG, so this is the trigger.
            // (Opening Live later also arms it via startRealtime(), now that send() routes the 5/MG toggle.)
            if wantsRealtime && !whoop5RealtimeArmed {
                whoop5RealtimeArmed = true
                log("WHOOP 5/MG: arming realtime HR (puffin TOGGLE_REALTIME_HR)")
                send(.toggleRealtimeHR, payload: [0x01])
            }
            startKeepAlive()                                    // re-subscribe + liveness watchdog
            // Kick the historical offload ONCE per connection — this is the 5/MG edition of the WHOOP4
            // connect-handshake (lines below). didWriteValueFor re-enters this `.whoop5` branch on EVERY
            // .withResponse ack during the offload (each HISTORY_END ack), so the trigger work MUST fire
            // once or it would re-issue SEND_HISTORICAL_DATA mid-stream and storm the strap. The notify
            // re-subscribe + realtime-arm above are idempotent and intentionally run on every re-entry;
            // only this block is gated. `whoop5SessionStarted` resets on disconnect.
            if !whoop5SessionStarted {
                whoop5SessionStarted = true
                connectHandshakeDone = true     // unblocks beginBackfill()'s guard
                log("WHOOP 5/MG: connect handshake done — backfill unblocked")
                log("WHOOP 5/MG: scheduling first historical offload (connect)")
                // Deferred ~1.5s so the puffin notify subscriptions settle before SEND_HISTORICAL_DATA,
                // mirroring the WHOOP4 kick. requestSync → beginBackfill is itself gated on
                // connectHandshakeDone, so a racing foreground/restore trigger can't fire it early.
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.requestSync(.connect) }
                startBackfillTimer()            // re-offload the type-47 store every backfillIntervalSeconds
            }
            return
        }

        if !didBond {
            didBond = true
            state.bonded = true
            log("BONDED (confirmed write acknowledged) — custom channels should now flow")
        }
        // Run the connect handshake EXACTLY ONCE per connection. didWriteValueFor re-fires on EVERY
        // .withResponse write — the bond write, every SEND_HISTORICAL, every HISTORY_END ack. Without
        // this guard those re-entries re-sent hello/SET_CLOCK at the strap *during* the offload and
        // stopped it from streaming type-47. This was THE iOS-side root cause: the Mac prototype pulls
        // type-47 fine because it runs the sequence once on a stable connection; the app stormed it.
        guard !connectHandshakeDone else { return }
        connectHandshakeDone = true
        backfillStarted = true

        // WHOOP-faithful connect lifecycle: hello → set RTC,
        // then offload. Hello is NOT strictly required to serve — verified on this strap via the Mac
        // ground-truth test: plain SEND_HISTORICAL_DATA serves type-47 with no hello and no high-freq-sync
        // (PHASE A = 50 records; PHASE B high-freq = 0). We still exchange hello to mirror WHOOP exactly.
        send(.getHelloHarvard)
        send(.getAdvertisingNameHarvard)
        send(.setClock, payload: BLEManager.setClockPayload())
        if clockRef == nil && !clockRequested {
            clockRequested = true
            send(.getClock, payload: [])   // the strap expects GET_CLOCK with an EMPTY payload;
                                           // the app's old default [0x00] is a wrong length the strap ignores.
                                           // (Offload no longer depends on this — Backfiller falls back to an
                                           // identity clockRef — but a real correlation helps realtime decode.)
        }
        send(.sendR10R11Realtime, payload: [0x00])   // stop the type-43 realtime flood (BLE airtime/battery)
        send(.getDataRange)                          // refresh the strap's stored range for the watchdog
        // Plain offload (no high-freq-sync), rate-limited (first connect always runs; reconnect-flaps are
        // throttled by BackfillPolicy). Deferred ~1.5s so SET_CLOCK/GET_DATA_RANGE round-trip first and
        // SEND_HISTORICAL runs on a settled link, like the paced Mac prototype. beginBackfill is itself
        // gated on connectHandshakeDone so a racing foreground/restore trigger can't fire it early.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.requestSync(.connect) }
        startBackfillTimer()   // re-offload the type-47 store every backfillIntervalSeconds
        startKeepAlive()       // always-ping: re-arm realtime, poll battery, watchdog the link
        enableLiveNotifications(reason: "post-bond")
        if wantsRealtime {
            log("Realtime HR: arming after bond")
            send(.sendR10R11Realtime, payload: [0x01])
            send(.toggleRealtimeHR, payload: [0x01])
        }
    }

    /// SET_CLOCK(10) payload = the strap's 8-byte form: [seconds u32 LE][subseconds
    /// u32 LE], subseconds in 1/32768 s (0 is fine). NOT the old 9-byte [u32 + 5 pad] — a wrong-length
    /// SET_CLOCK is ack-received but NOT latched, leaving the RTC lost so the strap won't serve type-47.
    static func setClockPayload(now: UInt32 = UInt32(Date().timeIntervalSince1970)) -> [UInt8] {
        [UInt8(now & 0xFF), UInt8((now >> 8) & 0xFF),
         UInt8((now >> 16) & 0xFF), UInt8((now >> 24) & 0xFF),
         0, 0, 0, 0]
    }

    /// Newest plausible-unix marker in a GET_DATA_RANGE COMMAND_RESPONSE = the strap's newest stored
    /// record. Mirrors re/diagnose_biometrics.py: scan u32 LE words in the response body (data starts at
    /// frame[7], after [type,seq,cmd]), keep those in the unix range, return the max. nil if none.
    static func dataRangeNewestUnix(from frame: [UInt8]) -> Int? {
        guard frame.count > 7 else { return nil }
        let body = Array(frame[7...]); var newest: Int? = nil; var i = 0
        while i + 4 <= body.count {
            let w = Int(body[i]) | Int(body[i+1]) << 8 | Int(body[i+2]) << 16 | Int(body[i+3]) << 24
            if w >= 1_700_000_000 && w <= 1_900_000_000 { newest = max(newest ?? 0, w) }
            i += 4
        }
        return newest
    }

    public func peripheral(_ peripheral: CBPeripheral,
                           didUpdateValueFor characteristic: CBCharacteristic,
                           error: Error?) {
        if let error {
            log("Notify update failed for \(characteristic.uuid): \(error.localizedDescription)")
            return
        }
        guard let data = characteristic.value else { return }
        let bytes = [UInt8](data)
        lastDataAt = Date()   // feed the liveness watchdog on every notification

        switch characteristic.uuid {
        case BLEManager.heartRateChar:
            parseStandardHR(bytes)
            // EXPERIMENTAL WHOOP 5.0/MG: there is no confirmed-write bond for a 5/MG strap, so once
            // live HR actually streams over the standard profile we treat the link as established —
            // otherwise the UI sits on "Connecting…" forever even though data is flowing (issue #8).
            if selectedModel.deviceFamily == .whoop5, !state.bonded {
                state.bonded = true
                log("WHOOP 5/MG: live HR streaming — marking the link established (experimental).")
            }
        case BLEManager.batteryChar:
            if let pct = bytes.first { state.setBattery(Double(pct)) } // 0x2A19 = percent
        case BLEManager.dataNotifyChar,
             BLEManager.cmdNotifyChar,
             BLEManager.eventNotifyChar:
            // Reassemble (no-op for already-complete frames) then route each complete frame.
            for frame in reassembler.feed(bytes) {
                if backfilling, BLEManager.isOffloadFrame(frame, family: .whoop4) {
                    // Historical replay is bulk sync traffic, not live UI traffic. Feed it only to
                    // the Backfiller; parsing every record through FrameRouter updates SwiftUI for
                    // no user-visible benefit and can make the app feel hung during long offloads.
                    armBackfillTimeout()
                    routeBackfillFrame(frame)
                    continue
                }
                router.handle(frame: frame)                       // live/UI path
                if frame.count > 6, frame[6] == WhoopCommand.getDataRange.rawValue,
                   let newest = BLEManager.dataRangeNewestUnix(from: frame) {
                    strapNewestTs = newest                        // feeds the liveness watchdog
                }
                // Clock correlation runs in both live and backfill modes. Once established it
                // unblocks both the Collector (live path) and the Backfiller (chunk decoding).
                if clockRef == nil {
                    let parsed = parseFrame(frame)
                    if let ref = ClockCorrelation.clockRef(from: parsed, wall: Int(Date().timeIntervalSince1970)) {
                        clockRef = ref
                        collector?.clockRef = ref                  // unblocks buffered persistence
                        backfiller?.clockRef = ref                 // unblocks historical chunk decode
                        log("Clock correlated: device=\(ref.device) wall=\(ref.wall)")
                        // Conditional SET_CLOCK (mirrors WHOOP): only when the strap RTC has drifted /
                        // is frozen — not blindly every connect. Offload doesn't depend on this (it uses
                        // clockRef for decoding); SET_CLOCK only keeps FUTURE logging timestamps sane.
                        if ClockPolicy.shouldSetClock(deviceClock: ref.device, wallNow: ref.wall) {
                            log("Clock drift detected — issuing SET_CLOCK")
                            send(.setClock, payload: BLEManager.setClockPayload())
                        }
                    }
                }
                if !backfilling {
                    // Live path (unchanged): synchronous ingest preserves delegate arrival order.
                    collector?.ingest(frame)
                }
            }
        default:
            // EXPERIMENTAL WHOOP 5.0/MG puffin notify chars (fd4b0003/0004/0005/0007): reassemble with
            // the family-aware reassembler and route through the family-aware FrameRouter so the UI
            // reflects arriving frames. We deliberately do NOT run the WHOOP4 backfill / collector /
            // clock paths here — puffin biometric + historical decode is still a stub. Live HR and
            // battery come from the standard 0x2A37 / 0x2A19 profiles handled above.
            if BLEManager.whoop5NotifyChars.contains(characteristic.uuid) {
                for frame in reassembler.feed(bytes) {
                    if backfilling, BLEManager.isOffloadFrame(frame, family: .whoop5) {
                        // Same policy as WHOOP4: historical offload frames are bulk sync traffic.
                        // Keep them out of the live UI parser during backfill and let Backfiller
                        // preserve/order/process them in the sliced drain.
                        armBackfillTimeout()
                        routeBackfillFrame(frame)
                        continue
                    }
                    router.handle(frame: frame)
                    // Capture for protocol mapping (no-op unless the Settings toggle is on). PR #20.
                    puffinRecorder.capture(frame: frame, char: characteristic.uuid)
                }
            }
        }
    }

    public func peripheral(_ peripheral: CBPeripheral,
                           didUpdateNotificationStateFor characteristic: CBCharacteristic,
                           error: Error?) {
        if let error = error {
            log("Notify enable failed for \(characteristic.uuid): \(error.localizedDescription)")
        } else {
            log("Notify \(characteristic.isNotifying ? "active" : "off") \(characteristic.uuid)")
        }
    }
}
