package my.gimano.app.car

import kotlinx.coroutines.flow.MutableStateFlow
import my.gimano.app.core.geo.GeoPoint
import my.gimano.app.data.model.LatLngDto
import my.gimano.app.data.model.RouteRequest
import my.gimano.app.nav.NavDestination
import org.junit.Assert.*
import org.junit.Test

class CarPreviewTest {
    private fun preview() = CarPreview(
        NavDestination("Station", "", GeoPoint(3.139, 101.6869), null),
        RouteRequest(LatLngDto(3.14, 101.68), LatLngDto(3.139, 101.6869)), emptyList())

    @Test fun identicalRequestPublishesNewScreensPreview() {
        val first = preview()
        val state = MutableStateFlow(first)
        val reopened = preview()
        state.value = reopened
        assertSame("A reopened screen must receive its own preview, not the previous equal object", reopened, state.value)
    }

    @Test fun selectionCopiesKeepOriginalScreenOwner() {
        val original = preview()
        val state = MutableStateFlow(original)
        state.value = original.select(1)
        state.value = state.value.select(0)
        assertSame(original, state.value.owner)
        assertEquals(0, state.value.selected)
    }
}
