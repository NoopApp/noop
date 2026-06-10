package com.noop.protocol

import com.noop.data.BatteryRow
import com.noop.data.EventEntry
import com.noop.data.GravityRow
import com.noop.data.HrRow
import com.noop.data.RespRow
import com.noop.data.RrRow
import com.noop.data.SkinTempRow
import com.noop.data.Spo2Row
import com.noop.data.StepRow
import com.noop.data.StreamBatch
import com.noop.data.StreamPersistence

/*
 * Historical (offload) decode for the WHOOP 4.0 — the type-47 HISTORICAL_DATA path.
 *
 * Faithful port of three macOS Swift pieces:
 *   - the `postHooks["historical_data"]` decoder (Packages/WhoopProtocol/.../PostHooks.swift),
 *     which decodes a type-47 record's biometric block using the per-version field table baked
 *     into whoop_protocol.json (V24/V12 = full DSP block; V5/V7/V9 = generic HR/RR only),
 *   - `classifyHistoricalMeta` (Packages/WhoopProtocol/.../HistoricalMeta.swift), the METADATA
 *     classifier the offload state machine uses, and
 *   - `extractHistoricalStreams` (Packages/WhoopProtocol/.../HistoricalStreams.swift), which turns
 *     a batch of parsed offload frames into datastore rows.
 *
 * WHY this lives here and not in [Framing.parseFrame]: the live [Framing] decoder deliberately
 * does NOT decode type-47 (it only handles REALTIME_DATA / EVENT / COMMAND_RESPONSE / METADATA),
 * exactly like the Swift live path. Historical records are decoded only during a backfill, so the
 * type-47 decoder is kept on the offload path to mirror the Swift split precisely.
 *
 * The frame envelope is identical to Framing.kt's: [0]=0xAA, [1..2]=len u16 LE, [3]=crc8(len),
 * [4]=packet type (47 here), [5]=record VERSION (NOT a sequence byte for type-47 — the schema
 * note says "Version = seq byte (frame[5])"), [6..]=record. Field offsets in the version table
 * are FRAME-ABSOLUTE (= openwhoop data offset + 7). All multi-byte values are little-endian.
 */

// MARK: - little-endian readers (null when out of range; mirror PostHooks.swift u8/u16/u32/f32)

private fun ByteArray.histU8(off: Int): Int? = if (off + 1 <= size) this[off].toInt() and 0xFF else null

private fun ByteArray.histU16(off: Int): Int? =
    if (off + 2 <= size) (this[off].toInt() and 0xFF) or ((this[off + 1].toInt() and 0xFF) shl 8) else null

private fun ByteArray.histU32(off: Int): Long? {
    if (off + 4 > size) return null
    return (this[off].toLong() and 0xFFL) or
        ((this[off + 1].toLong() and 0xFFL) shl 8) or
        ((this[off + 2].toLong() and 0xFFL) shl 16) or
        ((this[off + 3].toLong() and 0xFFL) shl 24)
}

/**
 * IEEE-754 float32 LE -> Double (exact, NO rounding). null when out of range.
 * Port of PostHooks.swift `f32`: read the 4 bytes as a u32 bit-pattern, reinterpret as Float,
 * then widen to Double. Kotlin's `Float.fromBits(Int)` is the exact analog of
 * `Float(bitPattern:)`; widening Float -> Double is value-preserving.
 */
private fun ByteArray.histF32(off: Int): Double? {
    val bits = histU32(off) ?: return null
    return Float.fromBits(bits.toInt()).toDouble()
}

/**
 * One decoded type-47 field-layout VERSION. Frame-absolute offsets, lifted verbatim from the
 * `HISTORICAL_DATA.versions` table in whoop_protocol.json. `rrFirstOff` is where the (up to 4)
 * u16 R-R intervals begin. A null DSP-block offset means that field is absent for the version.
 */
private data class HistVersion(
    val unixOff: Int,
    val hrOff: Int,
    val rrCountOff: Int,
    val rrFirstOff: Int,
    // Full DSP biometric block (V24 / V12 only); null on the generic V5/V7/V9 records.
    val spo2RedOff: Int? = null,
    val spo2IrOff: Int? = null,
    val skinTempRawOff: Int? = null,
    val respRateRawOff: Int? = null,
    val gravityXOff: Int? = null,
    val gravityYOff: Int? = null,
    val gravityZOff: Int? = null,
)

