package com.noop.data

import android.content.Context
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.combine
import kotlin.math.roundToInt

/**
 * Decoded streams to persist in one transaction. Android mirror of the Swift `Streams`
 * struct (Packages/WhoopProtocol/Sources/WhoopProtocol/Streams.swift) carrying the rows
 * for a single flush/backfill chunk. All `ts` values are wall-clock unix seconds (Long).
 *
 * The protocol/decoder layer builds one of these (deviceId stamped at insert time, not
 * stored on the per-row sample models — it is supplied to [WhoopRepository.insert]).
 */
data class StreamBatch(
    val hr: List<HrRow> = emptyList(),
    val rr: List<RrRow> = emptyList(),
    val events: List<EventEntry> = emptyList(),
    val battery: List<BatteryRow> = emptyList(),
    val spo2: List<Spo2Row> = emptyList(),
    val skinTemp: List<SkinTempRow> = emptyList(),
    val resp: List<RespRow> = emptyList(),
    val gravity: List<GravityRow> = emptyList(),
    val steps: List<StepRow> = emptyList(),
) {
    val isEmpty: Boolean
        get() = hr.isEmpty() && rr.isEmpty() && events.isEmpty() && battery.isEmpty() &&
            spo2.isEmpty() && skinTemp.isEmpty() && resp.isEmpty() && gravity.isEmpty() &&
            steps.isEmpty()
}

// Device-agnostic decoded rows (deviceId attached when inserted). Mirror Streams.swift shapes.
data class HrRow(val ts: Long, val bpm: Int)
data class RrRow(val ts: Long, val rrMs: Int)

/** payloadJSON is the deterministic sorted-keys JSON for the remaining parsed fields. */
data class EventEntry(val ts: Long, val kind: String, val payloadJSON: String)
data class BatteryRow(val ts: Long, val soc: Double?, val mv: Int?, val charging: Boolean? = null)
data class Spo2Row(val ts: Long, val red: Int, val ir: Int)
data class SkinTempRow(val ts: Long, val raw: Int)
/** Cumulative u16 step/motion counter at [ts] (WHOOP5 step_motion_counter@57). deviceId attached on insert. (#78) */
data class StepRow(val ts: Long, val counter: Int)
data class RespRow(val ts: Long, val raw: Int)
data class GravityRow(val ts: Long, val x: Double, val y: Double, val z: Double)

/** Count of rows ACTUALLY inserted per stream (mirrors WhoopStore.insert return tuple). */
data class InsertCounts(
    val hr: Int = 0,
    val rr: Int = 0,
    val events: Int = 0,
    val battery: Int = 0,
    val spo2: Int = 0,
    val skinTemp: Int = 0,
    val steps: Int = 0,
    val resp: Int = 0,
    val gravity: Int = 0,
)

/**
 * Repository over [WhoopDatabase] / [WhoopDao]. The single seam the rest of the app uses
 * to read/write the local store. Port of WhoopStore's public surface (StreamStore.swift,
 * Reads.swift, MetricsCache.swift) — the phone does NO metric computation here; daily/sleep
 * rows are an offline cache of server-computed values.
 */
class WhoopRepository(private val dao: WhoopDao) {

    constructor(db: WhoopDatabase) : this(db.whoopDao())

    // MARK: - Device

    suspend fun upsertDevice(id: String, mac: String? = null, name: String? = null) {
        val now = System.currentTimeMillis() / 1000
        // Preserve firstSeen on update: read existing, keep its firstSeen if present.
        val existing = dao.device(id)
        dao.upsertDevice(
            DeviceRow(
                id = id,
                mac = mac,
                name = name,
                firstSeen = existing?.firstSeen ?: now,
                lastSeen = now,
            )
        )
    }

    // MARK: - Insert decoded streams (idempotent by natural key)

