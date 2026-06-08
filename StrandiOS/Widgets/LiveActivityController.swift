#if os(iOS)
import Foundation
import ActivityKit

/// Starts, updates, and ends the live-HR Live Activity. The activity appears on the Lock Screen and
/// in the Dynamic Island while the strap is bonded and streaming heart rate.
@MainActor
final class LiveActivityController {
    private var activity: Activity<NOOPActivityAttributes>?
    private var lastPush: Date = .distantPast

    /// Drive the activity from the latest live values. Lazily starts when the strap is bonded and a
    /// heart rate is present; ends when the strap goes offline. Throttled to ~once every 2s so we
    /// stay well under the Live Activity update budget.
    func update(bpm: Int?, recovery: Int?, bonded: Bool) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }

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
        }
    }

    func end() async {
        guard let activity else { return }
        await activity.end(nil, dismissalPolicy: .immediate)
        self.activity = nil
    }
}
#endif
