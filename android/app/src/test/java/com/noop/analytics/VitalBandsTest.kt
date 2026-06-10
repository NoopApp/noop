package com.noop.analytics

import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * Pins VitalBands — the Health Monitor's personal-baseline banding. Mirrors
 * StrandAnalyticsTests/VitalBandsTests.swift case-for-case (identical numbers), so the
 * two platforms can never band the same vital differently.
 */
class VitalBandsTest {

    private val hrvCfg = Baselines.metricCfg.getValue("hrv")
    private val hrvPop = 40.0..120.0

    @Test
    fun nullValue_isNoData() {
        val r = VitalBands.band(null, listOf(50.0), hrvPop, hrvCfg)
        assertEquals(VitalBands.Band.NO_DATA, r.band)
    }

    // THE MOTIVATING CASE: a personal-normal HRV of 35 ms, population says 40-120.
    @Test
    fun lowHrv_below14Nights_populationOutOfRange() {
        val r = VitalBands.band(35.0, List(10) { 35.0 }, hrvPop, hrvCfg)
        assertEquals(VitalBands.Band.OUT_OF_RANGE, r.band)
        assertEquals(VitalBands.Basis.POPULATION, r.basis)
        assertEquals(10, r.nights)
    }

    @Test
    fun lowHrv_at14Nights_personalInRange() {
        val r = VitalBands.band(35.0, List(14) { 35.0 }, hrvPop, hrvCfg)
        assertEquals(VitalBands.Band.IN_RANGE, r.band)
        assertEquals(VitalBands.Basis.PERSONAL, r.basis)
        assertEquals(14, r.nights)
    }

    @Test
    fun personal_bigDeviation_outOfRange() {
        // constant 35 → spread = floorSpread; z(70) far above 2σ.
        val r = VitalBands.band(70.0, List(30) { 35.0 }, hrvPop, hrvCfg)
        assertEquals(VitalBands.Band.OUT_OF_RANGE, r.band)
        assertEquals(VitalBands.Basis.PERSONAL, r.basis)
    }

    @Test
    fun personal_justInside2Sigma_inRange() {
        val hist: List<Double?> = List(30) { 35.0 }
        val state = Baselines.foldHistory(hist, hrvCfg)
        val edge = state.baseline + 1.99 * 1.253 * state.spread   // strictly inside 2σ
        assertEquals(VitalBands.Band.IN_RANGE, VitalBands.band(edge, hist, hrvPop, hrvCfg).band)
    }

    @Test
    fun implausibleValue_alwaysOutOfRange_evenWithTrustedBaseline() {
        // hrv cfg bounds 5-250: 300 is implausible regardless of personal spread.
        val r = VitalBands.band(300.0, List(30) { 35.0 }, hrvPop, hrvCfg)
        assertEquals(VitalBands.Band.OUT_OF_RANGE, r.band)
        assertEquals(VitalBands.Basis.POPULATION, r.basis)
    }

    @Test
    fun nullCfg_spo2_staysPopulationOnly() {
        val r = VitalBands.band(93.0, emptyList(), 95.0..100.0, null)
        assertEquals(VitalBands.Band.OUT_OF_RANGE, r.band)
        assertEquals(VitalBands.Basis.POPULATION, r.basis)
    }

    @Test
    fun nullNights_doNotCountTowardTrust() {
        val hist: List<Double?> = (1..13).map { 35.0 as Double? } + List(10) { null }
        // 13 valid nights → provisional even after 10 trailing skips — still not personal.
        val r = VitalBands.band(35.0, hist, hrvPop, hrvCfg)
        assertEquals(VitalBands.Basis.POPULATION, r.basis)
    }

    @Test
    fun staleBaseline_fallsBackToPopulation() {
        // 20 valid nights then 20 missing: status STALE (>14 missing) → population.
        val hist: List<Double?> = List(20) { 35.0 as Double? } + List(20) { null }
        val r = VitalBands.band(35.0, hist, hrvPop, hrvCfg)
        assertEquals(VitalBands.Basis.POPULATION, r.basis)
    }

    @Test
    fun skinTempHistory_partitionsMixedSemantics() {
        val mixed: List<Double?> = listOf(34.1, 0.2, null, 33.8, -0.1)
        assertEquals(listOf(null, 0.2, null, null, -0.1), VitalBands.skinTempHistory(0.3, mixed))
        assertEquals(listOf(34.1, null, null, 33.8, null), VitalBands.skinTempHistory(34.0, mixed))
    }

    @Test
    fun calendarSeries_padsMissingDays() {
        val rows = listOf<Pair<String, Double?>>("2026-06-01" to 50.0, "2026-06-04" to 52.0)
        assertEquals(listOf(50.0, null, null, 52.0), VitalBands.calendarSeries(rows))
    }

    @Test
    fun calendarSeries_dropsMalformedKeys_emptyIsEmpty() {
        assertEquals(emptyList<Double?>(), VitalBands.calendarSeries(emptyList()))
        val rows = listOf<Pair<String, Double?>>("not-a-date" to 1.0, "2026-06-01" to 50.0)
        assertEquals(listOf(50.0), VitalBands.calendarSeries(rows))
    }
}
