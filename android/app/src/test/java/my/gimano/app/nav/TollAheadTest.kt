package my.gimano.app.nav

import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.test.advanceTimeBy
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import my.gimano.app.core.format.Lang
import my.gimano.app.core.geo.GeoMath
import my.gimano.app.core.geo.GeoPoint
import my.gimano.app.core.geo.Polyline
import my.gimano.app.core.nav.MoneyWords
import my.gimano.app.core.nav.RouteGeometry
import my.gimano.app.core.nav.TollAlong
import my.gimano.app.core.nav.TollBanner
import my.gimano.app.core.nav.TollKind
import my.gimano.app.core.nav.TollOnRoute
import my.gimano.app.core.nav.TollText
import my.gimano.app.core.nav.TollTracker
import my.gimano.app.data.location.DriveSimulator
import my.gimano.app.data.model.Leg
import my.gimano.app.data.model.Maneuver
import my.gimano.app.data.model.Route
import my.gimano.app.data.model.TollPlaza
import my.gimano.app.data.repo.DemoRepository
import my.gimano.app.data.settings.SoundMode
import org.junit.Assert.*
import org.junit.Test

/** docs/driving.md §1: toll ahead banner, voice once per plaza, running total. */
@OptIn(ExperimentalCoroutinesApi::class)
class TollAheadTest {
    /** A straight 11 km road heading east from (3.0, 101.0). */
    private val line = (0..110).map { GeoPoint(3.0, 101.0 + it * 0.001) }
    private val geometry = RouteGeometry(line)
    private fun at(alongM: Double) = geometry.pointAt(alongM).first

    private val sungaiBesi = TollPlaza("n1", "Plaza Tol Sungai Besi", "E2", at(5_000.0).lat, at(5_000.0).lng, fareMyr = 2.1, system = "open")
    private val entry = TollPlaza("n2", "Plaza Tol Bangi", "E2", at(2_000.0).lat, at(2_000.0).lng, fareMyr = 0.0, system = "closed_entry")
    private val unknown = TollPlaza("n3", "Plaza Tol Kajang", null, at(8_000.0).lat, at(8_000.0).lng)

    private fun route(tolls: List<TollPlaza>, estimate: Double? = 2.1, complete: Boolean = true) = Route(
        id = "r1", durationS = 600.0, distanceM = geometry.lengthM, polyline = Polyline.encode(line), hasTolls = tolls.isNotEmpty(),
        tollEstimateMyr = estimate, tollFareComplete = complete, tolls = tolls, vehicle = "car",
        legs = listOf(Leg(durationS = 600.0, distanceM = geometry.lengthM, maneuvers = listOf(
            Maneuver("depart", "Head east", beginShapeIndex = 0, endShapeIndex = 1),
            Maneuver("arrive", "Arrive", beginShapeIndex = line.lastIndex, endShapeIndex = line.lastIndex),
        ))),
    )

    @Test fun serverDistancesAreUsedAsGiven() {
        val placed = TollAlong.place(listOf(sungaiBesi.copy(distanceAlongRouteM = 4_321.0)), geometry)
        assertEquals(4_321.0, placed.single().alongM, 0.01)
    }

    @Test fun withoutServerDistancesPlazasAreProjectedOnTheRouteInOrder() {
        // 60 m north of the road: still placed, at its projection.
        val off = sungaiBesi.copy(lat = GeoMath.offset(at(5_000.0), 0.0, 60.0).lat)
        val placed = TollAlong.place(listOf(entry, off, unknown), geometry)
        assertEquals(listOf("n2", "n1", "n3"), placed.map { it.plaza.plazaId })
        assertEquals(2_000.0, placed[0].alongM, 5.0)
        assertEquals(5_000.0, placed[1].alongM, 5.0)
        // A plaza far from the route is not "ahead".
        val far = sungaiBesi.copy(lat = 3.05)
        assertTrue(TollAlong.place(listOf(far), geometry).isEmpty())
    }

