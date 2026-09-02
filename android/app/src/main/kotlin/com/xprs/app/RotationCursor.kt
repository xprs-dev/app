package com.xprs.app

/**
 * Which broadcast frame airs on the next rotation tick.
 *
 * The single extended advertising set carries one blob at a time, so every
 * registered frame takes turns on it. Two classes take turns differently:
 *
 *   PRIO      relayed and published traffic. Gets most of the channel, because
 *             a Reticulum handshake that spreads over a minute is a handshake
 *             nobody completes.
 *   PRESENCE  "I am here, and here is where to write to me" -- this station's
 *             own beacon. Gets a guaranteed one tick in [presenceEvery],
 *             because traffic that arrives at a station no peer can address is
 *             not a win.
 *
 * ── Why this is a class and not four lines inside rotateTick ─────────────
 *
 * It was four lines inside rotateTick, and they shared ONE cursor between the
 * two lists while advancing it modulo whichever list that tick had chosen:
 *
 *     if (rotateIdx >= keys.size) rotateIdx = 0
 *     val frame = frames[keys[rotateIdx]] ?: return
 *     rotateIdx = (rotateIdx + 1) % keys.size
 *
 * With traffic in flight, three ticks in four take the prio list (size 1-2),
 * which clamps the shared cursor to 0-1. The one-in-four presence tick then
 * reads presence[0] or presence[1] and nothing else -- so every presence frame
 * past index 1 NEVER AIRED. Frames are insertion-ordered, so "past index 1"
 * meant "registered after the first two", which is exactly where this
 * station's own beacon sat.
 *
 * Measured on the bench with an independent BLE scanner, 185 s of air: 17
 * beacons from each of two ESP32 stations, 15 packets relayed BY the phone,
 * and ZERO originated by it. The radio, the PHY, the framing and the subtype
 * were all correct; the scheduler simply never picked the frame. It is pulled
 * out here so that failure has a test (RotationCursorTest) instead of a
 * two-day bench session.
 *
 * Not thread-safe: every caller runs on the BLE worker thread.
 */
internal class RotationCursor(private val presenceEvery: Int) {
    /** One cursor PER LIST. The whole point of the file. */
    private var prioIdx = 0
    private var presenceIdx = 0
    private var ticks = 0

    /**
     * The key to air this tick, or null when there is nothing registered.
     *
     * Both lists are passed in fresh each tick because frames expire: a cursor
     * that outlived its list is clamped rather than wrapped, so dropping a
     * frame cannot make the rotation skip its neighbour.
     */
    fun next(prio: List<String>, presence: List<String>): String? {
        val usePresence =
            prio.isEmpty() || (presence.isNotEmpty() && (++ticks % presenceEvery == 0))
        val keys = if (usePresence) presence else prio
        if (keys.isEmpty()) return null
        var idx = if (usePresence) presenceIdx else prioIdx
        if (idx >= keys.size) idx = 0
        val key = keys[idx]
        val next = (idx + 1) % keys.size
        if (usePresence) presenceIdx = next else prioIdx = next
        return key
    }

    fun reset() {
        prioIdx = 0
        presenceIdx = 0
        ticks = 0
    }
}
