import Foundation
import WhoopProtocol

/// Append-only on-disk archive of HISTORICAL_DATA record frames that FAILED decode (#77 / #91).
///
/// The strap frees acked history the instant we send HISTORICAL_DATA_RESULT. On an unmapped
/// firmware layout the Backfiller decodes those records to zero rows, yet still has to ack the trim
/// (refusing would wedge the whole offload on a re-send loop). Without somewhere to put the raw
/// bytes first, every undecodable record is gone forever while the UI shows a healthy "History
/// synced". This archive is the user's only remaining copy — and the corpus a later layout mapping
/// re-ingests.
///
/// Format: newline-delimited JSON, one object per line, fsynced before returning so the bytes are
/// durable BEFORE the trim ack deletes the strap's copy (the whole point):
///   {"capturedAtMs":Double,"trim":Int,"family":"whoop4"|"whoop5","frameHex":String}
/// Frames carry sensor payloads, not identifiers — no serials/MACs land here. The companion Android
/// archive uses the same record shape so one mapping toolchain reads both.
struct RawHistoryArchive {
    /// File name under `<AppSupport>/com.noopapp.noop/`.
    static let fileName = "rejected_history.jsonl"
    /// Soft cap (~5 MB). When the existing file is at or over this, `archive` succeeds WITHOUT
    /// writing — by then there are ample sample bytes for mapping, and wedging the offload over a
    /// full archive would be strictly worse. The skipped frames are reported as unarchived.
    static let maxBytes = 5 * 1024 * 1024

    /// Outcome of an archive attempt.
    enum Result {
        /// Frames were durably written (fsynced). `count` is how many lines were appended.
        case written(count: Int)
        /// The archive is full; nothing was written but the caller may still ack. `count` frames
        /// were dropped (counted as unarchived so the sync status never claims "saved").
        case capReached(count: Int)
        /// The write genuinely failed. The caller must NOT ack — hold the cursor so the strap
        /// re-sends the chunk (no data loss either way).
        case failed
    }

    private let directory: URL

    /// Default location: `<AppSupport>/com.noopapp.noop/`, created on demand. Overridable for tests.
    init(directory: URL? = nil) {
        if let directory {
            self.directory = directory
        } else {
            let base = (try? FileManager.default.url(for: .applicationSupportDirectory,
                                                     in: .userDomainMask,
                                                     appropriateFor: nil, create: true))
                ?? URL(fileURLWithPath: NSTemporaryDirectory())
            self.directory = base.appendingPathComponent("com.noopapp.noop", isDirectory: true)
        }
    }

    /// The archive file URL (does not create anything).
    var fileURL: URL { directory.appendingPathComponent(RawHistoryArchive.fileName) }

    /// Durably append `frames` as JSONL. `trim`/`family` tag each line so the corpus is replayable.
    /// Empty input is a no-op success. See `Result` for the ack contract.
    func archive(_ frames: [[UInt8]], trim: UInt32, family: DeviceFamily) -> Result {
        guard !frames.isEmpty else { return .written(count: 0) }
        let url = fileURL
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        let existingSize = (attrs?[.size] as? Int) ?? 0
        if existingSize >= RawHistoryArchive.maxBytes {
            return .capReached(count: frames.count)
        }
        let capturedAtMs = Date().timeIntervalSince1970 * 1000
        var lines = ""
        lines.reserveCapacity(frames.count * 128)
        for f in frames {
            let hex = f.map { String(format: "%02x", $0) }.joined()
            // Hand-built JSON: the only dynamic field is hex (always [0-9a-f]) so no escaping is
            // needed, and this avoids a JSONEncoder allocation per frame on the offload hot path.
            lines += "{\"capturedAtMs\":\(capturedAtMs),\"trim\":\(Int(trim)),"
                + "\"family\":\"\(family.rawValue)\",\"frameHex\":\"\(hex)\"}\n"
        }
        let data = Data(lines.utf8)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: url.path) {
                let handle = try FileHandle(forWritingTo: url)
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: data)
                try handle.synchronize()   // durable BEFORE the ack — the point of the archive
            } else {
                try data.write(to: url, options: .atomic)
            }
            return .written(count: frames.count)
        } catch {
            return .failed
        }
    }

    /// Every archived frame with its strap family, oldest first — the read-back of the JSONL that
    /// `archive` writes. Malformed lines are skipped; an absent/empty file yields []. (Hand-parsed to
    /// match the hand-built writer: the only dynamic fields are `family` and the [0-9a-f] `frameHex`.)
    func readAll() -> [(frame: [UInt8], family: DeviceFamily)] {
        guard let text = try? String(contentsOf: fileURL, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").compactMap { line in
            guard let fr = line.range(of: "\"family\":\""),
                  let hr = line.range(of: "\"frameHex\":\"") else { return nil }
            let fam = String(line[fr.upperBound...].prefix { $0 != "\"" })
            let hex = line[hr.upperBound...].prefix { $0 != "\"" }
            guard let family = DeviceFamily(rawValue: fam), hex.count % 2 == 0 else { return nil }
            var bytes = [UInt8](); bytes.reserveCapacity(hex.count / 2); var i = hex.startIndex
            while i < hex.endIndex {
                let j = hex.index(i, offsetBy: 2)
                guard let b = UInt8(hex[i..<j], radix: 16) else { return nil }
                bytes.append(b); i = j
            }
            return (bytes, family)
        }
    }

    /// Re-decode every archived frame through the CURRENT decoder and insert whatever now decodes.
    /// The strap freed these records when they were acked, so this archive is the ONLY way banked
    /// history backfills after a newly-landed layout (e.g. WHOOP 4.0 v25). Idempotent: offloaded rows
    /// dedupe by (deviceId, ts), so a re-run can't double-insert. Returns rows recovered (for logging).
    /// Throws if a store insert fails — the caller MUST NOT advance the replay gate in that case, or
    /// these records (whose only surviving copy is this archive) would never be retried.
    @discardableResult
    func replay(into store: BackfillStoreWriting, deviceId: String) async throws -> Int {
        let archived = readAll()
        var rows = 0
        for family in Set(archived.map(\.family)) {
            let parsed = archived.filter { $0.family == family }.map { parseFrame($0.frame, family: family) }
            // type-47 records carry their own real-unix ts (clock offset ignored), so an identity
            // clock ref is correct here — the same fallback the Backfiller uses when clockRef is nil.
            let streams = extractHistoricalStreams(parsed, deviceClockRef: 0, wallClockRef: 0)
            rows += streams.gravity.count
            _ = try await store.insert(streams, deviceId: deviceId)
        }
        return rows
    }
}
