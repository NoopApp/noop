package com.noop.ingest

import android.content.Context
import android.net.Uri
import com.noop.data.DailyMetric
import com.noop.data.JournalEntry
import com.noop.data.SleepSession
import com.noop.data.WhoopRepository
import com.noop.data.WorkoutRow
import com.noop.ui.parseZonePercents
import org.json.JSONArray
import org.json.JSONObject
import java.io.ByteArrayOutputStream
import java.io.IOException
import java.util.Locale
import java.util.zip.ZipEntry
import java.util.zip.ZipOutputStream
import kotlin.math.abs
import kotlin.math.floor

/**
 * Serializes NOOP's own cached rows into WHOOP's 4-CSV export shape so NOOP's OWN importers
 * (WhoopCsvImporter here, WhoopExportImporter on macOS) re-import them losslessly — the
 * round-trip is pinned by WhoopCsvExporterTest parsing the output with the real importer.
 *
 * Header strings are byte-identical to a real WHOOP export (see the macOS test fixtures).
 * Everything is exported in UTC with "Cycle timezone","UTC+00:00" — NOOP stores epochs and
 * tz-less day strings, so UTC is the only encoding that round-trips exactly. A trailing
 * "Source" column (provably ignored by both parsers) marks on-device computed rows as
 * "noop (APPROXIMATE)" per the house rules; a noop_metric_series.json sidecar carries the
 * full metricSeries for fidelity and is deliberately NOT re-imported (the .sqlite backup
 * remains the lossless restore path).
 */
object WhoopCsvExporter {

    private val UTC_FMT: java.time.format.DateTimeFormatter =
        java.time.format.DateTimeFormatter.ofPattern("yyyy-MM-dd HH:mm:ss", Locale.US)
            .withZone(java.time.ZoneOffset.UTC)

    internal fun utc(epochSeconds: Long): String =
        UTC_FMT.format(java.time.Instant.ofEpochSecond(epochSeconds))

    /** RFC-4180: quote when the field carries , " \r \n; escape " as "". */
    internal fun csvField(raw: String?): String {
        if (raw.isNullOrEmpty()) return ""
        if (raw.none { it == ',' || it == '"' || it == '\n' || it == '\r' }) return raw
        return "\"" + raw.replace("\"", "\"\"") + "\""
    }

    /** Locale-proof numbers: integral Doubles print without ".0"; Double.toString uses '.'. */
    internal fun num(v: Double?): String = when {
        v == null -> ""
        v == floor(v) && abs(v) < 1e12 -> v.toLong().toString()
        else -> v.toString()
    }

    internal fun num(v: Int?): String = v?.toString() ?: ""

    // MARK: - Tolerant decoders for the cache's polymorphic JSON columns

    internal data class StageMinutes(
        val light: Double?, val deep: Double?, val rem: Double?, val awake: Double?,
    ) {
        val asleep: Double? get() =
            if (light == null && deep == null && rem == null) null
            else (light ?: 0.0) + (deep ?: 0.0) + (rem ?: 0.0)
    }

    /** Stage minutes from any persisted stagesJSON shape: {"light":min,...} (macOS import),
     *  [{"stage","min"}] (Android import/demo), [{"start","end","stage"}] (on-device stager,
     *  "wake" == awake). Unusable input → all-null. */
    internal fun stageMinutes(stagesJSON: String?): StageMinutes {
        val none = StageMinutes(null, null, null, null)
        if (stagesJSON.isNullOrBlank()) return none
        return runCatching {
            val t = stagesJSON.trim()
            if (t.startsWith("{")) {
                val o = JSONObject(t)
                fun g(k: String): Double? =
                    if (o.has(k)) o.optDouble(k).takeIf { !it.isNaN() } else null
                StageMinutes(g("light"), g("deep"), g("rem"), g("awake") ?: g("wake"))
            } else if (t.startsWith("[")) {
                val arr = JSONArray(t)
                var l = 0.0; var d = 0.0; var r = 0.0; var a = 0.0; var any = false
                for (i in 0 until arr.length()) {
                    val seg = arr.optJSONObject(i) ?: continue
                    val stage = seg.optString("stage", "").lowercase()
                    val min: Double = if (seg.has("min")) {
                        seg.optDouble("min", 0.0)
                    } else if (seg.has("start") && seg.has("end")) {
                        (seg.optLong("end") - seg.optLong("start")) / 60.0
                    } else {
                        continue
                    }
                    any = true
                    when (stage) {
                        "light" -> l += min
                        "deep", "sws" -> d += min
                        "rem" -> r += min
                        "awake", "wake" -> a += min
                        else -> {}   // unknown stage: counted as nothing
                    }
                }
                if (any) StageMinutes(l, d, r, a) else none
            } else none
        }.getOrDefault(none)
    }

