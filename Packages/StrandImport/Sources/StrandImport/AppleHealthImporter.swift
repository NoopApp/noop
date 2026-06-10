import Foundation
import ZIPFoundation

/// Parses an Apple Health export (`export.xml`, possibly inside `export.zip`)
/// into normalized Swift models using a **streaming SAX parser**
/// (`XMLParser`/`XMLParserDelegate`) — never a DOM, because the file can exceed
/// 1 GB.
///
/// Behaviour (per Strand design spec §3.1 / §7.1):
/// - Maintains an element stack to track nesting (`Correlation`, `Workout`,
///   `MetadataEntry`, etc.).
/// - Filters to the relevant `Record` types only.
/// - `OxygenSaturation` is a 0–1 fraction → multiplied by 100.
/// - `SleepAnalysis` category values mapped to `SleepStage`.
/// - **Dedupe:** records nested inside a `<Correlation>` also appear at top
///   level → only top-level records are ingested, and a final dedupe pass on
///   `type+start+end+source+value` removes any residual duplicates.
/// - Dates `yyyy-MM-dd HH:mm:ss Z` parsed with `Locale(en_US_POSIX)`.
public struct AppleHealthImporter {

    public init() {}

    /// Health types Strand cares about (prefix already stripped).
    public static let relevantTypes: Set<String> = [
        "HeartRate",
        "RestingHeartRate",
        "HeartRateVariabilitySDNN",
        "WalkingHeartRateAverage",
        "OxygenSaturation",
        "BodyTemperature",
        "AppleSleepingWristTemperature",
        "RespiratoryRate",
        "ActiveEnergyBurned",
        "BasalEnergyBurned",
        "VO2Max",
        "StepCount",
        "SleepAnalysis",
        // Body composition
        "BodyMass",
        "BodyFatPercentage",
        "LeanBodyMass",
        "BodyMassIndex",
    ]

    // MARK: - Public entry points

    /// Import from `export.zip` or a path to `export.xml` (or a folder
    /// containing it).
    public func `import`(from url: URL) throws -> AppleHealthImportResult {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else {
            throw ImportError.fileNotFound(url.path)
        }

        if isDir.boolValue {
            guard let xmlURL = findExportXML(inFolder: url) else {
                throw ImportError.missingEntry("export.xml")
            }
            return try importXML(at: xmlURL)
        }

        let ext = url.pathExtension.lowercased()
        if ext == "xml" {
            return try importXML(at: url)
        }
        if ext == "zip" {
            return try importZip(at: url)
        }
        // Unknown extension: try zip first, then raw XML.
        if let z = try? importZip(at: url) { return z }
        return try importXML(at: url)
    }

    /// Stream-parse a raw `export.xml` file.
    public func importXML(at xmlURL: URL) throws -> AppleHealthImportResult {
        // Sanitize first (#100): NSXMLParser cannot recover from a single malformed byte, and
        // multi-source exports are known to contain them (unescaped quotes from legacy third-party
        // apps → libxml error 65, control bytes, bad charrefs, malformed DTD subsets). The
        // sanitizer streams disk→disk so RAM stays bounded; clean input passes byte-identical.
        let clean = FileManager.default.temporaryDirectory
            .appendingPathComponent("noop-health-clean-\(UUID().uuidString).xml")
        defer { try? FileManager.default.removeItem(at: clean) }
        try HealthXMLSanitizer().sanitize(input: xmlURL, output: clean)
        // Stream from disk via an InputStream rather than XMLParser(contentsOf:), which would load
        // the entire (multi-hundred-MB) file into memory before parsing.
        guard let stream = InputStream(url: clean) else {
            throw ImportError.fileNotFound(clean.path)
        }
        return try runParser(XMLParser(stream: stream))
    }

    /// Parse a `Data` blob of XML (used for the zip-streaming path and tests).
    public func importXML(data: Data) throws -> AppleHealthImportResult {
        let (clean, _) = HealthXMLSanitizer().sanitize(data: data)   // same tolerance as the file path
        let parser = XMLParser(data: clean)
        return try runParser(parser)
    }

    // MARK: - Zip handling

