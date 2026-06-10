#if os(iOS)
import SwiftUI

/// iOS entry point. Unlike the macOS app (which adds a `MenuBarExtra` scene), iOS uses a single
/// `WindowGroup`; the glanceable menu-bar role is filled by the Home/Lock-Screen widget instead.
@main
struct StrandiOSApp: App {
    @StateObject private var model: AppModel
    @StateObject private var health: HealthKitBridge
    @State private var liveActivity = LiveActivityController()
    @Environment(\.scenePhase) private var scenePhase

    init() {
        // Debug-only canary: trips if the App Group entitlement is missing on this target before any
        // silent no-op (PendingIntents, WidgetSnapshot.publish, Live Activity) can mask the issue as
        // "the widget doesn't show anything yet." No-op in Release.
        WidgetSnapshot.assertGroupProvisioned()
        let model = AppModel()
        _model = StateObject(wrappedValue: model)
        _health = StateObject(wrappedValue: HealthKitBridge(
            repo: model.repo,
            appleDeviceId: model.appleDeviceId,
            noopDeviceId: model.deviceId
        ))
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(model)
                .environmentObject(model.live)
                .environmentObject(model.repo)
                .environmentObject(model.profile)
                .environmentObject(model.behavior)
                .environmentObject(model.intelligence)
                .environmentObject(model.coach)
                .environmentObject(health)
                .preferredColorScheme(.dark)
                .onReceive(model.live.$heartRate) { _ in
                    liveActivity.update(
                        bpm: model.bpm ?? model.live.heartRate,
                        recovery: model.repo.days.last(where: { $0.recovery != nil })?
                            .recovery.map { Int($0.rounded()) },
                        bonded: model.live.bonded
                    )
                }
        }
        // HealthKit authorization is intentionally NOT requested on launch. The system permission
        // dialog without prior in-app rationale violates Apple HIG / App Review guidance — the user
        // sees the prompt before any context. Authorization should be triggered from an explicit
        // user action: an "Enable Apple Health" row in Settings, or a dedicated step in
        // OnboardingWizard. HealthKitBridge.sync below guards on `auth == .authorized`, so the
        // scenePhase trigger is a safe no-op until the user opts in.
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                model.drainPendingIntents()
                Task {
                    await health.sync()
                    WidgetSnapshot.publish(from: model)
                }
            }
        }
    }
}
#endif
