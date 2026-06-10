package com.noop.ui

import android.content.ActivityNotFoundException
import android.content.Context
import android.content.Intent
import android.content.SharedPreferences
import android.net.Uri
import android.widget.Toast
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Campaign
import androidx.compose.material.icons.filled.Info
import androidx.compose.material.icons.filled.Science
import androidx.compose.material.icons.filled.Sensors
import androidx.compose.material.icons.filled.Storage
import androidx.compose.material.icons.outlined.Person
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Surface
import androidx.compose.material3.Switch
import androidx.compose.material3.SwitchDefaults
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.noop.BuildConfig
import com.noop.analytics.Zones
import com.noop.ble.PuffinExperiment
import com.noop.data.DataBackup
import com.noop.update.UpdateCheck
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlin.math.roundToInt

// MARK: - Settings (ported from Strand/Screens/SettingsView.swift)
//
// Profile (the numbers that power HR zones / calories / recovery baselines), a
// Backup & restore section wiring DataBackup export/import through the Storage
// Access Framework, and an About section with version + attribution + a Support
// link. Re-skinned to the locked NOOP component system: every surface is a
// NoopCard, every status uses StatePill, the two-column form feel is preserved.
//
// macOS parity notes:
//  - macOS persisted the profile in a ProfileStore (ObservableObject on disk). The
//    Android equivalent is SharedPreferences; this screen owns the only profile
//    store in the app, so HealthScreen's age-agnostic HR-max default can later read
//    from it. Values persist immediately on every change.
//  - macOS used native +/- Steppers; Compose has no Stepper, so each numeric field
//    is a tabular value flanked by round −/+ buttons (same intent, same ranges).
//  - The strap "Re-scan / Disconnect" controls map to the ViewModel's connect() /
//    disconnect() pass-throughs.
//  - Backup export/import run through SAF (CreateDocument / OpenDocument); the macOS
//    alert is mirrored by a Toast. DataBackup.exportTo already checkpoints the WAL,
//    so no separate repo checkpoint call is needed.

// MARK: - Profile store (SharedPreferences-backed; the macOS ProfileStore equivalent)

/**
 * The user's body profile — age / sex / weight / height plus an optional manual
 * HR-max override. Persisted to SharedPreferences so the values survive restarts
 * and other screens (HealthScreen, Coach zones) can read the same source of truth.
 *
 * Mirrors the macOS `ProfileStore` fields and ranges exactly. `hrMaxOverride == 0`
 * means "auto" — fall back to the Tanaka estimate from [age].
 */
class ProfileStore(private val prefs: SharedPreferences) {

    var age: Int
        get() = prefs.getInt(KEY_AGE, 30).coerceIn(AGE_MIN, AGE_MAX)
        set(v) = prefs.edit().putInt(KEY_AGE, v.coerceIn(AGE_MIN, AGE_MAX)).apply()

    /** "male" | "female" | "nonbinary" — matches the macOS tag values. */
    var sex: String
        get() = prefs.getString(KEY_SEX, "male") ?: "male"
        set(v) = prefs.edit().putString(KEY_SEX, v).apply()

    var weightKg: Double
        get() = prefs.getFloat(KEY_WEIGHT, 75f).toDouble().coerceIn(WEIGHT_MIN, WEIGHT_MAX)
        set(v) = prefs.edit().putFloat(KEY_WEIGHT, v.coerceIn(WEIGHT_MIN, WEIGHT_MAX).toFloat()).apply()

    var heightCm: Double
        get() = prefs.getFloat(KEY_HEIGHT, 178f).toDouble().coerceIn(HEIGHT_MIN, HEIGHT_MAX)
        set(v) = prefs.edit().putFloat(KEY_HEIGHT, v.coerceIn(HEIGHT_MIN, HEIGHT_MAX).toFloat()).apply()

    /** Manual max-heart-rate override in bpm; 0 = automatic (Tanaka). */
    var hrMaxOverride: Int
        get() = prefs.getInt(KEY_HRMAX, 0).coerceIn(0, 230)
        set(v) = prefs.edit().putInt(KEY_HRMAX, v.coerceIn(0, 230)).apply()

    /** The auto (Tanaka) HR-max for the current age. */
    val hrMaxAuto: Int get() = Zones.hrMaxTanaka(age)

