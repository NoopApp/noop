package com.noop.ui

import android.content.Context
import java.util.Locale
import kotlin.math.roundToInt

// MARK: - Unit system preference
//
// NOOP stores EVERYTHING in SI (km, kg, cm, °C) — the importers normalise on the way in, so this is a
// purely cosmetic, display-only layer. There is no data migration and nothing in Room changes when the
// user flips this. One Metric/Imperial switch for length+mass with a SEPARATE temperature override,
// because plenty of people think in kg/cm but still read body temperature in °F (and vice versa).
// Default is Metric — most of the world, and it matches what we store.
//
// Persisted via NoopPrefs (SharedPreferences), the same mechanism every other Android preference uses.
// This mirrors the macOS Units.swift + @AppStorage side exactly.

/** Length+mass unit system. Temperature has its own override (see [UnitPrefs.temperature]). */
enum class UnitSystem(val raw: String) {
    METRIC("metric"),
    IMPERIAL("imperial");

    /** Pairs temperature with the length/mass choice when no explicit override is set. */
    val temperatureMatching: TemperatureUnit
        get() = if (this == IMPERIAL) TemperatureUnit.FAHRENHEIT else TemperatureUnit.CELSIUS

    companion object {
        fun fromRaw(raw: String?): UnitSystem = entries.firstOrNull { it.raw == raw } ?: METRIC
    }
}

/** Temperature display unit, overridable independently of [UnitSystem]. */
enum class TemperatureUnit(val raw: String) {
    CELSIUS("celsius"),
    FAHRENHEIT("fahrenheit");

    companion object {
        fun fromRaw(raw: String?): TemperatureUnit? = entries.firstOrNull { it.raw == raw }
    }
}

/**
 * Reads the two unit preferences from [NoopPrefs] and resolves the "match the system" default for
 * temperature. SharedPreferences isn't reactive, so Compose screens read these once into remembered
 * state (exactly like the other toggles) and re-read on a recomposition triggered by the Settings write.
 */
object UnitPrefs {
    /** The length/mass system (default Metric). */
    fun system(context: Context): UnitSystem =
        UnitSystem.fromRaw(NoopPrefs.of(context).getString(NoopPrefs.KEY_UNIT_SYSTEM, null))

    /** The resolved temperature unit, applying the "match the length/mass system" default. */
    fun temperature(context: Context): TemperatureUnit {
        val override = TemperatureUnit.fromRaw(
            NoopPrefs.of(context).getString(NoopPrefs.KEY_TEMPERATURE_UNIT, null),
        )
        return override ?: system(context).temperatureMatching
    }

    /** Pure resolver shared with the tests: explicit override wins, else follow the system. */
    fun resolveTemperature(system: UnitSystem, override: String?): TemperatureUnit =
        TemperatureUnit.fromRaw(override) ?: system.temperatureMatching
}

/**
 * Pure, Android-free unit conversion and display formatting. Every site that prints a distance, mass,
 * height or temperature goes through here so the unit toggle reaches all of them at once.
 *
 * The conversion factors are pinned by `UnitFormatterTest` — a wrong factor can't ship silently.
 * Nothing here reads SharedPreferences: callers pass the resolved [UnitSystem] / [TemperatureUnit] in,
 * which keeps the formatter trivially testable and side-effect free. Mirrors Swift's `UnitFormatter`.
 */
object UnitFormatter {

    // MARK: Factors (single source of truth — tests pin these exact numbers)

    /** 1 kilometre = 0.621371 miles. */
    const val MILES_PER_KILOMETER = 0.621371
    /** 1 kilogram = 2.20462 pounds. */
    const val POUNDS_PER_KILOGRAM = 2.20462
    /** 1 inch = 2.54 cm exactly → 1 cm = 1/2.54 inches. */
    const val CENTIMETERS_PER_INCH = 2.54

    // MARK: Distance (stored km)

    /** km → miles. */
    fun kmToMiles(km: Double): Double = km * MILES_PER_KILOMETER

    /**
     * Format a distance given in METRES (the stored unit for workout distance).
     * Metric: "1.2 km" / "850 m". Imperial: "0.7 mi" / "230 yd" for sub-mile distances.
     */
    fun distanceFromMeters(meters: Double, system: UnitSystem): String = when (system) {
        UnitSystem.METRIC -> {
            val km = meters / 1000.0
            if (km >= 1) oneDecimal(km) + " km" else "${meters.roundToInt()} m"
        }
        UnitSystem.IMPERIAL -> {
            val miles = kmToMiles(meters / 1000.0)
            if (miles >= 0.1) {
                oneDecimal(miles) + " mi"
            } else {
                // Below ~160 m show yards rather than a "0.0 mi" that reads as nothing.
                "${(meters * 1.09361).roundToInt()} yd"
            }
        }
    }