    // MARK: - The four CSVs (headers byte-identical to a real WHOOP export)

    /** seriesByDay: day -> (metricSeries key -> value) for the cycles columns DailyMetric
     *  lacks (sleep_performance / sleep_consistency / sleep_need_min / sleep_debt_min).
     *  sourceByDay feeds the trailing provenance column both parsers ignore. */
    internal fun cyclesCsv(
        daily: List<DailyMetric>,
        seriesByDay: Map<String, Map<String, Double>>,
        sourceByDay: Map<String, String> = emptyMap(),
    ): String {
        val sb = StringBuilder()
        sb.append("Cycle start time,Cycle end time,Cycle timezone,Recovery score %,")
            .append("Resting heart rate (bpm),Heart rate variability (ms),Skin temp (celsius),")
            .append("Blood oxygen %,Day Strain,Energy burned (cal),Max HR (bpm),Average HR (bpm),")
            .append("Sleep onset,Wake onset,Sleep performance %,Respiratory rate (rpm),")
            .append("Asleep duration (min),In bed duration (min),Light sleep duration (min),")
            .append("Deep (SWS) duration (min),REM duration (min),Awake duration (min),")
            .append("Sleep efficiency %,Sleep consistency %,Sleep need (min),Sleep debt (min),Source\r\n")
        for (d in daily.sortedBy { it.day }) {
            val s = seriesByDay[d.day].orEmpty()
            sb.append(
                listOf(
                    d.day + " 00:00:00", "", "UTC+00:00",
                    num(d.recovery), num(d.restingHr), num(d.avgHrv), num(d.skinTempDevC),
                    num(d.spo2Pct), num(d.strain),
                    "", "", "",            // energy / max HR / avg HR — not in the wide row here
                    "", "",                // sleep/wake onset live in sleeps.csv
                    num(s["sleep_performance"]), num(d.respRateBpm), num(d.totalSleepMin),
                    "",                    // in-bed not stored on the Android daily row
                    num(d.lightMin), num(d.deepMin), num(d.remMin), num(d.disturbances),
                    num(d.efficiency), num(s["sleep_consistency"]), num(s["sleep_need_min"]),
                    num(s["sleep_debt_min"]), csvField(sourceByDay[d.day]),
                ).joinToString(","),
            ).append("\r\n")
        }
        return sb.toString()
    }

    internal fun sleepsCsv(
        sessions: List<SleepSession>,
        sourceBySession: (SleepSession) -> String = { "" },
    ): String {
        val sb = StringBuilder()
        sb.append("Cycle start time,Sleep onset,Wake onset,Cycle timezone,Nap,Sleep performance %,")
            .append("Respiratory rate (rpm),Asleep duration (min),In bed duration (min),")
            .append("Light sleep duration (min),Deep (SWS) duration (min),REM duration (min),")
            .append("Awake duration (min),Sleep efficiency %,Sleep consistency %,")
            .append("Sleep need (min),Sleep debt (min),Source\r\n")
        for (s in sessions.sortedBy { it.startTs }) {
            val stages = stageMinutes(s.stagesJSON)
            val inBedMin = if (s.endTs > s.startTs) (s.endTs - s.startTs) / 60.0 else null
            sb.append(
                listOf(
                    utc(s.startTs), utc(s.startTs), utc(s.endTs), "UTC+00:00",
                    // NOOP never stores a nap flag — everything exports as a main sleep.
                    "false", "", "",
                    num(stages.asleep), num(inBedMin),
                    num(stages.light), num(stages.deep), num(stages.rem), num(stages.awake),
                    num(s.efficiency), "", "", "", csvField(sourceBySession(s)),
                ).joinToString(","),
            ).append("\r\n")
        }
        return sb.toString()
    }

    internal fun workoutsCsv(
        rows: List<WorkoutRow>,
        sourceLabel: (WorkoutRow) -> String = { "" },
    ): String {
        val sb = StringBuilder()
        sb.append("Cycle start time,Workout start time,Workout end time,Cycle timezone,")
            .append("Activity name,Activity Strain,Energy burned (cal),Max HR (bpm),")
            .append("Average HR (bpm),HR Zone 1 %,HR Zone 2 %,HR Zone 3 %,HR Zone 4 %,")
            .append("HR Zone 5 %,Distance (meters),Source\r\n")
        for (w in rows.sortedBy { it.startTs }) {
            val zones = parseZonePercents(w.zonesJSON)
            sb.append(
                listOf(
                    utc(w.startTs), utc(w.startTs), utc(w.endTs), "UTC+00:00",
                    csvField(w.sport), num(w.strain), num(w.energyKcal), num(w.maxHr), num(w.avgHr),
                    num(zones?.get(0)), num(zones?.get(1)), num(zones?.get(2)),
                    num(zones?.get(3)), num(zones?.get(4)),
                    num(w.distanceM), csvField(sourceLabel(w)),
                ).joinToString(","),
            ).append("\r\n")
        }
        return sb.toString()
    }

