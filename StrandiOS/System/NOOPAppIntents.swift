#if os(iOS)
import Foundation
import AppIntents

/// Queue of actions requested by an App Intent while the app may be suspended. Intents can't reach
/// into the running `AppModel` directly (BLE only lives in the foreground app), so they enqueue here
/// and the app drains the queue when it next becomes active.
enum PendingIntents {
    enum Action: String { case markMoment, buzz }

    private static let key = "noop.pendingIntents"
    private static var defaults: UserDefaults? { UserDefaults(suiteName: WidgetSnapshot.suiteName) }

    /// Optional `at` is the invocation time, captured now and consumed on drain. Encoded into the
    /// stored string as "rawValue:epochSeconds" so the array stays a plain [String] (no schema
    /// migration; a legacy bare "markMoment" still decodes with a nil date).
    static func append(_ action: Action, at date: Date? = nil) {
        guard let d = defaults else { return }
        var list = d.stringArray(forKey: key) ?? []
        if let date { list.append("\(action.rawValue):\(date.timeIntervalSince1970)") }
        else { list.append(action.rawValue) }
        d.set(list, forKey: key)
    }

    static func drain() -> [(action: Action, date: Date?)] {
        guard let d = defaults else { return [] }
        let raw = d.stringArray(forKey: key) ?? []
        d.removeObject(forKey: key)
        return raw.compactMap { entry in
            let parts = entry.split(separator: ":", maxSplits: 1)
            guard let action = Action(rawValue: String(parts[0])) else { return nil }
            let date = parts.count == 2 ? Double(parts[1]).map { Date(timeIntervalSince1970: $0) } : nil
            return (action, date)
        }
    }
}

/// Record a timestamped "moment" — the iOS analogue of the strap double-tap "mark a moment" action.
struct MarkMomentIntent: AppIntent {
    static var title: LocalizedStringResource = "Mark a Moment"
    static var description = IntentDescription("Record a timestamped moment in NOOP.")

    func perform() async throws -> some IntentResult & ProvidesDialog {
        PendingIntents.append(.markMoment, at: Date())
        return .result(dialog: "Moment marked.")
    }
}

/// Send a confirming haptic buzz to the strap. Opens the app so the live BLE link can deliver it.
struct BuzzStrapIntent: AppIntent {
    static var title: LocalizedStringResource = "Buzz Strap"
    static var description = IntentDescription("Send a haptic buzz to your WHOOP strap.")
    static var openAppWhenRun = true

    func perform() async throws -> some IntentResult {
        PendingIntents.append(.buzz)
        return .result()
    }
}

/// Surfaces NOOP's intents to Siri, Spotlight, and the Shortcuts gallery without any user setup.
struct NOOPShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: MarkMomentIntent(),
                    phrases: ["Mark a moment in \(.applicationName)"],
                    shortTitle: "Mark a Moment",
                    systemImageName: "mappin.and.ellipse")
        AppShortcut(intent: BuzzStrapIntent(),
                    phrases: ["Buzz my \(.applicationName) strap"],
                    shortTitle: "Buzz Strap",
                    systemImageName: "waveform.path")
    }
}
#endif
