package com.noop.notif

import android.app.Notification

/**
 * Strict VoIP call detection for NotificationListenerService.
 *
 * The classifier intentionally uses only package name, category, and flags. It does not
 * inspect title, text, people, sender, or extras that may contain caller/message content.
 */
internal object VoipCallClassifier {
    const val CATEGORY_CALL = "call"

    private val knownVoipPackages = setOf(
        "com.whatsapp",
        "org.thoughtcrime.securesms",
        "org.telegram.messenger",
        "com.microsoft.teams",
        "us.zoom.videomeetings",
        "com.google.android.apps.tachyon",
        "com.google.android.apps.meetings",
        "com.facebook.orca",
    )

    data class Metadata(
        val category: String?,
        val isOngoing: Boolean,
        val isForegroundService: Boolean,
        val isGroupSummary: Boolean,
    )

    fun isKnownVoipPackage(packageName: String): Boolean =
        packageName in knownVoipPackages

    fun isIncomingCallNotification(packageName: String, metadata: Metadata): Boolean {
        if (!isKnownVoipPackage(packageName)) return false
        if (metadata.isForegroundService || metadata.isGroupSummary) return false
        // Do not read CallStyle extras here: this trades VoIP recall for the documented
        // wrist-alert privacy contract that notification extras are not inspected.
        return metadata.category == CATEGORY_CALL && !metadata.isOngoing
    }

    fun metadataOf(notification: Notification, isOngoing: Boolean): Metadata =
        Metadata(
            category = notification.category,
            isOngoing = isOngoing,
            isForegroundService = (notification.flags and Notification.FLAG_FOREGROUND_SERVICE) != 0,
            isGroupSummary = (notification.flags and Notification.FLAG_GROUP_SUMMARY) != 0,
        )
}
