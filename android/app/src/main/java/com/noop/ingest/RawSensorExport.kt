package com.noop.ingest

import android.content.Context
import android.content.Intent
import android.os.Build
import android.widget.Toast
import androidx.core.content.FileProvider
import com.noop.BuildConfig
import com.noop.data.WhoopRepository
import java.io.File
import java.util.Locale

/**
 * EXPERIMENTAL diagnostic: dump the decoded per-sample sensor streams NOOP already stores to ONE
 * combined long-format CSV (last 24 h) and share it. Lets power users / external devs prototype
 * sleep / activity / VBT algorithms on real data without a BLE stream (#308/#276/#322).
 *
 * Long format = one row per sample, with a `stream` discriminator and ONLY that stream's columns
 * filled (the rest blank). Streams: hr / rr / gravity / steps / ppghr / spo2 / skintemp / resp /
 * event. All rows are merged then sorted by ts ascending. Plain text only — never any BLE hex.
 *
 * The `hr` stream reads the RAW `hrSample` table (NOT WhoopDao.hrSamples, which COALESCE-unions in
 * the v26 PPG-derived HR); PPG HR is its own `ppghr` stream so a measured sensor HR is never
 * confused with a derived estimate. Columns and semantics MATCH the Swift exporter byte-for-byte:
 *   unix_s,iso_utc,stream,hr_bpm,rr_ms,grav_x,grav_y,grav_z,step_counter,ppg_bpm,ppg_conf,
 *   spo2_red,spo2_ir,skintemp_raw,resp_raw,event_kind,event_payload
 *
 * On-device only — the file is written to cache/logs (the existing FileProvider path) and shared via
 * the same ACTION_SEND mechanism as the strap-log export; nothing leaves the phone unless shared.
 */
object RawSensorExport {

    /** 17 columns, in the contract order shared with the Swift exporter. */
    private const val HEADER =
        "unix_s,iso_utc,stream,hr_bpm,rr_ms,grav_x,grav_y,grav_z,step_counter,ppg_bpm,ppg_conf," +
            "spo2_red,spo2_ir,skintemp_raw,resp_raw,event_kind,event_payload"

    private val UTC_FMT: java.time.format.DateTimeFormatter =
        java.time.format.DateTimeFormatter.ofPattern("yyyy-MM-dd'T'HH:mm:ss'Z'", Locale.US)
            .withZone(java.time.ZoneOffset.UTC)

    private fun iso(epochSeconds: Long): String =
        UTC_FMT.format(java.time.Instant.ofEpochSecond(epochSeconds))

    /** One emitted row: ts + the filled column(s) for its stream; everything else blank. Sorted by ts. */
    private class Row(val ts: Long, val cells: List<String>)

    // Locale-proof Double (always '.'); reuse the exporter's csvField for the one free-text column.
    private fun n(v: Double): String = WhoopCsvExporter.num(v)
    private fun n(v: Int): String = v.toString()

