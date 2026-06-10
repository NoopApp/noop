import Foundation
import WhoopStore

/// Origin of a workout row, classified from its stored `source` column. The macOS read model
/// (`WorkoutRow`) carries no `deviceId`, so the row's origin has to be recovered from `source`.
/// Stored values today:
///   - "whoop"        — WhoopImporter (imported WHOOP session)
///   - "apple_health" / "apple-health" — AppleHealthImport
///   - "manual"       — AppModel.endWorkout (v1.67 live session) AND the retro add/edit sheet
///   - "my-whoop-noop"— IntelligenceEngine detected bouts (source == the computed deviceId, i.e.
///                       it ends in "-noop"). These are re-derived every analyzeRecent run.
///
/// Classification order matters: "-noop" is checked BEFORE "whoop" because the computed id
/// "my-whoop-noop" also contains the substring "whoop".
enum WorkoutSource: Equatable {
    case whoop, apple, detected, manual

    static func classify(_ source: String) -> WorkoutSource {
        let s = source.lowercased()
        if s.hasSuffix("-noop") { return .detected }   // BEFORE whoop: "my-whoop-noop" contains "whoop"
        if s == "manual" { return .manual }
        if s.contains("whoop") { return .whoop }
        return .apple
    }

    /// Sport-cell text. The detector stores the machine token "detected"; show it as a neutral
    /// "Activity" (we don't claim a sport we didn't actually classify).
    static func displaySport(_ sport: String) -> String { sport == "detected" ? "Activity" : sport }

    // MARK: - Dismissed detected bouts (durable across re-detection)
    //
    // The engine wipes + re-derives "detected" rows every run, so deleting a detected row from the
    // table would only hide it until the next analyzeRecent recreates the same (startTs, sport) PK.
    // The durable "this isn't a workout" record is a list of dismissed time spans persisted in
    // UserDefaults (the macOS WorkoutRow lives in the WhoopStore Journal file, which this layer must
    // not extend with a new column). A detected row overlapping any dismissed span stays hidden.
    // (#107)

    /// UserDefaults key holding the dismissed spans as "startTs:endTs" strings.
    static let dismissedDefaultsKey = "workouts.dismissedDetected"

    /// Parse "startTs:endTs" spans (UserDefaults string array). Malformed / non-positive-width
    /// entries are dropped so a corrupt value can never hide everything.
    static func parseDismissedSpans(_ raw: [String]) -> [(start: Int, end: Int)] {
        raw.compactMap { s in
            let parts = s.split(separator: ":")
            guard parts.count == 2, let a = Int(parts[0]), let b = Int(parts[1]), b > a else { return nil }
            return (a, b)
        }
    }

    /// The "startTs:endTs" token persisted for a dismissed row (caller appends it to the defaults list).
    static func dismissedToken(for row: WorkoutRow) -> String { "\(row.startTs):\(row.endTs)" }

    /// Read-time filter: a DETECTED row overlapping any dismissed span is hidden. Imported / manual
    /// rows are never auto-hidden (the user deletes those outright), so dismissal only applies to the
    /// re-derived detected source. Half-open overlap test: `row.start < span.end && span.start < row.end`.
    static func isDismissed(_ row: WorkoutRow, spans: [(start: Int, end: Int)]) -> Bool {
        classify(row.source) == .detected
            && spans.contains { row.startTs < $0.end && $0.start < row.endTs }
    }

    // MARK: - Building / preserving rows

    /// Carry the captured fields the add/edit sheet does NOT expose (maxHr, strain, distanceM,
    /// zonesJSON, notes) over from the row being edited. A v1.67 live-tracked session has real
    /// captured strain/maxHr; rebuilding the row from the sheet's inputs alone would silently wipe
    /// them on an edit. No-op for a fresh add (`old == nil`).
    static func preservingCaptured(_ row: WorkoutRow, from old: WorkoutRow?) -> WorkoutRow {
        guard let old else { return row }
        return WorkoutRow(startTs: row.startTs, endTs: row.endTs, sport: row.sport,
                          source: row.source, durationS: row.durationS,
                          energyKcal: row.energyKcal, avgHr: row.avgHr,
                          maxHr: old.maxHr, strain: old.strain, distanceM: old.distanceM,
                          zonesJSON: old.zonesJSON, notes: old.notes)
    }

    /// Build a retroactive manual workout (source "manual", persisted under the strap deviceId by the
    /// caller — where v1.67's live sessions live). Returns nil when the input can't make an honest row.
    /// strain/zones stay nil: with no captured HR window an APPROXIMATE strain is never fabricated.
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
