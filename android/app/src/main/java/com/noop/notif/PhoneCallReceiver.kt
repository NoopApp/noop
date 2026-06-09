package com.noop.notif

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.telephony.TelephonyManager

/**
 * Native phone-call bridge. It listens only for state changes and never reads the
 * incoming number extra, contacts, or call log.
 */
class PhoneCallReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != TelephonyManager.ACTION_PHONE_STATE_CHANGED) return
        when (intent.getStringExtra(TelephonyManager.EXTRA_STATE)) {
            TelephonyManager.EXTRA_STATE_RINGING ->
                CallAlertController.start(context, CallAlertSource.PHONE)
            TelephonyManager.EXTRA_STATE_IDLE,
            TelephonyManager.EXTRA_STATE_OFFHOOK ->
                CallAlertController.stopSource(CallAlertSource.PHONE)
        }
    }
}
