package my.gimano.app.nav

import my.gimano.app.core.geo.GeoPoint
import my.gimano.app.core.nav.LiveAlertsOnRoute
import my.gimano.app.core.nav.RouteGeometry
import my.gimano.app.data.model.Report
import org.junit.Assert.*
import org.junit.Test

/** docs/driving.md §6.1: a report made after the route was calculated still reaches the trip (matched on the phone). */
class LiveAlertsOnRouteTest {
    // A straight road heading due north, ~2.2 km (0.02° of latitude).
    private val road = RouteGeometry(listOf(GeoPoint(3.0, 101.0), GeoPoint(3.01, 101.0), GeoPoint(3.02, 101.0)))

    private fun report(id: String, lat: Double, lng: Double = 101.0, type: String = "accident", subtype: String? = null, heading: Double? = null) =
        Report(id, type, subtype, lat, lng, heading, null, null, "2026-10-26T10:00:00Z", "2026-10-26T11:00:00Z")

    @Test fun aCrashOnTheRoadAheadJoinsTheTripWithItsAlongDistance() {
        val m = LiveAlertsOnRoute.match(road, listOf(report("a", 3.009, heading = 5.0)))
        assertEquals(1, m.size)
        assertEquals(1_000.0, m[0].distanceAlongRouteM, 15.0)
    }

    @Test fun otherSideAndOppositeHeadingAndOffRoadReportsAreLeftOut() {
        val m = LiveAlertsOnRoute.match(road, listOf(
            report("side", 3.009, subtype = "other_side"),
            report("opposite", 3.009, heading = 185.0),
            report("far", 3.009, lng = 101.01),               // ~1.1 km off the road
            report("noHeading", 3.012),                        // no heading: counts
        ))
        assertEquals(listOf("noHeading"), m.map { it.id })
    }

    @Test fun theQuestionIsAskedFrom150mBeforeToHundredAfter() {
        assertFalse(LiveAlertsOnRoute.asks(400.0))
        assertFalse(LiveAlertsOnRoute.asks(151.0))
        assertTrue(LiveAlertsOnRoute.asks(150.0))
        assertTrue(LiveAlertsOnRoute.asks(0.0))
        assertTrue(LiveAlertsOnRoute.asks(-100.0))
        assertFalse(LiveAlertsOnRoute.asks(-101.0))
    }
}