    /**
     * Persist one decoded batch under [deviceId]. Returns the number of rows actually inserted
     * per stream (0 for rows that already existed). Empty sub-lists compile/run nothing.
     * Port of WhoopStore.insert(_:deviceId:).
     */
    suspend fun insert(streams: StreamBatch, deviceId: String): InsertCounts {
        if (streams.isEmpty) return InsertCounts()

        val hrIds = if (streams.hr.isEmpty()) emptyList() else
            dao.insertHr(streams.hr.map { HrSample(deviceId, it.ts, it.bpm) })
        val rrIds = if (streams.rr.isEmpty()) emptyList() else
            dao.insertRr(streams.rr.map { RrInterval(deviceId, it.ts, it.rrMs) })
        val evIds = if (streams.events.isEmpty()) emptyList() else
            dao.insertEvents(streams.events.map { EventRow(deviceId, it.ts, it.kind, it.payloadJSON) })
        val batIds = if (streams.battery.isEmpty()) emptyList() else
            dao.insertBattery(streams.battery.map { BatterySample(deviceId, it.ts, it.soc, it.mv, it.charging) })
        val spo2Ids = if (streams.spo2.isEmpty()) emptyList() else
            dao.insertSpo2(streams.spo2.map { Spo2Sample(deviceId, it.ts, it.red, it.ir) })
        val skinIds = if (streams.skinTemp.isEmpty()) emptyList() else
            dao.insertSkinTemp(streams.skinTemp.map { SkinTempSample(deviceId, it.ts, it.raw) })
        val stepIds = if (streams.steps.isEmpty()) emptyList() else
            dao.insertSteps(streams.steps.map { StepSample(deviceId, it.ts, it.counter) })
        val respIds = if (streams.resp.isEmpty()) emptyList() else
            dao.insertResp(streams.resp.map { RespSample(deviceId, it.ts, it.raw) })
        val gravIds = if (streams.gravity.isEmpty()) emptyList() else
            dao.insertGravity(streams.gravity.map { GravitySample(deviceId, it.ts, it.x, it.y, it.z) })

        // OnConflictStrategy.IGNORE returns -1 for skipped (already-present) rows; count the inserts.
        return InsertCounts(
            hr = hrIds.countInserted(),
            rr = rrIds.countInserted(),
            events = evIds.countInserted(),
            battery = batIds.countInserted(),
            spo2 = spo2Ids.countInserted(),
            skinTemp = skinIds.countInserted(),
            steps = stepIds.countInserted(),
            resp = respIds.countInserted(),
            gravity = gravIds.countInserted(),
        )
    }

    // MARK: - Server-derived caches (latest value wins on conflict)

    suspend fun upsertDailyMetrics(days: List<DailyMetric>) = dao.upsertDailyMetrics(days)
    suspend fun upsertSleepSessions(sessions: List<SleepSession>) = dao.upsertSleepSessions(sessions)
    suspend fun upsertMetricSeries(rows: List<MetricSeriesRow>) = dao.upsertMetricSeries(rows)
    suspend fun upsertJournal(rows: List<JournalEntry>) = dao.upsertJournal(rows)
    suspend fun upsertWorkouts(rows: List<WorkoutRow>) = dao.upsertWorkouts(rows)
    suspend fun upsertAppleDaily(rows: List<AppleDaily>) = dao.upsertAppleDaily(rows)

    // MARK: - Reads

    suspend fun hrSamples(deviceId: String, from: Long, to: Long, limit: Int = DEFAULT_LIMIT) =
        dao.hrSamples(deviceId, from, to, limit)

    /** Downsampled HR (mean bpm per [bucketSeconds]) for the strap, for the Today 24h trend chart. */
    suspend fun hrBuckets(deviceId: String, from: Long, to: Long, bucketSeconds: Long = 300L) =
        dao.hrBuckets(deviceId, from, to, bucketSeconds)

    /**
     * DISPLAY-ONLY: fill missing workout HR from the strap's own samples (#77). An imported session
     * (Health Connect / Apple Health) stores avgHr = null, but if the strap was worn during that
     * window its ~1 Hz samples are already in Room under the strap device id — so derive avg/max
     * from them. Fills only rows whose avgHr is null (never mixes sources within a row), requires
     * [minSamples] (~1 min of data) so a few stray samples can't fabricate an average, and caps the
     * lookups so a huge history can't jank first paint. NEVER persisted — a re-import must not see
     * UI-derived values (the workout PK upsert would wipe them anyway).
     */
    suspend fun fillWorkoutHrFromStrap(
        rows: List<WorkoutRow>,
        strapDeviceId: String = "my-whoop",
        minSamples: Long = 60,
        cap: Int = 300,
    ): List<WorkoutRow> {
        var budget = cap
        return rows.map { row ->
            if (row.avgHr != null || row.endTs <= row.startTs || budget <= 0) return@map row
            budget -= 1
            val stats = dao.hrWindowStats(strapDeviceId, row.startTs, row.endTs)
            if (stats.n >= minSamples && stats.avg != null && stats.max != null) {
                row.copy(avgHr = stats.avg.roundToInt(), maxHr = row.maxHr ?: stats.max)
            } else row
        }
    }

    suspend fun rrIntervals(deviceId: String, from: Long, to: Long, limit: Int = DEFAULT_LIMIT) =
        dao.rrIntervals(deviceId, from, to, limit)

    suspend fun events(deviceId: String, from: Long, to: Long, limit: Int = DEFAULT_LIMIT) =
        dao.events(deviceId, from, to, limit)

