package com.noop.ingest

import android.content.Context
import androidx.health.connect.client.HealthConnectClient
import androidx.health.connect.client.permission.HealthPermission
import androidx.health.connect.client.records.ActiveCaloriesBurnedRecord
import androidx.health.connect.client.records.ExerciseSessionRecord
import androidx.health.connect.client.records.HeartRateRecord
import androidx.health.connect.client.records.HeartRateVariabilityRmssdRecord
import androidx.health.connect.client.records.OxygenSaturationRecord
import androidx.health.connect.client.records.Record
import androidx.health.connect.client.records.RespiratoryRateRecord
import androidx.health.connect.client.records.RestingHeartRateRecord
import androidx.health.connect.client.records.SleepSessionRecord
import androidx.health.connect.client.records.StepsRecord
import androidx.health.connect.client.records.TotalCaloriesBurnedRecord
import androidx.health.connect.client.records.Vo2MaxRecord
import androidx.health.connect.client.records.WeightRecord
import androidx.health.connect.client.request.ReadRecordsRequest
import androidx.health.connect.client.time.TimeRangeFilter
import com.noop.data.AppleDaily
import com.noop.data.DailyMetric
import com.noop.data.ImportSummary
import com.noop.data.WhoopRepository
import com.noop.data.WorkoutRow
import java.time.Instant
import java.time.LocalDate
import java.time.ZoneId
import kotlin.math.round
import kotlin.reflect.KClass

/**
 * Native Android Health Connect importer.
 *
 * Reads a fixed set of record types out of the on-device Health Connect store via
 * `androidx.health.connect:connect-client`, aggregates them **per LOCAL calendar day**
 * (the device's default zone), and upserts them into the same Room store the WHOOP/Apple
 * importers write to (see [WhoopRepository]). All timestamps written are wall-clock UNIX
 * **seconds** (Long), matching the rest of the data layer.
 *
 * Device-id mapping (so this co-exists with real WHOOP + Apple Health data):
 *   - Daily "Apple-style" aggregates (steps / calories / VO2max / weight / avg-HR)
 *     -> [AppleDaily] under deviceId "apple-health".
 *   - WHOOP-style autonomic markers (resting-HR / HRV / sleep-minutes / SpO2 / respiration)
 *     -> [DailyMetric] under deviceId "my-whoop", BUT only for days that have NO existing
 *     "my-whoop" daily row. Real WHOOP data is richer (recovery/strain/stages), so we never
 *     clobber it — we only backfill days WHOOP doesn't already own.
 *   - Exercise sessions -> [WorkoutRow] with source "health-connect".
 *
 * Permissions are assumed to have been granted by the UI (via the Health Connect permission
 * flow) BEFORE [import] is called. If Health Connect is unavailable, or the required
 * read permissions are not in fact granted, [import] returns [ImportSummary.failure].
 */
object HealthConnectImporter {

    const val SOURCE = "Health Connect"

    private const val WHOOP = "my-whoop"
    // Health Connect data is stored under its OWN source ("health-connect"), NOT the shared
    // "apple-health" bucket — otherwise it's mis-attributed to Apple Health in the UI (issue #34).
    // (The recovery/sleep backfill still lands under "my-whoop"; only the external-health aggregates
    // + workouts carry this source.)
    private const val HC_DEVICE = "health-connect"
    private const val HC_WORKOUT_SOURCE = "health-connect"

    /** Read window: a wide ~10-year span ending now. Health Connect itself caps retention. */
    private const val WINDOW_YEARS = 10L

    /** Page size for paginated readRecords() calls. */
    private const val PAGE_SIZE = 5000

    /** The record types this importer reads, in one place so PERMISSIONS stays in sync. */
    private val READ_RECORDS: List<KClass<out Record>> = listOf(
        StepsRecord::class,
        TotalCaloriesBurnedRecord::class,
        ActiveCaloriesBurnedRecord::class,
        HeartRateRecord::class,
        RestingHeartRateRecord::class,
        HeartRateVariabilityRmssdRecord::class,
        SleepSessionRecord::class,
        OxygenSaturationRecord::class,
        RespiratoryRateRecord::class,
        Vo2MaxRecord::class,
        WeightRecord::class,
        ExerciseSessionRecord::class,
    )

