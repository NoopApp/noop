import Foundation
import StrandDesign

/// Decodes the two stagesJSON shapes the sleepSession cache stores:
///   • the verbatim per-epoch segment array the on-device stager persists
///     ([{"start":…,"end":…,"stage":"wake|light|deep|rem"}], unix seconds) —
///     wire shape of StrandAnalytics.StageSegment / AnalyticsEngine.encodeStages;
///   • the imported WHOOP-export minutes dict ({"light":…,"deep":…,"rem":…,"awake":…}).
/// Segment timelines are APPROXIMATE (on-device staging, not cloud/clinical parity) —
/// callers label them as such.
enum SleepStagesDecoder {

    /// One persisted per-epoch stage segment (wall-clock unix seconds). Local
    /// Decodable twin of StrandAnalytics.StageSegment so tests need only Strand.
    struct Segment: Decodable, Equatable {
        let start: Int
        let end: Int
        let stage: String
    }

    /// Per-stage minutes, whichever shape the JSON carries.
    struct StageMinutes: Equatable {
        var awake: Double, light: Double, deep: Double, rem: Double
    }

    /// The persisted segment array, or nil when the JSON is the minutes dict / unparseable.
    static func segments(_ json: String?) -> [Segment]? {
        guard let json, let data = json.data(using: .utf8),
              let segs = try? JSONDecoder().decode([Segment].self, from: data),
              !segs.isEmpty,
              segs.allSatisfy({ $0.end > $0.start }) else { return nil }
        return segs
    }

    /// Per-stage minutes from either shape ("wake" sums into awake). nil when neither parses.
    static func minutes(_ json: String?) -> StageMinutes? {
        if let segs = segments(json) {
            var m = StageMinutes(awake: 0, light: 0, deep: 0, rem: 0)
            for s in segs {
                let mins = Double(s.end - s.start) / 60.0
                switch s.stage {
                case "wake", "awake": m.awake += mins
                case "light":         m.light += mins
                case "deep":          m.deep += mins
                case "rem":           m.rem += mins
                default:              break
                }
            }
            return m
        }
        guard let json, let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data),
              let dict = obj as? [String: Any] else { return nil }
        func val(_ key: String) -> Double {
            (dict[key] as? NSNumber)?.doubleValue ?? 0
        }
        return StageMinutes(awake: val("awake"), light: val("light"),
                            deep: val("deep"), rem: val("rem"))
    }
}

extension SleepStage {
    /// Map a persisted stage string to the design-system stage ("wake" → .awake).
    init?(persisted raw: String) {
        if raw == "wake" { self = .awake; return }
        self.init(rawValue: raw)
    }
}
