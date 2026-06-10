import Foundation
import WhoopProtocol
import WhoopStore

/// The subset of WhoopStore the Collector needs. A protocol so tests can inject a spy
/// (WhoopStore is `final`). WhoopStore conforms via the extension below.
/// Not @MainActor — the WhoopStore actor's async methods satisfy the async requirements;
/// a @MainActor SpyStore in tests also conforms (async witnesses hop actors).
protocol StoreWriting: AnyObject {
    @discardableResult
    func insert(_ streams: Streams, deviceId: String) async throws
        -> (hr: Int, rr: Int, events: Int, battery: Int,
            spo2: Int, skinTemp: Int, resp: Int, gravity: Int)
    func enqueueRawBatch(_ meta: RawBatchMeta, frames: [[UInt8]]) async throws
}
extension WhoopStore: StoreWriting {}

/// Cadence: flush after this many buffered frames OR this many seconds since the last
/// flush — whichever first. Also flushed explicitly on disconnect/foreground.
struct CollectorPolicy {
    var maxFrames: Int
    var maxInterval: TimeInterval
    /// Defensive cap on the PRE-CLOCK buffer only (see `ingest`). Generous default —
    /// ~4096 frames at ~60 bytes/frame is ~240KB, far beyond the handful seen pre-clock
    /// normally. Custom init keeps `.init(maxFrames:maxInterval:)` call sites compiling.
    var maxPreClockFrames: Int
    init(maxFrames: Int, maxInterval: TimeInterval, maxPreClockFrames: Int = 4096) {
        self.maxFrames = maxFrames
        self.maxInterval = maxInterval
        self.maxPreClockFrames = maxPreClockFrames
    }
    static let `default` = CollectorPolicy(maxFrames: 64, maxInterval: 30, maxPreClockFrames: 4096)
}

/// Buffers complete (reassembled) frames and periodically persists them:
/// parse → extractStreams(clockRef) → store.insert (DECODED FIRST, durable) →
/// store.enqueueRawBatch (raw, transient outbox) → clear buffer.
/// Because decoded is committed before raw is queued, pruning raw never loses a metric.
@MainActor
final class Collector {
    private let store: StoreWriting
    /// Concrete store for prune + stats (the StoreWriting seam covers the hot insert/enqueue path;
    /// prune/stats are infrequent so a direct reference is clearer than widening the protocol).
    private let concreteStore: WhoopStore?
    private let deviceId: String
    private let policy: CollectorPolicy
    /// Research toggle. When false (DEFAULT) no raw frames are persisted at all — the app is
    /// decoded-only. Injected for tests; backed by UserDefaults in the production init site.
    private let enableRawCapture: Bool
    private let now: () -> Int
    private let monotonic: () -> TimeInterval

    /// Set once the GET_CLOCK correlation lands (E1). Until then, frames buffer un-persisted.
    /// WHOOP 5/MG: BLEManager sets an IDENTITY ref at connect instead — 5/MG live frames carry
    /// real unix timestamps, so device==wall makes toWall a no-op (same idiom as Backfiller).
    var clockRef: ClockRef?
    /// Frame family for flush()'s decode. WHOOP4 default preserves the original byte-for-byte
    /// behavior; BLEManager sets .whoop5 for a puffin connection so live 5/MG frames parse with
    /// the puffin decoder (mirrors Android flushLive's family-aware Framing.parseFrame).
    var family: DeviceFamily = .whoop4
    /// On-demand bounded raw-capture window. ORs into the raw-persist gate so a "capture
    /// activity sample" action can persist raw even when `enableRawCapture` is off. The window's
    /// monotonic deadline auto-expires so a missed stop callback can't leak raw forever.
    private var rawCapture = RawCaptureWindow()
    private var buffer: [[UInt8]] = []
    /// Standard 0x2A37 HR/RR buffer — the reliable, always-on stream, recorded continuously
    /// (independent of the custom realtime stream or which screen is open).
    private var stdHR: [HRSample] = []
    private var stdRR: [RRInterval] = []
    private var batchStartedAt: TimeInterval
    var bufferedCount: Int { buffer.count }

    init(store: StoreWriting, deviceId: String,
         policy: CollectorPolicy = .default,
         enableRawCapture: Bool = false,
         now: @escaping () -> Int = { Int(Date().timeIntervalSince1970) },
         monotonic: @escaping () -> TimeInterval = { Date().timeIntervalSinceReferenceDate }) {
        self.store = store; self.deviceId = deviceId; self.policy = policy
        self.enableRawCapture = enableRawCapture
        self.now = now; self.monotonic = monotonic
        self.batchStartedAt = monotonic()
        self.concreteStore = store as? WhoopStore
    }

    /// Light storage summary for the UI. nil if there's no concrete store or the read throws.
    func storageStats() async -> (decodedRows: Int, rawBatches: Int, rawBytes: Int)? {
        guard let s = concreteStore else { return nil }
        return try? await s.storageStats()
    }

    /// Max persisted HR sample ts (the biometric "data frontier" for the stuck-strap watchdog).
    /// nil if there's no concrete store or nothing persisted yet. Mirrors storageStats().
    func latestHRSampleTs() async -> Int? {
        guard let s = concreteStore else { return nil }
        return try? await s.latestHRSampleTs(deviceId: deviceId)
    }

