import Foundation
import ZIPFoundation
import WhoopStore

/// Serializes NOOP's own cached rows back into WHOOP's 4-CSV export shape so NOOP's OWN importer
/// (WhoopExportImporter here, WhoopCsvImporter on Android) re-imports them losslessly. The
/// round-trip is the whole point and is pinned by WhoopCsvExporterTests, which re-parses this
/// output with the REAL importer and asserts field-level equality — so any header/format drift
/// fails a test rather than silently producing an un-reimportable zip.
///
/// Header strings are byte-identical to a real WHOOP export (the importer normalises them down to
/// `recovery_score_pct` etc., so they must match exactly). Everything is emitted in UTC with a
/// literal "UTC+00:00" timezone column: NOOP stores epoch seconds and tz-less day strings, so UTC
/// is the only encoding that round-trips a timestamp to the same instant. A trailing "Source"
/// column (which both parsers provably ignore — they key off named columns, never position) marks
/// on-device computed rows as "noop (APPROXIMATE)" per the house rules. A noop_metric_series.json
/// sidecar carries the full metricSeries for fidelity and is deliberately NOT re-imported — the
/// .sqlite backup remains the lossless restore path; this zip is the portable, WHOOP-shaped one.
public enum WhoopCsvExporter {

    // MARK: - Primitives

    /// RFC-4180 quoting: only quote when the field carries a comma, quote, CR or LF; escape an
    /// embedded `"` by doubling it. The importer's CSVTable parser is the consumer, so this is the
    /// minimal escaping it round-trips.
    static func field(_ raw: String?) -> String {
        guard let raw, !raw.isEmpty else { return "" }
        guard raw.contains(",") || raw.contains("\"") || raw.contains("\n") || raw.contains("\r") else {
            return raw
        }
        return "\"" + raw.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    /// Locale-proof numbers: integral Doubles print without a trailing ".0" (matching how WHOOP
    /// exports whole numbers), and String(Double) always uses '.' as the separator regardless of
    /// the user's locale — so the importer's Double() parse can't be defeated by a comma decimal.
    static func num(_ v: Double?) -> String {
        guard let v else { return "" }
        return v == v.rounded() && abs(v) < 1e12 ? String(Int64(v)) : String(v)
    }

    static func num(_ v: Int?) -> String { v.map(String.init) ?? "" }

    /// Fixed UTC formatter — one instance, en_US_POSIX so the date format is stable across locales.
    private static let utcFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(secondsFromGMT: 0)
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }()

    static func utc(_ ts: Int) -> String {
        utcFormatter.string(from: Date(timeIntervalSince1970: TimeInterval(ts)))
    }

    // MARK: - Tolerant decoders for the cache's polymorphic JSON columns

    /// Stage minutes recovered from any persisted stagesJSON shape NOOP has ever written:
    ///   - {"light":min,…}            — macOS WHOOP import (WhoopImporter)
    ///   - [{"stage","min"}]          — Android import / demo seeds
    ///   - [{"start","end","stage"}]  — the on-device SleepStager ("wake" == awake)
    /// Unusable / empty input → all-nil, so the column exports blank rather than a bogus zero.
    struct StageMinutes {
        var light: Double?, deep: Double?, rem: Double?, awake: Double?
        /// Asleep = light+deep+rem, but only if at least one of those is present (a sleep with
        /// only an "awake" figure shouldn't claim 0 minutes asleep).
        var asleep: Double? {
            if light == nil && deep == nil && rem == nil { return nil }
            return (light ?? 0) + (deep ?? 0) + (rem ?? 0)
        }
    }

