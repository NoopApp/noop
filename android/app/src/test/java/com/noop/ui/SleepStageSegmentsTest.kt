package com.noop.ui

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/**
 * Unit tests for [parsePersistedSegments], the pure helper behind the Sleep hero's real
 * hypnogram. Only the verbatim on-device segments array ([{start,end,stage}]) parses; both
 * imported minutes shapes fall through to null so imported nights keep the synthesized fallback.
 */
class SleepStageSegmentsTest {

    @Test
    fun parsesStagerSegmentsArray() {
        val json = """[
            {"start":1000,"end":1900,"stage":"light"},
            {"start":1900,"end":3700,"stage":"deep"},
            {"start":3700,"end":4000,"stage":"wake"}
        ]"""
        val segs = parsePersistedSegments(json)!!
        assertEquals(3, segs.size)
        assertEquals("deep", segs[1].stage)
        assertEquals(1800L, segs[1].end - segs[1].start)
    }

    @Test
    fun minutesDictReturnsNull() {
        assertNull(parsePersistedSegments("""{"light":210,"deep":80,"rem":95,"awake":25}"""))
    }

    @Test
    fun importedStageMinArrayReturnsNull() {
        assertNull(parsePersistedSegments("""[{"stage":"light","min":210.0},{"stage":"deep","min":80.0}]"""))
    }

    @Test
    fun singleSegmentReturnsNull() {
        assertNull(parsePersistedSegments("""[{"start":1000,"end":2000,"stage":"light"}]"""))
    }

    @Test
    fun garbageReturnsNull() {
        assertNull(parsePersistedSegments("not json"))
        assertNull(parsePersistedSegments(null))
        assertNull(parsePersistedSegments(""))
    }
}
