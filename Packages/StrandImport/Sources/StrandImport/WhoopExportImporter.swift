import Foundation
import ZIPFoundation

/// Parses a Whoop data export (CSV bundle) into normalized Swift models.
///
/// The parser is header-name-driven and tolerant: columns are matched by
/// normalized header name (not position), every column is optional, UTF-8 BOMs
/// are stripped, and missing files / columns degrade gracefully. The schema is
/// identical across Whoop 4 / 5 / MG, so a single parser covers all three.
///
/// Input may be a folder (possibly nested or renamed) or a `.zip`. CSVs are
/// located **by filename**, case-insensitively, anywhere in the tree.
public struct WhoopExportImporter {

    public init() {}

    // Recognised CSV filenames (lowercased).
    private static let cyclesName  = "physiological_cycles.csv"
    private static let sleepsName  = "sleeps.csv"
    private static let workoutsName = "workouts.csv"
    private static let journalName = "journal_entries.csv"

    /// Map a known localized WHOOP export filename to its canonical English name. WHOOP localizes
    /// the CSV filenames in non-English exports (issue #3): a German export ships Schlaf.csv,
    /// Trainings.csv, physiologische_zyklen.csv, and logbuch_eintraege.csv.
    private static func localizedAlias(_ base: String) -> String? {
        switch base {
        case "physiologische_zyklen.csv": return cyclesName   // German (app.whoop.com → Daten exportieren)
        case "schlaf.csv":                return sleepsName
        case "trainings.csv":             return workoutsName
        case "logbuch_eintraege.csv":     return journalName
        // Spanish (issue #76): physiological_cycles.csv keeps its English name, but sleep/workouts are
        // renamed. Folded + unfolded variants since the filename is lowercased but not diacritic-folded.
        case "sueño.csv", "sueno.csv":    return sleepsName
        case "entrenamientos.csv":        return workoutsName
        // French (issue #79): physiological_cycles.csv keeps its English name; sleep/workouts renamed.
        case "sommeil.csv":               return sleepsName
        case "entrainements.csv", "entraînements.csv": return workoutsName
        default:                          return nil
        }
    }

    /// Classify a CSV by its header columns when the filename is unrecognised. Covers any language
    /// whose column headers stay English even when the filenames are translated.
    private static func sniffKind(_ data: Data) -> String? {
        let h = Set(CSVTable(data: data).normalizedHeaders)
        if h.contains("activity_name") || h.contains("workout_start_time") { return workoutsName }
        if h.contains("question_text") || h.contains("answered_yes_no") || h.contains("question") { return journalName }
        if h.contains("nap") && (h.contains("sleep_onset") || h.contains("wake_onset")) { return sleepsName }
        if h.contains("cycle_start_time") || h.contains("recovery_score_pct") || h.contains("day_strain") { return cyclesName }
        if h.contains("sleep_onset") || h.contains("asleep_duration_min") { return sleepsName }
        return nil
    }

    /// Canonical key for a candidate CSV: exact English name, then a localized alias, then content.
    private static func canonicalKey(base: String, data: Data) -> String? {
        let wanted: Set<String> = [cyclesName, sleepsName, workoutsName, journalName]
        if wanted.contains(base) { return base }
        if let a = localizedAlias(base) { return a }
        return sniffKind(data)
    }

    // MARK: - Public entry point

    /// Import from a folder or a `.zip` URL, returning all normalized rows plus
    /// a summary.
    public func `import`(from url: URL) throws -> WhoopImportResult {
        let csvData = try loadCSVData(from: url)

        var cycles: [WhoopCycleRow] = []
        var sleeps: [WhoopSleepRow] = []
        var workouts: [WhoopWorkoutRow] = []
        var journal: [WhoopJournalRow] = []

        if let data = csvData[Self.cyclesName] {
            cycles = parseCycles(CSVTable(data: data))
        }
        if let data = csvData[Self.sleepsName] {
            sleeps = parseSleeps(CSVTable(data: data))
        }
        if let data = csvData[Self.workoutsName] {
            workouts = parseWorkouts(CSVTable(data: data))
        }
        if let data = csvData[Self.journalName] {
            journal = parseJournal(CSVTable(data: data))
        }

        let summary = makeSummary(cycles: cycles, sleeps: sleeps, workouts: workouts, journal: journal)
        return WhoopImportResult(
            cycles: cycles, sleeps: sleeps, workouts: workouts, journal: journal, summary: summary
        )
    }

