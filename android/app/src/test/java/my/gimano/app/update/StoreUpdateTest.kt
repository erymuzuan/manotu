package my.gimano.app.update

import my.gimano.app.core.update.*
import org.junit.Assert.*
import org.junit.Test

class StoreUpdateTest {
    private val body = """{"platforms":{"android-play":{"latest":"0.4.2","forceBelow":"0.4.0","storeUrl":"https://play.google.com/store/apps/details?id=my.manotu.app","releasedAt":"2026-10-27T01:00:00Z"},"ios":{"latest":"9.9.9"}}}"""

    @Test fun semverIsNumericPerSegment() {
        assertTrue(SemVer.compare("0.4.10", "0.4.9") > 0)
        assertTrue(SemVer.compare("0.4.9", "0.4.10") < 0)
        assertEquals(0, SemVer.compare("0.4", "0.4.0"))
        assertTrue(SemVer.compare("1.0.0", "0.99.99") > 0)
        assertEquals(0, SemVer.compare("0.4.2-debug", "0.4.2"))
        assertEquals("garbage never nags", 0, SemVer.compare("abc", "1.0.0"))
        assertNull(SemVer.parse("")); assertNull(SemVer.parse("1.x"))
    }

    @Test fun parsesThePlatformEntry() {
        val v = StoreVersion.parse(body)!!
        assertEquals("0.4.2", v.latest); assertEquals("0.4.0", v.forceBelow)
        assertEquals("https://play.google.com/store/apps/details?id=my.manotu.app", v.storeUrl)
        assertEquals("2026-10-27T01:00:00Z", v.releasedAt)
    }

    @Test fun parsingIsLenientAndRejectsGarbage() {
        val v = StoreVersion.parse("""{"platforms":{"android-play":{"latest":"0.4.2","forceBelow":null,"extra":[1],"storeUrl":"http://insecure"}}}""")!!
        assertNull(v.forceBelow); assertNull(v.storeUrl); assertNull(v.releasedAt)
        assertEquals(StoreVersion.FALLBACK_STORE_URL, StoreUpdatePolicy.storeUrl(v))
        assertNull(StoreVersion.parse("not json"))
        assertNull(StoreVersion.parse("""{"platforms":{}}"""))
        assertNull(StoreVersion.parse("""{"platforms":{"android-play":{"latest":"soon"}}}"""))
        assertNull(StoreVersion.parse("""{"platforms":{"android-play":{"forceBelow":"0.1.0"}}}"""))
    }

    @Test fun decisionSoftForcedNone() {
        val v = StoreVersion("0.4.2", "0.4.0")
        assertEquals(StoreUpdateDecision.None, StoreUpdatePolicy.decide("0.4.2", v))
        assertEquals(StoreUpdateDecision.None, StoreUpdatePolicy.decide("0.5.0", v))
        assertEquals(StoreUpdateDecision.Soft("0.4.1", "0.4.2"), StoreUpdatePolicy.decide("0.4.1", v))
        assertEquals(StoreUpdateDecision.Soft("0.4.0", "0.4.2"), StoreUpdatePolicy.decide("0.4.0", v))
        assertEquals(StoreUpdateDecision.Forced("0.3.9", "0.4.2"), StoreUpdatePolicy.decide("0.3.9", v))
        assertEquals(StoreUpdateDecision.Soft("0.4.9", "0.4.10"), StoreUpdatePolicy.decide("0.4.9", StoreVersion("0.4.10")))
        assertEquals(StoreUpdateDecision.None, StoreUpdatePolicy.decide("0.1.0", null))
    }

    @Test fun throttleIsThirtyMinutes() {
        val t = 1_000_000_000L
        assertTrue(StoreUpdatePolicy.shouldCheck(0, t))
        assertFalse(StoreUpdatePolicy.shouldCheck(t, t + 29 * 60_000L))
        assertTrue(StoreUpdatePolicy.shouldCheck(t, t + 30 * 60_000L))
        assertTrue("clock moved back", StoreUpdatePolicy.shouldCheck(t, t - 1))
    }

    @Test fun visibilityDefersDuringNavigationAndHonoursLater() {
        val soft = StoreUpdateDecision.Soft("1", "2"); val forced = StoreUpdateDecision.Forced("1", "2")
        assertTrue(StoreUpdatePolicy.visible(soft, navigating = false, laterThisLaunch = false))
        assertFalse(StoreUpdatePolicy.visible(soft, navigating = false, laterThisLaunch = true))
        assertFalse(StoreUpdatePolicy.visible(soft, navigating = true, laterThisLaunch = false))
        assertTrue(StoreUpdatePolicy.visible(forced, navigating = false, laterThisLaunch = true))
        assertFalse(StoreUpdatePolicy.visible(forced, navigating = true, laterThisLaunch = false))
        assertFalse(StoreUpdatePolicy.visible(StoreUpdateDecision.None, false, false))
    }

    @Test fun enabledOnlyForPlayOrDebugToggle() {
        assertTrue(StoreUpdatePolicy.enabled("play", debug = false, debugToggle = false))
        assertFalse(StoreUpdatePolicy.enabled("web", debug = false, debugToggle = true))
        assertFalse(StoreUpdatePolicy.enabled("web", debug = true, debugToggle = false))
        assertTrue(StoreUpdatePolicy.enabled("web", debug = true, debugToggle = true))
    }
}
