package my.gimano.app.nav

import my.gimano.app.core.drive.Countdown
import my.gimano.app.core.drive.LabelFit
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** docs/driving.md §6.1: the confirm card's 10 s ring and its never-cut labels; §6.4: the 5 s Undo. */
class ConfirmCountdownTest {
    @Test fun tenSecondRingCountsDownWholeSecondsThenExpires() {
        val c = Countdown(Countdown.CONFIRM_MS, startMs = 1_000)
        assertEquals(10, c.secondsLeft(1_000))
        assertEquals(1f, c.fraction(1_000), 0f)
        assertEquals(10, c.secondsLeft(1_001))          // rounded up: "10" shows for the first whole second
        assertEquals(9, c.secondsLeft(2_000))
        assertEquals(5, c.secondsLeft(6_500))
        assertEquals(0.45f, c.fraction(6_500), 0.0001f)
        assertEquals(1, c.secondsLeft(10_999))
        assertFalse(c.expired(10_999))
        assertTrue(c.expired(11_000))
        assertEquals(0, c.secondsLeft(11_000))
        assertEquals(0f, c.fraction(60_000), 0f)
    }

    @Test fun aClockBeforeTheStartReadsAsFull() {
        val c = Countdown(Countdown.UNDO_MS, startMs = 5_000)
        assertEquals(5_000, c.remainingMs(4_000))
        assertEquals(5, c.secondsLeft(4_000))
        assertFalse(c.expired(4_000))
    }

    @Test fun undoWindowIsFiveSeconds() {
        val c = Countdown(Countdown.UNDO_MS, startMs = 0)
        assertEquals(5, c.secondsLeft(0))
        assertFalse(c.expired(4_999))
        assertTrue(c.expired(5_000))
    }

    @Test fun labelsShrinkOneStepAtATimeAndNeverBelowTheMinimum() {
        var sp = LabelFit.MAX_SP
        val sizes = mutableListOf(sp)
        while (true) { sp = LabelFit.shrink(sp) ?: break; sizes += sp }
        assertEquals(listOf(15f, 14f, 13f, 12f, 11f), sizes)
        assertNull(LabelFit.shrink(LabelFit.MIN_SP))     // at 11 sp the button grows instead of cutting
        assertEquals(2, LabelFit.MAX_LINES)
    }
}
