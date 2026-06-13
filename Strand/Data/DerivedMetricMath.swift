import Foundation
import StrandAnalytics
import WhoopProtocol
import WhoopStore

enum DerivedMetricMath {
    static let defaultSleepNeedMin = AnalyticsEngine.Rest.defaultNeedHours * 60.0

    static func normalizedPercent(_ value: Double) -> Double {
        value <= 1.5 ? value * 100.0 : value
    }

    static func normalizedFraction(_ value: Double) -> Double {
        value > 1.5 ? value / 100.0 : value
    }

    static func dailyMetricValue(_ row: DailyMetric, key: String) -> Double? {
        switch key {
        case "recovery":
            return row.recovery
        case "strain":
            return row.strain
        case "sleep_performance":
            return sleepPerformance(row)
        case "sleep_total_min":
            return row.totalSleepMin
        case "asleep_min":
            return row.totalSleepMin
        case "in_bed_min":
            return inBedMinutes(row)
        case "sleep_efficiency":
            return row.efficiency.map(normalizedPercent)
        case "sleep_deep_min":
            return row.deepMin
        case "deep_min":
            return row.deepMin
        case "sleep_rem_min":
            return row.remMin
        case "rem_min":
            return row.remMin
        case "sleep_light_min":
            return row.lightMin
        case "core_min":
            return row.lightMin
        case "restorative_min":
            return restorativeMinutes(row)
        case "restorative_pct":
            guard let restorative = restorativeMinutes(row),
                  let total = row.totalSleepMin,
                  total > 0 else { return nil }
            return restorative / total * 100.0
        case "hours_vs_needed_pct":
            guard let total = row.totalSleepMin, total > 0,
                  let need = sleepNeedMinutes(row), need > 0 else { return nil }
            return total / need * 100.0
        case "sleep_need_min":
            return sleepNeedMinutes(row)
        case "sleep_debt_min":
            guard let total = row.totalSleepMin,
                  let need = sleepNeedMinutes(row) else { return nil }
            return max(0, need - total)
        case "rhr", "resting_hr":
            return row.restingHr.map(Double.init)
        case "hrv":
            return row.avgHrv
        case "spo2":
            return row.spo2Pct
        case "skin_temp":
            return row.skinTempDevC
        case "resp_rate":
            return row.respRateBpm
        case "steps":
            return row.steps.map(Double.init)
        case "active_kcal", "energy_kcal":
            return row.activeKcalEst
        default:
            return nil
        }
    }

    static func metricPoints(from row: DailyMetric, stress: Double? = nil) -> [MetricPoint] {
        let keys = [
            "recovery",
            "strain",
            "sleep_performance",
            "sleep_total_min",
            "in_bed_min",
            "sleep_efficiency",
            "sleep_deep_min",
            "sleep_rem_min",
            "sleep_light_min",
            "restorative_min",
            "restorative_pct",
            "hours_vs_needed_pct",
            "sleep_need_min",
            "sleep_debt_min",
            "rhr",
            "hrv",
            "spo2",
            "skin_temp",
            "resp_rate",
            "steps",
            "active_kcal",
            "energy_kcal",
        ]

        var points = keys.compactMap { key -> MetricPoint? in
            guard let value = dailyMetricValue(row, key: key), value.isFinite else { return nil }
            return MetricPoint(day: row.day, key: key, value: rounded(value))
        }
        if let stress, stress.isFinite {
            points.append(MetricPoint(day: row.day, key: "stress", value: rounded(stress)))
        }
        return points
    }

