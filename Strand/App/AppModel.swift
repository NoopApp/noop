import SwiftUI
import Combine
import WhoopProtocol
import WhoopStore

/// Data source currently running an import from the Data Sources screen.
enum DataSourceImportKind {
    case whoop
    case appleHealth
}

/// Root app state: owns the live BLE connection state and the CoreBluetooth engine.
/// More subsystems (Repository, AnalyticsEngine, ImportCoordinator) get wired in here
/// in later milestones.
@MainActor
final class AppModel: ObservableObject {
    /// Shared device id for both live capture (BLEManager) and imported history.
    let deviceId = "my-whoop"
    /// Source id for imported Apple Health data (stored beside Whoop for per-source pages + consensus).
    let appleDeviceId = "apple-health"
    /// Observable snapshot driven by the BLE engine (connection, HR, battery, log).
    let live: LiveState
    /// CoreBluetooth engine — scans, connects, bonds, streams.
    let ble: BLEManager
    /// Read model over the on-device store (dashboard + detail screens).
    let repo: Repository
    /// User profile (age/sex/body/HR-max) for zones, calories, baselines.
    let profile = ProfileStore()
    /// Behaviour settings: double-tap action, wear automation, zone coaching, smart alarm, illness watch.
    let behavior = BehaviorStore()
    /// On-device WHOOP-style recovery/strain/sleep computation from raw strap streams.
    let intelligence: IntelligenceEngine
    /// Opt-in AI coach (bring-your-own-key) — the one networked feature, off until the user enables it.
    let coach: AICoachEngine

    /// Timestamps of moments marked via a double-tap (persisted).
    @Published var moments: [Date] = []
    /// Illness/strain early-warning (recent RHR up + HRV down + skin-temp up vs baseline). nil = clear.
    @Published var healthAlert: String?
    private var lastDoubleTapAt: Date = .distantPast
    private var lastCoachZone: Int = -1
    // Stress-nudge state: rolling R-R buffer + a slow HRV baseline + a rate limiter.
    private var rrBuf: [Int] = []
    private var hrvBaseline: Double = 0
    private var lastStressBuzzAt: Date = .distantPast

    /// Import source currently writing to the local store, if any.
    @Published private var activeImportSource: DataSourceImportKind?
    /// Last WHOOP export import result surfaced in the WHOOP card.
    @Published var whoopImportSummary: String?
    /// Last Apple Health import result surfaced in the Apple Health card.
    @Published var appleHealthImportSummary: String?
    /// Typed failure flags per source — the summary's warning styling reads these instead of
    /// substring-matching the human-readable message (which misses errors like "Couldn't open
    /// the local store."). Surfaced on both the Data Sources cards and the onboarding import step.
    @Published var whoopImportFailed = false
    @Published var appleHealthImportFailed = false

    /// True while any data-source import is writing to the local store.
    var hasActiveImport: Bool { activeImportSource != nil }

    /// Returns true only for the source currently importing.
    func isImporting(_ source: DataSourceImportKind) -> Bool {
        activeImportSource == source
    }

    /// Whether the last import for a source ended in failure (for warning styling).
    func importFailed(_ source: DataSourceImportKind) -> Bool {
        switch source {
        case .whoop: return whoopImportFailed
        case .appleHealth: return appleHealthImportFailed
        }
    }

    /// Smoothed, display-ready live heart rate — median over a short window, spike-filtered.
    /// Every screen should show THIS, not the raw per-beat value (which swings with HRV).
    @Published var bpm: Int?
    private var hrWindow: [(t: Date, v: Double)] = []
    private var hrCancellables = Set<AnyCancellable>()

