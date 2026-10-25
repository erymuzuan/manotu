package my.gimano.app.core.report

import my.gimano.app.core.drive.Countdown
import kotlin.math.cos
import kotlin.math.hypot
import kotlin.math.sin

/**
 * Hold-to-report (docs/driving.md §6.4, canvas NavLaporTahan / NavLaporPilih / NavLaporHantar), free of Android so it
 * is unit-tested: the fan's geometry and hit-testing, the tap / hold / slide / release gesture, and the Undo window.
 *
 * Coordinates are dp relative to the report button's centre, x to the right and y DOWN (screen space). The button sits
 * at the bottom right, so the fan opens up and to the left.
 */
object QuickFan {
    /** One quick action. [angleDeg] is maths-style (0 = right, 90 = up, 180 = left). Colours are ARGB. */
    data class Slot(val type: String, val outer: Boolean, val angleDeg: Double, val color: Long, val ink: Long) {
        val radiusDp: Float get() = if (outer) OUTER_RADIUS_DP else INNER_RADIUS_DP
        val sizeDp: Float get() = if (outer) OUTER_SIZE_DP else INNER_SIZE_DP
    }

    const val INNER_RADIUS_DP = 122f
    const val OUTER_RADIUS_DP = 228f
    const val INNER_SIZE_DP = 62f
    const val OUTER_SIZE_DP = 56f
    /** The slot under the finger grows to this. */
    const val SELECTED_SIZE_DP = 80f
    /** Inside the button itself nothing is selected (release there = cancel). */
    const val BUTTON_RADIUS_DP = 42f
    /** Extra reach round each slot so a moving finger doesn't have to be exact. */
    const val SLOP_DP = 14f

    /** Inner ring: Hazard (amber), Police (blue), Accident (red). Outer: Traffic, Closure, Blocked lane, Weather, Animal. */
    val slots: List<Slot> = listOf(
        Slot("hazard", false, 90.0, 0xFFF2B01E, 0xFF3A2600),
        Slot("police", false, 135.0, 0xFF2563EB, 0xFFFFFFFF),
        Slot("accident", false, 180.0, 0xFFC62828, 0xFFFFFFFF),
        Slot("traffic", true, 90.0, 0xFFF97316, 0xFF2A1200),
        Slot("closure", true, 112.5, 0xFF4B5563, 0xFFFFFFFF),
        Slot("blocked_lane", true, 135.0, 0xFF7C3AED, 0xFFFFFFFF),
        Slot("weather", true, 157.5, 0xFF0F766E, 0xFFFFFFFF),
        Slot("animal", true, 180.0, 0xFF4D7C0F, 0xFFFFFFFF),
    )

    /** "Map issue" stays in the full sheet only. */
    val types: List<String> get() = slots.map { it.type }

    fun slot(type: String): Slot? = slots.firstOrNull { it.type == type }

    /** Centre of [slot] relative to the button centre, in dp (y down), at [scale]. */
    fun offset(slot: Slot, scale: Float = 1f): Pair<Float, Float> {
        val a = Math.toRadians(slot.angleDeg)
        val r = slot.radiusDp * scale
        return (r * cos(a)).toFloat() to (-r * sin(a)).toFloat()
    }

    /**
     * Shrinks the fan (never grows it) so the outer ring fits the room left of and above the button, minus a margin.
     * At least 0.6: on a very small screen the full sheet is still there.
     */
    fun scaleToFit(roomLeftDp: Float, roomUpDp: Float, marginDp: Float = 8f): Float {
        val need = OUTER_RADIUS_DP + OUTER_SIZE_DP / 2 + marginDp
        return minOf(1f, roomLeftDp / need, roomUpDp / need).coerceAtLeast(0.6f)
    }

    /** The slot under the finger at ([dx], [dy]) from the button centre, or null (on the button, or between slots). */
    fun hitTest(dx: Float, dy: Float, scale: Float = 1f): Slot? {
        if (hypot(dx, dy) < BUTTON_RADIUS_DP * scale) return null
        var best: Slot? = null
        var bestD = Float.MAX_VALUE
        for (s in slots) {
            val (x, y) = offset(s, scale)
            val d = hypot(dx - x, dy - y)
            if (d <= (s.sizeDp / 2 + SLOP_DP) * scale && d < bestD) { best = s; bestD = d }
        }
        return best
    }
}

/**
 * The report button's gesture: tap = the full sheet (as before); hold [holdMs] = the fan; slide = select (each new
 * selection asks for a haptic tick); release on a slot = send it at once; release anywhere else = cancel.
 */
