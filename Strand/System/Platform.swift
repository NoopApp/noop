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
