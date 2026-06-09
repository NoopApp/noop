package com.noop.notif

import android.content.Context
import android.os.Handler
import android.os.Looper
import com.noop.NoopApplication
import com.noop.ui.NotifPrefs

internal enum class CallAlertSource {
    PHONE,
    VOIP,
}

/**
 * Shared call-buzz coordinator for native phone state and strict VoIP notifications.
 * Multiple sources can be active at once, but only one throttled repeat loop drives the strap.
 */
internal object CallAlertController {
    private val handler = Handler(Looper.getMainLooper())
    private val policy = CallAlertPolicy()
    private val activeTokens = linkedSetOf<String>()
    private var buzzCount = 0
    private var lastBuzzAtMs: Long? = null
    private var appContext: Context? = null

    private val repeatRunnable = object : Runnable {
        override fun run() {
            val ctx = appContext ?: return
            maybeBuzz(ctx)
        }
    }

    fun start(context: Context, source: CallAlertSource, key: String = source.name): Boolean {
        if (!sourceEnabled(context, source)) return false
        appContext = context.applicationContext
        val wasInactive = activeTokens.isEmpty()
        activeTokens.add("${source.name}:$key")
        if (wasInactive) {
            buzzCount = 0
            lastBuzzAtMs = null
            handler.removeCallbacks(repeatRunnable)
            maybeBuzz(context.applicationContext)
        }
        return true
    }

    fun stop(source: CallAlertSource, key: String = source.name) {
        activeTokens.remove("${source.name}:$key")
        if (activeTokens.isEmpty()) resetLoop()
    }

    fun stopSource(source: CallAlertSource) {
        activeTokens.removeAll { it.startsWith("${source.name}:") }
        if (activeTokens.isEmpty()) resetLoop()
    }

    fun stopAll() {
        activeTokens.clear()
        resetLoop()
    }

    private fun maybeBuzz(context: Context) {
        pruneDisabledSources(context)
        val active = activeTokens.isNotEmpty()
        val now = System.currentTimeMillis()
        if (!policy.shouldBuzz(active, buzzCount, lastBuzzAtMs, now)) return
        if (!deliveryAllowed(context)) {
            scheduleNext()
            return
        }

        val ble = (context.applicationContext as? NoopApplication)?.ble ?: return
        ble.buzz(NotifPrefs.callLoops(context))
        buzzCount += 1
        lastBuzzAtMs = now
        scheduleNext()
    }

    private fun scheduleNext() {
        handler.removeCallbacks(repeatRunnable)
        val delay = policy.nextDelayMs(buzzCount) ?: return
        if (activeTokens.isNotEmpty()) handler.postDelayed(repeatRunnable, delay)
    }

    private fun resetLoop() {
        handler.removeCallbacks(repeatRunnable)
        buzzCount = 0
        lastBuzzAtMs = null
    }

    private fun pruneDisabledSources(context: Context) {
        activeTokens.removeAll { token ->
            val source = if (token.startsWith("${CallAlertSource.PHONE.name}:")) {
                CallAlertSource.PHONE
            } else {
                CallAlertSource.VOIP
            }
            !sourceEnabled(context, source)
        }
        if (activeTokens.isEmpty()) resetLoop()
    }

    private fun sourceEnabled(context: Context, source: CallAlertSource): Boolean {
        if (!NotifPrefs.getBool(context, NotifPrefs.MASTER, false)) return false
        if (!NotifPrefs.getBool(context, NotifPrefs.CALLS_MASTER, false)) return false
        return when (source) {
            CallAlertSource.PHONE -> NotifPrefs.getBool(context, NotifPrefs.CALLS_PHONE, false)
            CallAlertSource.VOIP -> NotifPrefs.getBool(context, NotifPrefs.CALLS_VOIP, false)
        }
    }

    private fun deliveryAllowed(context: Context): Boolean {
        if (!NotifPrefs.getBool(context, NotifPrefs.MASTER, false)) return false
        if (!NotifPrefs.getBool(context, NotifPrefs.CALLS_MASTER, false)) return false
        if (NotifPrefs.inQuietHours(context)) return false
        val ble = (context.applicationContext as? NoopApplication)?.ble ?: return false
        if (NotifPrefs.getBool(context, NotifPrefs.WORN, true) && !ble.state.value.worn) return false
        return true
    }
}
