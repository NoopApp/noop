package com.noop.ui

import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * Pins [AccentPreset] id resolution — the contract NoopPrefs relies on to persist/restore the
 * user's accent. A stored id must round-trip, and an unknown/missing id (older install, corrupted
 * pref) must fall back to the default rather than crash or blank the accent.
 */
class AccentPresetTest {

    @Test fun unknownOrMissingIdFallsBackToDefault() {
        assertEquals(AccentPreset.default, AccentPreset.fromId(null))
        assertEquals(AccentPreset.default, AccentPreset.fromId(""))
        assertEquals(AccentPreset.default, AccentPreset.fromId("not-a-real-id"))
    }

    @Test fun everyPresetIdRoundTrips() {
        for (preset in AccentPreset.values()) {
            assertEquals(preset, AccentPreset.fromId(preset.id))
        }
    }

    @Test fun idsAreUniqueAndDefaultIsGreen() {
        val ids = AccentPreset.values().map { it.id }
        assertEquals("preset ids must be unique (they are persistence keys)", ids.size, ids.toSet().size)
        assertEquals(AccentPreset.GREEN, AccentPreset.default)
    }
}
