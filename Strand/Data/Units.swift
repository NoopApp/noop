import Foundation

// MARK: - Unit system preference
//
// NOOP stores EVERYTHING in SI (km, kg, cm, °C) — the importers normalise on the way in, so this is a
// purely cosmetic, display-only layer. There is no data migration and nothing on disk changes when the
// user flips this. We keep one Metric/Imperial switch for length+mass with a SEPARATE temperature
// override, because plenty of people think in kg/cm but still read body temperature in °F (and vice
// versa). Default is Metric — most of the world, and it matches what we store.
//
// Persisted via @AppStorage (UserDefaults), the same mechanism every other macOS NOOP preference uses.
// The Android side mirrors this exactly in Units.kt + NoopPrefs.

/// The length+mass unit system. Temperature has its own override (see `UnitPrefs.temperature`).
enum UnitSystem: String, CaseIterable, Identifiable {
    case metric
    case imperial
    var id: String { rawValue }

    /// "follow the system" pairs temperature with the length/mass choice; an explicit case lets the
    /// user pin °C or °F independently of whether distances are in km or miles.
    var temperatureMatching: TemperatureUnit { self == .imperial ? .fahrenheit : .celsius }
}

/// Temperature display unit. Kept separate from `UnitSystem` so it can be overridden on its own.
enum TemperatureUnit: String, CaseIterable, Identifiable {
    case celsius
    case fahrenheit
    var id: String { rawValue }
}

/// UserDefaults keys for the two unit preferences. Public-ish (internal) so `SettingsView`'s
/// `@AppStorage(UnitPrefs.systemKey)` and the formatter read the SAME key — no drift.
enum UnitPrefs {
    static let systemKey = "units.system"
    /// Temperature override. Empty string = "match the length/mass system" (the default).
    static let temperatureKey = "units.temperature"

    /// Resolve the stored raw values into a concrete temperature unit, applying the
    /// "match the system" default when no explicit override is set.
    static func resolveTemperature(system: UnitSystem, override raw: String) -> TemperatureUnit {
        if let explicit = TemperatureUnit(rawValue: raw) { return explicit }
        return system.temperatureMatching
    }
}

// MARK: - Pure conversion + formatting

/// Pure, dependency-free unit conversion and display formatting. Every site that prints a distance,
/// mass, height or temperature goes through here so a unit toggle reaches all of them at once.
///
/// The conversion factors are pinned by `UnitFormatterTests` — a wrong factor can't ship silently.
/// Nothing here reads UserDefaults: callers pass the resolved `UnitSystem` / `TemperatureUnit` in, which
/// keeps the formatter trivially testable and side-effect free.
enum UnitFormatter {

    // MARK: Factors (single source of truth — tests pin these exact numbers)

    /// 1 kilometre = 0.621371 miles.
    static let milesPerKilometer = 0.621371
    /// 1 kilogram = 2.20462 pounds.
    static let poundsPerKilogram = 2.20462
    /// 1 inch = 2.54 cm exactly → 1 cm = 1/2.54 inches.
    static let centimetersPerInch = 2.54

    // MARK: Distance (stored km)

    /// km → miles.
    static func kmToMiles(_ km: Double) -> Double { km * milesPerKilometer }

    /// Format a distance given in METRES (the stored unit for workout distance).
    /// Metric: "1.2 km" / "850 m". Imperial: "0.7 mi" / "230 yd" for sub-mile distances.
    static func distanceFromMeters(_ meters: Double, system: UnitSystem) -> String {
        switch system {
        case .metric:
            let km = meters / 1000.0
            return km >= 1 ? oneDecimal(km) + " km" : "\(Int(meters.rounded())) m"
        case .imperial:
            let miles = kmToMiles(meters / 1000.0)
            if miles >= 0.1 { return oneDecimal(miles) + " mi" }
            // Below ~160 m show yards rather than a "0.0 mi" that reads as nothing.
            let yards = meters * 1.09361
            return "\(Int(yards.rounded())) yd"
        }
    }

