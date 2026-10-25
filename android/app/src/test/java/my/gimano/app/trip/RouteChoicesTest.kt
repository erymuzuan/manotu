package my.gimano.app.trip

import my.gimano.app.core.trip.RouteChoices
import my.gimano.app.core.trip.TravelMode
import my.gimano.app.data.model.Route
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class RouteChoicesTest {
    // Our backend, 26 Oct: Shah Alam → Suria KLCC.
    private val e5 = Route("e5", "best", 43 * 60.0, 41_300.0, hasTolls = true, tollEstimateMyr = 8.56, tollFareComplete = true,
        polyline = "", reasons = listOf("fastest"), viaRoads = listOf("E5"))
    private val ft2 = Route("ft2", durationS = 57 * 60.0, distanceM = 32_000.0, hasTolls = true, tollEstimateMyr = 3.0, tollFareComplete = true,
        polyline = "", reasons = listOf("shortest", "lower_toll"), viaRoads = listOf("FT2"))
    private val nkve = Route("nkve", durationS = 58 * 60.0, distanceM = 56_300.0, hasTolls = true, tollEstimateMyr = 4.06, tollFareComplete = true,
        polyline = "", reasons = listOf("lower_toll"), viaRoads = listOf("E1"))
    private val copy = Route("copy", durationS = 44 * 60.0, distanceM = 42_000.0, polyline = "", hidden = "same_road")

    @Test fun hiddenRoutesAreKeptApart() {
        val all = listOf(e5, ft2, copy, nkve)
        assertEquals(listOf("e5", "ft2", "nkve"), RouteChoices.shown(all).map { it.id })
        assertEquals(listOf("copy"), RouteChoices.hidden(all).map { it.id })
    }

    @Test fun longMotorTripsWithAChoiceOpenTheList() {
        assertTrue(RouteChoices.listFirst(listOf(e5, ft2), TravelMode.CAR, hasStops = false))
        assertTrue(RouteChoices.listFirst(listOf(e5, ft2), TravelMode.MOTORCYCLE, hasStops = false))
        assertFalse(RouteChoices.listFirst(listOf(e5, ft2), TravelMode.CAR, hasStops = true))
        assertFalse(RouteChoices.listFirst(listOf(e5, ft2), TravelMode.WALK, hasStops = false))
        assertFalse(RouteChoices.listFirst(listOf(e5, copy), TravelMode.CAR, hasStops = false))
        val short = e5.copy(distanceM = 9_700.0)
        assertFalse(RouteChoices.listFirst(listOf(short, ft2), TravelMode.CAR, hasStops = false))
    }

    @Test fun olderServersWithoutTheNewFieldsShowEveryRoute() {
        val a = Route("a", "best", 600.0, 12_000.0, polyline = "")
        val b = Route("b", durationS = 700.0, distanceM = 13_000.0, polyline = "")
        assertEquals(2, RouteChoices.shown(listOf(a, b)).size)
        assertTrue(RouteChoices.listFirst(listOf(a, b), TravelMode.CAR, hasStops = false))
    }

    @Test fun comparesWithTheFastest() {
        val shown = listOf(e5, ft2, nkve)
        val c = RouteChoices.compare(ft2, e5, shown)
        assertEquals(14 * 60.0, c.extraS, 0.1)
        assertEquals(5.56, c.tollSavedMyr!!, 0.001)
        assertEquals(9_300.0, c.shorterM!!, 0.1)
        assertNull(c.longerM)
        assertEquals(listOf("E5", "E1"), c.avoids)

        val n = RouteChoices.compare(nkve, e5, shown)
        assertEquals(15_000.0, n.longerM!!, 0.1)
        assertEquals(4.50, n.tollSavedMyr!!, 0.001)

        val dearer = RouteChoices.compare(e5, ft2.copy(id = "f"), listOf(ft2, e5))
        assertNull(dearer.tollSavedMyr)
        assertEquals(5.56, dearer.tollExtraMyr!!, 0.001)
    }

    @Test fun unknownFaresSaveNothing() {
        val unknown = ft2.copy(tollFareComplete = false)
        assertNull(RouteChoices.compare(unknown, e5, listOf(e5, unknown)).tollSavedMyr)
        assertEquals(0.0, RouteChoices.knownToll(ft2.copy(hasTolls = false))!!, 0.0)
    }
}
