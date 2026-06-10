import Foundation
#if canImport(AppKit)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif
import UniformTypeIdentifiers
import WhoopStore
import StrandImport

/// Settings → Backup & restore → "Export CSV…": serialize the merged "my-whoop" ∪ "my-whoop-noop"
/// history (imported wins per day — exactly what the dashboards show; Apple Health rows are
/// deliberately EXCLUDED so a re-import can't mis-attribute them as WHOOP data) into WHOOP's
/// 4-CSV zip via StrandImport.WhoopCsvExporter. The zip re-imports into NOOP on Mac (Data Sources →
/// WHOOP Export) and on Android. On-device computed rows are marked "noop (APPROXIMATE)" in the
/// Source column both importers ignore; the .sqlite backup remains the lossless restore path.
///
/// Self-contained: it reads through the store handle and reconstructs Repository's merge precedence
/// inline rather than depending on Repository's private merge helpers, so the export is decoupled
/// from the dashboard read path.
enum CsvExport {
    enum ExportResult {
        case exported(URL)
        case cancelled
        case failure(String)
    }

    @MainActor
    static func run(repo: Repository) async -> ExportResult {
        guard let store = await repo.storeHandle() else {
            return .failure("Couldn't open the local store.")
        }
        let deviceId = repo.deviceId
        // The on-device computed source id (recovery/strain/sleep derived from raw streams). This
        // mirrors Repository.computedDeviceId, which is private — so we reconstruct the same string.
        let computedId = deviceId + "-noop"
        let fromDay = "0000-01-01", toDay = "9999-12-31"
        let hi = Int(Date().timeIntervalSince1970) + 86_400

        do {
            // Merged exactly like Repository.mergeDaily: computed first, imported overwrites — so a
            // real WHOOP import always wins and the strap-only user still exports a full history.
            let imported = try await store.dailyMetrics(deviceId: deviceId, from: fromDay, to: toDay)
            let computed = try await store.dailyMetrics(deviceId: computedId, from: fromDay, to: toDay)
            var byDay: [String: DailyMetric] = [:]
            var sourceByDay: [String: String] = [:]
            for d in computed { byDay[d.day] = d; sourceByDay[d.day] = "noop (APPROXIMATE)" }
            for d in imported { byDay[d.day] = d; sourceByDay[d.day] = "import" }
            let days = byDay.values.sorted { $0.day < $1.day }

            // The cycles columns DailyMetric lacks, recovered from the imported metricSeries.
            var series: [String: [String: Double]] = [:]
            for key in ["sleep_performance", "sleep_consistency", "sleep_need_min", "sleep_debt_min",
                        "in_bed_min", "awake_min", "energy_kcal", "avg_hr", "max_hr"] {
                for p in (try await store.metricSeries(deviceId: deviceId, key: key,
                                                       from: fromDay, to: toDay)) {
                    series[p.day, default: [:]][key] = p.value
                }
            }

            // Sleep: merged per end-day, imported wins (Repository.mergeSleep semantics).
            let impSleep = try await store.sleepSessions(deviceId: deviceId, from: 0, to: hi, limit: 100_000)
            let compSleep = try await store.sleepSessions(deviceId: computedId, from: 0, to: hi, limit: 100_000)
            var sleepByDay: [String: CachedSleepSession] = [:]
            var sleepSource: [Int: String] = [:]   // keyed by startTs (the session's natural key)
            func endDay(_ s: CachedSleepSession) -> String {
                Repository.localDayKey(Date(timeIntervalSince1970: TimeInterval(s.endTs)))
            }
            for s in compSleep { sleepByDay[endDay(s)] = s; sleepSource[s.startTs] = "noop (APPROXIMATE)" }
            for s in impSleep { sleepByDay[endDay(s)] = s; sleepSource[s.startTs] = "import" }
            let sleeps = sleepByDay.values.sorted { $0.startTs < $1.startTs }

            // Workouts: imported WHOOP ∪ on-device detected. Apple-Health workouts are intentionally
            // omitted (read only the two NOOP sources), matching the cycles/sleep exclusion.
            let workouts = (try await store.workouts(deviceId: deviceId, from: 0, to: hi, limit: 100_000))
                + (try await store.workouts(deviceId: computedId, from: 0, to: hi, limit: 100_000))

            // Journal lives under the imported deviceId (WhoopImporter writes it there). Native
            // in-app journal logging is an Android/PR-#97 feature not present in this Mac build, so
            // the imported read is the complete on-Mac journal today.
            let journal = try await store.journalEntries(deviceId: deviceId, from: fromDay, to: toDay)

            // Sidecar: every metricSeries row under both NOOP sources, full fidelity.
            var sidecar: [String: [MetricPoint]] = [:]
            for id in [deviceId, computedId] {
                var points: [MetricPoint] = []
                for key in (try await store.metricKeys(deviceId: id)) {
                    points += try await store.metricSeries(deviceId: id, key: key, from: fromDay, to: toDay)
                }
                if !points.isEmpty { sidecar[id] = points }
            }

            let entries: [(name: String, data: Data)] = [
                ("physiological_cycles.csv",
                 Data(WhoopCsvExporter.cyclesCSV(days: days, series: series, sourceByDay: sourceByDay).utf8)),
                ("sleeps.csv",
                 Data(WhoopCsvExporter.sleepsCSV(sleeps, sourceBySession: { sleepSource[$0.startTs] ?? "" }).utf8)),
                ("workouts.csv",
                 Data(WhoopCsvExporter.workoutsCSV(workouts, sourceLabel: { workoutSource($0, computedId: computedId) }).utf8)),
                ("journal_entries.csv", Data(WhoopCsvExporter.journalCSV(journal).utf8)),
                ("noop_metric_series.json", WhoopCsvExporter.metricSeriesJSON(sidecar)),
            ]
            #if os(macOS)
            // Save panel — DataBackup.runExport precedent (NSSavePanel + .zip content type).
            let panel = NSSavePanel()
            panel.title = "Export NOOP data as CSV"
            panel.nameFieldStringValue = defaultName()
            panel.allowedContentTypes = [.zip]
            panel.canCreateDirectories = true
            guard panel.runModal() == .OK, let dest = panel.url else { return .cancelled }
            // NSSavePanel already confirmed overwrite; remove the stale file so Archive(.create) gets
            // a clean path (it appends to, rather than truncates, an existing zip).
            if FileManager.default.fileExists(atPath: dest.path) {
                try FileManager.default.removeItem(at: dest)
            }
            try WhoopCsvExporter.writeArchive(entries: entries, to: dest)
            return .exported(dest)
            #else
            // iOS: stage the zip in a temp dir, hand it to the system document picker so the user can
            // save it into Files / iCloud Drive (DataBackup.runExport precedent).
            let staged = FileManager.default.temporaryDirectory.appendingPathComponent(defaultName())
            if FileManager.default.fileExists(atPath: staged.path) {
                try FileManager.default.removeItem(at: staged)
            }
            try WhoopCsvExporter.writeArchive(entries: entries, to: staged)
            guard let dest = await DocumentPicker.export(staged) else { return .cancelled }
            return .exported(dest)
            #endif
        } catch {
            return .failure("CSV export failed: \(error.localizedDescription)")
        }
    }

    /// Classify a workout row for the parser-ignored Source column. The strings match how each row
    /// is written on this Mac: WhoopImporter uses source "whoop"; AppModel manual logging uses
    /// "manual"; IntelligenceEngine's on-device detected workouts use the computed source id with
    /// sport "detected".
    private static func workoutSource(_ w: WorkoutRow, computedId: String) -> String {
        if w.source == "manual" { return "manual" }
        if w.source == computedId || w.sport == "detected" { return "noop (APPROXIMATE)" }
        return "import"
    }

    // @MainActor: Repository.localDayKey is MainActor-isolated (Repository is @MainActor); only
    // called from `run`, which already is.
    @MainActor
    private static func defaultName() -> String {
        "noop-export-\(Repository.localDayKey(Date())).zip"
    }
}
