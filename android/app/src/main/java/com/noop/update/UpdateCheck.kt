package com.noop.update

import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import org.json.JSONObject
import java.net.HttpURLConnection
import java.net.URL

/**
 * User-initiated "Check for updates": a single call to GitHub's PUBLIC releases API that reads the
 * latest version and compares it to the installed one. It runs ONLY when the user taps the button —
 * there is no background polling and no auto-update. Nothing about the user is sent; it just reads a
 * version number. (Android already holds INTERNET for the opt-in AI Coach, so this adds no new
 * capability.)
 */
object UpdateCheck {

    private const val ENDPOINT = "https://api.github.com/repos/NoopApp/noop/releases/latest"

    sealed interface Result {
        data class UpToDate(val version: String) : Result
        data class Available(val version: String, val url: String, val notes: String) : Result
        object Failed : Result
    }

    /** Fetch the latest release and classify it against [currentVersion]. Never throws — any error
     *  (offline, rate-limited, malformed) resolves to [Result.Failed] so the caller shows a calm
     *  "try again" rather than crashing. */
    suspend fun check(currentVersion: String): Result = withContext(Dispatchers.IO) {
        runCatching {
            val conn = (URL(ENDPOINT).openConnection() as HttpURLConnection).apply {
                connectTimeout = 12_000
                readTimeout = 12_000
                setRequestProperty("Accept", "application/vnd.github+json")
            }
            try {
                if (conn.responseCode != 200) return@runCatching Result.Failed
                val json = JSONObject(conn.inputStream.bufferedReader().use { it.readText() })
                val latest = json.getString("tag_name").removePrefix("v")
                val url = json.getString("html_url")
                val notes = cleanNotes(json.optString("body", ""))
                if (isNewer(latest, currentVersion)) Result.Available(latest, url, notes)
                else Result.UpToDate(latest)
            } finally {
                conn.disconnect()
            }
        }.getOrDefault(Result.Failed)
    }

    /**
     * True iff [latest] is a strictly newer version than [current]. Compares dot-separated numeric
     * segments left to right — so `1.40 > 1.39` and `1.9 < 1.10`, both of which a plain string compare
     * gets WRONG. Tolerant of a leading "v" and any non-numeric suffix (e.g. the demo flavour's
     * "1.39-demo", or build metadata). Pure + unit-tested.
     */
    fun isNewer(latest: String, current: String): Boolean {
        val a = segments(latest)
        val b = segments(current)
        for (i in 0 until maxOf(a.size, b.size)) {
            val x = a.getOrElse(i) { 0 }
            val y = b.getOrElse(i) { 0 }
            if (x != y) return x > y
        }
        return false
    }

    private fun segments(s: String): List<Int> =
        s.trim().removePrefix("v").removePrefix("V")
            .takeWhile { it.isDigit() || it == '.' }   // stop at "-demo" / build metadata
            .split(".")
            .mapNotNull { it.toIntOrNull() }

    /** Turn a GitHub release body into a short, readable "what's new" for an inline preview: drop the
     *  "Downloads"/footer boilerplate, strip the heaviest markdown markers, and cap the length. */
    fun cleanNotes(body: String): String {
        var s = body.substringBefore("Downloads")
        for (marker in listOf("**", "## ", "# ")) s = s.replace(marker, "")
        s = s.trim()
        return if (s.length > 700) s.take(700).trim() + "…" else s
    }
}
