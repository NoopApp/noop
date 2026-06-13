import SwiftUI
import StrandAnalytics
import StrandDesign
import WhoopStore

struct BodyVitalReading: Identifiable {
    let key: String
    let label: String
    let unit: String
    let value: Double?
    let format: (Double) -> String
    let banding: VitalBands.Result
    let metricColor: Color
    let day: String?
    let source: DailyMetricSource?
    let missingCaption: String

    var id: String { key }

    var formattedValue: String? {
        value.map { "\(format($0)) \(unit)" }
    }

    var accent: Color {
        switch banding.band {
        case .noData:     return StrandPalette.textTertiary
        case .inRange:    return metricColor
        case .outOfRange: return StrandPalette.statusWarning
        }
    }

    var stateCaption: String {
        guard let day else { return missingCaption }
        var parts = [Self.dayLabel(day)]
        if let sourceText = Self.sourceLabel(source, key: key) {
            parts.append(sourceText)
        }
        parts.append(stateText)
        return parts.joined(separator: " · ")
    }

    var accessibilityText: String {
        guard let v = formattedValue else { return "\(label): no data" }
        return "\(label): \(v), \(stateCaption)"
    }

    private var stateText: String {
        switch (banding.band, banding.basis) {
        case (.noData, _):               return String(localized: "No data")
        case (.inRange, .personal):      return String(localized: "In your range")
        case (.outOfRange, .personal):   return String(localized: "Off baseline")
        case (.inRange, .population):    return String(localized: "Typical range")
        case (.outOfRange, .population): return String(localized: "Outside range")
        }
    }

    private static func sourceLabel(_ source: DailyMetricSource?, key: String) -> String? {
        guard let source else { return nil }
        switch source {
        case .whoopImport:
            return String(localized: "WHOOP import")
        case .noopComputed:
            if key == "skin" { return String(localized: "Overnight computed") }
            return String(localized: "NOOP computed")
        case .appleHealth:
            return String(localized: "Apple Health")
        case .localCache:
            return nil
        }
    }

    static func dayLabel(_ day: String) -> String {
        if day == BodyVitalSigns.logicalDayKey(Date()) { return String(localized: "Today") }
        guard let date = BodyVitalSigns.dayParser.date(from: day) else { return day }
        return BodyVitalSigns.dayFormatter.string(from: date)
    }
}

enum BodyVitalSigns {
    static func readings(days: [DailyMetric],
                         today: DailyMetric?,
                         temperatureUnit: TemperatureUnit) -> [BodyVitalReading] {
        var sourceRows = days.map { SourcedDailyMetric(metric: $0, source: .localCache) }
        if let today, !days.contains(where: { $0.day == today.day }) {
            sourceRows.append(SourcedDailyMetric(metric: today, source: .localCache))
        }
        return readings(sourceRows: sourceRows, temperatureUnit: temperatureUnit)
    }