    init() {
        let live = LiveState()
        self.live = live
        self.ble = BLEManager(state: live, deviceId: "my-whoop")
        self.repo = Repository(deviceId: "my-whoop")
        self.intelligence = IntelligenceEngine(repo: repo, profile: profile, deviceId: "my-whoop")
        self.coach = AICoachEngine(repo: repo)
        // Smooth HR centrally so it's solid everywhere it's shown.
        live.$heartRate.sink { [weak self] _ in self?.ingestHR() }.store(in: &hrCancellables)
        live.$rr.sink { [weak self] _ in self?.ingestHR() }.store(in: &hrCancellables)

        // Physical-input + wear hooks (fired live by FrameRouter).
        live.onDoubleTap = { [weak self] in self?.handleDoubleTap() }
        live.onWristChange = { [weak self] worn in self?.handleWristChange(worn) }
        // HR-zone haptic coaching watches the smoothed bpm.
        $bpm.sink { [weak self] hr in self?.coachZone(hr) }.store(in: &hrCancellables)
        // Illness/strain early-warning recomputes when the daily history changes.
        repo.$days.sink { [weak self] days in self?.evaluateIllness(days) }.store(in: &hrCancellables)
        // Re-arm the strap's firmware alarm whenever it (re)bonds. A smart-alarm time changed while the
        // strap was away never reached it — the send is gated on bond — so the strap kept the OLD time
        // and fired at it (#59). removeDuplicates() fires once per bond; gated on enabled so a disabled
        // alarm doesn't disarm on every reconnect.
        live.$bonded.removeDuplicates().sink { [weak self] bonded in
            guard let self, bonded, self.behavior.smartAlarmEnabled else { return }
            self.applySmartAlarm()
        }.store(in: &hrCancellables)
        // A completed backfill has just written strap history. Refresh the dashboard cache,
        // but leave heavyweight analysis to its own guarded/background-friendly path.
        live.$lastSyncedAt
            .dropFirst()
            .compactMap { $0 }
            .removeDuplicates()
            .sink { [weak self] _ in
                Task { [weak self] in await self?.refreshAfterCompletedBackfill() }
            }
            .store(in: &hrCancellables)

        moments = (UserDefaults.standard.array(forKey: "moments") as? [Double] ?? [])
            .map { Date(timeIntervalSince1970: $0) }

        // Turn the strap's offloaded raw data into dashboard scores on launch and every 15
        // minutes, so recovery / strain / sleep populate from the strap itself with no import.
        // IntelligenceEngine computes, persists under "my-whoop-noop", and refreshes the dashboard.
        Task { [weak self] in
            guard let self else { return }
            await self.repo.refresh()                          // surface any imported data at once
            try? await Task.sleep(nanoseconds: 6_000_000_000)  // give the first offload a moment
            while !Task.isCancelled {
                await self.intelligence.analyzeRecent()
                try? await Task.sleep(nanoseconds: 900_000_000_000)  // 15 min, matches the offload cadence
            }
        }
    }

    private func refreshAfterCompletedBackfill() async {
        live.append(log: "Backfill: refreshing dashboard cache from completed sync")
        await repo.refresh(days: 120)
    }

    /// Fold a fresh reading into the smoothing window and republish a stable bpm.
    /// Prefers the strap's reported HR; falls back to 60000/R-R. Clamps to a plausible
    /// 30–220 range (rejects 0 / garbage spikes) and publishes the window MEDIAN.
    private func ingestHR() {
        var inst: Double?
        if let hr = live.heartRate, hr >= 30, hr <= 220 {
            inst = Double(hr)
        } else if let rr = live.rr.last, rr > 0 {
            let v = 60_000.0 / Double(rr)
            if v >= 30, v <= 220 { inst = v }
        }
        guard let inst else { return }
        let now = Date()
        hrWindow.append((now, inst))
        hrWindow.removeAll { now.timeIntervalSince($0.t) > 10 }   // ~10s window
        if hrWindow.count > 40 { hrWindow.removeFirst(hrWindow.count - 40) }
        let vals = hrWindow.map(\.v).sorted()
        bpm = vals.isEmpty ? nil : Int(vals[vals.count / 2].rounded())
        evaluateStress()
    }