    suspend fun batterySamples(deviceId: String, from: Long, to: Long, limit: Int = DEFAULT_LIMIT) =
        dao.batterySamples(deviceId, from, to, limit)

    suspend fun spo2Samples(deviceId: String, from: Long, to: Long, limit: Int = DEFAULT_LIMIT) =
        dao.spo2Samples(deviceId, from, to, limit)

    suspend fun skinTempSamples(deviceId: String, from: Long, to: Long, limit: Int = DEFAULT_LIMIT) =
        dao.skinTempSamples(deviceId, from, to, limit)

    suspend fun stepSamples(deviceId: String, from: Long, to: Long, limit: Int = DEFAULT_LIMIT) =
        dao.stepSamples(deviceId, from, to, limit)

    /** Delete a computed source's [sport] workouts in [from, to] (makes re-detection idempotent). (#78) */
    suspend fun deleteComputedWorkouts(deviceId: String, sport: String, from: Long, to: Long) =
        dao.deleteWorkoutsBySport(deviceId, sport, from, to)

    suspend fun respSamples(deviceId: String, from: Long, to: Long, limit: Int = DEFAULT_LIMIT) =
        dao.respSamples(deviceId, from, to, limit)

    suspend fun gravitySamples(deviceId: String, from: Long, to: Long, limit: Int = DEFAULT_LIMIT) =
        dao.gravitySamples(deviceId, from, to, limit)

    suspend fun sleepSessions(deviceId: String, from: Long, to: Long, limit: Int = DEFAULT_LIMIT) =
        dao.sleepSessions(deviceId, from, to, limit)

    suspend fun metricSeries(deviceId: String, key: String, from: String, to: String) =
        dao.metricSeries(deviceId, key, from, to)

    /** Distinct metric keys present for a [deviceId]/source, sorted ascending. */
    suspend fun metricKeys(deviceId: String): List<String> = dao.metricKeys(deviceId)

    /** Workouts whose startTs falls in [from, to] (unix seconds), oldest first, row-limited. */
    suspend fun workouts(deviceId: String, from: Long, to: Long, limit: Int = DEFAULT_LIMIT): List<WorkoutRow> =
        dao.workouts(deviceId, from, to, limit)

    /** Journal entries for the inclusive day range [from, to] (YYYY-MM-DD), oldest first. */
    suspend fun journal(deviceId: String, from: String, to: String): List<JournalEntry> =
        dao.journal(deviceId, from, to)

    /** Apple-Health daily aggregates for the inclusive day range [from, to] (YYYY-MM-DD), oldest first. */
    suspend fun appleDaily(deviceId: String, from: String, to: String): List<AppleDaily> =
        dao.appleDaily(deviceId, from, to)

    /** All cached daily metrics for a device, oldest first. Feeds com.noop.analytics.IllnessWatch. */
    suspend fun days(deviceId: String): List<DailyMetric> = dao.days(deviceId)

    /**
     * One-time #34 refile: move legacy Health Connect data out of the shared "apple-health" bucket into
     * its own "health-connect" source, so it stops being shown as Apple Health. HC workouts are tagged
     * `source = "health-connect"` so they move unconditionally; the daily aggregates only move when there
     * is no Apple Health EXPORT (no apple-health metricSeries), since only the export writes metricSeries.
     * Idempotent + safe (runs before this import writes any HC data, so no PK conflict).
     */
    suspend fun refileLegacyHealthConnect() {
        dao.reassignWorkoutsBySource(from = "apple-health", to = "health-connect", source = "health-connect")
        if (dao.metricSeriesCount("apple-health") == 0) {
            dao.reassignAppleDaily(from = "apple-health", to = "health-connect")
            upsertDevice("health-connect", name = "Health Connect")
        }
    }

    // MARK: - Merged reads (imported source wins per day; computed "-noop" gap-fills)
    //
    // Mirrors macOS Repository.mergeDaily / mergeSleep: the IntelligenceEngine persists
    // on-device scores under "<deviceId>-noop"; the dashboard should see BOTH sources so
    // a strap-only user still gets a populated dashboard, while a real WHOOP import always
    // wins on the days it covers. The screens point their "my-whoop" reads at these merged
    // variants (the least invasive correct approach — no DAO/schema change, and the per-day
    // precedence lives in one place).

    /** The computed-source id for a given imported [deviceId] (e.g. "my-whoop" → "my-whoop-noop"). */
    fun computedDeviceId(deviceId: String): String = "$deviceId-noop"

