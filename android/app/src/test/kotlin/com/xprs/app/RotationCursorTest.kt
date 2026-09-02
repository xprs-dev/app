package com.xprs.app

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The rotation that starved this station's own beacon.
 *
 * Every test here fails against the shared-cursor version this replaced. The
 * first one is the bench, reduced: traffic in flight, the beacon registered
 * third, and 185 seconds of air with nothing of ours on it.
 */
class RotationCursorTest {
    private val prio = listOf("rns", "digi")
    // Insertion order, as LinkedHashMap gives it: the beacon is registered
    // after the two frames the RNS radio puts up at start, so it sits third.
    private val presence = listOf("wfd", "aprs", "xprs")

    @Test
    fun `every presence frame airs, including the ones past index one`() {
        val c = RotationCursor(4)
        val aired = mutableSetOf<String>()
        // A presence tick comes 1 in 4, so 3 presence frames need 12 ticks.
        // Give it 24 and demand all three, not just the reachable two.
        repeat(24) { c.next(prio, presence)?.let { k -> aired += k } }
        assertTrue(
            "presence frames never aired: ${presence - aired}",
            aired.containsAll(presence),
        )
    }

    @Test
    fun `presence keeps its own place while traffic runs`() {
        val c = RotationCursor(4)
        val order = mutableListOf<String>()
        repeat(12) { c.next(prio, presence)?.let { k -> if (k in presence) order += k } }
        // Three presence ticks in twelve, and each one moves on rather than
        // being dragged back by the traffic cursor.
        assertEquals(listOf("wfd", "aprs", "xprs"), order)
    }

    @Test
    fun `traffic still takes three ticks in four`() {
        val c = RotationCursor(4)
        var traffic = 0
        repeat(20) { if (c.next(prio, presence) in prio) traffic++ }
        assertEquals(15, traffic)
    }

    @Test
    fun `presence takes every tick when there is no traffic`() {
        val c = RotationCursor(4)
        val order = (0 until 6).map { c.next(emptyList(), presence) }
        assertEquals(listOf("wfd", "aprs", "xprs", "wfd", "aprs", "xprs"), order)
    }

    @Test
    fun `traffic takes every tick when there is no presence`() {
        val c = RotationCursor(4)
        val order = (0 until 4).map { c.next(prio, emptyList()) }
        assertEquals(listOf("rns", "digi", "rns", "digi"), order)
    }

    @Test
    fun `a shrunken list clamps rather than wrapping past its neighbour`() {
        val c = RotationCursor(4)
        // Walk the presence cursor to index 2 …
        repeat(3) { c.next(emptyList(), presence) }
        // … then two of the three frames expire. The stale index must not
        // silently skip the survivor.
        assertEquals("wfd", c.next(emptyList(), listOf("wfd")))
    }

    @Test
    fun `nothing registered airs nothing`() {
        assertNull(RotationCursor(4).next(emptyList(), emptyList()))
    }

    @Test
    fun `reset puts both cursors back`() {
        val c = RotationCursor(4)
        repeat(9) { c.next(prio, presence) }
        c.reset()
        assertEquals("rns", c.next(prio, presence))
    }
}
