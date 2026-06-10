package com.noop.ui

import android.content.Context
import android.content.Intent
import android.os.Build
import android.widget.Toast
import androidx.core.content.FileProvider
import com.noop.BuildConfig
import java.io.File

/**
 * Shares the strap connection log as a plain-text file so users can attach it to a bug report.
 *
 * Android's `Log.d` output isn't reachable without adb, which is why people on issues #17/#18
 * couldn't share what was happening on their strap. [com.noop.ble.WhoopBleClient] now keeps an
 * in-memory ring buffer (`exportLogText()`); this writes it to a cache file and fires a share sheet.
 */
object LogExport {

    fun shareStrapLog(context: Context, logText: String) {
        runCatching {
            val header = buildString {
                appendLine("NOOP strap log")
                appendLine("App:     ${BuildConfig.VERSION_NAME} (${BuildConfig.TIER})")
                appendLine("Android: ${Build.VERSION.RELEASE} (SDK ${Build.VERSION.SDK_INT})")
                appendLine("Device:  ${Build.MANUFACTURER} ${Build.MODEL}")
                appendLine("─".repeat(40))
            }
            val body = logText.ifBlank { "(strap log is empty — connect to your strap, reproduce the issue, then share again)" }

            val dir = File(context.cacheDir, "logs").apply { mkdirs() }
            val file = File(dir, "noop-strap-log.txt")
            file.writeText(header + "\n" + body)

            val uri = FileProvider.getUriForFile(context, "${context.packageName}.fileprovider", file)
            val send = Intent(Intent.ACTION_SEND).apply {
                type = "text/plain"
                putExtra(Intent.EXTRA_STREAM, uri)
                putExtra(Intent.EXTRA_SUBJECT, "NOOP strap log")
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            }
            context.startActivity(Intent.createChooser(send, "Share strap log"))
        }.onFailure {
            Toast.makeText(context, "Couldn't share the log: ${it.message}", Toast.LENGTH_LONG).show()
        }
    }

    /**
     * Shares the opt-in 5/MG raw backfill capture (JSONL of every frame from history syncs) for the
     * puffin biometric decode effort (#78). Copies filesDir → cache (the FileProvider path already
     * covers cache/logs) and prepends a header with an informed-consent line: the file holds raw
     * biometric frames and the strap's own console text.
     */
    fun shareWhoop5Capture(context: Context) {
        runCatching {
            val main = File(context.filesDir, com.noop.ble.WhoopBleClient.WHOOP5_CAPTURE_FILE)
            val prev = File(context.filesDir, "${com.noop.ble.WhoopBleClient.WHOOP5_CAPTURE_FILE}.1")
            if (!main.exists() && !prev.exists()) {
                Toast.makeText(
                    context,
                    "No capture yet — turn on \"Record 5/MG raw capture\", let a history sync run, then share again.",
                    Toast.LENGTH_LONG,
                ).show()
                return
            }
            val header = buildString {
                appendLine("# NOOP 5/MG raw backfill capture (JSONL; one frame per line)")
                appendLine("# App: ${BuildConfig.VERSION_NAME} (${BuildConfig.TIER}) · Android ${Build.VERSION.RELEASE} (SDK ${Build.VERSION.SDK_INT}) · ${Build.MANUFACTURER} ${Build.MODEL}")
                appendLine("# NOTE: contains raw biometric frames (heart rate, R-R, skin temp, motion) and the strap's console text — share only if you're comfortable with that.")
            }
            val dir = File(context.cacheDir, "logs").apply { mkdirs() }
            val out = File(dir, "noop-whoop5-capture.jsonl")
            out.outputStream().bufferedWriter().use { w ->
                w.write(header)
                // Oldest first: previous generation (if rotated), then the live file.
                for (f in listOf(prev, main)) if (f.exists()) f.bufferedReader().use { r -> r.copyTo(w) }
            }
            val uri = FileProvider.getUriForFile(context, "${context.packageName}.fileprovider", out)
            val send = Intent(Intent.ACTION_SEND).apply {
                type = "text/plain"
                putExtra(Intent.EXTRA_STREAM, uri)
                putExtra(Intent.EXTRA_SUBJECT, "NOOP 5/MG protocol capture")
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            }
            context.startActivity(Intent.createChooser(send, "Share 5/MG capture"))
        }.onFailure {
            Toast.makeText(context, "Couldn't share the capture: ${it.message}", Toast.LENGTH_LONG).show()
        }
    }
}
