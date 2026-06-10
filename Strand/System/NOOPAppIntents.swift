import AppIntents

/// INBOUND automation — exposes strap actions as standalone Shortcuts / Spotlight actions. The
/// OUTBOUND counterpart (strap double-tap → run a macOS Shortcut) lives next door in MacActions.swift.
///
/// These reach the LIVE, bonded `AppModel` via `AppModel.shared`. Constructing a fresh `AppModel()`
/// from an intent would be wrong: it would start a second BLEManager + a duplicate 15-min analysis
/// loop and could never buzz (the haptic command is gated on the live bonded peripheral). The
/// `weak` shared accessor lets an intent fired while NOOP is closed fail with a clear "open NOOP"
/// message instead of silently no-op'ing on a dead instance. (#42 idea-mining; macOS 13+ supports
/// AppIntents — no new entitlement or Info.plist key required.)

@available(macOS 13.0, *)
enum NOOPIntentError: Error, CustomLocalizedStringResourceConvertible {
    case notRunning
    case notConnected
    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .notRunning:   return "Open NOOP first so it can reach your strap."
        case .notConnected: return "Connect your WHOOP strap in NOOP, then try again."
        }
    }
}

@available(macOS 13.0, *)
struct BuzzStrapIntent: AppIntent {
    static var title: LocalizedStringResource = "Buzz Strap"
    static var description = IntentDescription("Vibrate your connected WHOOP strap.")
    static var openAppWhenRun = false

    @MainActor
    func perform() async throws -> some IntentResult {
        guard let model = AppModel.shared else { throw NOOPIntentError.notRunning }
        guard model.live.bonded else { throw NOOPIntentError.notConnected }
        model.buzz(loops: 2)
        return .result()
    }
}

@available(macOS 13.0, *)
struct MarkMomentIntent: AppIntent {
    static var title: LocalizedStringResource = "Mark a Moment"
    static var description = IntentDescription("Record a timestamped moment (and buzz the strap if it's connected).")
    static var openAppWhenRun = false

    @MainActor
    func perform() async throws -> some IntentResult {
        // markMoment() records regardless of bond (the confirming buzz no-ops when unbonded).
        guard let model = AppModel.shared else { throw NOOPIntentError.notRunning }
        model.markMoment()
        return .result()
    }
}

/// Auto-surfaces the actions in Shortcuts.app with suggested phrases.
@available(macOS 13.0, *)
struct NOOPShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: BuzzStrapIntent(),
                    phrases: ["Buzz my strap with \(.applicationName)", "Buzz \(.applicationName)"],
                    shortTitle: "Buzz Strap", systemImageName: "waveform")
        AppShortcut(intent: MarkMomentIntent(),
                    phrases: ["Mark a moment with \(.applicationName)", "Mark a moment in \(.applicationName)"],
                    shortTitle: "Mark a Moment", systemImageName: "mappin.and.ellipse")
    }
}