    /// Format a distance given in KILOMETRES (e.g. the Workouts "Total Distance" sum), with one decimal
    /// and a unit label. Metric: "12.4 km". Imperial: "7.7 mi".
    static func distanceFromKilometers(_ km: Double, system: UnitSystem) -> String {
        switch system {
        case .metric:   return oneDecimal(km) + " km"
        case .imperial: return oneDecimal(kmToMiles(km)) + " mi"
        }
    }

    /// Unit label only, for sites that format the number separately. "km" / "mi".
    static func distanceUnit(_ system: UnitSystem) -> String {
        system == .imperial ? "mi" : "km"
    }

    // MARK: Mass (stored kg)

    /// kg → pounds.
    static func kgToPounds(_ kg: Double) -> Double { kg * poundsPerKilogram }

    /// Format a mass given in KILOGRAMS with one decimal + unit. Metric: "74.5 kg". Imperial: "164.2 lb".
    static func massFromKilograms(_ kg: Double, system: UnitSystem) -> String {
        switch system {
        case .metric:   return oneDecimal(kg) + " kg"
        case .imperial: return oneDecimal(kgToPounds(kg)) + " lb"
        }
    }

    /// Mass unit label only. "kg" / "lb".
    static func massUnit(_ system: UnitSystem) -> String {
        system == .imperial ? "lb" : "kg"
    }

    // MARK: Height (stored cm)

    /// cm → total inches.
    static func cmToInches(_ cm: Double) -> Double { cm / centimetersPerInch }

    /// Decompose a height in CENTIMETRES into whole feet + inches (inches rounded, carried into feet).
    static func cmToFeetInches(_ cm: Double) -> (feet: Int, inches: Int) {
        let totalInches = Int(cmToInches(cm).rounded())
        var feet = totalInches / 12
        var inches = totalInches % 12
        if inches == 12 { feet += 1; inches = 0 }   // rounding can push 11.5" → 12"
        return (feet, inches)
    }

    /// Format a height given in CENTIMETRES. Metric: "178 cm". Imperial: "5′ 10″".
    static func heightFromCentimeters(_ cm: Double, system: UnitSystem) -> String {
        switch system {
        case .metric:
            return "\(Int(cm.rounded())) cm"
        case .imperial:
            let (ft, inch) = cmToFeetInches(cm)
            // Prime/double-prime are the conventional ft/in glyphs and read cleanly at small sizes.
            return "\(ft)′ \(inch)″"
        }
    }

    // MARK: Temperature (stored °C — absolute)

    /// °C → °F: F = C * 9/5 + 32.
    static func celsiusToFahrenheit(_ c: Double) -> Double { c * 9.0 / 5.0 + 32.0 }

    /// Format an ABSOLUTE temperature in CELSIUS. Metric: "33.4 °C". Imperial: "92.1 °F".
    static func temperatureFromCelsius(_ c: Double, unit: TemperatureUnit, decimals: Int = 1) -> String {
        switch unit {
        case .celsius:    return decimalString(c, decimals) + " °C"
        case .fahrenheit: return decimalString(celsiusToFahrenheit(c), decimals) + " °F"
        }
    }

    /// Format a temperature DEVIATION (a ±Δ°C, e.g. the skin-temp deviation pipeline). A delta scales by
    /// 9/5 but does NOT add the +32 offset — that would be wrong for a difference.
    static func temperatureDeltaFromCelsius(_ dc: Double, unit: TemperatureUnit, decimals: Int = 1) -> String {
        switch unit {
        case .celsius:    return decimalString(dc, decimals) + " °C"
        case .fahrenheit: return decimalString(dc * 9.0 / 5.0, decimals) + " °F"
        }
    }

    /// Temperature unit label only. "°C" / "°F".
    static func temperatureUnit(_ unit: TemperatureUnit) -> String {
        unit == .fahrenheit ? "°F" : "°C"
    }

    // MARK: Helpers

    private static func oneDecimal(_ v: Double) -> String { String(format: "%.1f", v) }

    private static func decimalString(_ v: Double, _ decimals: Int) -> String {
        decimals == 0 ? "\(Int(v.rounded()))" : String(format: "%.\(decimals)f", v)
    }
}
