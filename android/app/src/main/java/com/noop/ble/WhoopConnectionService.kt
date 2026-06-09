package com.noop.ble

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import androidx.core.app.NotificationCompat
import androidx.core.app.ServiceCompat
import androidx.core.content.ContextCompat
import com.noop.NoopApplication
import com.noop.R
import com.noop.ui.MainActivity
import com.noop.widget.WidgetSnapshot
import com.noop.widget.WidgetSnapshotStore
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.flow.catch
import kotlinx.coroutines.flow.collectLatest
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.launch
import kotlin.math.roundToInt

/**
 * Foreground service that keeps the WHOOP BLE connection alive while the app is backgrounded or
 * closed.
 *
 * Android tears a process down shortly after its last Activity goes away, which is exactly why
 * people on Reddit saw the strap disconnect the moment they closed NOOP. A started foreground
 * service — with an ongoing notification — keeps the process (and therefore the
 * [com.noop.NoopApplication]-owned [WhoopBleClient] and its GATT link) resident, so heart rate
 * keeps streaming and offloads keep landing in the background.
 *
 * It does **not** own or drive the connection: it simply holds the process up and mirrors the
 * client's [LiveState] into the notification. Start/stop is gated by a Settings toggle (see
 * `NoopPrefs.backgroundConnection`) and only ever happens from the foreground (on connect / when
 * the user flips the toggle), so we never trip Android 12+'s background-start restriction.
 *
 * The matching capability on macOS is free: `AppModel` is an app-level `@StateObject` kept alive by
 * the menu-bar extra, so closing the window leaves the strap connected.
 */
class WhoopConnectionService : Service() {

