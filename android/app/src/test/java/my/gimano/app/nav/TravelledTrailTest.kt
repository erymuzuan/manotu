package my.gimano.app.nav

import my.gimano.app.core.geo.GeoPoint
import my.gimano.app.core.geo.Polyline
import my.gimano.app.core.nav.CameraMode
import my.gimano.app.core.nav.CameraTarget
import my.gimano.app.core.nav.NavProgress
import my.gimano.app.core.nav.RouteGeometry
import my.gimano.app.core.nav.TravelledTrail
import my.gimano.app.data.location.Fix
import my.gimano.app.data.model.Route
import org.junit.Assert.*
import org.junit.Test
import java.time.Instant

/** docs/driving.md §6.3: the grey travelled line behind the arrow. */
class TravelledTrailTest {
    private val line = (0..200).map { GeoPoint(3.0, 101.0 + it * 0.0005) }   // east, ~55.6 m per segment
    private val g = RouteGeometry(line)

    @Test fun splitIndexIsTheLastVertexAtOrBeforeTheArrow() {
        val cum = doubleArrayOf(0.0, 10.0, 25.0, 40.0)
        assertEquals(0, TravelledTrail.splitIndex(cum, -5.0))
        assertEquals(0, TravelledTrail.splitIndex(cum, 0.0))
        assertEquals(0, TravelledTrail.splitIndex(cum, 9.99))
        assertEquals(1, TravelledTrail.splitIndex(cum, 10.0))
        assertEquals(2, TravelledTrail.splitIndex(cum, 39.0))
        assertEquals(3, TravelledTrail.splitIndex(cum, 40.0))
        assertEquals(3, TravelledTrail.splitIndex(cum, 1e9))
        assertEquals(0, TravelledTrail.splitIndex(DoubleArray(0), 5.0))
    }

    @Test fun tailEndsExactlyAtTheArrowAndTheStablePartIsSentOnlyWhenItMoves() {
        val t = TravelledTrail(g, rebaseVertices = 4, rebaseTailM = 10_000.0)
        val seg = g.cumulative[1]
        val first = t.update(seg * 1.5)
        assertEquals(listOf(line[0]), first.stable)                      // first frame: always sent
        assertEquals(listOf(line[0], line[1], g.pointAt(seg * 1.5).first), first.tail)
        val next = t.update(seg * 2.5)
        assertNull("unchanged stable part is not re-sent", next.stable)
        assertEquals(g.pointAt(seg * 2.5).first, next.tail.last())
        assertEquals(line[0], next.tail.first())
        // Past 4 vertices beyond the stable end: the stable part moves up to the arrow's vertex.
        val rebased = t.update(seg * 5.5)
        assertEquals(line.subList(0, 6), rebased.stable)
        assertEquals(listOf(line[5], g.pointAt(seg * 5.5).first), rebased.tail)
        // Stable + tail always cover the whole travelled part, start to arrow, with no gap.
        assertEquals(rebased.stable!!.last(), rebased.tail.first())
    }

    @Test fun longTailsAreRebasedByDistanceToo() {
        val t = TravelledTrail(g, rebaseVertices = 1_000, rebaseTailM = 200.0)
        t.update(10.0)
        assertNull(t.update(150.0).stable)
        assertNotNull(t.update(260.0).stable)
    }

    @Test fun aResnapBehindTheStablePartRebuildsIt() {
        val t = TravelledTrail(g, rebaseVertices = 2, rebaseTailM = 10_000.0)
        t.update(g.cumulative[10] + 1)
        t.update(g.cumulative[20] + 1)
        val back = t.update(g.cumulative[5] + 1)
        assertEquals(line.subList(0, 6), back.stable)
        assertEquals(2, back.tail.size)
    }

    @Test fun atTheVertexTheTailHasNoDuplicatePointAndTheEndIsClamped() {
        val t = TravelledTrail(g)
        assertEquals(listOf(line[0]), t.update(-50.0).tail)              // nothing travelled yet: draws nothing
        val end = t.update(g.lengthM + 500)
        assertEquals(line, end.stable)                                   // arrived: the whole route is travelled
        assertEquals(listOf(line.last()), end.tail)                      // no duplicate of the end vertex
        val mid = TravelledTrail(g).update(g.cumulative[3])              // exactly on a vertex
        assertEquals(listOf(line[0], line[1], line[2], line[3]), mid.tail)
    }

    @Test fun rendererFramesCarryTheTrailAndARerouteStartsAFreshOne() {
        val route = Route("r1", durationS = 600.0, distanceM = g.lengthM, polyline = Polyline.encode(line))
        fun state(r: Route, along: Double, t: Long): NavState {
            val geo = RouteGeometry(Polyline.decode(r.polyline))
            val p = geo.pointAt(along).first
            val progress = NavProgress(p, 90.0, along, 0.0, geo.lengthM - along, 100.0, 1, null, 0, 500.0, null, false)
            return NavState(active = true, route = r, progress = progress, fix = Fix(p, 25f, 90f, 5f, t), puck = p, puckBearing = 90.0,
                puckSnapped = true, puckAlongM = along, nextManeuverAlongM = along + 500, camera = CameraTarget(CameraMode.BANDAR),
                startedAt = Instant.parse("2026-10-25T10:00:00Z"))
        }
        val r = DriveRenderer()
        r.onState(state(route, 1_000.0, 1), 0)
        val f = r.frame(0, 500.0)!!
        assertEquals(line[0], f.trail!!.stable!!.first())
        assertEquals(1_000.0, g.cumulative[TravelledTrail.splitIndex(g.cumulative, 1_000.0)], 60.0)
        // Reroute from here: the new route starts at the car; its trail starts empty (the old one is gone).
        val newLine = (0..50).map { GeoPoint(3.0 + it * 0.0005, 101.0 + 18 * 0.0005) }   // north from ~1 km in
        val rerouted = Route("r2", durationS = 300.0, distanceM = 2_000.0, polyline = Polyline.encode(newLine))
        r.onState(state(rerouted, 0.0, 2), 1_000)
        val f2 = r.frame(1_000, 500.0)!!
        assertEquals(newLine[0].lat, f2.trail!!.stable!!.single().lat, 1e-5)
        assertTrue(f2.trail!!.tail.size <= 2)
    }
}
