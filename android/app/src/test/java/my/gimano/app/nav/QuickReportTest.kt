package my.gimano.app.nav

import my.gimano.app.core.identity.RequestSigning
import my.gimano.app.core.report.HoldToReport
import my.gimano.app.core.report.HoldToReport.Effect
import my.gimano.app.core.report.QuickFan
import my.gimano.app.core.report.QuickReportSession
import org.junit.Assert.*
import org.junit.Test

/** docs/driving.md §6.4: hold-to-report fan, gesture and Undo. */
class QuickReportTest {
    // ---- Fan geometry ---------------------------------------------------------------------------

    @Test fun eightSlotsInnerAndOuterRingsInTheSpecOrderAndColours() {
        assertEquals(listOf("hazard", "police", "accident"), QuickFan.slots.filter { !it.outer }.map { it.type })
        assertEquals(listOf("traffic", "closure", "blocked_lane", "weather", "animal"), QuickFan.slots.filter { it.outer }.map { it.type })
        assertFalse("map issue stays in the full sheet", "map_issue" in QuickFan.types)
        assertEquals(0xFFF2B01E, QuickFan.slot("hazard")!!.color)   // amber
        assertEquals(0xFF2563EB, QuickFan.slot("police")!!.color)   // blue
        assertEquals(0xFFC62828, QuickFan.slot("accident")!!.color) // red
        assertEquals(0xFFF97316, QuickFan.slot("traffic")!!.color)  // orange
        assertEquals(0xFF4B5563, QuickFan.slot("closure")!!.color)  // grey
        assertEquals(0xFF7C3AED, QuickFan.slot("blocked_lane")!!.color) // purple
        assertEquals(0xFF0F766E, QuickFan.slot("weather")!!.color)  // teal
        assertEquals(0xFF4D7C0F, QuickFan.slot("animal")!!.color)   // green
    }

    @Test fun fanOpensUpAndLeftOfTheButton() {
        val (hx, hy) = QuickFan.offset(QuickFan.slot("hazard")!!)
        assertEquals(0f, hx, 0.01f); assertEquals(-122f, hy, 0.01f)       // straight up
        val (ax, ay) = QuickFan.offset(QuickFan.slot("accident")!!)
        assertEquals(-122f, ax, 0.01f); assertEquals(0f, ay, 0.01f)       // straight left
        val (px, py) = QuickFan.offset(QuickFan.slot("police")!!)
        assertEquals(-86.27f, px, 0.05f); assertEquals(-86.27f, py, 0.05f)
        val (bx, by) = QuickFan.offset(QuickFan.slot("blocked_lane")!!, scale = 0.5f)
        assertEquals(-80.6f, bx, 0.1f); assertEquals(-80.6f, by, 0.1f)
        // No two slots overlap.
        val s = QuickFan.slots
        for (i in s.indices) for (j in i + 1 until s.size) {
            val (x1, y1) = QuickFan.offset(s[i]); val (x2, y2) = QuickFan.offset(s[j])
            assertTrue("${s[i].type}/${s[j].type}", Math.hypot((x1 - x2).toDouble(), (y1 - y2).toDouble()) > (s[i].sizeDp + s[j].sizeDp) / 2)
        }
    }

    @Test fun hitTestFindsTheSlotUnderTheFingerAndNothingOnTheButtonOrBetween() {
        assertEquals("hazard", QuickFan.hitTest(0f, -122f)?.type)
        assertEquals("hazard", QuickFan.hitTest(20f, -140f)?.type)         // within radius + slop
        assertEquals("traffic", QuickFan.hitTest(0f, -228f)?.type)
        assertEquals("animal", QuickFan.hitTest(-230f, 5f)?.type)
        assertEquals("weather", QuickFan.hitTest(-211f, -87f)?.type)
        assertNull(QuickFan.hitTest(0f, 0f))                               // on the button
        assertNull(QuickFan.hitTest(-10f, -30f))
        assertNull(QuickFan.hitTest(60f, 60f))                             // down-right: nothing there
        assertNull(QuickFan.hitTest(0f, -175f))                            // between the rings
        assertNull(QuickFan.hitTest(-400f, -400f))
        assertEquals("traffic", QuickFan.hitTest(0f, -114f, scale = 0.5f)?.type)
    }

    @Test fun fanScalesDownOnlyWhenTheScreenIsTooSmall() {
        assertEquals(1f, QuickFan.scaleToFit(360f, 600f), 0f)
        assertEquals(0.75f, QuickFan.scaleToFit(198f, 600f), 0.001f)
        assertEquals(0.6f, QuickFan.scaleToFit(50f, 50f), 0f)
    }

    // ---- Gesture ---------------------------------------------------------------------------------

    @Test fun aQuickTapOpensTheFullSheet() {
        val g = HoldToReport()
        g.down(0)
        assertEquals(Effect.None, g.tick(100))
        assertEquals(Effect.OpenSheet, g.up(3f, -2f, 150))
        assertEquals(HoldToReport.Phase.IDLE, g.phase)
    }

