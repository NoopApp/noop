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
        guard let day else { return String(localized: "No data") }
        return "\(Self.dayLabel(day)) · \(stateText)"
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

    static func dayLabel(_ day: String) -> String {
        if day == BodyVitalSigns.logicalDayKey(Date()) { return String(localized: "Today") }
        guard let date = BodyVitalSigns.dayParser.date(from: day) else { return day }
        return BodyVitalSigns.dayFormatter.string(from: date)
    }
}

enum BodyVitalSigns {
    static func readings(
        days: [DailyMetric],
        today: DailyMetric?,
        temperatureUnit: TemperatureUnit
    ) -> [BodyVitalReading] {
        let sorted = days.sorted { $0.day < $1.day }

        func latest(_ value: (DailyMetric) -> Double?) -> DailyMetric? {
            if let today, value(today) != nil { return today }
            return sorted.last(where: { value($0) != nil })
        }

        func history(before day: String?, _ value: (DailyMetric) -> Double?) -> [Double?] {
            let rows = sorted.filter { row in
                guard let day else { return true }
                return row.day < day
            }
            return VitalBands.calendarSeries(rows.map { ($0.day, value($0)) })
        }

        let respRow = latest(\.respRateBpm)
        let spo2Row = latest(\.spo2Pct)
        let rhrRow = latest { $0.restingHr.map(Double.init) }
        let hrvRow = latest(\.avgHrv)
        let skinRow = latest(\.skinTempDevC)

        let skin = skinRow?.skinTempDevC
        let skinIsAbsolute = skin.map(VitalBands.isAbsoluteSkinTemp) ?? true
        let skinResult: VitalBands.Result
        if let skin {
            skinResult = VitalBands.band(
                value: skin,
                history: VitalBands.skinTempHistory(matching: skin, in: history(before: skinRow?.day, \.skinTempDevC)),
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
                value: respRow?.respRateBpm,
                format: { String(format: "%.1f", $0) },
                banding: VitalBands.band(
                    value: respRow?.respRateBpm,
                    history: history(before: respRow?.day, \.respRateBpm),
                    populationRange: 12...20,
                    cfg: Baselines.respCfg
                ),
                metricColor: StrandPalette.metricCyan,
                day: respRow?.day
            ),
            BodyVitalReading(
                key: "spo2",
                label: "Blood O2",
                unit: "%",
                value: spo2Row?.spo2Pct,
                format: { String(format: "%.0f", $0) },
                banding: VitalBands.band(
                    value: spo2Row?.spo2Pct,
                    history: [],
                    populationRange: 95...100,
                    cfg: nil
                ),
                metricColor: StrandPalette.metricCyan,
                day: spo2Row?.day
            ),
            BodyVitalReading(
                key: "rhr",
                label: "Resting HR",
                unit: "bpm",
                value: rhrRow?.restingHr.map(Double.init),
                format: { String(Int($0.rounded())) },
                banding: VitalBands.band(
                    value: rhrRow?.restingHr.map(Double.init),
                    history: history(before: rhrRow?.day) { $0.restingHr.map(Double.init) },
                    populationRange: 40...60,
                    cfg: Baselines.restingHRCfg
                ),
                metricColor: StrandPalette.metricRose,
                day: rhrRow?.day
            ),
            BodyVitalReading(
                key: "hrv",
                label: "HRV",
                unit: "ms",
                value: hrvRow?.avgHrv,
                format: { String(Int($0.rounded())) },
                banding: VitalBands.band(
                    value: hrvRow?.avgHrv,
                    history: history(before: hrvRow?.day, \.avgHrv),
                    populationRange: 40...120,
                    cfg: Baselines.hrvCfg
                ),
                metricColor: StrandPalette.metricPurple,
                day: hrvRow?.day
            ),
            BodyVitalReading(
                key: "skin",
                label: "Skin Temp",
                unit: skinUnitLabel,
                value: skin,
                format: skinFormat,
                banding: skinResult,
                metricColor: StrandPalette.metricAmber,
                day: skinRow?.day
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
