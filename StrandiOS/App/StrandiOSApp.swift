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
                // HealthKit sync runs from the scenePhase.active handler below. It used to ALSO run
                // here in `.task`, which fired on initial view appearance and raced the scenePhase
                // transition on cold launch — doubling the HealthKit writes on first run.
                // HealthKitBridge.sync guards on `auth == .authorized` and `!syncing` so a duplicate
                // call was a no-op once auth was settled, but on the very first launch (auth dialog
                // still in flight) the two calls overlapped in unpredictable ways.
                .task {
                    await health.requestAuthorization()
                }
                .onReceive(model.live.$heartRate) { _ in
                    liveActivity.update(
                        bpm: model.bpm ?? model.live.heartRate,
                        recovery: model.repo.days.last(where: { $0.recovery != nil })?
                            .recovery.map { Int($0.rounded()) },
                        bonded: model.live.bonded
                    )
                }
        }
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
