package com.noop

import android.app.Application
import com.noop.ble.WhoopBleClient
import com.noop.data.WhoopDatabase
import com.noop.data.WhoopRepository
import com.noop.ui.NoopPrefs

/**
 * Application entry point.
 *
 * NOOP is a fully on-device WHOOP companion: it connects to the strap over BLE and persists
 * everything locally via Room. There is no network layer (the opt-in AI Coach aside).
 *
 * The data layer ([WhoopRepository]) and the BLE client ([WhoopBleClient]) are owned **here**, at the
 * process level, rather than by the Activity-scoped AppViewModel. That is what lets a connection keep
 * streaming when the app is backgrounded or closed: [com.noop.ble.WhoopConnectionService] holds the
 * process up with a foreground notification, and both it and the UI share this one BLE client. The
 * macOS app gets the same outcome for free — its `AppModel` is an app-level `@StateObject` kept alive
 * by the menu-bar extra.
 */
class NoopApplication : Application() {

    /** Process-wide Room-backed store. One instance shared by the UI and the background service. */
    val repository: WhoopRepository by lazy {
        WhoopRepository(WhoopDatabase.get(this).whoopDao())
    }

    /** Process-wide BLE client. Owns the GATT connection and outlives any single Activity/ViewModel. */
    val ble: WhoopBleClient by lazy {
        WhoopBleClient(applicationContext, repository = repository).apply {
            // Apply the persisted "Debug logging" preference at the composition root so the low-level
            // client never has to read the UI/prefs layer. Default OFF — see WhoopBleClient.debugLogcat.
            debugLogcat = NoopPrefs.debugLogging(applicationContext)
        }
    }
}
