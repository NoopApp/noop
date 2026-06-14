import Foundation
import WhoopProtocol
@preconcurrency import WhoopStore

// AnalyticsEngine.swift — orchestrator producing DailyMetric + sleep-session results.
//
// Mirrors the role of server/ingest/app/analysis/daily.py + sleep.daily_sleep_summary:
// given a day's raw streams + a user profile + personal baselines, it runs the
// individual analyzers and assembles a `DailyMetric` (WhoopStore shape) plus the
// detected `SleepSession`s (and their `CachedSleepSession` cache shapes).
//
// This is a PURE function over its inputs — it does NOT touch the database
// (persistence is wired elsewhere). All derived values are APPROXIMATE.

public enum AnalyticsEngine {

    /// Baselines passed in by the caller (built from prior nights via Baselines).
    public struct ProfileBaselines: Sendable {
        public let hrv: BaselineState?
        public let restingHR: BaselineState?
        public let resp: BaselineState?
        public let skinTemp: BaselineState?
        public init(hrv: BaselineState? = nil, restingHR: BaselineState? = nil,
                    resp: BaselineState? = nil, skinTemp: BaselineState? = nil) {
            self.hrv = hrv; self.restingHR = restingHR; self.resp = resp
            self.skinTemp = skinTemp
        }
    }

    /// The full analysis result for one day.
    ///
    /// NOTE: not `Sendable` — it embeds `DailyMetric` / `CachedSleepSession` from
    /// WhoopStore, which are not `Sendable` (and that package is out of scope to
    /// modify here). The individual analyzer result types in this package ARE
    /// `Sendable`.
    public struct DayResult {
        /// DailyMetric in the WhoopStore cache shape (recovery/strain/sleep rolled up).
        public let daily: DailyMetric
        /// Detected sleep sessions (rich, with stage segments).
        public let sleepSessions: [SleepSession]
        /// CachedSleepSession cache rows (one per detected session).
        public let cachedSleep: [CachedSleepSession]
        /// Detected workout/exercise sessions.
        public let workouts: [ExerciseSession]
        /// Recovery / "Charge" score [0,100] or nil (cold-start / no HRV baseline).
        public let recovery: Double?
        /// Day strain / "Effort" [0,100] or nil (insufficient HR samples / invalid HRR).
        public let strain: Double?
        /// Rest composite [0,100] or nil (no in-bed data). This is the value the
        /// `sleep_performance` metric key carries (duration-vs-need 0.50 + efficiency
        /// 0.20 + restorative share 0.20 + consistency 0.10). The downstream metric-series
        /// builder reads it from here; the Charge "Rest quality" term reads it ÷100.
        public let restScore: Double?
        /// Per-score confidence tiers (Charge / Effort / Rest) for the small label under
        /// each score. Always present (worst case `.calibrating`).
        public let chargeConfidence: ScoreConfidence
        public let effortConfidence: ScoreConfidence
        public let restConfidence: ScoreConfidence
        /// Wear-gated mean in-bed skin temperature (°C) for this night, or nil when no worn
        /// in-bed samples were available. Baseline-INDEPENDENT (like avgHrv): the caller seeds
        /// a personal skin-temp baseline from these nightly means and re-derives
        /// `DailyMetric.skinTempDevC` in a second pass. APPROXIMATE.
        public let nightlySkinTempC: Double?

        public init(daily: DailyMetric, sleepSessions: [SleepSession],
                    cachedSleep: [CachedSleepSession], workouts: [ExerciseSession],
                    recovery: Double?, strain: Double?, nightlySkinTempC: Double? = nil,
                    restScore: Double? = nil,
                    chargeConfidence: ScoreConfidence = .calibrating,
                    effortConfidence: ScoreConfidence = .calibrating,
                    restConfidence: ScoreConfidence = .calibrating) {
            self.daily = daily; self.sleepSessions = sleepSessions
            self.cachedSleep = cachedSleep; self.workouts = workouts
            self.recovery = recovery; self.strain = strain
            self.nightlySkinTempC = nightlySkinTempC
            self.restScore = restScore
            self.chargeConfidence = chargeConfidence
            self.effortConfidence = effortConfidence
            self.restConfidence = restConfidence
        }
    }

    private static let isoDay: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    /// Format a unix-seconds timestamp as a UTC YYYY-MM-DD day string.
    public static func dayString(_ ts: Int) -> String {
        isoDay.string(from: Date(timeIntervalSince1970: TimeInterval(ts)))
    }

