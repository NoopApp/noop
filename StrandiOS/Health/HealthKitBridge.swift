#if os(iOS)
import Foundation
import HealthKit
import WhoopStore

/// Two-way Apple Health bridge for the iOS app.
///
/// iOS has HealthKit (macOS does not), so the iOS target can do far more than parse a static export:
/// it reads the user's own Health data live and maps it onto the **same** `WhoopStore` rows the
/// macOS importer produces (under the `apple-health` source id), and it writes NOOP-computed metrics
/// back into Apple Health. Everything stays on-device and strictly opt-in.
@MainActor
final class HealthKitBridge: ObservableObject {

    enum AuthState: Equatable { case unknown, unavailable, denied, authorized }

    @Published private(set) var auth: AuthState = .unknown
    @Published private(set) var lastSync: Date?
    @Published private(set) var syncing = false

    private let store = HKHealthStore()
    private let repo: Repository
    /// Source id imported HealthKit data lands under (matches `AppModel.appleDeviceId`).
    private let appleDeviceId: String
    /// NOOP's own strap-derived source id, read back when writing into Health.
    private let noopDeviceId: String

    init(repo: Repository, appleDeviceId: String, noopDeviceId: String) {
        self.repo = repo
        self.appleDeviceId = appleDeviceId
        self.noopDeviceId = noopDeviceId
        if !HKHealthStore.isHealthDataAvailable() { auth = .unavailable }
    }

    // MARK: - Types

    private var readTypes: Set<HKObjectType> {
        var s = Set<HKObjectType>()
        for id in HealthKitBridge.quantityReadIds { if let t = HKObjectType.quantityType(forIdentifier: id) { s.insert(t) } }
        if let sleep = HKObjectType.categoryType(forIdentifier: .sleepAnalysis) { s.insert(sleep) }
        s.insert(HKObjectType.workoutType())
        return s
    }

    private var writeTypes: Set<HKSampleType> {
        var s = Set<HKSampleType>()
        for id in HealthKitBridge.quantityWriteIds { if let t = HKObjectType.quantityType(forIdentifier: id) { s.insert(t) } }
        if let sleep = HKObjectType.categoryType(forIdentifier: .sleepAnalysis) { s.insert(sleep) }
        return s
    }

    // Every id here ends up in the HealthKit permission dialog. Only request what `sync` actually
    // aggregates into `DayAgg`; adding read scopes the app never consumes makes the consent prompt
    // noisier and surfaces a privacy ask we don't honour.
    private static let quantityReadIds: [HKQuantityTypeIdentifier] = [
        .heartRate, .restingHeartRate, .heartRateVariabilitySDNN, .oxygenSaturation,
        .respiratoryRate, .bodyTemperature, .stepCount, .activeEnergyBurned,
        .basalEnergyBurned, .vo2Max
    ]
    private static let quantityWriteIds: [HKQuantityTypeIdentifier] = [
        .restingHeartRate, .heartRateVariabilitySDNN, .oxygenSaturation, .respiratoryRate
    ]

    // MARK: - Authorization

    /// Request read + write permission. HealthKit never reveals whether *read* was granted, so we
    /// treat a successful request as `.authorized` and let queries return empty if the user declined.
    func requestAuthorization() async {
        guard HKHealthStore.isHealthDataAvailable() else { auth = .unavailable; return }
        do {
            try await store.requestAuthorization(toShare: writeTypes, read: readTypes)
            auth = .authorized
        } catch {
            auth = .denied
        }
    }

    // MARK: - Read → store