    // MARK: - Locate + load CSVs

    /// Return `[lowercasedFilename: rawData]` for every recognised CSV in the
    /// folder or zip at `url`.
    private func loadCSVData(from url: URL) throws -> [String: Data] {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        let exists = fm.fileExists(atPath: url.path, isDirectory: &isDir)
        guard exists else { throw ImportError.fileNotFound(url.path) }

        if isDir.boolValue {
            return try loadFromFolder(url)
        }

        // A file — treat as zip if it has a zip extension or opens as an archive.
        if url.pathExtension.lowercased() == "zip" {
            return try loadFromZip(url)
        }
        // Try as a zip anyway; if that fails, it's not a supported input.
        if let z = try? loadFromZip(url) { return z }
        throw ImportError.notAZipOrFolder(url.path)
    }

    private func loadFromFolder(_ folder: URL) throws -> [String: Data] {
        let fm = FileManager.default
        var result: [String: Data] = [:]

        guard let enumerator = fm.enumerator(
            at: folder,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            throw ImportError.fileNotFound(folder.path)
        }

        for case let fileURL as URL in enumerator {
            let base = fileURL.lastPathComponent.lowercased()
            guard base.hasSuffix(".csv") else { continue }   // skip GPX/ECG/etc.
            let size = (try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            if size > Self.maxEntryBytes { continue }   // refuse an implausibly large CSV
            guard let data = try? Data(contentsOf: fileURL) else { continue }
            // Route by English name, localized filename alias, then header content (issue #3).
            if let key = Self.canonicalKey(base: base, data: data), result[key] == nil {
                result[key] = data
            }
        }
        return result
    }

    /// Per-CSV uncompressed ceiling. Real Whoop CSV bundles are a few MB; this guards against a
    /// zip-bomb where a tiny entry inflates to many GB and OOM-kills the app.
    private static let maxEntryBytes = 256 << 20   // 256 MB

    private func loadFromZip(_ zipURL: URL) throws -> [String: Data] {
        let archive: Archive
        do {
            archive = try Archive(url: zipURL, accessMode: .read)
        } catch {
            throw ImportError.notAZipOrFolder(zipURL.path)
        }

        var result: [String: Data] = [:]

        for entry in archive {
            guard entry.type == .file else { continue }
            let base = (entry.path as NSString).lastPathComponent.lowercased()
            guard base.hasSuffix(".csv") else { continue }   // skip GPX/ECG/etc.
            // Reject entries whose declared uncompressed size is implausible (zip-bomb guard)...
            let declared = Int(exactly: entry.uncompressedSize) ?? Int.max
            if declared > Self.maxEntryBytes { continue }
            var buffer = Data()
            var written = 0
            do {
                // extract() verifies CRC32 (skipCRC32 defaults to false) and throws on a
                // mismatch/truncation; the running budget also stops a lying ZIP64 header mid-stream.
                _ = try archive.extract(entry) { chunk in
                    written += chunk.count
                    if written > Self.maxEntryBytes { throw CancellationError() }
                    buffer.append(chunk)
                }
            } catch {
                // Corrupt / truncated / oversized entry: skip rather than import partial data.
                continue
            }
            guard !buffer.isEmpty else { continue }
            // Route by English name, localized filename alias, then header content (issue #3).
            if let key = Self.canonicalKey(base: base, data: buffer), result[key] == nil {
                result[key] = buffer
            }
        }
        return result
    }

    // MARK: - physiological_cycles.csv

    func parseCycles(_ table: CSVTable) -> [WhoopCycleRow] {
        var out: [WhoopCycleRow] = []
        out.reserveCapacity(table.rows.count)
        for row in table.rows {
            let tz = WhoopTime.tzOffsetMinutes(row.cell("cycle_timezone"))

            var r = WhoopCycleRow()
            r.tzOffsetMin = tz
            r.cycleStart = WhoopTime.parse(row.cell("cycle_start_time"), offsetMinutes: tz)
            r.cycleEnd   = WhoopTime.parse(row.cell("cycle_end_time"), offsetMinutes: tz)

            // Skip rows with no usable timestamp at all.
            if r.cycleStart == nil && r.cycleEnd == nil { continue }

            r.recoveryScore    = row.double("recovery_score_pct")
            r.restingHeartRate = row.double("resting_heart_rate_bpm", "resting_heart_rate")
            r.hrvMs            = row.double("heart_rate_variability_ms", "heart_rate_variability_rmssd_ms")
            r.skinTempCelsius  = row.double("skin_temp_celsius", "skin_temp_f")
            r.bloodOxygenPct   = row.double("blood_oxygen_pct", "blood_oxygen_pct_pct")
            r.dayStrain        = row.double("day_strain")
            r.energyKcal       = row.double("energy_burned_cal")  // CSV "(cal)" == kcal
            r.avgHeartRate     = row.double("average_hr_bpm", "average_heart_rate_bpm")
            r.maxHeartRate     = row.double("max_hr_bpm", "max_heart_rate_bpm")

            r.sleepOnset = WhoopTime.parse(row.cell("sleep_onset"), offsetMinutes: tz)
            r.wakeOnset  = WhoopTime.parse(row.cell("wake_onset"), offsetMinutes: tz)

            r.sleepPerformancePct = row.double("sleep_performance_pct")
            r.respiratoryRate     = row.double("respiratory_rate_rpm", "respiratory_rate")
            r.asleepDurationMin   = row.double("asleep_duration_min")
            r.inBedDurationMin    = row.double("in_bed_duration_min")
            r.lightSleepDurationMin = row.double("light_sleep_duration_min")
            r.deepSleepDurationMin  = row.double("deep_sws_duration_min", "deep_sleep_duration_min")
            r.remDurationMin        = row.double("rem_duration_min")
            r.awakeDurationMin      = row.double("awake_duration_min")
            r.sleepEfficiencyPct    = row.double("sleep_efficiency_pct")
            r.sleepConsistencyPct   = row.double("sleep_consistency_pct")
            r.sleepNeedMin          = row.double("sleep_need_min")
            r.sleepDebtMin          = row.double("sleep_debt_min")

            out.append(r)
        }
        return out
    }

    // MARK: - sleeps.csv

    func parseSleeps(_ table: CSVTable) -> [WhoopSleepRow] {
        var out: [WhoopSleepRow] = []
        out.reserveCapacity(table.rows.count)
        for row in table.rows {
            let tz = WhoopTime.tzOffsetMinutes(row.cell("cycle_timezone"))

            var r = WhoopSleepRow()
            r.tzOffsetMin = tz
            r.cycleStart = WhoopTime.parse(row.cell("cycle_start_time"), offsetMinutes: tz)
            r.sleepOnset = WhoopTime.parse(row.cell("sleep_onset"), offsetMinutes: tz)
            r.wakeOnset  = WhoopTime.parse(row.cell("wake_onset"), offsetMinutes: tz)

            if r.cycleStart == nil && r.sleepOnset == nil && r.wakeOnset == nil { continue }

            r.isNap = row.bool("nap") ?? false

            r.sleepPerformancePct = row.double("sleep_performance_pct")
            r.respiratoryRate     = row.double("respiratory_rate_rpm", "respiratory_rate")
            r.asleepDurationMin   = row.double("asleep_duration_min")
            r.inBedDurationMin    = row.double("in_bed_duration_min")
            r.lightSleepDurationMin = row.double("light_sleep_duration_min")
            r.deepSleepDurationMin  = row.double("deep_sws_duration_min", "deep_sleep_duration_min")
            r.remDurationMin        = row.double("rem_duration_min")
            r.awakeDurationMin      = row.double("awake_duration_min")
            r.sleepEfficiencyPct    = row.double("sleep_efficiency_pct")
            r.sleepConsistencyPct   = row.double("sleep_consistency_pct")
            r.sleepNeedMin          = row.double("sleep_need_min")
            r.sleepDebtMin          = row.double("sleep_debt_min")

            out.append(r)
        }
        return out
    }

    // MARK: - workouts.csv

    func parseWorkouts(_ table: CSVTable) -> [WhoopWorkoutRow] {
        var out: [WhoopWorkoutRow] = []
        out.reserveCapacity(table.rows.count)
        for row in table.rows {
            let tz = WhoopTime.tzOffsetMinutes(row.cell("cycle_timezone"))

            var r = WhoopWorkoutRow()
            r.tzOffsetMin = tz
            r.cycleStart   = WhoopTime.parse(row.cell("cycle_start_time"), offsetMinutes: tz)
            r.workoutStart = WhoopTime.parse(row.cell("workout_start_time"), offsetMinutes: tz)
            r.workoutEnd   = WhoopTime.parse(row.cell("workout_end_time"), offsetMinutes: tz)

            if r.workoutStart == nil && r.workoutEnd == nil && r.cycleStart == nil { continue }

            r.activityName   = row.cell("activity_name")
            r.activityStrain = row.double("activity_strain")
            r.energyKcal     = row.double("energy_burned_cal")  // CSV "(cal)" == kcal
            r.avgHeartRate   = row.double("average_hr_bpm", "average_heart_rate_bpm")
            r.maxHeartRate   = row.double("max_hr_bpm", "max_heart_rate_bpm")

            r.hrZone1Pct = row.double("hr_zone_1_pct", "zone_1_pct", "hr_zone_1_pct_pct")
            r.hrZone2Pct = row.double("hr_zone_2_pct", "zone_2_pct", "hr_zone_2_pct_pct")
            r.hrZone3Pct = row.double("hr_zone_3_pct", "zone_3_pct", "hr_zone_3_pct_pct")
            r.hrZone4Pct = row.double("hr_zone_4_pct", "zone_4_pct", "hr_zone_4_pct_pct")
            r.hrZone5Pct = row.double("hr_zone_5_pct", "zone_5_pct", "hr_zone_5_pct_pct")

            // Optional GPS / distance / altitude columns.
            r.distanceMeters       = row.double("distance_meters", "distance_meter")
            r.altitudeGainMeters   = row.double("altitude_gain_meters", "altitude_gain_meter")
            r.altitudeChangeMeters = row.double("altitude_change_meters", "altitude_change_meter")

            out.append(r)
        }
        return out
    }

    // MARK: - journal_entries.csv

    func parseJournal(_ table: CSVTable) -> [WhoopJournalRow] {
        var out: [WhoopJournalRow] = []
        out.reserveCapacity(table.rows.count)
        for row in table.rows {
            let tz = WhoopTime.tzOffsetMinutes(row.cell("cycle_timezone"))

            var r = WhoopJournalRow()
            r.tzOffsetMin = tz
            r.cycleStart = WhoopTime.parse(row.cell("cycle_start_time"), offsetMinutes: tz)
            r.question = row.cell("question_text", "question")
            r.answer   = row.cell("answered_yes_no", "answer", "answer_text")
            r.notes    = row.cell("notes")

            // A journal row is only meaningful if it has a question.
            if r.question == nil && r.answer == nil && r.notes == nil { continue }
            out.append(r)
        }
        return out
    }

    // MARK: - Summary

    private func makeSummary(
        cycles: [WhoopCycleRow],
        sleeps: [WhoopSleepRow],
        workouts: [WhoopWorkoutRow],
        journal: [WhoopJournalRow]
    ) -> ImportSummary {
        var dates: [Date] = []
        dates.append(contentsOf: cycles.compactMap { $0.cycleStart })
        dates.append(contentsOf: sleeps.compactMap { $0.sleepOnset ?? $0.cycleStart })
        dates.append(contentsOf: workouts.compactMap { $0.workoutStart ?? $0.cycleStart })
        dates.append(contentsOf: journal.compactMap { $0.cycleStart })

        let count = cycles.count + sleeps.count + workouts.count + journal.count
        return ImportSummary(
            sourceKind: .whoopExport,
            recordCount: count,
            earliest: dates.min(),
            latest: dates.max(),
            countsByCategory: [
                "cycles": cycles.count,
                "sleeps": sleeps.count,
                "workouts": workouts.count,
                "journal": journal.count,
            ]
        )
    }
}
