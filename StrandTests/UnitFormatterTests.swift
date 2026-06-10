import XCTest
@testable import Strand

/// Pins the exact conversion factors and the formatted-string shapes for the Imperial/Metric display
/// layer (D#103). NOOP stores everything in SI; this is the only place the conversions live, so a wrong
/// factor here would silently mis-display every weight/distance/height/temperature in the app. These
/// tests exist specifically so that can't ship. Mirrors the Android UnitFormatterTest case-for-case.
final class UnitFormatterTests: XCTestCase {

    // MARK: - Factors (the load-bearing numbers)

    func testDistanceFactorIsExact() {
        // 1 km = 0.621371 mi
        XCTAssertEqual(UnitFormatter.milesPerKilometer, 0.621371, accuracy: 1e-12)
        XCTAssertEqual(UnitFormatter.kmToMiles(1), 0.621371, accuracy: 1e-9)
        XCTAssertEqual(UnitFormatter.kmToMiles(10), 6.21371, accuracy: 1e-9)
        XCTAssertEqual(UnitFormatter.kmToMiles(0), 0, accuracy: 1e-12)
    }

    func testMassFactorIsExact() {
        // 1 kg = 2.20462 lb
        XCTAssertEqual(UnitFormatter.poundsPerKilogram, 2.20462, accuracy: 1e-12)
        XCTAssertEqual(UnitFormatter.kgToPounds(1), 2.20462, accuracy: 1e-9)
        XCTAssertEqual(UnitFormatter.kgToPounds(75), 165.3465, accuracy: 1e-4)
    }

    func testHeightFactorIsExact() {
        // 1 inch = 2.54 cm  →  1 cm = 0.393700787 in
        XCTAssertEqual(UnitFormatter.centimetersPerInch, 2.54, accuracy: 1e-12)
        XCTAssertEqual(UnitFormatter.cmToInches(2.54), 1, accuracy: 1e-9)
        XCTAssertEqual(UnitFormatter.cmToInches(30.48), 12, accuracy: 1e-9)
    }

    func testTemperatureFactorIsExact() {
        // °F = °C * 9/5 + 32
        XCTAssertEqual(UnitFormatter.celsiusToFahrenheit(0), 32, accuracy: 1e-9)
        XCTAssertEqual(UnitFormatter.celsiusToFahrenheit(100), 212, accuracy: 1e-9)
        XCTAssertEqual(UnitFormatter.celsiusToFahrenheit(37), 98.6, accuracy: 1e-9)
        XCTAssertEqual(UnitFormatter.celsiusToFahrenheit(-40), -40, accuracy: 1e-9)   // the crossover
    }

    // MARK: - Distance formatting

    func testDistanceFromMetersMetric() {
        XCTAssertEqual(UnitFormatter.distanceFromMeters(1200, system: .metric), "1.2 km")
        XCTAssertEqual(UnitFormatter.distanceFromMeters(850, system: .metric), "850 m")
    }

    func testDistanceFromMetersImperial() {
        // 5000 m = 5 km = 3.106855 mi
        XCTAssertEqual(UnitFormatter.distanceFromMeters(5000, system: .imperial), "3.1 mi")
        // 100 m is well below a tenth of a mile → yards (100 m ≈ 109 yd)
        XCTAssertEqual(UnitFormatter.distanceFromMeters(100, system: .imperial), "109 yd")
    }

    func testDistanceFromKilometers() {
        XCTAssertEqual(UnitFormatter.distanceFromKilometers(12.4, system: .metric), "12.4 km")
        // 12.4 km * 0.621371 = 7.704... → "7.7 mi"
        XCTAssertEqual(UnitFormatter.distanceFromKilometers(12.4, system: .imperial), "7.7 mi")
    }

    // MARK: - Mass formatting

    func testMassFromKilograms() {
        XCTAssertEqual(UnitFormatter.massFromKilograms(74.5, system: .metric), "74.5 kg")
        // 74.5 * 2.20462 = 164.24419 → "164.2 lb"
        XCTAssertEqual(UnitFormatter.massFromKilograms(74.5, system: .imperial), "164.2 lb")
    }

    // MARK: - Height formatting

    func testHeightFromCentimetersMetric() {
        XCTAssertEqual(UnitFormatter.heightFromCentimeters(178, system: .metric), "178 cm")
    }

    func testHeightFromCentimetersImperial() {
        // 178 cm = 70.07 in = 5 ft 10 in
        XCTAssertEqual(UnitFormatter.heightFromCentimeters(178, system: .imperial), "5′ 10″")
        // 152.4 cm = exactly 60 in = 5 ft 0 in
        XCTAssertEqual(UnitFormatter.heightFromCentimeters(152.4, system: .imperial), "5′ 0″")
    }

    func testHeightRoundingCarriesInchesIntoFeet() {
        // 182.7 cm ≈ 71.93 in → rounds to 72 in, which must carry to 6 ft 0 in (never "5 ft 12 in").
        let (ft, inch) = UnitFormatter.cmToFeetInches(182.7)
        XCTAssertEqual(ft, 6)
        XCTAssertEqual(inch, 0)
    }

    // MARK: - Temperature formatting

    func testAbsoluteTemperature() {
        XCTAssertEqual(UnitFormatter.temperatureFromCelsius(33.4, unit: .celsius), "33.4 °C")
        // 33.4 °C = 92.12 °F → "92.1 °F"
        XCTAssertEqual(UnitFormatter.temperatureFromCelsius(33.4, unit: .fahrenheit), "92.1 °F")
    }

    func testTemperatureDeltaHasNoOffset() {
        // A +0.6 °C deviation is a 1.08 °F deviation — scale by 9/5, do NOT add 32.
        XCTAssertEqual(UnitFormatter.temperatureDeltaFromCelsius(0.6, unit: .fahrenheit), "1.1 °F")
        XCTAssertEqual(UnitFormatter.temperatureDeltaFromCelsius(0.6, unit: .celsius), "0.6 °C")
    }

    // MARK: - Preference resolution

    func testTemperatureOverrideResolution() {
        // No explicit override → follows the length/mass system.
        XCTAssertEqual(UnitPrefs.resolveTemperature(system: .metric, override: ""), .celsius)
        XCTAssertEqual(UnitPrefs.resolveTemperature(system: .imperial, override: ""), .fahrenheit)
        // Explicit override wins regardless of the system.
        XCTAssertEqual(UnitPrefs.resolveTemperature(system: .imperial, override: "celsius"), .celsius)
        XCTAssertEqual(UnitPrefs.resolveTemperature(system: .metric, override: "fahrenheit"), .fahrenheit)
    }

    // MARK: - Unit labels

    func testUnitLabels() {
        XCTAssertEqual(UnitFormatter.distanceUnit(.metric), "km")
        XCTAssertEqual(UnitFormatter.distanceUnit(.imperial), "mi")
        XCTAssertEqual(UnitFormatter.massUnit(.metric), "kg")
        XCTAssertEqual(UnitFormatter.massUnit(.imperial), "lb")
        XCTAssertEqual(UnitFormatter.temperatureUnit(.celsius), "°C")
        XCTAssertEqual(UnitFormatter.temperatureUnit(.fahrenheit), "°F")
    }
}