    /**
     * Read each stream for [deviceId] over [from, to] (inclusive, unix seconds) and build the combined
     * long-format CSV body (header + rows sorted by ts asc). A high per-stream [limit] caps a runaway
     * 24 h window without truncating a normal day. Returns the CSV text plus a per-stream count map.
     */
    internal suspend fun buildCsv(
        repo: WhoopRepository,
        deviceId: String,
        from: Long,
        to: Long,
        limit: Int = 200_000,
    ): Pair<String, Map<String, Int>> {
        val rows = ArrayList<Row>()
        // Blank cell-lists per stream: 14 value columns after unix_s/iso_utc/stream.
        // index: 0 hr_bpm,1 rr_ms,2 grav_x,3 grav_y,4 grav_z,5 step_counter,6 ppg_bpm,7 ppg_conf,
        //        8 spo2_red,9 spo2_ir,10 skintemp_raw,11 resp_raw,12 event_kind,13 event_payload
        fun cells(vararg set: Pair<Int, String>): List<String> {
            val c = MutableList(14) { "" }
            for ((i, v) in set) c[i] = v
            return c
        }

        val counts = LinkedHashMap<String, Int>()
        fun tally(stream: String, n: Int) { counts[stream] = n }

        val hr = repo.rawHrSamples(deviceId, from, to, limit)
        tally("hr", hr.size)
        for (s in hr) rows += Row(s.ts, mkRow("hr", s.ts, cells(0 to n(s.bpm))))

        val rr = repo.rrIntervals(deviceId, from, to, limit)
        tally("rr", rr.size)
        for (s in rr) rows += Row(s.ts, mkRow("rr", s.ts, cells(1 to n(s.rrMs))))

        val grav = repo.gravitySamples(deviceId, from, to, limit)
        tally("gravity", grav.size)
        for (s in grav) rows += Row(s.ts, mkRow("gravity", s.ts, cells(2 to n(s.x), 3 to n(s.y), 4 to n(s.z))))

        val steps = repo.stepSamples(deviceId, from, to, limit)
        tally("steps", steps.size)
        for (s in steps) rows += Row(s.ts, mkRow("steps", s.ts, cells(5 to n(s.counter))))

        val ppg = repo.ppgHrSamples(deviceId, from, to, limit)
        tally("ppghr", ppg.size)
        for (s in ppg) rows += Row(s.ts, mkRow("ppghr", s.ts, cells(6 to n(s.bpm), 7 to n(s.conf))))

        val spo2 = repo.spo2Samples(deviceId, from, to, limit)
        tally("spo2", spo2.size)
        for (s in spo2) rows += Row(s.ts, mkRow("spo2", s.ts, cells(8 to n(s.red), 9 to n(s.ir))))

        val skin = repo.skinTempSamples(deviceId, from, to, limit)
        tally("skintemp", skin.size)
        for (s in skin) rows += Row(s.ts, mkRow("skintemp", s.ts, cells(10 to n(s.raw))))

        val resp = repo.respSamples(deviceId, from, to, limit)
        tally("resp", resp.size)
        for (s in resp) rows += Row(s.ts, mkRow("resp", s.ts, cells(11 to n(s.raw))))

        val events = repo.events(deviceId, from, to, limit)
        tally("event", events.size)
        for (s in events) {
            rows += Row(
                s.ts,
                mkRow("event", s.ts, cells(12 to WhoopCsvExporter.csvField(s.kind), 13 to WhoopCsvExporter.csvField(s.payloadJSON))),
            )
        }

        // Stable sort by ts asc (a stream's intra-ts order is its query's secondary key).
        rows.sortBy { it.ts }
        val sb = StringBuilder(HEADER).append('\n')
        for (r in rows) sb.append(r.cells.joinToString(",")).append('\n')
        return sb.toString() to counts
    }

    /** unix_s,iso_utc,stream + the 14 value cells. */
    private fun mkRow(stream: String, ts: Long, valueCells: List<String>): List<String> =
        ArrayList<String>(17).apply {
            add(ts.toString()); add(iso(ts)); add(stream); addAll(valueCells)
        }

    /**
     * Build the last-24 h CSV for the strap source and fire a share sheet (text/csv). Runs the DB read
     * off the main thread; toasts a per-stream summary so the user sees what was captured (and that the
     * deeper 5/MG streams are empty until they've been unlocked). On-device only.
     */
    suspend fun export(context: Context, repo: WhoopRepository, deviceId: String = "my-whoop") {
        runCatching {
            val now = System.currentTimeMillis() / 1000
            val (csv, counts) = buildCsv(repo, deviceId, now - 86_400, now)

            val header = buildString {
                appendLine("# NOOP raw sensor export · last 24h · long-format CSV")
                appendLine("# App: ${BuildConfig.VERSION_NAME} (${BuildConfig.TIER}) · Android ${Build.VERSION.RELEASE} (SDK ${Build.VERSION.SDK_INT}) · ${Build.MANUFACTURER} ${Build.MODEL}")
                appendLine("# One row per decoded sample; only the row's `stream` columns are filled. Times are UTC.")
            }
            val dir = File(context.cacheDir, "logs").apply { mkdirs() }
            val file = File(dir, "noop-raw-sensors.csv")
            file.writeText(header + csv)

            val uri = FileProvider.getUriForFile(context, "${context.packageName}.fileprovider", file)
            val send = Intent(Intent.ACTION_SEND).apply {
                type = "text/csv"
                putExtra(Intent.EXTRA_STREAM, uri)
                putExtra(Intent.EXTRA_SUBJECT, "NOOP raw sensor export")
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            }
            context.startActivity(Intent.createChooser(send, "Export raw sensor data"))

            val total = counts.values.sum()
            val summary = if (total == 0) {
                "No samples in the last 24h — wear the strap and let it sync, then export again."
            } else {
                // Compact "hr 3204 · rr 812 · …" line, only non-empty streams.
                counts.filterValues { it > 0 }.entries.joinToString(" · ") { "${it.key} ${it.value}" }
            }
            Toast.makeText(context, summary, Toast.LENGTH_LONG).show()
        }.onFailure {
            Toast.makeText(context, "Couldn't export sensor data: ${it.message}", Toast.LENGTH_LONG).show()
        }
    }
}
