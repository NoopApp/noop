package com.noop.notif

import android.app.Notification
import android.service.notification.NotificationListenerService
import android.service.notification.StatusBarNotification
import com.noop.NoopApplication
import com.noop.ui.NotifPrefs

/**
 * Wrist alerts — mirror selected app notifications to a strap buzz.
 *
 * Declaring this service (with BIND_NOTIFICATION_LISTENER_SERVICE in the manifest) is what makes NOOP
 * appear in Android's **Notification Access** list at all (issue #52 — before this, the "Open
 * Notification Access" button opened a list NOOP wasn't in). When the user grants access, Android binds
 * this service and delivers [onNotificationPosted]; we gate on the persisted [NotifPrefs] settings the
 * Notifications screen already writes (master toggle, per-app opt-in, quiet hours, only-when-worn) and
 * buzz the strap with the app's chosen pattern.
 *
 * Everything stays on-device: we never read notification CONTENT — only which package posted, to decide
 * whether to tap the wrist. The buzz uses the same RUN_HAPTICS_PATTERN path as Test buzz, so it works on
 * WHOOP 4.0; on 5/MG the haptic command isn't honoured yet (issue #48).
 */
class NoopNotificationListener : NotificationListenerService() {

    override fun onNotificationPosted(sbn: StatusBarNotification) {
        val ctx = applicationContext
        val n = sbn.notification ?: return

        if (VoipCallClassifier.isKnownVoipPackage(sbn.packageName)) {
            val metadata = VoipCallClassifier.metadataOf(n, isOngoing = sbn.isOngoing)
            if (VoipCallClassifier.isIncomingCallNotification(sbn.packageName, metadata)) {
                // An incoming VoIP call is handled ONLY by the Calls path — never ALSO as a per-app
                // alert. Always return: start() is a no-op when Calls is off, but either way a call
                // notification must not fall through and double-buzz the same app's per-app alert.
                CallAlertController.start(ctx, CallAlertSource.VOIP, sbn.key)
                return
            } else {
                CallAlertController.stop(CallAlertSource.VOIP, sbn.key)
            }
        }

        // Master gate + per-app opt-in (both default off — nothing buzzes until the user turns it on).
        if (!NotifPrefs.getBool(ctx, NotifPrefs.MASTER, false)) return
        if (!NotifPrefs.appEnabled(ctx, sbn.packageName)) return

        // Skip noise: ongoing/foreground-service notifications and group summaries aren't user-facing alerts.
        if (sbn.isOngoing) return
        if ((n.flags and Notification.FLAG_GROUP_SUMMARY) != 0) return
        if ((n.flags and Notification.FLAG_FOREGROUND_SERVICE) != 0) return

        if (NotifPrefs.inQuietHours(ctx)) return

        val ble = (application as? NoopApplication)?.ble ?: return
        // Only-when-worn (default on): don't buzz an empty strap on the desk.
        if (NotifPrefs.getBool(ctx, NotifPrefs.WORN, true) && !ble.state.value.worn) return

        // Buzz with the app's chosen pattern. send() is a safe no-op if the strap isn't connected.
        ble.buzz(NotifPrefs.appLoops(ctx, sbn.packageName))
    }

    override fun onNotificationRemoved(sbn: StatusBarNotification) {
        if (VoipCallClassifier.isKnownVoipPackage(sbn.packageName)) {
            CallAlertController.stop(CallAlertSource.VOIP, sbn.key)
        }
    }
}