    /// Pull the last `days` of Apple Health into the on-device store under the `apple-health` source,
    /// then write NOOP's own computed metrics back into Health. Safe to call repeatedly (idempotent
    /// upserts keyed by day).
    func sync(days: Int = 30) async {
        guard auth == .authorized, !syncing else { return }
        syncing = true
        defer { syncing = false }
        guard let store = await repo.storeHandle() else { return }

        let cal = Calendar.current
        let end = Date()
        guard let start = cal.date(byAdding: .day, value: -days, to: cal.startOfDay(for: end)) else { return }

        var byDay: [String: DayAgg] = [:]
        func agg(_ day: String) -> DayAgg { byDay[day] ?? DayAgg() }

        // Quantity aggregates per day.
        await collect(.restingHeartRate, unit: HKUnit.count().unitDivided(by: .minute()), start: start, end: end, op: .discreteAverage) { day, v in
            var a = agg(day); a.restingHr = v; byDay[day] = a
        }
        await collect(.heartRate, unit: HKUnit.count().unitDivided(by: .minute()), start: start, end: end, op: .discreteAverage) { day, v in
            var a = agg(day); a.avgHr = v; byDay[day] = a
        }
        await collect(.heartRate, unit: HKUnit.count().unitDivided(by: .minute()), start: start, end: end, op: .discreteMax) { day, v in
            var a = agg(day); a.maxHr = v; byDay[day] = a
        }
        await collect(.heartRateVariabilitySDNN, unit: .secondUnit(with: .milli), start: start, end: end, op: .discreteAverage) { day, v in
            var a = agg(day); a.hrv = v; byDay[day] = a
        }
        await collect(.oxygenSaturation, unit: .percent(), start: start, end: end, op: .discreteAverage) { day, v in
            var a = agg(day); a.spo2 = v * 100; byDay[day] = a   // 0…1 → percent
        }
        await collect(.respiratoryRate, unit: HKUnit.count().unitDivided(by: .minute()), start: start, end: end, op: .discreteAverage) { day, v in
            var a = agg(day); a.respRate = v; byDay[day] = a
        }
        await collect(.stepCount, unit: .count(), start: start, end: end, op: .cumulativeSum) { day, v in
            var a = agg(day); a.steps = v; byDay[day] = a
        }
        await collect(.activeEnergyBurned, unit: .kilocalorie(), start: start, end: end, op: .cumulativeSum) { day, v in
            var a = agg(day); a.activeKcal = v; byDay[day] = a
        }
        await collect(.basalEnergyBurned, unit: .kilocalorie(), start: start, end: end, op: .cumulativeSum) { day, v in
            var a = agg(day); a.basalKcal = v; byDay[day] = a
        }
        await collect(.vo2Max, unit: HKUnit(from: "ml/kg*min"), start: start, end: end, op: .discreteAverage) { day, v in
            var a = agg(day); a.vo2max = v; byDay[day] = a
        }

        // Sleep minutes per day (asleep stages summed; attributed to wake day).
        await collectSleep(start: start, end: end) { day, asleepMin, deepMin, remMin, coreMin in
            var a = agg(day)
            a.asleepMin = asleepMin; a.deepMin = deepMin; a.remMin = remMin; a.coreMin = coreMin
            byDay[day] = a
        }

        // Build + upsert the store rows under the apple-health source.
        let appleRows = byDay.map { (day, a) in
            AppleDaily(day: day, steps: a.steps.map { Int($0) },
                       activeKcal: a.activeKcal, basalKcal: a.basalKcal, vo2max: a.vo2max,
                       avgHr: a.avgHr.map { Int($0.rounded()) }, maxHr: a.maxHr.map { Int($0.rounded()) },
                       walkingHr: nil, weightKg: nil)
        }
        let dmRows = byDay.map { (day, a) in
            DailyMetric(day: day, totalSleepMin: a.asleepMin, efficiency: nil,
                        deepMin: a.deepMin, remMin: a.remMin, lightMin: a.coreMin, disturbances: nil,
                        restingHr: a.restingHr.map { Int($0.rounded()) }, avgHrv: a.hrv,
                        recovery: nil, strain: nil, exerciseCount: nil,
                        spo2Pct: a.spo2, skinTempDevC: nil, respRateBpm: a.respRate)
        }
        try? await store.upsertAppleDaily(appleRows, deviceId: appleDeviceId)
        try? await store.upsertDailyMetrics(dmRows, deviceId: appleDeviceId)

        await writeBack(whoopStore: store)
        lastSync = Date()
    }

    // MARK: - Write back (NOOP → Health)

