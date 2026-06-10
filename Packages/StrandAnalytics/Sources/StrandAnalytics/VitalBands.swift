import Foundation

/// Personal-baseline banding for the Health Monitor's vital tiles.
///
/// In-range is judged against the user's OWN trailing baseline (Baselines' Winsorized EWMA)
/// once it is trusted (>= Baselines.minNightsTrust = 14 valid nights and not stale); until
/// then — and when the baseline has gone stale after a wear gap — the fixed population range
/// is the fallback. MetricCfg's physiological bounds stay an absolute outer guard either way
/// (deliberately NOT the population range: that would resurrect the false positive being
/// fixed, e.g. a perfectly normal personal HRV of 35 ms vs the 40–120 population band).
/// APPROXIMATE — informational, not a diagnosis.
public enum VitalBands {

    public enum Band: String, Equatable, Sendable { case inRange, outOfRange, noData }
    /// How the band was judged (drives the tile caption).
    public enum Basis: String, Equatable, Sendable { case personal, population }

    public struct Result: Equatable, Sendable {
        public let band: Band
        public let basis: Basis
        /// Valid nights backing the personal baseline (0 when none).
        public let nights: Int
        public init(band: Band, basis: Basis, nights: Int) {
            self.band = band; self.basis = basis; self.nights = nights
        }
    }

    /// |z| at or below this is in-range vs the personal baseline (~95% of the user's own
    /// normal nights). The module's inNormalRange (|z| <= 1) would flag ~32% of normal
    /// nights — too noisy for a passive tile.
    public static let sigmaK: Double = 2.0

    /// Band `value` for one vital.
    /// - history: nightly values oldest→newest EXCLUDING the displayed day
    ///   (nil = missing night; use calendarSeries to pad wear gaps).
    /// - cfg: nil disables the personal path entirely (SpO2 stays population-only).
    public static func band(value: Double?,
                            history: [Double?],
                            populationRange: ClosedRange<Double>,
                            cfg: MetricCfg?) -> Result {
        guard let value else { return Result(band: .noData, basis: .population, nights: 0) }
        guard let cfg else {
            return Result(band: populationRange.contains(value) ? .inRange : .outOfRange,
                          basis: .population, nights: 0)
        }
        let state = Baselines.foldHistory(history, cfg: cfg)
        // Absolute-plausibility outer guard: outside the physiological bounds is
        // out-of-range no matter what the personal spread says.
        guard cfg.minVal <= value && value <= cfg.maxVal else {
            return Result(band: .outOfRange, basis: .population, nights: state.nValid)
        }
        if state.trusted {   // >= 14 valid nights and not stale
            let z = Baselines.deviation(value, state: state).z
            return Result(band: abs(z) <= sigmaK ? .inRange : .outOfRange,
                          basis: .personal, nights: state.nValid)
        }
        return Result(band: populationRange.contains(value) ? .inRange : .outOfRange,
                      basis: .population, nights: state.nValid)
    }

    // MARK: - Skin temp (mixed semantics: absolute °C from CSV import vs ±°C deviation on-device)

    /// Values >= 20 °C read as absolute skin temperature; smaller magnitudes as deviations.
    /// The WHOOP CSV export stores absolute °C in the skin-temp column while the on-device
    /// pipeline stores a deviation from the personal baseline — a merged series is bimodal,
    /// so the displayed value picks which kind its history keeps. Heuristic but physically
    /// safe: no real wrist skin temp is below 20 °C and no real deviation reaches ±20 °C.
    public static func isAbsoluteSkinTemp(_ v: Double) -> Bool { v >= 20.0 }

    /// Keep only history entries of the SAME kind as the displayed value
    /// (others become nil = missing nights) so the baseline isn't bimodal.
    public static func skinTempHistory(matching value: Double, in history: [Double?]) -> [Double?] {
        let absolute = isAbsoluteSkinTemp(value)
        return history.map { v in
            guard let v else { return nil }
            return isAbsoluteSkinTemp(v) == absolute ? v : nil
        }
    }

    /// Deviation-semantics config for on-device skin-temp rows (±°C around the personal mean).
    public static let skinTempDeviationCfg = MetricCfg(
        minVal: -8.0, maxVal: 8.0, floorSpread: 0.3, halfLifeB: 14.0, halfLifeS: 21.0)

    // MARK: - Calendar padding

    /// Calendar-align (day, value) rows ("yyyy-MM-dd" keys) into a nightly series with nil
    /// for missing days, so Baselines staleness sees wear gaps (stored rows simply skip
    /// absent days; without padding a user returning after two months would be judged
    /// against an ancient "trusted" baseline). Malformed day keys are dropped. Pure; fixed
    /// UTC math on the day keys only.
    public static func calendarSeries(_ rows: [(day: String, value: Double?)]) -> [Double?] {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(secondsFromGMT: 0)
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(secondsFromGMT: 0)!
        let dates = rows.compactMap { f.date(from: $0.day) }
        guard let first = dates.min(), let last = dates.max() else { return [] }
        var byDay: [String: Double?] = [:]
        for r in rows where f.date(from: r.day) != nil { byDay[r.day] = r.value }
        var out: [Double?] = []
        var d = first
        while d <= last {
            out.append(byDay[f.string(from: d)] ?? nil)
            guard let next = cal.date(byAdding: .day, value: 1, to: d) else { break }
            d = next
        }
        return out
    }
}
