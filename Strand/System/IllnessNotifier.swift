import Foundation
import UserNotifications

/// Surfaces the illness early-warning as a macOS user notification when the banner transitions
/// from clear to raised — today it is silent unless the window is open (the menu-bar extra keeps
/// NOOP alive). Rate-limited to once per local calendar day; the in-app banner stays the live
/// surface. On-device only; the summary is APPROXIMATE — informational, not a diagnosis.
enum IllnessNotifier {
    private static let lastDayKey = "behavior.illnessLastNotifiedDay"

    /// Ask up front (called when the user enables the watch) so the system dialog appears at a
    /// predictable moment, not on the first 3 a.m. transition.
    static func requestAuthorization() {
        UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    /// Post the early-warning, at most once per local calendar day.
    static func post(_ message: String) {
        let day = dayKey(Date())
        let d = UserDefaults.standard
        guard d.string(forKey: lastDayKey) != day else { return }
        // Mark the day up front so the once-per-day limit holds even if the user declined
        // notifications or delivery is deferred — the in-app banner stays the live surface either
        // way, and we never re-prompt or retry on every transition.
        d.set(day, forKey: lastDayKey)
        let center = UNUserNotificationCenter.current()
        // Authorization is requested once via requestAuthorization() when the watch is enabled;
        // here we only check status (no second system prompt).
        center.getNotificationSettings { settings in
            guard settings.authorizationStatus == .authorized else { return }
            let content = UNMutableNotificationContent()
            content.title = "Early warning — take it easy"
            content.subtitle = "On-device estimate (approximate) — not a diagnosis."
            content.body = message
            content.sound = .default
            center.add(UNNotificationRequest(identifier: "illness-watch",
                                             content: content, trigger: nil))
        }
    }

    private static func dayKey(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }
}