    /**
     * The set of Health Connect read-permission strings the UI must request before calling
     * [import]. One `READ_*` permission per record type in [READ_RECORDS].
     */
    val PERMISSIONS: Set<String> =
        READ_RECORDS.map { HealthPermission.getReadPermission(it) }.toSet()

    /**
     * Whether Health Connect is installed/available on this device.
     * One of [HealthConnectClient.SDK_AVAILABLE],
     * [HealthConnectClient.SDK_UNAVAILABLE],
     * [HealthConnectClient.SDK_UNAVAILABLE_PROVIDER_UPDATE_REQUIRED].
     */
    fun sdkStatus(context: Context): Int = HealthConnectClient.getSdkStatus(context)

    /** The Health Connect client. Caller should gate on [sdkStatus] == SDK_AVAILABLE first. */
    fun client(context: Context): HealthConnectClient = HealthConnectClient.getOrCreate(context)

    /**
     * Read all configured record types, aggregate per local day, and upsert into [repo].
     * Assumes [PERMISSIONS] have already been granted. Returns [ImportSummary.failure] when
     * Health Connect is unavailable or the permissions are not actually granted.
     */
    suspend fun import(context: Context, repo: WhoopRepository): ImportSummary {
        if (sdkStatus(context) != HealthConnectClient.SDK_AVAILABLE) {
            return ImportSummary.failure(SOURCE, "Health Connect is not available on this device.")
        }

        // Refile any legacy Health Connect data that landed in the shared "apple-health" bucket before
        // #34 BEFORE importing, so a re-import refiles cleanly instead of duplicating across both sources.
        try { repo.refileLegacyHealthConnect() } catch (_: Exception) { /* best-effort */ }

        val client = client(context)

        // Verify the permissions really are granted (the UI may have been dismissed).
        val granted = try {
            client.permissionController.getGrantedPermissions()
        } catch (e: Exception) {
            return ImportSummary.failure(SOURCE, "Could not read Health Connect permissions: ${e.message}")
        }
        if (!granted.containsAll(PERMISSIONS)) {
            return ImportSummary.failure(SOURCE, "Health Connect permissions have not been granted.")
        }

        val zone = ZoneId.systemDefault()
        val end = Instant.now()
        val start = LocalDate.now(zone).minusYears(WINDOW_YEARS).atStartOfDay(zone).toInstant()
        val filter = TimeRangeFilter.between(start, end)

        // Per-day accumulators. Keyed by "YYYY-MM-DD" (local).
        val acc = HashMap<String, DayAcc>()
        fun dayOf(instant: Instant): String = LocalDate.ofInstant(instant, zone).toString()
        fun bucket(day: String): DayAcc = acc.getOrPut(day) { DayAcc() }

        val workouts = ArrayList<WorkoutRow>()

        try {
            // --- Steps ---
            readAll(client, StepsRecord::class, filter) { r ->
                bucket(dayOf(r.startTime)).steps += r.count
            }
            // --- Total calories burned (basal + active) ---
            readAll(client, TotalCaloriesBurnedRecord::class, filter) { r ->
                bucket(dayOf(r.startTime)).totalKcal += r.energy.inKilocalories
            }
            // --- Active calories burned ---
            readAll(client, ActiveCaloriesBurnedRecord::class, filter) { r ->
                bucket(dayOf(r.startTime)).activeKcal += r.energy.inKilocalories
            }
            // --- Heart rate (instantaneous samples) -> per-day average ---
            readAll(client, HeartRateRecord::class, filter) { r ->
                for (s in r.samples) {
                    val b = bucket(dayOf(s.time))
                    b.hrSum += s.beatsPerMinute
                    b.hrCount += 1
                }
            }
            // --- Resting heart rate -> per-day average (rounded to Int) ---
            readAll(client, RestingHeartRateRecord::class, filter) { r ->
                val b = bucket(dayOf(r.time))
                b.rhrSum += r.beatsPerMinute
                b.rhrCount += 1
            }
            // --- HRV (RMSSD, ms) -> per-day average ---
            readAll(client, HeartRateVariabilityRmssdRecord::class, filter) { r ->
                val b = bucket(dayOf(r.time))
                b.hrvSum += r.heartRateVariabilityMillis
                b.hrvCount += 1
            }
            // --- Sleep sessions -> per-day total sleep minutes, assigned to the WAKE day ---
            readAll(client, SleepSessionRecord::class, filter) { r ->
                val day = dayOf(r.endTime)
                val b = bucket(day)
                // Prefer summed asleep-stage minutes; fall back to session span when no stages.
                val asleepMin = asleepMinutes(r)
                val totalMin = if (asleepMin > 0.0) asleepMin
                else (r.endTime.epochSecond - r.startTime.epochSecond) / 60.0
                b.sleepMin += totalMin
                b.hasSleep = true
            }
            // --- SpO2 (%) -> per-day average ---
            readAll(client, OxygenSaturationRecord::class, filter) { r ->
                val b = bucket(dayOf(r.time))
                b.spo2Sum += r.percentage.value
                b.spo2Count += 1
            }
            // --- Respiratory rate (breaths/min) -> per-day average ---
            readAll(client, RespiratoryRateRecord::class, filter) { r ->
                val b = bucket(dayOf(r.time))
                b.respSum += r.rate
                b.respCount += 1
            }
            // --- VO2 max (ml/kg/min) -> latest value of the day wins ---
            readAll(client, Vo2MaxRecord::class, filter) { r ->
                val b = bucket(dayOf(r.time))
                if (r.time.epochSecond >= b.vo2maxTs) {
                    b.vo2max = r.vo2MillilitersPerMinuteKilogram
                    b.vo2maxTs = r.time.epochSecond
                }
            }
            // --- Weight (kg) -> latest value of the day wins ---
            readAll(client, WeightRecord::class, filter) { r ->
                val b = bucket(dayOf(r.time))
                if (r.time.epochSecond >= b.weightTs) {
                    b.weightKg = r.weight.inKilograms
                    b.weightTs = r.time.epochSecond
                }
            }
            // --- Exercise sessions -> WorkoutRow(source="health-connect") ---
            readAll(client, ExerciseSessionRecord::class, filter) { r ->
                val startS = r.startTime.epochSecond
                val endS = r.endTime.epochSecond
                workouts.add(
                    WorkoutRow(
                        deviceId = HC_DEVICE,
                        startTs = startS,
                        endTs = endS,
                        sport = exerciseName(r),
                        source = HC_WORKOUT_SOURCE,
                        durationS = (endS - startS).toDouble().coerceAtLeast(0.0),
                        energyKcal = null,
                        avgHr = null,
                        maxHr = null,
                        strain = null,
                        distanceM = null,
                        zonesJSON = null,
                        notes = r.title,
                    )
                )
                // Count exercises per local day on the start day for the WHOOP daily backfill.
                bucket(dayOf(r.startTime)).exerciseCount += 1
            }

            // Fill per-workout HR (#77): an ExerciseSessionRecord carries no summary HR, so avg/max
            // were stored null and every imported workout showed "–". Intersect each session's window
            // with its HeartRateRecord samples — a targeted per-session read, bounded by workout count
            // (the day-aggregate HeartRateRecord pass above streams the full range and must not be
            // buffered). readAll swallows a per-session failure, so one bad session can't fail the
            // import. ≥60 samples (~1 min) required so a few strays can't fabricate an average.
            for (i in workouts.indices) {
                val w = workouts[i]
                if (w.endTs <= w.startTs) continue
                var sum = 0L
                var n = 0L
                var max = 0L
                readAll(
                    client, HeartRateRecord::class,
                    TimeRangeFilter.between(
                        Instant.ofEpochSecond(w.startTs), Instant.ofEpochSecond(w.endTs)
                    ),
                ) { hr ->
                    for (s in hr.samples) {
                        sum += s.beatsPerMinute
                        n += 1
                        if (s.beatsPerMinute > max) max = s.beatsPerMinute
                    }
                }
                if (n >= 60) {
                    workouts[i] = w.copy(
                        avgHr = round(sum.toDouble() / n).toInt(),
                        maxHr = max.toInt(),
                    )
                }
            }
        } catch (e: Exception) {
            return ImportSummary.failure(SOURCE, "Health Connect read failed: ${e.message}")
        }

        if (acc.isEmpty() && workouts.isEmpty()) {
            return ImportSummary(
                source = SOURCE,
                counts = emptyMap(),
                message = "No Health Connect data found to import.",
            )
        }

        // Existing WHOOP-owned days: read ONCE so we never clobber richer WHOOP daily rows.
        val whoopDays: Set<String> = try {
            repo.days(WHOOP).map { it.day }.toSet()
        } catch (e: Exception) {
            emptySet()
        }

        val appleRows = ArrayList<AppleDaily>(acc.size)
        val dailyRows = ArrayList<DailyMetric>(acc.size)

        for ((day, a) in acc) {
            // AppleDaily: steps / calories / vo2max / weight / avg-HR.
            val hasApple = a.steps > 0L || a.totalKcal > 0.0 || a.activeKcal > 0.0 ||
                a.vo2max != null || a.weightKg != null || a.hrCount > 0
            if (hasApple) {
                appleRows.add(
                    AppleDaily(
                        deviceId = HC_DEVICE,
                        day = day,
                        steps = if (a.steps > 0L) a.steps.toInt() else null,
                        activeKcal = if (a.activeKcal > 0.0) round1(a.activeKcal) else null,
                        basalKcal = basalKcal(a),
                        vo2max = a.vo2max?.let { round1(it) },
                        avgHr = if (a.hrCount > 0) round(a.hrSum.toDouble() / a.hrCount).toInt() else null,
                        maxHr = null,
                        walkingHr = null,
                        weightKg = a.weightKg?.let { round2(it) },
                    )
                )
            }

            // DailyMetric (my-whoop): resting-HR / HRV / sleep-minutes / SpO2 / respiration,
            // ONLY for days WHOOP does not already own.
            if (day !in whoopDays) {
                val rhr = if (a.rhrCount > 0) round(a.rhrSum.toDouble() / a.rhrCount).toInt() else null
                val hrv = if (a.hrvCount > 0) round1(a.hrvSum / a.hrvCount) else null
                val sleep = if (a.hasSleep) round1(a.sleepMin) else null
                val spo2 = if (a.spo2Count > 0) round1(a.spo2Sum / a.spo2Count) else null
                val resp = if (a.respCount > 0) round1(a.respSum / a.respCount) else null
                val exCount = if (a.exerciseCount > 0) a.exerciseCount else null
                val hasMetric = rhr != null || hrv != null || sleep != null ||
                    spo2 != null || resp != null || exCount != null
                if (hasMetric) {
                    dailyRows.add(
                        DailyMetric(
                            deviceId = WHOOP,
                            day = day,
                            totalSleepMin = sleep,
                            restingHr = rhr,
                            avgHrv = hrv,
                            spo2Pct = spo2,
                            respRateBpm = resp,
                            exerciseCount = exCount,
                        )
                    )
                }
            }
        }

        // Persist. Register the devices we write under so name() lookups resolve.
        try {
            if (appleRows.isNotEmpty()) {
                repo.upsertDevice(HC_DEVICE, name = "Health Connect")
                repo.upsertAppleDaily(appleRows)
            }
            if (dailyRows.isNotEmpty()) {
                repo.upsertDevice(WHOOP, name = "WHOOP")
                repo.upsertDailyMetrics(dailyRows)
            }
            if (workouts.isNotEmpty()) {
                repo.upsertWorkouts(workouts)
            }
        } catch (e: Exception) {
            return ImportSummary.failure(SOURCE, "Saving Health Connect data failed: ${e.message}")
        }

        val counts = buildMap {
            if (appleRows.isNotEmpty()) put("appleDaily", appleRows.size)
            if (dailyRows.isNotEmpty()) put("dailyMetric", dailyRows.size)
            if (workouts.isNotEmpty()) put("workout", workouts.size)
        }

        // Day range across everything we touched (aggregates + workout start days).
        val touchedDays = sortedSetOf<String>().apply {
            addAll(appleRows.map { it.day })
            addAll(dailyRows.map { it.day })
            addAll(workouts.map { LocalDate.ofInstant(Instant.ofEpochSecond(it.startTs), zone).toString() })
        }
        val firstDay = touchedDays.firstOrNull()
        val lastDay = touchedDays.lastOrNull()

        val total = counts.values.sum()
        return ImportSummary(
            source = SOURCE,
            counts = counts,
            firstDay = firstDay,
            lastDay = lastDay,
            message = if (total == 0) "Nothing new to import from Health Connect."
            else "Imported $total rows from Health Connect.",
        )
    }

