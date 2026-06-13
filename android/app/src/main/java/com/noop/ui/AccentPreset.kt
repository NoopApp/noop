package com.noop.ui

import androidx.compose.ui.graphics.Color

/**
 * User-selectable accent colors — the app's interactive *chrome* only (buttons, focus, selection,
 * links). Data/semantic colors (recovery, strain, sleep stages, HR zones, status) are intentionally
 * NOT user-configurable: recoloring e.g. the recovery gradient's green would break its red→green
 * "bad→good" meaning.
 *
 * A curated, fixed set rather than a free picker so every choice stays legible on the near-black
 * [Palette.surfaceBase] (#060A08); a free RGB picker would let a user pick a low-contrast accent and
 * make the UI unreadable. `id` is the stable persistence key (see [AccentStore]); never renumber it.
 */
enum class AccentPreset(val id: String, val displayName: String, val color: Color) {
    GREEN("green", "Health green", Color(0xFF18C98B)),   // default — the original brand accent
    CYAN("cyan", "Cyan", Color(0xFF29C2E8)),
    BLUE("blue", "Blue", Color(0xFF4C8DFF)),
    VIOLET("violet", "Violet", Color(0xFF9B7BFF)),
    MAGENTA("magenta", "Magenta", Color(0xFFE85CC8)),
    CORAL("coral", "Coral", Color(0xFFFF7A4D));

    companion object {
        val default = GREEN

        /** Resolve a stored id back to a preset; unknown/missing ids fall back to [default]. */
        fun fromId(id: String?): AccentPreset = values().firstOrNull { it.id == id } ?: default
    }
}
