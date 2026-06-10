import XCTest
@testable import Strand

/// Pins the cross-platform backup classification (mirror of the Android DataBackupOriginTest):
/// the import path's magic check passes for ANY SQLite file, so origin is judged by the
/// migrator's bookkeeping table — GRDB writes grdb_migrations (this app), Room writes
/// room_master_table (the Android app). An Android backup must be rejected with the
/// CSV-export pointer instead of silently replacing the GRDB database.
final class DataBackupOriginTests: XCTestCase {

    func testClassifiesByMigratorBookkeepingTable() {
        XCTAssertEqual(DataBackup.backupOrigin(of: ["grdb_migrations", "dailyMetric", "hrSample"]),
                       .mac)
        XCTAssertEqual(DataBackup.backupOrigin(of: ["room_master_table", "daily_metrics"]),
                       .android)
        // Neither marker (empty/pre-migration file): fall through to the normal path.
        XCTAssertEqual(DataBackup.backupOrigin(of: ["some_table"]), .unknown)
        XCTAssertEqual(DataBackup.backupOrigin(of: []), .unknown)
        // Both markers: this platform's marker wins (restoring here is less destructive).
        XCTAssertEqual(DataBackup.backupOrigin(of: ["grdb_migrations", "room_master_table"]),
                       .mac)
    }
}
