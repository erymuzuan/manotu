package my.gimano.app.safety

import my.gimano.app.core.geo.GeoMath
import my.gimano.app.core.geo.GeoPoint
import my.gimano.app.core.safety.ReminderAction
import my.gimano.app.core.safety.RestrictedAreas
import my.gimano.app.core.safety.RestrictedZone
import my.gimano.app.core.safety.SafetyAgreement
import my.gimano.app.core.safety.SafetyReminder
import my.gimano.app.core.safety.SensitiveTerms
import my.gimano.app.data.repo.RestrictedAreaException
import my.gimano.app.data.safety.RestrictedAreaStore
import my.gimano.app.data.safety.RestrictedAreasDto
import my.gimano.app.data.settings.AppSettings
import my.gimano.app.data.settings.toBackupMap
import kotlinx.coroutines.test.runTest
import org.junit.Assert.*
import org.junit.Test
import java.io.File
import java.nio.file.Files

/** docs/safety.md: the agreement gate, the drive reminder decision, the restricted-area geofence and the terms matcher. */
class SafetyTest {
    // ---------------------------------------------------------------- 1. agreement

    @Test fun agreementIsAskedOncePerVersion() {
        assertTrue(SafetyAgreement.needsAgreement(0))
        assertFalse(SafetyAgreement.needsAgreement(SafetyAgreement.VERSION))
        assertFalse(SafetyAgreement.needsAgreement(SafetyAgreement.VERSION + 1))   // a newer app's agreement restored here
    }

    @Test fun restoreKeepsTheLaterAgreement() {
        assertEquals(1 to "2026-10-25T01:00:00Z", SafetyAgreement.newer(0 to null, 1 to "2026-10-25T01:00:00Z"))
        assertEquals(1 to "local", SafetyAgreement.newer(1 to "local", 1 to "backup"))
        assertEquals(2 to "local", SafetyAgreement.newer(2 to "local", 1 to "backup"))
    }

    @Test fun safetySettingsTravelInTheBackupOnly() {
        val m = AppSettings(safetyAgreedVersion = 1, safetyAgreedAt = "2026-10-25T01:00:00Z", safetyReminderEnabled = false,
            safetyReminderDisabledAt = "2026-10-25T02:00:00Z").toBackupMap()
        assertEquals("1", m["safety.agreedVersion"])
        assertEquals("2026-10-25T01:00:00Z", m["safety.agreedAt"])
        assertEquals("false", m["safety.reminderEnabled"])
        assertEquals("2026-10-25T02:00:00Z", m["safety.reminderDisabledAt"])
        // Never agreed: no date row at all.
        assertFalse(AppSettings().toBackupMap().containsKey("safety.agreedAt"))
        assertEquals("true", AppSettings().toBackupMap()["safety.reminderEnabled"])
    }

    // ---------------------------------------------------------------- 2. reminder

    @Test fun reminderCardOnlyWhenStoppedOrUnknown() {
        assertEquals(ReminderAction.CARD, SafetyReminder.onStart(true, null))
        assertEquals(ReminderAction.CARD, SafetyReminder.onStart(true, 0.0))
        assertEquals(ReminderAction.CARD, SafetyReminder.onStart(true, 9.9))
        assertEquals(ReminderAction.BANNER, SafetyReminder.onStart(true, 10.0))
        assertEquals(ReminderAction.BANNER, SafetyReminder.onStart(true, 60.0))
        assertEquals(ReminderAction.NONE, SafetyReminder.onStart(false, null))
        assertEquals(ReminderAction.NONE, SafetyReminder.onStart(false, 80.0))
    }

    @Test fun longDriveLineAfterTwoHours() {
        assertFalse(SafetyReminder.isLongDrive(null))
        assertFalse(SafetyReminder.isLongDrive(7200.0))
        assertTrue(SafetyReminder.isLongDrive(7201.0))
    }

    // ---------------------------------------------------------------- 4. geofence

    /** ~1 km square near Sungai Besi (fixture-like). */
    private val square = listOf(GeoPoint(3.0700, 101.7020), GeoPoint(3.0700, 101.7110), GeoPoint(3.0790, 101.7110), GeoPoint(3.0790, 101.7020), GeoPoint(3.0700, 101.7020))
    private val areas = RestrictedAreas("v", blockM = 100.0, reviewM = 300.0, terms = emptyList(), rings = listOf(square))

    @Test fun insideIsBlocked() {
        assertEquals(RestrictedZone.BLOCKED, areas.zone(GeoPoint(3.0745, 101.7065)))
        assertTrue(areas.contains(GeoPoint(3.0745, 101.7065)))
    }

    @Test fun distanceToTheEdgeDecides() {
        val edge = GeoPoint(3.0745, 101.7110)
        fun east(m: Double) = GeoMath.offset(edge, 90.0, m)
        assertEquals(RestrictedZone.BLOCKED, areas.zone(east(60.0)))
        assertFalse(areas.contains(east(60.0)))
        assertEquals(RestrictedZone.NEAR, areas.zone(east(150.0)))
        assertEquals(RestrictedZone.NEAR, areas.zone(east(290.0)))
        assertEquals(RestrictedZone.CLEAR, areas.zone(east(320.0)))
        assertEquals(RestrictedZone.CLEAR, areas.zone(GeoPoint(3.1390, 101.6869)))
    }