/**
 * V24 layout (this WHOOP 4.0; verified on 762 device records per the schema note). V12 shares the
 * exact same DSP layout ("ref":"24"). Offsets are FRAME-ABSOLUTE, copied from whoop_protocol.json.
 */
private val HIST_V24 = HistVersion(
    unixOff = 11,
    hrOff = 21,
    rrCountOff = 22,
    rrFirstOff = 23,
    spo2RedOff = 68,
    spo2IrOff = 70,
    skinTempRawOff = 72,
    respRateRawOff = 80,
    gravityXOff = 40,
    gravityYOff = 44,
    gravityZOff = 48,
)

/** Generic HR/RR-only record (V5; V7/V9 share it via "ref":"5"). No DSP sensor block. */
private val HIST_V5 = HistVersion(
    unixOff = 11,
    hrOff = 21,
    rrCountOff = 22,
    rrFirstOff = 23,
)

/** Resolve a record version (frame[5]) to its field layout, or null if the layout is unmapped. */
private fun histVersionLayout(version: Int): HistVersion? = when (version) {
    24, 12 -> HIST_V24
    5, 7, 9 -> HIST_V5
    else -> null
}

/**
 * Decode a single type-47 HISTORICAL_DATA frame into the same flat parsed-map keys the Swift
 * `postHooks["historical_data"]` produces. Returns null when the frame is not a valid type-47
 * record (wrong SOF/too short/failed CRC/unmapped version) — callers skip those, matching the
 * Swift `if !r.ok || r.crcOK == false { continue }` + unmapped-layout guard.
 *
 * Keys emitted (only when present in the frame): `hist_version`, `unix`, `heart_rate`, `rr_count`,
 * `rr_intervals` (List<Int>), `spo2_red`, `spo2_ir`, `skin_temp_raw`, `resp_rate_raw`, `gravity_x`,
 * `gravity_y`, `gravity_z`. These match the keys [extractHistoricalStreams] reads.
 */