    internal fun journalCsv(rows: List<JournalEntry>): String {
        val sb = StringBuilder()
        sb.append("Cycle start time,Cycle timezone,Question text,Answered yes/no,Notes\r\n")
        for (e in rows.sortedWith(compareBy({ it.day }, { it.question }))) {
            sb.append(
                listOf(
                    e.day + " 00:00:00", "UTC+00:00", csvField(e.question),
                    // The macOS importer requires the literal "true" — never prettify to Yes/No.
                    if (e.answeredYes) "true" else "false",
                    csvField(e.notes),
                ).joinToString(","),
            ).append("\r\n")
        }
        return sb.toString()
    }

    /** Full-fidelity metricSeries dump ({deviceId, day, key, value}) — the sidecar is
     *  documentation/fidelity only; the importers deliberately ignore non-CSV entries. */
    internal fun metricSeriesJson(rows: List<com.noop.data.MetricSeriesRow>): String {
        val arr = JSONArray()
        for (r in rows.sortedWith(compareBy({ it.deviceId }, { it.day }, { it.key }))) {
            arr.put(
                JSONObject()
                    .put("deviceId", r.deviceId)
                    .put("day", r.day)
                    .put("key", r.key)
                    .put("value", r.value),
            )
        }
        return arr.toString(2)
    }

    internal fun zipBytes(entries: Map<String, ByteArray>): ByteArray {
        val bos = ByteArrayOutputStream()
        ZipOutputStream(bos).use { zos ->
            for ((name, bytes) in entries) {
                zos.putNextEntry(ZipEntry(name))
                zos.write(bytes)
                zos.closeEntry()
            }
        }
        return bos.toByteArray()
    }

    /**
     * UI entry point: serialize the merged "my-whoop" ∪ "my-whoop-noop" history (imported
     * wins per day — exactly what the dashboards show; Apple Health / Health Connect rows
     * are deliberately EXCLUDED so a re-import can't mis-attribute them as WHOOP data)
     * and write a zip to [uri]. Returns a human summary for the toast.
     */
    suspend fun exportZip(
        context: Context,
        uri: Uri,
        repo: WhoopRepository,
        deviceId: String = "my-whoop",
    ): String {
        val computedId = repo.computedDeviceId(deviceId)
        val hi = System.currentTimeMillis() / 1000 + 86_400
        val daily = repo.daysMerged(deviceId)
        val importedDays = repo.days(deviceId).map { it.day }.toHashSet()
        val sourceByDay = daily.associate { d ->
            d.day to if (d.day in importedDays) "import" else "noop (APPROXIMATE)"
        }
        val sleeps = repo.sleepSessionsMerged(deviceId, 0L, hi)
        val workouts = repo.workouts(deviceId, 0L, hi) +
            repo.workouts(computedId, 0L, hi)
        val journal = repo.journal(deviceId, "0000-01-01", "9999-12-31")

        val seriesByDay = HashMap<String, MutableMap<String, Double>>()
        for (key in listOf("sleep_performance", "sleep_consistency", "sleep_need_min", "sleep_debt_min")) {
            for (p in repo.metricSeries(deviceId, key, "0000-01-01", "9999-12-31")) {
                seriesByDay.getOrPut(p.day) { HashMap() }[key] = p.value
            }
        }
        // Sidecar: every metricSeries row under both sources, full fidelity.
        val sidecarRows = buildList {
            for (id in listOf(deviceId, computedId)) {
                for (key in repo.metricKeys(id)) {
                    addAll(repo.metricSeries(id, key, "0000-01-01", "9999-12-31"))
                }
            }
        }

        fun workoutSource(w: WorkoutRow): String = when {
            w.deviceId.endsWith("-noop") -> "noop (APPROXIMATE)"
            w.source == "manual" -> "manual"
            else -> "import"
        }

        val zip = zipBytes(
            linkedMapOf(
                "physiological_cycles.csv" to cyclesCsv(daily, seriesByDay, sourceByDay).toByteArray(),
                "sleeps.csv" to sleepsCsv(sleeps).toByteArray(),
                "workouts.csv" to workoutsCsv(workouts, ::workoutSource).toByteArray(),
                "journal_entries.csv" to journalCsv(journal).toByteArray(),
                "noop_metric_series.json" to metricSeriesJson(sidecarRows).toByteArray(),
            ),
        )
        context.contentResolver.openOutputStream(uri)?.use { it.write(zip); it.flush() }
            ?: throw IOException("Could not open the chosen file for writing.")
        return "Exported ${daily.size} days, ${sleeps.size} sleeps, ${workouts.size} workouts, " +
            "${journal.size} journal entries."
    }
}