    @Test fun concaveRingsAndOpenRings() {
        // An L shape (open: last point not repeated): the notch is outside.
        val l = listOf(GeoPoint(0.0, 0.0), GeoPoint(0.0, 0.02), GeoPoint(0.01, 0.02), GeoPoint(0.01, 0.01), GeoPoint(0.02, 0.01), GeoPoint(0.02, 0.0))
        val a = RestrictedAreas("v", 100.0, 300.0, emptyList(), listOf(l))
        assertEquals(RestrictedZone.BLOCKED, a.zone(GeoPoint(0.005, 0.005)))
        assertEquals(RestrictedZone.CLEAR, a.zone(GeoPoint(0.018, 0.018)))
        // Degenerate rings are ignored.
        assertTrue(RestrictedAreas("v", 100.0, 300.0, emptyList(), listOf(listOf(GeoPoint(1.0, 1.0)))).isEmpty)
    }

    @Test fun serverPayloadIsLngLat() {
        val dto = RestrictedAreasDto.parse("""{"version":"x","blockM":50,"reviewM":200,"terms":["kem"],"areas":[[[101.702,3.07],[101.711,3.07],[101.711,3.079],[101.702,3.079],[101.702,3.07]]],"future":1}""")
        val a = dto.toAreas()
        assertEquals(50.0, a.blockM, 0.0)
        assertEquals(RestrictedZone.BLOCKED, a.zone(GeoPoint(3.0745, 101.7065)))
    }

    // ---------------------------------------------------------------- C. sensitive terms

    private val terms = SensitiveTerms(listOf("kem", "pintu belakang", "CCTV", "pengawal"))

    @Test fun wholeWordsCaseAndAccentInsensitive() {
        assertEquals(listOf("kem"), terms.matches("Gerai depan Kem, sedap"))
        assertEquals(listOf("pintu belakang"), terms.matches("Masuk ikut PINTU   belakang"))
        assertEquals(listOf("CCTV"), terms.matches("ada cctv."))
        assertTrue(terms.hasMatch("Kém lama"))           // accent ignored
        assertFalse(terms.hasMatch("Kemaman"))           // not a whole word
        assertFalse(terms.hasMatch("pintu depan"))
        assertFalse(terms.hasMatch(null))
        assertFalse(SensitiveTerms(emptyList()).hasMatch("kem"))
    }

    @Test fun removeSentencesKeepsTheRest() {
        assertEquals("Nasi lemak sedap. Buka pagi.", terms.removeSentences("Nasi lemak sedap. Pengawal tidur pukul 3! Buka pagi."))
        assertEquals("", terms.removeSentences("Kem Sungai Besi"))
        assertEquals("Line one\nLine three", terms.removeSentences("Line one\nada CCTV di sini\nLine three"))
    }

    // ---------------------------------------------------------------- 422 restricted_area

    @Test fun restrictedRefusalCarriesTheServerText() {
        val e = RestrictedAreaException.parse("""{"type":"x","title":"Restricted","status":422,"code":"restricted_area","detail":"Tempat ini dalam kawasan larangan."}""")
        assertEquals("Tempat ini dalam kawasan larangan.", e?.detail)
        assertNull(RestrictedAreaException.parse("""{"status":422,"title":"Validation","errors":{"name":["required"]}}"""))
        assertNull(RestrictedAreaException.parse("not json"))
    }

    // ---------------------------------------------------------------- store: 404 / offline / cache

    @Test fun storeToleratesMissingEndpointAndUsesItsFileCache() = runTest {
        val dir = Files.createTempDirectory("manotu-restricted").toFile()
        // Nothing listens here: like offline / not deployed. No data, no client-side check, no crash.
        val s = RestrictedAreaStore(dir, baseUrl = { "http://127.0.0.1:9/api/v1/" })
        s.loadCached(); s.refresh(force = true)
        assertNull(s.areas.value)
        assertEquals(RestrictedZone.CLEAR, s.zone(GeoPoint(3.0745, 101.7065)))
        // A copy saved earlier is used offline.
        File(dir, "restricted-areas.json").writeText("""{"version":"c","areas":[[[101.702,3.07],[101.711,3.07],[101.711,3.079],[101.702,3.079]]],"terms":["kem"]}""")
        val s2 = RestrictedAreaStore(dir, baseUrl = { "http://127.0.0.1:9/api/v1/" })
        s2.loadCached(); s2.refresh(force = true)
        assertEquals(RestrictedZone.BLOCKED, s2.zone(GeoPoint(3.0745, 101.7065)))
        assertTrue(s2.terms.value.hasMatch("kem"))
    }

    // ---------------------------------------------------------------- copy

    @Test fun everySafetyStringIsInBothLanguages() {
        fun keys(path: String): Set<String> {
            val f = listOf(File(path), File("app/$path")).first { it.exists() }
            return Regex("""<string name="((?:safety|restricted|flag_sensitive|status_held)[^"]*)"""").findAll(f.readText()).map { it.groupValues[1] }.toSet()
        }
        val en = keys("src/main/res/values/strings.xml")
        val ms = keys("src/main/res/values-ms/strings.xml")
        assertTrue(en.size > 60)
        assertEquals(en, ms)
    }
}