    /** Effective HR-max: the manual override if set, else the Tanaka estimate. */
    val hrMax: Int get() = if (hrMaxOverride > 0) hrMaxOverride else hrMaxAuto

    companion object {
        private const val PREFS = "noop_profile"
        private const val KEY_AGE = "age"
        private const val KEY_SEX = "sex"
        private const val KEY_WEIGHT = "weight_kg"
        private const val KEY_HEIGHT = "height_cm"
        private const val KEY_HRMAX = "hr_max_override"

        private const val AGE_MIN = 13
        private const val AGE_MAX = 100
        private const val WEIGHT_MIN = 30.0
        private const val WEIGHT_MAX = 250.0
        private const val HEIGHT_MIN = 120.0
        private const val HEIGHT_MAX = 230.0

        fun from(context: Context): ProfileStore =
            ProfileStore(context.getSharedPreferences(PREFS, Context.MODE_PRIVATE))
    }
}

// MARK: - Screen

@Composable
fun SettingsScreen(vm: AppViewModel) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    val live by vm.live.collectAsStateWithLifecycle()

    // The profile store is stable for the lifetime of this screen; a version counter
    // forces recomposition after each mutating write (SharedPreferences isn't reactive).
    val profile = remember { ProfileStore.from(context) }
    var rev by remember { mutableStateOf(0) }
    fun mutate(block: () -> Unit) { block(); rev++ }

    var backupBusy by remember { mutableStateOf(false) }

    // Re-scan must request the runtime Bluetooth permission before scanning — without this the
    // button calls connect() directly and silently no-ops on Android 12+ when the permission was
    // denied/revoked (issue #1). Shared with Live's Connect via the one rememberRequestScan gate.
    val requestScan = rememberRequestScan { vm.connect() }

    // "What's New" changelog sheet, reachable any time from About (mirrors the macOS
    // Settings → About "What's new" button). Persistence/gating lives in NoopRoot; this
    // is a manual re-open and writes nothing.
    var showWhatsNew by remember { mutableStateOf(false) }

    // EXPERIMENTAL WHOOP 5/MG protocol probes (off by default). Mirrors the macOS @AppStorage toggle;
    // SharedPreferences isn't reactive, so the Switch drives a local mutableState that the store reads.
    val puffinExperiment = remember { PuffinExperiment.from(context) }
    var puffinExperiments by remember { mutableStateOf(puffinExperiment.isEnabled) }
    var puffinCapture by remember { mutableStateOf(puffinExperiment.isCaptureEnabled) }

    // "Keep connected in the background" — drives WhoopConnectionService (foreground service). Default
    // on. SharedPreferences isn't reactive, so the Switch mirrors into a local state.
    var backgroundConnection by remember { mutableStateOf(NoopPrefs.backgroundConnection(context)) }

    // "Debug logging" — mirror the strap log to logcat (adb). Default OFF so normal users don't.
    var debugLogging by remember { mutableStateOf(NoopPrefs.debugLogging(context)) }

    // SAF launchers — CreateDocument for export, OpenDocument for import.
    val exportLauncher = rememberLauncherForActivityResult(
        ActivityResultContracts.CreateDocument("application/octet-stream"),
    ) { uri ->
        if (uri == null) { backupBusy = false; return@rememberLauncherForActivityResult }
        scope.launch {
            val result = withContext(Dispatchers.IO) {
                runCatching { DataBackup.exportTo(context, uri) }
            }
            backupBusy = false
            result.fold(
                onSuccess = {
                    Toast.makeText(
                        context,
                        "Backup exported. Copy this file to your new phone and use Import there to restore everything.",
                        Toast.LENGTH_LONG,
                    ).show()
                },
                onFailure = { e ->
                    Toast.makeText(context, "Backup problem: ${e.message}", Toast.LENGTH_LONG).show()
                },
            )
        }
    }

    val importLauncher = rememberLauncherForActivityResult(
        ActivityResultContracts.OpenDocument(),
    ) { uri ->
        if (uri == null) { backupBusy = false; return@rememberLauncherForActivityResult }
        scope.launch {
            val result = withContext(Dispatchers.IO) {
                DataBackup.importFrom(context, uri)
            }
            backupBusy = false
            when (result) {
                is DataBackup.ImportResult.NeedsRestart -> Toast.makeText(
                    context,
                    "Backup imported. Fully close and reopen NOOP for it to take effect.",
                    Toast.LENGTH_LONG,
                ).show()
                is DataBackup.ImportResult.Failed -> Toast.makeText(
                    context, result.message, Toast.LENGTH_LONG,
                ).show()
            }
        }
    }

    ScreenScaffold(
        title = "Settings",
        subtitle = "Your numbers, your strap, and how NOOP works. All on this phone.",
    ) {
        // Read the revision counter so every profile write recomposes this subtree
        // (SharedPreferences is not observable; `mutate` bumps `rev` after each write).
        @Suppress("UNUSED_VARIABLE") val tick = rev

        // --- Profile ---
        SettingsSection(
            icon = Icons.Outlined.Person,
            title = "Profile",
            blurb = "These power your heart-rate zones, calorie estimates and recovery baselines. Keep them accurate.",
        ) {
            Column {
                FormRow(label = "Age") {
                    StepperField(
                        value = profile.age.toString(),
                        accessibility = "Age, ${profile.age} years",
                        onMinus = { mutate { profile.age -= 1 } },
                        onPlus = { mutate { profile.age += 1 } },
                    )
                }
                RowDivider()
                FormRow(label = "Sex") {
                    SegmentedPillControl(
                        items = SEX_OPTIONS,
                        selection = SEX_OPTIONS.firstOrNull { it.tag == profile.sex } ?: SEX_OPTIONS[0],
                        label = { it.label },
                        onSelect = { mutate { profile.sex = it.tag } },
                    )
                }
                RowDivider()
                FormRow(label = "Weight") {
                    StepperField(
                        value = "%.1f".format(profile.weightKg),
                        unit = "kg",
                        accessibility = "Weight in kilograms",
                        onMinus = { mutate { profile.weightKg -= 0.5 } },
                        onPlus = { mutate { profile.weightKg += 0.5 } },
                    )
                }
                RowDivider()
                FormRow(label = "Height") {
                    StepperField(
                        value = "%.0f".format(profile.heightCm),
                        unit = "cm",
                        accessibility = "Height in centimetres",
                        onMinus = { mutate { profile.heightCm -= 1 } },
                        onPlus = { mutate { profile.heightCm += 1 } },
                    )
                }
                RowDivider()
                FormRow(label = "Max heart rate") {
                    Column(horizontalAlignment = Alignment.End) {
                        StepperField(
                            value = if (profile.hrMaxOverride > 0) profile.hrMaxOverride.toString() else "Auto",
                            unit = "bpm",
                            accessibility = if (profile.hrMaxOverride == 0) {
                                "Max heart rate override, automatic"
                            } else {
                                "Max heart rate override, ${profile.hrMaxOverride} bpm"
                            },
                            valueColor = if (profile.hrMaxOverride > 0) Palette.textPrimary else Palette.textTertiary,
                            onMinus = { mutate { profile.hrMaxOverride -= 1 } },
                            onPlus = { mutate { profile.hrMaxOverride += 1 } },
                        )
                        Spacer(Modifier.height(6.dp))
                        Text(
                            text = if (profile.hrMaxOverride > 0) {
                                "Manual override"
                            } else {
                                "Auto · ${profile.hrMaxAuto} bpm (Tanaka)"
                            },
                            style = NoopType.footnote,
                            color = if (profile.hrMaxOverride > 0) Palette.accent else Palette.textTertiary,
                        )
                    }
                }
            }
        }

        // --- Strap ---
        SettingsSection(
            icon = Icons.Filled.Sensors,
            title = "Strap",
            blurb = "NOOP pairs directly with your WHOOP over Bluetooth — no WHOOP app, no cloud.",
        ) {
            Column(verticalArrangement = Arrangement.spacedBy(16.dp)) {
                Row(
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(12.dp),
                ) {
                    StatePill(
                        title = strapStatusTitle(live.bonded, live.connected),
                        tone = strapTone(live.bonded, live.connected),
                        pulsing = live.connected,
                    )
                    live.batteryPct?.let { pct ->
                        StatePill(
                            title = "Battery ${pct.roundToInt()}%",
                            tone = batteryTone(pct),
                            showsDot = false,
                        )
                    }
                }
                Text(
                    strapStatusDetail(live.bonded, live.connected, live.scanning),
                    style = NoopType.subhead,
                    color = Palette.textSecondary,
                )
                Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                    Button(
                        onClick = { requestScan() },
                        enabled = !live.scanning,
                        colors = ButtonDefaults.buttonColors(
                            containerColor = Palette.accent,
                            contentColor = Palette.surfaceBase,
                        ),
                    ) { Text(if (live.scanning) "Searching…" else "Re-scan", style = NoopType.captionNumber) }

                    OutlinedButton(
                        onClick = { vm.disconnect() },
                        enabled = live.connected || live.bonded,
                        colors = ButtonDefaults.outlinedButtonColors(contentColor = Palette.statusCritical),
                    ) { Text("Disconnect", style = NoopType.captionNumber) }
                }

                // Keep streaming when the app is closed (Android foreground service). On Mac, NOOP
                // already keeps your strap connected from the menu bar — just close the window.
                Row(
                    modifier = Modifier.fillMaxWidth(),
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(16.dp),
                ) {
                    Column(modifier = Modifier.weight(1f)) {
                        Text(
                            "Keep connected in the background",
                            style = NoopType.subhead,
                            color = Palette.textPrimary,
                        )
                        Text(
                            "Keeps streaming from your strap with an ongoing notification, even after you close NOOP. Turn off to disconnect when the app is closed.",
                            style = NoopType.footnote,
                            color = Palette.textTertiary,
                        )
                    }
                    Switch(
                        checked = backgroundConnection,
                        onCheckedChange = {
                            backgroundConnection = it
                            vm.setBackgroundConnection(it)
                        },
                        colors = SwitchDefaults.colors(
                            checkedThumbColor = Palette.surfaceBase,
                            checkedTrackColor = Palette.accent,
                            uncheckedThumbColor = Palette.textSecondary,
                            uncheckedTrackColor = Palette.surfaceInset,
                            uncheckedBorderColor = Palette.hairline,
                        ),
                    )
                }

                // Diagnostics: "Debug logging" mirrors the strap log to logcat (adb). Default OFF — a
                // normal user never needs to write the connection log to the system log; the in-app log
                // (and the "Share strap log" export below) work regardless. Developers flip this on to
                // watch the connection live over `adb logcat -s WhoopBleClient`.
                Row(
                    modifier = Modifier.fillMaxWidth(),
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(16.dp),
                ) {
                    Column(modifier = Modifier.weight(1f)) {
                        Text(
                            "Debug logging",
                            style = NoopType.subhead,
                            color = Palette.textPrimary,
                        )
                        Text(
                            "Also write the strap log to the system log (logcat) for development over adb. Off by default — the in-app log and “Share strap log” below work either way.",
                            style = NoopType.footnote,
                            color = Palette.textTertiary,
                        )
                    }
                    Switch(
                        checked = debugLogging,
                        onCheckedChange = {
                            debugLogging = it
                            vm.setDebugLogging(it)
                        },
                        colors = SwitchDefaults.colors(
                            checkedThumbColor = Palette.surfaceBase,
                            checkedTrackColor = Palette.accent,
                            uncheckedThumbColor = Palette.textSecondary,
                            uncheckedTrackColor = Palette.surfaceInset,
                            uncheckedBorderColor = Palette.hairline,
                        ),
                        modifier = Modifier.semantics {
                            contentDescription = "Debug logging"
                        },
                    )
                }

                // Diagnostics: export the strap connection log so people can attach it to a bug report.
                OutlinedButton(
                    onClick = { LogExport.shareStrapLog(context, vm.ble.exportLogText()) },
                    modifier = Modifier.fillMaxWidth(),
                    colors = ButtonDefaults.outlinedButtonColors(contentColor = Palette.textSecondary),
                ) { Text("Share strap log (for bug reports)", style = NoopType.captionNumber) }
            }
        }

        // --- Experimental · WHOOP 5 / MG ---
        SettingsSection(
            icon = Icons.Filled.Science,
            title = "Experimental · WHOOP 5 / MG",
            blurb = "Live heart rate already works on a WHOOP 5/MG strap. These probes go further and try to coax more out of it. They are guesses, off by default, and only ever touch a 5/MG strap — WHOOP 4.0 is never affected.",
        ) {
            Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                Row(
                    modifier = Modifier.fillMaxWidth(),
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(16.dp),
                ) {
                    Text(
                        "Try WHOOP 5/MG protocol probes",
                        style = NoopType.subhead,
                        color = Palette.textPrimary,
                        modifier = Modifier.weight(1f),
                    )
                    Switch(
                        checked = puffinExperiments,
                        onCheckedChange = {
                            puffinExperiments = it
                            puffinExperiment.isEnabled = it
                        },
                        colors = SwitchDefaults.colors(
                            checkedThumbColor = Palette.surfaceBase,
                            checkedTrackColor = Palette.accent,
                            uncheckedThumbColor = Palette.textSecondary,
                            uncheckedTrackColor = Palette.surfaceInset,
                            uncheckedBorderColor = Palette.hairline,
                        ),
                        modifier = Modifier.semantics {
                            contentDescription = "Try WHOOP 5/MG protocol probes"
                        },
                    )
                }
                Text(
                    "On a 5/MG connection NOOP will send a puffin realtime-stream request after the handshake, and log what comes back. If you have a 5/MG strap, turning this on and sharing your strap log helps map the protocol. No effect on WHOOP 4.0.",
                    style = NoopType.caption,
                    color = Palette.textTertiary,
                )

                Row(
                    modifier = Modifier.fillMaxWidth(),
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(16.dp),
                ) {
                    Text(
                        "Record 5/MG raw capture (research)",
                        style = NoopType.subhead,
                        color = Palette.textPrimary,
                        modifier = Modifier.weight(1f),
                    )
                    Switch(
                        checked = puffinCapture,
                        onCheckedChange = {
                            puffinCapture = it
                            puffinExperiment.isCaptureEnabled = it
                        },
                        colors = SwitchDefaults.colors(
                            checkedThumbColor = Palette.surfaceBase,
                            checkedTrackColor = Palette.accent,
                            uncheckedThumbColor = Palette.textSecondary,
                            uncheckedTrackColor = Palette.surfaceInset,
                            uncheckedBorderColor = Palette.hairline,
                        ),
                        modifier = Modifier.semantics {
                            contentDescription = "Record 5/MG raw capture"
                        },
                    )
                }
                Text(
                    "Records the raw frames of each 5/MG history sync to a file on this phone, so you can share them and help NOOP learn to decode 5/MG sleep, recovery and strain. The file contains raw biometric frames (heart rate, R-R, skin temperature, motion) and the strap's own diagnostic text. Nothing leaves the phone unless you share it. Off by default.",
                    style = NoopType.caption,
                    color = Palette.textTertiary,
                )
                OutlinedButton(
                    onClick = { LogExport.shareWhoop5Capture(context) },
                    modifier = Modifier.fillMaxWidth(),
                    colors = ButtonDefaults.outlinedButtonColors(contentColor = Palette.textSecondary),
                ) { Text("Share 5/MG capture (for the decode effort)", style = NoopType.captionNumber) }
            }
        }

        // --- Backup & restore ---
        SettingsSection(
            icon = Icons.Filled.Storage,
            title = "Backup & restore",
            blurb = "Move all your NOOP data to another phone. Export saves everything — history, sleeps, workouts, settings — to a single file you can copy across; import replaces this phone's data with a backup.",
        ) {
            Column(verticalArrangement = Arrangement.spacedBy(16.dp)) {
                Row(
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(12.dp),
                ) {
                    Button(
                        onClick = {
                            backupBusy = true
                            exportLauncher.launch("noop-backup.noopdb")
                        },
                        enabled = !backupBusy,
                        colors = ButtonDefaults.buttonColors(
                            containerColor = Palette.accent,
                            contentColor = Palette.surfaceBase,
                        ),
                    ) { Text("Export…", style = NoopType.captionNumber) }

                    OutlinedButton(
                        onClick = {
                            backupBusy = true
                            importLauncher.launch(arrayOf("*/*"))
                        },
                        enabled = !backupBusy,
                        colors = ButtonDefaults.outlinedButtonColors(contentColor = Palette.accent),
                    ) { Text("Import…", style = NoopType.captionNumber) }

                    if (backupBusy) {
                        CircularProgressIndicator(
                            color = Palette.accent,
                            strokeWidth = 2.dp,
                            modifier = Modifier.size(18.dp),
                        )
                    }
                }

                NoteRow(
                    icon = Icons.Filled.Info,
                    iconTint = Palette.textTertiary,
                    text = "Importing overwrites everything currently on this phone. Your old data is kept in a side file just in case. NOOP needs a relaunch for an import to take effect.",
                )
            }
        }

        // --- About ---
        SettingsSection(
            icon = Icons.Filled.Info,
            title = "About",
            blurb = "NOOP — all your data, none of the cloud.",
        ) {
            Column(verticalArrangement = Arrangement.spacedBy(16.dp)) {
                Row(
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(10.dp),
                ) {
                    Text("NOOP", style = NoopType.title2, color = Palette.textPrimary)
                    StatePill("v${BuildConfig.VERSION_NAME}", tone = StrandTone.Neutral, showsDot = false)
                }

                // Check for updates — a single, user-initiated call to GitHub's public releases API
                // when the button is tapped. No background polling, no auto-update; nothing about you
                // is sent. Android already holds INTERNET (for the opt-in Coach), so this adds nothing.
                var updChecking by remember { mutableStateOf(false) }
                var updResult by remember { mutableStateOf<UpdateCheck.Result?>(null) }
                Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    Row(
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(10.dp),
                    ) {
                        OutlinedButton(
                            onClick = {
                                if (!updChecking) {
                                    updChecking = true
                                    updResult = null
                                    scope.launch {
                                        updResult = UpdateCheck.check(BuildConfig.VERSION_NAME)
                                        updChecking = false
                                    }
                                }
                            },
                            enabled = !updChecking,
                            colors = ButtonDefaults.outlinedButtonColors(contentColor = Palette.accent),
                        ) {
                            if (updChecking) {
                                CircularProgressIndicator(
                                    modifier = Modifier.size(14.dp).padding(end = 6.dp),
                                    strokeWidth = 2.dp,
                                    color = Palette.accent,
                                )
                                Text("Checking…", style = NoopType.captionNumber)
                            } else {
                                Text("Check for updates", style = NoopType.captionNumber)
                            }
                        }
                        when (val r = updResult) {
                            is UpdateCheck.Result.UpToDate ->
                                Text(
                                    "You're on the latest (${r.version}).",
                                    style = NoopType.footnote, color = Palette.textSecondary,
                                )
                            UpdateCheck.Result.Failed ->
                                Text(
                                    "Couldn't check. Try again.",
                                    style = NoopType.footnote, color = Palette.statusWarning,
                                )
                            else -> {}
                        }
                    }

                    // Update available: show what's new, with a download straight to the release.
                    (updResult as? UpdateCheck.Result.Available)?.let { avail ->
                        Column(
                            modifier = Modifier
                                .fillMaxWidth()
                                .clip(RoundedCornerShape(10.dp))
                                .background(Palette.surfaceInset)
                                .border(1.dp, Palette.accent.copy(alpha = 0.3f), RoundedCornerShape(10.dp))
                                .padding(12.dp),
                            verticalArrangement = Arrangement.spacedBy(8.dp),
                        ) {
                            Row(verticalAlignment = Alignment.CenterVertically) {
                                Text(
                                    "Version ${avail.version} is available",
                                    style = NoopType.subhead, color = Palette.textPrimary,
                                    modifier = Modifier.weight(1f),
                                )
                                Button(
                                    onClick = {
                                        context.startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(avail.url)))
                                    },
                                    colors = ButtonDefaults.buttonColors(
                                        containerColor = Palette.accent, contentColor = Palette.surfaceBase,
                                    ),
                                ) { Text("Download", style = NoopType.captionNumber) }
                            }
                            if (avail.notes.isNotEmpty()) {
                                Text(
                                    avail.notes,
                                    style = NoopType.footnote, color = Palette.textSecondary,
                                    modifier = Modifier
                                        .heightIn(max = 160.dp)
                                        .verticalScroll(rememberScrollState()),
                                )
                            }
                        }
                    }

                    Text(
                        "Checks GitHub for the latest version when you tap — nothing else is sent.",
                        style = NoopType.footnote, color = Palette.textTertiary,
                    )
                }

                Text(
                    "A standalone companion for your WHOOP. Everything stays on this phone — your history, your live stream, your numbers. Nothing is uploaded.",
                    style = NoopType.subhead,
                    color = Palette.textSecondary,
                )

                // What's new — re-open the changelog sheet any time (macOS About parity).
                Box(
                    modifier = Modifier
                        .fillMaxWidth()
                        .clip(RoundedCornerShape(10.dp))
                        .background(Palette.surfaceInset)
                        .border(1.dp, Palette.hairline, RoundedCornerShape(10.dp))
                        .clickable { showWhatsNew = true }
                        .padding(horizontal = 14.dp, vertical = 12.dp)
                        .semantics { contentDescription = "What's new in NOOP ${AppChangelog.CURRENT_VERSION}" },
                ) {
                    Row(
                        modifier = Modifier.fillMaxWidth(),
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(10.dp),
                    ) {
                        Icon(
                            Icons.Filled.Campaign,
                            contentDescription = null,
                            tint = Palette.accent,
                            modifier = Modifier.size(18.dp),
                        )
                        Column(modifier = Modifier.weight(1f)) {
                            Text("What's new", style = NoopType.headline, color = Palette.textPrimary)
                            Text(
                                "Recent changes and what to expect",
                                style = NoopType.footnote,
                                color = Palette.textSecondary,
                            )
                        }
                        Text("›", style = NoopType.title2, color = Palette.accent)
                    }
                }

                // Medical disclaimer — inset well with a warning-tinted hairline.
                Row(
                    modifier = Modifier
                        .fillMaxWidth()
                        .clip(RoundedCornerShape(10.dp))
                        .background(Palette.surfaceInset)
                        .border(1.dp, Palette.statusWarning.copy(alpha = 0.25f), RoundedCornerShape(10.dp))
                        .padding(12.dp),
                    horizontalArrangement = Arrangement.spacedBy(10.dp),
                    verticalAlignment = Alignment.Top,
                ) {
                    Icon(
                        Icons.Filled.Info,
                        contentDescription = null,
                        tint = Palette.statusWarning,
                        modifier = Modifier.size(16.dp),
                    )
                    Text(
                        "NOOP is not a medical device. It is for informational and personal-insight purposes only and is not intended to diagnose, treat, cure or prevent any condition. Talk to a clinician for medical advice.",
                        style = NoopType.footnote,
                        color = Palette.textSecondary,
                    )
                }

                RowDivider()

                Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
                    Overline("Built on")
                    AttributionRow(repo = "my-whoop", note = "WHOOP 4.0 protocol")
                    AttributionRow(repo = "goose", note = "WHOOP 5.0 protocol")
                }
                Text(
                    "Open-source BLE reverse-engineering work. Thank you.",
                    style = NoopType.footnote,
                    color = Palette.textTertiary,
                )

                RowDivider()

                // Support link — opens the project's contact email (same address the
                // Support screen lists). NOOP is anonymous, so email is the support channel.
                Box(
                    modifier = Modifier
                        .fillMaxWidth()
                        .clip(RoundedCornerShape(10.dp))
                        .background(Palette.accent.copy(alpha = 0.10f))
                        .border(1.dp, Palette.accent.copy(alpha = 0.25f), RoundedCornerShape(10.dp))
                        .clickable {
                            val intent = Intent(Intent.ACTION_SENDTO).apply {
                                data = Uri.parse("mailto:$SUPPORT_EMAIL")
                                putExtra(Intent.EXTRA_SUBJECT, "NOOP support")
                            }
                            try {
                                context.startActivity(intent)
                            } catch (_: ActivityNotFoundException) {
                                Toast.makeText(context, "Email us at $SUPPORT_EMAIL", Toast.LENGTH_LONG).show()
                            }
                        }
                        .padding(horizontal = 14.dp, vertical = 12.dp)
                        .semantics { contentDescription = "Contact support at $SUPPORT_EMAIL" },
                ) {
                    Row(
                        modifier = Modifier.fillMaxWidth(),
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        Column(modifier = Modifier.weight(1f)) {
                            Text("Support & contact", style = NoopType.headline, color = Palette.textPrimary)
                            Text(
                                "Questions, feedback, bugs — $SUPPORT_EMAIL",
                                style = NoopType.footnote,
                                color = Palette.textSecondary,
                            )
                        }
                        Text("›", style = NoopType.title2, color = Palette.accent)
                    }
                }
            }
        }

        // What's new sheet, opened from the About row above. Full-screen Dialog so it
        // covers the whole screen like the macOS .sheet; closing just hides it.
        if (showWhatsNew) {
            Dialog(
                onDismissRequest = { showWhatsNew = false },
                properties = DialogProperties(usePlatformDefaultWidth = false),
            ) {
                Surface(modifier = Modifier.fillMaxSize(), color = Palette.surfaceBase) {
                    WhatsNewSheet(onClose = { showWhatsNew = false })
                }
            }
        }
    }
}

