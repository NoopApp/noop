package com.noop.ui

import android.content.Context

/**
 * Persists the user's chosen [AccentPreset]. Plain (unencrypted) SharedPreferences — a color choice
 * isn't sensitive, unlike the AI key in AiKeyStore. Read synchronously at launch so the theme is
 * correct from the first frame (see [apply]).
 */
object AccentStore {
    private const val FILE_NAME = "noop_appearance_prefs"
    private const val KEY_ACCENT = "accent_preset_id"

    private fun prefs(ctx: Context) =
        ctx.applicationContext.getSharedPreferences(FILE_NAME, Context.MODE_PRIVATE)

    /** The saved accent, or [AccentPreset.default] if none/invalid. */
    fun load(ctx: Context): AccentPreset = AccentPreset.fromId(prefs(ctx).getString(KEY_ACCENT, null))

    fun save(ctx: Context, preset: AccentPreset) {
        prefs(ctx).edit().putString(KEY_ACCENT, preset.id).apply()
    }

    /**
     * Apply the saved accent to the live [Palette]. Call BEFORE `setContent` so the very first
     * composition already uses the chosen color (no green flash on launch).
     */
    fun apply(ctx: Context) {
        Palette.accent = load(ctx).color
    }
}
