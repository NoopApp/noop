package com.noop.data

import androidx.room.Dao
import androidx.room.Insert
import androidx.room.OnConflictStrategy
import androidx.room.Query
import androidx.room.Upsert
import kotlinx.coroutines.flow.Flow

/**
 * Data-access for the local store. Mirrors the GRDB reads/writes in WhoopStore
 * (StreamStore.swift, Reads.swift, MetricsCache.swift).
 *
 * Stream inserts use OnConflictStrategy.IGNORE == Swift `ON CONFLICT(...) DO NOTHING`
 * (idempotent by natural key — re-inserting an existing row is a no-op).
 *
 * Server-derived caches (dailyMetric, sleepSession, metricSeries) use @Upsert so the
 * latest server value wins on conflict, matching the `ON CONFLICT ... DO UPDATE SET ...`
 * upserts in MetricsCache.swift.
 *
 * Range reads are ORDER BY ts ASC (R-R and events add a secondary key matching Reads.swift),
 * and bound by [from, to] inclusive with a row limit.
 */
@Dao
interface WhoopDao {

    // MARK: - Device

    @Insert(onConflict = OnConflictStrategy.REPLACE)
    suspend fun upsertDevice(device: DeviceRow)

    @Query("SELECT * FROM device WHERE id = :id")
    suspend fun device(id: String): DeviceRow?

    // MARK: - Stream inserts (idempotent by natural key)

    @Insert(onConflict = OnConflictStrategy.IGNORE)
    suspend fun insertHr(rows: List<HrSample>): List<Long>

    @Insert(onConflict = OnConflictStrategy.IGNORE)
    suspend fun insertRr(rows: List<RrInterval>): List<Long>

    @Insert(onConflict = OnConflictStrategy.IGNORE)
    suspend fun insertEvents(rows: List<EventRow>): List<Long>

    @Insert(onConflict = OnConflictStrategy.IGNORE)
    suspend fun insertBattery(rows: List<BatterySample>): List<Long>

    @Insert(onConflict = OnConflictStrategy.IGNORE)
    suspend fun insertSpo2(rows: List<Spo2Sample>): List<Long>

    @Insert(onConflict = OnConflictStrategy.IGNORE)
    suspend fun insertSkinTemp(rows: List<SkinTempSample>): List<Long>

    @Insert(onConflict = OnConflictStrategy.IGNORE)
    suspend fun insertResp(rows: List<RespSample>): List<Long>

    @Insert(onConflict = OnConflictStrategy.IGNORE)
    suspend fun insertGravity(rows: List<GravitySample>): List<Long>

    // MARK: - Server-derived caches (latest value wins)

    @Upsert
    suspend fun upsertDailyMetrics(rows: List<DailyMetric>)

    @Upsert
    suspend fun upsertSleepSessions(rows: List<SleepSession>)

    @Upsert
    suspend fun upsertMetricSeries(rows: List<MetricSeriesRow>)

    @Upsert
    suspend fun upsertJournal(rows: List<JournalEntry>)

    @Upsert
    suspend fun upsertWorkouts(rows: List<WorkoutRow>)

    @Upsert
    suspend fun upsertAppleDaily(rows: List<AppleDaily>)

    // MARK: - Range reads (ORDER BY ts ASC, inclusive [from, to], limited)

    @Query(
        "SELECT * FROM hrSample WHERE deviceId = :deviceId AND ts >= :from AND ts <= :to " +
            "ORDER BY ts ASC LIMIT :limit"
    )
    suspend fun hrSamples(deviceId: String, from: Long, to: Long, limit: Int): List<HrSample>

    @Query(
        "SELECT * FROM rrInterval WHERE deviceId = :deviceId AND ts >= :from AND ts <= :to " +
            "ORDER BY ts ASC, rrMs ASC LIMIT :limit"
    )
    suspend fun rrIntervals(deviceId: String, from: Long, to: Long, limit: Int): List<RrInterval>

