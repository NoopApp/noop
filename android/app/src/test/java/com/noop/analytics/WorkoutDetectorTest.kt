package com.noop.analytics

import com.noop.data.GravitySample
import com.noop.data.HrSample
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Parity tests for the Kotlin [WorkoutDetector] — mirrors the sustained-effort
 * fragmentation regression in StrandAnalytics/WorkoutDetectorTests.swift (#303).
 */
class WorkoutDetectorTest {

    private val dev = "test-device"

    private fun hr(ts: Long, bpm: Int) = HrSample(deviceId = dev, ts = ts, bpm = bpm)
    private fun grav(ts: Long, x: Double) =
        GravitySample(deviceId = dev, ts = ts, x = x, y = 0.0, z = 1.0)

    /**
     * A long endurance bout that dips below the motion gate every few minutes
     * (coasting / junction / sensor gap) while HR stays elevated. Returns a full day
     * with the ride embedded in rest.
     */
    private fun longRideWithDips(
        rideStart: Long,
        rideDur: Long,
        cadenceS: Long,
        dipS: Long,
    ): Pair<List<HrSample>, List<GravitySample>> {
        val hrList = ArrayList<HrSample>()
        val gravList = ArrayList<GravitySample>()
        val dayStart = rideStart - 30 * 60
        val dayEnd = rideStart + rideDur + 30 * 60
        var t = dayStart
        while (t < dayEnd) {
            val inRide = t >= rideStart && t < rideStart + rideDur
            val phaseInCycle = (t - rideStart).mod(cadenceS)
            val coasting = inRide && phaseInCycle >= cadenceS - dipS
            hrList.add(hr(t, if (inRide) 150 else 52))
            if (inRide && !coasting) {
                val osc = ((t - rideStart).mod(2L)).toDouble() * 0.5
                gravList.add(grav(t, osc))
            } else {
                gravList.add(grav(t, 0.0))
            }
            t += 1
        }
        return hrList to gravList
    }

    @Test fun longRideWithBriefDips_isOneWorkout() {
        // ~4 h ride (issue: 13:00–16:52) with a ~3-min coasting dip every ~8 min. Each
        // dip exceeds the OLD 150 s merge gap, so the ride used to shatter into ~30
        // sub-5-min slivers, most then dropped — surfacing as a few tiny "workouts".
        val start = 9_000_000L
        val rideDur = 232L * 60 // 3 h 52 m
        val (hrList, gravList) = longRideWithDips(
            rideStart = start, rideDur = rideDur, cadenceS = 8L * 60, dipS = 180L,
        )
        val sessions = WorkoutDetector.detect(hr = hrList, gravity = gravList, age = 30.0)

        assertEquals("sustained ride fragmented into ${sessions.size} workouts", 1, sessions.size)
        val w = sessions[0]
        assertTrue(
            "merged ride too short: ${w.durationS.toInt()}s of ${rideDur}s",
            w.durationS > rideDur.toDouble() * 0.9,
        )
        assertEquals(150.0, w.avgHR, 2.0)
    }

    @Test fun genuinelySeparateWorkouts_staySeparate() {
        // Two real workouts separated by a long genuine rest (HR to resting, motion
        // stops) for ~25 min must NOT be merged by the bridge.
        val startA = 10_000_000L
        val durA = 20L * 60
        val restGap = 25L * 60
        val startB = startA + durA + restGap
        val durB = 20L * 60
        val hrList = ArrayList<HrSample>()
        val gravList = ArrayList<GravitySample>()
        val dayStart = startA - 30 * 60
        val dayEnd = startB + durB + 30 * 60
        var t = dayStart
        while (t < dayEnd) {
            val inA = t >= startA && t < startA + durA
            val inB = t >= startB && t < startB + durB
            val active = inA || inB
            hrList.add(hr(t, if (active) 160 else 52))
            if (active) {
                val osc = (t.mod(2L)).toDouble() * 0.5
                gravList.add(grav(t, osc))
            } else {
                gravList.add(grav(t, 0.0))
            }
            t += 1
        }
        val sessions = WorkoutDetector.detect(hr = hrList, gravity = gravList, age = 30.0)
        assertEquals("separate workouts were over-merged", 2, sessions.size)
    }
}
