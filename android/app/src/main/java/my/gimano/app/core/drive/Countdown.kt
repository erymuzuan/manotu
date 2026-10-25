package my.gimano.app.core.drive

/**
 * A fixed-length countdown, free of Android so it is unit-tested (docs/driving.md §6): the confirm card's 10 s ring
 * ("Still closed?" / "Still there?") and the quick report's 5 s Undo. Callers pass the clock.
 */
class Countdown(val totalMs: Long, private val startMs: Long) {
    init { require(totalMs > 0) }

    fun elapsedMs(nowMs: Long): Long = (nowMs - startMs).coerceIn(0, totalMs)

    fun remainingMs(nowMs: Long): Long = totalMs - elapsedMs(nowMs)

    /** Whole seconds shown in the ring: 10, 9, … 1, then 0 when it has run out (rounded up, so "10" shows first). */
    fun secondsLeft(nowMs: Long): Int = ((remainingMs(nowMs) + 999) / 1000).toInt()

    /** Share of the ring still drawn: 1 at the start, 0 at the end. */
    fun fraction(nowMs: Long): Float = remainingMs(nowMs).toFloat() / totalMs

    fun expired(nowMs: Long): Boolean = remainingMs(nowMs) <= 0

    companion object {
        /** The confirm card closes with no answer after this long. */
        const val CONFIRM_MS = 10_000L
        /** A quick report's "Undo" stays for this long. */
        const val UNDO_MS = 5_000L
    }
}

/** Font size for a confirm button label: shrink one step at a time before ever cutting the text (§6.1). */
object LabelFit {
    const val MAX_SP = 15f
    const val MIN_SP = 11f
    const val STEP_SP = 1f
    const val MAX_LINES = 2

    /** The next size to try after [current] overflowed, or null when already at the smallest (then the row grows). */
    fun shrink(current: Float): Float? = (current - STEP_SP).takeIf { it >= MIN_SP - 0.01f }
}
