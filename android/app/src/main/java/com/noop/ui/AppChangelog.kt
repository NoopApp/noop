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
    const val CURRENT_VERSION = "1.18"

    data class Release(
        val version: String,
        val title: String,
        val date: String,
        val items: List<String>,
    )

    /** Newest first. */
    val releases: List<Release> = listOf(
        Release(
            version = "1.18",
            title = "Import fixes — both sources, all data types",
            date = "June 2026",
            items = listOf(
                "Fixed (Mac): importing an Apple Health export overwrote your WHOOP import's status message in Data Sources — the two shared one status line, so it looked like Apple Health replaced your WHOOP data. Each source now keeps its own status and result (and the Apple Health card shows its own). Your data was always stored separately; only the on-screen message was wrong.",
                "Fixed (Android): a single Health Connect data type failing (e.g. \"count must not be less than 1\" on some devices) aborted the entire import. Each data type is now read independently, so one quirky type is skipped and everything else still imports.",
            ),
        ),
        Release(
            version = "1.17",
            title = "Sleep from WHOOP 4 on more firmware (Mac)",
            date = "June 2026",
            items = listOf(
                "Fixed (Mac): no sleep recorded from a WHOOP 4 on certain firmware. NOOP stages your sleep from the strap's overnight motion data — but historical records from firmware versions it hadn't mapped were being silently dropped, so the offload finished yet produced no motion → no sleep. NOOP now falls back to the standard record layout for unmapped firmware, accepting it only when it decodes to physically-real data (so it can never store garbage), and surfaces a genuinely-unknown firmware version in the strap log. If your WHOOP 4 wasn't recording sleep, update and wear it overnight while connected.",
            ),
        ),
        Release(
            version = "1.16",
            title = "Health Connect shows as Health Connect",
            date = "June 2026",
            items = listOf(
                "Fixed (Android): data imported from Health Connect was being shown as \"Apple Health.\" It's now filed under its own Health Connect source and counted on the Health Connect card. Nothing was ever lost — it was a labelling bug — and your already-imported data refiles itself automatically the next time you import from Health Connect.",
            ),
        ),
        Release(
            version = "1.15",
            title = "WHOOP 5/MG: the buzz works",
            date = "June 2026",
            items = listOf(
                "The wrist buzz now works on WHOOP 5.0/MG (experimental). Now that live heart rate confirmed a 5/MG strap acts on NOOP's commands, the haptic buzz — Test buzz, the smart alarm — is wired through the same path. Try Test buzz in Notifications; if it doesn't fire on your 5/MG strap, let us know. (Battery already worked on 5/MG via the standard profile.) WHOOP 4.0 is unchanged.",
            ),
        ),
        Release(
            version = "1.14",
            title = "Android Today: clearer empty states",
            date = "June 2026",
            items = listOf(
                "Android Today now reads honestly when you don't have data for the actual day yet: missing metrics show a clear \"No Data\" instead of blank dashes, and the recovery ring no longer shows a depleted 0% when there's simply no score for today. Added a Today footer with your recent workouts and Data Sources counts, so imported history is clearly labelled as history — matching the Mac. Completes the stale-import cleanup from the last few releases.",
            ),
        ),
        Release(
            version = "1.13",
            title = "WHOOP 5/MG heart rate on Android",
            date = "June 2026",
            items = listOf(
                "WHOOP 5.0/MG live heart rate now works on Android. Once the strap bonds, NOOP subscribes to its realtime data channels and decodes the heart-rate stream the same way the Mac does — before, Android only listened on the standard profile, which a 5/MG strap doesn't stream, so it bonded but showed no HR. Still experimental: 5/MG owners, update and share a strap log if it doesn't come through. WHOOP 4.0 is unaffected.",
            ),
        ),
        Release(
            version = "1.12",
            title = "WHOOP 5/MG heart rate on Mac + a Readiness fix",
            date = "June 2026",
            items = listOf(
                "WHOOP 5.0/MG on Mac: the secure pairing now completes and live heart rate comes through. NOOP waits for the strap to bond before subscribing to its data channels — subscribing too early was the silent failure — then asks it to start streaming with the right framing. If the strap won't bond on first connect, NOOP now tells you to close the official WHOOP app and put the strap in pairing mode (blue LEDs flashing), which is what lets it pair. Still experimental on 5/MG; built from a 5/MG owner's verified flow. (Android 5/MG bonding landed in v1.10; WHOOP 4.0 is untouched.)",
                "Readiness now reflects today, not a stale import. After importing months-old WHOOP history, the \"Should you push today?\" card was still reading off the newest imported day. It now anchors to your real calendar day on both Mac and Android — completing the v1.11 dashboard fix — so an old import no longer drives today's readiness.",
            ),
        ),
        Release(
            version = "1.11",
            title = "Today reflects today (not stale imports)",
            date = "June 2026",
            items = listOf(
                "Fixed the dashboard treating the newest imported day as \"today\" after a historical import — so months-old data showed as today's recovery/readiness. Today now shows only a row for your actual calendar date, and the 14-day sparklines and Trends W/M/3M windows are anchored to today. Older imports stay visible under the wider ranges / All history. Fixed on both Mac and Android.",
            ),
        ),
        Release(
            version = "1.10",
            title = "5/MG bonding on Android + Health Monitor fix",
            date = "June 2026",
            items = listOf(
                "WHOOP 5.0/MG on Android: fixed the strap connecting but never bonding (it wrote the opening message unacknowledged, which didn't trigger the encrypted pairing the strap needs before it will stream). It's now a confirmed write that triggers bonding, so live heart rate can come through. Still experimental — 5/MG owners, please update and share a strap log.",
                "Fixed the Health Monitor heart-rate freezing when you opened it from the Live page. Leaving Live was switching the live HR stream off entirely; the stream now stays on while any live-HR screen is open.",
            ),
        ),
        Release(
            version = "1.9",
            title = "Fix: bonded but no live data (Android)",
            date = "June 2026",
            items = listOf(
                "Fixed an Android bug where the strap would connect and bond but show no live data at all — heart rate, battery, worn and events all blank — on some phones (it shows up reliably on newer Android). A Bluetooth callback-threading race let the pairing write starve the data-stream subscriptions; NOOP now pins all Bluetooth callbacks to one thread and retries a momentarily-busy subscription, so the stream comes up reliably. Reported, diagnosed and hardware-verified by a community contributor.",
            ),
        ),
        Release(
            version = "1.8",
            title = "Strap-log export on Mac + a Health Monitor fix",
            date = "June 2026",
            items = listOf(
                "Mac: you can now export the strap log — Copy / Save… on the Live screen's strap log — so Mac users can attach it to a bug report too (Android has had this since 1.6).",
                "Fixed the Health Monitor heart-rate chart sitting on a flat line: it now plots your live heart rate over time instead of deriving from sparse R-R data.",
            ),
        ),
        Release(
            version = "1.7",
            title = "WHOOP 5/MG frame capture (Mac)",
            date = "June 2026",
            items = listOf(
                "Mac: new opt-in “Record puffin frames” under Settings → Experimental. While connected to a WHOOP 5/MG strap it logs the raw frames — each stamped with your live heart rate as a cross-check — to a file you can export, so 5/MG owners can contribute the data we need to decode recovery, strain and sleep. Read-only, off by default; WHOOP 4.0 is unaffected. Built on community contributions toward the 5/MG protocol.",
            ),
        ),
        Release(
            version = "1.6",
            title = "Share strap logs, and a worn-status fix",
            date = "June 2026",
            items = listOf(
                "New on Android: Settings → Strap → “Share strap log” exports the connection log to a file you can attach to a bug report. If your strap won't connect or behaves oddly, this is the single most helpful thing you can send.",
                "Fixed on Android: the “Worn” status always reading Off. It now assumes you're wearing the strap until the strap says otherwise, matching the Mac app.",
            ),
        ),
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