    // MARK: - paginated read helper

    /**
     * Read every page of [type] within [filter], invoking [onRecord] for each record.
     * Loops on the response page token so we never miss records past the first page.
     */
    private suspend fun <T : Record> readAll(
        client: HealthConnectClient,
        type: KClass<T>,
        filter: TimeRangeFilter,
        onRecord: (T) -> Unit,
    ) {
        var pageToken: String? = null
        try {
            do {
                val response = client.readRecords(
                    ReadRecordsRequest(
                        recordType = type,
                        timeRangeFilter = filter,
                        pageSize = PAGE_SIZE,
                        pageToken = pageToken,
                    )
                )
                for (record in response.records) onRecord(record)
                pageToken = response.pageToken
            } while (pageToken != null)
        } catch (e: Exception) {
            // One record type failing (e.g. a device/SDK validation quirk like "count must not be less
            // than 1" seen on some Health Connect builds) must NOT abort the whole import — log it and
            // keep whatever was read, so every other data type still comes in (issue #34). The reads
            // accumulate into shared buckets, so a partial type is simply absent, never corrupt.
            android.util.Log.w("HealthConnect", "read of ${type.simpleName} failed; skipping: ${e.message}")
        }
    }

    // MARK: - field mapping helpers

    /** Sum of asleep-stage durations (minutes). Excludes AWAKE / OUT_OF_BED / UNKNOWN. */
    private fun asleepMinutes(r: SleepSessionRecord): Double {
        if (r.stages.isEmpty()) return 0.0
        var min = 0.0
        for (stage in r.stages) {
            if (stage.stage in ASLEEP_STAGES) {
                min += (stage.endTime.epochSecond - stage.startTime.epochSecond) / 60.0
            }
        }
        return min
    }