    @Query(
        "SELECT * FROM event WHERE deviceId = :deviceId AND ts >= :from AND ts <= :to " +
            "ORDER BY ts ASC, kind ASC LIMIT :limit"
    )
    suspend fun events(deviceId: String, from: Long, to: Long, limit: Int): List<EventRow>

    @Query(
        "SELECT * FROM battery WHERE deviceId = :deviceId AND ts >= :from AND ts <= :to " +
            "ORDER BY ts ASC LIMIT :limit"
    )
    suspend fun batterySamples(deviceId: String, from: Long, to: Long, limit: Int): List<BatterySample>

    @Query(
        "SELECT * FROM spo2Sample WHERE deviceId = :deviceId AND ts >= :from AND ts <= :to " +
            "ORDER BY ts ASC LIMIT :limit"
    )
    suspend fun spo2Samples(deviceId: String, from: Long, to: Long, limit: Int): List<Spo2Sample>

    @Query(
        "SELECT * FROM skinTempSample WHERE deviceId = :deviceId AND ts >= :from AND ts <= :to " +
            "ORDER BY ts ASC LIMIT :limit"
    )
    suspend fun skinTempSamples(deviceId: String, from: Long, to: Long, limit: Int): List<SkinTempSample>

    @Query(
        "SELECT * FROM respSample WHERE deviceId = :deviceId AND ts >= :from AND ts <= :to " +
            "ORDER BY ts ASC LIMIT :limit"
    )
    suspend fun respSamples(deviceId: String, from: Long, to: Long, limit: Int): List<RespSample>

    @Query(
        "SELECT * FROM gravitySample WHERE deviceId = :deviceId AND ts >= :from AND ts <= :to " +
            "ORDER BY ts ASC LIMIT :limit"
    )
    suspend fun gravitySamples(deviceId: String, from: Long, to: Long, limit: Int): List<GravitySample>

    // MARK: - Daily metrics / sleep reads (mirror MetricsCache.swift)

    /**
     * Cached daily metrics for days in [from, to] (lexicographic YYYY-MM-DD compare), oldest first.
     * Port of MetricsCache.swift dailyMetrics(deviceId:from:to:).
     */
    @Query(
        "SELECT * FROM dailyMetric WHERE deviceId = :deviceId AND day >= :from AND day <= :to " +
            "ORDER BY day ASC"
    )
    suspend fun dailyMetricsRange(deviceId: String, from: String, to: String): List<DailyMetric>

    /** All cached daily metrics for a device, oldest first. Convenience for analytics windows. */
    @Query("SELECT * FROM dailyMetric WHERE deviceId = :deviceId ORDER BY day ASC")
    suspend fun days(deviceId: String): List<DailyMetric>

    /** Reactive stream of all daily metrics for a device, oldest first. */
    @Query("SELECT * FROM dailyMetric WHERE deviceId = :deviceId ORDER BY day ASC")
    fun daysFlow(deviceId: String): Flow<List<DailyMetric>>

    @Query(
        "SELECT * FROM sleepSession WHERE deviceId = :deviceId AND startTs >= :from AND startTs <= :to " +
            "ORDER BY startTs ASC LIMIT :limit"
    )
    suspend fun sleepSessions(deviceId: String, from: Long, to: Long, limit: Int): List<SleepSession>

    // MARK: - Generic metric series (Swift metricSeries, v9)

    @Query(
        "SELECT * FROM metricSeries WHERE deviceId = :deviceId AND key = :key AND day >= :from AND day <= :to " +
            "ORDER BY day ASC"
    )
    suspend fun metricSeries(
        deviceId: String,
        key: String,
        from: String,
        to: String,
    ): List<MetricSeriesRow>

    /** Distinct metric keys present for a device, sorted ascending (Swift metricKeys, v9). */
    @Query("SELECT DISTINCT key FROM metricSeries WHERE deviceId = :deviceId ORDER BY key ASC")
    suspend fun metricKeys(deviceId: String): List<String>

