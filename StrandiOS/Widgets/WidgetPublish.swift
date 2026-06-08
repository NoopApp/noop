#if os(iOS)
import Foundation
import WidgetKit

extension WidgetSnapshot {
    /// Build a glance snapshot from the live app state and publish it to the shared App Group, then
    /// ask WidgetKit to refresh. Called when the app becomes active and after a Health sync.
    @MainActor
    static func publish(from model: AppModel) {
        // Most recent day that actually has a recovery score.
        let recovery = model.repo.days.last(where: { $0.recovery != nil })?.recovery
        let snap = WidgetSnapshot(
            recovery: recovery.map { Int($0.rounded()) },
            bpm: model.bpm ?? model.live.heartRate,
            batteryPct: model.live.batteryPct.map { Int($0.rounded()) },
            bonded: model.live.bonded,
            updated: Date()
        )
        snap.save()
        WidgetCenter.shared.reloadAllTimelines()
    }
}
#endif
