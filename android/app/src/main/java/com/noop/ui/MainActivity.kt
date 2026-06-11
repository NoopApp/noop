package com.noop.ui

import android.Manifest
import android.content.Context
import android.content.Intent
import android.content.SharedPreferences
import android.os.Build
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.material3.Surface
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import androidx.core.view.WindowCompat
import androidx.lifecycle.lifecycleScope
import androidx.lifecycle.viewmodel.compose.viewModel
import com.noop.BuildConfig
import com.noop.ble.WhoopModel
import com.noop.data.DemoSeeder
import com.noop.data.WhoopRepository
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch

/**
 * Single-activity host. Requests the runtime BLE permissions the strap connection
 * needs, then renders the Compose tree under [NoopTheme]. The design system is
 * dark-only, so we draw edge-to-edge over the near-black [Palette.surfaceBase].
 */
class MainActivity : ComponentActivity() {

    private val permissionLauncher =
        registerForActivityResult(ActivityResultContracts.RequestMultiplePermissions()) {
            // Permission results flow back into the BLE client's own runtime checks;
            // the UI simply reflects connection state. No blocking here.
        }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        WindowCompat.setDecorFitsSystemWindows(window, false)

        // Demo build only: preload a full synthetic dataset so every screen is populated
        // out of the box (no strap, no import). No-op once seeded; never runs on the full app.
        if (BuildConfig.ENABLE_DEMO) {
            lifecycleScope.launch(Dispatchers.IO) {
                runCatching { DemoSeeder.seedIfEmpty(WhoopRepository.from(applicationContext)) }
            }
        }

        // Only pre-warm permissions at launch for already-onboarded users. First-run onboarding
        // requests each permission at the step that explains it — Bluetooth when the Connect step
        // appears, notifications when it enables the background keep-alive — so the OS prompt never
        // lands before the screen that justifies it.
        if (NoopPrefs.of(this).getBoolean(NoopPrefs.KEY_ONBOARDED, false)) {
            requestBlePermissions()
        }

        setContent {
            NoopTheme {
                NoopRoot()
            }
        }
    }

    /** Request the BLE permissions appropriate to the running OS version. */
    private fun requestBlePermissions() {
        val needed = buildList {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                // Android 12+: granular Bluetooth permissions.
                add(Manifest.permission.BLUETOOTH_SCAN)
                add(Manifest.permission.BLUETOOTH_CONNECT)
            } else {
                // Pre-12: location is required for BLE scanning.
                add(Manifest.permission.ACCESS_FINE_LOCATION)
            }
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                add(Manifest.permission.POST_NOTIFICATIONS)
            }
        }.toTypedArray()

        if (needed.isNotEmpty()) permissionLauncher.launch(needed)
    }
}

internal fun appLaunchIntent(context: Context): Intent =
    context.packageManager.getLaunchIntentForPackage(context.packageName)
        ?.apply {
            addFlags(
                Intent.FLAG_ACTIVITY_NEW_TASK or
                    Intent.FLAG_ACTIVITY_SINGLE_TOP or
                    Intent.FLAG_ACTIVITY_CLEAR_TOP,
            )
        }
        ?: Intent(context, MainActivity::class.java).apply {
            action = Intent.ACTION_MAIN
            addCategory(Intent.CATEGORY_LAUNCHER)
            addFlags(
                Intent.FLAG_ACTIVITY_NEW_TASK or
                    Intent.FLAG_ACTIVITY_SINGLE_TOP or
                    Intent.FLAG_ACTIVITY_CLEAR_TOP,
            )
        }

