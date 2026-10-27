package my.gimano.app.links

import my.gimano.app.core.links.NavLink
import my.gimano.app.core.links.NavLinkParser
import my.gimano.app.core.links.NavLinkPending
import org.junit.Assert.*
import org.junit.Test

class NavLinkTest {
    private val prefixes = listOf("manotu://navigate?", "https://manotu.app/nav/?", "https://manotu.app/nav?")

    @Test fun parsesValidLinks() {
        for (p in prefixes) {
            assertEquals(NavLink(3.1301, 101.6712, "Aisyah, Block B"), NavLinkParser.parse(p + "lat=3.1301&lng=101.6712&label=Aisyah%2C%20Block%20B"))
            assertEquals(NavLink(3.1301, 101.6712, null), NavLinkParser.parse(p + "lat=3.1301&lng=101.6712"))
            assertEquals(NavLink(3.0, 101.0, null), NavLinkParser.parse(p + "lng=101&lat=3"))
            assertEquals(NavLink(3.0, 101.0, "Kedai Ali & Co. (#12/3) @ Jln O'Neil: 1-2"),
                NavLinkParser.parse(p + "lat=3&lng=101&label=" + java.net.URLEncoder.encode("Kedai Ali & Co. (#12/3) @ Jln O'Neil: 1-2", "UTF-8").replace("+", "%20")))
            assertEquals("Café Zaitun 中文 9", NavLinkParser.parse(p + "lat=3&lng=101&label=Cafe%CC%81%20Zaitun%20%E4%B8%AD%E6%96%87%209")?.label)
        }
        assertTrue(NavLinkParser.parse("MANOTU://Navigate?lat=1&lng=2") != null)
    }

    @Test fun coordinateBoundaries() {
        for (p in prefixes) {
            assertNotNull(NavLinkParser.parse(p + "lat=90&lng=180"))
            assertNotNull(NavLinkParser.parse(p + "lat=-90&lng=-180"))
            assertNotNull(NavLinkParser.parse(p + "lat=90.000000&lng=-180.000000"))
            for (bad in listOf("lat=90.000001&lng=0", "lat=-90.1&lng=0", "lat=0&lng=180.000001", "lat=0&lng=-181", "lat=91&lng=0", "lat=0&lng=181"))
                assertNull(bad, NavLinkParser.parse(p + bad))
        }
    }

    @Test fun rejectsBadNumbers() {
        val p = "manotu://navigate?"
        for (bad in listOf("lat=3.1234567&lng=101", "lat=3&lng=101.1234567", "lat=1e1&lng=2", "lat=1E1&lng=2", "lat=3&lng=1e2", "lat=03.1&lng=1", "lat=3&lng=00", "lat=3&lng=-01", "lat=3&lng=2&label=", "lat=3&lng=2&label=%20%20", "lat=%2B3&lng=101", "lat=+3&lng=101",
            "lat=NaN&lng=1", "lat=Infinity&lng=1", "lat=&lng=1", "lat=3&lng=", "lat=3", "lng=3", "lat=.5&lng=1", "lat=5.&lng=1", "lat=0x10&lng=1", "lat=3,5&lng=1",
            "lat=1000&lng=1", "lat=%20&lng=1", "lat=1%2E5&lng=1", "lat=--1&lng=1", "lat=٣&lng=1", ""))
            assertNull(bad, NavLinkParser.parse(p + bad))
        assertNull(NavLinkParser.parse("manotu://navigate"))
    }

    @Test fun rejectsDuplicatesAndExtraParameters() {
        for (p in prefixes) {
            for (bad in listOf("lat=1&lat=1&lng=2", "lat=1&lng=2&lng=2", "lat=1&lng=2&label=a&label=b", "lat=1&lng=2&from=3,4", "lat=1&lng=2&mode=car",
                "lat=1&lng=2&Lat=3", "Lat=1&lng=2", "lat=1&lng=2&", "&lat=1&lng=2", "lat=1&&lng=2", "lat=1&lng=2&x", "lat=1&lng=2&=y", "lat=1&lng=2&url=https://evil.test"))
                assertNull(bad, NavLinkParser.parse(p + bad))
        }
    }

