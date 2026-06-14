import Foundation
import WhoopStore

/// Sleep-session origin + manual add/delete/merge helpers (#281), modelled on `WorkoutSource`.
///
/// The macOS read model (`CachedSleepSession`) carries no `deviceId`/`source`, so a session's origin
/// has to be recovered from the store it was read from. The Repository keeps that mapping:
///   - imported WHOOP / Apple sessions live under the strap `deviceId` ("my-whoop")
///   - on-device computed sessions live under the computed id ("my-whoop-noop"), RE-DERIVED every
///     `IntelligenceEngine.analyzeRecent` run — so deleting one only hides it until the next run
///     resurrects the same (deviceId, startTs) row (the exact problem `WorkoutSource` solves for
///     detected bouts).
///   - MANUAL sessions the user adds also live under the strap `deviceId` with a dedicated stage
///     marker, where the engine never writes sleep — so they are never clobbered by a re-analysis.
///
/// `SleepSource` therefore provides: a validated manual-session builder, the durable "deleted sleep
/// span" list the engine consults so a deleted COMPUTED night stays deleted, and a merge helper for
/// the issue's "sessions close together" ask.
enum SleepSource {

    // MARK: - Manual sessions

    /// Marker written into a manual session's `stagesJSON` so the UI can label it "added by you" and
    /// the merge detector can tell manual blocks apart. It is a normal stage-summary object (so the
    /// existing decoder renders it) with an extra `"manual": true` flag the strict segment decoder
    /// ignores. Kept tiny and honest: the user-supplied ASLEEP minutes go to a single neutral "light"
    /// bucket and the rest to "awake" — we never fabricate a deep/REM architecture we didn't measure.
    static let manualFlagKey = "manual"

