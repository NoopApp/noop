package com.noop.ble

import android.content.Context
import android.content.SharedPreferences

/**
 * Opt-in switch for the EXPERIMENTAL WHOOP 5.0/MG ("puffin") protocol probes.
 *
 * Direct port of the macOS `PuffinExperiment` (Strand/BLE/PuffinExperiment.swift). Live HR on a
 * 5/MG strap already works over the standard profile after CLIENT_HELLO. These probes go further —
 * sending puffin-framed commands (e.g. asking the strap to start its realtime stream) to learn what
 * a real 5/MG strap responds to. They are guesses, so they are OFF by default and only ever written
 * to the puffin command characteristic (fd4b0002). A 5/MG owner can flip this on under Settings →
 * Experimental to help map the protocol; everyone else is unaffected. It never touches WHOOP 4.0.
 *
 * The macOS app stored this in `UserDefaults` under the key `noopPuffinExperiments`; the Android
 * equivalent is [SharedPreferences]. The same key name is reused for parity.
 */
class PuffinExperiment(private val prefs: SharedPreferences) {

    /** True if the user opted in to the WHOOP 5/MG protocol probes (default false). */
    var isEnabled: Boolean
        get() = prefs.getBoolean(KEY, false)
        set(v) = prefs.edit().putBoolean(KEY, v).apply()

    /** True if the user opted in to recording raw 5/MG backfill frames to a shareable JSONL file
     *  (default false). SEPARATE from [isEnabled]: probes SEND commands at the strap; capture only
     *  RECORDS what arrives — different risk profiles, so different switches. (#78 fork) */
    var isCaptureEnabled: Boolean
        get() = prefs.getBoolean(KEY_CAPTURE, false)
        set(v) = prefs.edit().putBoolean(KEY_CAPTURE, v).apply()

    /** True if the user opted in to the WHOOP 5/MG "R22" deep-data unlock — the one probe that WRITES
     *  a persistent feature flag to the strap (the `enable_r22_*` SET_CONFIG sequence). Kept distinct
     *  from [isEnabled] because it changes strap state; reversible, default false. Mirrors the macOS
     *  `PuffinExperiment.deepDataKey`. Driven only from `WhoopBleClient.enableWhoop5DeepData()`. (#174) */
    var isDeepDataEnabled: Boolean
        get() = prefs.getBoolean(KEY_DEEP_DATA, false)
        set(v) = prefs.edit().putBoolean(KEY_DEEP_DATA, v).apply()

    /** True if the user opted in to "Broadcast heart rate": NOOP writes the device-config flag
     *  whoop_live_hr_in_adv_ind_pkt="1" so the strap advertises the standard Heart Rate Service
     *  (0x180D) + its live HR, pairable by a Garmin/Zwift/gym HR client. Reversible. Default false. */
    var broadcastHr: Boolean
        get() = prefs.getBoolean(KEY_BROADCAST_HR, false)
        set(v) = prefs.edit().putBoolean(KEY_BROADCAST_HR, v).apply()

    companion object {
        /** Persisted preferences file. */
        private const val PREFS = "noop_experiments"

        /** Shared key name with the macOS build (`PuffinExperiment.defaultsKey`). */
        const val KEY = "noopPuffinExperiments"

        /** 5/MG raw backfill capture (research aid for the puffin biometric decode). */
        const val KEY_CAPTURE = "noopWhoop5Capture"

        /** 5/MG R22 deep-data unlock opt-in (mirrors macOS `PuffinExperiment.deepDataKey`). */
        const val KEY_DEEP_DATA = "noopWhoop5DeepData"

        /** "Broadcast heart rate" opt-in (writes whoop_live_hr_in_adv_ind_pkt). */
        const val KEY_BROADCAST_HR = "noopBroadcastHr"

        fun from(context: Context): PuffinExperiment =
            PuffinExperiment(context.getSharedPreferences(PREFS, Context.MODE_PRIVATE))
    }
}
