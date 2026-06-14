import SwiftUI

#if canImport(AppKit)
import AppKit
/// The native bitmap image type for the current platform.
public typealias PlatformImage = NSImage
#elseif canImport(UIKit)
import UIKit
public typealias PlatformImage = UIImage
#endif

// MARK: - Image bridging

extension Image {
    /// Build a SwiftUI `Image` from the platform-native bitmap type (`NSImage` on macOS,
    /// `UIImage` on iOS) so call sites stay platform-agnostic.
    init(platformImage: PlatformImage) {
        #if canImport(AppKit)
        self.init(nsImage: platformImage)
        #elseif canImport(UIKit)
        self.init(uiImage: platformImage)
        #endif
    }
}

// MARK: - Pasteboard

/// Cross-platform clipboard write. `NSPasteboard` on macOS, `UIPasteboard` on iOS.
enum PlatformPasteboard {
    static func copy(_ string: String) {
        #if canImport(AppKit)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
        #elseif canImport(UIKit)
        UIPasteboard.general.string = string
        #endif
    }
}

// MARK: - Device noun (#225)

/// The platform's device noun, so user-facing copy reads correctly per platform instead of
/// hard-coding "Mac" everywhere (which is wrong on iPhone). Use these in any string that talks
/// about *this* device generically — NOT in strings about a Mac that are genuinely Mac-only
/// (e.g. "a Mac can't write to a 5/MG", or the Lock-the-Mac automation).
enum Platform {
    /// "iPhone" on iOS, "Mac" on macOS. e.g. "Everything stays on your \(Platform.deviceNoun)."
    static var deviceNoun: String {
        #if os(iOS)
        return "iPhone"
        #else
        return "Mac"
        #endif
    }

    /// "this iPhone" / "this Mac" — the common demonstrative form.
    static var deviceNounPhrase: String { "this \(deviceNoun)" }
}

// MARK: - Opening URLs

/// Cross-platform "open this URL with the system" helper. Used for `mailto:` and `shortcuts://`.
enum PlatformOpen {
    @MainActor static func url(_ url: URL) {
        #if canImport(AppKit)
        NSWorkspace.shared.open(url)
        #elseif canImport(UIKit)
        UIApplication.shared.open(url)
        #endif
    }
}

// MARK: - Screen idle (keep-awake for hands-free sessions)

/// Prevent the display from auto-locking during a live, watched session (the breathing
/// orb, the HIIT interval timer). iOS-only; a no-op on macOS, which has no idle-lock
/// concern for these screens. Apple guidance: set `true` only while genuinely needed and
/// reset to `false` the moment the session ends so the system idle timer resumes normally.
enum ScreenIdle {
    @MainActor static func keepAwake(_ on: Bool) {
        #if os(iOS)
        UIApplication.shared.isIdleTimerDisabled = on
        #endif
    }
}