    static func readings(sourceRows: [SourcedDailyMetric],
                         temperatureUnit: TemperatureUnit,
                         now: Date = Date()) -> [BodyVitalReading] {
        let logicalDay = logicalDayKey(now)

        func points(key: String, _ value: (DailyMetric) -> Double?) -> [VitalPoint] {
            let allowedSources = DailyMetricSource.vitalPrecedence(for: key)
            var byDay: [String: VitalPoint] = [:]
            for source in allowedSources {
                for row in sourceRows where row.source == source {
                    guard let v = value(row.metric), byDay[row.metric.day] == nil else { continue }
                    byDay[row.metric.day] = VitalPoint(day: row.metric.day, value: v, source: row.source)
                }
            }
            return byDay.values.sorted { $0.day < $1.day }
        }

        func latest(_ pts: [VitalPoint]) -> VitalPoint? {
            pts.last(where: { $0.day == logicalDay }) ?? pts.last
        }

        func history(before day: String?, _ pts: [VitalPoint]) -> [Double?] {
            VitalBands.calendarSeries(pts.filter { point in
                guard let day else { return true }
                return point.day < day
            }.map { ($0.day, Optional($0.value)) })
        }

        let respPoints = points(key: "resp", \.respRateBpm)
        let spo2Points = points(key: "spo2", \.spo2Pct)
        let rhrPoints = points(key: "rhr") { $0.restingHr.map(Double.init) }
        let hrvPoints = points(key: "hrv", \.avgHrv)
        let skinPoints = points(key: "skin", \.skinTempDevC)

        let respRow = latest(respPoints)
        let spo2Row = latest(spo2Points)
        let rhrRow = latest(rhrPoints)
        let hrvRow = latest(hrvPoints)
        let skinRow = latest(skinPoints)

        let skin = skinRow?.value
        let skinIsAbsolute = skin.map(VitalBands.isAbsoluteSkinTemp) ?? true
        let skinResult: VitalBands.Result
        if let skin {
            skinResult = VitalBands.band(
                value: skin,
                history: VitalBands.skinTempHistory(matching: skin, in: history(before: skinRow?.day, skinPoints)),
                populationRange: skinIsAbsolute ? 33...36 : (-0.6)...0.6,
                cfg: skinIsAbsolute ? Baselines.metricCfg["skin_temp"]! : VitalBands.skinTempDeviationCfg
            )
        } else {
            skinResult = VitalBands.Result(band: .noData, basis: .population, nights: 0)
        }

        let skinUnitLabel = UnitFormatter.temperatureUnit(temperatureUnit)
        let skinFormat: (Double) -> String = { c in
            let full = skinIsAbsolute
                ? UnitFormatter.temperatureFromCelsius(c, unit: temperatureUnit, decimals: 1)
                : UnitFormatter.temperatureDeltaFromCelsius(c, unit: temperatureUnit, decimals: 1)
            return full.replacingOccurrences(of: " " + skinUnitLabel, with: "")
        }

        return [
            BodyVitalReading(
                key: "resp",
                label: "Resp Rate",
                unit: "rpm",
                value: respRow?.value,
                format: { String(format: "%.1f", $0) },
                banding: VitalBands.band(
                    value: respRow?.value,
                    history: history(before: respRow?.day, respPoints),
                    populationRange: 12...20,
                    cfg: Baselines.respCfg
                ),
                metricColor: StrandPalette.metricCyan,
                day: respRow?.day,
                source: respRow?.source,
                missingCaption: String(localized: "No respiratory-rate value")
            ),
            BodyVitalReading(
                key: "spo2",
                label: "Blood O2",
                unit: "%",
                value: spo2Row?.value,
                format: { String(format: "%.0f", $0) },
                banding: VitalBands.band(
                    value: spo2Row?.value,
                    history: [],
                    populationRange: 95...100,
                    cfg: nil
                ),
                metricColor: StrandPalette.metricCyan,
                day: spo2Row?.day,
                source: spo2Row?.source,
                missingCaption: String(localized: "No SpO2 import or Health value")
            ),
            BodyVitalReading(
                key: "rhr",
                label: "Resting HR",
                unit: "bpm",
                value: rhrRow?.value,
                format: { String(Int($0.rounded())) },
                banding: VitalBands.band(
                    value: rhrRow?.value,
                    history: history(before: rhrRow?.day, rhrPoints),
                    populationRange: 40...60,
                    cfg: Baselines.restingHRCfg
                ),
                metricColor: StrandPalette.metricRose,
                day: rhrRow?.day,
                source: rhrRow?.source,
                missingCaption: String(localized: "No resting HR value")
            ),
            BodyVitalReading(
                key: "hrv",
                label: "HRV",
                unit: "ms",
                value: hrvRow?.value,
                format: { String(Int($0.rounded())) },
                banding: VitalBands.band(
                    value: hrvRow?.value,
                    history: history(before: hrvRow?.day, hrvPoints),
                    populationRange: 40...120,
                    cfg: Baselines.hrvCfg
                ),
                metricColor: StrandPalette.metricPurple,
                day: hrvRow?.day,
                source: hrvRow?.source,
                missingCaption: String(localized: "No HRV value")
            ),
            BodyVitalReading(
                key: "skin",
                label: "Skin Temp",
                unit: skinUnitLabel,
                value: skin,
                format: skinFormat,
                banding: skinResult,
                metricColor: StrandPalette.metricAmber,
                day: skinRow?.day,
                source: skinRow?.source,
                missingCaption: String(localized: "No nightly skin-temp value")
            ),
        ]
    }

    static func latestDayLabel(_ readings: [BodyVitalReading]) -> String? {
        readings.compactMap(\.day).max().map(BodyVitalReading.dayLabel)
    }

    static func logicalDayKey(_ now: Date, rolloverHour: Int = 4) -> String {
        localDayFormatter.string(from: now.addingTimeInterval(-Double(rolloverHour) * 3_600))
    }

    private static let localDayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    static let dayParser: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "d MMM"
        return f
    }()
}

private struct VitalPoint: Equatable {
    let day: String
    let value: Double
    let source: DailyMetricSource
}

private extension DailyMetricSource {
    static func vitalPrecedence(for key: String) -> [DailyMetricSource] {
        switch key {
        case "skin":
            return [.whoopImport, .noopComputed, .localCache]
        default:
            return [.whoopImport, .noopComputed, .appleHealth, .localCache]
        }
    }
}