    static func stageMinutes(_ stagesJSON: String?) -> StageMinutes {
        let none = StageMinutes(light: nil, deep: nil, rem: nil, awake: nil)
        guard let stagesJSON, let data = stagesJSON.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) else { return none }
        // Dict shape: minutes already aggregated per stage.
        if let dict = obj as? [String: Any] {
            func g(_ k: String) -> Double? { (dict[k] as? NSNumber)?.doubleValue }
            return StageMinutes(light: g("light"), deep: g("deep"), rem: g("rem"),
                                awake: g("awake") ?? g("wake"))
        }
        // Array shape: either per-stage minutes, or start/end segments to sum.
        guard let arr = obj as? [[String: Any]] else { return none }
        var l = 0.0, d = 0.0, r = 0.0, a = 0.0
        var any = false
        for seg in arr {
            let stage = (seg["stage"] as? String)?.lowercased() ?? ""
            let minutes: Double
            if let m = (seg["min"] as? NSNumber)?.doubleValue {
                minutes = m
            } else if let s = (seg["start"] as? NSNumber)?.doubleValue,
                      let e = (seg["end"] as? NSNumber)?.doubleValue {
                minutes = (e - s) / 60.0
            } else {
                continue
            }
            any = true
            switch stage {
            case "light":         l += minutes
            case "deep", "sws":   d += minutes
            case "rem":           r += minutes
            case "awake", "wake": a += minutes
            default:              break
            }
        }
        return any ? StageMinutes(light: l, deep: d, rem: r, awake: a) : none
    }

    /// Z1–Z5 percents from zonesJSON. macOS import writes "z1"…"z5"; Android writes "zone1"…"zone5".
    /// nil when the row carries no usable zone data, so the columns export blank.
    static func zonePercents(_ zonesJSON: String?) -> [Double]? {
        guard let zonesJSON, let data = zonesJSON.data(using: .utf8),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return nil }
        let p = (1...5).map { i -> Double in
            ((obj["z\(i)"] ?? obj["zone\(i)"]) as? NSNumber)?.doubleValue ?? 0
        }
        return p.contains(where: { $0 > 0 }) ? p : nil
    }

    // MARK: - The four CSVs (headers byte-identical to a real WHOOP export)

    /// physiological_cycles.csv. `series` is day -> (metricSeries key -> value), carrying the
    /// cycles-only columns DailyMetric doesn't store (sleep performance/consistency/need/debt,
    /// in-bed, energy, avg/max HR). `sourceByDay` feeds the trailing, parser-ignored Source column.
    public static func cyclesCSV(days: [DailyMetric],
                                 series: [String: [String: Double]],
                                 sourceByDay: [String: String] = [:]) -> String {
        var out = "Cycle start time,Cycle end time,Cycle timezone,Recovery score %,"
            + "Resting heart rate (bpm),Heart rate variability (ms),Skin temp (celsius),"
            + "Blood oxygen %,Day Strain,Energy burned (cal),Max HR (bpm),Average HR (bpm),"
            + "Sleep onset,Wake onset,Sleep performance %,Respiratory rate (rpm),"
            + "Asleep duration (min),In bed duration (min),Light sleep duration (min),"
            + "Deep (SWS) duration (min),REM duration (min),Awake duration (min),"
            + "Sleep efficiency %,Sleep consistency %,Sleep need (min),Sleep debt (min),Source\r\n"
        for d in days.sorted(by: { $0.day < $1.day }) {
            let s = series[d.day] ?? [:]
            let cols: [String] = [
                d.day + " 00:00:00", "", "UTC+00:00",
                num(d.recovery), num(d.restingHr), num(d.avgHrv), num(d.skinTempDevC), num(d.spo2Pct),
                num(d.strain), num(s["energy_kcal"]), num(s["max_hr"]), num(s["avg_hr"]),
                "", "",                              // sleep/wake onset live in sleeps.csv, not here
                num(s["sleep_performance"]), num(d.respRateBpm), num(d.totalSleepMin), num(s["in_bed_min"]),
                num(d.lightMin), num(d.deepMin), num(d.remMin),
                num(s["awake_min"] ?? d.disturbances.map(Double.init)),
                num(d.efficiency), num(s["sleep_consistency"]), num(s["sleep_need_min"]),
                num(s["sleep_debt_min"]),
                field(sourceByDay[d.day]),
            ]
            out += cols.joined(separator: ",") + "\r\n"
        }
        return out
    }

    /// sleeps.csv. Stage durations come from the tolerant stagesJSON decoder; in-bed is derived
    /// from the session span when the row carries no explicit figure.
    public static func sleepsCSV(_ sessions: [CachedSleepSession],
                                 sourceBySession: (CachedSleepSession) -> String = { _ in "" }) -> String {
        var out = "Cycle start time,Sleep onset,Wake onset,Cycle timezone,Nap,Sleep performance %,"
            + "Respiratory rate (rpm),Asleep duration (min),In bed duration (min),"
            + "Light sleep duration (min),Deep (SWS) duration (min),REM duration (min),"
            + "Awake duration (min),Sleep efficiency %,Sleep consistency %,"
            + "Sleep need (min),Sleep debt (min),Source\r\n"
        for s in sessions.sorted(by: { $0.startTs < $1.startTs }) {
            let stages = stageMinutes(s.stagesJSON)
            let inBedMin: Double? = s.endTs > s.startTs ? Double(s.endTs - s.startTs) / 60.0 : nil
            let cols: [String] = [
                utc(s.startTs), utc(s.startTs), utc(s.endTs), "UTC+00:00",
                // NOOP never stores a nap flag — everything exports as a main sleep so the importer
                // keeps it (it drops `isNap` rows).
                "false", "", "",
                num(stages.asleep), num(inBedMin),
                num(stages.light), num(stages.deep), num(stages.rem), num(stages.awake),
                num(s.efficiency), "", "", "",
                field(sourceBySession(s)),
            ]
            out += cols.joined(separator: ",") + "\r\n"
        }
        return out
    }

    /// workouts.csv. `sourceLabel` classifies each row for the trailing Source column.
    public static func workoutsCSV(_ rows: [WorkoutRow],
                                   sourceLabel: (WorkoutRow) -> String = { _ in "" }) -> String {
        var out = "Cycle start time,Workout start time,Workout end time,Cycle timezone,"
            + "Activity name,Activity Strain,Energy burned (cal),Max HR (bpm),"
            + "Average HR (bpm),HR Zone 1 %,HR Zone 2 %,HR Zone 3 %,HR Zone 4 %,"
            + "HR Zone 5 %,Distance (meters),Source\r\n"
        for w in rows.sorted(by: { $0.startTs < $1.startTs }) {
            let zones = zonePercents(w.zonesJSON)
            let cols: [String] = [
                utc(w.startTs), utc(w.startTs), utc(w.endTs), "UTC+00:00",
                field(w.sport), num(w.strain), num(w.energyKcal), num(w.maxHr), num(w.avgHr),
                num(zones?[0]), num(zones?[1]), num(zones?[2]), num(zones?[3]), num(zones?[4]),
                num(w.distanceM),
                field(sourceLabel(w)),
            ]
            out += cols.joined(separator: ",") + "\r\n"
        }
        return out
    }

    /// journal_entries.csv. The importer reads the answer as `lowercased() == "true"`, so the
    /// answer column MUST be the literal "true"/"false" — never prettify it to Yes/No.
    public static func journalCSV(_ rows: [JournalEntry]) -> String {
        var out = "Cycle start time,Cycle timezone,Question text,Answered yes/no,Notes\r\n"
        for e in rows.sorted(by: { ($0.day, $0.question) < ($1.day, $1.question) }) {
            let cols: [String] = [
                e.day + " 00:00:00", "UTC+00:00", field(e.question),
                e.answeredYes ? "true" : "false",
                field(e.notes),
            ]
            out += cols.joined(separator: ",") + "\r\n"
        }
        return out
    }

    /// Full-fidelity metricSeries dump ({deviceId, day, key, value}). The sidecar is documentation /
    /// fidelity only; the importers deliberately ignore it (they only read the four CSVs). Sorted
    /// for a stable, diffable file.
    public static func metricSeriesJSON(_ points: [String: [MetricPoint]]) -> Data {
        var rows: [[String: Any]] = []
        for deviceId in points.keys.sorted() {
            for p in (points[deviceId] ?? []).sorted(by: { ($0.day, $0.key) < ($1.day, $1.key) }) {
                rows.append(["deviceId": deviceId, "day": p.day, "key": p.key, "value": p.value])
            }
        }
        return (try? JSONSerialization.data(withJSONObject: rows,
                                            options: [.prettyPrinted, .sortedKeys])) ?? Data("[]".utf8)
    }

    // MARK: - Archive

    /// Write the entries into a fresh zip at `url`. Each entry's bytes are provided in slices via
    /// ZIPFoundation's provider closure (the data is already fully in memory).
    public static func writeArchive(entries: [(name: String, data: Data)], to url: URL) throws {
        let archive = try Archive(url: url, accessMode: .create)
        for e in entries {
            try archive.addEntry(with: e.name, type: .file,
                                 uncompressedSize: Int64(e.data.count),
                                 provider: { position, size in
                                     e.data.subdata(in: Int(position)..<(Int(position) + size))
                                 })
        }
    }
}
