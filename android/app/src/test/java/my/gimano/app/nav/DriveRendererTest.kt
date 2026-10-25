package my.gimano.app.nav

import my.gimano.app.core.geo.GeoPoint
import my.gimano.app.core.geo.Polyline
import my.gimano.app.core.nav.CameraMode
import my.gimano.app.core.nav.CameraTarget
import my.gimano.app.core.nav.NavProgress
import my.gimano.app.core.nav.RouteGeometry
import my.gimano.app.data.location.Fix
import my.gimano.app.data.model.Route
import org.junit.Assert.*
import org.junit.Test
import java.time.Instant

class DriveRendererTest {
    private val line = (0..200).map { GeoPoint(3.0, 101.0 + it * 0.0005) }   // east
    private val g = RouteGeometry(line)
    private val route = Route("r", durationS = 600.0, distanceM = g.lengthM, polyline = Polyline.encode(line))
    private val started = Instant.parse("2026-10-25T10:00:00Z")

    private fun state(along: Double, t: Long, mode: CameraMode, startedAt: Instant = started): NavState {
        val p = g.pointAt(along).first
        val progress = NavProgress(p, 90.0, along, 0.0, g.lengthM - along, 100.0, 1, null, 0, 500.0, null, false)
        return NavState(active = true, route = route, progress = progress, fix = Fix(p, 25f, 90f, 5f, t), puck = p, puckBearing = 90.0,
            puckSnapped = true, puckAlongM = along, nextManeuverAlongM = along + 500, camera = CameraTarget(mode), startedAt = startedAt)
    }

    @Test fun modeChangesEaseOverTwoSecondsAndThePuckMovesEveryFrame() {
        val r = DriveRenderer()
        r.onState(state(1_000.0, 1, CameraMode.BANDAR), 0)
        assertEquals(16.0, r.frame(0, 500.0)!!.zoom, 1e-9)
        r.onState(state(1_025.0, 2, CameraMode.LEBUH_RAYA), 1_000)
        val mid = r.frame(2_000, 500.0)!!
        assertTrue(mid.zoom < 16.0 && mid.zoom > 15.2)
        assertEquals(15.2, r.frame(3_000, 500.0)!!.zoom, 1e-9)
        // Between fixes the point keeps moving (interpolated), never jumping.
        val a = r.frame(1_200, 500.0)!!.point.lng
        val b = r.frame(1_600, 500.0)!!.point.lng
        assertTrue(b > a)
        assertEquals("heading east, filtered", 90.0, r.frame(3_000, 500.0)!!.bearing, 1.0)
    }

    @Test fun aNewDriveStartsWithoutTheOldHeading() {
        val r = DriveRenderer()
        r.onState(state(1_000.0, 1, CameraMode.BANDAR).copy(puckBearing = 270.0, puckAlongM = null), 0)
        r.frame(0, 500.0)
        r.onState(state(1_000.0, 2, CameraMode.BANDAR, Instant.parse("2026-10-25T11:00:00Z")), 100)
        assertEquals(90.0, r.frame(150, 500.0)!!.bearing, 1.0)
    }
}
