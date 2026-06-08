package com.noop.ui

import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.HourglassEmpty
import androidx.compose.material.icons.outlined.Science
import androidx.compose.material.icons.outlined.Shield
import androidx.compose.material.icons.outlined.VerifiedUser
import androidx.compose.ui.graphics.vector.ImageVector

// MARK: - AppChangelog (ported byte-for-byte from Strand/System/AppChangelog.swift)
//
// Single source of truth for the in-app "What's New" sheet and the expectation-setting
// copy used in onboarding. Mirrored from the macOS `AppChangelog` enum so every surface
// — macOS, Android, the repo CHANGELOG.md — tells the exact same story.
//
// Icon mapping (SF Symbol → Material, all verified to resolve in material-icons-extended):
//   flask           → Icons.Outlined.Science        (independent / experimental)
//   checkmark.seal  → Icons.Outlined.VerifiedUser   (the supported path)
//   hourglass       → Icons.Outlined.HourglassEmpty (scores build over time)
//   lock.shield     → Icons.Outlined.Shield         (everything stays on-device)

object AppChangelog {

    /**
     * Bump this when you add a release below. The "What's New" sheet shows automatically when the
     * stored last-seen version is behind this. (Decoupled from the bundle version on purpose.)
     */
    const val CURRENT_VERSION = "1.5"

    data class Release(
        val version: String,
        val title: String,
        val date: String,
        val items: List<String>,
    )

    /** Newest first. */
    val releases: List<Release> = listOf(
        Release(
            version = "1.5",
            title = "WHOOP 5/MG: secure-pairing fix",
            date = "June 2026",
            items = listOf(
                "WHOOP 5.0/MG: fixed connecting getting stuck at “Finishing the secure pairing handshake.” NOOP now establishes the encrypted pairing first, then subscribes — so live heart rate can come through instead of hanging. Still experimental on 5/MG: if you have one, please try it and share your strap log on GitHub so we can keep improving it.",
            ),
        ),
        Release(
            version = "1.4",
            title = "Live heart rate that doesn't freeze",
            date = "June 2026",
            items = listOf(
                "Fixed live heart rate freezing on a stale number mid-session. NOOP now keeps the strap's realtime stream re-armed and, if the link goes quiet, quietly reconnects on its own — no more disconnect-and-reconnect by hand to un-stick it. (Android now matches how the Mac app already behaved.)",
                "Hardened the Bluetooth frame reader so a single corrupt packet can't wedge the live stream until you reconnect.",
            ),
        ),
        Release(
            version = "1.3",
            title = "Stays connected in the background",
            date = "June 2026",
            items = listOf(
                "NOOP now keeps your strap connected when the app is closed. On Android it shows a quiet ongoing notification and keeps streaming your heart rate; on Mac, just close the window and NOOP keeps running from the menu bar.",
                "New “Keep connected in the background” toggle in Settings → Strap (on by default). Turn it off and NOOP disconnects whenever you close the app.",
                "Fixed the strap dropping the moment you closed the app, and made sure the notification permission is actually requested.",
            ),
        ),
        Release(
            version = "1.2",
            title = "Readiness, and the start of WHOOP 5/MG",
            date = "June 2026",
            items = listOf(
                "New Readiness card on Today — a “should you push today?” read from your own history: HRV vs your baseline, resting-heart-rate drift, sleeping respiratory rate, training-load balance and training variety, rolled into one headline.",
                "WHOOP 5/MG: live heart rate now works. Deeper 5/MG metrics (recovery, strain, sleep) are still experimental and being worked on.",
                "Opt-in WHOOP 5/MG protocol probes under Settings → Experimental, for 5/MG owners who want to help map the protocol.",
                "German and other localized WHOOP exports now import with real values, not blanks.",
                "Fixed the WHOOP 5/MG “stuck connecting” state and the macOS “Choose export” button.",
            ),
        ),
        Release(
            version = "1.1",
            title = "Scores live from the strap",
            date = "June 2026",
            items = listOf(
                "Recovery, strain and sleep now compute live on-device from the strap, not only from an import. They calibrate over your first few nights, like any recovery wearable.",
                "Pick your strap (WHOOP 4.0 or 5.0/MG) before connecting, so it looks for the right one.",
                "macOS is now a universal build that runs on both Intel and Apple Silicon.",
            ),
        ),
        Release(
            version = "1.0",
            title = "First release",
            date = "June 2026",
            items = listOf(
                "Pair directly with a WHOOP strap over Bluetooth — no WHOOP account, no cloud.",
                "Compute recovery, strain, HRV and sleep locally on your own device.",
                "Bring your history: import a WHOOP export, an Apple Health export, or Android Health Connect.",
            ),
        ),
    )

    /**
     * Expectation-setting points shown during onboarding and at the top of "What's New". This is the
     * “what is this and what should I expect” story, so people don't have to go read GitHub.
     */
    data class Expectation(
        val icon: ImageVector,
        val title: String,
        val body: String,
    )

    val expectations: List<Expectation> = listOf(
        Expectation(
            icon = Icons.Outlined.Science,
            title = "Independent, and experimental",
            body = "NOOP is a personal, open project — not the WHOOP app, and not affiliated with WHOOP. It reads a strap you own, on your own device. Treat it as a capable work-in-progress rather than a finished product.",
        ),
        Expectation(
            icon = Icons.Outlined.VerifiedUser,
            title = "WHOOP 4.0 is the supported path",
            body = "WHOOP 4.0 is tested and works end to end. WHOOP 5.0/MG is newer: live heart rate works today, but deeper metrics (recovery, strain, sleep) for 5/MG are still being figured out. NOOP always tells you what's live versus still building.",
        ),
        Expectation(
            icon = Icons.Outlined.HourglassEmpty,
            title = "Your scores build over a few nights",
            body = "Live heart rate is instant. Recovery, strain and sleep sharpen as NOOP learns your baseline over your first nights of wear. Want your history now? Import your WHOOP export in Data Sources and it backfills in about a minute.",
        ),
        Expectation(
            icon = Icons.Outlined.Shield,
            title = "Everything stays on your device",
            body = "No account, no cloud, no sync. NOOP talks only to your strap and keeps everything local. Your data is yours alone.",
        ),
    )
}
