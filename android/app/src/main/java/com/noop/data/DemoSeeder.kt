package com.noop.data

import org.json.JSONArray
import org.json.JSONObject
import java.time.LocalDate
import java.time.ZoneId
import kotlin.math.PI
import kotlin.math.cos
import kotlin.math.ln
import kotlin.math.round
import kotlin.math.sqrt
import kotlin.random.Random

/**
 * Seeds a comprehensive, self-contained demo dataset so the **dev** build is a full
 * walkthrough of every screen — Today, Sleep, Trends, Workouts, Health, Stress,
 * Insights, Explore, Compare, Apple Health — with no strap and no import required.
 *
 * The caller gates this to `BuildConfig.ENABLE_DEMO`, so the full app never seeds and
 * starts clean. It is a no-op if "my-whoop" already holds daily rows, so it runs at most
 * once and never clobbers real data.
 *
 * Everything here is **synthetic and deterministic** (fixed RNG seed). Nothing is real
 * biometric data. Values are physiologically plausible and internally correlated
 * (recovery ↔ HRV ↔ resting-HR ↔ sleep; strain ↔ workouts; a slow fitness drift over
 * the window) so the charts, trends and insights all read like a real account.
 */
object DemoSeeder {

    private const val WHOOP = "my-whoop"
    private const val APPLE = "apple-health"
    private const val DAYS = 120

    private val SPORTS = listOf(
        "Running", "Cycling", "Strength", "HIIT", "Swimming", "Yoga", "Walking", "Rowing"
    )

    /** Seed only if the demo (and the user) has no daily history yet. Safe to call on every launch. */
    suspend fun seedIfEmpty(repo: WhoopRepository) {
        if (repo.days(WHOOP).isNotEmpty()) return
        seed(repo)
    }

