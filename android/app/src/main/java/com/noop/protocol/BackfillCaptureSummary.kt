package com.noop.protocol

class BackfillCaptureSummary(
    private val maxUnknownSamples: Int = 20,
) {
    private data class UnknownSample(
        val typeName: String,
        val crcOk: Boolean?,
        val size: Int,
        val characteristic: String,
        val hex: String,
    )

    private val counts = linkedMapOf<String, Int>()
    private val unknownSamples = ArrayList<UnknownSample>()

    fun record(typeName: String, crcOk: Boolean?, size: Int, characteristic: String, hex: String) {
        counts[typeName] = (counts[typeName] ?: 0) + 1
        if (unknownSamples.size < maxUnknownSamples && isUnknownType(typeName)) {
            unknownSamples += UnknownSample(typeName, crcOk, size, characteristic, hex)
        }
    }

    fun countsText(): String =
        if (counts.isEmpty()) {
            "none"
        } else {
            counts.entries
                .sortedBy { it.key }
                .joinToString(", ") { (type, count) -> "$type=$count" }
        }

    fun unknownSamplesText(): String =
        if (unknownSamples.isEmpty()) {
            "none"
        } else {
            unknownSamples.joinToString("; ") {
                "${it.typeName}(size=${it.size},char=${it.characteristic},crc=${it.crcOk},hex=${it.hex})"
            }
        }

    fun reset() {
        counts.clear()
        unknownSamples.clear()
    }

    private fun isUnknownType(typeName: String): Boolean = typeName.startsWith("type")
}
