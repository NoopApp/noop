package com.noop.ble

import android.content.Context
import com.noop.protocol.DeviceFamily
import java.io.File
import java.io.FileOutputStream

/**
 * Append-only on-device archive of HISTORICAL_DATA record frames that FAILED to decode (#77 / #91).
 *
 * WHY this exists: the strap FREES history once the phone acks its trim cursor. If a chunk's records
 * can't be decoded (CRC failure, or an unmapped firmware layout the v24 plausibility gate rejects),
 * acking anyway permanently destroys the user's ONLY copy of those records while the UI says "History
 * synced". So the Backfiller archives the raw bytes HERE — durably — BEFORE acking. The archive then
 * lets a later release that maps the layout recover the data, and is itself the corpus that mapping
 * needs. Frames carry sensor payloads, not identifiers (no serials/MACs).
 *
 * Format: one JSON object per line (JSONL) in the app-private filesDir, file [REJECTED_ARCHIVE_FILE]:
 *   {"capturedAtMs":<Long>,"trim":<Long>,"family":"whoop4"|"whoop5","frameHex":"<hex>"}
 * Each [append] flushes + fsyncs before returning, so a row is durable before the caller acks.
 *
 * Size cap ([maxBytes], ~5 MB): once the file reaches the cap, [append] does NOT write the frames but
 * still returns a SUCCESS result with [AppendResult.written] = false. That is deliberate — wedging the
 * whole offload on a full archive would be worse than dropping the newest few rejects, and by the time
 * 5 MB of rejects exist there is ample sample material to map the layout. The caller records the
 * not-written frames separately so the sync status never falsely claims they were preserved.
 *
 * A genuine WRITE FAILURE (I/O error) instead throws — the caller treats that as "do NOT ack", so the
 * strap keeps the records and re-sends them on the next offload. No data is lost either way.
 */
class RawHistoryArchive(
    private val context: Context,
    private val maxBytes: Long = REJECTED_ARCHIVE_MAX_BYTES,
) {
    /**
     * Outcome of an [append]. [ok] is true whenever the offload may proceed to ack; [written] is true
     * only when the bytes were actually persisted. (ok=true, written=false) is the archive-full case:
     * the offload continues but the frames were NOT preserved — surface that honestly.
     */
    data class AppendResult(val ok: Boolean, val written: Boolean)

    private val file: File get() = File(context.filesDir, REJECTED_ARCHIVE_FILE)

    /**
     * Durably append the given undecodable record [frames] (one JSONL line each). [trim] is the
     * HISTORY_END trim cursor the frames belong to; [family] tags the firmware generation so one
     * mapping toolchain can read both WHOOP 4 and 5/MG archives.
     *
     * Returns [AppendResult] (ok=true) on success, distinguishing actually-written from
     * archive-full-skipped. Throws [java.io.IOException] (and propagates other write errors) ONLY when
     * the bytes could not be made durable — the caller must then NOT ack so the strap re-sends.
     */
    fun append(frames: List<ByteArray>, trim: Long, family: DeviceFamily): AppendResult {
        if (frames.isEmpty()) return AppendResult(ok = true, written = false)

        val f = file
        // Cap reached: succeed WITHOUT writing so a full archive can't wedge the offload. The caller
        // tracks these as unarchived so the status stays honest.
        if (f.length() >= maxBytes) return AppendResult(ok = true, written = false)

        val familyTag = familyTag(family)
        val now = System.currentTimeMillis()
        // FileOutputStream in append mode; fsync the descriptor so the rows are durable BEFORE the ack
        // (the whole point of the archive). A throw here propagates → caller holds the ack.
        FileOutputStream(f, true).use { out ->
            val sb = StringBuilder()
            for (frame in frames) {
                sb.append(encodeLine(now, trim, familyTag, frame)).append('\n')
            }
            out.write(sb.toString().toByteArray(Charsets.UTF_8))
            out.flush()
            out.fd.sync()
        }
        return AppendResult(ok = true, written = true)
    }

    private fun encodeLine(capturedAtMs: Long, trim: Long, familyTag: String, frame: ByteArray): String =
        buildString {
            append("{\"capturedAtMs\":").append(capturedAtMs)
            append(",\"trim\":").append(trim)
            append(",\"family\":\"").append(familyTag).append('"')
            append(",\"frameHex\":\"").append(frame.toHex()).append("\"}")
        }

    private fun familyTag(family: DeviceFamily): String =
        if (family == DeviceFamily.WHOOP5) "whoop5" else "whoop4"

    private fun ByteArray.toHex(): String = joinToString("") { "%02x".format(it) }

    companion object {
        /** Archive filename in the app-private filesDir. */
        const val REJECTED_ARCHIVE_FILE = "rejected_history.jsonl"

        /** ~5 MB cap; above this [append] reports success without writing (frames tracked as unarchived). */
        const val REJECTED_ARCHIVE_MAX_BYTES = 5L * 1024 * 1024
    }
}
