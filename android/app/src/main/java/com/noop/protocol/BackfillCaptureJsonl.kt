package com.noop.protocol

data class BackfillCaptureRecord(
    val capturedAtMs: Long,
    val sessionId: String,
    val characteristic: String,
    val typeName: String,
    val crcOk: Boolean?,
    val offload: Boolean,
    val size: Int,
    val parsed: Map<String, Any?>,
    val hex: String,
)

object BackfillCaptureJsonl {
    fun encode(record: BackfillCaptureRecord): String =
        buildString {
            append('{')
            appendField("captured_at_ms", record.capturedAtMs)
            append(',')
            appendField("session_id", record.sessionId)
            append(',')
            appendField("characteristic", record.characteristic)
            append(',')
            appendField("type_name", record.typeName)
            append(',')
            appendField("crc_ok", record.crcOk)
            append(',')
            appendField("offload", record.offload)
            append(',')
            appendField("size", record.size)
            append(',')
            appendQuoted("parsed")
            append(':')
            appendJsonValue(record.parsed)
            append(',')
            appendField("hex", record.hex)
            append('}')
        }

    private fun StringBuilder.appendField(name: String, value: Any?) {
        appendQuoted(name)
        append(':')
        appendJsonValue(value)
    }

    private fun StringBuilder.appendJsonValue(value: Any?) {
        when (value) {
            null -> append("null")
            is Boolean -> append(value)
            is Number -> append(value)
            is Map<*, *> -> {
                append('{')
                value.entries
                    .sortedBy { it.key.toString() }
                    .forEachIndexed { index, entry ->
                        if (index > 0) append(',')
                        appendQuoted(entry.key.toString())
                        append(':')
                        appendJsonValue(entry.value)
                    }
                append('}')
            }
            is Iterable<*> -> {
                append('[')
                value.forEachIndexed { index, item ->
                    if (index > 0) append(',')
                    appendJsonValue(item)
                }
                append(']')
            }
            is IntArray -> appendJsonValue(value.asIterable())
            is LongArray -> appendJsonValue(value.asIterable())
            is DoubleArray -> appendJsonValue(value.asIterable())
            is BooleanArray -> appendJsonValue(value.asIterable())
            else -> appendQuoted(value.toString())
        }
    }

    private fun StringBuilder.appendQuoted(value: String) {
        append('"')
        for (ch in value) {
            when (ch) {
                '\\' -> append("\\\\")
                '"' -> append("\\\"")
                '\n' -> append("\\n")
                '\r' -> append("\\r")
                '\t' -> append("\\t")
                else -> {
                    if (ch.code < 0x20) {
                        append("\\u")
                        append(ch.code.toString(16).padStart(4, '0'))
                    } else {
                        append(ch)
                    }
                }
            }
        }
        append('"')
    }
}
