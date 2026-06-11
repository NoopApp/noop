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
}
