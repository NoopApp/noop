package com.noop.ble

import android.content.Context
import com.noop.data.StreamBatch
import com.noop.data.WhoopRepository
import com.noop.protocol.DeviceFamily
import com.noop.protocol.Framing
import com.noop.protocol.HistoricalMeta
import com.noop.protocol.classifyHistoricalMeta
import com.noop.protocol.extractHistoricalStreams
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock

/**
 * Historical-offload state machine (idle / backfilling).
 *
 * Direct port of the macOS Swift `Backfiller` (Strand/Collect/Backfiller.swift). It consumes the
 * METADATA frames of an offload — HISTORY_START / repeated HISTORY_END / HISTORY_COMPLETE —
 * accumulating the type-47 records between them into chunks and committing each chunk durably.
 *
 * Per-chunk local safe-trim invariant (unchanged from Swift):
 *   decode known -> persist decoded (durable) -> persist the strap_trim cursor -> ack the trim to
 *   the strap (link-layer confirmed write).
 * A chunk is forgotten by the strap only after its decoded rows are locally durable AND the trim
 * cursor is persisted AND the ack write is confirmed. The phone NEVER waits on a server (there is
 * none — Strand is fully on-device).
 *
 * CRITICAL behaviour preserved from Swift: a high-freq-sync offload sends ONE HISTORY_START then
 * REPEATED HISTORY_ENDs (a chunk-close every ~50 records). So we ack EVERY end and keep
 * accumulating afterwards — we snapshot+clear the accumulated frames on each END but leave the
 * chunk OPEN so subsequent records become the next chunk. An END with no accumulated records is
 * still acked (it advances the strap's trim) — that is how the offload progresses.
 *
 * CONCURRENCY: [ingest] is `suspend` and serialised by [mutex] so START/data/END chunk assembly is
 * never reordered, matching the Swift serial-drain task. The owning [WhoopBleClient] feeds frames
 * in arrival order from a single drain coroutine.
 *
 * RAW CAPTURE: the Swift Backfiller optionally persists raw frames (research toggle, default OFF).
 * The Android data layer has no raw-frame outbox table, so raw persistence is intentionally omitted
 * here — decoded rows are the product of record and are still durably committed before the trim is
 * advanced, exactly as in the Swift default (raw-off) configuration. See the FLAG in the port notes.
 */