    /// Drop the smoothing window and blank the hero number so a resume / re-attach shows "—"
    /// until a genuinely fresh sample arrives, instead of republishing the stale pre-gap median.
    /// Called on Live-tab entry / manual Start HR (see `startRealtimeHR`), NOT on the 30s keep-alive
    /// re-arm — so steady-state smoothing is untouched. Fixes #46 (HR jumped to a stale ~100 on
    /// reopen, then "slowly came back down" as fresh low samples refilled the window).
    func resetSmoothing() {
        hrWindow.removeAll()
        bpm = nil
    }

    /// Experimental resting stress nudge: track RMSSD vs a slow baseline; when HRV drops well below
    /// baseline while HR is calm (not exercising), buzz once — rate-limited to once / 15 min. Off by
    /// default; conservative so it rarely false-fires.
    private func evaluateStress() {
        guard behavior.stressNudge, live.bonded, live.worn else { return }
        let fresh = live.rr.filter { $0 > 300 && $0 < 2000 }   // plausible R-R (30–200 bpm)
        guard !fresh.isEmpty else { return }
        rrBuf.append(contentsOf: fresh)
        if rrBuf.count > 60 { rrBuf.removeFirst(rrBuf.count - 60) }
        guard rrBuf.count >= 20 else { return }
        let rmssd = AppModel.rmssd(rrBuf)
        guard rmssd > 0 else { return }
        hrvBaseline = hrvBaseline == 0 ? rmssd : hrvBaseline * 0.98 + rmssd * 0.02   // slow EMA
        guard let hr = bpm, hr >= 55, hr <= 100 else { return }   // resting band — not a workout
        let now = Date()
        if rmssd < hrvBaseline * 0.6, now.timeIntervalSince(lastStressBuzzAt) > 900 {
            lastStressBuzzAt = now
            buzz(loops: 1)
            live.append(log: "Stress nudge — take a paced breath")
        }
    }

    static func rmssd(_ rr: [Int]) -> Double {
        guard rr.count >= 2 else { return 0 }
        var sum = 0.0, n = 0
        for i in 1..<rr.count { let d = Double(rr[i] - rr[i - 1]); sum += d * d; n += 1 }
        return n > 0 ? (sum / Double(n)).squareRoot() : 0
    }

    /// Start scanning for the strap. When no model is given, use the one the user
    /// picked (persisted under "selectedWhoopModel"), so every scan entry point —
    /// Live, onboarding, the menu bar, Settings — honours the same choice.
    func scan(model: WhoopModel? = nil) {
        let chosen = model
            ?? UserDefaults.standard.string(forKey: "selectedWhoopModel").flatMap(WhoopModel.init(rawValue:))
            ?? .whoop4
        ble.connect(model: chosen)
    }
    func disconnect() { ble.disconnect() }

    /// Drop the current strap and clear bond state so a newly-picked strap model connects fresh
    /// (lets a user with both a WHOOP 4 and a 5/MG switch between them).
    func prepareStrapSwitch() { ble.prepareForModelSwitch() }

    /// Enable the realtime stream + mark it wanted so the keep-alive re-arms it (can't lapse).
    /// Blanks the stale smoothing window first (#46): on Live-tab entry / resume we don't want the
    /// pre-gap median republished, so the hero shows "—" until a fresh sample lands. The keep-alive
    /// re-arm goes through `ble.startRealtime()` directly, NOT here, so steady-state is untouched.
    func startRealtimeHR() {
        resetSmoothing()
        ble.startRealtime()
    }
    /// Stop the realtime stream (the lightweight 0x2A37 HR keeps recording regardless).
    func stopRealtimeHR() { ble.stopRealtime() }
    /// Ask the strap for a fresh battery reading.
    func getBattery() { ble.refreshBattery() }

    /// Fire a haptic buzz on the strap. patternId=2 is the graduated buzz confirmed on-device;
    /// `loops` sets the length. Used by the in-app test button and (later) notification alerts.
    /// Requires a bonded connection — no-op otherwise (the command characteristic is gated on bond).
    func buzz(loops: UInt8 = 2) {
        ble.send(.runHapticsPattern, payload: [2, loops, 0, 0, 0])
    }