    /**
     * All cached daily metrics for [deviceId], oldest first, MERGED with the on-device
     * computed scores from "<deviceId>-noop". Imported rows win per day; computed rows
     * fill the days the import doesn't cover. Port of macOS Repository.mergeDaily.
     */
    suspend fun daysMerged(deviceId: String): List<DailyMetric> =
        mergeDaily(imported = dao.days(deviceId), computed = dao.days(computedDeviceId(deviceId)))

    /**
     * Reactive merged daily metrics (oldest first): imported [deviceId] rows win per day,
     * computed "<deviceId>-noop" rows gap-fill. Emits whenever either source changes.
     */
    fun daysMergedFlow(deviceId: String): Flow<List<DailyMetric>> =
        dao.daysFlow(deviceId).combine(dao.daysFlow(computedDeviceId(deviceId))) { imported, computed ->
            mergeDaily(imported = imported, computed = computed)
        }

    /**
     * Sleep sessions for [deviceId] in [from, to] (unix seconds) MERGED with the computed
     * "<deviceId>-noop" sessions. Imported sessions win per night-end day; computed sessions
     * gap-fill. Port of macOS Repository.mergeSleep. Sorted by startTs ascending.
     */
    suspend fun sleepSessionsMerged(
        deviceId: String,
        from: Long,
        to: Long,
        limit: Int = DEFAULT_LIMIT,
    ): List<SleepSession> = mergeSleep(
        imported = dao.sleepSessions(deviceId, from, to, limit),
        computed = dao.sleepSessions(computedDeviceId(deviceId), from, to, limit),
    )

    /** Cached daily metrics for the inclusive day range [from, to] (YYYY-MM-DD), oldest first. */
    suspend fun dailyMetrics(deviceId: String, from: String, to: String): List<DailyMetric> =
        dao.dailyMetricsRange(deviceId, from, to)

    // MARK: - Flows

    /** Reactive daily metrics (oldest first) for a device. */
    fun daysFlow(deviceId: String): Flow<List<DailyMetric>> = dao.daysFlow(deviceId)

    // MARK: - Frontier / convenience

    suspend fun latestHrSampleTs(deviceId: String): Long? = dao.latestHrSampleTs(deviceId)
    suspend fun latestHr(deviceId: String): HrSample? = dao.latestHr(deviceId)
    suspend fun latestBattery(deviceId: String): BatterySample? = dao.latestBattery(deviceId)

    companion object {
        /** Default row cap on range reads. Matches the Swift call sites' bounded scans. */
        const val DEFAULT_LIMIT = 100_000

        /** Build a repository backed by the process-wide singleton database. */
        fun from(context: Context): WhoopRepository = WhoopRepository(WhoopDatabase.get(context))

        /**
         * Imported daily rows win per day; computed rows fill the days the import doesn't
         * cover. Returns oldest→newest by day string (lexicographic = chronological for
         * YYYY-MM-DD). Port of macOS Repository.mergeDaily.
         */
        internal fun mergeDaily(
            imported: List<DailyMetric>,
            computed: List<DailyMetric>,
        ): List<DailyMetric> {
            val byDay = LinkedHashMap<String, DailyMetric>()
            for (d in computed) byDay[d.day] = d // computed first…
            // …import overwrites, so a real WHOOP import always wins — BUT coalesce the strap-only
            // on-device metrics (steps / calories / RSA resp) from the computed row, since importers
            // (esp. Health Connect) write a "my-whoop" daily row with those columns null and would
            // otherwise blank them on days the import also covers. (#78)
            for (d in imported) {
                val c = byDay[d.day]
                byDay[d.day] = if (c == null) d else d.copy(
                    steps = d.steps ?: c.steps,
                    activeKcalEst = d.activeKcalEst ?: c.activeKcalEst,
                    respRateBpm = d.respRateBpm ?: c.respRateBpm,
                )
            }
            return byDay.values.sortedBy { it.day }
        }

        /**
         * Same precedence for sleep sessions, keyed by the UTC day the night ends on.
         * Port of macOS Repository.mergeSleep (the macOS keyer used the local tz; this
         * port keys on UTC for consistency with AnalyticsEngine's UTC day attribution).
         */
        internal fun mergeSleep(
            imported: List<SleepSession>,
            computed: List<SleepSession>,
        ): List<SleepSession> {
            fun endDay(s: SleepSession): String =
                com.noop.analytics.AnalyticsEngine.dayString(s.endTs)
            val byDay = LinkedHashMap<String, SleepSession>()
            for (s in computed) byDay[endDay(s)] = s
            for (s in imported) byDay[endDay(s)] = s
            return byDay.values.sortedBy { it.startTs }
        }
    }
}

/** OnConflictStrategy.IGNORE returns the new rowid, or -1 when the row was skipped. */
private fun List<Long>.countInserted(): Int = count { it != -1L }
