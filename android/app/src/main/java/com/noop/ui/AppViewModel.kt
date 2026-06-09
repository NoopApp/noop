package com.noop.ui

import android.app.Application
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import com.noop.NoopApplication
import com.noop.analytics.IllnessWatch
import com.noop.analytics.IntelligenceEngine
import com.noop.analytics.UserProfile
import com.noop.ble.LiveState
import com.noop.ble.WhoopConnectionService
import com.noop.ble.WhoopModel
import com.noop.data.DailyMetric
import com.noop.data.WhoopRepository
import com.noop.protocol.CommandNumber
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.stateIn
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch

/**
 * The single app-wide view model. Holds the BLE client and the Room-backed
 * repository, re-publishes the BLE [LiveState], maintains a spike-filtered/smoothed
 * BPM for the big read-outs, and runs the on-device illness watch over cached
 * daily metrics. Mirrors the macOS AppModel responsibilities (LiveState bridge,
 * `bpm` smoothing, health-alert string) without any networking.
 */
class AppViewModel(app: Application) : AndroidViewModel(app) {

    /** Process-wide context for prefs + the background-connection service. */
    private val appContext = app.applicationContext

    /** The process owns the store + BLE client (see [NoopApplication]) so the connection can outlive
     *  this Activity-scoped ViewModel and keep streaming under [WhoopConnectionService]. */
    private val noopApp = app as NoopApplication

    // Offline store — process-wide, shared with the background service.
    private val repository: WhoopRepository = noopApp.repository

    // BLE client — process-owned; emits LiveState and persists decoded live + historical streams
    // into [repository] (same process-wide DB).
    val ble = noopApp.ble

    val repo: WhoopRepository get() = repository

    // Body profile (age/sex/weight/height + HR-max override) — the same SharedPreferences
    // store the Settings screen edits. Feeds the on-device scorer's HRmax/zones/calories.
    private val profileStore = ProfileStore.from(app.applicationContext)

    /** The imported strap source id (raw streams + imported history live under this). */
    private val deviceId = "my-whoop"

    /** Live connection + biometric snapshot, surfaced straight from the BLE client. */
    val live: StateFlow<LiveState> = ble.state

    /** Which strap the user is pairing — drives the scan filter in [connect]. Defaults to WHOOP 4.0. */
    private val _selectedModel = MutableStateFlow(WhoopModel.WHOOP4)
    val selectedModel: StateFlow<WhoopModel> = _selectedModel.asStateFlow()
    fun setSelectedModel(model: WhoopModel) {
        if (model == _selectedModel.value) return
        _selectedModel.value = model
        // Drop the previous strap's sticky bond/connection so the next scan targets the new family's
        // service and bonds it fresh (lets a user move between a WHOOP 4 and a 5/MG).
        ble.prepareForModelSwitch()
    }

    // MARK: - Smoothed BPM (median over a short window, mirrors AppModel.bpm)

    private val hrWindow = ArrayDeque<Int>()
    private val hrWindowSize = 5
    private val _bpm = MutableStateFlow<Int?>(null)
    /** Spike-filtered, smoothed heart rate for the hero number. Null until data arrives. */
    val bpm: StateFlow<Int?> = _bpm.asStateFlow()

    // MARK: - Illness watch banner

    private val _healthAlert = MutableStateFlow<String?>(null)
    /** Non-null when the illness watch flags an early-warning pattern. Drives the banner. */
    val healthAlert: StateFlow<String?> = _healthAlert.asStateFlow()

    // MARK: - Today's cached metrics

    private val _today = MutableStateFlow<DailyMetric?>(null)
    val today: StateFlow<DailyMetric?> = _today.asStateFlow()

    /**
     * Recent daily metrics (newest last), backing the Today grid + illness watch.
     * MERGED: imported "my-whoop" rows win per day; on-device computed "my-whoop-noop"
     * rows (from [IntelligenceEngine]) gap-fill, so recovery/strain/sleep populate from
     * the strap with no WHOOP import.
     */
    val recentDays: StateFlow<List<DailyMetric>> =
        repository.daysMergedFlow(deviceId)
            .stateIn(viewModelScope, SharingStarted.WhileSubscribed(5_000), emptyList())