class HoldToReport(private val holdMs: Long = HOLD_MS, private val tapSlopDp: Float = TAP_SLOP_DP) {
    sealed interface Effect {
        data object None : Effect
        data object OpenSheet : Effect
        data object FanOpened : Effect
        /** The finger moved onto [slot] (tick + banner), or off every slot (null). */
        data class Selected(val slot: QuickFan.Slot?) : Effect
        data class Send(val type: String) : Effect
        data object Cancel : Effect
    }

    enum class Phase { IDLE, PRESSED, FAN }

    var phase = Phase.IDLE
        private set
    var selected: QuickFan.Slot? = null
        private set
    var scale = 1f

    private var downMs = 0L
    private var moved = false

    fun down(nowMs: Long): Effect {
        phase = Phase.PRESSED; downMs = nowMs; moved = false; selected = null
        return Effect.None
    }

    /** Called while the finger is down and still (the fan opens on time without a move). */
    fun tick(nowMs: Long): Effect =
        if (phase == Phase.PRESSED && !moved && nowMs - downMs >= holdMs) { phase = Phase.FAN; Effect.FanOpened } else Effect.None

    fun move(dx: Float, dy: Float, nowMs: Long): Effect {
        when (phase) {
            Phase.IDLE -> return Effect.None
            Phase.PRESSED -> {
                if (hypot(dx, dy) > tapSlopDp) moved = true
                // Dragging before the hold time isn't a tap any more, but the fan still opens once the hold is reached.
                if (nowMs - downMs < holdMs) return Effect.None
                phase = Phase.FAN
                val s = QuickFan.hitTest(dx, dy, scale)
                selected = s
                return if (s == null) Effect.FanOpened else Effect.Selected(s)
            }
            Phase.FAN -> {
                val s = QuickFan.hitTest(dx, dy, scale)
                if (s == selected) return Effect.None
                selected = s
                return Effect.Selected(s)
            }
        }
    }

    fun up(dx: Float, dy: Float, nowMs: Long): Effect {
        val was = phase
        val sel = if (was == Phase.FAN) QuickFan.hitTest(dx, dy, scale) else null
        phase = Phase.IDLE
        selected = null
        return when (was) {
            Phase.IDLE -> Effect.None
            Phase.PRESSED -> if (nowMs - downMs < holdMs && !moved && hypot(dx, dy) <= tapSlopDp) Effect.OpenSheet else Effect.Cancel
            Phase.FAN -> sel?.let { Effect.Send(it.type) } ?: Effect.Cancel
        }
    }

    /** The system took the gesture (e.g. a call came in): nothing is sent. */
    fun cancel(): Effect {
        val was = phase
        phase = Phase.IDLE; selected = null
        return if (was == Phase.IDLE) Effect.None else Effect.Cancel
    }

    companion object {
        const val HOLD_MS = 300L
        const val TAP_SLOP_DP = 12f
    }
}

/**
 * One quick report from release to the end of its Undo (§6.4): the card shows at once ("Hazard reported · just now")
 * while the request is in flight. Undo within [Countdown.UNDO_MS] deletes it on the server, or, when it isn't sent
 * yet, cancels it (deleted as soon as the server answers).
 */
class QuickReportSession(val type: String, private val startedMs: Long) {
    enum class State { SENDING, SENT, UNDONE, FAILED }

    sealed interface Action {
        data object None : Action
        /** Undo while still sending: drop the card; delete the report when its id arrives. */
        data object CancelPending : Action
        data class Delete(val reportId: String) : Action
    }

    private val window = Countdown(Countdown.UNDO_MS, startedMs)

    var state = State.SENDING
        private set
    var reportId: String? = null
        private set
    private var undoRequested = false

    fun secondsLeft(nowMs: Long): Int = window.secondsLeft(nowMs)
    fun fraction(nowMs: Long): Float = window.fraction(nowMs)

    /** The card (with Undo) is shown until the window ends, while the report is being sent or sent. */
    fun showsCard(nowMs: Long): Boolean = !window.expired(nowMs) && (state == State.SENDING || state == State.SENT)

    fun canUndo(nowMs: Long): Boolean = showsCard(nowMs)

    fun undo(nowMs: Long): Action {
        if (!canUndo(nowMs)) return Action.None
        return when (state) {
            State.SENDING -> { undoRequested = true; state = State.UNDONE; Action.CancelPending }
            State.SENT -> { state = State.UNDONE; Action.Delete(reportId!!) }
            else -> Action.None
        }
    }

    /** The server created it: normally nothing to do; after an early Undo it is deleted now. */
    fun onSent(id: String): Action {
        reportId = id
        if (undoRequested) return Action.Delete(id)
        if (state == State.SENDING) state = State.SENT
        return Action.None
    }

    fun onFailed() { if (state == State.SENDING) state = State.FAILED }
}