fun decodeHistorical(frame: ByteArray, family: DeviceFamily = DeviceFamily.WHOOP4): Map<String, Any?>? {
    if (frame.size < 8 || frame[0] != 0xAA.toByte()) return null

    // Integrity gate: validate the envelope + CRC32 via the shared Framing parser. We reuse its
    // crcOk so a garbled/forged offload frame can never inject rows. parseFrame leaves type-47's
    // `parsed` empty (the live decoder skips type-47), so we decode the record ourselves below.
    val checked = Framing.parseFrame(frame, family)
    if (!checked.ok || checked.crcOk == false) return null

    // WHOOP 5.0/MG has the longer puffin envelope (record @8), so its v18 layout is decoded separately
    // at its own absolute offsets (port of Swift decodeWhoop5Historical). WHOOP 4 below is unchanged.
    if (family == DeviceFamily.WHOOP5) return decodeWhoop5Historical(frame)
    if (family != DeviceFamily.WHOOP4) return null
    if (frame[4].toInt() and 0xFF != PacketType.HISTORICAL_DATA.rawValue) return null

    val version = frame[5].toInt() and 0xFF
    // Unmapped firmware version: instead of dropping the whole record (→ no HR/R-R/gravity → no sleep,
    // and on Android this previously meant ZERO data for a strap on newer firmware — the macOS
    // issue-#30 fix that never reached Android; the likely cause of #77 on some WHOOP 4 straps), fall
    // back to the canonical v24 DSP layout. Firmware versions overwhelmingly share it (V12 == V24). We
    // accept the fallback ONLY if it decodes to physically-real data (validated at the end) so a wrong
    // layout can never store garbage. Mapped versions are unaffected. Mirrors Swift PostHooks
    // "historical_data" (PostHooks.swift). (#30 / #77)
    val mapped = histVersionLayout(version)
    val usingFallback = mapped == null
    val layout = mapped ?: HIST_V24

    val out = LinkedHashMap<String, Any?>()
    out["hist_version"] = version

    // unix is the record's REAL unix seconds (no clock offset needed for type-47).
    frame.histU32(layout.unixOff)?.let { out["unix"] = it.toInt() }
    frame.histU8(layout.hrOff)?.let { out["heart_rate"] = it }
    val rrn = frame.histU8(layout.rrCountOff) ?: 0
    out["rr_count"] = rrn

    // Up to 4 R-R intervals (u16, ms). Drop 0 ms placeholders, matching PostHooks (`v != 0`).
    val rrVals = ArrayList<Int>()
    for (i in 0 until minOf(rrn, 4)) {
        val v = frame.histU16(layout.rrFirstOff + i * 2)
        if (v != null && v != 0) rrVals.add(v)
    }
    out["rr_intervals"] = rrVals

    // Full DSP block (V24/V12 only). Each read is guarded; absent fields are simply not emitted.
    layout.spo2RedOff?.let { off -> frame.histU16(off)?.let { out["spo2_red"] = it } }
    layout.spo2IrOff?.let { off -> frame.histU16(off)?.let { out["spo2_ir"] = it } }
    layout.skinTempRawOff?.let { off -> frame.histU16(off)?.let { out["skin_temp_raw"] = it } }
    layout.respRateRawOff?.let { off -> frame.histU16(off)?.let { out["resp_rate_raw"] = it } }
    layout.gravityXOff?.let { off -> frame.histF32(off)?.let { out["gravity_x"] = it } }
    layout.gravityYOff?.let { off -> frame.histF32(off)?.let { out["gravity_y"] = it } }
    layout.gravityZOff?.let { off -> frame.histF32(off)?.let { out["gravity_z"] = it } }

    // Validate the v24-layout guess for an unmapped version: gravity is the DSP-separated orientation
    // vector, so |gravity| ≈ 1 g on a real record regardless of motion, and HR is physiological. If the
    // guess doesn't fit this firmware the decoded values are random — drop the record rather than store
    // garbage (same outcome as before the fallback). Mapped versions skip this entirely. (#30 / #77)
    if (usingFallback) {
        val gx = (out["gravity_x"] as? Double) ?: Double.NaN
        val gy = (out["gravity_y"] as? Double) ?: Double.NaN
        val gz = (out["gravity_z"] as? Double) ?: Double.NaN
        val mag = Math.sqrt(gx * gx + gy * gy + gz * gz)
        val hr = (out["heart_rate"] as? Int) ?: 0
        if (!(mag in 0.8..1.2 && hr in 25..230)) return null
    }

    return out
}

/**
 * WHOOP 5.0/MG type-47 "v18" historical decode. The puffin envelope is longer, so the record starts at
 * byte 8 (type@8, version@9) and fields sit at their WHOOP5-ABSOLUTE offsets — NOT the WHOOP4 V24 layout
 * shifted by +4 (that decodes to garbage on v18). Offsets verified against real worn/off-wrist frames
 * (the data is the arbiter): unix@15, hr@22, rr@24+, gravity@45/49/53, and per-second fields each gated
 * to a physical range so a wrong offset on unmapped firmware stores nothing. Mirrors Swift
 * `decodeWhoop5Historical`, and emits the same keys [extractHistoricalStreams] reads. v26 (PPG) and other
 * versions aren't stored, so they return null here (skipped), matching the Swift raw-region treatment.
 */