// MARK: - First-run / changelog gating (mirrors macOS ContentView.swift)
//
// Two persisted flags decide what the user sees on launch, exactly like the macOS
// ZStack-over-RootView:
//   • "noop.onboarded"               (Boolean, default false)
//   • "noop.lastSeenChangelogVersion" (String,  default "")
//
// Gate:
//   !onboarded                              → OnboardingScreen. On finish, mark onboarded
//                                             AND set lastSeen = CURRENT_VERSION, so a brand-new
//                                             user who just read the expectations doesn't ALSO
//                                             get the changelog popped at them.
//   onboarded && lastSeen != CURRENT_VERSION → existing user who updated: show WhatsNewSheet once,
//                                             over the live AppRoot, until they dismiss it.
//
// SharedPreferences isn't reactive, so each value is read once into a remembered
// mutableState and writes go through .edit().apply() + a state update to recompose.

/** Shared accessor for the onboarding / changelog flags (the macOS @AppStorage equivalent). */
object NoopPrefs {
    const val NAME = "noop_prefs"
    const val KEY_ONBOARDED = "noop.onboarded"
    const val KEY_LAST_SEEN_CHANGELOG = "noop.lastSeenChangelogVersion"
    /** Terms-of-use version the user last accepted. Empty until the first-run gate is accepted; a
     *  material terms change bumps [Terms.CURRENT_VERSION] and re-prompts. Mirrors macOS @AppStorage. */
    const val KEY_ACCEPTED_TERMS_VERSION = "noop.acceptedTermsVersion"

    /** "Keep connected in the background" — drives [com.noop.ble.WhoopConnectionService]. Default on. */
    const val KEY_BACKGROUND_CONNECTION = "noop.backgroundConnection"

    /** "Debug logging" — when on, the strap log is also written to logcat (`adb`). Default OFF so a
     *  normal user never emits the connection log to the system log; the in-app ring buffer (and the
     *  "Share strap log" export) work regardless. See [com.noop.ble.WhoopBleClient.debugLogcat]. */
    const val KEY_DEBUG_LOGGING = "noop.debugLogging"

    fun of(context: Context): SharedPreferences =
        context.getSharedPreferences(NAME, Context.MODE_PRIVATE)

    /** Whether NOOP should hold the strap connection open via a foreground service. Default true. */
    fun backgroundConnection(context: Context): Boolean =
        of(context).getBoolean(KEY_BACKGROUND_CONNECTION, true)

    fun setBackgroundConnection(context: Context, enabled: Boolean) {
        of(context).edit().putBoolean(KEY_BACKGROUND_CONNECTION, enabled).apply()
    }

    /** Whether the strap log is mirrored to logcat. Default false (normal users don't log to adb). */
    fun debugLogging(context: Context): Boolean =
        of(context).getBoolean(KEY_DEBUG_LOGGING, false)

    fun setDebugLogging(context: Context, enabled: Boolean) {
        of(context).edit().putBoolean(KEY_DEBUG_LOGGING, enabled).apply()
    }

    /** Imperial/Metric display preference (D#103). Display-only — stored data stays SI. The length/mass
     *  system is read by [UnitPrefs.system]; the temperature override (empty = "match the system") by
     *  [UnitPrefs.temperature]. Mirrors macOS @AppStorage("units.system" / "units.temperature"). */
    const val KEY_UNIT_SYSTEM = "units.system"
    const val KEY_TEMPERATURE_UNIT = "units.temperature"

    fun setUnitSystem(context: Context, system: UnitSystem) {
        of(context).edit().putString(KEY_UNIT_SYSTEM, system.raw).apply()
    }

    /** Persist the temperature override, or pass null to clear it back to "match the system". */
    fun setTemperatureUnit(context: Context, unit: TemperatureUnit?) {
        of(context).edit().apply {
            if (unit == null) remove(KEY_TEMPERATURE_UNIT) else putString(KEY_TEMPERATURE_UNIT, unit.raw)
        }.apply()
    }

    /** Health Connect periodic auto-sync (Samsung Health → Health Connect → NOOP). Default OFF.
     *  Interval in hours (default 12). Last successful sync as epoch millis (0 = never). */
    const val KEY_HC_AUTO_SYNC = "noop.hcAutoSync"
    const val KEY_HC_SYNC_HOURS = "noop.hcSyncHours"
    const val KEY_HC_LAST_SYNC = "noop.hcLastSync"