    /// Fire a specific preset haptic pattern (patternId 0–6 on Harvard; loops sets length).
    /// Used by the notification-pattern picker and coaching features.
    func buzz(pattern: UInt8, loops: UInt8 = 1) {
        ble.send(.runHapticsPattern, payload: [pattern, loops, 0, 0, 0])
    }

    /// Arm (or clear) the strap's firmware alarm from the smart-alarm settings. The firmware alarm
    /// fires even if the Mac is asleep / NOOP is closed. No-op until bonded (send is gated on bond).
    func applySmartAlarm() {
        guard behavior.smartAlarmEnabled else { ble.disableStrapAlarm(); return }
        let cal = Calendar.current
        let now = Date()
        var next = cal.date(bySettingHour: behavior.smartAlarmMinutes / 60,
                            minute: behavior.smartAlarmMinutes % 60, second: 0, of: now) ?? now
        if next <= now { next = cal.date(byAdding: .day, value: 1, to: next) ?? next }
        ble.armStrapAlarm(at: next)
    }

    // MARK: - Physical inputs / wear automation

    private func handleDoubleTap() {
        let now = Date()
        guard now.timeIntervalSince(lastDoubleTapAt) > 1.2 else { return }   // debounce repeats
        lastDoubleTapAt = now
        live.append(log: "Double-tap → \(behavior.doubleTapAction.label)")
        runMacAction(behavior.doubleTapAction, shortcut: behavior.doubleTapShortcut)
    }

    /// Run a configured Mac action. In-app actions (buzz/moment) stay on-device; lock + shortcuts
    /// go through MacActions.
    func runMacAction(_ kind: MacActionKind, shortcut: String) {
        switch kind {
        case .none: break
        case .lockScreen: if !MacActions.lockScreen() { MacActions.runShortcut("Lock Screen") }
        case .buzzBack: buzz(loops: 1)
        case .markMoment: markMoment()
        case .runShortcut: MacActions.runShortcut(shortcut)
        }
    }

    /// Record a "moment" (double-tap marker) with a confirming buzz.
    func markMoment() {
        moments.append(Date())
        if moments.count > 500 { moments.removeFirst(moments.count - 500) }
        UserDefaults.standard.set(moments.map(\.timeIntervalSince1970), forKey: "moments")
        buzz(loops: 1)
        live.append(log: "Moment marked")
    }

    private func handleWristChange(_ worn: Bool) {
        if worn {
            if !behavior.wristOnShortcut.isEmpty { MacActions.runShortcut(behavior.wristOnShortcut) }
        } else {
            if behavior.autoLockOnWristOff, !MacActions.lockScreen() { MacActions.runShortcut("Lock Screen") }
            if !behavior.wristOffShortcut.isEmpty { MacActions.runShortcut(behavior.wristOffShortcut) }
        }
    }

    /// HR-zone haptic coaching: buzz when crossing into the top zone (ease off) or back to recovery.
    private func coachZone(_ hr: Int?) {
        guard behavior.zoneCoaching, live.bonded, live.worn, let hr, hr >= 30 else { return }
        let maxHR = Double(profile.hrMax)
        guard maxHR > 0 else { return }
        let pct = Double(hr) / maxHR
        let zone = pct >= 0.9 ? 5 : pct >= 0.8 ? 4 : pct >= 0.7 ? 3 : pct >= 0.6 ? 2 : 1
        defer { lastCoachZone = zone }
        guard lastCoachZone != -1, zone != lastCoachZone else { return }
        if zone == 5, lastCoachZone < 5 { buzz(loops: 3) }          // entered max — ease off
        else if zone <= 1, lastCoachZone > 1 { buzz(loops: 1) }     // recovered
    }