    init {
        // Smooth HR from each LiveState emission.
        viewModelScope.launch {
            ble.state.collect { state ->
                state.heartRate?.let { ingestHr(it) }
            }
        }
        // Recompute the illness banner + today's row whenever cached days change.
        viewModelScope.launch {
            recentDays.collect { days ->
                // Only treat a row as "today" if its date is the phone's ACTUAL local calendar day.
                // Was days.lastOrNull() — the newest stored row regardless of date — so after importing
                // historical data the newest import (e.g. months old) showed as today's synthesis (#23).
                val todayKey = java.time.LocalDate.now().toString()   // ISO yyyy-MM-dd, local
                _today.value = days.lastOrNull { it.day == todayKey }
                _healthAlert.value = IllnessWatch.evaluate(days)
            }
        }

        // Turn the strap's offloaded raw data into dashboard scores on launch and every
        // 15 minutes, so recovery / strain / sleep populate from the strap itself with no
        // import. IntelligenceEngine computes, persists under "my-whoop-noop", and the
        // merged daysMergedFlow above republishes the freshly computed scores to the UI.
        // Mirrors macOS AppModel's launch + 15-min analyze loop.
        viewModelScope.launch {
            delay(FIRST_OFFLOAD_GRACE_MS) // give the first offload a moment
            while (isActive) {
                runCatching {
                    IntelligenceEngine.analyzeRecent(
                        repo = repository,
                        profile = currentProfile(),
                        importedDeviceId = deviceId,
                        maxHROverride = profileStore.hrMaxOverride
                            .takeIf { it > 0 }?.toDouble(),
                    )
                }
                delay(ANALYZE_INTERVAL_MS) // 15 min, matches the offload cadence
            }
        }
    }

    /** Snapshot the user's body profile from SharedPreferences as an analytics [UserProfile]. */
    private fun currentProfile(): UserProfile = UserProfile(
        weightKg = profileStore.weightKg,
        heightCm = profileStore.heightCm,
        age = profileStore.age.toDouble(),
        sex = profileStore.sex,
    )

    // MARK: - HR smoothing (median filter)

    private fun ingestHr(raw: Int) {
        if (raw <= 0) return
        hrWindow.addLast(raw)
        while (hrWindow.size > hrWindowSize) hrWindow.removeFirst()
        val sorted = hrWindow.sorted()
        _bpm.value = sorted[sorted.size / 2]
    }

    /**
     * Drop the smoothing window and blank the hero number so a resume / re-attach shows "—" until a
     * genuinely fresh sample arrives, instead of republishing the stale pre-gap median. Called on
     * Live/Health screen entry (requestRealtimeHr 0->1), NOT on keep-alive re-arm, so steady-state
     * smoothing is untouched. Mirrors AppModel.resetSmoothing and the existing disconnect() clear.
     * Fixes #46 (HR jumped to a stale ~100 on reopen, then settled as fresh low samples refilled).
     */
    private fun resetSmoothing() {
        hrWindow.clear()
        _bpm.value = null
    }

    // MARK: - Strap controls (thin pass-throughs to the BLE client)

    fun connect() {
        ble.connect(_selectedModel.value)
        // Keep the link alive when the app is closed, unless the user has opted out. Started from the
        // foreground (this is a user tap), so Android 12+'s background-start rule is satisfied.
        if (NoopPrefs.backgroundConnection(appContext)) {
            WhoopConnectionService.start(appContext)
        }
    }

    fun disconnect() {
        // User asked to disconnect: drop the foreground promotion first, then the link itself.
        WhoopConnectionService.stop(appContext)
        ble.disconnect()
        hrWindow.clear()
        _bpm.value = null
    }

    /**
     * Flip the "keep connected in the background" preference (driven by Settings). Turning it on
     * while a strap is live promotes to the foreground immediately; turning it off drops the
     * foreground service (the connection stays up until the app is actually closed).
     */
    fun setBackgroundConnection(enabled: Boolean) {
        NoopPrefs.setBackgroundConnection(appContext, enabled)
        if (enabled) {
            if (ble.state.value.connected || ble.state.value.bonded) {
                WhoopConnectionService.start(appContext)
            }
        } else {
            WhoopConnectionService.stop(appContext)
        }
    }

    /**
     * Flip "Debug logging" (driven by Settings → Strap). Persists the preference and pushes it to the
     * live BLE client so it takes effect immediately. Default OFF: the strap log stays in the in-app
     * ring buffer (and the "Share strap log" export) but is not mirrored to logcat unless the user opts
     * in — so a normal user never writes the connection log to the system log. With it on, developers
     * can watch the connection live over `adb logcat -s WhoopBleClient`.
     */
    fun setDebugLogging(enabled: Boolean) {
        NoopPrefs.setDebugLogging(appContext, enabled)
        ble.debugLogcat = enabled
    }

