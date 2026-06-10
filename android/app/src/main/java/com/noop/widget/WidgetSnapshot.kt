package com.noop.widget

import android.content.Context
import androidx.glance.appwidget.GlanceAppWidgetManager
import androidx.glance.appwidget.updateAll

/**
 * The handful of numbers the home-screen widget shows, persisted to SharedPreferences so the
 * widget can render after a process restart (Glance recomposes from disk, not from app memory).
 */
data class WidgetSnapshot(
    /** Today's recovery 0–100, null until NOOP has scored enough nights (honest-blank). */
    val recoveryPct: Int? = null,
    /** Live heart rate, null when not streaming. */
    val heartRate: Int? = null,
    /** Strap battery 0–100, null until the strap reports it. */
    val batteryPct: Int? = null,
    val connected: Boolean = false,
    /** Wall-clock millis of the last push, so the widget can show honest staleness. */
    val updatedAtMs: Long = 0L,
)

/**
 * Persists snapshots and tells Glance to recompose. Both producers funnel through [push]:
 * [com.noop.ble.WhoopConnectionService] (long-lived — the widget's heartbeat while the app UI is
 * closed) and [com.noop.ui.AppViewModel] (covers foreground use with the background service off).
 *
 * Throttled by [PushGate] (see its KDoc). CALLER CONTRACT (#82): collect with backpressure
 * (`conflate()` + `collect`), NEVER `collectLatest` — push suspends in Glance machinery longer than
 * the live-HR emission interval (~1/s), so collectLatest cancels every push mid-flight and the
 * widget starves on stale prefs forever while the strap streams.
 */
object WidgetSnapshotStore {
    private const val FILE = "noop_widget"

    suspend fun push(context: Context, snap: WidgetSnapshot) {
        val app = context.applicationContext
        // Cheap, non-suspending gate FIRST — at live-HR cadence (~1/s) almost every call ends here.
        if (!PushGate.admit(snap)) return

        // Persist before anything suspending, and only THEN mark the gate (#82: marking before the
        // write let a cancelled push burn the refresh window — the widget starved on stale prefs).
        // Saving even with no widget placed means a widget added later renders fresh data instantly.
        save(app, snap)
        PushGate.markPushed(snap)

        val ids = runCatching {
            GlanceAppWidgetManager(app).getGlanceIds(NoopGlanceWidget::class.java)
        }.getOrDefault(emptyList())
        if (ids.isEmpty()) return
        runCatching { NoopGlanceWidget().updateAll(app) }
    }

    fun save(context: Context, snap: WidgetSnapshot) {
        context.getSharedPreferences(FILE, Context.MODE_PRIVATE).edit()
            .putInt("recovery", snap.recoveryPct ?: -1)
            .putInt("hr", snap.heartRate ?: -1)
            .putInt("battery", snap.batteryPct ?: -1)
            .putBoolean("connected", snap.connected)
            .putLong("updatedAt", snap.updatedAtMs)
            .apply()
    }

    fun load(context: Context): WidgetSnapshot {
        val p = context.getSharedPreferences(FILE, Context.MODE_PRIVATE)
        return WidgetSnapshot(
            recoveryPct = p.getInt("recovery", -1).takeIf { it >= 0 },
            heartRate = p.getInt("hr", -1).takeIf { it > 0 },
            batteryPct = p.getInt("battery", -1).takeIf { it >= 0 },
            connected = p.getBoolean("connected", false),
            updatedAtMs = p.getLong("updatedAt", 0L),
        )
    }
}

/**
 * The push-throttle decision, extracted pure so it's unit-testable (PushGateTests). Meaningful
 * changes (recovery, battery 5%-bucket, connection, and HR presence — so the FIRST heart-rate
 * sample shows immediately, #82) admit straight away; an unchanged key re-admits once per
 * [HR_REFRESH_MS] so the displayed HR still ticks. Glance re-inflation is far heavier than a
 * notification post, hence the gate.
 */
internal object PushGate {
    private const val HR_REFRESH_MS = 60_000L

    private var lastKey: String? = null
    private var lastPushAtMs = 0L

    private fun keyOf(snap: WidgetSnapshot): String =
        "${snap.recoveryPct}|${snap.batteryPct?.div(5)}|${snap.connected}|${snap.heartRate != null}"

    fun admit(snap: WidgetSnapshot): Boolean =
        keyOf(snap) != lastKey || snap.updatedAtMs - lastPushAtMs >= HR_REFRESH_MS

    fun markPushed(snap: WidgetSnapshot) {
        lastKey = keyOf(snap)
        lastPushAtMs = snap.updatedAtMs
    }

    fun resetForTest() {
        lastKey = null
        lastPushAtMs = 0L
    }
}
