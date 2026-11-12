package my.gimano.app.car

import my.gimano.app.core.car.CarNavigationIntent
import org.junit.Assert.*
import org.junit.Test

class CarNavigationIntentTest {
    private fun parse(uri: String) = CarNavigationIntent.parse(CarNavigationIntent.ACTION, uri)
    @Test fun assistantQueriesDecodeSpacesAndUnicode() {
        assertEquals("KL Sentral", parse("geo:0,0?q=KL+Sentral")!!.query)
        assertEquals("Kuala Lumpur", parse("geo:0,0?q=Kuala%20Lumpur")!!.query)
        assertEquals("咖啡", parse("geo:0,0?q=%E5%92%96%E5%95%A1")!!.query)
    }
    @Test fun queryWinsOverSearchBiasCoordinates() {
        assertEquals("coffee", parse("geo:3.1,101.7?q=coffee&mode=d")!!.query)
    }
    @Test fun coordinateOnlyDestination() {
        val target = parse("geo:3.139,101.6869")!!
        assertNull(target.query)
        assertEquals(3.139, target.lat!!, 0.000001)
        assertEquals(101.6869, target.lng!!, 0.000001)
    }
    @Test fun malformedOrUnrelatedInputIsRejected() {
        listOf("geo:NaN,101", "geo:91,101", "geo:3,181", "geo:3", "geo:0,0?q=%GG",
            "geo:0,0?q=a&q=b", "geo:0,0?q=%00", "https://example.com?q=coffee").forEach {
            assertNull(it, parse(it))
        }
        assertNull(CarNavigationIntent.parse("android.intent.action.VIEW", "geo:3,101"))
        assertNull(CarNavigationIntent.parse(CarNavigationIntent.ACTION, null))
    }
}