    private suspend fun seed(repo: WhoopRepository) {
        val rng = Random(0xC0FFEE)
        val zone = ZoneId.systemDefault()
        val startDay = LocalDate.now().minusDays((DAYS - 1).toLong())

        repo.upsertDevice(WHOOP, name = "WHOOP (demo)")

        val daily = ArrayList<DailyMetric>(DAYS)
        val sleeps = ArrayList<SleepSession>(DAYS)
        val series = ArrayList<MetricSeriesRow>(DAYS * 2)
        val apple = ArrayList<AppleDaily>(DAYS)
        val workouts = ArrayList<WorkoutRow>()
        val journal = ArrayList<JournalEntry>()

        var weight = 79.5
        var fitness = 0.0 // slow upward drift: HRV rises, resting-HR falls, VO2max climbs

        for (i in 0 until DAYS) {
            val date = startDay.plusDays(i.toLong())
            val day = date.toString() // ISO yyyy-MM-dd
            val weekend = date.dayOfWeek.value >= 6
            fitness += 0.012

            // --- training load for the day ---
            val trains = if (weekend) rng.nextDouble() < 0.40 else rng.nextDouble() < 0.62
            val nWorkouts = if (!trains) 0 else if (rng.nextDouble() < 0.22) 2 else 1

            // --- sleep architecture ---
            val totalSleep = gauss(rng, 430.0, 35.0).coerceIn(300.0, 540.0)
            val efficiency = gauss(rng, 89.0, 4.0).coerceIn(72.0, 98.0)
            val deep = (totalSleep * gauss(rng, 0.20, 0.03)).coerceIn(35.0, 130.0)
            val rem = (totalSleep * gauss(rng, 0.23, 0.03)).coerceIn(45.0, 150.0)
            val light = (totalSleep - deep - rem).coerceAtLeast(60.0)
            val disturbances = gauss(rng, 6.0, 3.0).coerceIn(0.0, 18.0).toInt()

            // --- autonomic markers ---
            val hrv = (gauss(rng, 78.0 + fitness * 1.5, 12.0) + (if (weekend) 6 else 0) - nWorkouts * 4)
                .coerceIn(28.0, 150.0)
            val rhr = (gauss(rng, 56.0 - fitness * 0.4, 3.0) + nWorkouts * 1.2)
                .coerceIn(42.0, 70.0).toInt()
            val spo2 = gauss(rng, 96.5, 0.8).coerceIn(93.0, 100.0)
            val skinTempDev = gauss(rng, 0.0, 0.25).coerceIn(-1.2, 1.4)
            val resp = gauss(rng, 14.6, 0.9).coerceIn(11.0, 19.0)

            // --- recovery: a function of HRV, sleep quality and resting-HR ---
            val recovery = (
                40 + (hrv - 70) * 0.55 + (efficiency - 85) * 0.6 + (totalSleep - 420) * 0.03 -
                    (rhr - 55) * 1.4 - disturbances * 0.8 + gauss(rng, 0.0, 5.0)
                ).coerceIn(8.0, 99.0)

            // --- strain: workout-driven ---
            val strain = (
                if (nWorkouts == 0) gauss(rng, 7.5, 1.8)
                else gauss(rng, 13.5, 2.4) + (nWorkouts - 1) * 2.5
                ).coerceIn(3.0, 21.0)

            daily.add(
                DailyMetric(
                    deviceId = WHOOP, day = day,
                    totalSleepMin = round1(totalSleep), efficiency = round1(efficiency),
                    deepMin = round1(deep), remMin = round1(rem), lightMin = round1(light),
                    disturbances = disturbances, restingHr = rhr, avgHrv = round1(hrv),
                    recovery = round1(recovery), strain = round1(strain), exerciseCount = nWorkouts,
                    spo2Pct = round1(spo2), skinTempDevC = round2(skinTempDev), respRateBpm = round1(resp),
                )
            )

            // --- sleep session: previous night ~23:10 → wake ---
            val onset = date.minusDays(1).atTime(23, 10).atZone(zone).toEpochSecond() + rng.nextInt(-1800, 1800)
            val inBedSec = ((totalSleep + totalSleep * (100 - efficiency) / 100) * 60).toLong()
            sleeps.add(
                SleepSession(
                    deviceId = WHOOP, startTs = onset, endTs = onset + inBedSec,
                    efficiency = round1(efficiency), restingHr = rhr, avgHrv = round1(hrv),
                    stagesJSON = stagesJson(deep, rem, light, disturbances),
                )
            )

            // --- long-format extras (body composition) under my-whoop ---
            weight += gauss(rng, -0.02, 0.18)
            series.add(MetricSeriesRow(WHOOP, day, "weightKg", round2(weight)))
            series.add(
                MetricSeriesRow(
                    WHOOP, day, "bodyFatPct",
                    round1((18.0 - fitness * 0.2 + gauss(rng, 0.0, 0.4)).coerceIn(10.0, 24.0))
                )
            )

            // --- Apple Health daily aggregate ---
            val steps = gauss(rng, 8500.0, 2600.0).coerceIn(1200.0, 19000.0).toInt()
            apple.add(
                AppleDaily(
                    deviceId = APPLE, day = day,
                    steps = steps,
                    activeKcal = round1((steps * 0.045 + nWorkouts * 220).coerceIn(120.0, 1400.0)),
                    basalKcal = round1(gauss(rng, 1650.0, 40.0)),
                    vo2max = round1((46 + fitness * 0.3 + gauss(rng, 0.0, 0.5)).coerceIn(38.0, 56.0)),
                    avgHr = gauss(rng, 72.0, 5.0).toInt(),
                    maxHr = gauss(rng, 150.0, 12.0).toInt(),
                    walkingHr = gauss(rng, 108.0, 6.0).toInt(),
                    weightKg = round2(weight),
                )
            )

            // --- workouts on training days ---
            repeat(nWorkouts) { k ->
                val sport = SPORTS[rng.nextInt(SPORTS.size)]
                val durSec = (gauss(rng, 48.0, 16.0).coerceIn(18.0, 110.0) * 60)
                val start = date.atTime(if (weekend) 9 else 18, rng.nextInt(0, 50))
                    .atZone(zone).toEpochSecond() + k * 3600
                val avg = gauss(rng, 138.0, 12.0).toInt()
                val src = if (rng.nextDouble() < 0.7) WHOOP else APPLE
                val distanceSports = setOf("Running", "Cycling", "Walking", "Swimming", "Rowing")
                workouts.add(
                    WorkoutRow(
                        deviceId = src, startTs = start, endTs = start + durSec.toLong(),
                        sport = sport, source = src,
                        durationS = round1(durSec),
                        energyKcal = round1((durSec / 60) * gauss(rng, 9.0, 2.0)),
                        avgHr = avg, maxHr = (avg + gauss(rng, 22.0, 6.0)).toInt(),
                        strain = round1((strain * gauss(rng, 0.6, 0.1)).coerceIn(4.0, 21.0)),
                        distanceM = if (sport in distanceSports)
                            round1(gauss(rng, 6500.0, 2500.0).coerceAtLeast(500.0)) else null,
                        // Only WHOOP-sourced rows carry zones (matching real imports — Apple Health
                        // rows never do), so the demo Workouts screen showcases the HR Zones card.
                        zonesJSON = if (src == WHOOP) run {
                            val z = listOf(
                                gauss(rng, 15.0, 5.0), gauss(rng, 30.0, 8.0), gauss(rng, 28.0, 8.0),
                                gauss(rng, 15.0, 6.0), gauss(rng, 6.0, 3.0),
                            ).map { it.coerceIn(0.0, 100.0) }
                            """{"zone1":${round1(z[0])},"zone2":${round1(z[1])},"zone3":${round1(z[2])},"zone4":${round1(z[3])},"zone5":${round1(z[4])}}"""
                        } else null,
                        notes = null,
                    )
                )
            }

            // --- journal answers for the recent 40 days ---
            if (i >= DAYS - 40) {
                journal.add(JournalEntry(WHOOP, day, "Any alcohol?", rng.nextDouble() < 0.18))
                journal.add(JournalEntry(WHOOP, day, "Caffeine after 4pm?", rng.nextDouble() < 0.30))
                journal.add(JournalEntry(WHOOP, day, "Felt stressed?", rng.nextDouble() < 0.28))
            }
        }

        repo.upsertDailyMetrics(daily)
        repo.upsertSleepSessions(sleeps)
        repo.upsertMetricSeries(series)
        repo.upsertAppleDaily(apple)
        if (workouts.isNotEmpty()) repo.upsertWorkouts(workouts)
        if (journal.isNotEmpty()) repo.upsertJournal(journal)
    }

    // MARK: - helpers

    /** Box–Muller normal sample. */
    private fun gauss(rng: Random, mean: Double, sd: Double): Double {
        val u1 = rng.nextDouble().coerceIn(1e-9, 1.0)
        val u2 = rng.nextDouble()
        return mean + sd * (sqrt(-2.0 * ln(u1)) * cos(2.0 * PI * u2))
    }

    private fun round1(x: Double) = round(x * 10.0) / 10.0
    private fun round2(x: Double) = round(x * 100.0) / 100.0

    /** A plausible light→deep→rem cycle as a stage-segments array (minutes). Tolerant by design. */
    private fun stagesJson(deep: Double, rem: Double, light: Double, awakeMin: Int): String {
        val arr = JSONArray()
        fun seg(stage: String, min: Double) {
            arr.put(JSONObject().put("stage", stage).put("min", round1(min)))
        }
        seg("light", light * 0.35); seg("deep", deep * 0.6); seg("light", light * 0.30)
        seg("rem", rem * 0.6); seg("deep", deep * 0.4); seg("light", light * 0.35)
        seg("rem", rem * 0.4); seg("awake", awakeMin.toDouble())
        return arr.toString()
    }
}
