#if os(iOS)
import Foundation

extension AppModel {
    /// Execute any actions queued by App Intents while the app was suspended (mark moment, buzz).
    /// Call when the app becomes active.
    func drainPendingIntents() {
        for action in PendingIntents.drain() {
            switch action {
            case .markMoment: markMoment()
            case .buzz:       buzz(loops: 1)
            }
        }
    }
}
#endif