class Backfiller(
    private val repository: WhoopRepository,
    private val deviceId: String,
    private val cursorStore: TrimCursorStore,
    /**
     * Confirms one HISTORY_END chunk to the strap. Carries both the trim cursor (first u32 of
     * end_data, persisted as the `strap_trim` cursor) and the verbatim 8-byte `end_data` (the raw
     * HISTORY_END metadata.data[10:18]) the high-freq-sync ack form requires.
     */
    private val ackTrim: (trim: Long, endData: ByteArray) -> Unit,
    /**
     * Fires after a chunk's decoded rows are durably committed AND acked — i.e. real new data just
     * landed. Lets the client schedule on-device scoring right away instead of leaving fresh history
     * invisible until the next 15-min analysis tick. Empty chunks (metadata-only ENDs) don't fire.
     * (#78 fork)
     */
    private val onChunkCommitted: (StreamBatch) -> Unit = {},
    /**
     * The (device, wall) clock reference. type-47 records carry their OWN real unix timestamp so
     * the offset is a no-op for them; this is supplied only for the REALTIME_RAW_DATA fallback and
     * to mirror the Swift signature. Defaults to an identity ref (device == wall == now): the Swift
     * Backfiller falls back to exactly this when GET_CLOCK is silent, and type-47 still decodes to
     * correct wall time. Settable by [WhoopBleClient] if a real correlation lands.
     */
    var clockRef: ClockRef = ClockRef.identityNow(),
) {

    /**
     * Strap family for the CURRENT offload, set at [begin] — drives the family-aware frame parse
     * (5/MG inner record is +4) and the +4 end_data slice. The Backfiller is constructed once at
     * client init (before the family is known), so this is settable per-offload rather than a
     * constructor arg. Mirrors Swift `Backfiller.family` set in `begin(family:)`. (#78)
     */
    private var family: DeviceFamily = DeviceFamily.WHOOP4

    /** True while a historical offload session is active. */
    @Volatile
    var isBackfilling = false
        private set

    /** Serialises the suspend [ingest] calls so chunk boundaries are never crossed concurrently. */
    private val mutex = Mutex()

    /** Guards the [chunk]/[chunkOpen] mutations (the only cross-thread state: ingest vs begin/timeout). */
    private val chunkLock = Any()

    /** Buffered data frames for the current open chunk (between START and the next END). */
    private val chunk = ArrayList<ByteArray>()

    /** Whether a START has been received and we're accumulating a chunk. */
    private var chunkOpen = false

    /**
     * Called by [WhoopBleClient] when the strap signals a historical offload is beginning.
     * chunkOpen starts TRUE: the biometric replay streams records immediately and sends one
     * HISTORY_START then repeated HISTORY_ENDs, so we must accumulate from the outset.
     * Port of Swift `begin()`.
     */
    fun begin(family: DeviceFamily = DeviceFamily.WHOOP4) {
        this.family = family
        isBackfilling = true
        synchronized(chunkLock) {
            chunk.clear()
            chunkOpen = true
        }
    }

    /**
     * Feed one complete (reassembled) BLE frame into the state machine. Suspends while a chunk is
     * persisted so chunk boundaries are never crossed concurrently. Port of Swift `ingest(_:)`.
     */
    suspend fun ingest(frame: ByteArray) {
        mutex.withLock {
            when (val meta = classifyHistoricalMeta(Framing.parseFrame(frame, family))) {
                is HistoricalMeta.Start -> {
                    isBackfilling = true
                    synchronized(chunkLock) {
                        chunk.clear()
                        chunkOpen = true
                    }
                }
                is HistoricalMeta.End -> finishChunk(meta.unix, meta.trim, frame)
                is HistoricalMeta.Complete -> {
                    isBackfilling = false
                    synchronized(chunkLock) {
                        chunk.clear()
                        chunkOpen = false
                    }
                }
                is HistoricalMeta.Other -> synchronized(chunkLock) { if (chunkOpen) chunk.add(frame) }
            }
        }
    }

    /**
     * Commit one HISTORY_END chunk: persist decoded -> persist strap_trim cursor -> ack the trim.
     * Early-returns on any failure to preserve the safe-trim invariant (never ack data we failed to
     * store). Port of Swift `finishChunk(unix:trim:endFrame:)`.
     *
     * We snapshot+clear the accumulated frames but leave [chunkOpen] TRUE so the records following
     * this END become the next chunk. An END with no records is still acked (advances the trim).
     */
    private suspend fun finishChunk(unix: Long, trim: Long, endFrame: ByteArray) {
        val endData = endData(endFrame, family) ?: return

        val frames = synchronized(chunkLock) {
            val snapshot = ArrayList(chunk)
            chunk.clear() // next records accumulate into the next chunk
            snapshot
        }

        var committed: StreamBatch? = null
        if (frames.isNotEmpty()) {
            val ref = clockRef
            val decoded = extractHistoricalStreams(frames, ref.device, ref.wall, family)
            try {
                repository.insert(decoded, deviceId) // DECODED FIRST (durable)
                committed = decoded
            } catch (t: Throwable) {
                return // do NOT advance/ack — chunk was never durably committed
            }
        }

        // Persist the trim cursor BEFORE acking (so a crash between persist and ack still resumes
        // from the right place). Stored via [TrimCursorStore] because the Room schema has no cursor
        // table — see the port FLAG. trim is a u32 carried as Long (unsigned-safe).
        try {
            cursorStore.set(STRAP_TRIM_CURSOR, trim)
        } catch (t: Throwable) {
            return
        }

        ackTrim(trim, endData)
        committed?.takeIf { !it.isEmpty }?.let(onChunkCommitted)
    }

    /**
     * Called when a backfill watchdog timer fires (strap went silent mid-offload). Clears state
     * WITHOUT acking — the open chunk was never durably committed. Port of Swift `timeoutFired()`.
     */
    fun timeoutFired() {
        isBackfilling = false
        synchronized(chunkLock) {
            chunk.clear()
            chunkOpen = false
        }
    }

    companion object {
        /** Cursor name for the strap's safe-trim watermark. Matches the Swift `setCursor("strap_trim", ...)`. */
        const val STRAP_TRIM_CURSOR = "strap_trim"

        /**
         * The 8-byte `end_data` the high-freq-sync ack requires: metadata.data[10:18]. The inner
         * record begins at frame[7] on WHOOP4 (end_data = frame[17:25]) and at frame[11] on WHOOP5/MG
         * (the +4 puffin envelope → end_data = frame[21:29]). The trim cursor is the first u32 of
         * end_data. Returns null if the frame is too short. Verified against a real WHOOP5 HISTORY_END
         * (trim=112193 at frame[21:25]); port of Swift `Backfiller.endData(from:family:)`. (#78)
         */
        fun endData(frame: ByteArray, family: DeviceFamily): ByteArray? {
            val start = if (family == DeviceFamily.WHOOP5) 21 else 17
            if (frame.size < start + 8) return null
            return frame.copyOfRange(start, start + 8)
        }
    }
}

