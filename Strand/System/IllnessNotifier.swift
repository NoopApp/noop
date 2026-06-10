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
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = "Early warning — take it easy"
            content.subtitle = "On-device estimate (approximate) — not a diagnosis."
            content.body = message
            content.sound = .default
            center.add(UNNotificationRequest(identifier: "illness-watch",
                                             content: content, trigger: nil))
            d.set(day, forKey: lastDayKey)
        }
    }

    private static func dayKey(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }
}