    private func importZip(at zipURL: URL) throws -> AppleHealthImportResult {
        let archive: Archive
        do {
            archive = try Archive(url: zipURL, accessMode: .read)
        } catch {
            throw ImportError.notAZipOrFolder(zipURL.path)
        }

        // Locate the export.xml entry by filename anywhere in the archive
        // (Apple nests it under apple_health_export/).
        var target: Entry?
        for entry in archive where entry.type == .file {
            if (entry.path as NSString).lastPathComponent.lowercased() == "export.xml" {
                target = entry
                break
            }
        }
        guard let entry = target else { throw ImportError.missingEntry("export.xml") }

        // Decompress export.xml to a temp file (chunks go straight to disk, so RAM stays bounded),
        // then stream-parse it from disk. This replaces a pipe-fed background parser that could
        // deadlock or crash with a broken-pipe exception on a malformed/malicious export.
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("noop-health-\(UUID().uuidString).xml")
        FileManager.default.createFile(atPath: tmp.path, contents: nil)
        guard let handle = try? FileHandle(forWritingTo: tmp) else {
            throw ImportError.xmlParseFailed("could not open a temp file for import")
        }
        defer { try? FileManager.default.removeItem(at: tmp) }

        var written = 0
        let cap = 8 << 30   // 8 GB decompressed ceiling (real exports are < 2 GB) — zip-bomb guard
        do {
            _ = try archive.extract(entry, bufferSize: 1 << 20) { chunk in
                written += chunk.count
                if written > cap { throw ImportError.xmlParseFailed("export.xml too large") }
                try handle.write(contentsOf: chunk)
            }
        } catch {
            try? handle.close()
            throw ImportError.xmlParseFailed("could not read export.xml from zip: \(error.localizedDescription)")
        }
        try? handle.close()

        return try importXML(at: tmp)
    }

    // MARK: - Core parse

    private func runParser(_ parser: XMLParser) throws -> AppleHealthImportResult {
        let delegate = HealthXMLDelegate()
        parser.delegate = delegate
        parser.shouldProcessNamespaces = false
        let ok = parser.parse()
        if !ok || delegate.parseError != nil {
            let base = delegate.parseError?.localizedDescription
                ?? parser.parserError?.localizedDescription
                ?? "unknown error"
            // Line/column make a mid-file failure in a multi-GB export diagnosable from the
            // user's screenshot alone (#100) — previously both were discarded.
            let msg = "\(base) (line \(parser.lineNumber), column \(parser.columnNumber))"
            throw ImportError.xmlParseFailed(msg)
        }
        return delegate.makeResult()
    }

    private func findExportXML(inFolder folder: URL) -> URL? {
        let fm = FileManager.default
        // Common location first.
        let direct = folder.appendingPathComponent("export.xml")
        if fm.fileExists(atPath: direct.path) { return direct }
        let nested = folder.appendingPathComponent("apple_health_export/export.xml")
        if fm.fileExists(atPath: nested.path) { return nested }
        // Otherwise search.
        if let e = fm.enumerator(at: folder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) {
            for case let u as URL in e where u.lastPathComponent.lowercased() == "export.xml" {
                return u
            }
        }
        return nil
    }
}

// MARK: - SAX delegate

final class HealthXMLDelegate: NSObject, XMLParserDelegate {

    // Outputs
    private(set) var samples: [HealthSample] = []
    private(set) var workouts: [HealthWorkout] = []
    private(set) var sleepIntervals: [SleepStageInterval] = []
    private(set) var countsByType: [String: Int] = [:]
    private(set) var parseError: Error?

    // Element nesting stack (just the element names).
    private var stack: [String] = []
    // Depth of the current Correlation, if inside one. Records nested inside a
    // Correlation are skipped (they also appear top-level).
    private var correlationDepth = 0

    // Dedupe set over HealthSample dedupeKeys.
    private var seenSampleKeys: Set<String> = []

    private let dateParser = HealthDateParser()

