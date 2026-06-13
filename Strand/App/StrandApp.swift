import SwiftUI
#if os(macOS)
import AppKit
#endif

@main
struct StrandApp: App {
    #if os(macOS)
    @NSApplicationDelegateAdaptor(SingleInstanceAppDelegate.self) private var singleInstanceDelegate
    #endif
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(model)
                .environmentObject(model.live)
                .environmentObject(model.repo)
                .environmentObject(model.profile)
                .environmentObject(model.behavior)
                .environmentObject(model.intelligence)
                .environmentObject(model.coach)
                .frame(minWidth: 1000, minHeight: 700)
                .preferredColorScheme(.dark)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1180, height: 820)

        // Menu-bar extra: glanceable live HR + a compact popover.
        MenuBarExtra {
            MenuBarContent()
                .environmentObject(model)
                .environmentObject(model.repo)
                .environmentObject(model.live)
        } label: {
            MenuBarLabel()
                .environmentObject(model.repo)
                .environmentObject(model.live)
        }
        .menuBarExtraStyle(.window)
    }
}

#if os(macOS)
final class SingleInstanceAppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        enforceSingleInstance()
    }

    private func enforceSingleInstance() {
        guard !ProcessInfo.processInfo.environment.keys.contains("XCTestConfigurationFilePath") else { return }
        guard let bundleID = Bundle.main.bundleIdentifier else { return }
        let currentPID = ProcessInfo.processInfo.processIdentifier
        let currentURL = Bundle.main.bundleURL.standardizedFileURL
        let displayName = (Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? (Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String)
            ?? "NOOP"
        let installedURL = URL(fileURLWithPath: "/Applications/\(displayName).app").standardizedFileURL
        let otherApps = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .filter { $0.processIdentifier != currentPID }
        guard !otherApps.isEmpty else { return }

        if currentURL == installedURL {
            otherApps.forEach { _ = $0.terminate() }
            return
        }

        let appToKeep = otherApps.first { $0.bundleURL?.standardizedFileURL == installedURL } ?? otherApps[0]
        appToKeep.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
        NSApp.terminate(nil)
    }
}
#endif
