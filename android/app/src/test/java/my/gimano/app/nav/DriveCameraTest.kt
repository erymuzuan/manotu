package my.gimano.app.nav

import my.gimano.app.core.format.Lang
import my.gimano.app.core.geo.GeoMath
import my.gimano.app.core.geo.GeoPoint
import my.gimano.app.core.geo.Polyline
import my.gimano.app.core.nav.CameraMode
import my.gimano.app.core.nav.CameraModeController
import my.gimano.app.core.nav.Easer
import my.gimano.app.core.nav.HeadingFilter
import my.gimano.app.core.nav.Problem
import my.gimano.app.core.nav.PuckAnimator
import my.gimano.app.core.nav.RouteGeometry
import my.gimano.app.core.nav.SimpangRule
import my.gimano.app.core.nav.SnapHysteresis
import my.gimano.app.core.nav.SpeedModeSelector
import my.gimano.app.core.nav.TinjauInfo
import my.gimano.app.core.nav.TinjauPlanner
import my.gimano.app.core.nav.TinjauText
import my.gimano.app.core.nav.TinjauZoom
import my.gimano.app.data.model.AlertOnRoute
import my.gimano.app.data.model.Route
import my.gimano.app.data.model.TrafficSegment
import org.junit.Assert.*
import org.junit.Test

/** docs/driving.md §2 (camera modes) and §3 (steady arrow): the pure parts. */
class DriveCameraTest {
    private val line = (0..200).map { GeoPoint(3.0, 101.0 + it * 0.0005) }   // ~11 km east, vertex every ~55 m
    private val g = RouteGeometry(line)

    // ---- speed modes -------------------------------------------------------------------------------

    @Test fun speedModesNeedFiveSecondsPastTheThreshold() {
        val s = SpeedModeSelector()
        assertEquals(CameraMode.PERLAHAN, s.update(20.0, 0))
        assertEquals(CameraMode.PERLAHAN, s.update(40.0, 1_000))
        assertEquals(CameraMode.PERLAHAN, s.update(40.0, 5_900))
        assertEquals(CameraMode.BANDAR, s.update(40.0, 6_000))
    }

    @Test fun hysteresisOfFiveKmh() {
        val s = SpeedModeSelector()
        s.update(60.0, 0)                                              // Bandar
        // 82 km/h is past 80 but not 85: stays Bandar however long.
        for (t in 0..20) assertEquals(CameraMode.BANDAR, s.update(82.0, t * 1_000L))
        for (t in 21..26) s.update(90.0, t * 1_000L)
        assertEquals(CameraMode.LEBUH_RAYA, s.mode)
        // Back below 80 but above 75: still Lebuh raya.
        for (t in 27..40) assertEquals(CameraMode.LEBUH_RAYA, s.update(78.0, t * 1_000L))
        for (t in 41..46) s.update(70.0, t * 1_000L)
        assertEquals(CameraMode.BANDAR, s.mode)
        // Perlahan only below 25 (not at 28).
        for (t in 47..60) assertEquals(CameraMode.BANDAR, s.update(28.0, t * 1_000L))
    }

    @Test fun aBriefDipDoesNotSwitch() {
        val s = SpeedModeSelector()
        s.update(100.0, 0)
        s.update(60.0, 1_000); s.update(60.0, 4_000)
        assertEquals(CameraMode.LEBUH_RAYA, s.update(100.0, 5_000))
        assertEquals(CameraMode.LEBUH_RAYA, s.update(60.0, 8_000))   // the timer restarted at 8 s
        assertEquals(CameraMode.LEBUH_RAYA, s.update(60.0, 12_000))
        assertEquals(CameraMode.BANDAR, s.update(60.0, 13_000))
    }

    // ---- Simpang ---------------------------------------------------------------------------------------

    @Test fun simpangWithin300mOr15sUntil50mAfter() {
        assertTrue(SimpangRule.active("right", 290.0, null, null, 30.0))
        assertFalse(SimpangRule.active("right", 350.0, null, null, 30.0))
        assertTrue("15 s at 100 km/h ≈ 417 m", SimpangRule.active("exit_left", 400.0, null, null, 100.0))
        assertFalse(SimpangRule.active("straight", 100.0, null, null, 30.0))
        assertTrue("40 m after the turn", SimpangRule.active("left", 900.0, "right", 40.0, 30.0))
        assertFalse("60 m after the turn", SimpangRule.active("left", 900.0, "right", 60.0, 30.0))
    }

    // ---- Tinjau ----------------------------------------------------------------------------------------