    /** SleepSessionRecord stage ints that count as "asleep". */
    private val ASLEEP_STAGES: Set<Int> = setOf(
        SleepSessionRecord.STAGE_TYPE_LIGHT,
        SleepSessionRecord.STAGE_TYPE_DEEP,
        SleepSessionRecord.STAGE_TYPE_REM,
        SleepSessionRecord.STAGE_TYPE_SLEEPING, // generic "asleep" with no sub-stage
    )

    /** Derive basal kcal = total − active when both are present and positive; else null. */
    private fun basalKcal(a: DayAcc): Double? {
        if (a.totalKcal <= 0.0) return null
        val basal = a.totalKcal - a.activeKcal
        return if (basal > 0.0) round1(basal) else null
    }

    /**
     * A short, human sport name for a Health Connect exercise session. Uses the user's title
     * if present, else maps the EXERCISE_TYPE_* int to a readable label, else "Workout".
     */
    private fun exerciseName(r: ExerciseSessionRecord): String {
        val title = r.title?.trim()
        if (!title.isNullOrEmpty()) return title
        return EXERCISE_TYPE_NAMES[r.exerciseType] ?: "Workout"
    }

    /**
     * Map of common ExerciseSessionRecord.EXERCISE_TYPE_* constants to readable labels. We reference the
     * library constants directly rather than hardcoding ints — the old hardcoded values were WRONG (e.g.
     * 79 was mapped to "Swimming" but 79 is actually WALKING, so a walking session showed as swimming —
     * issue #53; 80 was "Swimming" but is WATER_POLO; 82 was "Walking" but is WHEELCHAIR; etc.). Using
     * the constants makes the int↔label mapping impossible to get wrong, and a renamed/removed constant
     * becomes a compile error instead of a silent mismatch. Unknown types fall back to "Workout".
     */
    private val EXERCISE_TYPE_NAMES: Map<Int, String> = mapOf(
        ExerciseSessionRecord.EXERCISE_TYPE_RUNNING to "Running",
        ExerciseSessionRecord.EXERCISE_TYPE_RUNNING_TREADMILL to "Running",
        ExerciseSessionRecord.EXERCISE_TYPE_BIKING to "Cycling",
        ExerciseSessionRecord.EXERCISE_TYPE_BIKING_STATIONARY to "Cycling",
        ExerciseSessionRecord.EXERCISE_TYPE_SWIMMING_OPEN_WATER to "Swimming",
        ExerciseSessionRecord.EXERCISE_TYPE_SWIMMING_POOL to "Swimming",
        ExerciseSessionRecord.EXERCISE_TYPE_STRENGTH_TRAINING to "Strength",
        ExerciseSessionRecord.EXERCISE_TYPE_WALKING to "Walking",
        ExerciseSessionRecord.EXERCISE_TYPE_HIKING to "Hiking",
        ExerciseSessionRecord.EXERCISE_TYPE_YOGA to "Yoga",
        ExerciseSessionRecord.EXERCISE_TYPE_ROWING to "Rowing",
        ExerciseSessionRecord.EXERCISE_TYPE_ROWING_MACHINE to "Rowing",
        ExerciseSessionRecord.EXERCISE_TYPE_HIGH_INTENSITY_INTERVAL_TRAINING to "HIIT",
        ExerciseSessionRecord.EXERCISE_TYPE_ELLIPTICAL to "Elliptical",
        ExerciseSessionRecord.EXERCISE_TYPE_PILATES to "Pilates",
        ExerciseSessionRecord.EXERCISE_TYPE_BOXING to "Boxing",
        ExerciseSessionRecord.EXERCISE_TYPE_BADMINTON to "Badminton",
        ExerciseSessionRecord.EXERCISE_TYPE_BASEBALL to "Baseball",
        ExerciseSessionRecord.EXERCISE_TYPE_BASKETBALL to "Basketball",
        ExerciseSessionRecord.EXERCISE_TYPE_SOCCER to "Soccer",
        ExerciseSessionRecord.EXERCISE_TYPE_WEIGHTLIFTING to "Weightlifting",
    )

    private fun round1(x: Double) = round(x * 10.0) / 10.0
    private fun round2(x: Double) = round(x * 100.0) / 100.0

    /** Per-local-day accumulator. */
    private class DayAcc {
        var steps: Long = 0L
        var totalKcal: Double = 0.0
        var activeKcal: Double = 0.0

        var hrSum: Long = 0L
        var hrCount: Int = 0

        var rhrSum: Long = 0L
        var rhrCount: Int = 0

        var hrvSum: Double = 0.0
        var hrvCount: Int = 0

        var sleepMin: Double = 0.0
        var hasSleep: Boolean = false

        var spo2Sum: Double = 0.0
        var spo2Count: Int = 0

        var respSum: Double = 0.0
        var respCount: Int = 0

        var vo2max: Double? = null
        var vo2maxTs: Long = Long.MIN_VALUE

        var weightKg: Double? = null
        var weightTs: Long = Long.MIN_VALUE

        var exerciseCount: Int = 0
    }
}