    // MARK: XMLParserDelegate

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String]
    ) {
        let parentIsCorrelation = (stack.last == "Correlation")
        stack.append(elementName)

        // Drain per-element: a multi-year export.xml has tens of millions of elements, each
        // bridging an attribute dictionary + temporaries (date parsing). Without a pool these
        // accumulate until parse() returns, inflating peak memory. Pool drains every element.
        autoreleasepool {
            switch elementName {
            case "Correlation":
                correlationDepth += 1

            case "Record":
                // Skip records nested inside a Correlation (deduped to top-level).
                if parentIsCorrelation || correlationDepth > 0 {
                    return
                }
                handleRecord(attributeDict)

            case "Workout":
                handleWorkout(attributeDict)

            default:
                break
            }
        }
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        if elementName == "Correlation", correlationDepth > 0 {
            correlationDepth -= 1
        }
        if stack.last == elementName {
            stack.removeLast()
        }
    }

    func parser(_ parser: XMLParser, parseErrorOccurred parseError: Error) {
        // Ignore benign "no data" / EOF style errors that can occur when the
        // streaming pipe closes; only record genuine malformed-XML errors.
        let ns = parseError as NSError
        if ns.domain == XMLParser.errorDomain {
            // Code 5 == NSXMLParserPrematureDocumentEndError can happen on empty
            // streams; treat truly empty as non-fatal only if we parsed nothing.
            if ns.code == XMLParser.ErrorCode.prematureDocumentEndError.rawValue,
               samples.isEmpty, workouts.isEmpty, sleepIntervals.isEmpty {
                self.parseError = parseError
                return
            }
        }
        self.parseError = parseError
    }

    // MARK: Record handling

    private func handleRecord(_ attrs: [String: String]) {
        guard let rawType = attrs["type"] else { return }
        let type = Self.stripPrefix(rawType)
        guard AppleHealthImporter.relevantTypes.contains(type) else { return }

        guard
            let startStr = attrs["startDate"],
            let endStr = attrs["endDate"],
            let (start, _) = dateParser.parse(startStr),
            let (end, endOffset) = dateParser.parse(endStr)
        else { return }

        let source = attrs["sourceName"]
        let unit = attrs["unit"]
        let rawValue = attrs["value"]

        if type == "SleepAnalysis" {
            // Sleep is a category record; its value is a stage enum string.
            let stage = SleepStage.from(rawValue: rawValue ?? "")
            let interval = SleepStageInterval(
                stage: stage,
                start: start,
                end: end,
                tzOffsetMin: endOffset,
                sourceName: source
            )
            sleepIntervals.append(interval)
            countsByType[type, default: 0] += 1

            // Also record a generic sample so the row survives in the sink with
            // its raw value string (dedupe-protected).
            appendSample(
                type: type,
                value: nil,
                valueString: rawValue,
                unit: unit,
                start: start,
                end: end,
                tzOffsetMin: endOffset,
                sourceName: source
            )
            return
        }

        var numeric = rawValue.flatMap { Double($0) }
        // OxygenSaturation is a 0–1 fraction → percent.
        if type == "OxygenSaturation", let v = numeric {
            numeric = v * 100.0
        }

        appendSample(
            type: type,
            value: numeric,
            valueString: rawValue,
            unit: unit,
            start: start,
            end: end,
            tzOffsetMin: endOffset,
            sourceName: source
        )
        countsByType[type, default: 0] += 1
    }

    private func appendSample(
        type: String,
        value: Double?,
        valueString: String?,
        unit: String?,
        start: Date,
        end: Date,
        tzOffsetMin: Int,
        sourceName: String?
    ) {
        let sample = HealthSample(
            type: type,
            value: value,
            valueString: valueString,
            unit: unit,
            start: start,
            end: end,
            tzOffsetMin: tzOffsetMin,
            sourceName: sourceName
        )
        // Dedupe on type+start+end+source+value.
        if seenSampleKeys.insert(sample.dedupeKey).inserted {
            samples.append(sample)
        }
    }

    // MARK: Workout handling

    private func handleWorkout(_ attrs: [String: String]) {
        guard
            let startStr = attrs["startDate"],
            let endStr = attrs["endDate"],
            let (start, _) = dateParser.parse(startStr),
            let (end, endOffset) = dateParser.parse(endStr)
        else { return }

        let rawActivity = attrs["workoutActivityType"] ?? "Unknown"
        let activity = Self.stripPrefix(rawActivity)

        var durationS: Double?
        if let dStr = attrs["duration"], let d = Double(dStr) {
            // durationUnit is typically "min"; default to minutes per Apple's export.
            let unit = (attrs["durationUnit"] ?? "min").lowercased()
            switch unit {
            case "min": durationS = d * 60.0
            case "sec", "s": durationS = d
            case "hr", "h": durationS = d * 3600.0
            default: durationS = d * 60.0
            }
        }

        let distanceM = attrs["totalDistance"].flatMap { Double($0) }.map { meters -> Double in
            let unit = (attrs["totalDistanceUnit"] ?? "km").lowercased()
            switch unit {
            case "km": return meters * 1000.0
            case "mi": return meters * 1609.344
            case "m":  return meters
            default:   return meters * 1000.0
            }
        }

        let energyKcal = attrs["totalEnergyBurned"].flatMap { Double($0) }
        // Apple exports energy in kcal by default (totalEnergyBurnedUnit "kcal").

        let workout = HealthWorkout(
            activityType: activity,
            durationS: durationS,
            distanceM: distanceM,
            energyKcal: energyKcal,
            start: start,
            end: end,
            tzOffsetMin: endOffset,
            sourceName: attrs["sourceName"]
        )
        workouts.append(workout)
        countsByType["Workout", default: 0] += 1
    }

    // MARK: Result

    func makeResult() -> AppleHealthImportResult {
        var dates: [Date] = []
        dates.append(contentsOf: samples.map { $0.start })
        dates.append(contentsOf: workouts.map { $0.start })
        dates.append(contentsOf: sleepIntervals.map { $0.start })

        let summary = ImportSummary(
            sourceKind: .appleHealth,
            recordCount: samples.count + workouts.count,
            earliest: dates.min(),
            latest: dates.max(),
            countsByCategory: countsByType
        )
        return AppleHealthImportResult(
            samples: samples,
            workouts: workouts,
            sleepIntervals: sleepIntervals,
            summary: summary
        )
    }

    // MARK: Helpers

    /// Strip the HealthKit identifier prefix from a type string.
    /// `HKQuantityTypeIdentifierHeartRate` → `HeartRate`,
    /// `HKCategoryTypeIdentifierSleepAnalysis` → `SleepAnalysis`,
    /// `HKWorkoutActivityTypeRunning` → `Running`.
    static func stripPrefix(_ raw: String) -> String {
        let prefixes = [
            "HKQuantityTypeIdentifier",
            "HKCategoryTypeIdentifier",
            "HKDataTypeIdentifier",
            "HKWorkoutActivityType",
        ]
        for p in prefixes where raw.hasPrefix(p) {
            return String(raw.dropFirst(p.count))
        }
        return raw
    }
}

