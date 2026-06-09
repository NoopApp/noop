package com.noop.ui

import android.Manifest
import android.content.pm.PackageManager
import android.os.Build
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.platform.LocalContext
import androidx.core.content.ContextCompat

/**
 * The runtime permissions a BLE scan needs on this OS version. Android 12+ (API 31) uses the
 * granular Bluetooth permissions; API <= 30 falls back to fine location, which the platform
 * requires before it will hand back BLE scan results.
 */
fun blePermissions(): Array<String> =
    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S)
        arrayOf(Manifest.permission.BLUETOOTH_SCAN, Manifest.permission.BLUETOOTH_CONNECT)
    else
        arrayOf(Manifest.permission.ACCESS_FINE_LOCATION)

/**
 * Returns a callback that starts a scan, first requesting the runtime Bluetooth permission if it
 * isn't already granted. This is the single source of truth for "tap a button → scan" across the
 * app (Live, Settings, onboarding), so no screen can forget the gate.
 *
 * Why this exists (issue #1): a button that calls `vm.connect()` directly silently no-ops on
 * Android 12+ when the permission was denied or revoked — `startScan()` throws SecurityException,
 * the BLE layer swallows it into a status note, and no prompt is ever shown. The user taps and
 * nothing happens (the exact Pixel 9 report). Requesting the permission *before* connecting fixes
 * that. On grant the launcher calls [onGranted]; on denial, connect() still surfaces the explanatory
 * status note rather than failing silently.
 *
 * This belongs in the Compose layer, not the ViewModel: only an Activity-scoped launcher can raise
 * the system permission dialog. The ViewModel has no launcher and would just re-introduce the
 * silent no-op.
 */
@Composable
fun rememberRequestScan(onGranted: () -> Unit): () -> Unit {
    val context = LocalContext.current
    val perms = remember { blePermissions() }
    val launcher = rememberLauncherForActivityResult(
        ActivityResultContracts.RequestMultiplePermissions(),
    ) { onGranted() }
    return {
        val granted = perms.all {
            ContextCompat.checkSelfPermission(context, it) == PackageManager.PERMISSION_GRANTED
        }
        if (granted) onGranted() else launcher.launch(perms)
    }
}