    /** Main-thread scope used only to mirror [LiveState] into the notification. */
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)

    /** The single live-state→notification collector. Re-`start`s land here repeatedly (on every
     *  connect, plus any OS restart), so we cancel the old one before launching a new one. */
    private var notifyJob: Job? = null

    private val ble get() = (application as NoopApplication).ble
    private val repo get() = (application as NoopApplication).repository

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        // The notification "Disconnect" action routes back here as a self-intent.
        if (intent?.action == ACTION_STOP) {
            runCatching { ble.disconnect() }
            ServiceCompat.stopForeground(this, ServiceCompat.STOP_FOREGROUND_REMOVE)
            stopSelf()
            return START_NOT_STICKY
        }

        ensureChannel()
        // Must call startForeground promptly after startForegroundService(). If it fails (e.g. the
        // API 34 connectedDevice type needs BLUETOOTH_CONNECT and the user denied it) we stop cleanly
        // rather than crash — the connection itself keeps working in the foreground regardless.
        if (!startForegroundCompat(buildNotification(ble.state.value, null))) {
            stopSelf()
            return START_NOT_STICKY
        }

        // Keep the ongoing notification in step with the live connection state AND today's recovery
        // (the 15-min IntelligenceEngine recompute), so it re-posts when either changes — a glanceable
        // poor-man's Live Activity (#42). daysMergedFlow is the same merged store the dashboard reads.
        notifyJob?.cancel()
        notifyJob = scope.launch {
            combine(
                ble.state,
                // Defence-in-depth: a Room/disk error in this flow would otherwise propagate uncaught
                // out of scope.launch and kill the process — the FGS exists to protect the connection,
                // not to take it down. (Audited during #82, which proved unrelated/unreproducible —
                // this guard is belt-and-braces, not a diagnosed fix.) After catch{emit} the inner
                // flow completes; combine keeps running on ble.state with days frozen.
                repo.daysMergedFlow("my-whoop").catch { emit(emptyList()) },
            ) { state, days ->
                val todayKey = java.time.LocalDate.now().toString()
                state to days.lastOrNull { it.day == todayKey }?.recovery
            }.catch { /* belt-and-braces: a frozen notification beats a dead process */ }
                .collectLatest { (state, recovery) ->
                postNotification(state, recovery)
                // Feed the home-screen widget from the same stream — this service is its heartbeat
                // while the app UI is closed. Throttled + no-op without a placed widget (the store
                // checks both); runCatching so a Glance hiccup never tears down the connection.
                runCatching {
                    WidgetSnapshotStore.push(
                        this@WhoopConnectionService,
                        WidgetSnapshot(
                            recoveryPct = recovery?.roundToInt(),
                            heartRate = state.heartRate,
                            batteryPct = state.batteryPct?.roundToInt(),
                            connected = state.connected,
                            updatedAtMs = System.currentTimeMillis(),
                        ),
                    )
                }
            }
        }

        // START_NOT_STICKY: the FGS's job is to keep this process *alive* (which it does while
        // running, making OS kills unlikely). We deliberately do NOT resurrect after a kill, because
        // a fresh process has no strap/model context to reconnect with — the user reopening the app
        // re-establishes it. Resurrecting would only show a "Reconnecting…" notification that never
        // resolves.
        return START_NOT_STICKY
    }

    /** Promote to the foreground. Returns false (rather than throwing) if the platform refuses. */
    private fun startForegroundCompat(notification: Notification): Boolean = runCatching {
        val type =
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                ServiceInfo.FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE
            } else {
                0
            }
        ServiceCompat.startForeground(this, NOTIF_ID, notification, type)
    }.isSuccess

    private fun postNotification(state: LiveState, recoveryPct: Double? = null) {
        // Defensive: a notify() throw (OEM quirk, revoked POST_NOTIFICATIONS on some ROMs) must not
        // crash the collector and tear down the connection we exist to keep alive.
        runCatching {
            val mgr = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            mgr.notify(NOTIF_ID, buildNotification(state, recoveryPct))
        }
    }

    private fun buildNotification(state: LiveState, recoveryPct: Double?): Notification {
        val title = when {
            !state.connected -> "Reconnecting to your WHOOP…"
            state.heartRate != null -> "${state.heartRate} bpm"
            else -> "Connected to your WHOOP"
        }
        val detail = buildList {
            add(if (state.connected) "Streaming in the background" else "Keeping the link open")
            recoveryPct?.let { add("Recovery ${it.roundToInt()}%") }
            state.batteryPct?.let { add("Strap ${it.roundToInt()}%") }
        }.joinToString("  ·  ")

        val openApp = PendingIntent.getActivity(
            this,
            0,
            Intent(this, MainActivity::class.java)
                .addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
        val stopAction = PendingIntent.getService(
            this,
            1,
            Intent(this, WhoopConnectionService::class.java).setAction(ACTION_STOP),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )

        return NotificationCompat.Builder(this, CHANNEL_ID)
            .setSmallIcon(R.drawable.ic_stat_heart)
            .setContentTitle(title)
            .setContentText(detail)
            .setContentIntent(openApp)
            .addAction(0, "Disconnect", stopAction)
            .setOngoing(true)
            .setSilent(true)
            .setShowWhen(false)
            .setCategory(Notification.CATEGORY_SERVICE)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .setVisibility(NotificationCompat.VISIBILITY_PUBLIC)
            .build()
    }

    private fun ensureChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        // Defensive: channel creation can throw on some OEM ROMs / under memory pressure; never let
        // that crash onStartCommand (it would take the FGS — and the connection — down with it).
        runCatching {
            val mgr = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            if (mgr.getNotificationChannel(CHANNEL_ID) != null) return
            val channel = NotificationChannel(
                CHANNEL_ID,
                "Strap connection",
                NotificationManager.IMPORTANCE_LOW,
            ).apply {
                description = "Shown while NOOP keeps your WHOOP connected in the background."
                setShowBadge(false)
                enableVibration(false)
                setSound(null, null)
            }
            mgr.createNotificationChannel(channel)
        }
    }

    override fun onDestroy() {
        scope.cancel()
        super.onDestroy()
    }

    companion object {
        private const val CHANNEL_ID = "noop_strap_connection"
        private const val NOTIF_ID = 4201
        const val ACTION_STOP = "com.noop.ble.action.STOP_CONNECTION"

        /**
         * Promote the process to the foreground so the strap stays connected. Safe to call when
         * already running. MUST be called from a foreground context (we call it from connect / the
         * Settings toggle) to satisfy Android 12+'s background-start rule. Defensive: any failure is
         * swallowed so it can never break the core connect flow.
         */
        fun start(context: Context) {
            runCatching {
                ContextCompat.startForegroundService(
                    context,
                    Intent(context, WhoopConnectionService::class.java),
                )
            }
        }

        /** Drop the foreground promotion. The connection itself is torn down by the caller. */
        fun stop(context: Context) {
            runCatching { context.stopService(Intent(context, WhoopConnectionService::class.java)) }
        }
    }
}