    @Test fun bannerAt1kmOnTheHighwayAnd500mBelow60() {
        val fast = TollTracker(listOf(TollOnRoute(sungaiBesi, 5_000.0)))
        assertNull(fast.update(3_900.0, 100.0, 0).banner)
        val u = fast.update(4_100.0, 100.0, 1_000)
        assertEquals(900.0, u.banner!!.distanceM, 0.01)
        assertSame("spoken when the banner appears", sungaiBesi, u.speak!!.plaza)

        val slow = TollTracker(listOf(TollOnRoute(sungaiBesi, 5_000.0)))
        assertNull(slow.update(4_100.0, 45.0, 0).banner)
        assertNotNull(slow.update(4_550.0, 45.0, 1_000).banner)
    }

    @Test fun spokenOncePerPlazaAndHidden10sAfterPassing() {
        val t = TollTracker(listOf(TollOnRoute(sungaiBesi, 5_000.0)))
        var speaks = 0
        var now = 0L
        var along = 3_000.0
        while (along < 5_000.0) {
            if (t.update(along, 100.0, now).speak != null) speaks++
            along += 28.0; now += 1_000
        }
        assertEquals(1, speaks)
        val passed = t.update(5_010.0, 100.0, now)
        assertTrue(passed.banner!!.passed)
        assertEquals(2.1, passed.paidMyr, 1e-9)
        assertNotNull("still shown 9 s after", t.update(5_200.0, 100.0, now + 9_000).banner)
        assertNull("hidden 10 s after passing", t.update(5_300.0, 100.0, now + 10_000).banner)
        assertNull(t.update(5_300.0, 100.0, now + 11_000).speak)
    }

    @Test fun plazasBehindTheFirstFixAreNeitherPaidNorAnnounced() {
        val t = TollTracker(TollAlong.place(listOf(entry, sungaiBesi, unknown), geometry))
        val u = t.update(5_500.0, 100.0, 0)
        assertEquals(0.0, u.paidMyr, 1e-9)
        assertNull(u.speak)
        assertNull(u.banner)
        assertEquals("the next one still counts", "n3", t.update(7_100.0, 100.0, 1_000).speak?.plaza?.plazaId)
    }

    @Test fun runningTotalCountsOnlyPassedPlazas() {
        val t = TollTracker(TollAlong.place(listOf(entry, sungaiBesi, unknown), geometry))
        assertEquals(0.0, t.update(1_000.0, 90.0, 0).paidMyr, 1e-9)
        assertEquals(0.0, t.update(2_100.0, 90.0, 1).paidMyr, 1e-9)    // closed entry: pay at the exit
        assertEquals(2.1, t.update(5_100.0, 90.0, 2).paidMyr, 1e-9)
        assertEquals(2.1, t.update(9_000.0, 90.0, 3).paidMyr, 1e-9)    // fare unknown adds nothing
        assertEquals(3, t.update(9_000.0, 90.0, 4).passed)
    }

    @Test fun bannerWordingMatchesTheSpec() {
        val fare = TollBanner(TollOnRoute(sungaiBesi, 0.0), TollKind.FARE, 900.0, false)
        assertEquals("Tol Sungai Besi", TollText.title(sungaiBesi, Lang.MS))
        assertEquals("Sungai Besi toll", TollText.title(sungaiBesi, Lang.EN))
        assertEquals("900 m di hadapan · RM 2.10", TollText.detail(fare, Lang.MS))
        assertEquals("900 m ahead · RM 2.10", TollText.detail(fare, Lang.EN))
        assertEquals("900 m · RM 2.10", TollText.carDetail(fare, Lang.MS))
        val closed = TollBanner(TollOnRoute(entry, 0.0), TollKind.CLOSED_ENTRY, 900.0, false)
        assertTrue(TollText.detail(closed, Lang.MS).startsWith("Tol masuk"))
        assertTrue(TollText.detail(closed, Lang.MS).endsWith("bayar di tol keluar"))
        assertTrue(TollText.detail(closed, Lang.EN).endsWith("pay at the exit"))
        val unk = TollBanner(TollOnRoute(unknown, 0.0), TollKind.UNKNOWN, 900.0, false)
        assertTrue(TollText.detail(unk, Lang.MS).startsWith("Tol di hadapan"))
        assertTrue(TollText.detail(unk, Lang.MS).endsWith("harga tidak diketahui"))
        assertTrue(TollText.detail(unk, Lang.EN).endsWith("fare unknown"))
    }