    // MARK: - One-time #34 refile: separate legacy Health Connect data from the Apple Health bucket.
    // Only an Apple Health EXPORT writes metricSeries, so metricSeries-count==0 means the apple-health
    // daily rows are Health-Connect-origin and safe to move. HC workouts are tagged source so they move
    // unconditionally. Safe on first run: no `to` rows exist yet (no PK conflict), and post-#34 nothing
    // ever writes HC data to apple-health again, so it's idempotent (re-runs match 0 rows).
    @Query("SELECT COUNT(*) FROM metricSeries WHERE deviceId = :deviceId")
    suspend fun metricSeriesCount(deviceId: String): Int

    @Query("UPDATE appleDaily SET deviceId = :to WHERE deviceId = :from")
    suspend fun reassignAppleDaily(from: String, to: String)

    @Query("UPDATE workout SET deviceId = :to WHERE deviceId = :from AND source = :source")
    suspend fun reassignWorkoutsBySource(from: String, to: String, source: String)

    // MARK: - Journal / workouts / Apple-Health reads (mirror JournalWorkoutAppleCache.swift, v8)

    /**
     * Journal entries for days in [from, to] (lexicographic YYYY-MM-DD compare), oldest day first
     * then by question. Port of JournalWorkoutAppleCache.swift journalEntries(deviceId:from:to:).
     */
    @Query(
        "SELECT * FROM journal WHERE deviceId = :deviceId AND day >= :from AND day <= :to " +
            "ORDER BY day ASC, question ASC"
    )
    suspend fun journal(deviceId: String, from: String, to: String): List<JournalEntry>

    /**
     * Workouts whose startTs falls in [from, to] (unix seconds), oldest first, row-limited.
     * Port of JournalWorkoutAppleCache.swift workouts(deviceId:from:to:limit:).
     */
    @Query(
        "SELECT * FROM workout WHERE deviceId = :deviceId AND startTs >= :from AND startTs <= :to " +
            "ORDER BY startTs ASC LIMIT :limit"
    )
    suspend fun workouts(deviceId: String, from: Long, to: Long, limit: Int): List<WorkoutRow>

    /**
     * Apple-Health daily aggregates for days in [from, to] (lexicographic compare), oldest first.
     * Port of JournalWorkoutAppleCache.swift appleDaily(deviceId:from:to:).
     */
    @Query(
        "SELECT * FROM appleDaily WHERE deviceId = :deviceId AND day >= :from AND day <= :to " +
            "ORDER BY day ASC"
    )
    suspend fun appleDaily(deviceId: String, from: String, to: String): List<AppleDaily>

    // MARK: - Frontier / stats (Reads.swift)

    /** Max HR sample ts for a device, or null if none — the biometric data frontier. */
    @Query("SELECT MAX(ts) FROM hrSample WHERE deviceId = :deviceId")
    suspend fun latestHrSampleTs(deviceId: String): Long?

    @Query("SELECT COUNT(*) FROM hrSample") suspend fun countHr(): Int
    @Query("SELECT COUNT(*) FROM rrInterval") suspend fun countRr(): Int
    @Query("SELECT COUNT(*) FROM event") suspend fun countEvents(): Int
    @Query("SELECT COUNT(*) FROM battery") suspend fun countBattery(): Int
    @Query("SELECT COUNT(*) FROM spo2Sample") suspend fun countSpo2(): Int
    @Query("SELECT COUNT(*) FROM skinTempSample") suspend fun countSkinTemp(): Int
    @Query("SELECT COUNT(*) FROM respSample") suspend fun countResp(): Int
    @Query("SELECT COUNT(*) FROM gravitySample") suspend fun countGravity(): Int

    // MARK: - Live convenience reads

    /** Latest HR sample for a device (most recent ts), or null. */
    @Query("SELECT * FROM hrSample WHERE deviceId = :deviceId ORDER BY ts DESC LIMIT 1")
    suspend fun latestHr(deviceId: String): HrSample?

    /** Latest battery sample for a device (most recent ts), or null. */
    @Query("SELECT * FROM battery WHERE deviceId = :deviceId ORDER BY ts DESC LIMIT 1")
    suspend fun latestBattery(deviceId: String): BatterySample?
}