    @Test fun holdOpensTheFanSlideSelectsWithATickAndReleaseSends() {
        val g = HoldToReport()
        g.down(0)
        assertEquals(Effect.None, g.tick(299))
        assertEquals(Effect.FanOpened, g.tick(300))
        assertEquals(Effect.None, g.tick(400))
        assertEquals(Effect.None, g.move(0f, -30f, 420))                  // still on the button: nothing selected
        val sel = g.move(0f, -120f, 500)
        assertEquals("hazard", (sel as Effect.Selected).slot?.type)
        assertEquals(Effect.None, g.move(4f, -124f, 520))                 // same slot: no second tick
        assertEquals("police", (g.move(-85f, -85f, 600) as Effect.Selected).slot?.type)
        assertEquals("hazard", (g.move(0f, -122f, 700) as Effect.Selected).slot?.type)
        assertEquals(Effect.Send("hazard"), g.up(0f, -122f, 800))
    }

    @Test fun releasingOutsideASlotCancels() {
        val g = HoldToReport()
        g.down(0); g.tick(320)
        g.move(0f, -122f, 400)
        assertEquals(Effect.Selected(null), g.move(0f, -175f, 450))       // slid off: banner back to the hint
        assertEquals(Effect.Cancel, g.up(0f, -175f, 500))
        // Release back on the button = cancel too.
        g.down(1_000); g.tick(1_400)
        assertEquals(Effect.Cancel, g.up(0f, 0f, 1_500))
    }

    @Test fun draggingFastStillOpensTheFanOnceHeldAndALongPressWithoutTheFanNeverOpensTheSheet() {
        val g = HoldToReport()
        g.down(0)
        assertEquals(Effect.None, g.move(-40f, -60f, 120))                // moved before the hold time
        assertEquals(Effect.None, g.tick(310))                            // moving: the fan opens on the next move
        assertEquals("hazard", (g.move(0f, -122f, 330) as Effect.Selected).slot?.type)
        assertEquals(Effect.Send("hazard"), g.up(0f, -122f, 400))
        // A drag that ends before the hold time is neither a tap nor a report.
        g.down(1_000); g.move(-80f, 0f, 1_100)
        assertEquals(Effect.Cancel, g.up(-80f, 0f, 1_200))
    }

    @Test fun aSystemCancelSendsNothing() {
        val g = HoldToReport()
        g.down(0); g.tick(300); g.move(0f, -122f, 350)
        assertEquals(Effect.Cancel, g.cancel())
        assertEquals(Effect.None, g.cancel())
        assertNull(g.selected)
    }

    // ---- Undo ------------------------------------------------------------------------------------

    @Test fun undoAfterSendingDeletesTheReport() {
        val s = QuickReportSession("hazard", 10_000)
        assertTrue(s.showsCard(10_000))
        assertEquals(QuickReportSession.Action.None, s.onSent("r1"))
        assertEquals(QuickReportSession.State.SENT, s.state)
        assertEquals(3, s.secondsLeft(12_500))
        assertEquals(QuickReportSession.Action.Delete("r1"), s.undo(14_000))
        assertEquals(QuickReportSession.State.UNDONE, s.state)
        assertFalse(s.showsCard(14_100))
        assertEquals(QuickReportSession.Action.None, s.undo(14_200))      // only once
    }

    @Test fun undoWhileSendingCancelsAndDeletesWhenTheIdArrives() {
        val s = QuickReportSession("police", 0)
        assertEquals(QuickReportSession.Action.CancelPending, s.undo(800))
        assertEquals(QuickReportSession.Action.Delete("r2"), s.onSent("r2"))
        assertEquals(QuickReportSession.State.UNDONE, s.state)
    }

    @Test fun undoIsOnlyOfferedForFiveSeconds() {
        val s = QuickReportSession("accident", 0)
        s.onSent("r3")
        assertTrue(s.canUndo(4_999))
        assertFalse(s.canUndo(5_000))
        assertFalse(s.showsCard(5_000))
        assertEquals(QuickReportSession.Action.None, s.undo(5_001))
        assertEquals(QuickReportSession.State.SENT, s.state)               // the report stays
    }

    @Test fun aFailedSendShowsNoCardAndCannotBeUndone() {
        val s = QuickReportSession("traffic", 0)
        s.onFailed()
        assertFalse(s.showsCard(100))
        assertEquals(QuickReportSession.Action.None, s.undo(100))
    }

    @Test fun undoRequestIsSigned() {
        assertTrue(RequestSigning.isSigned("DELETE", "/api/v1/reports/0d6c2f8e-7b39-4f0e-9f4e-4b3f6a1c2d11"))
        assertFalse(RequestSigning.isSigned("DELETE", "/api/v1/reports"))
        assertTrue(RequestSigning.isSigned("POST", "/api/v1/reports"))
    }
}