    @Test fun rejectsBadLabels() {
        val p = "manotu://navigate?lat=1&lng=2&label="
        for (bad in listOf("%3Cb%3E", "a%3Eb", "a%3Cb", "a%0Ab", "a%0Db", "a%09b", "a%00b", "a%1Fb", "a%7Fb", "a%C2%85b", "https%3A%2F%2Fevil.test", "see%20http%3A%2F%2Fx",
            "www.evil.test", "a+b", "a%2Bb", "a%25b", "a%22b", "a%3Bb", "a%3Fb", "a%3Db", "a%5Cb", "a%7Bb", "a%24b", "a%2Ab", "a%21b", "a%E2%80%AEb", "a%F0%9F%98%80b",
            "%ZZ", "a+b+c", "%4", "%", "%C3", "%FF", "a%E2%82", "%2g", "%+1", "a%0A"))
            assertNull(bad, NavLinkParser.parse(p + bad))
        // raw (unencoded) hostile characters make the URI invalid
        assertNull(NavLinkParser.parse(p + "<b>"))
        assertNull(NavLinkParser.parse(p + "a b"))
        assertNull(NavLinkParser.parse(p + "a\nb"))
    }

    @Test fun labelLengthIsCountedAfterDecoding() {
        val p = "manotu://navigate?lat=1&lng=2&label="
        assertEquals("a".repeat(60), NavLinkParser.parse(p + "a".repeat(60))?.label)
        assertNull(NavLinkParser.parse(p + "a".repeat(61)))
        assertEquals(60, NavLinkParser.parse(p + "%20".repeat(0) + "%2C".repeat(60))?.label?.length)
        assertNull(NavLinkParser.parse(p + "%2C".repeat(61)))
        assertEquals("中".repeat(50), NavLinkParser.parse(p + "%E4%B8%AD".repeat(50))?.label)
        assertNull(NavLinkParser.parse("manotu://navigate?lat=1&lng=2&label=" + "a".repeat(600)))
    }

    @Test fun rejectsWrongSchemeHostPathAndExtras() {
        val q = "lat=1&lng=2"
        for (link in listOf("https://evil.test/nav/?$q", "https://manotu.app.evil.test/nav/?$q", "https://www.manotu.app/nav/?$q", "http://manotu.app/nav/?$q",
            "https://manotu.app/nav/x?$q", "https://manotu.app/navigate?$q", "https://manotu.app/p/?$q", "https://manotu.app/NAV/?$q", "https://manotu.app//nav/?$q",
            "https://manotu.app/nav//?$q", "https://manotu.app/?$q", "https://manotu.app/nav/../p/?$q",
            "manotu://place?$q", "manotu://navigate/x?$q", "manotu://navigate//?$q", "manotu://nav?$q", "manotu://evil.test/navigate?$q", "manotu:navigate?$q",
            "gimano://navigate?$q", "geo:1,2", "intent://navigate?$q", "javascript:alert(1)", "navigate?$q", "",
            "https://u@manotu.app/nav/?$q", "https://u:p@manotu.app/nav/?$q", "manotu://u@navigate?$q", "https://manotu.app:443/nav/?$q", "https://manotu.app:8443/nav/?$q",
            "manotu://navigate:80?$q", "https://manotu.app/nav/?$q#x", "manotu://navigate?$q#", "manotu://navigate?$q#key", "https://manotu.app/nav/?$q\n", " https://manotu.app/nav/?$q"))
            assertNull(link, NavLinkParser.parse(link))
    }

    @Test fun recognisesNavTargetsEvenWhenRejected() {
        assertTrue(NavLinkParser.isNavTarget("manotu://navigate?lat=999"))
        assertTrue(NavLinkParser.isNavTarget("https://manotu.app/nav/?x=1"))
        assertFalse(NavLinkParser.isNavTarget("manotu://event#1.abc"))
        assertFalse(NavLinkParser.isNavTarget("https://manotu.app/j/#a.b"))
    }

    @Test fun pendingIsSupersededByNewerLinkAndClearedByCancelOrConfirm() {
        val a = NavLink(1.0, 2.0, "A"); val b = NavLink(3.0, 4.0, null)
        assertEquals(a, NavLinkPending.offer(null, a))
        assertEquals(b, NavLinkPending.offer(a, b))
        assertNull(NavLinkPending.cancel(b))
        assertEquals(b to null, NavLinkPending.confirm(b, driveActive = false))
        assertEquals(null to null, NavLinkPending.confirm(null, driveActive = false))
        // a drive in progress: nothing is routed, the pending link is dropped
        assertEquals(null to null, NavLinkPending.confirm(b, driveActive = true))
    }
}