    /// Apply the raw-retention policy. Returns rows pruned (0 if no concrete store).
    @discardableResult
    func prune() async -> Int {
        guard let s = concreteStore else { return 0 }
        return (try? await s.pruneRaw(now: now(),
                                keepWindowSeconds: PrunePolicy.keepWindowSeconds,
                                maxUnsyncedBytes: PrunePolicy.maxUnsyncedBytes)) ?? 0
    }

    /// Buffer one complete frame (synchronous: preserves delegate arrival order).
    /// Auto-flushes via a detached Task when the cadence threshold is hit (flush is async).
    func ingest(_ frame: [UInt8]) {
        buffer.append(frame)
        // Pre-clock only: bound memory if GET_CLOCK never lands while data keeps flowing.
        // Drop OLDEST beyond the cap (keep most recent). Post-clock this branch is skipped —
        // the cadence flush below bounds the buffer instead.
        if clockRef == nil && buffer.count > policy.maxPreClockFrames {
            buffer.removeFirst(buffer.count - policy.maxPreClockFrames)
        }
        guard clockRef != nil else { return }   // can't correlate ts yet → keep buffering
        if buffer.count >= policy.maxFrames || (monotonic() - batchStartedAt) >= policy.maxInterval {
            Task { @MainActor in await self.flush() }
        }
    }

    /// Persist + queue everything buffered. No-op when empty or before a clock ref exists.
    /// Buffer is snapshotted and cleared SYNCHRONOUSLY before the first await so that any
    /// concurrent ingest() calls during persistence accumulate into the NEXT batch cleanly.
    func flush() async {
        guard let ref = clockRef, !buffer.isEmpty else { return }
        // SNAPSHOT + CLEAR before any await: decoded-before-raw ordering AND the
        // buffer-snapshot-before-await invariant are both satisfied here.
        let frames = buffer
        buffer.removeAll(keepingCapacity: true)

        let parsed = frames.map { parseFrame($0, family: family) }
        let streams = extractStreams(parsed, deviceClockRef: ref.device, wallClockRef: ref.wall)
        do {
            try await store.insert(streams, deviceId: deviceId)   // DECODED FIRST (durable)
        } catch {
            // Re-buffer at the front so these frames are retried on the next cadence.
            buffer.insert(contentsOf: frames, at: 0)
            return
        }
        // Reset only after a successful insert so the interval trigger keeps firing if
        // inserts fail (batchStartedAt must NOT advance on a failed drain).
        batchStartedAt = monotonic()
        // RAW SECOND (transient outbox), only when the research toggle is ON. Default OFF →
        // decoded-only, no raw is stored. Failure is non-fatal — decoded is already durable.
        guard enableRawCapture || rawCapture.isActive(at: monotonic()) else { return }
        let wall = now()
        let tsValues = streams.hr.map(\.ts) + streams.rr.map(\.ts)
            + streams.events.map(\.ts) + streams.battery.map(\.ts)
        let meta = RawBatchMeta(
            batchId: UUID().uuidString, deviceId: deviceId, clockRef: ref, capturedAt: wall,
            startTs: tsValues.min() ?? wall, endTs: tsValues.max() ?? wall,
            frameCount: frames.count, byteSize: frames.reduce(0) { $0 + $1.count })
        try? await store.enqueueRawBatch(meta, frames: frames)
    }

    // MARK: - Standard 0x2A37 HR/RR (continuous recording)

    /// Buffer one standard Heart-Rate-Measurement reading. No clock correlation needed —
    /// these carry a wall-clock `ts` directly. Auto-flushes ~every 30 readings (~30s).
    func ingestStandardHR(hr: Int, rr: [Int], at ts: Int) {
        if hr >= 30, hr <= 220 { stdHR.append(HRSample(ts: ts, bpm: hr)) }
        for r in rr where r >= 250 && r <= 3000 { stdRR.append(RRInterval(ts: ts, rrMs: r)) }
        if stdHR.count + stdRR.count >= 30 {
            Task { @MainActor in await self.flushStandardHR() }
        }
    }

    /// Persist the buffered standard HR/RR. Re-buffers on failure so nothing is lost.
    func flushStandardHR() async {
        guard !stdHR.isEmpty || !stdRR.isEmpty else { return }
        let hr = stdHR, rr = stdRR
        stdHR.removeAll(keepingCapacity: true)
        stdRR.removeAll(keepingCapacity: true)
        do {
            try await store.insert(Streams(hr: hr, rr: rr), deviceId: deviceId)
        } catch {
            stdHR.insert(contentsOf: hr, at: 0)
            stdRR.insert(contentsOf: rr, at: 0)
        }
    }

    // MARK: - On-demand raw capture

    /// Open a bounded raw-capture window so the next flushes persist raw even with the global
    /// research toggle off. Auto-expires at the (clamped) monotonic deadline.
    func beginRawCapture(seconds: TimeInterval) {
        rawCapture.open(at: monotonic(), duration: seconds)
    }

    /// Flush WHILE the window is still active so the just-captured frames get persisted as raw,
    /// THEN close the window.
    func endRawCapture() async {
        await flush()
        rawCapture.close()
    }
}
