package com.noop.ui

import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * Pins the Workouts "Src" column badge to the real stored origins. The bug (#53): Health Connect
 * workouts showed the "Apple" pill because the badge was a binary `isWhoop ? "Whoop" : "Apple"`.
 * These cases mirror exactly what the importers write:
 *   - WhoopCsvImporter      → deviceId/source "my-whoop"
 *   - AppleHealthImporter   → deviceId "apple-health", source "Apple Health"
 *   - HealthConnectImporter → deviceId/source "health-connect"
 */
class WorkoutSourceLabelTest {

    @Test
    fun whoop_isLabelledWhoop() {
        assertEquals("Whoop", workoutSourceLabel("my-whoop", "my-whoop"))
    }

    @Test
    fun appleHealth_isLabelledApple() {
        // deviceId "apple-health" with the human label "Apple Health" — must NOT fall through to HC.
        assertEquals("Apple", workoutSourceLabel("apple-health", "Apple Health"))
    }

    @Test
    fun healthConnect_isLabelledHC_notApple() {
        // The regression under test: this used to come back "Apple".
        assertEquals("HC", workoutSourceLabel("health-connect", "health-connect"))
    }

    @Test
    fun unknownSource_fallsBackToApple() {
        assertEquals("Apple", workoutSourceLabel("", ""))
    }
}