    private fun route(segments: List<TrafficSegment> = emptyList(), alerts: List<AlertOnRoute> = emptyList(), traffic: Double? = null) =
        Route("r", durationS = 600.0, distanceM = g.lengthM, trafficDurationS = traffic, polyline = Polyline.encode(line), trafficSegments = segments, alerts = alerts)

    @Test fun jamsAreMergedFromContiguousHeavySegments() {
        val p = TinjauPlanner.problems(route(listOf(TrafficSegment(50, 60, 3), TrafficSegment(60, 72, 4), TrafficSegment(100, 110, 2))), g)
        assertEquals(1, p.size)
        assertEquals("jam", p[0].kind)
        assertEquals(g.distanceAtIndex(50), p[0].startAlongM, 0.1)
        assertEquals(g.distanceAtIndex(72) - g.distanceAtIndex(50), p[0].lengthM!!, 0.1)
    }

    @Test fun tinjauOncePerJamOnlyWithin5kmAndHeldSixPointTwoSeconds() {
        val c = CameraModeController()
        c.setRoute(route(listOf(TrafficSegment(150, 170, 4)), traffic = 960.0), g)
        val jamAt = g.distanceAtIndex(150)
        // 6 km before: nothing yet.
        assertEquals(CameraMode.BANDAR, c.update(60.0, jamAt - 6_000, null, null, null, null, 0).mode)
        val t = c.update(60.0, jamAt - 4_800, null, null, null, null, 1_000)
        assertEquals(CameraMode.TINJAU, t.mode)
        assertEquals(4_800.0, t.tinjau!!.distanceM, 1.0)
        assertEquals(360.0, t.tinjau!!.delayS!!, 0.1)
        assertEquals(CameraMode.TINJAU, c.update(60.0, jamAt - 4_700, null, null, null, null, 7_000).mode)
        assertEquals(CameraMode.BANDAR, c.update(60.0, jamAt - 4_600, null, null, null, null, 8_300).mode)
        // Not repeated for the same jam.
        for (k in 1..60) assertNotEquals(CameraMode.TINJAU, c.update(60.0, jamAt - 4_500 + k * 50, null, null, null, null, 9_000L + k * 1_000).mode)
    }

    @Test fun simpangBeatsTinjauAndAManeuverWithin20sSkipsIt() {
        val c = CameraModeController()
        c.setRoute(route(listOf(TrafficSegment(150, 170, 4))), g)
        val jamAt = g.distanceAtIndex(150)
        assertEquals(CameraMode.SIMPANG, c.update(60.0, jamAt - 4_000, "right", 200.0, null, null, 0).mode)
        // 300 m at 50 km/h = 21.6 s: Simpang no (> 300 m? no, = 300 m is Simpang) → use 320 m at 60 km/h = 19 s.
        assertNotEquals(CameraMode.TINJAU, c.update(60.0, jamAt - 3_900, "right", 320.0, null, null, 1_000).mode)
        // Once the turn is done, the jam is shown (it was only skipped, not used up).
        assertEquals(CameraMode.TINJAU, c.update(60.0, jamAt - 3_700, "left", 2_000.0, "right", 120.0, 2_000).mode)
        // A turn coming up during the zoom-out ends it at once.
        assertEquals(CameraMode.SIMPANG, c.update(60.0, jamAt - 3_650, "left", 250.0, null, null, 3_000).mode)
    }

    /** Seen on the Desktop Head Unit: a jam 5 km ahead, an exit 320 m ahead at 50 km/h (23 s): Simpang would cut it at once. */
    @Test fun tinjauWaitsUntilSimpangWouldNotCutItShortAndIsReArmedWhenCut() {
        val c = CameraModeController()
        c.setRoute(route(listOf(TrafficSegment(150, 170, 4))), g)
        val jamAt = g.distanceAtIndex(150)
        assertNotEquals(CameraMode.TINJAU, c.update(50.0, jamAt - 4_900, "exit_left", 320.0, null, null, 0).mode)
        assertEquals(CameraMode.SIMPANG, c.update(50.0, jamAt - 4_880, "exit_left", 300.0, null, null, 1_000).mode)
        // After the exit: shown now (not used up while it was skipped).
        assertEquals(CameraMode.TINJAU, c.update(50.0, jamAt - 4_500, "exit_left", 9_000.0, "exit_left", 80.0, 30_000).mode)

        // Cut short by a turn that came up faster (speeding up): shown again afterwards.
        val d = CameraModeController()
        d.setRoute(route(listOf(TrafficSegment(150, 170, 4))), g)
        assertEquals(CameraMode.TINJAU, d.update(60.0, jamAt - 4_800, null, null, null, null, 0).mode)
        assertEquals(CameraMode.SIMPANG, d.update(60.0, jamAt - 4_780, "right", 250.0, null, null, 1_500).mode)
        assertEquals(CameraMode.TINJAU, d.update(60.0, jamAt - 4_400, "left", 3_000.0, "right", 100.0, 30_000).mode)
    }