/**
 * A (device-epoch, wall-clock) correlation in unix seconds. Android analog of the Swift `ClockRef`.
 * type-47 historical records carry real unix timestamps, so the identity ref (device == wall) makes
 * the offset math a no-op while still decoding correct wall time — the same fallback the Swift
 * Backfiller uses when GET_CLOCK is silent.
 */
data class ClockRef(val device: Int, val wall: Int) {
    companion object {
        fun identityNow(): ClockRef {
            val now = (System.currentTimeMillis() / 1000L).toInt()
            return ClockRef(device = now, wall = now)
        }
    }
}

/**
 * Durable key/value cursor store. The macOS Backfiller persists `strap_trim` via the GRDB store's
 * cursor table; the Android Room schema has no cursor table (see Entities.kt — no cursor entity),
 * so this small SharedPreferences-backed store provides the equivalent durability WITHOUT touching
 * the Room schema or the build/manifest.
 *
 * FLAG (uncertain / divergence from macOS): on the Swift side the cursor lives in the same SQLite
 * file as the decoded rows, so cursor and rows commit/back-up atomically together. Here the cursor
 * lives in SharedPreferences, separate from the Room DB. The safe-trim ORDERING is preserved
 * (decoded rows are inserted and durable before the cursor is written, and the cursor is written
 * before the ack), so the worst case is a redundant re-offload of an already-stored chunk after a
 * crash — never data loss — because the decoded inserts are idempotent by natural key. If a Room
 * `cursor` table is later added, swap this implementation for a DAO-backed one.
 */
interface TrimCursorStore {
    suspend fun set(name: String, value: Long)
    suspend fun get(name: String): Long?
}

/** Default [TrimCursorStore] backed by a private SharedPreferences file. */
class PrefsTrimCursorStore(context: Context) : TrimCursorStore {
    private val prefs = context.applicationContext
        .getSharedPreferences("noop_backfill_cursors", Context.MODE_PRIVATE)

    override suspend fun set(name: String, value: Long) {
        // commit() (synchronous) so durability is established before we ack the strap.
        prefs.edit().putLong(name, value).commit()
    }

    override suspend fun get(name: String): Long? =
        if (prefs.contains(name)) prefs.getLong(name, 0L) else null
}
