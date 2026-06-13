import Foundation

/// One interrogable metric: how to fetch it (key+source), how to label/format it, and whether
/// higher is better (drives delta tinting). The Metric Explorer + Compare are built from this list.
struct MetricDescriptor: Identifiable, Hashable {
    let key: String
    let title: String
    let category: String
    let unit: String
    let source: String       // "my-whoop" or "apple-health"
    let icon: String
    let decimals: Int
    let higherIsBetter: Bool?
    var id: String { source + ":" + key }

    func format(_ v: Double) -> String {
        let n = decimals == 0 ? String(Int(v.rounded())) : String(format: "%.\(decimals)f", v)
        return unit.isEmpty ? n : "\(n) \(unit)"
    }

    /// Unit-aware format: for the three SI-stored metrics that have a non-metric counterpart
    /// (weight/lean_mass in kg, skin_temp in °C) convert + relabel via `UnitFormatter`. Every other
    /// metric (%, bpm, ms, min, …) is unit-agnostic and falls through to the plain `format` above, so
    /// the imperial toggle only ever touches the values that actually have an imperial form.
    func format(_ v: Double, system: UnitSystem, temperature: TemperatureUnit) -> String {
        switch unit {
        case "kg":  return UnitFormatter.massFromKilograms(v, system: system)
        case "°C":  return UnitFormatter.temperatureFromCelsius(v, unit: temperature, decimals: decimals)
        default:    return format(v)
        }
    }

    /// Like `format`, but for a DIFFERENCE between two values (e.g. the Δ StatTile). A temperature
    /// delta scales by 9/5 with NO +32 offset; mass/distance deltas scale by their plain factor. The
    /// caller supplies the magnitude (sign is rendered separately).
    func formatDelta(_ v: Double, system: UnitSystem, temperature: TemperatureUnit) -> String {
        switch unit {
        case "kg":  return UnitFormatter.massFromKilograms(v, system: system)
        case "°C":  return UnitFormatter.temperatureDeltaFromCelsius(v, unit: temperature, decimals: decimals)
        default:    return format(v)
        }
    }

    /// The unit LABEL as displayed (e.g. the trailing chip in the Metric Explorer list), mapped to the
    /// active system. Only the convertible units change; everything else returns its stored label.
    func displayUnit(system: UnitSystem, temperature: TemperatureUnit) -> String {
        switch unit {
        case "kg":  return UnitFormatter.massUnit(system)
        case "°C":  return UnitFormatter.temperatureUnit(temperature)
        default:    return unit
        }
    }
}

struct MetricSourceCandidate: Equatable, Hashable, Sendable {
    let source: String
    let key: String
}

struct MetricSourceSeries {
    let candidate: MetricSourceCandidate
    let rows: [(day: String, value: Double)]
}

struct ResolvedMetricPoint: Equatable, Sendable {
    let day: String
    let value: Double
    let source: String
    let sourceKey: String
}

struct MetricSeriesResolution: Equatable, Sendable {
    let requestedSource: String
    let candidates: [MetricSourceCandidate]
    let points: [ResolvedMetricPoint]

    var values: [(day: String, value: Double)] {
        points.map { ($0.day, $0.value) }
    }

    var usedSources: [String] {
        var seen = Set<String>()
        var ordered: [String] = []
        for point in points where !seen.contains(point.source) {
            seen.insert(point.source)
            ordered.append(point.source)
        }
        return ordered
    }

    var sourceCaption: String {
        let sources = usedSources
        guard !sources.isEmpty else {
            return candidates.first.map { MetricCatalog.sourceTitle($0.source) } ?? MetricCatalog.sourceTitle(requestedSource)
        }
        return sources.map(MetricCatalog.sourceTitle).joined(separator: " + ")
    }
}

/// Canonical catalog — mirrors the WHOOP "Trend View" plus Apple Health body metrics.
/// Keys match exactly what the importers write into metricSeries.
enum MetricCatalog {
    static let whoopSource = "my-whoop"
    static let appleHealthSource = "apple-health"
    static let nutritionSource = "nutrition-csv"
    static let moodSource = "noop-mood"

    static let categories = ["Heart", "Charge", "Rest", "Effort", "Health", "Nutrition", "Mind"]

