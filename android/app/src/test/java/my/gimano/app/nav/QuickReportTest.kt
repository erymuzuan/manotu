package my.gimano.app.nav

import my.gimano.app.core.identity.RequestSigning
import my.gimano.app.core.report.HoldToReport
import my.gimano.app.core.report.HoldToReport.Effect
import my.gimano.app.core.report.QuickFan
import my.gimano.app.core.report.QuickReportSession
import my.gimano.app.core.report.ReportDefaults
import org.junit.Assert.*
import org.junit.Test

/** docs/driving.md §6.4: hold-to-report fan, gesture and Undo. */
class QuickReportTest {
    // ---- Fan geometry ---------------------------------------------------------------------------

    @Test fun fiveBubblesOnOneArcInTheSpecOrderAndColours() {
        assertEquals(listOf("hazard", "police", "accident", "traffic", "closure"), QuickFan.slots.map { it.type })
        assertTrue("one arc", QuickFan.slots.all { it.radiusDp == QuickFan.ARC_RADIUS_DP })
        for (t in listOf("blocked_lane", "weather", "animal", "map_issue")) assertFalse("$t is in the drawer only", t in QuickFan.types)
        assertEquals(0xFFF2B01E, QuickFan.slot("hazard")!!.color)   // amber
        assertEquals(0xFF2563EB, QuickFan.slot("police")!!.color)   // blue
        assertEquals(0xFFC62828, QuickFan.slot("accident")!!.color) // red
        assertEquals(0xFFF97316, QuickFan.slot("traffic")!!.color)  // orange
        assertEquals(0xFF4B5563, QuickFan.slot("closure")!!.color)  // grey
    }

    @Test fun arcOpensUpAndLeftOfTheButton() {
        val (hx, hy) = QuickFan.offset(QuickFan.slot("hazard")!!)
        assertEquals(0f, hx, 0.01f); assertEquals(-170f, hy, 0.01f)       // straight up
        val (cx, cy) = QuickFan.offset(QuickFan.slot("closure")!!)
        assertEquals(-170f, cx, 0.01f); assertEquals(0f, cy, 0.01f)       // straight left
        val (ax, ay) = QuickFan.offset(QuickFan.slot("accident")!!)
        assertEquals(-120.2f, ax, 0.05f); assertEquals(-120.2f, ay, 0.05f)
        val (bx, by) = QuickFan.offset(QuickFan.slot("accident")!!, scale = 0.5f)
        assertEquals(-60.1f, bx, 0.05f); assertEquals(-60.1f, by, 0.05f)
        // No two bubbles overlap.
        val s = QuickFan.slots
        for (i in s.indices) for (j in i + 1 until s.size) {
            val (x1, y1) = QuickFan.offset(s[i]); val (x2, y2) = QuickFan.offset(s[j])
            assertTrue("${s[i].type}/${s[j].type}", Math.hypot((x1 - x2).toDouble(), (y1 - y2).toDouble()) > (s[i].sizeDp + s[j].sizeDp) / 2)
        }
    }

    @Test fun hitTestFindsTheBubbleUnderTheFingerAndNothingOnTheButtonOrBetween() {
        assertEquals("hazard", QuickFan.hitTest(0f, -170f)?.type)
        assertEquals("hazard", QuickFan.hitTest(20f, -185f)?.type)         // within radius + slop
        assertEquals("closure", QuickFan.hitTest(-172f, 5f)?.type)
        assertEquals("traffic", QuickFan.hitTest(-157f, -65f)?.type)
        assertEquals("accident", QuickFan.hitTest(-120f, -120f)?.type)
        assertNull(QuickFan.hitTest(0f, 0f))                               // on the button
        assertNull(QuickFan.hitTest(-10f, -30f))
        assertNull(QuickFan.hitTest(60f, 60f))                             // down-right: nothing there
        assertNull(QuickFan.hitTest(0f, -110f))                            // inside the arc
        assertNull(QuickFan.hitTest(-400f, -400f))
        assertEquals("hazard", QuickFan.hitTest(0f, -85f, scale = 0.5f)?.type)
    }

