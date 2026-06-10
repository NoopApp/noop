import Foundation
import Combine
import WhoopProtocol
import WhoopStore
import StrandAnalytics

/// On-device "intelligence": computes recovery / day-strain / sleep from the raw strap streams using
/// the same model shape WHOOP uses (HRV vs personal baseline ~60%, resting HR ~20%, sleep ~15%,
/// respiration ~5%; strain 0–21 from cardiovascular load). This is what makes NOOP independent of
/// WHOOP's cloud — for any day the strap collected raw data with NOOP connected, NOOP scores it
/// itself rather than relying on the values WHOOP computed in the imported CSV.
@MainActor
final class IntelligenceEngine: ObservableObject {
    private let repo: Repository
    private let profile: ProfileStore
    private let deviceId: String

    @Published var results: [Computed] = []      // newest first
    @Published var computing = false
    @Published var note: String?

    struct Computed: Identifiable {
        let day: String
        let recovery: Double?
        let strain: Double?
        let sleepMin: Double?
        let hrv: Double?
        let rhr: Int?
        var id: String { day }
    }

    init(repo: Repository, profile: ProfileStore, deviceId: String) {
        self.repo = repo; self.profile = profile; self.deviceId = deviceId
    }

    /// Compute on-device scores for each of the last `maxDays` that actually has raw HR data.
    /// Personal baselines (HRV / resting HR) are folded from the imported history, so even the first
    /// live night can be scored against your norm.
    func analyzeRecent(maxDays: Int = 21) async {
        guard !computing else { return }
        guard let store = await repo.storeHandle() else { note = "No on-device store yet."; return }
        guard let hrvCfg = Baselines.metricCfg["hrv"],
              let rhrCfg = Baselines.metricCfg["resting_hr"],
              let respCfg = Baselines.metricCfg["resp"],
              let skinCfg = Baselines.metricCfg["skin_temp"] else { return }

        computing = true
        defer { computing = false }

        let up = UserProfile(weightKg: profile.weightKg, heightCm: profile.heightCm,
                             age: Double(profile.age), sex: profile.sex)

        let maxHR = profile.hrMaxOverride > 0 ? Double(profile.hrMaxOverride) : nil
        let now = Int(Date().timeIntervalSince1970)
        // Device wall-clock offset (seconds east of UTC) for the sleep detector's daytime
        // false-sleep guard (#90): the stager places each window's center on the LOCAL clock
        // so only genuinely-daytime windows face the stricter nap bar. (Computed once; a DST
        // boundary inside the window is a negligible edge case for an hour-of-day band.)
        let tzOffset = TimeZone.current.secondsFromGMT()

        // ── Pass 1: analyse each offloaded night against the IMPORTED-ONLY baseline. For a BLE-only
        // user `repo.days` (imported) is empty, so the HRV baseline isn't usable yet and recovery is
        // null here — but each night's avgHrv/restingHr are computed baseline-INDEPENDENTLY, so we
        // harvest them to SEED the baseline and re-score in pass 2. foldHistory winsorizes outliers;
        // repo.days is published oldest→newest, so the replay order is already chronological. (#78)
        let hist = repo.days
        let hrvBase1 = Baselines.foldHistory(hist.map { $0.avgHrv }, cfg: hrvCfg)
        let rhrBase1 = Baselines.foldHistory(hist.map { $0.restingHr.map(Double.init) }, cfg: rhrCfg)
        let baselines1 = AnalyticsEngine.ProfileBaselines(hrv: hrvBase1, restingHR: rhrBase1)

        // Keep each night's small result (daily metrics + sessions), NOT the raw streams — every field
        // except recovery is baseline-independent, so pass 2 only re-scores the cheap recovery
        // composite. The hr/rr/resp/gravity arrays go out of scope each iteration (memory stays bounded).
        var scoredNights: [(daily: DailyMetric, strain: Double?, cachedSleep: [CachedSleepSession],
                            workouts: [ExerciseSession], nightlySkin: Double?)] = []
        // Nightly values harvested in pass 1, keyed by day, to seed the pass-2 baseline.
        var nightlyHrvByDay: [String: Double?] = [:]
        var nightlyRhrByDay: [String: Double?] = [:]
        // On-device RSA respiration + wear-gated skin-temp means (baseline-independent), harvested to
        // seed resp/skin-temp baselines the same way avgHrv seeds the HRV baseline.
        var nightlyRespByDay: [String: Double?] = [:]
        var nightlySkinByDay: [String: Double?] = [:]

        for offset in 0..<maxDays {
            let dayStart = now - offset * 86_400
            let day = AnalyticsEngine.dayString(dayStart)
            // Read a generous window around the night that ends on `day`; the stager finds the span.
            let from = dayStart - 30 * 3_600
            let to = dayStart + 12 * 3_600

            let hr = (try? await store.hrSamples(deviceId: deviceId, from: from, to: to, limit: 200_000)) ?? []
            guard hr.count >= 200 else { continue }   // need real raw data, not a stray sample
            let rr = (try? await store.rrIntervals(deviceId: deviceId, from: from, to: to, limit: 200_000)) ?? []
            let resp = (try? await store.respSamples(deviceId: deviceId, from: from, to: to, limit: 200_000)) ?? []
            let grav = (try? await store.gravitySamples(deviceId: deviceId, from: from, to: to, limit: 200_000)) ?? []
            let steps = (try? await store.stepSamples(deviceId: deviceId, from: from, to: to, limit: 200_000)) ?? []
            let skin = (try? await store.skinTempSamples(deviceId: deviceId, from: from, to: to, limit: 200_000)) ?? []

            // Calendar-day window for the ADDITIVE daily totals (steps + calories). The night window
            // above is anchored to the current UTC time-of-day and ends at dayStart+12h, so for a PAST
            // day whose late hours sit after that bound those hours are never read and the totals
            // undercount. Read exactly [midnightUtc(day), midnightUtc(day)+86400) and hand it to
            // analyzeDay's dayHr/daySteps, which use it ONLY for those totals. (floorMod so the
            // midnight floor is correct for any sign; the store range is inclusive, so end at -1 s.)
            let dayMid = dayStart - ((dayStart % 86_400) + 86_400) % 86_400
            let dayEnd = dayMid + 86_400 - 1
            let dayHr = (try? await store.hrSamples(deviceId: deviceId, from: dayMid, to: dayEnd, limit: 200_000)) ?? []
            let daySteps = (try? await store.stepSamples(deviceId: deviceId, from: dayMid, to: dayEnd, limit: 200_000)) ?? []

            let res = await Task.detached(priority: .utility) {
                AnalyticsEngine.analyzeDay(day: day, hr: hr, rr: rr, resp: resp, gravity: grav,
                                           steps: steps, dayHr: dayHr, daySteps: daySteps,
                                           skinTemp: skin,
                                           profile: up, baselines: baselines1, maxHROverride: maxHR,
                                           tzOffsetSeconds: tzOffset)
            }.value
            nightlyHrvByDay[res.daily.day] = res.daily.avgHrv
            nightlyRhrByDay[res.daily.day] = res.daily.restingHr.map(Double.init)
            nightlyRespByDay[res.daily.day] = res.daily.respRateBpm
            nightlySkinByDay[res.daily.day] = res.nightlySkinTempC
            scoredNights.append((daily: res.daily, strain: res.strain, cachedSleep: res.cachedSleep,
                                 workouts: res.workouts, nightlySkin: res.nightlySkinTempC))
            await Task.yield()
        }

        // ── Seed the baseline from the UNION of imported nightly history + the values just computed.
        // THIS is the BLE-only recovery fix: the "-noop" nightly avgHrv/restingHr finally feed the
        // baseline so a strap-only user crosses Baselines.minNightsSeed and recovery lights up.
        // IMPORTED values win per day: write them first, then fill ONLY days the import doesn't cover
        // (Swift has no putIfAbsent — `dict[day] == nil` is true only when the KEY is absent, so a day
        // imported with a nil avgHrv stays imported, not overwritten by the computed value).
        var histHrvByDay: [String: Double?] = [:]
        var histRhrByDay: [String: Double?] = [:]
        var histRespByDay: [String: Double?] = [:]
        for d in hist {
            histHrvByDay[d.day] = d.avgHrv
            histRhrByDay[d.day] = d.restingHr.map(Double.init)
            histRespByDay[d.day] = d.respRateBpm
        }
        for (day, v) in nightlyHrvByDay where histHrvByDay[day] == nil { histHrvByDay[day] = v }
        for (day, v) in nightlyRhrByDay where histRhrByDay[day] == nil { histRhrByDay[day] = v }
        for (day, v) in nightlyRespByDay where histRespByDay[day] == nil { histRespByDay[day] = v }
        let hrvSeq = histHrvByDay.keys.sorted().map { histHrvByDay[$0]! }   // chronological [Double?]
        let rhrSeq = histRhrByDay.keys.sorted().map { histRhrByDay[$0]! }
        let respSeq = histRespByDay.keys.sorted().map { histRespByDay[$0]! }
        // Skin-temp baseline is on-device-only (imported rows carry skinTempDevC, not the raw mean),
        // so fold purely over the pass-1 nightly means in chronological order.
        let skinSeq = nightlySkinByDay.keys.sorted().map { nightlySkinByDay[$0]! }
        // Resp baseline gated on `usable`: RecoveryScorer includes the resp term whenever a
        // baseline object is present — a CALIBRATING (<4-night) baseline would let one noisy
        // RSA night move recovery (mirrors the skin-temp use-site gate; honest cold-start).
        let respFold = Baselines.foldHistory(respSeq, cfg: respCfg)
        let baselines2 = AnalyticsEngine.ProfileBaselines(
            hrv: Baselines.foldHistory(hrvSeq, cfg: hrvCfg),
            restingHR: Baselines.foldHistory(rhrSeq, cfg: rhrCfg),
            resp: respFold.usable ? respFold : nil,
            skinTemp: Baselines.foldHistory(skinSeq, cfg: skinCfg))

        // Real (non-detected) workouts in the scored window, used to de-duplicate detected bouts so a
        // user who BOTH has real sessions AND wears the strap doesn't see the same session twice (the
        // per-day merge precedence does not cover the workout table). This covers BOTH directions of
        // the cross-source duplicate (#107): the strap source carries imported WHOOP rows AND manual /
        // re-labelled rows (both written under `deviceId`), and apple-health carries Health imports —
        // a detected bout overlapping ANY of them is skipped below. Port of the Android dedup block.
        let computedId = deviceId + "-noop"
        let windowStart = now - maxDays * 86_400 - 30 * 3_600
        var realWorkouts = (try? await store.workouts(deviceId: deviceId, from: windowStart,
                                                       to: now, limit: 100_000)) ?? []
        realWorkouts += (try? await store.workouts(deviceId: "apple-health", from: windowStart,
                                                    to: now, limit: 100_000)) ?? []

        // ── Pass 2: re-score ONLY recovery against the now-seeded baseline (cheap, baseline-dependent);
        // every other field was computed once in pass 1. Recovery stays nil until the HRV baseline is
        // usable (≥ minNightsSeed valid nights) — honest cold-start, via RecoveryScorer's usable gate.
        var out: [Computed] = []
        var dailies: [DailyMetric] = []
        var cachedSleep: [CachedSleepSession] = []
        var workoutRows: [WorkoutRow] = []
        for night in scoredNights {
            let recovery = recomputeRecovery(night.daily, baselines2)
            let skinDev = recomputeSkinTempDev(night.nightlySkin, baselines2.skinTemp)
            out.append(Computed(day: night.daily.day, recovery: recovery, strain: night.strain,
                                sleepMin: night.daily.totalSleepMin, hrv: night.daily.avgHrv,
                                rhr: night.daily.restingHr))
            dailies.append(night.daily.with(recovery: recovery, skinTempDevC: skinDev))
            cachedSleep.append(contentsOf: night.cachedSleep)
            // Persist the detected workouts the pipeline already computes (previously discarded).
            // Skip any bout overlapping a real imported workout so import+wear users don't
            // double-count. sport = "detected"; energyKcal is the APPROXIMATE Keytel/BMR total.
            for s in night.workouts {
                if realWorkouts.contains(where: { s.start < $0.endTs && $0.startTs < s.end }) { continue }
                workoutRows.append(WorkoutRow(startTs: s.start, endTs: s.end,
                                              sport: "detected", source: computedId,
                                              durationS: s.durationS, energyKcal: s.caloriesKcal,
                                              avgHr: Int(s.avgHR), maxHr: s.peakHR,
                                              strain: s.strain, distanceM: nil,
                                              zonesJSON: nil, notes: nil))
            }
        }

        // Persist the computed scores under a dedicated "-noop" source so the WHOLE dashboard
        // (Today / Recovery / Strain / Sleep / Trends), not just this screen, reads them. The
        // Repository merges these UNDER any imported "my-whoop" rows, so a real WHOOP import
        // always wins; this only fills the days the strap collected but no import covered.
        if !dailies.isEmpty { _ = try? await store.upsertDailyMetrics(dailies, deviceId: computedId) }
        if !cachedSleep.isEmpty { _ = try? await store.upsertSleepSessions(cachedSleep, deviceId: computedId) }
        // Make re-detection idempotent across runs: clear the prior computed detected workouts in the
        // scored window (a bout's startTs can drift as more HR arrives, which would otherwise orphan
        // stale rows under the (deviceId,startTs,sport) key), then re-insert.
        _ = try? await store.deleteWorkouts(deviceId: computedId, sport: "detected",
                                            from: windowStart, to: now)
        if !workoutRows.isEmpty { _ = try? await store.upsertWorkouts(workoutRows, deviceId: computedId) }

        results = out
        note = out.isEmpty
            ? "No scored nights yet. Wear the strap with NOOP connected overnight and the engine will score your recovery, strain and sleep itself, no WHOOP cloud required."
            : nil

        // Reload the dashboard caches so the freshly computed scores show up immediately.
        if !dailies.isEmpty { await repo.refresh() }
    }