    /// Format a unix-seconds timestamp as a YYYY-MM-DD day string in the LOCAL wall clock
    /// `offsetSeconds` east of UTC. With the default `offsetSeconds == 0` this is identical to
    /// `dayString(_:)` (UTC), so pure-function callers and tests are unaffected. Shifting the
    /// timestamp by the offset and then formatting in UTC yields the local calendar date without
    /// pulling in a `TimeZone` (keeps the engine deterministic + DB-free). This is how a sleep
    /// session is attributed to the day its wake falls on for a user NOT on UTC: a night ending
    /// 03:30 local crosses UTC midnight for many offsets, so the UTC end-day was a calendar day
    /// off from the LOCAL day the dashboard (logical-day, importer, SleepView) keys on (#304).
    public static func dayString(_ ts: Int, offsetSeconds: Int) -> String {
        isoDay.string(from: Date(timeIntervalSince1970: TimeInterval(ts + offsetSeconds)))
    }

    /// JSON-encode stage segments to the verbatim array shape CachedSleepSession stores.
    static func encodeStages(_ stages: [StageSegment]) -> String? {
        guard let data = try? JSONEncoder().encode(stages) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Analyze one day's streams into a `DayResult`.
    ///
    /// - Parameters:
    ///   - day: the calendar day this metric is for, on the SAME wall-clock basis as
    ///     `tzOffsetSeconds` (UTC when that is 0, the device-local day otherwise); a sleep
    ///     session is attributed to the day its `end` falls on (a night ending that morning).
    ///     The caller MUST derive `day` with the same offset (see `dayString(_:offsetSeconds:)`)
    ///     so the session→day match and the additive-total day windows agree (#304).
    ///   - hr/rr/resp/gravity: the day's raw streams (the wider window around the
    ///     night may be passed; sleep detection finds the in-bed span itself).
    ///   - profile: user profile (age/sex/weight/height) for HRmax + calories.
    ///   - baselines: personal baselines for recovery normalization.
    ///   - maxHROverride: explicit HRmax (bpm) to use for strain/zones; nil →
    ///     Tanaka from profile.age.
    public static func analyzeDay(day: String,
                                  hr: [HRSample] = [],
                                  rr: [RRInterval] = [],
                                  resp: [RespSample] = [],
                                  gravity: [GravitySample] = [],
                                  steps: [StepSample] = [],
                                  // Calendar-day-scoped overrides for the ADDITIVE daily totals
                                  // (steps + activeKcalEst) ONLY. When nil, the totals fall back to
                                  // the same window the rest of the analysis uses (preserving the
                                  // pure-function contract). The caller (IntelligenceEngine) supplies
                                  // a full [midnightUtc(day), midnightUtc(day)+86400) read here so a
                                  // PAST day's late hours — which fall outside the ~42h
                                  // night-detection window when the current UTC time-of-day is before
                                  // noon — are still counted. Sleep / recovery / strain / workouts
                                  // keep using hr/rr/resp/gravity/steps.
                                  dayHr: [HRSample]? = nil,
                                  daySteps: [StepSample]? = nil,
                                  // Wear-gated nightly skin-temp mean is harvested here
                                  // (baseline-independent); IntelligenceEngine seeds a personal
                                  // baseline from these means across nights and re-derives
                                  // skinTempDevC in pass 2 (same two-pass shape as avgHrv→recovery).
                                  skinTemp: [SkinTempSample] = [],
                                  profile: UserProfile,
                                  baselines: ProfileBaselines = ProfileBaselines(),
                                  maxHROverride: Double? = nil,
                                  // Wall-clock UTC offset (seconds) for the sleep detector's daytime
                                  // false-sleep guard (#90). Default 0 keeps pure-function callers/tests
                                  // on UTC; IntelligenceEngine passes the device's real offset.
                                  tzOffsetSeconds: Int = 0,
                                  // Rest composite (Charge/Effort/Rest) personalization. Both default to
                                  // their neutral form so pure-function callers/tests get a well-defined
                                  // Rest from a single night; IntelligenceEngine refines them from history.
                                  //   sleepNeedHours: personal sleep need (h). Default 8 h; the caller
                                  //     refines it toward the recent average. Drives the 0.50 duration term.
                                  //   sleepConsistency: sleep/wake regularity in [0,1] (1 = perfectly
                                  //     regular). nil → the consistency term is neutral (0.5) since a single
                                  //     day carries no regularity signal — the caller supplies it from history.
                                  sleepNeedHours: Double = Rest.defaultNeedHours,
                                  sleepConsistency: Double? = nil) -> DayResult {

        // ── Sleep detection + staging ─────────────────────────────────────────
        let allSessions = SleepStager.detectSleep(hr: hr, rr: rr, resp: resp, gravity: gravity,
                                                  tzOffsetSeconds: tzOffsetSeconds)
        // Sessions attributed to `day` = those whose end falls on `day`. `day` and the end-day are
        // compared on the SAME basis: the device-local wall clock (`tzOffsetSeconds`), so a night
        // that ends in the small hours and crosses UTC midnight still lands on the local day the rest
        // of the app keys on. With the default offset 0 this is the original UTC behaviour (#304).
        let matched = allSessions.filter { dayString($0.end, offsetSeconds: tzOffsetSeconds) == day }

        // ── Daily sleep aggregates (AASM, in-bed weighted) ────────────────────
        var deepS = 0.0, remS = 0.0, lightS = 0.0, tstS = 0.0
        var inBedS = 0.0, effWeighted = 0.0
        var disturbances = 0
        for s in matched {
            let m = SleepStager.hypnogramMetrics(s)
            let inBed = Double(s.end - s.start)
            inBedS += inBed
            effWeighted += s.efficiency * inBed
            deepS += m.deepMin * 60.0
            remS += m.remMin * 60.0
            lightS += m.lightMin * 60.0
            tstS += m.tstS
            disturbances += m.disturbances
        }
        let efficiency = inBedS > 0 ? effWeighted / inBedS : 0.0

        // ── Rest composite (Charge/Effort/Rest) ───────────────────────────────
        // The 0–100 sleep score the `sleep_performance` metric key now carries:
        //   duration-vs-personal-need 0.50 + efficiency 0.20 + restorative share 0.20
        //   + consistency 0.10. nil when there is no in-bed data. The Charge "Rest
        //   quality" term reads it ÷100 (replacing raw efficiency).
        let hasStagedSleep = (deepS + remS) > 0
        let restScore: Double? = matched.isEmpty ? nil : Rest.composite(
            tstSeconds: tstS,
            inBedSeconds: inBedS,
            efficiency: efficiency,
            restorativeSeconds: deepS + remS,
            needHours: sleepNeedHours,
            consistency: sleepConsistency)

        // Daily resting HR = lowest per-session resting HR across matched sessions.
        let restingHRDaily = matched.compactMap { $0.restingHR }.min()
        // Daily avg HRV = in-bed-weighted mean of per-session avg HRV.
        let avgHRVDaily: Double? = {
            let pairs = matched.compactMap { s -> (Double, Double)? in
                s.avgHRV.map { ($0, Double(s.end - s.start)) }
            }
            guard !pairs.isEmpty else { return nil }
            let total = pairs.reduce(0.0) { $0 + $1.0 * $1.1 }
            let weight = pairs.reduce(0.0) { $0 + $1.1 }
            return weight > 0 ? total / weight : nil
        }()

        // Nightly APPROXIMATE respiratory rate (breaths/min) from the R-R stream via
        // RSA. WHOOP5 v18 carries no raw resp ADC, so this is an on-device estimate,
        // NOT a cloud/clinical respiration value. Per matched in-bed session, estimate
        // over [start, end]; the night's value = median of finite per-session
        // estimates; nil only when no session yields a finite estimate.
        let respRateDaily: Double? = {
            let perSession = matched
                .map { SleepStager.respRateFromRR(rr, start: $0.start, end: $0.end) }
                .filter { $0.isFinite }
            return perSession.isEmpty ? nil : HRVAnalyzer.median(perSession)
        }()

        let sleepStart = matched.map { $0.start }.min()
        let sleepEnd = matched.map { $0.end }.max()

        // ── Skin-temperature deviation (offline) ──────────────────────────────
        // Computed BEFORE recovery so Charge can fold it in. Wear-gated in-bed mean
        // (baseline-independent, harvested every pass) + the deviation against the
        // personal baseline. In pass 1 baselines.skinTemp is nil so the deviation is nil
        // and the mean is harvested; IntelligenceEngine seeds the baseline from those means
        // and re-derives the deviation in pass 2 (mirrors avgHrv→recovery). APPROXIMATE.
        let nightlySkinTempC = wornNightlySkinTempC(matched, hr: hr, skinTemp: skinTemp)
        let skinTempDevC: Double? = nightlySkinTempC.flatMap { (v: Double) -> Double? in
            guard let b = baselines.skinTemp, b.usable else { return nil }
            return round2(Baselines.deviation(v, state: b).delta)
        }

        // ── Recovery / "Charge" ───────────────────────────────────────────────
        var recovery: Double? = nil
        if let hrvVal = avgHRVDaily, let rhrVal = restingHRDaily, let hrvBase = baselines.hrv {
            // Rest-quality term = the Rest composite ÷100 (replaces raw efficiency).
            let sleepPerf = restScore.map { $0 / 100.0 }
            recovery = RecoveryScorer.recovery(
                hrv: hrvVal,
                rhr: Double(rhrVal),
                resp: respRateDaily,       // term drops + renormalizes when nil / no baseline
                hrvBaseline: hrvBase,
                rhrBaseline: baselines.restingHR,
                respBaseline: baselines.resp,
                sleepPerf: sleepPerf,
                skinTempDev: skinTempDevC)  // symmetric penalty; drops + renormalizes when nil
        }

        // ── Strain / "Effort" (day cardiovascular load over the full HR window) ──
        let effMaxHR: Double? = maxHROverride ?? (profile.age > 0 ? StrainScorer.tanakaHRmax(age: profile.age) : nil)
        let restForStrain = restingHRDaily.map(Double.init) ?? StrainScorer.defaultRestingHR
        let strain = StrainScorer.strain(hr, maxHR: effMaxHR, restingHR: restForStrain,
                                         sex: profile.sex)

        // ── Workouts ──────────────────────────────────────────────────────────
        let workouts = WorkoutDetector.detect(
            hr: hr, gravity: gravity,
            restingHR: restingHRDaily.map(Double.init),
            maxHR: maxHROverride,
            age: profile.age > 0 ? profile.age : nil,
            profile: profile)

        // ── Steps (APPROXIMATE) ───────────────────────────────────────────────
        // step_motion_counter@57 is a CUMULATIVE u16 running counter. The daily total is the SUM of
        // positive consecutive deltas across the day's samples. u16 wraparound: a negative delta
        // means the counter rolled past 65535, so add 65536. The day's ~42h read window may include
        // adjacent-day samples, so filter to the day first (local-day basis, like the sleep match
        // above; UTC when offset 0). ESTIMATE only — not
        // cloud/clinical parity.
        let stepsTotal: Int? = {
            // Prefer the full-calendar-day stream for the additive total; fall back to the
            // night-window stream when the caller didn't supply one (pure-function callers/tests).
            let sorted = (daySteps ?? steps).filter { dayString($0.ts, offsetSeconds: tzOffsetSeconds) == day }.sorted { $0.ts < $1.ts }
            if sorted.count < 2 { return nil }
            // A firmware reboot resets the counter and is byte-indistinguishable from a u16 wrap.
            // A genuine wrap yields a SMALL corrected delta (the steps since the last record); a
            // reset-from-low yields a huge one. Cap each corrected delta so a reboot can't inject
            // tens of thousands of phantom steps. Heuristic — partial, since a reset from a HIGH
            // prior count still looks like a small wrap; tune once @57's cadence is validated.
            let maxStepDelta = 30_000
            var total = 0
            for i in 1..<sorted.count {
                var delta = sorted[i].counter - sorted[i - 1].counter
                if delta < 0 { delta += 65_536 }  // u16 wraparound
                if delta >= 1 && delta <= maxStepDelta { total += delta }  // drop resets
            }
            if total <= 0 { return nil }
            // @57 counts motion ticks, not validated steps — the 5/MG counter overcounts. Divide
            // by the user-calibrated ticks-per-step (default 1.0 = raw pass-through; floor 0.5 so
            // a bad pref can at most double, never explode, the total). (#139)
            let scaled = Int((Double(total) / max(profile.stepTicksPerStep, 0.5)).rounded())
            return scaled > 0 ? scaled : nil
        }()

        // ── Daily calories (APPROXIMATE, HR-only whole-day estimate) ──────────
        // Whole-day active+resting energy from the full HR window, using the same resting/active
        // per-second model the per-workout estimate uses (resting BMR below activeThreshold, Keytel
        // active above). effMaxHR + restingHRDaily are the same effective HRmax / resting baseline
        // strain uses. Nil when there is no HR. A heart-rate ESTIMATE — not cloud/clinical parity.
        // Whole-day additive totals (steps above, calories here) are summed over the full UTC
        // calendar day supplied by the caller (dayHr / daySteps), NOT the ~42h sleep-detection
        // window — which, anchored to the current time-of-day, would drop a past day's late hours
        // and double-count seconds shared with adjacent days. Fall back to the night-window hr for
        // pure-function callers that don't supply dayHr. Strain keeps the full window (bounded log).
        let dayHrFiltered = (dayHr ?? hr).filter { dayString($0.ts, offsetSeconds: tzOffsetSeconds) == day }
        let activeKcalEst: Double? = dayHrFiltered.isEmpty ? nil : Calories.estimateDayCalories(
            dayHrFiltered, profile: profile, hrmax: effMaxHR,
            restingHR: restingHRDaily.map(Double.init))

        // ── Assemble DailyMetric ──────────────────────────────────────────────
        let daily = DailyMetric(
            day: day,
            totalSleepMin: matched.isEmpty ? nil : tstS / 60.0,
            efficiency: matched.isEmpty ? nil : efficiency,
            deepMin: matched.isEmpty ? nil : deepS / 60.0,
            remMin: matched.isEmpty ? nil : remS / 60.0,
            lightMin: matched.isEmpty ? nil : lightS / 60.0,
            disturbances: matched.isEmpty ? nil : disturbances,
            restingHr: restingHRDaily,
            avgHrv: avgHRVDaily,
            recovery: recovery,
            strain: strain,
            exerciseCount: workouts.count,
            spo2Pct: nil,
            skinTempDevC: skinTempDevC,
            respRateBpm: respRateDaily,
            steps: stepsTotal,
            activeKcalEst: activeKcalEst)
        _ = sleepStart; _ = sleepEnd  // available for callers wiring sleep_start/end columns

        // ── Cache rows ────────────────────────────────────────────────────────
        let cachedSleep = matched.map { s in
            CachedSleepSession(
                startTs: s.start, endTs: s.end,
                efficiency: s.efficiency,
                restingHr: s.restingHR,
                avgHrv: s.avgHRV,
                stagesJSON: encodeStages(s.stages))
        }

        // ── Per-score confidence tiers ────────────────────────────────────────
        let chargeConfidence = ScoreConfidence.charge(recovery: recovery, hrvBaseline: baselines.hrv)
        let effortConfidence = ScoreConfidence.effort(strain: strain, hrSampleCount: hr.count)
        let restConfidence = ScoreConfidence.rest(hasSession: !matched.isEmpty,
                                                  hasStagedSleep: hasStagedSleep)

        return DayResult(daily: daily, sleepSessions: matched, cachedSleep: cachedSleep,
                         workouts: workouts, recovery: recovery, strain: strain,
                         nightlySkinTempC: nightlySkinTempC,
                         restScore: restScore,
                         chargeConfidence: chargeConfidence,
                         effortConfidence: effortConfidence,
                         restConfidence: restConfidence)
    }

    // MARK: - Rest composite (Charge/Effort/Rest)

    /// The 0–100 Rest score. Composite of four published-sleep-quality components:
    ///   - duration vs personal need (0.50): hours asleep ÷ need, clamped to 1.0.
    ///   - efficiency (0.20): asleep / in-bed, already in [0,1].
    ///   - restorative share (0.20): (deep + REM) ÷ asleep, clamped to a 0.50 target
    ///     (≈50% deep+REM is "full marks"; healthy adults sit ~40–50%).
    ///   - consistency (0.10): sleep/wake regularity in [0,1]; a single day carries no
    ///     regularity signal, so the caller supplies it from history — nil → neutral 0.5.
    /// All sub-scores clamp to [0,1]; the weighted sum scales to [0,100]. Kept
    /// dependency-free + constant-explicit so the Kotlin mirror is byte-identical.
    public enum Rest {
        /// Default personal sleep need (hours) before the caller refines it.
        public static let defaultNeedHours: Double = 8.0
        /// "Full marks" restorative (deep+REM) share of asleep time.
        public static let restorativeTarget: Double = 0.50
        /// Neutral consistency when the caller supplies no regularity signal.
        public static let neutralConsistency: Double = 0.5

        public static let wDuration: Double = 0.50
        public static let wEfficiency: Double = 0.20
        public static let wRestorative: Double = 0.20
        public static let wConsistency: Double = 0.10

        /// Build the composite. `tstSeconds` = total sleep time, `restorativeSeconds` =
        /// deep+REM seconds. Returns a value in [0,100].
        public static func composite(tstSeconds: Double,
                                     inBedSeconds: Double,
                                     efficiency: Double,
                                     restorativeSeconds: Double,
                                     needHours: Double,
                                     consistency: Double?) -> Double {
            func clamp01(_ x: Double) -> Double { max(0.0, min(1.0, x)) }

            let needSeconds = max(needHours, 0.1) * 3600.0
            let durationScore = clamp01(tstSeconds / needSeconds)
            let efficiencyScore = clamp01(efficiency)
            let restorativeScore = tstSeconds > 0
                ? clamp01((restorativeSeconds / tstSeconds) / restorativeTarget)
                : 0.0
            let consistencyScore = clamp01(consistency ?? neutralConsistency)

            let weighted = wDuration * durationScore
                + wEfficiency * efficiencyScore
                + wRestorative * restorativeScore
                + wConsistency * consistencyScore
            // weighted is in [0,1] (weights sum to 1). Scale to [0,100] and round to 2dp.
            return (weighted * 10000.0).rounded() / 100.0
        }

        /// Rest composite [0,100] derived from a persisted `DailyMetric` (the pass-2 / display path —
        /// the raw streams are gone, but the night's totals remain). nil when there's no sleep.
        /// Single source of truth so the persisted `sleep_performance` series and the Charge
        /// "Rest quality" term agree. `consistency` is the caller's regularity signal (nil → neutral).
        public static func composite(daily d: DailyMetric, needHours: Double = defaultNeedHours,
                                     consistency: Double? = nil) -> Double? {
            guard let tstMin = d.totalSleepMin, tstMin > 0, let eff = d.efficiency else { return nil }
            let tstSec = tstMin * 60.0
            let restorativeSec = ((d.deepMin ?? 0) + (d.remMin ?? 0)) * 60.0
            return composite(tstSeconds: tstSec, inBedSeconds: tstSec / max(eff, 0.01),
                             efficiency: eff, restorativeSeconds: restorativeSec,
                             needHours: needHours, consistency: consistency)
        }
    }

    /// Round to 2 decimal places (matches the imported/demo skin-temp deviation precision).
    static func round2(_ v: Double) -> Double { (v * 100.0).rounded() / 100.0 }

    /// Min worn, in-bed skin-temp samples (1 Hz ⇒ seconds) before a nightly mean is trusted.
    /// ~5 min guards against a few stray samples fabricating a baseline value.
    static let minSkinTempSamples = 300

    /// Plausible worn skin-temperature range (°C). Off-wrist/charging samples drift to ambient
    /// and are excluded; the strap's own decode gate is the looser 5–45.
    static let skinTempMinC = 28.0
    static let skinTempMaxC = 42.0

    /// Wear-gated mean in-bed skin temperature (°C) for the night, or nil when too few worn
    /// samples. A sample counts when (a) its timestamp falls inside a detected in-bed `sessions`
    /// span, (b) a concurrent HR sample reads a worn, alive BPM (the strap streams HR only
    /// on-wrist), and (c) the value is in the plausible worn range — so an on-charger interval
    /// drifting to ambient can't poison the nightly mean. °C = raw/100 — the firmware stores
    /// CENTIDEGREES in skin_temp_raw@73, not the AS6221's native 1/128 register units: the real
    /// captures in Whoop5HistoricalTests read worn=3057 / off-wrist=2247, which under /100 are
    /// 30.6 °C skin and 22.5 °C room ambient (physically right on both ends) but under /128 are
    /// 23.9 °C and 17.6 °C — "skin" colder than any live wrist, and below the 28 °C worn gate, so
    /// /128 silently dropped every real night (PR #97 review, tigercraft4; user report #166).
    /// Matches the Android decoder's /100 for the same register. All values APPROXIMATE.
    static func wornNightlySkinTempC(_ sessions: [SleepSession],
                                     hr: [HRSample],
                                     skinTemp: [SkinTempSample],
                                     minSamples: Int = minSkinTempSamples) -> Double? {
        if sessions.isEmpty || skinTemp.isEmpty { return nil }
        var wornSeconds = Set<Int>(minimumCapacity: hr.count)
        for h in hr where (30...220).contains(h.bpm) { wornSeconds.insert(h.ts) }
        var sum = 0.0
        var n = 0
        for t in skinTemp {
            if !wornSeconds.contains(t.ts) { continue }
            if !sessions.contains(where: { t.ts >= $0.start && t.ts <= $0.end }) { continue }
            let c = Double(t.raw) / 100.0
            if c < skinTempMinC || c > skinTempMaxC { continue }
            sum += c
            n += 1
        }
        return n >= minSamples ? sum / Double(n) : nil
    }
}
