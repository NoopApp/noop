package com.noop.ui

import android.app.Application
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import com.noop.NoopApplication
import com.noop.alarm.SmartAlarmScheduler
import com.noop.alarm.SmartAlarmStore
import com.noop.alarm.WindDownScheduler
import com.noop.alarm.WindDownStore
import com.noop.analytics.IllnessWatch
import com.noop.analytics.IntelligenceEngine
import com.noop.analytics.RouteMath
import com.noop.analytics.Sport
import com.noop.analytics.Calories
import com.noop.analytics.StrainScorer
import com.noop.analytics.UserProfile
import com.noop.analytics.WorkoutSport
import com.noop.location.GpsSession
import kotlinx.coroutines.Job
import com.noop.ble.LiveState
import com.noop.ble.WhoopConnectionService
import com.noop.ble.WhoopModel
import androidx.health.connect.client.HealthConnectClient
import com.noop.data.DailyMetric
import com.noop.data.HrSample
import com.noop.data.WhoopRepository
import com.noop.data.WorkoutRow
import com.noop.ingest.HealthConnectImporter
import com.noop.ingest.HealthConnectWriter
import com.noop.ingest.LiftingImporter
import com.noop.notif.IllnessAlertNotifier
import com.noop.protocol.CommandNumber
import com.noop.widget.WidgetSnapshot
import com.noop.widget.WidgetSnapshotStore
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.stateIn
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlin.math.roundToInt

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
        // Switching straps: forget the saved one so launch auto-reconnect (#67) doesn't target the old strap.
        NoopPrefs.clearLastDevice(appContext)
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

    // Declared BEFORE the init block on purpose: the recentDays collector launched from init
    // runs synchronously on Main.immediate and reads this on its very first (cached) emission —
    // a declaration after init would still be null there (JVM initializes fields in declaration
    // order) and crash the constructor. Opt-OUT, default ON (Android has always run the watch);
    // port of macOS behavior.illnessWatch, which is opt-in.
    private val _illnessWatchEnabled = MutableStateFlow(NoopPrefs.illnessWatch(appContext))
    /** Whether the illness early-warning runs (banner + notification). */
    val illnessWatchEnabled: StateFlow<Boolean> = _illnessWatchEnabled.asStateFlow()

    // Declared BEFORE the init block for the SAME reason as _illnessWatchEnabled above: the bond
    // collector launched from init runs synchronously on Main.immediate and reads _smartAlarmEnabled on
    // its first (cached) emission. A declaration after init is null there and NPEs the constructor on a
    // cold start where the strap is already bonded — the #84 "crashes once, fine on the retry" race on
    // fast devices (S24+). Port of macOS BehaviorStore (Swift two-phase init makes this safe for free).
    private val _smartAlarmEnabled = MutableStateFlow(NoopPrefs.smartAlarmEnabled(appContext))
    val smartAlarmEnabled: StateFlow<Boolean> = _smartAlarmEnabled.asStateFlow()
    private val _smartAlarmMinutes = MutableStateFlow(NoopPrefs.smartAlarmMinutes(appContext))
    val smartAlarmMinutes: StateFlow<Int> = _smartAlarmMinutes.asStateFlow()

    // PHONE smart alarm (#207) — distinct from the strap-firmware buzz alarm above. The state lives in
    // its own [SmartAlarmStore]; the GUARANTEED wake is an exact OS alarm via [SmartAlarmScheduler],
    // independent of Bluetooth, sleep detection, or this process being alive. The overnight watcher
    // (WhoopConnectionService) may only move it EARLIER within the window.
    private val phoneAlarmStore = SmartAlarmStore.from(appContext)
    private val _phoneAlarmEnabled = MutableStateFlow(phoneAlarmStore.enabled)
    /** Whether the phone smart alarm is armed (a guaranteed OS alarm is scheduled). */
    val phoneAlarmEnabled: StateFlow<Boolean> = _phoneAlarmEnabled.asStateFlow()
    private val _phoneAlarmTargetMinutes = MutableStateFlow(phoneAlarmStore.targetMinutes)
    /** Earliest acceptable wake time, minutes since midnight. */
    val phoneAlarmTargetMinutes: StateFlow<Int> = _phoneAlarmTargetMinutes.asStateFlow()
    private val _phoneAlarmWindowMinutes = MutableStateFlow(phoneAlarmStore.windowMinutes)
    /** How long after the target the guaranteed hard deadline sits. */
    val phoneAlarmWindowMinutes: StateFlow<Int> = _phoneAlarmWindowMinutes.asStateFlow()

    // Wind-down nudge (#207) — cross-platform, NON-safety-critical. A gentle evening notification
    // derived from the user's earliest wake time. Inexact daily alarm; no exact-alarm permission.
    private val windDownStore = WindDownStore.from(appContext)
    private val _windDownEnabled = MutableStateFlow(windDownStore.enabled)
    /** Whether the evening wind-down nudge is scheduled. */
    val windDownEnabled: StateFlow<Boolean> = _windDownEnabled.asStateFlow()

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
        // Smooth HR from each LiveState emission, and re-arm the strap's firmware alarm whenever it
        // (re)bonds. A smart-alarm time changed while the strap was away never reached it — the send
        // is gated on bond — so the strap kept the OLD time and fired at it (#59). Gated on enabled so
        // a disabled alarm doesn't disarm on every reconnect.
        viewModelScope.launch {
            var lastBonded = false
            ble.state.collect { state ->
                state.heartRate?.let { ingestHr(it) }
                if (state.bonded && !lastBonded) {
                    if (_smartAlarmEnabled.value) applySmartAlarm()
                    // Remember this strap so we can reconnect to it directly on the next launch (#67),
                    // e.g. after an APK update restarts the process.
                    ble.lastDeviceAddress?.let { NoopPrefs.setLastDevice(appContext, it, _selectedModel.value) }
                }
                lastBonded = state.bonded
            }
        }
        // Recompute the illness banner + today's row whenever cached days change.
        viewModelScope.launch {
            recentDays.collect { days ->
                // Only treat a row as "today" if its date is the phone's ACTUAL local calendar day.
                // Was days.lastOrNull() — the newest stored row regardless of date — so after importing
                // historical data the newest import (e.g. months old) showed as today's synthesis (#23).
                // Resolve via the LOGICAL day (rolls at 04:00 local), so between midnight and 4am we keep
                // showing the prior logical day's row instead of an empty new-calendar-day row (#144).
                // Presentation-only: stored row keys are untouched.
                val todayKey = logicalDayKeyNow()   // ISO yyyy-MM-dd, local logical day
                _today.value = days.lastOrNull { it.day == todayKey }
                val previousAlert = _healthAlert.value
                _healthAlert.value =
                    if (_illnessWatchEnabled.value) IllnessWatch.evaluate(days) else null
                // Banner transition (clear → raised) → real system notification; the notifier's
                // persisted day gate dedupes against the background-service call site.
                if (previousAlert == null) {
                    _healthAlert.value?.let { IllnessAlertNotifier.onEvaluated(appContext, it) }
                }
                // Keep the home-screen widget fresh while the app is open — covers users who turned
                // the background service off (the service is the widget's heartbeat otherwise).
                // Throttled + no-op without a placed widget; never let a Glance hiccup kill the collector.
                runCatching {
                    val live = ble.state.value
                    WidgetSnapshotStore.push(
                        appContext,
                        WidgetSnapshot(
                            recoveryPct = _today.value?.recovery?.roundToInt(),
                            heartRate = live.heartRate,
                            batteryPct = live.batteryPct?.roundToInt(),
                            connected = live.connected,
                            updatedAtMs = System.currentTimeMillis(),
                        ),
                    )
                }
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
                    // analyzeRecent now hops to Dispatchers.Default; a scope cancellation surfaces as a
                    // CancellationException that runCatching would otherwise swallow, breaking the loop's
                    // own cancellation — rethrow it so onCleared() actually stops the loop. (#125)
                }.onFailure { if (it is kotlin.coroutines.cancellation.CancellationException) throw it }
                // Opt-in writeback: push the freshly computed nights into Health Connect so other
                // apps see them. Idempotent (clientRecordId per metric+day), so re-running every
                // cycle just upserts. Never let an HC hiccup (perm revoked mid-flight, provider
                // update) break the analysis loop.
                if (_hcWriteback.value) {
                    runCatching { HealthConnectWriter.write(appContext, repository) }
                }
                delay(ANALYZE_INTERVAL_MS) // 15 min, matches the offload cadence
            }
        }

        // Apply the persisted "Continuous HRV capture" intent so the BLE client holds the dense realtime
        // stream armed once bonded (the reconciler arms it post-bond). Only effective with background
        // connection on — without it there's nothing keeping the link up to stream over, so a continuous
        // want would be meaningless. Pushed BEFORE autoReconnectOnLaunch so a launch reconnect arms it.
        ble.setKeepStreamForData(continuousHrvEffective())

        // Reconnect to the strap we last bonded to, so the user doesn't have to tap Connect after an
        // app update / restart (#67). Self-gates on the keep-connected pref + a saved strap + permission.
        autoReconnectOnLaunch()
    }

    /** The effective continuous-HRV want: the user's "Continuous HRV capture" preference AND
     *  "Keep connected in the background" — the latter is what holds the link up for the stream to ride,
     *  so continuous capture is meaningless without it. */
    private fun continuousHrvEffective(): Boolean =
        NoopPrefs.continuousHrv(appContext) && NoopPrefs.backgroundConnection(appContext)

    /**
     * On launch, reconnect DIRECTLY to the strap we last bonded to (no scan), so the connection
     * survives an app update / restart without the user tapping Connect (#67). Gated on "Keep
     * connected in the background" (the user's keep-it-on intent) and a previously-bonded strap; the
     * BLE client itself no-ops if already connected or the runtime permission isn't granted yet.
     */
    private fun autoReconnectOnLaunch() {
        val saved = NoopPrefs.lastDevice(appContext) ?: return
        // Restore the model selection whenever a strap is remembered — deliberately NOT gated on the
        // background-connection pref, so an opted-out 5/MG user's picker and scan family still
        // survive restarts. Only the reconnect itself respects the pref. (#78 fork)
        _selectedModel.value = saved.second
        if (!NoopPrefs.backgroundConnection(appContext)) return
        // APK updates tear down the old foreground service along with the old process. Re-promote it
        // on the first launch after update/restart before reconnecting, so the persistent notification
        // and long-lived connection both come back without the user toggling the setting again.
        WhoopConnectionService.start(appContext)
        ble.reconnectToAddress(saved.first, saved.second)
    }

    /** Snapshot the user's body profile from SharedPreferences as an analytics [UserProfile]. */
    private fun currentProfile(): UserProfile = UserProfile(
        weightKg = profileStore.weightKg,
        heightCm = profileStore.heightCm,
        age = profileStore.age.toDouble(),
        sex = profileStore.sex,
        stepTicksPerStep = profileStore.stepTicksPerStep,
    )

    // MARK: - HR smoothing (median filter)

    private fun ingestHr(raw: Int) {
        if (raw <= 0) return
        hrWindow.addLast(raw)
        while (hrWindow.size > hrWindowSize) hrWindow.removeFirst()
        val sorted = hrWindow.sorted()
        _bpm.value = sorted[sorted.size / 2]
        captureWorkoutSample(_bpm.value!!)
    }

    // MARK: - Manual workout tracking
    //
    // Lets a user start/stop a workout themselves rather than relying on auto-detection (a top request).
    // Holds the start time + the live HR collected since; on End the window is scored via StrainScorer
    // and saved as a WorkoutRow (source "manual"), which then shows in the Workouts screen. The day's
    // strain already counts this HR (same live stream the store persists), so it's a per-session
    // annotation, not a double-count. Mirrors macOS AppModel.

    /** A manual workout in progress. [samples] accumulate from the smoothed live bpm; [liveStrain] is
     *  recomputed as the window grows so the active card shows strain building in real time. */
    data class ActiveWorkout(
        val startMs: Long,
        val sport: Sport,
        val gpsEnabled: Boolean,
        val samples: List<HrSample> = emptyList(),
        val track: List<RouteMath.LatLng> = emptyList(),
        val distanceM: Double = 0.0,
        val paceSecPerKm: Double? = null,
        val liveStrain: Double = 0.0,
        val avgHr: Int = 0,
        val peakHr: Int = 0,
    )

    private val _activeWorkout = MutableStateFlow<ActiveWorkout?>(null)
    val activeWorkout: StateFlow<ActiveWorkout?> = _activeWorkout.asStateFlow()
    private val _lastWorkout = MutableStateFlow<WorkoutRow?>(null)
    val lastWorkout: StateFlow<WorkoutRow?> = _lastWorkout.asStateFlow()

    /** Mirrors the process-level [GpsSession] route into [_activeWorkout] for live display. The route
     *  itself is collected by [WhoopConnectionService], not here, so it survives the screen turning off
     *  (#215) — this observer just republishes it to the UI while the ViewModel is alive. */
    private var gpsJob: Job? = null

    /** Begin a workout for [sport]; start GPS route tracking when [gpsEnabled]. Single buzz confirms. */
    fun startWorkout(sport: Sport = WorkoutSport.default, gpsEnabled: Boolean = false) {
        if (_activeWorkout.value != null) return
        _lastWorkout.value = null
        val startMs = System.currentTimeMillis()
        _activeWorkout.value = ActiveWorkout(startMs = startMs, sport = sport, gpsEnabled = gpsEnabled)
        buzz(1)
        if (gpsEnabled) {
            // Hand the route to the process-level session and make sure the foreground service is up to
            // collect it — even if the user hasn't opted into background connection, the route must keep
            // tracking with the screen off (#215). Then mirror the shared route back into the UI state.
            GpsSession.start(startMs, sport.name)
            WhoopConnectionService.start(appContext)
            observeGpsSession()
        }
    }

    /** Mirror the process-level [GpsSession] route into [_activeWorkout] while the ViewModel is alive.
     *  Re-attachable: also used by [rehydrateActiveGpsWorkout] after a VM/process restart. */
    private fun observeGpsSession() {
        gpsJob?.cancel()
        gpsJob = viewModelScope.launch {
            GpsSession.state.collect { s ->
                val w = _activeWorkout.value ?: return@collect
                _activeWorkout.value = w.copy(track = s.track, distanceM = s.distanceM, paceSecPerKm = s.paceSecPerKm)
            }
        }
    }

    /**
     * If a GPS workout is still tracking in the background (process kept alive by the foreground
     * service) but this ViewModel was recreated, rebuild the active-workout card from [GpsSession] so
     * reopening the app doesn't hide an in-flight ride. HR samples that elapsed while the UI was gone
     * aren't recoverable here (they stream live), but the route — the thing #215 was about — is intact.
     */
    private fun rehydrateActiveGpsWorkout() {
        val s = GpsSession.state.value
        if (!s.active || _activeWorkout.value != null) return
        val sport = WorkoutSport.all.firstOrNull { it.name == s.sportName } ?: WorkoutSport.default
        _activeWorkout.value = ActiveWorkout(
            startMs = s.startMs, sport = sport, gpsEnabled = true,
            track = s.track, distanceM = s.distanceM, paceSecPerKm = s.paceSecPerKm,
        )
        observeGpsSession()
    }

    /** Finish the active workout: score the captured HR window + finalize the GPS route, save a
     *  WorkoutRow, and (opt-in) write it to Health Connect. A session with no HR AND no track is
     *  discarded quietly. Double-buzz confirms the save. */
    fun endWorkout() {
        val w = _activeWorkout.value ?: return
        _activeWorkout.value = null
        gpsJob?.cancel(); gpsJob = null
        // The process-level session is authoritative for the route: it kept accumulating even if this
        // ViewModel was cleared mid-ride (screen off), so [w.track] may be stale. Stop it and take its
        // final track. A non-GPS workout has nothing in the session, so fall back to the local track. (#215)
        val track = if (w.gpsEnabled) GpsSession.stop() else w.track
        val distanceM = if (w.gpsEnabled) RouteMath.totalMeters(track) else w.distanceM
        // If we promoted the foreground service ONLY to keep GPS tracking alive (the user hasn't opted
        // into the background connection), drop it now the route is finished — otherwise a lingering
        // "Connected" notification would outlive the workout. With background-connection on, leave it
        // up. Done here (before the discard early-return) so an empty GPS session tears down too. (#215)
        if (w.gpsEnabled && !NoopPrefs.backgroundConnection(appContext)) {
            WhoopConnectionService.stop(appContext)
        }
        val samples = w.samples
        if (samples.size < 2 && track.size < 2) { _lastWorkout.value = null; return }
        val endMs = System.currentTimeMillis()
        val avg = if (samples.isNotEmpty()) samples.sumOf { it.bpm } / samples.size else null
        val peak = if (samples.isNotEmpty()) samples.maxOf { it.bpm } else null
        val strain = if (samples.size >= 2)
            StrainScorer.strain(samples, maxHR = profileStore.hrMax.toDouble(), sex = profileStore.sex) else null
        // Estimate calories from the captured HR window (same Keytel/Harris–Benedict model the
        // auto-detector uses) so a manual session shows energy too, not just duration/strain. (#117)
        val energyKcal = if (samples.size >= 2)
            Calories.estimateBoutCalories(samples, currentProfile(), profileStore.hrMax.toDouble(), null)
                .first.takeIf { it > 0 }
        else null
        val row = WorkoutRow(
            deviceId = deviceId, startTs = w.startMs / 1000, endTs = endMs / 1000,
            sport = w.sport.name, source = "manual", durationS = (endMs - w.startMs) / 1000.0,
            energyKcal = energyKcal,
            avgHr = avg, maxHr = peak, strain = strain,
            distanceM = distanceM.takeIf { it > 0 },
            routePolyline = if (track.size >= 2) RouteMath.encode(track) else null,
        )
        _lastWorkout.value = row
        buzz(2)
        viewModelScope.launch {
            runCatching { repository.upsertWorkouts(listOf(row)) }
            if (_hcWriteback.value) {
                runCatching { HealthConnectWriter.writeExercise(appContext, row, w.sport.exerciseType) }
            }
        }
    }

    /** Append the current smoothed bpm to the active workout and recompute its running strain. Called
     *  from ingestHr on every fresh sample; a no-op when no workout is running. */
    private fun captureWorkoutSample(bpm: Int) {
        // `_activeWorkout` (declared further down) can still be null HERE: the HR collector in the first
        // init block can fire ingestHr -> captureWorkoutSample INLINE during construction (a StateFlow
        // replays its current value to a new collector), before this field's initializer has run — the
        // JVM field-init footgun. The safe-call tolerates that one-shot race; once constructed it is
        // never null. (Fixes the NPE in @maddognik's ADB: captureWorkoutSample -> getValue on null.)
        @Suppress("UNNECESSARY_SAFE_CALL")
        val w = _activeWorkout?.value ?: return
        val s = w.samples + HrSample(deviceId = deviceId, ts = System.currentTimeMillis() / 1000, bpm = bpm)
        val strain = StrainScorer.strain(s, maxHR = profileStore.hrMax.toDouble(), sex = profileStore.sex) ?: 0.0
        _activeWorkout.value = w.copy(
            samples = s, avgHr = s.sumOf { it.bpm } / s.size, peakHr = s.maxOf { it.bpm }, liveStrain = strain,
        )
    }

    // MARK: - Workouts screen (load + manual edit · relabel · dismiss · delete) (#107)
    //
    // The screen observes [workouts]; every mutation re-loads it so the list reflects the new state
    // immediately. Loads ALL sources — strap (imported + manual), Apple Health / Health Connect, and
    // the on-device DETECTED bouts under "<deviceId>-noop" — then filters out dismissed detected bouts
    // so a duplicate the auto-detector created is visible but removable. Mirrors macOS
    // Repository.workoutRows.

    private val _workouts = MutableStateFlow<List<WorkoutRow>>(emptyList())
    /** All workouts for the Workouts screen (newest first), dismissed detected bouts removed. */
    val workouts: StateFlow<List<WorkoutRow>> = _workouts.asStateFlow()

    /** Persist a bed/wake-time edit for one sleep session (delete-then-upsert at the new window).
     *  Swallows failures — the Sleep screen already applied the change optimistically. */
    suspend fun updateSleepSessionTimes(session: com.noop.data.SleepSession, newStartTs: Long, newEndTs: Long) {
        runCatching { repository.updateSleepSessionTimes(session, newStartTs, newEndTs) }
    }

    /** Delete one sleep session. Swallows failures — the Sleep screen already removed it
     *  optimistically, so the day recomputes without the misread night either way. (#281) */
    suspend fun deleteSleepSession(session: com.noop.data.SleepSession) {
        runCatching { repository.deleteSleepSession(session) }
    }

    /** Re-read every source + the dismissed markers and republish [workouts]. */
    fun loadWorkouts() {
        viewModelScope.launch {
            val now = System.currentTimeMillis() / 1000
            val whoop = repository.workouts(deviceId, 0L, now)
            val apple = repository.workouts("apple-health", 0L, now) +
                repository.workouts("health-connect", 0L, now)
            val detected = repository.workouts(repository.computedDeviceId(deviceId), 0L, now)
            // Imported lifting sessions (Hevy / Liftosaur) carry a volume-load note but no HR — they're
            // a strength-volume estimate, not cardio. Kept OUT of the strap HR-fill below so we never
            // fabricate a heart rate the lift never measured.
            val lifting = repository.workouts(LiftingImporter.SOURCE_ID, 0L, now)
            val markers = repository.dismissedDetected(deviceId)
            // Fill imported sessions' missing HR from strap samples (#77), same as before; detected /
            // manual rows already carry their own HR so they pass through unchanged.
            val filled = repository.fillWorkoutHrFromStrap((whoop + apple + detected))
            _workouts.value = WorkoutEditing
                .filterDismissed(filled + lifting, markers)
                .sortedByDescending { it.startTs }
        }
    }

    /** Save a retroactive / edited manual workout, then reload. [replacing] is the original on edit. */
    fun saveManualWorkout(row: WorkoutRow, replacing: WorkoutRow? = null) {
        viewModelScope.launch {
            runCatching { repository.saveManualWorkout(row, replacing) }
            loadWorkouts()
        }
    }

    /** Re-label a detected bout to [sport] (becomes a durable manual session), then reload. */
    fun relabelDetected(row: WorkoutRow, sport: String) {
        viewModelScope.launch {
            runCatching { repository.relabelDetected(row, sport) }
            loadWorkouts()
        }
    }

    /** Dismiss a detected bout ("not a workout") durably, then reload. */
    fun dismissDetected(row: WorkoutRow) {
        viewModelScope.launch {
            runCatching { repository.dismissDetected(row) }
            loadWorkouts()
        }
    }

    /** Delete one workout (manual delete, or durable dismiss for a detected bout), then reload. */
    fun deleteWorkout(row: WorkoutRow) {
        viewModelScope.launch {
            runCatching { repository.deleteWorkout(row) }
            loadWorkouts()
        }
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

    fun connect(promoteService: Boolean = true) {
        ble.connect(_selectedModel.value)
        // Keep the link alive when the app is closed, unless the user has opted out. Started from the
        // foreground (this is a user tap), so Android 12+'s background-start rule is satisfied.
        // Onboarding auto-connects before the user has finished setup and passes promoteService=false
        // so the persistent notification doesn't appear mid-flow; it promotes once on completion.
        if (promoteService && NoopPrefs.backgroundConnection(appContext)) {
            WhoopConnectionService.start(appContext)
        }
    }

    /** Promote the background service now if a strap is live and the user hasn't opted out — used by
     *  onboarding to defer the foreground notification until the flow completes. */
    fun promoteBackgroundConnectionIfActive() {
        if (!NoopPrefs.backgroundConnection(appContext)) return
        if (ble.state.value.connected || ble.state.value.bonded) {
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
        // Continuous HRV capture is gated on background connection (it has nothing to stream over without
        // it), so a change here re-reconciles the keep-stream want: turning background off disarms the
        // continuous stream when no Live screen wants it; turning it back on re-arms it if the pref is on.
        ble.setKeepStreamForData(continuousHrvEffective())
    }

    /**
     * Flip "Continuous HRV capture" (driven by Settings → Strap). Persists the preference and pushes the
     * effective want to the BLE client so it takes effect immediately: turning it on while bonded +
     * backgrounded arms the dense realtime stream now; turning it off disarms it unless a Live screen
     * still wants it (the reconciler only sends the toggle on the false↔true edge). Gated on background
     * connection — it does nothing while that's off (there'd be no background link to stream over).
     */
    fun setContinuousHrv(enabled: Boolean) {
        NoopPrefs.setContinuousHrv(appContext, enabled)
        ble.setKeepStreamForData(continuousHrvEffective())
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

    // --- Health Connect periodic auto-sync (Samsung Health → Health Connect → NOOP) ---
    private val _hcAutoSync = MutableStateFlow(NoopPrefs.hcAutoSync(appContext))
    val hcAutoSync: StateFlow<Boolean> = _hcAutoSync.asStateFlow()
    private val _hcSyncHours = MutableStateFlow(NoopPrefs.hcSyncHours(appContext))
    val hcSyncHours: StateFlow<Int> = _hcSyncHours.asStateFlow()
    private val _hcLastSync = MutableStateFlow(NoopPrefs.hcLastSync(appContext))
    val hcLastSync: StateFlow<Long> = _hcLastSync.asStateFlow()
    private val _hcWriteback = MutableStateFlow(NoopPrefs.hcWriteback(appContext))
    val hcWriteback: StateFlow<Boolean> = _hcWriteback.asStateFlow()

    init {
        // On app open, catch up the Health Connect sync if it's overdue. This on-open import is the
        // ONLY auto-sync path: we deliberately skip a true-background worker — it needs a sensitive
        // background-health permission and is unreliable on Android 14+, and opening the app regularly
        // is enough for a personal health app.
        syncHealthConnectIfStale()

        // If a GPS workout is still tracking in the background (the screen was off and this VM was
        // recreated on reopen), rebuild its active-workout card from the process-level session. Placed
        // in THIS init — not the first one above — because it reads _activeWorkout, which is declared
        // below the first init block and would still be null there (JVM field init order). (#215)
        rehydrateActiveGpsWorkout()
    }

    /** Flip auto-sync. Persists and, on enable, kicks an immediate import; thereafter it catches up on
     *  app open via [syncHealthConnectIfStale]. */
    fun setHcAutoSync(enabled: Boolean) {
        _hcAutoSync.value = enabled
        NoopPrefs.setHcAutoSync(appContext, enabled)
        if (enabled) syncHealthConnectIfStale(force = true)
    }

    /** Change the sync interval (hours). Takes effect on the next on-open catch-up sync. */
    fun setHcSyncHours(hours: Int) {
        _hcSyncHours.value = hours
        NoopPrefs.setHcSyncHours(appContext, hours)
    }

    /** Flip Health Connect writeback (computed metrics → HC). Persists; the UI requests the write
     *  permissions and kicks the first write via [writebackHealthConnectNow]. While on, every 15-min
     *  recompute re-writes (idempotent — clientRecordId upserts). Default OFF. */
    fun setHcWriteback(enabled: Boolean) {
        _hcWriteback.value = enabled
        NoopPrefs.setHcWriteback(appContext, enabled)
    }

    /** One immediate writeback (permissions assumed granted — the UI gates on that). */
    fun writebackHealthConnectNow() {
        viewModelScope.launch {
            withContext(Dispatchers.IO) {
                runCatching { HealthConnectWriter.write(appContext, repository) }
            }
        }
    }

    /**
     * Foreground catch-up import: when auto-sync is on and the last sync is older than the chosen
     * interval (or [force]), pull from Health Connect now. Health Connect background reads are
     * restricted, so opening the app is the guaranteed sync point. No-ops silently if Health Connect
     * is unavailable or its read permissions aren't granted (the UI requests them when enabling).
     */
    fun syncHealthConnectIfStale(force: Boolean = false) {
        if (!_hcAutoSync.value) return
        val intervalMs = _hcSyncHours.value.toLong() * 60 * 60 * 1000
        val last = _hcLastSync.value
        val now = System.currentTimeMillis()
        if (!force && last != 0L && now - last < intervalMs) return
        viewModelScope.launch {
            val ran = withContext(Dispatchers.IO) {
                if (HealthConnectImporter.sdkStatus(appContext) != HealthConnectClient.SDK_AVAILABLE) {
                    return@withContext false
                }
                val granted = runCatching {
                    HealthConnectImporter.client(appContext).permissionController.getGrantedPermissions()
                }.getOrDefault(emptySet())
                // Partial permissions are fine (#150): auto-import as long as at least one type is granted.
                if (granted.none { it in HealthConnectImporter.PERMISSIONS }) return@withContext false
                runCatching { HealthConnectImporter.import(appContext, repository) }.isSuccess
            }
            if (ran) {
                val t = System.currentTimeMillis()
                NoopPrefs.setHcLastSync(appContext, t)
                _hcLastSync.value = t
            }
        }
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

    /**
     * User-initiated "Sync now": kick a historical offload on demand (#93). A thin pass-through to the
     * BLE client's gated [WhoopBleClient.syncNow], which forwards to the same connected+bonded+
     * not-already-backfilling guard the auto-kick and 900s periodic timer use — so it's a safe no-op
     * when the strap isn't ready or a session is already running. Progress is unknowable from the
     * protocol, so the UI shows an indeterminate indicator + live.syncChunksThisSession, never a percent. */
    fun syncNow() = ble.syncNow()

    // --- Smart alarm (persisted; arms the strap's firmware alarm). Port of macOS BehaviorStore +
    // AppModel.applySmartAlarm. The previous Android UI was a non-persisted mock-up (issue #51).
    // NOTE: the _smartAlarm* state fields are declared ABOVE the init block (next to _illnessWatchEnabled)
    // so the init bond-collector can't read them before they're initialized (#84). ---

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

    // --- PHONE smart alarm (#207). The setters persist + (re)arm the GUARANTEED OS alarm via
    // [SmartAlarmScheduler]: scheduling the hard deadline FIRST, before any smart logic exists, so the
    // fallback is in place the instant the alarm is enabled. Whether the strap is connected is
    // irrelevant — that's the whole point. The exact-alarm permission is requested by the UI before
    // these are called on a fresh enable; if it's somehow missing, arm() returns null and the UI shows
    // the permission prompt. ---

    /** Enable/disable the phone smart alarm. Enabling arms the guaranteed hard-deadline alarm now;
     *  disabling cancels it. Returns false if exact alarms aren't permitted (the UI then routes the
     *  user to grant the permission and re-tries). */
    fun setPhoneAlarmEnabled(enabled: Boolean): Boolean {
        if (enabled && !SmartAlarmScheduler.canScheduleExact(appContext)) return false
        phoneAlarmStore.enabled = enabled
        _phoneAlarmEnabled.value = enabled
        if (enabled) SmartAlarmScheduler.arm(appContext, phoneAlarmStore)
        else SmartAlarmScheduler.cancel(appContext, phoneAlarmStore)
        return true
    }

    /** Change the earliest wake time (minutes since midnight). Re-arms while enabled so the new
     *  window takes effect immediately. */
    fun setPhoneAlarmTargetMinutes(minutes: Int) {
        phoneAlarmStore.targetMinutes = minutes
        _phoneAlarmTargetMinutes.value = phoneAlarmStore.targetMinutes
        if (phoneAlarmStore.enabled) SmartAlarmScheduler.arm(appContext, phoneAlarmStore)
        // The wind-down nudge is derived from the wake time, so keep it in step.
        if (windDownStore.enabled) WindDownScheduler.schedule(appContext, windDownStore, phoneAlarmStore.targetMinutes)
    }

    /** Change the window length (minutes after the target the hard deadline sits). Re-arms while
     *  enabled. */
    fun setPhoneAlarmWindowMinutes(minutes: Int) {
        phoneAlarmStore.windowMinutes = minutes
        _phoneAlarmWindowMinutes.value = phoneAlarmStore.windowMinutes
        if (phoneAlarmStore.enabled) SmartAlarmScheduler.arm(appContext, phoneAlarmStore)
    }

    /** Whether the OS will honour an exact alarm right now (API 31+ gates it behind a permission). */
    fun canScheduleExactAlarms(): Boolean = SmartAlarmScheduler.canScheduleExact(appContext)

    /** Enable/disable the evening wind-down nudge. Schedules the daily inexact reminder from the
     *  current earliest wake time, or cancels it. */
    fun setWindDownEnabled(enabled: Boolean) {
        windDownStore.enabled = enabled
        _windDownEnabled.value = enabled
        if (enabled) WindDownScheduler.schedule(appContext, windDownStore, phoneAlarmStore.targetMinutes)
        else WindDownScheduler.cancel(appContext)
    }

    // --- Illness watch (opt-out; the evaluation itself is the pure IllnessWatch.evaluate).
    // State lives next to _healthAlert above (declaration-order constraint); setter here with
    // the other settings mutators. ---
    fun setIllnessWatchEnabled(enabled: Boolean) {
        _illnessWatchEnabled.value = enabled
        NoopPrefs.setIllnessWatch(appContext, enabled)
        // Recompute now — the recentDays collector only fires on data changes.
        _healthAlert.value = if (enabled) IllnessWatch.evaluate(recentDays.value) else null
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
