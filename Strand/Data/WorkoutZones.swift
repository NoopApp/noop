import Foundation
import WhoopStore

// MARK: - Imported per-workout HR zones
//
// `zonesJSON` is the verbatim HR-zone-percentage object from the WHOOP CSV import
// (WhoopImporter writes "z1"…"z5"; the Android importer writes "zone1"…"zone5" for the
// same data — tolerate both so a cache moved between platforms still renders). Values
// are 0–100 percent of the workout's duration and may sum to less than 100 (time below
// zone 1 is not exported).
enum WorkoutZones {

    /// Z1…Z5 percentages (0–100) for one workout, or nil when the row carries no usable zone data.
    static func percents(_ zonesJSON: String?) -> [Double]? {
        guard let zonesJSON,
              let data = zonesJSON.data(using: .utf8),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return nil }
        let p = (1...5).map { i -> Double in
            let v = (obj["z\(i)"] ?? obj["zone\(i)"]) as? NSNumber
            return min(max(v?.doubleValue ?? 0, 0), 100)
        }
        return p.contains(where: { $0 > 0 }) ? p : nil
    }

    /// Duration-weighted zone minutes across rows. Mirrors the daily-metric derivation in
    /// WhoopImporter (duration-minutes × pct ÷ 100). APPROXIMATE: an on-device aggregate of
    /// the imported per-workout percentages, not a WHOOP-computed figure.
    struct Summary {
        let minutes: [Double]          // index 0 = Z1 … 4 = Z5
        let sessionsWithZones: Int
        var totalMinutes: Double { minutes.reduce(0, +) }
    }

    static func summary(from rows: [WorkoutRow]) -> Summary? {
        var mins = [Double](repeating: 0, count: 5)
        var n = 0
        for r in rows {
            guard let p = percents(r.zonesJSON) else { continue }
            let durMin = (r.durationS ?? Double(r.endTs - r.startTs)) / 60.0
            guard durMin > 0 else { continue }
            for i in 0..<5 { mins[i] += durMin * p[i] / 100.0 }
            n += 1
        }
        guard n > 0, mins.reduce(0, +) > 0 else { return nil }
        return Summary(minutes: mins, sessionsWithZones: n)
    }
}
