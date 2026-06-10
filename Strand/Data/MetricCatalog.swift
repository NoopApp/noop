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

/// Canonical catalog — mirrors the WHOOP "Trend View" plus Apple Health body metrics.
/// Keys match exactly what the importers write into metricSeries.
enum MetricCatalog {
    static let categories = ["Heart", "Recovery", "Sleep", "Strain", "Health"]

    static let all: [MetricDescriptor] = [
        // ── Heart
        d("avg_hr", "Average Heart Rate", "Heart", "bpm", "my-whoop", "heart", 0, nil),
        d("max_hr", "Max Heart Rate", "Heart", "bpm", "my-whoop", "bolt.heart", 0, nil),
        d("energy_kcal", "Calories", "Heart", "kcal", "my-whoop", "flame", 0, nil),
        d("vo2max", "VO₂ Max", "Heart", "", "apple-health", "lungs.fill", 1, true),

        // ── Recovery
        d("recovery", "Recovery", "Recovery", "%", "my-whoop", "heart.circle", 0, true),
        d("hrv", "Heart Rate Variability", "Recovery", "ms", "my-whoop", "waveform.path.ecg", 0, true),
        d("rhr", "Resting Heart Rate", "Recovery", "bpm", "my-whoop", "heart", 0, false),
        d("resp_rate", "Respiratory Rate", "Recovery", "rpm", "my-whoop", "lungs", 1, nil),
        d("spo2", "Blood Oxygen", "Recovery", "%", "my-whoop", "drop", 0, true),
        d("skin_temp", "Skin Temperature", "Recovery", "°C", "my-whoop", "thermometer", 1, nil),

        // ── Sleep
        d("sleep_performance", "Sleep Performance", "Sleep", "%", "my-whoop", "moon.stars", 0, true),
        d("in_bed_min", "Time in Bed", "Sleep", "min", "my-whoop", "bed.double", 0, nil),
        d("sleep_total_min", "Asleep Time", "Sleep", "min", "my-whoop", "moon.zzz", 0, true),
        d("hours_vs_needed_pct", "Hours vs Needed", "Sleep", "%", "my-whoop", "gauge.medium", 0, true),
        d("sleep_consistency", "Sleep Consistency", "Sleep", "%", "my-whoop", "calendar", 0, true),
        d("restorative_pct", "Restorative Sleep", "Sleep", "%", "my-whoop", "sparkles", 0, true),
        d("restorative_min", "Restorative Sleep", "Sleep", "min", "my-whoop", "sparkles", 0, true),
        d("sleep_efficiency", "Sleep Efficiency", "Sleep", "%", "my-whoop", "bed.double.fill", 0, true),
        d("sleep_deep_min", "Deep (SWS) Sleep", "Sleep", "min", "my-whoop", "moon.fill", 0, true),
        d("sleep_rem_min", "REM Sleep", "Sleep", "min", "my-whoop", "moon.haze", 0, true),
        d("sleep_light_min", "Light Sleep", "Sleep", "min", "my-whoop", "moon", 0, nil),
        d("sleep_need_min", "Sleep Need", "Sleep", "min", "my-whoop", "gauge", 0, nil),
        d("sleep_debt_min", "Sleep Debt", "Sleep", "min", "my-whoop", "exclamationmark.circle", 0, false),

        // ── Strain
        d("strain", "Day Strain", "Strain", "/21", "my-whoop", "flame", 1, nil),
        d("steps", "Steps", "Strain", "", "apple-health", "figure.walk", 0, true),
        d("hr_zones13_min", "HR Zones 1–3", "Strain", "min", "my-whoop", "heart", 0, nil),
        d("hr_zones45_min", "HR Zones 4–5", "Strain", "min", "my-whoop", "heart.fill", 0, nil),
        d("hr_zones_all_min", "HR Zones (All)", "Strain", "min", "my-whoop", "heart.text.square", 0, nil),
        d("strength_min", "Strength Activity Time", "Strain", "min", "my-whoop", "dumbbell", 0, nil),
        d("active_kcal", "Active Energy", "Strain", "kcal", "apple-health", "flame.fill", 0, nil),

        // ── Health / Body
        d("weight", "Weight", "Health", "kg", "apple-health", "scalemass", 1, nil),
        d("body_fat", "Body Fat", "Health", "%", "apple-health", "percent", 1, false),
        d("lean_mass", "Lean Body Mass", "Health", "kg", "apple-health", "figure.arms.open", 1, true),
        d("bmi", "BMI", "Health", "", "apple-health", "figure", 1, nil),
        d("stress", "Day Stress", "Health", "/3", "my-whoop", "gauge.with.dots.needle.50percent", 1, false),
    ]

    static func inCategory(_ c: String) -> [MetricDescriptor] { all.filter { $0.category == c } }

    private static func d(_ key: String, _ title: String, _ category: String, _ unit: String,
                          _ source: String, _ icon: String, _ decimals: Int,
                          _ higherIsBetter: Bool?) -> MetricDescriptor {
        MetricDescriptor(key: key, title: title, category: category, unit: unit,
                         source: source, icon: icon, decimals: decimals, higherIsBetter: higherIsBetter)
    }
}
