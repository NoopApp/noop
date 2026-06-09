package com.noop.notif

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class VoipCallClassifierTest {
    @Test
    fun acceptsKnownPackageWithCallCategory() {
        val metadata = VoipCallClassifier.Metadata(
            category = VoipCallClassifier.CATEGORY_CALL,
            isOngoing = false,
            isForegroundService = false,
            isGroupSummary = false,
        )

        assertTrue(VoipCallClassifier.isIncomingCallNotification("com.whatsapp", metadata))
    }

    @Test
    fun rejectsOngoingKnownPackageCallCategory() {
        val metadata = VoipCallClassifier.Metadata(
            category = VoipCallClassifier.CATEGORY_CALL,
            isOngoing = true,
            isForegroundService = false,
            isGroupSummary = false,
        )

        assertFalse(VoipCallClassifier.isIncomingCallNotification("org.thoughtcrime.securesms", metadata))
    }

    @Test
    fun rejectsUnknownPackagesAndNormalNotifications() {
        val callMetadata = VoipCallClassifier.Metadata(
            category = VoipCallClassifier.CATEGORY_CALL,
            isOngoing = false,
            isForegroundService = false,
            isGroupSummary = false,
        )
        val messageMetadata = callMetadata.copy(category = "msg")

        assertFalse(VoipCallClassifier.isIncomingCallNotification("com.example.chat", callMetadata))
        assertFalse(VoipCallClassifier.isIncomingCallNotification("com.whatsapp", messageMetadata))
    }

    @Test
    fun rejectsOngoingForegroundOrGroupSummaryCallNotifications() {
        val metadata = VoipCallClassifier.Metadata(
            category = VoipCallClassifier.CATEGORY_CALL,
            isOngoing = false,
            isForegroundService = false,
            isGroupSummary = false,
        )

        assertFalse(VoipCallClassifier.isIncomingCallNotification("com.whatsapp", metadata.copy(isOngoing = true)))
        assertFalse(VoipCallClassifier.isIncomingCallNotification("com.whatsapp", metadata.copy(isForegroundService = true)))
        assertFalse(VoipCallClassifier.isIncomingCallNotification("com.whatsapp", metadata.copy(isGroupSummary = true)))
    }

    @Test
    fun rejectsNullCategoryEvenForKnownPackages() {
        val metadata = VoipCallClassifier.Metadata(
            category = null,
            isOngoing = false,
            isForegroundService = false,
            isGroupSummary = false,
        )

        assertFalse(VoipCallClassifier.isIncomingCallNotification("us.zoom.videomeetings", metadata))
    }
}