private fun decodeWhoop5Historical(frame: ByteArray): Map<String, Any?>? {
    if (frame.histU8(8) != PacketType.HISTORICAL_DATA.rawValue) return null
    val version = frame.histU8(9) ?: return null
    if (version != 18) return null

    val out = LinkedHashMap<String, Any?>()
    out["hist_version"] = version
    frame.histU32(15)?.let { out["unix"] = it.toInt() }
    frame.histU8(22)?.let { out["heart_rate"] = it }
    val rrn = frame.histU8(23) ?: 0
    out["rr_count"] = rrn
    val rrVals = ArrayList<Int>()
    for (i in 0 until minOf(rrn, 4)) {
        val v = frame.histU16(24 + i * 2)
        if (v != null && v != 0) rrVals.add(v)
    }
    out["rr_intervals"] = rrVals
    frame.histF32(45)?.let { out["gravity_x"] = it }
    frame.histF32(49)?.let { out["gravity_y"] = it }
    frame.histF32(53)?.let { out["gravity_z"] = it }

    // Per-second fields beyond HR/gravity, each gated to a physically-real range (cross-validated
    // worn vs off-wrist). Fields the source report listed but that didn't decode consistently on this
    // firmware (cardiac_flags@33, sleep-state@81, perfusion@69/71) are deliberately not decoded.
    frame.histF32(41)?.let { if (it.isFinite() && it in 0.0..8.0) out["dynamic_acceleration"] = it }
    frame.histU16(57)?.let { out["step_motion_counter"] = it }
    frame.histU8(63)?.let { if (it in 0..2) out["motion_wear_quality"] = it }
    // skin temp: raw u16 (the store keeps it raw, /100 at display); gate on the °C being physical.
    frame.histU16(73)?.let { if ((it / 100.0) in 20.0..45.0) out["skin_temp_raw"] = it }
    return out
}

// MARK: - METADATA classification (port of HistoricalMeta.swift)

/** Classification of a METADATA frame (type 49) for the historical-offload state machine. */
sealed class HistoricalMeta {
    object Start : HistoricalMeta()

    /** HISTORY_END: [unix] = record unix seconds, [trim] = the trim cursor to ack/advance. */
    data class End(val unix: Long, val trim: Long) : HistoricalMeta()

    object Complete : HistoricalMeta()
    object Other : HistoricalMeta()
}

/**
 * Classify a parsed METADATA frame into the four cases the offload state machine needs.
 * Direct port of Swift `classifyHistoricalMeta`.
 *
 * Field mapping (whoop_protocol.json + Framing.decodeMetadata): `meta_type` is the
 * "NAME(rawValue)" enum label (e.g. "HISTORY_END(2)"); for HISTORY_END the metadata decoder
 * additionally stores `unix` and `trim_cursor`. We match by prefix so a raw-value change can't
 * break the classifier.
 *
 * Integrity gate (kept from Swift): only act on a checksum-valid frame — without it a garbled or
 * forged BLE peer could forge HISTORY_END / HISTORY_COMPLETE and advance/ack the trim cursor for
 * data we never durably stored.
 */
fun classifyHistoricalMeta(p: ParsedFrame): HistoricalMeta {
    if (!p.ok || p.crcOk == false) return HistoricalMeta.Other
    if (p.typeName != "METADATA") return HistoricalMeta.Other
    val metaName = p.parsed["meta_type"] as? String ?: return HistoricalMeta.Other
    return when {
        metaName.startsWith("HISTORY_START") -> HistoricalMeta.Start
        metaName.startsWith("HISTORY_COMPLETE") -> HistoricalMeta.Complete
        metaName.startsWith("HISTORY_END") -> {
            val unix = p.parsed.intOrNull("unix")
            val trim = p.parsed.intOrNull("trim_cursor")
            if (unix == null || trim == null) HistoricalMeta.Other
            // u32-on-the-wire; the Int values were already truncated to 32 bits on decode. Carry as
            // Long (unsigned-safe) so a value past 2^31 doesn't surface as negative downstream.
            else HistoricalMeta.End(unix = unix.toLong() and 0xFFFFFFFFL, trim = trim.toLong() and 0xFFFFFFFFL)
        }
        else -> HistoricalMeta.Other
    }
}

// MARK: - Historical extraction (port of HistoricalStreams.swift extractHistoricalStreams)

/**
 * Turn a batch of parsed offload frames into a [StreamBatch] of datastore rows. Direct port of
 * Swift `extractHistoricalStreams`.
 *
 * HR/R-R/SpO2/skinTemp/resp/gravity come from type-47 HISTORICAL_DATA records, each of which
 * carries its OWN real unix timestamp — so NO wall-clock offset is applied to them (the
 * [deviceClockRef]/[wallClockRef] args exist only for the REALTIME_RAW_DATA fallback below and to
 * mirror the Swift signature). EVENT timestamps are real RTC unix seconds (already wall-clock).
 * CRC-failed / non-ok frames are skipped.
 *
 * [rawFrames] are the verbatim BLE frames for this chunk; [decodeHistorical] re-validates + decodes
 * each. We take the frames (not pre-parsed records) because the live [Framing.parseFrame] doesn't
 * populate type-47 fields — the type-47 record is decoded here by [decodeHistorical].
 */