    /// Illness/strain early-warning: compare the last ~2 days against a ~28-day baseline (ending 3
    /// days ago) for resting HR, HRV, skin-temp deviation and respiration. Two or more anomalies →
    /// a banner. The classic early-illness signature (RHR↑ + HRV↓ + skin-temp↑). On-device only.
    private func evaluateIllness(_ days: [DailyMetric]) {
        guard behavior.illnessWatch, days.count >= 14 else { healthAlert = nil; return }
        let recent = Array(days.suffix(2))
        let base = Array(days.suffix(31).dropLast(3))    // ~28 days ending 3 days ago
        func mean(_ vals: [Double]) -> Double? { vals.isEmpty ? nil : vals.reduce(0, +) / Double(vals.count) }
        func rm(_ kp: (DailyMetric) -> Double?) -> Double? { mean(recent.compactMap(kp)) }
        func bm(_ kp: (DailyMetric) -> Double?) -> Double? { mean(base.compactMap(kp)) }

        var flags: [String] = []
        if let r = rm({ $0.restingHr.map(Double.init) }), let b = bm({ $0.restingHr.map(Double.init) }), r >= b + 5 {
            flags.append("resting HR +\(Int((r - b).rounded())) bpm")
        }
        if let r = rm({ $0.avgHrv }), let b = bm({ $0.avgHrv }), b > 0, r <= b * 0.80 {
            flags.append("HRV −\(Int(((1 - r / b) * 100).rounded()))%")
        }
        if let r = rm({ $0.skinTempDevC }), r >= 0.6 {
            flags.append("skin temp +\(String(format: "%.1f", r))°C")
        }
        if let r = rm({ $0.respRateBpm }), let b = bm({ $0.respRateBpm }), r >= b + 1.5 {
            flags.append("respiration up")
        }
        healthAlert = flags.count >= 2
            ? "Your body looks strained — " + flags.joined(separator: ", ") + ". Consider taking it easy."
            : nil
    }

    /// Import a Whoop CSV export (.zip or folder) → on-device store, then refresh the dashboard.
    func importWhoop(url: URL) {
        beginImport(.whoop)
        Task {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do {
                guard let store = await repo.storeHandle() else {
                    finishImport(.whoop, summary: "Couldn't open the local store.", failed: true)
                    return
                }
                let summary = try await WhoopImporter.importExport(url: url, into: store, deviceId: deviceId)
                await repo.refresh()
                let span: String
                if let a = summary.earliest, let b = summary.latest {
                    let f = DateFormatter(); f.dateFormat = "MMM yyyy"
                    span = " · \(f.string(from: a))–\(f.string(from: b))"
                } else { span = "" }
                finishImport(.whoop, summary: "Imported \(summary.recordCount) records\(span)")
            } catch {
                finishImport(.whoop, summary: "Import failed: \(error)", failed: true)
            }
        }
    }

    /// Import an Apple Health export (export.zip) — streams + aggregates per-day into the store
    /// under the `apple-health` source, then refreshes. Large exports take ~1–2 minutes.
    func importAppleHealth(url: URL) {
        beginImport(.appleHealth)
        Task {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do {
                guard let store = await repo.storeHandle() else {
                    finishImport(.appleHealth, summary: "Couldn't open the local store.", failed: true)
                    return
                }
                let summary = try await AppleHealthImport.importExport(url: url, into: store, deviceId: appleDeviceId)
                await repo.refresh()
                finishImport(.appleHealth, summary: "Imported \(summary.recordCount) records")
            } catch {
                finishImport(.appleHealth, summary: "Import failed: \(error)", failed: true)
            }
        }
    }

    /// Marks a source as importing and clears only that source's old status text + failure flag.
    private func beginImport(_ source: DataSourceImportKind) {
        activeImportSource = source
        switch source {
        case .whoop:
            whoopImportSummary = nil
            whoopImportFailed = false
        case .appleHealth:
            appleHealthImportSummary = nil
            appleHealthImportFailed = false
        }
    }

    /// Stores the completed import summary (and typed failure flag) on the matching source card.
    private func finishImport(_ source: DataSourceImportKind, summary: String, failed: Bool = false) {
        switch source {
        case .whoop:
            whoopImportSummary = summary
            whoopImportFailed = failed
        case .appleHealth:
            appleHealthImportSummary = summary
            appleHealthImportFailed = failed
        }
        activeImportSource = nil
    }
}