private const val SUPPORT_EMAIL = "thenoopapp@gmail.com"

// MARK: - Strap status helpers (mirror SettingsView's computed properties)

private fun strapStatusTitle(bonded: Boolean, connected: Boolean): String = when {
    bonded && connected -> "Bonded · streaming"
    connected -> "Connected"
    bonded -> "Bonded · idle"
    else -> "Disconnected"
}

private fun strapTone(bonded: Boolean, connected: Boolean): StrandTone = when {
    connected -> StrandTone.Positive
    bonded -> StrandTone.Warning
    else -> StrandTone.Critical
}

// `internal` (not private) so the unit test in the same package can assert the scanning branch.
internal fun strapStatusDetail(bonded: Boolean, connected: Boolean, scanning: Boolean): String = when {
    scanning -> "Searching for your WHOOP… make sure it's charged, on your wrist, and the official WHOOP app isn't connected to it."
    bonded && connected -> "Your strap is paired and sending data. Open Live for a real-time heart rate."
    connected -> "Connected. Finishing the secure pairing handshake…"
    bonded -> "Previously paired but not currently connected. Re-scan to reconnect."
    else -> "No strap connected. Put your WHOOP nearby and tap Re-scan to pair."
}

private fun batteryTone(pct: Double): StrandTone = when {
    pct <= 15 -> StrandTone.Critical
    pct <= 30 -> StrandTone.Warning
    else -> StrandTone.Positive
}