// MARK: - Date parsing for Apple Health

/// Parses Apple Health dates `yyyy-MM-dd HH:mm:ss Z` (space before a colon-less
/// offset) with `en_US_POSIX`, returning a UTC `Date` plus the original offset
/// in minutes.
final class HealthDateParser {
    private let formatter: DateFormatter

    init() {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = Calendar(identifier: .gregorian)
        f.dateFormat = "yyyy-MM-dd HH:mm:ss Z"
        self.formatter = f
    }

    /// Returns (utcDate, offsetMinutes).
    func parse(_ raw: String) -> (Date, Int)? {
        guard let date = formatter.date(from: raw) else {
            // Fallback: try a few alternative shapes (ISO-8601, no seconds).
            return parseFallback(raw)
        }
        return (date, Self.offsetMinutes(from: raw))
    }

    private func parseFallback(_ raw: String) -> (Date, Int)? {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        if let d = iso.date(from: raw) {
            return (d, Self.offsetMinutes(from: raw))
        }
        return nil
    }

    /// Extract the trailing numeric UTC offset (`+0100`, `-0500`, `+01:00`, `Z`)
    /// from a date string, in minutes.
    static func offsetMinutes(from raw: String) -> Int {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        if trimmed.hasSuffix("Z") || trimmed.hasSuffix("z") { return 0 }
        // Offset is the last token; look for the sign within the last ~6 chars.
        let tail = String(trimmed.suffix(6))
        guard let signRange = tail.range(of: "[+-]", options: .regularExpression) else {
            return 0
        }
        let offStr = String(tail[signRange.lowerBound...])
        let sign = offStr.hasPrefix("-") ? -1 : 1
        let digits = offStr.dropFirst().filter { $0.isNumber }
        guard digits.count >= 2 else { return 0 }
        let s = String(digits)
        var hours = 0, minutes = 0
        if s.count >= 4 {
            hours = Int(s.prefix(2)) ?? 0
            minutes = Int(s.dropFirst(2).prefix(2)) ?? 0
        } else {
            hours = Int(s.prefix(2)) ?? 0
        }
        return sign * (hours * 60 + minutes)
    }
}
