#if os(iOS)
import Foundation
import ActivityKit

/// Starts, updates, and ends the live-HR Live Activity. The activity appears on the Lock Screen and
/// in the Dynamic Island while the strap is bonded and streaming heart rate.
@MainActor
final class LiveActivityController {
    private var activity: Activity<NOOPActivityAttributes>?
    private var lastPush: Date = .distantPast
    /// Cached `ActivityAuthorizationInfo` — `update` runs at ~1 Hz off the live HR stream, and
    /// instantiating this system bridge per tick is needless allocation. ActivityKit's auth status
    /// only changes via Settings, so caching for the controller's lifetime is safe.
    private let authInfo = ActivityAuthorizationInfo()
    /// Synchronous gate against concurrent `Activity.request` calls. The `else` branch below is
    /// re-entered while the first request is still in flight (it hasn't assigned `self.activity`
    /// yet), so without this guard two close-together HR samples could both fire `Activity.request`
    /// and create duplicate Live Activities.
    private var isStarting = false

    /// Drive the activity from the latest live values. Lazily starts when the strap is bonded and a
    /// heart rate is present; ends when the strap goes offline. Throttled to ~once every 2s so we
    /// stay well under the Live Activity update budget.
    func update(bpm: Int?, recovery: Int?, bonded: Bool) {
        guard authInfo.areActivitiesEnabled else { return }

        if !bonded {
            Task { await end() }
            return
        }
        guard bpm != nil else { return }

        let state = NOOPActivityAttributes.ContentState(bpm: bpm, recovery: recovery, bonded: bonded)

        if let activity {
            guard Date().timeIntervalSince(lastPush) > 2 else { return }
            lastPush = Date()
            Task { await activity.update(ActivityContent(state: state, staleDate: nil)) }
        } else {
            // Set the start gate SYNCHRONOUSLY before any await so a second `update` arriving on the
            // main actor while `Activity.request` is still in flight bails here instead of issuing a
            // second request. The 2-second throttle above only guards the update path.
            guard !isStarting else { return }
            isStarting = true
            do {
                activity = try Activity.request(
                    attributes: NOOPActivityAttributes(title: "Live HR"),
                    content: ActivityContent(state: state, staleDate: nil),
                    pushType: nil
                )
                lastPush = Date()
            } catch {
                activity = nil
            }
            isStarting = false
        }
    }

    func end() async {
        guard let activity else { return }
        await activity.end(nil, dismissalPolicy: .immediate)
        self.activity = nil
    }
}
#endif
