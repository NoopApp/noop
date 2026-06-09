package com.noop.ingest

import android.content.Context
import androidx.health.connect.client.HealthConnectClient
import androidx.work.Constraints
import androidx.work.CoroutineWorker
import androidx.work.ExistingPeriodicWorkPolicy
import androidx.work.PeriodicWorkRequestBuilder
import androidx.work.WorkManager
import androidx.work.WorkerParameters
import com.noop.NoopApplication
import com.noop.ui.NoopPrefs
import java.util.concurrent.TimeUnit

/**
 * Periodic background sync of Health Connect into the local store (Samsung Health → Health
 * Connect → NOOP). This is the "set it and forget it" companion to the manual "Import from Health
 * Connect" button on the Data Sources screen: with auto-sync on, NOOP re-pulls new daily data
 * (VO₂max, SpO₂, resting-HR, HRV, sleep, workouts) on a schedule without any taps.
 *
 * Two mechanisms, by design — Health Connect restricts background reads, so a worker alone can't be
 * relied on across all Android versions:
 *   1. This [HealthConnectSyncWorker] runs on a WorkManager [PeriodicWorkRequest] (best-effort
 *      true-background, runs when the OS allows and battery isn't low).
 *   2. A foreground catch-up in [com.noop.ui.AppViewModel.syncHealthConnectIfStale] imports
 *      whenever the app is opened and the last sync is older than the chosen interval — the
 *      dependable sync point that never needs the background-read permission.
 *
 * Read-only and idempotent: the importer upserts on natural keys and never overwrites richer WHOOP
 * data, so re-running is always safe. Nothing leaves the device.
 */
class HealthConnectSyncWorker(
    context: Context,
    params: WorkerParameters,
) : CoroutineWorker(context, params) {

    override suspend fun doWork(): Result {
        val ctx = applicationContext
        if (!NoopPrefs.hcAutoSync(ctx)) return Result.success()
        if (HealthConnectImporter.sdkStatus(ctx) != HealthConnectClient.SDK_AVAILABLE) {
            return Result.success()
        }
        // Can't prompt for permissions from the background; if they aren't granted, the in-app flow
        // asks next time the user opens Data Sources. Treat as a clean no-op, not a failure.
        val granted = runCatching {
            HealthConnectImporter.client(ctx).permissionController.getGrantedPermissions()
        }.getOrDefault(emptySet())
        if (!granted.containsAll(HealthConnectImporter.PERMISSIONS)) return Result.success()

        val app = ctx as? NoopApplication ?: return Result.success()
        val ran = runCatching { HealthConnectImporter.import(ctx, app.repository) }
        if (ran.isFailure) return Result.retry()
        NoopPrefs.setHcLastSync(ctx, System.currentTimeMillis())
        return Result.success()
    }
}

/** Scheduler for the periodic Health Connect sync. Idempotent: safe to call on every app start. */
object HealthConnectSync {

    private const val UNIQUE = "noop.hcPeriodicSync"

    /**
     * Register or cancel the periodic sync to match the current preference. Uses a unique periodic
     * work with [ExistingPeriodicWorkPolicy.UPDATE] so changing the interval re-targets the same
     * job rather than stacking duplicates.
     */
    fun apply(context: Context, enabled: Boolean, hours: Int) {
        val wm = WorkManager.getInstance(context.applicationContext)
        if (!enabled) {
            wm.cancelUniqueWork(UNIQUE)
            return
        }
        val constraints = Constraints.Builder()
            .setRequiresBatteryNotLow(true)
            .build()
        val request = PeriodicWorkRequestBuilder<HealthConnectSyncWorker>(
            hours.toLong(), TimeUnit.HOURS,
        ).setConstraints(constraints).build()
        wm.enqueueUniquePeriodicWork(UNIQUE, ExistingPeriodicWorkPolicy.UPDATE, request)
    }

    /** Re-apply the saved preference at process start, so the job survives reboots and app updates. */
    fun reschedule(context: Context) {
        apply(context, NoopPrefs.hcAutoSync(context), NoopPrefs.hcSyncHours(context))
    }
}
