#if os(iOS)
import Foundation

extension AppModel {
    /// Execute any actions queued by App Intents while the app was suspended (mark moment, buzz).
    /// Call when the app becomes active.
    func drainPendingIntents() {
        for item in PendingIntents.drain() {
            switch item.action {
            case .markMoment: markMoment(at: item.date ?? Date())
            case .buzz:       buzz(loops: 1)
            }
        }
    }
}
#endif
