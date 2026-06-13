import Foundation
enum StorePaths {
    /// `<AppSupport>/OpenWhoop/whoop.sqlite`, creating the directory if needed.
    static func defaultDatabasePath() throws -> String {
        let fm = FileManager.default
        let appSupport = try fm.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                    appropriateFor: nil, create: true)
        let base = macOSProductionContainerAppSupport(defaultingTo: appSupport)
            .appendingPathComponent("OpenWhoop", isDirectory: true)
        try fm.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("whoop.sqlite").path
    }

    private static func macOSProductionContainerAppSupport(defaultingTo appSupport: URL) -> URL {
        #if os(macOS)
        let productionBundleID = "com.noopapp.noop"
        guard Bundle.main.bundleIdentifier == productionBundleID else { return appSupport }
        let path = appSupport.standardizedFileURL.path
        if path.contains("/Library/Containers/\(productionBundleID)/Data/") { return appSupport }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Containers/\(productionBundleID)/Data/Library/Application Support",
                                    isDirectory: true)
        #else
        return appSupport
        #endif
    }
}
