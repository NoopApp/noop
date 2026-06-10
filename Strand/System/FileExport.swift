import Foundation

#if canImport(AppKit)
import AppKit
import UniformTypeIdentifiers
#elseif canImport(UIKit)
import UIKit
import UniformTypeIdentifiers
#endif

/// Cross-platform "save / share a file" helper.
///
/// - macOS uses `NSSavePanel` (sandbox-safe via the user-selected-file entitlement).
/// - iOS presents the system share sheet (`UIActivityViewController`) so the user can save the file
///   to Files, AirDrop it, or send it on — the idiomatic iOS way to get a file out of the sandbox.
enum FileExport {

    /// Write `text` to a file and let the user choose where it goes.
    @MainActor
    static func exportText(_ text: String, suggestedName: String) {
        #if os(macOS)
        let panel = NSSavePanel()
        panel.nameFieldStringValue = suggestedName
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? text.write(to: url, atomically: true, encoding: .utf8)
        #else
        // Write to a temp file FIRST and only present the share sheet if the file actually exists.
        // The previous `try?` swallowed write failures, then handed an empty/missing path to the
        // share sheet — the user saw a broken export with no error. Clean up the temp file after the
        // share sheet closes so the temporaryDirectory doesn't accumulate dead exports across runs.
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(suggestedName)
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            return
        }
        present(activityItems: [url], cleanup: [url])
        #endif
    }

    /// Let the user save / share an existing file at `src`. On macOS this copies to a chosen
    /// destination; on iOS it offers the file through the share sheet. `src` is owned by the caller
    /// (e.g. a Puffin capture inside the app's container) and is NOT deleted by the share-sheet
    /// completion handler — only files we staged ourselves get cleaned up.
    @MainActor
    static func exportFile(at src: URL, suggestedName: String? = nil) {
        #if os(macOS)
        let panel = NSSavePanel()
        panel.nameFieldStringValue = suggestedName ?? src.lastPathComponent
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let dest = panel.url else { return }
        let fm = FileManager.default
        do {
            if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
            try fm.copyItem(at: src, to: dest)
        } catch { /* best-effort */ }
        #else
        guard FileManager.default.fileExists(atPath: src.path) else { return }
        present(activityItems: [src], cleanup: [])
        #endif
    }

    #if os(iOS)
    /// Present `UIActivityViewController` and, once it closes, best-effort remove the URLs in
    /// `cleanup` so staged exports don't accumulate in `temporaryDirectory` across runs.
    @MainActor
    private static func present(activityItems: [Any], cleanup: [URL]) {
        guard let scene = UIApplication.shared.connectedScenes
                .compactMap({ $0 as? UIWindowScene })
                .first(where: { $0.activationState == .foregroundActive }) ?? UIApplication.shared
                .connectedScenes.compactMap({ $0 as? UIWindowScene }).first,
              let root = scene.windows.first(where: { $0.isKeyWindow })?.rootViewController
                ?? scene.windows.first?.rootViewController else { return }
        let vc = UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
        if !cleanup.isEmpty {
            vc.completionWithItemsHandler = { _, _, _, _ in
                let fm = FileManager.default
                for url in cleanup where fm.fileExists(atPath: url.path) {
                    try? fm.removeItem(at: url)
                }
            }
        }
        // iPad: anchor the popover to the screen centre to avoid a crash.
        if let pop = vc.popoverPresentationController {
            pop.sourceView = root.view
            pop.sourceRect = CGRect(x: root.view.bounds.midX, y: root.view.bounds.midY, width: 0, height: 0)
            pop.permittedArrowDirections = []
        }
        root.present(vc, animated: true)
    }
    #endif
}
