package my.gimano.app.nav

import kotlinx.serialization.json.Json
import my.gimano.app.core.format.Lang
import my.gimano.app.core.geo.GeoMath
import my.gimano.app.core.geo.GeoPoint
import my.gimano.app.core.geo.Polyline
import my.gimano.app.core.nav.ArrivalRule
import my.gimano.app.core.nav.ArrivalText
import my.gimano.app.core.nav.LastMetres
import my.gimano.app.core.nav.NavigationTracker
import my.gimano.app.core.nav.Side
import my.gimano.app.data.model.Leg
import my.gimano.app.data.model.Maneuver
import my.gimano.app.data.model.NavigationPoint
import my.gimano.app.data.model.Place
import my.gimano.app.data.model.Route
import org.junit.Assert.*
import org.junit.Test

/** docs/driving.md §4: arriving at the entrance. */
class ArrivalTest {
    private val end = GeoPoint(3.0, 101.01)
    /** Heading east, the road's left is north. */
    private val north = GeoMath.offset(end, 0.0, 25.0)
    private val south = GeoMath.offset(end, 180.0, 25.0)

    @Test fun arrivedAt30mAlongTheRouteOr40mFromThePin() {
        assertTrue(ArrivalRule.arrived(30.0, 5.0, 300.0, true))
        assertFalse(ArrivalRule.arrived(31.0, 5.0, 300.0, true))
        assertFalse("off the route, the along-route rule doesn't count", ArrivalRule.arrived(10.0, 60.0, 300.0, true))
        assertTrue("near the pin", ArrivalRule.arrived(200.0, 5.0, 40.0, true))
        assertFalse("never before the last leg", ArrivalRule.arrived(10.0, 5.0, 10.0, false))
    }

    @Test fun trackerUsesThePin() {
        val line = (0..20).map { GeoPoint(3.0, 101.0 + it * 0.0005) }  // ~1.1 km east
        val r = Route("r", durationS = 100.0, distanceM = 1_100.0, polyline = Polyline.encode(line), legs = listOf(Leg(listOf(
            Maneuver("depart", beginShapeIndex = 0), Maneuver("arrive", beginShapeIndex = 20)))))
        // Pin 35 m north of a point 150 m before the route end.
        val nearPin = GeoMath.offset(line[17], 0.0, 35.0)
        val t = NavigationTracker(r, nearPin)
        assertFalse(t.update(line[10])!!.arrived)
        assertTrue("within 40 m of the pin before the route end", t.update(line[17])!!.arrived)
        val plain = NavigationTracker(r, null)
        assertFalse(plain.update(line[17])!!.arrived)
        assertTrue(plain.update(GeoMath.offset(line[20], 270.0, 25.0))!!.arrived)
    }

    @Test fun lastMetresDashedToTheEntranceThenToThePin() {
        val entrance = GeoMath.offset(end, 0.0, 20.0)
        val pin = GeoMath.offset(end, 0.0, 120.0)
        val l = LastMetres.lines(end, entrance, pin)
        assertEquals(listOf("entrance", "pin"), l.map { it.kind })
        assertEquals(listOf(end, entrance), l[0].points)
        assertEquals(listOf(entrance, pin), l[1].points)
        // Pin within 15 m of the route end: no grey line.
        assertEquals(listOf("entrance"), LastMetres.lines(end, entrance, GeoMath.offset(end, 90.0, 10.0)).map { it.kind })
        // No entrance: grey from the route end to the pin.
        assertEquals(listOf(end, pin), LastMetres.lines(end, null, pin).single().points)
        assertTrue(LastMetres.lines(end, null, GeoMath.offset(end, 0.0, 10.0)).isEmpty())
    }

    @Test fun sideOfTheDirectionOfTravel() {
        assertEquals(Side.LEFT, ArrivalText.side(end, 90.0, north))
        assertEquals(Side.RIGHT, ArrivalText.side(end, 90.0, south))
        assertEquals(Side.RIGHT, ArrivalText.side(end, 270.0, north))
        assertNull(ArrivalText.side(end, 90.0, GeoMath.offset(end, 0.0, 1.0)))
    }

    @Test fun arrivalLineWording() {
        val main = NavigationPoint(north.lat, north.lng, source = "osm_entrance", kind = "main")
        assertEquals("Pintu masuk utama di sebelah kiri · 25 m dari jalan", ArrivalText.line(main, end, 90.0, null, Lang.MS))
        assertEquals("Main entrance on your left · 25 m from the road", ArrivalText.line(main, end, 90.0, null, Lang.EN))
        val other = NavigationPoint(south.lat, south.lng, source = "confirmed", kind = null)
        assertEquals("Entrance on your right · 25 m from the road", ArrivalText.line(other, end, 90.0, null, Lang.EN))
        val outline = NavigationPoint(north.lat, north.lng, source = "outline")
        assertEquals("Tempat ini di sebelah kiri · 25 m dari jalan", ArrivalText.line(outline, end, 90.0, GeoMath.offset(end, 0.0, 80.0), Lang.MS))
        assertEquals("The place is on your left · 25 m from the road", ArrivalText.line(outline, end, 90.0, null, Lang.EN))
        // Route ends at the entrance itself: the side comes from the pin, no distance.
        val atRoad = NavigationPoint(end.lat, end.lng, kind = "main")
        assertEquals("Main entrance on your right", ArrivalText.line(atRoad, end, 90.0, south, Lang.EN))
        assertNull(ArrivalText.line(null, end, 90.0, north, Lang.EN))
    }

    @Test fun parsesArrivalAndNavigationPoint() {
        val json = Json { ignoreUnknownKeys = true }
        val r = json.decodeFromString(Route.serializer(), """{"id":"r","durationS":1,"distanceM":1,"polyline":"",
            "arrival":{"lat":3.1180302,"lng":101.6768485,"source":"osm_entrance","kind":"main"}}""")
        assertEquals("main", r.arrival!!.kind)
        val p = json.decodeFromString(Place.serializer(), """{"id":"w922804567","name":"Mid Valley Megamall","lat":3.117928,"lng":101.676998,
            "navigationPoint":{"lat":3.1180302,"lng":101.6768485,"source":"osm_entrance","kind":"main"}}""")
        assertEquals(3.1180302, p.navigationPoint!!.lat, 1e-9)
        assertEquals(p.navigationPoint, p.summary().navigationPoint)
    }
}
