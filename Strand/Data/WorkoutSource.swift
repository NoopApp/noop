import Foundation
import WhoopStore

/// Origin of a workout row, classified from its stored `source` column (the macOS read model
/// carries no deviceId). Stored values today: "whoop" (WhoopImporter), "apple_health"
/// (AppleHealthImport), "manual" (AppModel.endWorkout, v1.67, + the retro add/edit sheet),
/// "my-whoop-noop" (IntelligenceEngine detected bouts — source == the computed deviceId).
enum WorkoutSource: Equatable {
    case whoop, apple, detected, manual

    static func classify(_ source: String) -> WorkoutSource {
        let s = source.lowercased()
        if s.hasSuffix("-noop") { return .detected }   // BEFORE whoop: "my-whoop-noop" contains "whoop"
        if s == "manual" { return .manual }
        if s.contains("whoop") { return .whoop }
        return .apple
    }

    /// Sport cell text: the machine token "detected" reads as "Activity".
    static func displaySport(_ sport: String) -> String { sport == "detected" ? "Activity" : sport }

    /// "startTs:endTs" spans the user dismissed (UserDefaults). Malformed entries are dropped.
    static func parseDismissedSpans(_ raw: [String]) -> [(start: Int, end: Int)] {
        raw.compactMap { s in
            let parts = s.split(separator: ":")
            guard parts.count == 2, let a = Int(parts[0]), let b = Int(parts[1]), b > a else { return nil }
            return (a, b)
        }
    }

    /// Read-time filter: a detected row overlapping a dismissed span is hidden (the engine
    /// re-derives detected rows each run, so a plain delete would resurrect them).
    static func isDismissed(_ row: WorkoutRow, spans: [(start: Int, end: Int)]) -> Bool {
        classify(row.source) == .detected && spans.contains { row.startTs < $0.end && $0.start < row.endTs }
    }

    /// Carry the captured fields the add/edit sheet does NOT expose (maxHr, strain, distanceM,
    /// zonesJSON, notes) over from the row being edited. A v1.67 live-tracked session has real
    /// captured strain/maxHr; rebuilding the row from the sheet's five inputs alone would
    /// silently wipe them on any edit. No-op for a fresh add (old == nil).
    static func preservingCaptured(_ row: WorkoutRow, from old: WorkoutRow?) -> WorkoutRow {
        guard let old else { return row }
        return WorkoutRow(startTs: row.startTs, endTs: row.endTs, sport: row.sport,
                          source: row.source, durationS: row.durationS,
                          energyKcal: row.energyKcal, avgHr: row.avgHr,
                          maxHr: old.maxHr, strain: old.strain, distanceM: old.distanceM,
                          zonesJSON: old.zonesJSON, notes: old.notes)
    }

    /// Build a retroactive manual workout (source "manual", persisted under deviceId "my-whoop"
    /// by the caller — where v1.67's live sessions live). Nil when the input can't make an honest
    /// row; strain/zones stay nil (no captured HR window — APPROXIMATE figures are never fabricated).
    static func buildManualRow(start: Date, durationMin: Int, sport: String,
                               avgHr: Int?, energyKcal: Double?, now: Date = Date()) -> WorkoutRow? {
        guard durationMin > 0, durationMin <= 24 * 60 else { return nil }
        let trimmed = sport.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, start <= now else { return nil }
        if let hr = avgHr, !(25...250).contains(hr) { return nil }
        if let k = energyKcal, k < 0 || k > 20_000 { return nil }
        let s = Int(start.timeIntervalSince1970)
        guard s > 0 else { return nil }
        return WorkoutRow(startTs: s, endTs: s + durationMin * 60, sport: trimmed, source: "manual",
                          durationS: Double(durationMin) * 60, energyKcal: energyKcal,
                          avgHr: avgHr, maxHr: nil, strain: nil, distanceM: nil,
                          zonesJSON: nil, notes: nil)
    }
}