    /// Write NOOP's strap-derived daily metrics (resting HR, HRV, SpO₂, respiratory rate) into Apple
    /// Health so they appear across the user's Health ecosystem. Idempotency is left to HealthKit's
    /// own de-duplication by sample time; we only write the most recent `days` of NOOP metrics.
    private func writeBack(whoopStore: WhoopStore, days: Int = 14) async {
        guard auth == .authorized else { return }
        let cal = Calendar.current
        let to = HealthKitBridge.dayString(Date())
        guard let fromDate = cal.date(byAdding: .day, value: -days, to: Date()) else { return }
        let from = HealthKitBridge.dayString(fromDate)
        guard let rows = try? await whoopStore.dailyMetrics(deviceId: noopDeviceId, from: from, to: to) else { return }

        var samples: [HKObject] = []
        for row in rows {
            guard let date = HealthKitBridge.date(from: row.day) else { continue }
            let noon = cal.date(bySettingHour: 12, minute: 0, second: 0, of: date) ?? date
            if let rhr = row.restingHr, let t = HKQuantityType.quantityType(forIdentifier: .restingHeartRate) {
                samples.append(HKQuantitySample(type: t, quantity: .init(unit: HKUnit.count().unitDivided(by: .minute()), doubleValue: Double(rhr)), start: noon, end: noon))
            }
            if let hrv = row.avgHrv, let t = HKQuantityType.quantityType(forIdentifier: .heartRateVariabilitySDNN) {
                samples.append(HKQuantitySample(type: t, quantity: .init(unit: .secondUnit(with: .milli), doubleValue: hrv), start: noon, end: noon))
            }
            if let spo2 = row.spo2Pct, let t = HKQuantityType.quantityType(forIdentifier: .oxygenSaturation) {
                samples.append(HKQuantitySample(type: t, quantity: .init(unit: .percent(), doubleValue: spo2 / 100), start: noon, end: noon))
            }
            if let rr = row.respRateBpm, let t = HKQuantityType.quantityType(forIdentifier: .respiratoryRate) {
                samples.append(HKQuantitySample(type: t, quantity: .init(unit: HKUnit.count().unitDivided(by: .minute()), doubleValue: rr), start: noon, end: noon))
            }
        }
        guard !samples.isEmpty else { return }
        try? await store.save(samples)
    }

    private struct DayAgg {
        var restingHr: Double?; var avgHr: Double?; var maxHr: Double?; var hrv: Double?
        var spo2: Double?; var respRate: Double?; var steps: Double?
        var activeKcal: Double?; var basalKcal: Double?; var vo2max: Double?
        var asleepMin: Double?; var deepMin: Double?; var remMin: Double?; var coreMin: Double?
    }

    private func collect(_ id: HKQuantityTypeIdentifier, unit: HKUnit, start: Date, end: Date,
                         op: HKStatisticsOptions, sink: @escaping (String, Double) -> Void) async {
        guard let type = HKQuantityType.quantityType(forIdentifier: id) else { return }
        let cal = Calendar.current
        let anchor = cal.startOfDay(for: start)
        let predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: .strictStartDate)
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            let q = HKStatisticsCollectionQuery(quantityType: type, quantitySamplePredicate: predicate,
                                                options: op, anchorDate: anchor,
                                                intervalComponents: DateComponents(day: 1))
            q.initialResultsHandler = { _, results, _ in
                results?.enumerateStatistics(from: start, to: end) { stats, _ in
                    let q: HKQuantity?
                    switch op {
                    case .cumulativeSum:    q = stats.sumQuantity()
                    case .discreteAverage:  q = stats.averageQuantity()
                    case .discreteMax:      q = stats.maximumQuantity()
                    default:                q = stats.averageQuantity()
                    }
                    if let q { sink(HealthKitBridge.dayString(stats.startDate), q.doubleValue(for: unit)) }
                }
                cont.resume()
            }
            store.execute(q)
        }
    }

    private func collectSleep(start: Date, end: Date,
                              sink: @escaping (String, Double?, Double?, Double?, Double?) -> Void) async {
        guard let type = HKObjectType.categoryType(forIdentifier: .sleepAnalysis) else { return }
        let predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: [])
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            let q = HKSampleQuery(sampleType: type, predicate: predicate, limit: HKObjectQueryNoLimit, sortDescriptors: nil) { _, samples, _ in
                var asleep: [String: Double] = [:], deep: [String: Double] = [:]
                var rem: [String: Double] = [:], core: [String: Double] = [:]
                for case let s as HKCategorySample in samples ?? [] {
                    let mins = s.endDate.timeIntervalSince(s.startDate) / 60
                    let day = HealthKitBridge.dayString(s.endDate)
                    switch s.value {
                    case HKCategoryValueSleepAnalysis.asleepDeep.rawValue:
                        deep[day, default: 0] += mins; asleep[day, default: 0] += mins
                    case HKCategoryValueSleepAnalysis.asleepREM.rawValue:
                        rem[day, default: 0] += mins; asleep[day, default: 0] += mins
                    case HKCategoryValueSleepAnalysis.asleepCore.rawValue, HKCategoryValueSleepAnalysis.asleepUnspecified.rawValue:
                        core[day, default: 0] += mins; asleep[day, default: 0] += mins
                    default:
                        break
                    }
                }
                for day in Set(asleep.keys) {
                    sink(day, asleep[day], deep[day], rem[day], core[day])
                }
                cont.resume()
            }
            store.execute(q)
        }
    }

    // MARK: - Date helpers

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"; f.timeZone = .current; return f
    }()
    private static func dayString(_ date: Date) -> String { dayFormatter.string(from: date) }
    private static func date(from day: String) -> Date? { dayFormatter.date(from: day) }
}
#endif