    fun hcAutoSync(context: Context): Boolean =
        of(context).getBoolean(KEY_HC_AUTO_SYNC, false)

    fun setHcAutoSync(context: Context, enabled: Boolean) {
        of(context).edit().putBoolean(KEY_HC_AUTO_SYNC, enabled).apply()
    }

    fun hcSyncHours(context: Context): Int =
        of(context).getInt(KEY_HC_SYNC_HOURS, 12)

    fun setHcSyncHours(context: Context, hours: Int) {
        of(context).edit().putInt(KEY_HC_SYNC_HOURS, hours).apply()
    }

    fun hcLastSync(context: Context): Long =
        of(context).getLong(KEY_HC_LAST_SYNC, 0L)

    fun setHcLastSync(context: Context, epochMs: Long) {
        of(context).edit().putLong(KEY_HC_LAST_SYNC, epochMs).apply()
    }

    /** Health Connect writeback (NOOP's computed metrics → HC, for other apps). Default OFF. */
    const val KEY_HC_WRITEBACK = "noop.hcWriteback"

    fun hcWriteback(context: Context): Boolean =
        of(context).getBoolean(KEY_HC_WRITEBACK, false)

    fun setHcWriteback(context: Context, enabled: Boolean) {
        of(context).edit().putBoolean(KEY_HC_WRITEBACK, enabled).apply()
    }

    /** Smart alarm: arm the strap's firmware alarm to buzz at a wake time. Default off; default time 07:00. */
    const val KEY_SMART_ALARM = "noop.smartAlarmEnabled"
    const val KEY_SMART_ALARM_MINUTES = "noop.smartAlarmMinutes"

    fun smartAlarmEnabled(context: Context): Boolean =
        of(context).getBoolean(KEY_SMART_ALARM, false)

    fun setSmartAlarmEnabled(context: Context, enabled: Boolean) {
        of(context).edit().putBoolean(KEY_SMART_ALARM, enabled).apply()
    }

    /** Wake time as minutes since midnight (default 420 = 07:00). */
    fun smartAlarmMinutes(context: Context): Int =
        of(context).getInt(KEY_SMART_ALARM_MINUTES, 7 * 60)

    fun setSmartAlarmMinutes(context: Context, minutes: Int) {
        of(context).edit().putInt(KEY_SMART_ALARM_MINUTES, minutes).apply()
    }

    /** Illness early-warning (banner + notification). Default ON — the watch has always run on
     *  Android, so this is an opt-OUT; macOS is opt-in (behavior.illnessWatch, default off). */
    const val KEY_ILLNESS_WATCH = "noop.illnessWatch"

    fun illnessWatch(context: Context): Boolean =
        of(context).getBoolean(KEY_ILLNESS_WATCH, true)

    fun setIllnessWatch(context: Context, enabled: Boolean) {
        of(context).edit().putBoolean(KEY_ILLNESS_WATCH, enabled).apply()
    }

    /** Last local day (ISO yyyy-MM-dd) an illness notification was posted — the once-a-day gate,
     *  persisted so the app-open and background-service call sites can't double-post. */
    const val KEY_ILLNESS_LAST_NOTIFIED_DAY = "noop.illnessLastNotifiedDay"

    fun illnessLastNotifiedDay(context: Context): String? =
        of(context).getString(KEY_ILLNESS_LAST_NOTIFIED_DAY, null)

    fun setIllnessLastNotifiedDay(context: Context, day: String) {
        of(context).edit().putString(KEY_ILLNESS_LAST_NOTIFIED_DAY, day).apply()
    }

    /** The last strap we bonded to (address + model), persisted so NOOP can reconnect to it directly on
     *  the next launch — e.g. after an APK update restarts the process (#67). On-device only; never sent. */
    const val KEY_LAST_DEVICE_ADDR = "noop.lastDeviceAddress"
    const val KEY_LAST_DEVICE_MODEL = "noop.lastDeviceModel"