    /// Re-score ONLY the recovery composite for a day against a (re-seeded) baseline. Every other field
    /// in `daily` is baseline-independent and already final from pass 1. Returns nil until the HRV
    /// baseline is usable (RecoveryScorer gates on `hrvBaseline.usable`, i.e. ≥ minNightsSeed valid
    /// nights) — so the honest null-until-4-nights cold-start is free. Mirrors AnalyticsEngine's own
    /// recovery call + Android IntelligenceEngine.recomputeRecovery. (#78)
    private func recomputeRecovery(_ daily: DailyMetric, _ baselines: AnalyticsEngine.ProfileBaselines) -> Double? {
        guard let hrvVal = daily.avgHrv, let rhrVal = daily.restingHr, let hrvBase = baselines.hrv else { return nil }
        return RecoveryScorer.recovery(hrv: hrvVal, rhr: Double(rhrVal), resp: daily.respRateBpm,
                                       hrvBaseline: hrvBase, rhrBaseline: baselines.restingHR,
                                       respBaseline: baselines.resp, sleepPerf: daily.efficiency)
    }

    /// Re-derive the skin-temperature deviation (°C) for a night against the freshly-seeded personal
    /// baseline, mirroring the avgHrv→recovery re-score. Nil when the night had no wear-gated mean or
    /// the skin-temp baseline isn't usable yet (< minNightsSeed) — honest cold-start. Rounded to 2 dp
    /// to match the imported/demo precision. APPROXIMATE.
    private func recomputeSkinTempDev(_ nightly: Double?, _ base: BaselineState?) -> Double? {
        guard let v = nightly, let b = base, b.usable else { return nil }
        return (Baselines.deviation(v, state: b).delta * 100.0).rounded() / 100.0
    }
}

private extension DailyMetric {
    /// Rebuild the immutable DailyMetric with a substituted recovery + skin-temp deviation
    /// (the struct has no `copy()`). (#78)
    func with(recovery r: Double?, skinTempDevC sd: Double?) -> DailyMetric {
        DailyMetric(day: day, totalSleepMin: totalSleepMin, efficiency: efficiency, deepMin: deepMin,
                    remMin: remMin, lightMin: lightMin, disturbances: disturbances, restingHr: restingHr,
                    avgHrv: avgHrv, recovery: r, strain: strain, exerciseCount: exerciseCount,
                    spo2Pct: spo2Pct, skinTempDevC: sd, respRateBpm: respRateBpm,
                    steps: steps, activeKcalEst: activeKcalEst)
    }
}
