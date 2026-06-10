import Foundation
import AppKit
import SQLite3
import UniformTypeIdentifiers
import WhoopStore

/// Full-database EXPORT / IMPORT for device migration.
///
/// NOOP keeps everything in one SQLite file (`<AppSupport>/OpenWhoop/whoop.sqlite`, plus the
/// `-wal`/`-shm` WAL sidecars while the store is open). Moving to another Mac is therefore just a
/// matter of moving that file. Export checkpoints the WAL (so the single file is whole) and copies
/// it to a user-chosen location; import validates a chosen backup, snapshots the current DB to a
/// side file, drops the backup in over the live path, and asks the user to relaunch (the store is
/// held open, so the new file can't be swapped in live).
///
/// Sandbox-safe: relies on the `com.apple.security.files.user-selected.read-write` entitlement and
/// security-scoped access on the panel-returned URLs. Every path is best-effort — failures surface
/// as a `.failure` result and never crash.
enum DataBackup {

    // MARK: - Result

    enum BackupResult {
        /// Export wrote the backup to `url`.
        case exported(URL)
        /// Import succeeded; a relaunch is required for it to take effect. `sidecar` is where the
        /// previous database was preserved, in case the user wants to roll back.
        case imported(sidecar: URL)
        /// The user dismissed the save/open panel — nothing happened, show nothing loud.
        case cancelled
        /// Something went wrong; `message` is user-facing.
        case failure(String)
    }

    // MARK: - Export