    @Test fun closureAccidentAndHazardAlertsAlsoTriggerTinjau() {
        val alert = AlertOnRoute("a1", "accident", lat = 3.0, lng = 101.05, createdAt = "", expiresAt = "", distanceAlongRouteM = 5_000.0)
        val police = alert.copy(id = "p1", type = "police", distanceAlongRouteM = 4_000.0)
        val c = CameraModeController()
        c.setRoute(route(alerts = listOf(police, alert)), g)
        val t = c.update(60.0, 1_000.0, null, null, null, null, 0)
        assertEquals(CameraMode.TINJAU, t.mode)
        assertEquals("accident", t.tinjau!!.problem.kind)
        assertNull("delay only for jams", t.tinjau!!.delayS)
    }

    @Test fun tinjauText() {
        val jam = TinjauInfo(Problem("j", "jam", 0.0, 1_200.0, GeoPoint(0.0, 0.0)), 4_800.0, 360.0, 0)
        assertEquals("Sesak 4.8 km di hadapan · 1.2 km panjang · +6 min", TinjauText.line(jam, Lang.MS))
        assertEquals("Traffic 4.8 km ahead · 1.2 km long · +6 min", TinjauText.line(jam, Lang.EN))
        assertEquals("Traffic 4.8 km ahead · 1.2 km long", TinjauText.line(jam.copy(delayS = null), Lang.EN))
    }

    @Test fun tinjauZoomFitsTheProblemButNeverBelow12Point5() {
        val near = TinjauZoom.fit(1_000.0, 3.0, 900.0, 0.76, 16.0)
        val far = TinjauZoom.fit(5_000.0, 3.0, 900.0, 0.76, 16.0)
        assertTrue(far < near)
        assertEquals(12.5, TinjauZoom.fit(50_000.0, 3.0, 450.0, 0.76, 16.0), 1e-9)
        assertEquals(16.0, TinjauZoom.fit(10.0, 3.0, 450.0, 0.76, 16.0), 1e-9)
        // The fitted view really covers the distance: metres per dp × available dp ≥ distance.
        val mpp = 40_075_016.686 * Math.cos(Math.toRadians(3.0)) / (512 * Math.pow(2.0, far))
        assertTrue(far > 12.5 && mpp * 900 * 0.76 >= 5_000.0)
    }

    // ---- steady arrow ------------------------------------------------------------------------------------

    @Test fun snapWithin25mAndReleaseOnlyAfter3sBeyond40m() {
        val s = SnapHysteresis()
        assertFalse(s.update(30.0, 90.0, 90.0, 50.0, 0))
        assertTrue(s.update(20.0, 90.0, 90.0, 50.0, 1_000))
        assertTrue("35 m: still snapped", s.update(35.0, 90.0, 90.0, 50.0, 2_000))
        assertTrue(s.update(45.0, 90.0, 90.0, 50.0, 3_000))
        assertTrue(s.update(45.0, 90.0, 90.0, 50.0, 5_900))
        assertFalse(s.update(45.0, 90.0, 90.0, 50.0, 6_000))
    }

    @Test fun snapNeedsAMatchingHeadingAbove10Kmh() {
        assertFalse(SnapHysteresis().update(5.0, 200.0, 90.0, 50.0, 0))
        assertTrue(SnapHysteresis().update(5.0, 200.0, 90.0, 5.0, 0))
        assertTrue(SnapHysteresis().update(5.0, 140.0, 90.0, 50.0, 0))
    }

    @Test fun briefExcursionsDoNotUnsnap() {
        val s = SnapHysteresis()
        s.update(0.0, null, 0.0, 50.0, 0)
        s.update(50.0, null, 0.0, 50.0, 1_000); s.update(50.0, null, 0.0, 50.0, 3_000)
        s.update(10.0, null, 0.0, 50.0, 3_500)        // back on: the 3 s restart
        assertTrue(s.update(50.0, null, 0.0, 50.0, 4_000))
        assertTrue(s.update(50.0, null, 0.0, 50.0, 6_500))
    }

    @Test fun headingTurnsAtMost90DegreesPerSecond() {
        val h = HeadingFilter()
        h.update(0.0, 0)
        var last = 0.0
        for (k in 1..10) {
            val v = h.update(180.0, k * 100L)
            assertTrue("≤ 9° per 100 ms", Math.abs(GeoMath.angleDiff(last, v)) <= 9.0 + 1e-9)
            last = v
        }
        // Wraps the short way round 0°/360°.
        val w = HeadingFilter(); w.update(350.0, 0)
        val v = w.update(10.0, 1_000)
        assertTrue(v > 350.0 || v < 10.0)
    }