    fun setLastDevice(context: Context, address: String, model: WhoopModel) {
        of(context).edit()
            .putString(KEY_LAST_DEVICE_ADDR, address)
            .putString(KEY_LAST_DEVICE_MODEL, model.name)
            .apply()
    }

    /** The saved strap as (address, model), or null if none has bonded yet. */
    fun lastDevice(context: Context): Pair<String, WhoopModel>? {
        val addr = of(context).getString(KEY_LAST_DEVICE_ADDR, null) ?: return null
        val model = of(context).getString(KEY_LAST_DEVICE_MODEL, null)
            ?.let { name -> runCatching { WhoopModel.valueOf(name) }.getOrNull() }
            ?: WhoopModel.WHOOP4
        return addr to model
    }

    fun clearLastDevice(context: Context) {
        of(context).edit().remove(KEY_LAST_DEVICE_ADDR).remove(KEY_LAST_DEVICE_MODEL).apply()
    }
}

/**
 * Root gate around [AppRoot]. Reads the two prefs once, then renders onboarding,
 * the changelog sheet, or just the app shell, updating both the store and local
 * state on each transition.
 */
@Composable
fun NoopRoot() {
    val context = LocalContext.current
    val prefs = remember { NoopPrefs.of(context) }
    val appViewModel: AppViewModel = viewModel()

    var onboarded by remember {
        mutableStateOf(prefs.getBoolean(NoopPrefs.KEY_ONBOARDED, false))
    }
    var lastSeenChangelog by remember {
        mutableStateOf(prefs.getString(NoopPrefs.KEY_LAST_SEEN_CHANGELOG, "") ?: "")
    }

    // Terms acknowledgment gate — over EVERYTHING (before onboarding/pairing/Bluetooth) until the
    // current terms version is accepted; re-appears if the terms materially change. (clickwrap)
    var acceptedTerms by remember {
        mutableStateOf(prefs.getString(NoopPrefs.KEY_ACCEPTED_TERMS_VERSION, "") ?: "")
    }
    if (acceptedTerms != Terms.CURRENT_VERSION) {
        TermsGateScreen(onAccept = {
            prefs.edit().putString(NoopPrefs.KEY_ACCEPTED_TERMS_VERSION, Terms.CURRENT_VERSION).apply()
            acceptedTerms = Terms.CURRENT_VERSION
        })
        return
    }

    if (!onboarded) {
        OnboardingScreen(
            viewModel = appViewModel,
            onFinished = {
                // A brand-new user just saw the expectations in onboarding — don't also pop the
                // changelog at them; mark them current (mirrors macOS ContentView onFinished).
                prefs.edit()
                    .putBoolean(NoopPrefs.KEY_ONBOARDED, true)
                    .putString(NoopPrefs.KEY_LAST_SEEN_CHANGELOG, AppChangelog.CURRENT_VERSION)
                    .apply()
                lastSeenChangelog = AppChangelog.CURRENT_VERSION
                onboarded = true
            },
        )
        return
    }

    // Existing, onboarded user: render the app, and if they've updated since last launch
    // (stored version behind current), show "What's New" once over the top.
    AppRoot(viewModel = appViewModel)

    if (lastSeenChangelog != AppChangelog.CURRENT_VERSION) {
        Dialog(
            onDismissRequest = {
                prefs.edit()
                    .putString(NoopPrefs.KEY_LAST_SEEN_CHANGELOG, AppChangelog.CURRENT_VERSION)
                    .apply()
                lastSeenChangelog = AppChangelog.CURRENT_VERSION
            },
            properties = DialogProperties(usePlatformDefaultWidth = false),
        ) {
            Surface(modifier = Modifier.fillMaxSize(), color = Palette.surfaceBase) {
                WhatsNewSheet(
                    onClose = {
                        prefs.edit()
                            .putString(NoopPrefs.KEY_LAST_SEEN_CHANGELOG, AppChangelog.CURRENT_VERSION)
                            .apply()
                        lastSeenChangelog = AppChangelog.CURRENT_VERSION
                    },
                )
            }
        }
    }
}
