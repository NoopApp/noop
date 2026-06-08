import Foundation
#if canImport(AppKit)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

/// What a strap double-tap (or a wrist-off trigger) does. Cross-platform: a third-party app cannot
/// lock an iPhone, so `lockScreen` is hidden from the iOS action picker via `available`.
enum MacActionKind: String, Codable, CaseIterable, Identifiable {
    case none
    case lockScreen
    case buzzBack
    case markMoment
    case runShortcut

    var id: String { rawValue }

    /// Actions offered to the user on the current platform. iOS cannot lock the device, so that
    /// action is dropped there.
    static var available: [MacActionKind] {
        #if os(iOS)
        return allCases.filter { $0 != .lockScreen }
        #else
        return allCases
        #endif
    }

    var label: String {
        switch self {
        case .none:        return "Nothing"
        #if os(iOS)
        case .lockScreen:  return "Lock the device"
        #else
        case .lockScreen:  return "Lock the Mac"
        #endif
        case .buzzBack:    return "Buzz back (confirm)"
        case .markMoment:  return "Mark a moment"
        case .runShortcut: return "Run a Shortcut…"
        }
    }
    var symbol: String {
        switch self {
        case .none:        return "circle.slash"
        case .lockScreen:  return "lock.fill"
        case .buzzBack:    return "waveform.path"
        case .markMoment:  return "mappin.and.ellipse"
        case .runShortcut: return "bolt.fill"
        }
    }
}

/// Side effects for strap-triggered actions. Sandbox-friendly: Shortcuts run via the URL scheme
/// (Shortcuts.app does the privileged work), and screen lock uses login.framework's lock entry
/// point on macOS (there is no iOS equivalent — `lockScreen()` returns false on iOS).
enum MacActions {
    /// Lock the screen immediately — the same call the Apple-menu "Lock Screen" uses
    /// (login.framework `SACLockScreenImmediate`, resolved at runtime). Returns false if unavailable
    /// (always on iOS), so callers can fall back to a "Lock Screen" Shortcut.
    @discardableResult
    static func lockScreen() -> Bool {
        #if os(macOS)
        let path = "/System/Library/PrivateFrameworks/login.framework/login"
        guard let handle = dlopen(path, RTLD_NOW) else { return false }
        defer { dlclose(handle) }
        guard let sym = dlsym(handle, "SACLockScreenImmediate") else { return false }
        typealias LockFn = @convention(c) () -> Int32
        let fn = unsafeBitCast(sym, to: LockFn.self)
        _ = fn()
        return true
        #else
        return false
        #endif
    }

    /// Run a Shortcut by name via the `shortcuts://` URL scheme. Anything the user can build in
    /// Shortcuts is reachable this way. On iOS this foregrounds the Shortcuts app to run it.
    @MainActor
    static func runShortcut(_ name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let encoded = trimmed.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "shortcuts://run-shortcut?name=\(encoded)") else { return }
        PlatformOpen.url(url)
    }
}
