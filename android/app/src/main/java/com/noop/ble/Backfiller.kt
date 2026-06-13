package com.noop.ble

import android.content.Context
import com.noop.data.InsertCounts
import com.noop.data.StreamBatch
import com.noop.data.WhoopRepository
import com.noop.protocol.DeviceFamily
import com.noop.protocol.Framing
import com.noop.protocol.HistoricalMeta
import com.noop.protocol.classifyHistoricalMeta
import com.noop.protocol.decodeHistorical
import com.noop.protocol.extractHistoricalStreams
import com.noop.protocol.rejectedHistoricalRecords
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
 * RAW CAPTURE: the Swift Backfiller optionally persists ALL raw frames (research toggle, default OFF);
 * the Android data layer has no raw-frame outbox table, so that bulk capture is intentionally omitted
 * here — decoded rows are the product of record and are still durably committed before the trim is
 * advanced, exactly as in the Swift default (raw-off) configuration. The ONE exception is the
 * undecodable-record archive (#77 / #91): record frames that fail decode are persisted via
 * [rejectedSink] BEFORE the trim is acked, because the strap frees acked history and those bytes would
 * otherwise be the user's permanently-lost only copy. See the FLAG in the port notes.
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
     * Per-console-only chunk hook (#77 family): a chunk arrived with frames but decoded no rows and
     * held no genuine rejects — pure diagnostic/console output. Lets the client tally a completed-but-
     * empty offload (the strap isn't banking) without false-positiving a normal caught-up sync.
     */
    private val onConsoleChunk: () -> Unit = {},
    /**
     * Diagnostic sink into the strap log. Lets [finishChunk] surface a chunk that arrived with frames
     * but decoded to ZERO rows — the otherwise-invisible silent-data-loss case (frames failing CRC /
     * an unmapped layout are dropped, the chunk looks empty, the trim acks past them). Without this a
     * "zero data" strap log shows healthy "acked chunk" lines while data is being discarded (#77). */
    private val log: (String) -> Unit = {},
    /**
     * Durable archive for HISTORICAL_DATA record frames that FAILED decode, called BEFORE the chunk
     * is acked. The strap frees acked history, so these raw bytes are the user's ONLY remaining copy
     * of an unmapped firmware's records — archiving them preserves the data for a later release that
     * maps the layout AND provides the corpus that mapping needs (#77 / #91). Return false ONLY when
     * the archive could not be made durable (a write failure — NOT the archive-full case): finishChunk
     * then does NOT advance the cursor or ack, so the strap keeps the records and re-sends them (same
     * invariant as a failed repository insert). The default keeps old behaviour for tests/callers that
     * do not wire an archive (no archive → nothing to preserve → proceed).
     */
    private val rejectedSink: (frames: List<ByteArray>, trim: Long) -> Boolean = { _, _ -> true },
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
     * Per-session persistence tally — the success-side observability flagged as the forensics blind spot
     * (#150): NOOP logged FAILURES (decoded-to-0) but never SUCCESSES, so a strap log couldn't tell a
     * banking strap from a broken one. Reset in [begin]; read by [WhoopBleClient] at session end to emit
     * "persisted N rows (M with motion) across K night(s)". Nights are day-keys (ts / 86400). Mirrors the
     * Swift Backfiller.
     */
    var sessionRowsPersisted = 0
        private set
    var sessionMotionRows = 0
        private set
    private val sessionNightKeys = HashSet<Long>()
    val sessionNights: Int get() = sessionNightKeys.size

    /**
     * Logged once per session when the strap reports trim=0xFFFFFFFF — the "no valid flash cursor"
     * sentinel: it has no banked history to offload (a clock/charge state, not a decode bug).
     */
    private var loggedNoCursor = false

    /**
     * Distinct historical record-layout versions logged this session. Before this, only the unmapped/
     * reject path surfaced a version, so a HEALTHY log never revealed which layout the strap emits
     * (v24/v25 on 4.0, v18/v26 on 5/MG) — exactly the firmware→layout signal triage needs. Reset in
     * [begin]; each distinct layout is logged once per session.
     */
    private val loggedLayoutVersions = HashSet<Int>()

    /**
     * Called by [WhoopBleClient] when the strap signals a historical offload is beginning.
     * chunkOpen starts TRUE: the biometric replay streams records immediately and sends one
     * HISTORY_START then repeated HISTORY_ENDs, so we must accumulate from the outset.
     * Port of Swift `begin()`.
     */
    fun begin(family: DeviceFamily = DeviceFamily.WHOOP4) {
        this.family = family
        isBackfilling = true
        sessionRowsPersisted = 0
        sessionMotionRows = 0
        sessionNightKeys.clear()
        loggedNoCursor = false
        loggedLayoutVersions.clear()
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

        // #150 forensics: trim=0xFFFFFFFF is the strap's "no valid flash cursor" sentinel — it has no
        // banked history to hand over. Surface it once so a log reads as a clock/charge state on the
        // strap, not a NOOP decode bug (retro-decode can't help here). The ack still proceeds below.
        if (trim == 0xFFFFFFFFL && !loggedNoCursor) {
            loggedNoCursor = true
            log(
                "Backfill: strap reported no flash cursor (trim=0xFFFFFFFF) — it has no banked history to " +
                    "offload. This is a clock/charge state on the strap, not a decode problem; fully charge " +
                    "it and reconnect so it starts banking.",
            )
        }

        val frames = synchronized(chunkLock) {
            val snapshot = ArrayList(chunk)
            chunk.clear() // next records accumulate into the next chunk
            snapshot
        }

        var committed: StreamBatch? = null
        if (frames.isNotEmpty()) {
            val ref = clockRef
            val decoded = extractHistoricalStreams(frames, ref.device, ref.wall, family)
            // Observability: which historical layout does this strap emit? Only the unmapped/reject path
            // logged a version before, so a healthy sync never revealed v24/v25 (4.0) or v18/v26 (5/MG).
            // Sample the chunk's first genuine record (null ⇒ console/CRC-fail); log each layout once/session.
            frames.firstNotNullOfOrNull { decodeHistorical(it, family)?.get("hist_version") as? Int }
                ?.let { if (loggedLayoutVersions.add(it)) log("Backfill: historical records use layout v$it") }
            // #77 / #91: HISTORICAL_DATA record frames that fail decode (CRC failure, or an unmapped
            // layout the v24 fallback's plausibility gate also rejects) used to be acked anyway — the
            // strap trims acked history, so the user's ONLY copy of those records was permanently
            // destroyed while the UI reported "History synced". Classify PER FRAME (a type-50 console
            // frame decodes to 0 rows BY DESIGN and must not raise the alarm — the old chunk-level
            // isEmpty check counted it and could waste the hex sample on it; it also missed mixed chunks
            // where one good row hid the losses). Archive the rejects durably FIRST, and only then allow
            // the ack below. The WHOOP4 happy path (zero rejects) is unchanged.
            val rejected = rejectedHistoricalRecords(frames, family)
            // #77 family: decoded no rows AND no genuine rejects ⇒ pure console output. Tally it so a
            // completed-but-empty offload (strap not banking) is distinguishable from a caught-up sync.
            if (decoded.isEmpty && rejected.isEmpty()) onConsoleChunk()
            if (rejected.isNotEmpty()) {
                log(
                    "Backfill: WARNING ${rejected.size} record frame(s) decoded to 0 rows " +
                        "(trim=$trim) — archiving raw bytes before ack (CRC/unmapped layout)",
                )
                // #91 / #30: a hex sample in the strap log so an unmapped firmware's record layout can
                // be mapped from a shared log. Dump the FULL frame (not a 64-byte prefix — v25/v26
                // records run ~84 B and the truncated tail is exactly where the unmapped motion/HR
                // fields sit), and sample a few more so one log carries enough records to triangulate
                // offsets. These only ever fire for unmapped firmware.
                rejected.take(8).forEachIndexed { i, f ->
                    val hex = f.joinToString("") { "%02x".format(it) }
                    log("Backfill: rejected frame[$i] ${f.size}B: $hex")
                }
                // Archive must be durable BEFORE the ack. A false return means a genuine write failure
                // (NOT the archive-full case, which returns true) — hold the cursor/ack so the strap
                // re-sends the chunk on the next offload. No data loss either way.
                if (!rejectedSink(rejected, trim)) {
                    return
                }
            }
            try {
                val counts = repository.insert(decoded, deviceId) // DECODED FIRST (durable)
                committed = decoded
                // Success-side observability (#150): tally what actually persisted so the session can emit
                // "persisted N rows (M with motion) across K night(s)" — the win-rate signal we never logged.
                val (rows, motion, nights) = chunkTally(counts, decoded.gravity.map { it.ts } + decoded.hr.map { it.ts })
                sessionRowsPersisted += rows
                sessionMotionRows += motion
                sessionNightKeys.addAll(nights)
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

        /**
         * Pure per-chunk persistence tally (#150). [rows] = biometric rows inserted (HR, R-R, SpO2,
         * skin-temp, resp, gravity — battery/events/steps are housekeeping, NOT biometric history, so
         * they must not inflate the count; matches the Swift tuple, which has no steps). [motion] =
         * gravity rows (the sleep-critical signal). nights = distinct day-keys (ts / 86400). Summed
         * across a session by [finishChunk] to drive the success summary line.
         */
        fun chunkTally(counts: InsertCounts, timestamps: List<Long>): Triple<Int, Int, Set<Long>> {
            val rows = counts.hr + counts.rr + counts.spo2 + counts.skinTemp + counts.resp + counts.gravity
            return Triple(rows, counts.gravity, timestamps.map { it / 86400L }.toSet())
        }

        /**
         * The one-line session success summary (#150) — the success-side log that never existed. Null
         * when nothing persisted, so a console-only / caught-up session stays quiet and the existing
         * empty-banking diagnostics speak instead.
         */
        fun sessionSummaryLine(rows: Int, motion: Int, nights: Int): String? =
            if (rows <= 0) null
            else "Backfill: session persisted $rows rows ($motion with motion) across $nights night(s)."
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