// MARK: - Sex options

private data class SexOption(val tag: String, val label: String)

private val SEX_OPTIONS = listOf(
    SexOption("male", "Male"),
    SexOption("female", "Female"),
    SexOption("nonbinary", "Non-binary"),
)

// MARK: - Section card (ports SettingsView's private SettingsSection)

/** A grouped settings card: icon + title header, an explanatory blurb, then content. */
@Composable
private fun SettingsSection(
    icon: ImageVector,
    title: String,
    blurb: String,
    content: @Composable () -> Unit,
) {
    NoopCard(padding = 20.dp) {
        Column(verticalArrangement = Arrangement.spacedBy(16.dp)) {
            Row(
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(10.dp),
            ) {
                Icon(icon, contentDescription = null, tint = Palette.accent, modifier = Modifier.size(18.dp))
                Text(title, style = NoopType.headline, color = Palette.textPrimary)
            }
            Text(blurb, style = NoopType.subhead, color = Palette.textSecondary)
            content()
        }
    }
}

// MARK: - Two-column form row (ports SettingsView's private FormRow)

/** Label on the left, control on the right — the two-column form feel. */
@Composable
private fun FormRow(label: String, control: @Composable () -> Unit) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .heightIn(min = 44.dp)
            .padding(vertical = 4.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(16.dp),
    ) {
        Text(
            label,
            style = NoopType.body,
            color = Palette.textPrimary,
            modifier = Modifier.weight(1f),
        )
        control()
    }
}

// MARK: - Shared bits

@Composable
private fun RowDivider() {
    Box(
        modifier = Modifier
            .fillMaxWidth()
            .padding(vertical = 4.dp)
            .height(1.dp)
            .background(Palette.hairline),
    )
}

@Composable
private fun NoteRow(icon: ImageVector, iconTint: Color, text: String) {
    Row(
        horizontalArrangement = Arrangement.spacedBy(10.dp),
        verticalAlignment = Alignment.Top,
    ) {
        Icon(icon, contentDescription = null, tint = iconTint, modifier = Modifier.size(16.dp))
        Text(text, style = NoopType.footnote, color = Palette.textSecondary)
    }
}

@Composable
private fun AttributionRow(repo: String, note: String) {
    Row(
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(8.dp),
        modifier = Modifier.semantics { contentDescription = "$repo, $note" },
    ) {
        Text("›", style = NoopType.headline, color = Palette.accent)
        Text(repo, style = NoopType.mono(12f), color = Palette.textPrimary)
        Text("· $note", style = NoopType.footnote, color = Palette.textTertiary)
    }
}