    /**
     * Format a distance given in KILOMETRES (e.g. the Workouts "Total Distance" sum), with one decimal
     * and a unit label. Metric: "12.4 km". Imperial: "7.7 mi".
     */
    fun distanceFromKilometers(km: Double, system: UnitSystem): String = when (system) {
        UnitSystem.METRIC -> oneDecimal(km) + " km"
        UnitSystem.IMPERIAL -> oneDecimal(kmToMiles(km)) + " mi"
    }

    /** Unit label only, for sites that format the number separately. "km" / "mi". */
    fun distanceUnit(system: UnitSystem): String = if (system == UnitSystem.IMPERIAL) "mi" else "km"

    // MARK: Mass (stored kg)

    /** kg → pounds. */
    fun kgToPounds(kg: Double): Double = kg * POUNDS_PER_KILOGRAM

    /** Format a mass given in KILOGRAMS with one decimal + unit. Metric: "74.5 kg". Imperial: "164.2 lb". */
    fun massFromKilograms(kg: Double, system: UnitSystem): String = when (system) {
        UnitSystem.METRIC -> oneDecimal(kg) + " kg"
        UnitSystem.IMPERIAL -> oneDecimal(kgToPounds(kg)) + " lb"
    }

    /** Mass unit label only. "kg" / "lb". */
    fun massUnit(system: UnitSystem): String = if (system == UnitSystem.IMPERIAL) "lb" else "kg"

    // MARK: Height (stored cm)

    /** cm → total inches. */
    fun cmToInches(cm: Double): Double = cm / CENTIMETERS_PER_INCH

    /** Decompose a height in CENTIMETRES into whole feet + inches (inches rounded, carried into feet). */
    fun cmToFeetInches(cm: Double): Pair<Int, Int> {
        val totalInches = cmToInches(cm).roundToInt()
        var feet = totalInches / 12
        var inches = totalInches % 12
        if (inches == 12) { feet += 1; inches = 0 } // rounding can push 11.5" → 12"
        return Pair(feet, inches)
    }

    /** Format a height given in CENTIMETRES. Metric: "178 cm". Imperial: "5′ 10″". */
    fun heightFromCentimeters(cm: Double, system: UnitSystem): String = when (system) {
        UnitSystem.METRIC -> "${cm.roundToInt()} cm"
        UnitSystem.IMPERIAL -> {
            val (ft, inch) = cmToFeetInches(cm)
            // Prime/double-prime are the conventional ft/in glyphs and read cleanly at small sizes.
            "$ft′ $inch″"
        }
    }

    // MARK: Temperature (stored °C — absolute)

    /** °C → °F: F = C * 9/5 + 32. */
    fun celsiusToFahrenheit(c: Double): Double = c * 9.0 / 5.0 + 32.0

    /** Format an ABSOLUTE temperature in CELSIUS. Metric: "33.4 °C". Imperial: "92.1 °F". */
    fun temperatureFromCelsius(c: Double, unit: TemperatureUnit, decimals: Int = 1): String = when (unit) {
        TemperatureUnit.CELSIUS -> decimalString(c, decimals) + " °C"
        TemperatureUnit.FAHRENHEIT -> decimalString(celsiusToFahrenheit(c), decimals) + " °F"
    }

    /**
     * Format a temperature DEVIATION (a ±Δ°C, e.g. the skin-temp deviation pipeline). A delta scales by
     * 9/5 but does NOT add the +32 offset — that would be wrong for a difference.
     */
    fun temperatureDeltaFromCelsius(dc: Double, unit: TemperatureUnit, decimals: Int = 1): String = when (unit) {
        TemperatureUnit.CELSIUS -> decimalString(dc, decimals) + " °C"
        TemperatureUnit.FAHRENHEIT -> decimalString(dc * 9.0 / 5.0, decimals) + " °F"
    }

    /** Temperature unit label only. "°C" / "°F". */
    fun temperatureUnit(unit: TemperatureUnit): String =
        if (unit == TemperatureUnit.FAHRENHEIT) "°F" else "°C"

    // MARK: Helpers

    private fun oneDecimal(v: Double): String = String.format(Locale.US, "%.1f", v)

    private fun decimalString(v: Double, decimals: Int): String =
        if (decimals == 0) "${v.roundToInt()}" else String.format(Locale.US, "%.${decimals}f", v)
}
