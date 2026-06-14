package com.noop.location

import com.noop.analytics.RouteMath.LatLng
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class TrackFilterTest {
    private fun fix(lat: Double, lon: Double, acc: Float, tMs: Long) = RawFix(lat, lon, acc, tMs)

    @Test fun firstGoodFix_accepted() {
        val f = TrackFilter()
        assertEquals(LatLng(51.50, -0.12), f.accept(fix(51.50, -0.12, 8f, 0)))
    }

    @Test fun poorAccuracy_rejected() {
        val f = TrackFilter()
        assertNull(f.accept(fix(51.50, -0.12, 60f, 0))) // > 50 m accuracy gate
    }

    @Test fun moderateAccuracy_accepted() {
        // 40 m fixes are typical on a weak-signal run; the old 30 m gate dropped these, collapsing the
        // route to a couple of points (#324). They must now be accepted (still under the 50 m gate).
        val f = TrackFilter()
        assertEquals(LatLng(51.50, -0.12), f.accept(fix(51.50, -0.12, 40f, 0)))
    }

    @Test fun teleportJump_rejected() {
        val f = TrackFilter()
        f.accept(fix(51.50, -0.12, 8f, 0))
        // 2 km in 1 s -> ~2000 m/s, impossible -> rejected.
        assertNull(f.accept(fix(51.52, -0.12, 8f, 1000)))
    }

    @Test fun normalWalk_accepted() {
        val f = TrackFilter()
        f.accept(fix(51.5000, -0.1200, 8f, 0))
        // ~15 m in 10 s -> 1.5 m/s, fine.
        val p = f.accept(fix(51.50013, -0.1200, 8f, 10_000))
        assertEquals(51.50013, p!!.lat, 1e-6)
    }
}
