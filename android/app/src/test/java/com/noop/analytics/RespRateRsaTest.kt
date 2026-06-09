package com.noop.analytics

import com.noop.data.RrInterval
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Tests SleepStager.respRateFromRR (RSA) on a synthetic R-R series with a KNOWN breathing
 * frequency. WHOOP5 v18 carries no raw resp ADC, so respiratory rate is derived on-device
 * from the R-R stream via respiratory sinus arrhythmia; this pins that the estimator recovers
 * a planted breathing rate and returns NaN on too-little data (honest no-data). The value is
 * an APPROXIMATE on-device estimate, not cloud/clinical respiration.
 */
class RespRateRsaTest {

    @Test
    fun respRateFromRR_recoversKnownBreathingFrequency() {
        // Synthetic RR: mean HR 60 bpm (RR ~1000 ms) with a 0.25 Hz (15 breaths/min)
        // RSA modulation of +/-40 ms. ~7 minutes of beats so multiple 5-min windows.
        val breathHz = 0.25 // 15 breaths/min
        val baseRrMs = 1000.0
        val ampMs = 40.0
        val start = 1_700_000_000L
        val rows = ArrayList<RrInterval>()
        var tSec = 0.0
        // generate ~420 s of beats
        while (tSec < 420.0) {
            val rrMs = baseRrMs + ampMs * Math.sin(2.0 * Math.PI * breathHz * tSec)
            tSec += rrMs / 1000.0
            rows.add(
                RrInterval(
                    deviceId = "test",
                    ts = start + tSec.toLong(),
                    rrMs = rrMs.toInt(),
                )
            )
        }
        val end = start + tSec.toLong()
        val est = SleepStager.respRateFromRR(rows, start, end)
        assertTrue("expected finite resp estimate, got $est", est.isFinite())
        // RSA peak-pick should land within ~3 bpm of the true 15 breaths/min.
        assertEquals(15.0, est, 3.0)
    }

    @Test
    fun respRateFromRR_tooFewBeatsIsNaN() {
        val start = 1_700_000_000L
        val rows = listOf(
            RrInterval(deviceId = "test", ts = start + 1, rrMs = 1000),
            RrInterval(deviceId = "test", ts = start + 2, rrMs = 1000),
            RrInterval(deviceId = "test", ts = start + 3, rrMs = 1000),
        )
        assertTrue(SleepStager.respRateFromRR(rows, start, start + 10).isNaN())
        assertTrue(SleepStager.respRateFromRR(emptyList(), start, start + 10).isNaN())
    }
}
