package com.noop.data

import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * Pins the cross-platform backup classification: the import path's magic check passes for ANY
 * SQLite file, so origin is judged by the migrator's bookkeeping table — Room writes
 * room_master_table (this app), GRDB writes grdb_migrations (the Mac app). A Mac backup must
 * be rejected with the CSV-export pointer instead of silently replacing the Room database and
 * stranding the user after restart.
 */
class DataBackupOriginTest {

    @Test
    fun classifiesByMigratorBookkeepingTable() {
        assertEquals(
            DataBackup.BackupOrigin.ANDROID,
            DataBackup.backupOriginOf(setOf("room_master_table", "daily_metrics", "hr_samples")),
        )
        assertEquals(
            DataBackup.BackupOrigin.MAC,
            DataBackup.backupOriginOf(setOf("grdb_migrations", "dailyMetric", "hrSample")),
        )
        // Neither marker (empty/pre-migration file): fall through to the normal path.
        assertEquals(
            DataBackup.BackupOrigin.UNKNOWN,
            DataBackup.backupOriginOf(setOf("some_table")),
        )
        assertEquals(DataBackup.BackupOrigin.UNKNOWN, DataBackup.backupOriginOf(emptySet()))
        // A pathological file carrying BOTH markers reads as Android (this platform's marker
        // wins — restoring it here is the less destructive interpretation).
        assertEquals(
            DataBackup.BackupOrigin.ANDROID,
            DataBackup.backupOriginOf(setOf("room_master_table", "grdb_migrations")),
        )
    }
}