    /// Checkpoint (if the store is reachable) and copy the live database to a user-chosen file.
    ///
    /// - Parameter checkpoint: invoked first to flush the WAL into the main file. Pass
    ///   `repo.checkpointForBackup`; returns whether a checkpoint actually ran. When it doesn't
    ///   (store not open yet, or it failed), we copy the on-disk files as-is — including any `-wal`
    ///   sidecar — so the backup is still complete, just not consolidated.
    @MainActor
    static func runExport(checkpoint: @escaping () async -> Bool) async -> BackupResult {
        let dbPath: String
        do { dbPath = try StorePaths.defaultDatabasePath() }
        catch { return .failure("Couldn't locate the NOOP database. \(error.localizedDescription)") }

        let dbURL = URL(fileURLWithPath: dbPath)
        guard FileManager.default.fileExists(atPath: dbPath) else {
            return .failure("There's no NOOP data to export yet. Import or record some first.")
        }

        // Flush the WAL so the single .sqlite carries everything. Best-effort.
        let checkpointed = await checkpoint()

        // Ask where to save.
        let panel = NSSavePanel()
        panel.title = "Export NOOP backup"
        panel.prompt = "Export"
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = defaultBackupName()
        panel.allowedContentTypes = sqliteContentTypes()
        panel.isExtensionHidden = false

        guard panel.runModal() == .OK, let dest = panel.url else { return .cancelled }

        let scoped = dest.startAccessingSecurityScopedResource()
        defer { if scoped { dest.stopAccessingSecurityScopedResource() } }

        let fm = FileManager.default
        do {
            // NSSavePanel already handled the "replace existing?" confirmation; clear the target.
            if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
            try fm.copyItem(at: dbURL, to: dest)

            // If we couldn't checkpoint, fold any pending WAL into the side copy so the backup is
            // self-contained. We can't run SQLite over the destination safely here, so instead we
            // copy the sidecars next to it under the same base name; importing copies only the main
            // file, but at least nothing is silently lost. In practice the store is almost always
            // open and the checkpoint succeeds, leaving no WAL to worry about.
            if !checkpointed {
                copySidecarsIfPresent(from: dbURL, toMainBackup: dest)
            }
            return .exported(dest)
        } catch {
            return .failure("Export failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Import

    /// Pick a `.sqlite` backup, validate it, snapshot the current DB to a side file, then copy the
    /// backup over the live database path (removing the `-wal`/`-shm` siblings). The store stays
    /// open, so the swapped-in file only takes effect after a relaunch — the caller informs the user.
    @MainActor
    static func runImport() async -> BackupResult {
        let dbPath: String
        do { dbPath = try StorePaths.defaultDatabasePath() }
        catch { return .failure("Couldn't locate the NOOP database. \(error.localizedDescription)") }

        let panel = NSOpenPanel()
        panel.title = "Import NOOP backup"
        panel.prompt = "Import"
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = sqliteContentTypes()

        guard panel.runModal() == .OK, let source = panel.url else { return .cancelled }

        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }

        // Validate: must be a real SQLite database (magic header "SQLite format 3\0").
        guard isSQLiteFile(at: source) else {
            return .failure("That file isn't a NOOP backup — it doesn't look like a SQLite database.")
        }

        // Reject the OTHER platform's backup honestly. The magic check passes for ANY SQLite
        // file, so an Android (Room) backup sailed through, replaced the GRDB database, and
        // left the user stranded after the relaunch (the GRDB migration bookkeeping is absent).
        // Probe the schema read-only and point the user at the path that DOES work cross-platform.
        if backupOrigin(of: sqliteTableNames(at: source)) == .android {
            return .failure("That backup is from NOOP for Android — the two apps store data in different database layouts, so a direct restore is not possible. On the phone use Settings → Export CSV… and import the zip here under Data Sources → WHOOP Export instead.")
        }

        let fm = FileManager.default
        let dbURL = URL(fileURLWithPath: dbPath)

        do {
            // Snapshot the current DB (+ sidecars) to a timestamped side file so the user can roll back.
            var sidecar = dbURL.deletingLastPathComponent()
                .appendingPathComponent("whoop-replaced-\(timestamp()).sqlite")
            if fm.fileExists(atPath: dbURL.path) {
                if fm.fileExists(atPath: sidecar.path) { try fm.removeItem(at: sidecar) }
                try fm.copyItem(at: dbURL, to: sidecar)
            } else {
                // Nothing to preserve (fresh install); report a placeholder so the message reads sensibly.
                sidecar = dbURL
            }

            // Remove the live DB and its WAL/SHM siblings, then drop the backup in.
            removeIfPresent(dbURL)
            removeIfPresent(URL(fileURLWithPath: dbPath + "-wal"))
            removeIfPresent(URL(fileURLWithPath: dbPath + "-shm"))

            try fm.copyItem(at: source, to: dbURL)
            return .imported(sidecar: sidecar)
        } catch {
            return .failure("Import failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Helpers

    /// "NOOP-backup-2026-06-07.sqlite"
    private static func defaultBackupName() -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return "NOOP-backup-\(f.string(from: Date())).sqlite"
    }

    private static func timestamp() -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd-HHmmss"
        return f.string(from: Date())
    }

    /// `.sqlite` UTType if the system knows it, always falling back to the generic database type so
    /// the panels still open on systems without a `.sqlite` declaration.
    private static func sqliteContentTypes() -> [UTType] {
        var types: [UTType] = []
        if let sqlite = UTType(filenameExtension: "sqlite") { types.append(sqlite) }
        types.append(.database)
        types.append(.data)
        return types
    }

    /// Which platform produced a NOOP backup, judged by its migrator's bookkeeping table.
    enum BackupOrigin: Equatable { case mac, android, unknown }

    /// Pure classification over a backup's sqlite_master table names: GRDB (this app) writes
    /// `grdb_migrations`, Room (the Android app) writes `room_master_table`. `.unknown`
    /// (neither — an empty or pre-migration file) falls through to the normal import path,
    /// where the open-time migrator decides. Mirrors Android DataBackup.backupOriginOf.
    static func backupOrigin(of tableNames: Set<String>) -> BackupOrigin {
        if tableNames.contains("grdb_migrations") { return .mac }
        if tableNames.contains("room_master_table") { return .android }
        return .unknown
    }

    /// All table names in a SQLite file, opened read-only via the system SQLite (never mutates
    /// the probed file). Empty set on any failure — the caller treats that as `.unknown`.
    private static func sqliteTableNames(at url: URL) -> Set<String> {
        var db: OpaquePointer?
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            sqlite3_close(db)
            return []
        }
        defer { sqlite3_close(db) }
        var stmt: OpaquePointer?
        let sql = "SELECT name FROM sqlite_master WHERE type = 'table'"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        var names: Set<String> = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let c = sqlite3_column_text(stmt, 0) {
                names.insert(String(cString: c))
            }
        }
        return names
    }

    /// Read the first 16 bytes and check for the SQLite magic header.
    private static func isSQLiteFile(at url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        guard let head = try? handle.read(upToCount: 16), head.count >= 16 else { return false }
        // "SQLite format 3" + NUL terminator.
        let magic: [UInt8] = Array("SQLite format 3".utf8) + [0x00]
        return Array(head) == magic
    }

    private static func removeIfPresent(_ url: URL) {
        let fm = FileManager.default
        if fm.fileExists(atPath: url.path) { try? fm.removeItem(at: url) }
    }

    /// Copy `<db>-wal`/`<db>-shm` next to the main backup, under the backup's base name, if they
    /// exist on disk (only reached when the checkpoint didn't run). Best-effort — failures are ignored.
    private static func copySidecarsIfPresent(from dbURL: URL, toMainBackup dest: URL) {
        let fm = FileManager.default
        for suffix in ["-wal", "-shm"] {
            let side = URL(fileURLWithPath: dbURL.path + suffix)
            guard fm.fileExists(atPath: side.path) else { continue }
            let target = URL(fileURLWithPath: dest.path + suffix)
            if fm.fileExists(atPath: target.path) { try? fm.removeItem(at: target) }
            try? fm.copyItem(at: side, to: target)
        }
    }
}