    static let all: [MetricDescriptor] = [
        // ── Heart
        d("avg_hr", "Average Heart Rate", "Heart", "bpm", "my-whoop", "heart", 0, nil),
        d("max_hr", "Max Heart Rate", "Heart", "bpm", "my-whoop", "bolt.heart", 0, nil),
        d("energy_kcal", "Calories", "Heart", "kcal", "my-whoop", "flame", 0, nil),
        d("vo2max", "VO₂ Max", "Heart", "", "apple-health", "lungs.fill", 1, true),

        // ── Charge (was Recovery)
        d("recovery", "Charge", "Charge", "%", "my-whoop", "heart.circle", 0, true),
        d("hrv", "Heart Rate Variability", "Charge", "ms", "my-whoop", "waveform.path.ecg", 0, true),
        d("rhr", "Resting Heart Rate", "Charge", "bpm", "my-whoop", "heart", 0, false),
        d("resp_rate", "Respiratory Rate", "Charge", "rpm", "my-whoop", "lungs", 1, nil),
        d("spo2", "Blood Oxygen", "Charge", "%", "my-whoop", "drop", 0, true),
        d("skin_temp", "Skin Temperature", "Charge", "°C", "my-whoop", "thermometer", 1, nil),

        // ── Rest (was Sleep)
        d("sleep_performance", "Rest", "Rest", "%", "my-whoop", "moon.stars", 0, true),
        d("in_bed_min", "Time in Bed", "Rest", "min", "my-whoop", "bed.double", 0, nil),
        d("sleep_total_min", "Asleep Time", "Rest", "min", "my-whoop", "moon.zzz", 0, true),
        d("hours_vs_needed_pct", "Hours vs Needed", "Rest", "%", "my-whoop", "gauge.medium", 0, true),
        d("sleep_consistency", "Sleep Consistency", "Rest", "%", "my-whoop", "calendar", 0, true),
        d("restorative_pct", "Restorative Sleep", "Rest", "%", "my-whoop", "sparkles", 0, true),
        d("restorative_min", "Restorative Sleep", "Rest", "min", "my-whoop", "sparkles", 0, true),
        d("sleep_efficiency", "Sleep Efficiency", "Rest", "%", "my-whoop", "bed.double.fill", 0, true),
        d("sleep_deep_min", "Deep (SWS) Sleep", "Rest", "min", "my-whoop", "moon.fill", 0, true),
        d("sleep_rem_min", "REM Sleep", "Rest", "min", "my-whoop", "moon.haze", 0, true),
        d("sleep_light_min", "Light Sleep", "Rest", "min", "my-whoop", "moon", 0, nil),
        d("sleep_need_min", "Sleep Need", "Rest", "min", "my-whoop", "gauge", 0, nil),
        d("sleep_debt_min", "Sleep Debt", "Rest", "min", "my-whoop", "exclamationmark.circle", 0, false),

        // ── Effort (was Strain)
        d("strain", "Effort", "Effort", "/100", "my-whoop", "flame", 1, nil),
        d("steps", "Steps", "Effort", "", "apple-health", "figure.walk", 0, true),
        d("hr_zones13_min", "HR Zones 1–3", "Effort", "min", "my-whoop", "heart", 0, nil),
        d("hr_zones45_min", "HR Zones 4–5", "Effort", "min", "my-whoop", "heart.fill", 0, nil),
        d("hr_zones_all_min", "HR Zones (All)", "Effort", "min", "my-whoop", "heart.text.square", 0, nil),
        d("strength_min", "Strength Activity Time", "Effort", "min", "my-whoop", "dumbbell", 0, nil),
        d("active_kcal", "Active Energy", "Effort", "kcal", "apple-health", "flame.fill", 0, nil),

        // ── Health / Body
        d("weight", "Weight", "Health", "kg", "apple-health", "scalemass", 1, nil),
        d("body_fat", "Body Fat", "Health", "%", "apple-health", "percent", 1, false),
        d("lean_mass", "Lean Body Mass", "Health", "kg", "apple-health", "figure.arms.open", 1, true),
        d("bmi", "BMI", "Health", "", "apple-health", "figure", 1, nil),
        d("stress", "Day Stress", "Health", "/3", "my-whoop", "gauge.with.dots.needle.50percent", 1, false),

        // ── Nutrition (imported from a food-tracker CSV: calories-in alongside calories-out)
        d("calories_in", "Calories In", "Nutrition", "kcal", "nutrition-csv", "fork.knife", 0, nil),
        d("protein_g", "Protein", "Nutrition", "g", "nutrition-csv", "p.circle", 0, nil),
        d("carbs_g", "Carbs", "Nutrition", "g", "nutrition-csv", "c.circle", 0, nil),
        d("fat_g", "Fat", "Nutrition", "g", "nutrition-csv", "f.circle", 0, nil),

        // ── Mind (daily mood check-in, 1–5; non-clinical self-tracking)
        d("mood", "Mood", "Mind", "/5", "noop-mood", "face.smiling", 0, true),
    ]

    static func inCategory(_ c: String) -> [MetricDescriptor] { all.filter { $0.category == c } }

    static func sourceTitle(_ source: String) -> String {
        switch source {
        case whoopSource:
            return "WHOOP"
        case appleHealthSource:
            return "Apple Health"
        case nutritionSource:
            return "Nutrition"
        case moodSource:
            return "Mood"
        case let s where s.hasSuffix("-noop"):
            return "NOOP computed"
        default:
            return source
        }
    }

    static func sourceCandidates(
        forKey key: String,
        preferredSource: String,
        actualWhoopSource: String = whoopSource
    ) -> [MetricSourceCandidate] {
        if preferredSource == whoopSource || preferredSource == actualWhoopSource {
            var candidates = [
                MetricSourceCandidate(source: actualWhoopSource, key: key),
                MetricSourceCandidate(source: actualWhoopSource + "-noop", key: key),
            ]
            if let appleKey = appleCompatibleKey(forWhoopKey: key) {
                candidates.append(MetricSourceCandidate(source: appleHealthSource, key: appleKey))
            }
            return uniqued(candidates)
        }
        return [MetricSourceCandidate(source: preferredSource, key: key)]
    }

    private static func appleCompatibleKey(forWhoopKey key: String) -> String? {
        switch key {
        case "rhr":
            return "resting_hr"
        case "hrv", "spo2", "resp_rate":
            return key
        default:
            return nil
        }
    }

    private static func uniqued(_ candidates: [MetricSourceCandidate]) -> [MetricSourceCandidate] {
        var seen = Set<MetricSourceCandidate>()
        var out: [MetricSourceCandidate] = []
        for candidate in candidates where !seen.contains(candidate) {
            seen.insert(candidate)
            out.append(candidate)
        }
        return out
    }

    private static func d(_ key: String, _ title: String, _ category: String, _ unit: String,
                          _ source: String, _ icon: String, _ decimals: Int,
                          _ higherIsBetter: Bool?) -> MetricDescriptor {
        MetricDescriptor(key: key, title: title, category: category, unit: unit,
                         source: source, icon: icon, decimals: decimals, higherIsBetter: higherIsBetter)
    }
}
