import XCTest
@testable import Strand

/// Pins the cross-platform backup classification (mirror of the Android DataBackupOriginTest):
/// the import path's magic-header check passes for ANY SQLite file, so origin is judged by the
/// migrator's bookkeeping table — GRDB writes `grdb_migrations` (this app), Room writes
/// `room_master_table` (the Android app). An Android backup must be rejected rather than silently
/// replacing the GRDB database and stranding the user after the relaunch.
final class DataBackupOriginTests: XCTestCase {

    func testClassifiesByMigratorBookkeepingTable() {
        XCTAssertEqual(DataBackup.backupOrigin(of: ["grdb_migrations", "dailyMetric", "hrSample"]),
                       .mac)
        XCTAssertEqual(DataBackup.backupOrigin(of: ["room_master_table", "daily_metrics"]),
                       .android)
        // Neither marker (empty/pre-migration file): fall through to the normal path.
        XCTAssertEqual(DataBackup.backupOrigin(of: ["some_table"]), .unknown)
        XCTAssertEqual(DataBackup.backupOrigin(of: []), .unknown)
    }

    func testThisPlatformWinsWhenBothMarkersPresent() {
        // Degenerate both-present case: restoring here is the less destructive read.
        XCTAssertEqual(DataBackup.backupOrigin(of: ["grdb_migrations", "room_master_table"]),
                       .mac)
    }

    func testOlderRoomLayoutDetectedByAndroidMetadataPair() {
        // Pre-`room_master_table` Room/AndroidX backups still carry the android_metadata +
        // sqlite_sequence duo — flag those as Android too.
        XCTAssertEqual(DataBackup.backupOrigin(of: ["android_metadata", "sqlite_sequence", "daily_metrics"]),
                       .android)
        // android_metadata alone (no Room sequence table) stays unknown — don't over-reject.
        XCTAssertEqual(DataBackup.backupOrigin(of: ["android_metadata"]), .unknown)
    }
}