    @Test fun headingIsLowPassedNotJumpy() {
        val h = HeadingFilter()
        h.update(90.0, 0)
        val v = h.update(100.0, 50)                     // 50 ms later, 10° change
        assertTrue(v > 90.0 && v < 95.0)
        var x = v
        for (k in 2..40) x = h.update(100.0, k * 50L)
        assertEquals(100.0, x, 0.5)
    }

    @Test fun puckInterpolatesAlongTheRouteOverTheFixInterval() {
        val a = PuckAnimator(g)
        a.onFix(g.pointAt(1_000.0).first, 1_000.0, 25.0, 5_000.0, 0)
        a.onFix(g.pointAt(1_025.0).first, 1_025.0, 25.0, 5_000.0, 1_000)
        assertEquals(1_000.0, a.pose(1_000)!!.alongM!!, 0.01)
        assertEquals(1_012.5, a.pose(1_500)!!.alongM!!, 0.01)
        assertEquals(1_025.0, a.pose(2_000)!!.alongM!!, 0.01)
        // The drawn point is on the line (not a straight cut across a bend).
        val p = a.pose(1_500)!!
        assertEquals(0.0, g.snap(p.point)!!.distanceFromRouteM, 0.5)
    }

    @Test fun intervalClampedTo300msAnd1200ms() {
        val a = PuckAnimator(g)
        a.onFix(g.pointAt(0.0).first, 0.0, 10.0, null, 0)
        a.onFix(g.pointAt(30.0).first, 30.0, 10.0, null, 5_000)     // a 5 s gap animates over 1.2 s
        assertEquals(30.0, a.pose(5_000 + 1_200)!!.alongM!!, 0.01)
        a.onFix(g.pointAt(40.0).first, 40.0, 10.0, null, 5_100)     // 100 ms → 300 ms
        assertTrue(a.pose(5_250)!!.alongM!! < 40.0)
    }

    @Test fun deadReckonsUpTo1sButNeverPastTheManeuver() {
        val a = PuckAnimator(g)
        a.onFix(g.pointAt(0.0).first, 0.0, 20.0, 1_100.0, 0)
        a.onFix(g.pointAt(1_000.0).first, 1_000.0, 20.0, 1_100.0, 1_000)
        // Arrived at 1000 at t=2000; then 20 m/s for at most 1 s.
        assertEquals(1_010.0, a.pose(2_500)!!.alongM!!, 0.01)
        assertEquals(1_020.0, a.pose(3_000)!!.alongM!!, 0.01)
        assertEquals("holds after 1 s", 1_020.0, a.pose(9_000)!!.alongM!!, 0.01)
        val b = PuckAnimator(g)
        b.onFix(g.pointAt(1_000.0).first, 1_000.0, 20.0, 1_005.0, 0)
        b.onFix(g.pointAt(1_000.0).first, 1_000.0, 20.0, 1_005.0, 1_000)
        assertEquals("capped at the maneuver", 1_005.0, b.pose(3_000)!!.alongM!!, 0.01)
    }

    @Test fun smallBackwardJitterHoldsInsteadOfReversing() {
        val a = PuckAnimator(g)
        a.onFix(g.pointAt(500.0).first, 500.0, 0.0, null, 0)
        a.onFix(g.pointAt(495.0).first, 495.0, 0.0, null, 1_000)
        assertEquals(500.0, a.pose(1_500)!!.alongM!!, 0.01)
    }

    @Test fun offRouteInterpolatesStraight() {
        val a = PuckAnimator(null)
        val p0 = GeoPoint(3.0, 101.0); val p1 = GeoPoint(3.0, 101.0002)
        a.onFix(p0, null, 5.0, null, 0)
        a.onFix(p1, null, 5.0, null, 1_000)
        val mid = a.pose(1_500)!!.point
        assertEquals(101.0001, mid.lng, 1e-7)
    }

    @Test fun easerSmoothsBetweenTargets() {
        val e = Easer(17.0)
        e.set(15.2, 2_000, 0)
        assertEquals(17.0, e.value(0), 1e-9)
        assertEquals(16.1, e.value(1_000), 1e-9)
        assertEquals(15.2, e.value(2_000), 1e-9)
        e.set(15.2, 2_000, 2_500)                         // same target: no restart
        assertEquals(15.2, e.value(2_600), 1e-9)
    }
}