    @Test fun voiceWordingMatchesTheSpec() {
        assertEquals("Tol Sungai Besi di hadapan, dua ringgit sepuluh sen.", TollText.spoken(TollOnRoute(sungaiBesi, 0.0), Lang.MS))
        assertEquals("Sungai Besi toll ahead, two ringgit ten.", TollText.spoken(TollOnRoute(sungaiBesi, 0.0), Lang.EN))
        val sb = entry.copy(name = "Plaza Tol Sungai Besi")
        assertEquals("Tol masuk Sungai Besi di hadapan.", TollText.spoken(TollOnRoute(sb, 0.0), Lang.MS))
        assertEquals("Sungai Besi toll entry ahead.", TollText.spoken(TollOnRoute(sb, 0.0), Lang.EN))
    }

    @Test fun moneyInWords() {
        assertEquals("lima ringgit dua puluh lima sen", MoneyWords.say(5.25, Lang.MS))
        assertEquals("five ringgit twenty-five", MoneyWords.say(5.25, Lang.EN))
        assertEquals("sebelas ringgit", MoneyWords.say(11.0, Lang.MS))
        assertEquals("lima puluh sen", MoneyWords.say(0.5, Lang.MS))
        assertEquals("seratus dua puluh tiga ringgit", MoneyWords.say(123.0, Lang.MS))
        assertEquals("one hundred twelve ringgit", MoneyWords.say(112.0, Lang.EN))
    }

    @Test fun tripLineSoFarAndEstimate() {
        assertEquals("Tol setakat ini RM 2.10 · anggaran RM 9.35", TollText.tripLine(2.1, route(listOf(sungaiBesi), 9.35, true), lang = Lang.MS))
        assertEquals("Tolls so far RM 0.00 · estimate from RM 4.10", TollText.tripLine(0.0, route(listOf(sungaiBesi), 4.1, false), lang = Lang.EN))
        assertNull(TollText.tripLine(0.0, route(emptyList(), null), lang = Lang.EN))
    }

    private class Recorder : Speaker {
        val spoken = ArrayList<String>()
        override fun speak(text: String, lang: Lang, flush: Boolean) { spoken += text }
        override fun stop() {}
    }


    @Test fun controllerSpeaksTheTollInFullAndAlertsOnlyButNeverMuted() = runTest {
        for (mode in SoundMode.entries) {
            val r = route(listOf(sungaiBesi))
            val speaker = Recorder()
            val fixes = FixSource { DriveSimulator.drive(RouteGeometry(line), 90.0).map { it.copy(simulated = false) } }
            val c = NavigationController(backgroundScope, DemoRepository(cannedDocs = { emptyList() }), fixes, speaker,
                object : NavServiceControl { override fun start() {}; override fun stop() {} }, soundMode = { mode }, langProvider = { Lang.EN })
            c.start(r, NavDestination("End", "", line.last(), null), null, simulate = false)
            var sawBanner = false
            repeat(400) { advanceTimeBy(1_000); runCurrent(); if (c.state.value.toll != null) sawBanner = true }
            val tollPrompts = speaker.spoken.count { it.startsWith("Sungai Besi toll ahead") }
            assertEquals("$mode", if (mode == SoundMode.OFF) 0 else 1, tollPrompts)
            assertTrue("$mode banner shown", sawBanner)
            assertEquals(2.1, c.state.value.tollsPaidMyr, 1e-9)
            c.stop()
        }
    }
}