    @Test fun arcScalesDownOnlyWhenTheScreenIsTooSmall() {
        assertEquals(1f, QuickFan.scaleToFit(360f, 600f), 0f)
        assertEquals(0.75f, QuickFan.scaleToFit(163.5f, 600f), 0.001f)
        assertEquals(0.6f, QuickFan.scaleToFit(50f, 50f), 0f)
    }

    @Test fun everyTypeWithOptionsHasADefaultAndMapIssueNeverAutoSends() {
        assertEquals("heavy", ReportDefaults.defaultSubtype("traffic"))
        assertEquals("visible", ReportDefaults.defaultSubtype("police"))
        assertEquals("minor", ReportDefaults.defaultSubtype("accident"))
        assertEquals("object_on_road", ReportDefaults.defaultSubtype("hazard"))
        assertNull(ReportDefaults.defaultSubtype("closure"))
        assertTrue(ReportDefaults.autoSends("accident")); assertFalse(ReportDefaults.autoSends("map_issue"))
        assertEquals(3_000L, ReportDefaults.AUTO_SEND_MS)
    }

    // ---- Gesture ---------------------------------------------------------------------------------

    @Test fun aQuickTapOpensTheDrawer() {
        val g = HoldToReport()
        g.down(0)
        assertEquals(Effect.None, g.tick(100))
        assertEquals(Effect.OpenSheet, g.up(3f, -2f, 150))
        assertEquals(HoldToReport.Phase.IDLE, g.phase)
    }

    @Test fun holdOpensTheArcSlideSelectsWithATickAndReleaseContinuesToTheDetailSheet() {
        val g = HoldToReport()
        g.down(0)
        assertEquals(Effect.None, g.tick(299))
        assertEquals(Effect.FanOpened, g.tick(300))
        assertEquals(Effect.None, g.tick(400))
        assertEquals(Effect.None, g.move(0f, -30f, 420))                  // still on the button: nothing selected
        val sel = g.move(0f, -170f, 500)
        assertEquals("hazard", (sel as Effect.Selected).slot?.type)
        assertEquals(Effect.None, g.move(4f, -172f, 520))                 // same slot: no second tick
        assertEquals("police", (g.move(-65f, -157f, 600) as Effect.Selected).slot?.type)
        assertEquals("hazard", (g.move(0f, -170f, 700) as Effect.Selected).slot?.type)
        assertEquals(Effect.Continue("hazard"), g.up(0f, -170f, 800))
    }

    @Test fun releasingOutsideASlotCancels() {
        val g = HoldToReport()
        g.down(0); g.tick(320)
        g.move(0f, -170f, 400)
        assertEquals(Effect.Selected(null), g.move(0f, -110f, 450))       // slid off: banner back to the hint
        assertEquals(Effect.Cancel, g.up(0f, -110f, 500))
        // Release back on the button = cancel too.
        g.down(1_000); g.tick(1_400)
        assertEquals(Effect.Cancel, g.up(0f, 0f, 1_500))
    }

    @Test fun draggingFastStillOpensTheFanOnceHeldAndALongPressWithoutTheFanNeverOpensTheSheet() {
        val g = HoldToReport()
        g.down(0)
        assertEquals(Effect.None, g.move(-40f, -60f, 120))                // moved before the hold time
        assertEquals(Effect.None, g.tick(310))                            // moving: the fan opens on the next move
        assertEquals("hazard", (g.move(0f, -170f, 330) as Effect.Selected).slot?.type)
        assertEquals(Effect.Continue("hazard"), g.up(0f, -170f, 400))
        // A drag that ends before the hold time is neither a tap nor a report.
        g.down(1_000); g.move(-80f, 0f, 1_100)
        assertEquals(Effect.Cancel, g.up(-80f, 0f, 1_200))
    }

    @Test fun aSystemCancelSendsNothing() {
        val g = HoldToReport()
        g.down(0); g.tick(300); g.move(0f, -170f, 350)
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
