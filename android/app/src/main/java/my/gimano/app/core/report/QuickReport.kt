package my.gimano.app.core.report

import my.gimano.app.core.drive.Countdown
import kotlin.math.cos
import kotlin.math.hypot
import kotlin.math.sin

/**
 * Hold-to-report (docs/driving.md §6.4, canvas NavLaporTahan / NavLaporPilih / NavLaporHantar), free of Android so it
 * is unit-tested: the arc's geometry and hit-testing, the tap / hold / slide / release gesture, and the Undo window.
 *
 * Coordinates are dp relative to the report button's centre, x to the right and y DOWN (screen space). The button sits
 * at the bottom right, so the arc opens up and to the left.
 */
object QuickFan {
    /** One quick action. [angleDeg] is maths-style (0 = right, 90 = up, 180 = left). Colours are ARGB. */
    data class Slot(val type: String, val angleDeg: Double, val color: Long, val ink: Long) {
        val radiusDp: Float get() = ARC_RADIUS_DP
        val sizeDp: Float get() = SIZE_DP
    }

    /** All five bubbles sit on one arc (docs/driving.md §6.4, canvas RpHold). */
    const val ARC_RADIUS_DP = 170f
    const val SIZE_DP = 60f
    /** The slot under the finger grows to this. */
    const val SELECTED_SIZE_DP = 80f
    /** Inside the button itself nothing is selected (release there = cancel). */
    const val BUTTON_RADIUS_DP = 42f
    /** Extra reach round each slot so a moving finger doesn't have to be exact. */
    const val SLOP_DP = 14f

    /** Hazard, Police, Crash, Traffic, Closed: the five most reported, from straight up round to the left. */
    val slots: List<Slot> = listOf(
        Slot("hazard", 90.0, 0xFFF2B01E, 0xFF3A2600),
        Slot("police", 112.5, 0xFF2563EB, 0xFFFFFFFF),
        Slot("accident", 135.0, 0xFFC62828, 0xFFFFFFFF),
        Slot("traffic", 157.5, 0xFFF97316, 0xFF2A1200),
        Slot("closure", 180.0, 0xFF4B5563, 0xFFFFFFFF),
    )

    /** Weather, Animal, Blocked lane and Map issue are in the drawer only. */
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
        val need = ARC_RADIUS_DP + SELECTED_SIZE_DP / 2 + marginDp
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
 * The report button's gesture: tap = the drawer; hold [holdMs] = the fan; slide = select (each new
 * selection asks for a haptic tick); release on a slot = the detail sheet for it; release anywhere else = cancel.
 */
class HoldToReport(private val holdMs: Long = HOLD_MS, private val tapSlopDp: Float = TAP_SLOP_DP) {
    sealed interface Effect {
        data object None : Effect
        data object OpenSheet : Effect
        data object FanOpened : Effect
        /** The finger moved onto [slot] (tick + banner), or off every slot (null). */
        data class Selected(val slot: QuickFan.Slot?) : Effect
        /** Released on a bubble: go on to the detail sheet for [type] (nothing is sent yet). */
        data class Continue(val type: String) : Effect
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
            Phase.FAN -> sel?.let { Effect.Continue(it.type) } ?: Effect.Cancel
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

/**
 * The detail sheet both doors end on (tap drawer, hold arc): the default subtype is picked already and the report
 * sends itself after [AUTO_SEND_MS] unless the driver touches an option or presses Cancel / Report (docs/driving.md §6.4).
 */
object ReportDefaults {
    const val AUTO_SEND_MS = 3_000L

    /** Subtypes per type, same order as the sheet; the first is the default except Traffic (heavy). */
    private val subtypes = mapOf(
        "traffic" to listOf("moderate", "heavy", "standstill"),
        "police" to listOf("visible", "hidden", "roadblock"),
        "accident" to listOf("minor", "major", "other_side"),
        "hazard" to listOf("object_on_road", "pothole", "stopped_vehicle", "roadkill", "construction", "flood", "oil_spill"),
        "blocked_lane" to listOf("left", "center", "right"),
        "weather" to listOf("heavy_rain", "fog", "flood", "haze"),
        "animal" to listOf("on_road", "on_shoulder"),
    )

    fun defaultSubtype(type: String): String? = if (type == "traffic") "heavy" else subtypes[type]?.first()

    /** Map issue has its own sheet (road problems) and is never sent by a timer. */
    fun autoSends(type: String): Boolean = type != "map_issue"
}
