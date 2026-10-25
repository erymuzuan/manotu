package my.gimano.app.car

import androidx.car.app.navigation.model.Maneuver
import my.gimano.app.core.car.CarManeuvers
import my.gimano.app.core.car.CarRules
import my.gimano.app.core.car.Odometer
import my.gimano.app.core.car.OncePerKey
import my.gimano.app.core.car.StillThereGate
import my.gimano.app.core.format.Lang
import my.gimano.app.data.model.Route
import my.gimano.app.data.model.TollPlaza
import org.junit.Assert.*
import org.junit.Test
import java.io.File

/** docs/driving.md §5: the car screens' pure rules. */
class CarRulesTest {
    private fun route(tolls: Boolean, est: Double?, complete: Boolean) = Route("r", durationS = 1.0, distanceM = 1.0, polyline = "", vehicle = "car",
        hasTolls = tolls, tollEstimateMyr = est, tollFareComplete = complete, tolls = if (tolls) listOf(TollPlaza("p", "Plaza Tol Sungai Besi")) else emptyList())

    @Test fun routeChoiceTollLabels() {
        assertEquals("Tanpa tol", CarRules.tollLabel(route(false, null, false), Lang.MS))
        assertEquals("Tol RM 2.10", CarRules.tollLabel(route(true, 2.1, true), Lang.MS))
        assertEquals("Toll from RM 1.60", CarRules.tollLabel(route(true, 1.6, false), Lang.EN))
        assertEquals("Tol", CarRules.tollLabel(route(true, null, false), Lang.MS))
    }

    @Test fun shortViaKeepsRouteRowsToOneLine() {
        assertEquals("Via E11, E6", CarRules.shortVia("Via E11 Lebuhraya Damansara–Puchong, E6 Lebuhraya Utara–Selatan Hubungan Tengah", Lang.EN))
        assertEquals("Melalui Jalan Sultan Ismail", CarRules.shortVia("Via Jalan Sultan Ismail, Jalan Ampang", Lang.MS))
        assertEquals("Via Lingkaran Syed Putra Very L…", CarRules.shortVia("Lingkaran Syed Putra Very Long Road Name", Lang.EN))
        assertNull(CarRules.shortVia("", Lang.EN))
    }

    @Test fun stillThereAtMostOncePer2kmAndOncePerReport() {
        val g = StillThereGate()
        assertFalse("too far ahead", g.shouldAsk("a", 900.0, 0.0))
        assertTrue(g.shouldAsk("a", 700.0, 100.0))
        assertFalse("same report", g.shouldAsk("a", 300.0, 2_500.0))
        assertFalse("another report within 2 km", g.shouldAsk("b", 500.0, 1_900.0))
        assertTrue(g.shouldAsk("b", 500.0, 2_100.0))
    }

    @Test fun odometerKeepsCountingAcrossReroutes() {
        val o = Odometer()
        o.update(0.0, "r1"); o.update(500.0, "r1"); o.update(1_200.0, "r1")
        o.update(0.0, "r2")                // reroute: along restarts at 0
        o.update(800.0, "r2")
        assertEquals(2_000.0, o.metres, 1e-9)
        o.update(790.0, "r2")              // jitter backwards adds nothing
        assertEquals(2_000.0, o.metres, 1e-9)
    }

    @Test fun alertsOncePerKey() {
        val k = OncePerKey()
        assertTrue(k.first("plaza1")); assertFalse(k.first("plaza1")); assertTrue(k.first("plaza2"))
        k.reset(); assertTrue(k.first("plaza1"))
    }

    @Test fun maneuverTypesNeverNeedARoundaboutExitNumber() {
        val ours = listOf("depart", "arrive", "straight", "slight_left", "left", "sharp_left", "slight_right", "right", "sharp_right",
            "uturn_left", "uturn_right", "roundabout_enter", "roundabout_exit", "merge", "ramp_left", "ramp_right", "exit_left", "exit_right",
            "keep_left", "keep_right", "ferry")
        val needExit = setOf(Maneuver.TYPE_ROUNDABOUT_ENTER_AND_EXIT_CW, Maneuver.TYPE_ROUNDABOUT_ENTER_AND_EXIT_CCW,
            Maneuver.TYPE_ROUNDABOUT_ENTER_AND_EXIT_CW_WITH_ANGLE, Maneuver.TYPE_ROUNDABOUT_ENTER_AND_EXIT_CCW_WITH_ANGLE)
        ours.forEach { assertFalse(it, CarManeuvers.type(it) in needExit) }
        assertEquals(Maneuver.TYPE_TURN_NORMAL_LEFT, CarManeuvers.type("left"))
        assertEquals(Maneuver.TYPE_DESTINATION, CarManeuvers.type("arrive"))
        assertEquals("Malaysia drives on the left: clockwise", Maneuver.TYPE_ROUNDABOUT_ENTER_CW, CarManeuvers.type("roundabout_enter"))
    }

    /** The car app is declared as a navigation app with the permissions it uses; nothing else. */
    @Test fun manifestDeclaresTheNavigationCarApp() {
        val m = File("src/main/AndroidManifest.xml").readText()
        assertTrue(m.contains("androidx.car.app.category.NAVIGATION"))
        assertTrue(m.contains("androidx.car.app.NAVIGATION_TEMPLATES"))
        assertTrue(m.contains("androidx.car.app.ACCESS_SURFACE"))
        assertTrue(m.contains("com.google.android.gms.car.application"))
        assertTrue(File("src/main/res/xml/automotive_app_desc.xml").readText().contains("<uses name=\"template\""))
    }

    /** Privacy (AGENTS.md): the car code adds no new endpoint, upload or logging of the user's data. */
    @Test fun carCodeSendsNothingNew() {
        val src = File("src/main/java/my/gimano/app/car").listFiles()!!.joinToString("\n") { it.readText() }
        val repoCalls = Regex("""repo\.(\w+)\(""").findAll(src).map { it.groupValues[1] }.toSet()
        assertEquals("only what the phone already does", setOf("search", "routes", "vote", "createReport"), repoCalls)
        assertFalse(src.contains("Log.") || src.contains("GLog."))
        assertFalse(src.contains("OkHttp") || src.contains("Retrofit"))
    }
}