    static func heartRateProfilePoints(day: String, samples: [HRSample],
                                       age: Double, maxHROverride: Double?) -> [MetricPoint] {
        guard !samples.isEmpty else { return [] }
        let bpms = samples.map { Double($0.bpm) }
        let avg = bpms.reduce(0, +) / Double(bpms.count)
        let maxBpm = bpms.max() ?? avg
        let zones = HRZones.timeInZone(
            samples,
            zoneSet: HRZones.zones(age: age, maxHROverride: maxHROverride)
        )
        let minutes = zones.seconds.map { $0 / 60.0 }
        let zone13 = minutes.prefix(3).reduce(0, +)
        let zone45 = minutes.suffix(2).reduce(0, +)
        let allZones = minutes.reduce(0, +)

        var points = [
            MetricPoint(day: day, key: "avg_hr", value: rounded(avg)),
            MetricPoint(day: day, key: "max_hr", value: rounded(maxBpm)),
            MetricPoint(day: day, key: "hr_zones13_min", value: rounded(zone13)),
            MetricPoint(day: day, key: "hr_zones45_min", value: rounded(zone45)),
            MetricPoint(day: day, key: "hr_zones_all_min", value: rounded(allZones)),
        ]
        for idx in 0..<min(5, minutes.count) {
            points.append(MetricPoint(day: day, key: "hr_zone\(idx + 1)_min", value: rounded(minutes[idx])))
        }
        return points
    }

    static func stressScore(daily: DailyMetric,
                            hrvBaseline: BaselineState?,
                            rhrBaseline: BaselineState?) -> Double? {
        var raw = 0.0
        var hasSignal = false
        if let rhr = daily.restingHr.map(Double.init),
           let baseline = rhrBaseline,
           baseline.usable {
            raw += Baselines.deviation(rhr, state: baseline).z
            hasSignal = true
        }
        if let hrv = daily.avgHrv,
           let baseline = hrvBaseline,
           baseline.usable {
            raw -= Baselines.deviation(hrv, state: baseline).z
            hasSignal = true
        }
        guard hasSignal else { return nil }
        return StressMath.squash(raw)
    }

    private static func restorativeMinutes(_ row: DailyMetric) -> Double? {
        if row.deepMin == nil && row.remMin == nil { return nil }
        return (row.deepMin ?? 0) + (row.remMin ?? 0)
    }

    private static func inBedMinutes(_ row: DailyMetric) -> Double? {
        guard let total = row.totalSleepMin,
              let efficiency = row.efficiency.map(normalizedFraction),
              efficiency > 0.01 else { return nil }
        return total / efficiency
    }

    private static func sleepNeedMinutes(_ row: DailyMetric) -> Double? {
        guard row.totalSleepMin != nil
            || row.efficiency != nil
            || row.deepMin != nil
            || row.remMin != nil
            || row.lightMin != nil else { return nil }
        return defaultSleepNeedMin
    }

    private static func sleepPerformance(_ row: DailyMetric) -> Double? {
        guard let total = row.totalSleepMin,
              total > 0,
              let efficiency = row.efficiency.map(normalizedFraction) else { return nil }
        let restorative = restorativeMinutes(row) ?? 0
        return AnalyticsEngine.Rest.composite(
            tstSeconds: total * 60.0,
            inBedSeconds: inBedMinutes(row).map { $0 * 60.0 } ?? (total * 60.0 / max(efficiency, 0.01)),
            efficiency: efficiency,
            restorativeSeconds: restorative * 60.0,
            needHours: AnalyticsEngine.Rest.defaultNeedHours,
            consistency: nil
        )
    }

    private static func rounded(_ value: Double) -> Double {
        (value * 100.0).rounded() / 100.0
    }
}

// MARK: - Stress math

enum StressMath {
    static func mean(_ xs: [Double]) -> Double? {
        guard !xs.isEmpty else { return nil }
        return xs.reduce(0, +) / Double(xs.count)
    }

    static func std(_ xs: [Double], mean m: Double?) -> Double {
        guard let m, xs.count > 1 else { return 0 }
        let v = xs.map { ($0 - m) * ($0 - m) }.reduce(0, +) / Double(xs.count)
        return v.squareRoot()
    }

    static func rawScore(
        rhrToday: Double?, meanRHR: Double?, sdRHR: Double,
        hrvToday: Double?, meanHRV: Double?, sdHRV: Double
    ) -> Double {
        var sum = 0.0
        if let r = rhrToday, let m = meanRHR, sdRHR > 0.0001 {
            sum += (r - m) / sdRHR
        }
        if let h = hrvToday, let m = meanHRV, sdHRV > 0.0001 {
            sum += (m - h) / sdHRV
        }
        return sum
    }

    static func squash(_ raw: Double) -> Double {
        let s = 3.0 / (1.0 + exp(-raw))
        return min(max(s, 0), 3)
    }
}