fun extractHistoricalStreams(
    rawFrames: List<ByteArray>,
    deviceClockRef: Int,
    wallClockRef: Int,
    family: DeviceFamily = DeviceFamily.WHOOP4,
): StreamBatch {
    fun wall(deviceTs: Int?): Int? = if (deviceTs == null) null else wallClockRef + (deviceTs - deviceClockRef)

    // FIX #72: type-47 `unix` and EVENT `event_timestamp` are the strap RTC's own real-unix seconds.
    // When the strap RTC is grossly stale (it sat unused for months, so its clock is months behind) those
    // land far in the past — live HR works but all offloaded history is misdated. Correct them by the
    // (wall - device) clock offset, but ONLY when grossly stale, and SNAPPED to a 5-min grid so the SAME
    // record re-syncs to the SAME corrected ts (offloaded rows dedupe by (deviceId, ts); an un-snapped,
    // slightly-different offset on re-sync would duplicate every row). A normal/identity clockRef has
    // offset ~0 (< threshold) → rawTs unchanged (current behavior).
    val staleThreshold = 86_400          // 1 day
    val snapGranularity = 300            // 5 min
    val clockOffset = wallClockRef - deviceClockRef
    fun correctedWall(rawTs: Long): Long {
        if (kotlin.math.abs(clockOffset) <= staleThreshold) return rawTs
        val snapped = (if (clockOffset >= 0) clockOffset + snapGranularity / 2
                       else clockOffset - snapGranularity / 2) / snapGranularity * snapGranularity
        return rawTs + snapped.toLong()
    }

    val hr = ArrayList<HrRow>()
    val rr = ArrayList<RrRow>()
    val spo2 = ArrayList<Spo2Row>()
    val skinTemp = ArrayList<SkinTempRow>()
    val steps = ArrayList<StepRow>()
    val resp = ArrayList<RespRow>()
    val gravity = ArrayList<GravityRow>()
    val events = ArrayList<EventEntry>()
    val battery = ArrayList<BatteryRow>()

    for (frame in rawFrames) {
        // Packet type byte: WHOOP 5/MG's longer puffin envelope puts it at frame[8]; WHOOP 4 at frame[4].
        val t = if (family == DeviceFamily.WHOOP5) (frame.histU8(8) ?: -1)
                else if (frame.size > 4) frame[4].toInt() and 0xFF else -1
        when (t) {
            PacketType.HISTORICAL_DATA.rawValue -> {
                // type-47 carries the strap RTC's real-unix seconds. Correct for a grossly-stale RTC
                // (FIX #72); a normal strap is unchanged (offset < threshold).
                val p = decodeHistorical(frame, family) ?: continue
                val ts = (p.intOrNull("unix")?.toLong())?.let { correctedWall(it) } ?: continue

                // skip startup hr=0 (matches Swift `bpm != 0`).
                p.intOrNull("heart_rate")?.let { bpm -> if (bpm != 0) hr.add(HrRow(ts, bpm)) }

                @Suppress("UNCHECKED_CAST")
                (p["rr_intervals"] as? List<Int>)?.forEach { rrMs -> rr.add(RrRow(ts, rrMs)) }

                p.intOrNull("spo2_red")?.let { red ->
                    spo2.add(Spo2Row(ts, red = red, ir = p.intOrNull("spo2_ir") ?: 0))
                }
                p.intOrNull("skin_temp_raw")?.let { raw -> skinTemp.add(SkinTempRow(ts, raw)) }
                // step_motion_counter@57 is the WHOOP5 CUMULATIVE u16 counter (decoded but, until now,
                // dropped). Stored raw; AnalyticsEngine derives the daily step total from counter deltas.
                // APPROXIMATE — @57 semantics unverified vs the official app (see decodeWhoop5Historical). (#78)
                p.intOrNull("step_motion_counter")?.let { c -> steps.add(StepRow(ts, c)) }
                p.intOrNull("resp_rate_raw")?.let { raw -> resp.add(RespRow(ts, raw)) }
                p.doubleOrNull("gravity_x")?.let { gx ->
                    gravity.add(
                        GravityRow(
                            ts,
                            x = gx,
                            y = p.doubleOrNull("gravity_y") ?: 0.0,
                            z = p.doubleOrNull("gravity_z") ?: 0.0,
                        ),
                    )
                }
            }

            PacketType.REALTIME_RAW_DATA.rawValue -> {
                // Fallback (rare during a plain type-47 offload): HR/RR off the type-43 header. Its
                // timestamp is a device-epoch value, so it DOES get the wall-clock offset. The live
                // Framing decoder doesn't decode type-43 biometrics, so re-parse via parseFrame and
                // read whatever timestamp/HR/RR it surfaced (typically none on this firmware).
                val parsed = Framing.parseFrame(frame, family)
                if (!parsed.ok || parsed.crcOk == false) continue
                val ts = wall(parsed.parsed.intOrNull("timestamp")) ?: continue
                parsed.parsed.intOrNull("heart_rate")?.let { bpm -> hr.add(HrRow(ts.toLong(), bpm)) }
                @Suppress("UNCHECKED_CAST")
                (parsed.parsed["rr_intervals"] as? List<Int>)?.forEach { rrMs ->
                    rr.add(RrRow(ts.toLong(), rrMs))
                }
            }

            PacketType.EVENT.rawValue -> {
                // EVENT carries the strap RTC's real-unix seconds. Correct for a grossly-stale RTC
                // (FIX #72); a normal strap is unchanged. Port of the Swift `case "EVENT"` branch:
                // persist the event (with battery extracted for BATTERY_LEVEL) so offloaded
                // wrist/charge/battery events aren't lost. During a backfill the live path is
                // suppressed, so the offload extractor MUST handle these.
                val parsed = Framing.parseFrame(frame, family)
                if (!parsed.ok || parsed.crcOk == false) continue
                val ts = (parsed.parsed.intOrNull("event_timestamp")?.toLong())?.let { correctedWall(it) } ?: continue
                val kind = (parsed.parsed["event"] as? String) ?: ""
                if (kind.startsWith("BATTERY_LEVEL")) appendHistBattery(battery, ts, parsed.parsed)
                val payload = LinkedHashMap(parsed.parsed)
                payload.remove("event")
                payload.remove("event_timestamp")
                events.add(EventEntry(ts, kind, StreamPersistence.encodePayload(payload)))
            }

            PacketType.COMMAND_RESPONSE.rawValue -> {
                // No device timestamp on COMMAND_RESPONSE → stamp battery at wallClockRef (Swift parity).
                val parsed = Framing.parseFrame(frame, family)
                if (!parsed.ok || parsed.crcOk == false) continue
                appendHistBattery(battery, wallClockRef.toLong(), parsed.parsed)
            }

            else -> Unit
        }
    }

    return StreamBatch(
        hr = hr, rr = rr, events = events, battery = battery,
        spo2 = spo2, skinTemp = skinTemp, resp = resp, gravity = gravity, steps = steps,
    )
}

/**
 * Append a [BatteryRow] from a parsed frame's `battery_pct`/`battery_mV`/`battery_charging` fields
 * (no-op when neither soc nor mv is present). Mirrors the live-path `appendBattery` in Streams.kt
 * (kept local here to avoid widening that internal helper's surface).
 */
private fun appendHistBattery(out: MutableList<BatteryRow>, ts: Long, p: Map<String, Any?>) {
    val soc = p.doubleOrNull("battery_pct")
    val mv = p.intOrNull("battery_mV")
    if (soc == null && mv == null) return
    val charging = p.intOrNull("battery_charging")?.let { it != 0 }
    out.add(BatteryRow(ts = ts, soc = soc, mv = mv, charging = charging))
}