    /** How many screens currently want the live HR stream (Live, Health Monitor, …). The stream stays
     *  on while ANY of them is visible, so navigating between them doesn't stop it (issue #18: leaving
     *  Live sent TOGGLE_REALTIME_HR=0, leaving Health Monitor with a frozen value). */
    private var realtimeWanters = 0

    /** A screen that shows live HR appeared. Arms the realtime stream on the 0→1 transition, and
     *  blanks the stale smoothing window so a resume shows "—" until a fresh sample lands (#46).
     *  Guarded on 0→1 so a second concurrent HR screen doesn't re-clear an already-live window. */
    fun requestRealtimeHr() {
        if (realtimeWanters++ == 0) {
            resetSmoothing()
            ble.startRealtime()
        }
    }

    /** A live-HR screen went away. Stops the realtime stream only when the last one leaves. */
    fun releaseRealtimeHr() {
        realtimeWanters = (realtimeWanters - 1).coerceAtLeast(0)
        if (realtimeWanters == 0) ble.stopRealtime()
    }

    /** Refresh the battery reading. Reads the standard 0x2A19 characteristic (works on 5/MG, where the
     *  proprietary command is dropped) and also fires the legacy command on WHOOP 4. */
    fun getBattery() = ble.refreshBattery()

    // --- Smart alarm (persisted; arms the strap's firmware alarm). Port of macOS BehaviorStore +
    // AppModel.applySmartAlarm. The previous Android UI was a non-persisted mock-up (issue #51). ---
    private val _smartAlarmEnabled = MutableStateFlow(NoopPrefs.smartAlarmEnabled(appContext))
    val smartAlarmEnabled: StateFlow<Boolean> = _smartAlarmEnabled.asStateFlow()
    private val _smartAlarmMinutes = MutableStateFlow(NoopPrefs.smartAlarmMinutes(appContext))
    val smartAlarmMinutes: StateFlow<Int> = _smartAlarmMinutes.asStateFlow()

    fun setSmartAlarmEnabled(enabled: Boolean) {
        _smartAlarmEnabled.value = enabled
        NoopPrefs.setSmartAlarmEnabled(appContext, enabled)
        applySmartAlarm()
    }

    fun setSmartAlarmMinutes(minutes: Int) {
        _smartAlarmMinutes.value = minutes.coerceIn(0, 24 * 60 - 1)
        NoopPrefs.setSmartAlarmMinutes(appContext, _smartAlarmMinutes.value)
        applySmartAlarm()
    }

    /** Arm or clear the strap's firmware alarm from the current setting, computing the next occurrence
     *  of the wake time (today, or tomorrow if it's already passed). Needs the strap connected — if it
     *  isn't, `send()` logs "ignored — not connected" and arming happens next time you connect + toggle. */
    private fun applySmartAlarm() {
        if (!_smartAlarmEnabled.value) {
            ble.disableStrapAlarm()
            return
        }
        val cal = java.util.Calendar.getInstance().apply {
            set(java.util.Calendar.HOUR_OF_DAY, _smartAlarmMinutes.value / 60)
            set(java.util.Calendar.MINUTE, _smartAlarmMinutes.value % 60)
            set(java.util.Calendar.SECOND, 0)
            set(java.util.Calendar.MILLISECOND, 0)
        }
        if (cal.timeInMillis <= System.currentTimeMillis()) cal.add(java.util.Calendar.DAY_OF_YEAR, 1)
        ble.armStrapAlarm(cal.timeInMillis / 1000)
    }

    /** Fire a haptic buzz on the strap (requires a bonded connection). */
    fun buzz(loops: Int = 2) = ble.buzz(loops)

    override fun onCleared() {
        super.onCleared()
        // The BLE client is process-owned (NoopApplication) and may be held up by
        // WhoopConnectionService, so we never shut it down here. Only drop the connection when the
        // user hasn't opted into background streaming — otherwise closing the UI would defeat the
        // foreground service. (We deliberately do NOT call ble.shutdown(): the client outlives the
        // ViewModel and is reused by the next Activity.)
        if (!NoopPrefs.backgroundConnection(appContext)) {
            ble.disconnect()
        }
    }

    private companion object {
        /** Grace before the first scoring pass, letting the first BLE offload land. */
        const val FIRST_OFFLOAD_GRACE_MS = 6_000L
        /** On-device scoring cadence — 15 min, matching the strap offload cadence. */
        const val ANALYZE_INTERVAL_MS = 15 * 60 * 1_000L
    }
}