    /// True when this session was hand-added by the user (its stagesJSON carries the manual flag).
    static func isManual(_ session: CachedSleepSession) -> Bool {
        guard let json = session.stagesJSON, let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data),
              let dict = obj as? [String: Any] else { return false }
        return (dict[manualFlagKey] as? Bool) == true || (dict[manualFlagKey] as? NSNumber)?.boolValue == true
    }

    /// Encode the honest coarse stage summary for a manual session: `asleepMin` of "light" plus the
    /// in-bed remainder as "awake", tagged with the manual flag. Returns nil for a non-positive window.
    static func manualStagesJSON(inBedMin: Double, asleepMin: Double) -> String? {
        guard inBedMin > 0 else { return nil }
        let asleep = max(0, min(asleepMin, inBedMin))
        let awake = max(0, inBedMin - asleep)
        let dict: [String: Any] = ["light": asleep, "deep": 0, "rem": 0, "awake": awake,
                                   manualFlagKey: true]
        guard let data = try? JSONSerialization.data(withJSONObject: dict),
              let json = String(data: data, encoding: .utf8) else { return nil }
        return json
    }

    /// Build a manual sleep session from the add sheet's inputs. `start`/`end` are the bed/wake
    /// window; `asleepMin` is how much of it was actually asleep (defaults to the whole window).
    /// Returns nil when the inputs can't make an honest session (mirrors `WorkoutSource.buildManualRow`).
    static func buildManualSession(start: Date, end: Date, asleepMin: Double?,
                                   now: Date = Date()) -> CachedSleepSession? {
        let s = Int(start.timeIntervalSince1970)
        let e = Int(end.timeIntervalSince1970)
        guard s > 0, e > s else { return nil }
        guard start <= now, end <= now else { return nil }
        let inBedMin = Double(e - s) / 60.0
        // A single sleep block longer than 18 h is almost certainly a misentry — refuse it.
        guard inBedMin > 0, inBedMin <= 18 * 60 else { return nil }
        let asleep = asleepMin ?? inBedMin
        guard asleep >= 0, asleep <= inBedMin else { return nil }
        let eff = inBedMin > 0 ? asleep / inBedMin : nil   // fraction ≤ 1, as the decoder expects
        return CachedSleepSession(startTs: s, endTs: e, efficiency: eff, restingHr: nil,
                                  avgHrv: nil, stagesJSON: manualStagesJSON(inBedMin: inBedMin,
                                                                            asleepMin: asleep))
    }

    // MARK: - Deleted sessions (durable across re-analysis)
    //
    // The engine wipes-via-upsert + re-derives computed sleep every run, so deleting a computed
    // session from the table would only hide it until the next analyzeRecent recreates the same
    // (deviceId, startTs) row. The durable "the user removed this night" record is a list of deleted
    // time spans persisted in UserDefaults (the WhoopStore read model carries no per-row flag). A
    // re-derived computed session overlapping any deleted span is skipped on write. Mirrors
    // `WorkoutSource`'s dismissed-detected-spans mechanism. (#281)

    /// UserDefaults key holding the deleted spans as "startTs:endTs" strings.
    static let deletedDefaultsKey = "sleep.deletedSessions"

    /// Parse "startTs:endTs" spans. Malformed / non-positive-width entries are dropped so a corrupt
    /// value can never hide every night.
    static func parseDeletedSpans(_ raw: [String]) -> [(start: Int, end: Int)] {
        raw.compactMap { s in
            let parts = s.split(separator: ":")
            guard parts.count == 2, let a = Int(parts[0]), let b = Int(parts[1]), b > a else { return nil }
            return (a, b)
        }
    }

    /// The "startTs:endTs" token persisted for a deleted session.
    static func deletedToken(startTs: Int, endTs: Int) -> String { "\(startTs):\(endTs)" }

    /// True when a session overlaps any deleted span (half-open: `a.start < b.end && b.start < a.end`).
    /// The engine calls this to drop a re-derived computed night the user already removed.
    static func isDeleted(startTs: Int, endTs: Int, spans: [(start: Int, end: Int)]) -> Bool {
        spans.contains { startTs < $0.end && $0.start < endTs }
    }

    // MARK: - Merge (sessions close together)

    /// Default gap (seconds) under which two adjacent blocks are considered the same night and a merge
    /// is offered — a WHOOP split-sleep artefact is typically a short awake gap. 60 min is conservative.
    static let mergeGapThreshold = 60 * 60

    /// Combine two sessions into one spanning [min start, max end]. Stage minutes are summed (the gap
    /// between them counts as "awake" so time-in-bed stays truthful) and efficiency is recomputed over
    /// the merged in-bed window. The result is written as a manual session (it is a user-authored edit).
    /// `a` and `b` may be in any order.
    static func merge(_ a: CachedSleepSession, _ b: CachedSleepSession) -> CachedSleepSession {
        let start = min(a.startTs, b.startTs)
        let end = max(a.endTs, b.endTs)
        let stagesA = stageMinutes(a), stagesB = stageMinutes(b)
        let light = stagesA.light + stagesB.light
        let deep = stagesA.deep + stagesB.deep
        let rem = stagesA.rem + stagesB.rem
        let asleep = light + deep + rem
        let inBedMin = Double(end - start) / 60.0
        // The gap between the two blocks (and each block's own awake) is awake time in the merged night.
        let awake = max(0, inBedMin - asleep)
        let dict: [String: Any] = ["light": light, "deep": deep, "rem": rem, "awake": awake,
                                   manualFlagKey: true]
        let json = (try? JSONSerialization.data(withJSONObject: dict))
            .flatMap { String(data: $0, encoding: .utf8) }
        let eff = inBedMin > 0 ? min(1, asleep / inBedMin) : nil
        return CachedSleepSession(startTs: start, endTs: end, efficiency: eff,
                                  restingHr: a.restingHr ?? b.restingHr,
                                  avgHrv: a.avgHrv ?? b.avgHrv, stagesJSON: json)
    }

    /// Stage minutes for a session, decoding either the summary object or the segment array the
    /// on-device stager writes. Zeroes when there's no usable stage data.
    private static func stageMinutes(_ s: CachedSleepSession) -> (light: Double, deep: Double, rem: Double) {
        guard let json = s.stagesJSON, let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) else { return (0, 0, 0) }
        // Summary object {light,deep,rem,awake}.
        if let dict = obj as? [String: Any] {
            func v(_ k: String) -> Double {
                if let n = dict[k] as? NSNumber { return n.doubleValue }
                if let d = dict[k] as? Double { return d }
                if let i = dict[k] as? Int { return Double(i) }
                return 0
            }
            return (v("light"), v("deep"), v("rem"))
        }
        // Segment array [{start,end,stage}].
        if let arr = obj as? [[String: Any]] {
            var light = 0.0, deep = 0.0, rem = 0.0
            for seg in arr {
                guard let st = (seg["start"] as? NSNumber)?.intValue,
                      let en = (seg["end"] as? NSNumber)?.intValue, en > st,
                      let name = seg["stage"] as? String else { continue }
                let m = Double(en - st) / 60.0
                switch name {
                case "light": light += m
                case "deep": deep += m
                case "rem": rem += m
                default: break
                }
            }
            return (light, deep, rem)
        }
        return (0, 0, 0)
    }

    /// A merge candidate: two adjacent sessions and the gap between them.
    struct MergeCandidate: Equatable {
        let first: CachedSleepSession
        let second: CachedSleepSession
        let gapSeconds: Int
    }

    /// Find pairs of sessions whose end→start gap is under `gapThreshold` (and non-overlapping or
    /// touching), scanning a list sorted by start. Used to SUGGEST a merge — the user confirms it.
    /// Only adjacent pairs are returned (a 3-way split surfaces as two successive suggestions).
    static func suggestedMerges(_ sessions: [CachedSleepSession],
                                gapThreshold: Int = mergeGapThreshold) -> [MergeCandidate] {
        let sorted = sessions.sorted { $0.startTs < $1.startTs }
        var out: [MergeCandidate] = []
        for i in 0..<max(0, sorted.count - 1) {
            let a = sorted[i], b = sorted[i + 1]
            let gap = b.startTs - a.endTs
            // Gap in [−overlap … threshold): blocks that touch, slightly overlap, or sit within the
            // threshold are the same night. A large negative gap (b fully inside a) is skipped — that
            // is a containment artefact, not an adjacent split.
            if gap < gapThreshold && b.startTs >= a.startTs && b.endTs >= a.endTs {
                out.append(MergeCandidate(first: a, second: b, gapSeconds: max(0, gap)))
            }
        }
        return out
    }
}
