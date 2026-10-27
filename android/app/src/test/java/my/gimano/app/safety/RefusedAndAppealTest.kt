package my.gimano.app.safety

import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.runBlocking
import my.gimano.app.backup.JdbcSqlPort
import my.gimano.app.core.safety.AppealError
import my.gimano.app.core.safety.AppealRules
import my.gimano.app.core.safety.AppealState
import my.gimano.app.core.safety.PausePersistence
import my.gimano.app.core.safety.PostingPause
import my.gimano.app.core.safety.RefusedItem
import my.gimano.app.core.safety.RefusedKind
import my.gimano.app.core.safety.RefusedRules
import my.gimano.app.data.backup.BackupDb
import my.gimano.app.data.local.GimanoSchema
import my.gimano.app.data.safety.RefusedContentStore
import org.junit.After
import org.junit.Assert.*
import org.junit.Before
import org.junit.Test
import java.io.File
import java.sql.DriverManager
import java.time.Duration
import java.time.Instant

/** Refused content kept on the phone (30 days), the appeal rules, and the persisted posting pause. */
class RefusedAndAppealTest {
    private val t0 = Instant.parse("2026-10-27T08:00:00Z")
    private var clock = t0
    private lateinit var dir: File
    private lateinit var db: JdbcSqlPort
    private lateinit var store: RefusedContentStore

    @Before fun setUp() {
        dir = File.createTempFile("refused", "").also { it.delete(); it.mkdirs() }
        db = JdbcSqlPort(DriverManager.getConnection("jdbc:sqlite::memory:"))
        GimanoSchema.create { db.exec(it) }
        clock = t0
        store = RefusedContentStore({ db }, File(dir, "refused"), now = { clock }, io = Dispatchers.Unconfined)
    }

    @After fun tearDown() { dir.deleteRecursively(); PostingPause.persist = null; PostingPause.clear() }

    private fun item(id: String, text: String = "call 012 3456789", at: Instant = clock, kind: RefusedKind = RefusedKind.REVIEW, place: String? = "p1") =
        RefusedItem(id, kind, place, "Kedai Ali", text, listOf("external_contact"), emptyList(), at)

    // ---------------------------------------------------------------- the store

    @Test fun savedRefusalComesBackWithEverythingAndStartsWithoutAnAppeal() = runBlocking {
        store.save(item("a", "WhatsApp me 0123"))
        val got = store.get("a")!!
        assertEquals("WhatsApp me 0123", got.text)
        assertEquals(listOf("external_contact"), got.reasons)
        assertEquals("Kedai Ali", got.placeName)
        assertEquals(AppealState.NONE, got.appealState)
        assertEquals(t0, got.createdAt)
        assertEquals(1, RefusedRules.badge(store.allNow(), clock))
    }

    @Test fun itemsExpireAfter30DaysAndTheirPhotosGoWithThem() = runBlocking {
        val name = store.savePhoto("old", 0, byteArrayOf(1, 2, 3))!!
        store.save(item("old", at = t0).copy(kind = RefusedKind.PHOTO, photos = listOf(name)))
        store.save(item("new", text = "other", at = t0.plus(Duration.ofDays(20))))
        assertTrue(store.photoFile("old", name)!!.exists())

        clock = t0.plus(Duration.ofDays(29)).plusSeconds(3600)
        assertEquals(setOf("old", "new"), store.allNow().map { it.id }.toSet())

        clock = t0.plus(Duration.ofDays(30))
        assertEquals("exactly 30 days is gone", listOf("new"), store.allNow().map { it.id })
        assertNull("photo file deleted with the row", store.photoFile("old", name))
        assertFalse(File(dir, "refused/old").exists())

        clock = t0.plus(Duration.ofDays(51))
        assertEquals(0, store.purgeExpired().let { store.allNow().size })
    }

    @Test fun daysLeftCountsDown() {
        val i = item("x")
        assertEquals(30, i.daysLeft(t0))
        assertEquals(10, i.daysLeft(t0.plus(Duration.ofDays(20))))
        assertEquals(0, i.daysLeft(t0.plus(Duration.ofDays(45))))
        assertTrue(i.expired(t0.plus(Duration.ofDays(30))))
        assertFalse(i.expired(t0.plus(Duration.ofDays(30)).minusSeconds(1)))
    }

    @Test fun refusingTheSameTextAgainReplacesTheEarlierCopyButNotAnAppealedOne() = runBlocking {
        store.save(item("a")); store.save(item("b"))
        assertEquals(listOf("b"), store.allNow().map { it.id })
        store.setState("b", AppealState.SENT)
        store.save(item("c"))
        assertEquals(setOf("b", "c"), store.allNow().map { it.id }.toSet())
        // another place or another text is a different item
        store.save(item("d", place = "p2")); store.save(item("e", text = "different"))
        assertEquals(4, store.allNow().size)
    }

    @Test fun aRefusedReviewKeepsItsRatingForTheAppeal() = runBlocking {
        store.save(item("r").copy(rating = 4))
        assertEquals(4, store.get("r")!!.rating)
        assertTrue(store.get("r")!!.appealable)
        assertFalse("a review without a rating cannot be appealed", item("n").appealable)
        assertTrue("photos and places need no rating", item("p", kind = RefusedKind.PHOTO).appealable)
    }

    @Test fun appealStateAndBadgeFollowTheAppeal() = runBlocking {
        store.save(item("a")); store.save(item("b", text = "two"))
        assertEquals(2, RefusedRules.badge(store.allNow(), clock))
        store.setState("a", AppealState.SENT)
        assertEquals(1, RefusedRules.badge(store.allNow(), clock))
        assertEquals(AppealState.SENT, store.get("a")!!.appealState)
        store.setState("a", AppealState.ANSWERED)
        assertEquals(AppealState.ANSWERED, store.get("a")!!.appealState)
    }

    @Test fun postingTheFixedVersionRemovesTheCopyUnlessAnAppealIsWithTheMaintainers() = runBlocking {
        store.save(item("a")); store.save(item("b", text = "two"))
        store.setState("b", AppealState.SENT)
        store.deleteIfUnappealed("a"); store.deleteIfUnappealed("b")
        assertEquals(listOf("b"), store.allNow().map { it.id })
        store.delete("b")
        assertTrue(store.allNow().isEmpty())
    }

    @Test fun textIsClippedAndCannotBreakTheRowFormat() = runBlocking {
        store.save(item("a", text = "x\u001fy".repeat(2000)))
        val got = store.get("a")!!
        assertEquals(RefusedRules.TEXT_MAX, got.text.length)
        assertFalse(got.text.contains('\u001f'))
        store.save(item("n").copy(placeName = "A\u001fB", text = "multi\nline"))
        assertEquals("A B", store.get("n")!!.placeName)
        assertEquals("multi\nline", store.get("n")!!.text)
    }

    @Test fun photoNamesWithPathsAreNeverResolved() {
        store.savePhoto("a", 0, byteArrayOf(1))
        assertNull(store.photoFile("a", "../a/0.jpg"))
        assertNull(store.photoFile("a", "x/0.jpg"))
        assertNotNull(store.photoFile("a", "0.jpg"))
    }

    @Test fun clearForgetsEverything() = runBlocking {
        store.save(item("a")); store.savePhoto("a", 0, byteArrayOf(1))
        store.clear()
        assertTrue(store.allNow().isEmpty())
        assertFalse(File(dir, "refused/a").exists())
    }

    // ---------------------------------------------------------------- never backed up, always created

    @Test fun refusedContentIsNotInABackupSnapshotButExistsOnEveryOpen() {
        store.saveNow(item("a"))
        BackupDb.cleanSnapshot(db)
        assertEquals("snapshot drops it", 0L, db.queryLong("SELECT COUNT(*) FROM sqlite_master WHERE name = 'refused_content'"))
        assertTrue("device-local, not part of a backup", "refused_content" !in GimanoSchema.BACKED_UP_TABLES)

        // an install from before this table: the idempotent open-time upgrade adds it, and runs again harmlessly
        val old = JdbcSqlPort(DriverManager.getConnection("jdbc:sqlite::memory:"))
        GimanoSchema.DDL.filter { !it.startsWith("CREATE TABLE refused_content") && !it.startsWith("CREATE TABLE device_state") && it != GimanoSchema.PERSONAL_ROUTES_DDL && it != GimanoSchema.IDENTITY_DDL }.forEach { old.exec(it) }
        repeat(2) { GimanoSchema.upgrade { old.exec(it) } }
        assertEquals(1L, old.queryLong("SELECT COUNT(*) FROM sqlite_master WHERE name = 'refused_content'"))
        assertEquals(1L, old.queryLong("SELECT COUNT(*) FROM sqlite_master WHERE name = 'device_state'"))
        assertThrows(Exception::class.java) { old.exec("INSERT INTO refused_content (id, kind, created_at) VALUES ('x','bogus','t')") }
    }

    // ---------------------------------------------------------------- appeal validation

    @Test fun noteIsRequiredTrimmedAndAtMost200() {
        assertNull(AppealRules.validNote(""))
        assertNull(AppealRules.validNote("   \n "))
        assertEquals("ok", AppealRules.validNote("  ok  "))
        assertEquals("a".repeat(200), AppealRules.validNote("a".repeat(200)))
        assertNull(AppealRules.validNote("a".repeat(201)))
        assertEquals(200, AppealRules.clipNote("b".repeat(500)).length)
    }

    @Test fun sendStaysDisabledUntilThereIsANoteAndNothingIsInFlight() {
        assertFalse(AppealRules.canSend("", false))
        assertFalse(AppealRules.canSend("   ", false))
        assertTrue(AppealRules.canSend("It is a real shop", false))
        assertFalse("while sending", AppealRules.canSend("It is a real shop", true))
        assertFalse("already appealed", AppealRules.canSend("x", false, AppealState.SENT))
    }

    @Test fun atMostThreePhotosAndFiveMegabytesEach() {
        assertEquals(3, AppealRules.clipPhotos(0, 10))
        assertEquals(1, AppealRules.clipPhotos(2, 5))
        assertEquals(0, AppealRules.clipPhotos(3, 1))
        assertEquals(0, AppealRules.clipPhotos(1, 0))
        assertTrue(AppealRules.photoFits(5 * 1024 * 1024))
        assertFalse(AppealRules.photoFits(5 * 1024 * 1024 + 1))
        assertFalse(AppealRules.photoFits(0))
    }

    @Test fun serverAnswersMapToTheScreensMessages() {
        assertEquals(AppealError.ALREADY_APPEALED, AppealRules.errorOf(409, """{"code":"already_appealed"}"""))
        assertEquals(AppealError.ALREADY_APPEALED, AppealRules.errorOf(409, null))
        assertEquals(AppealError.NOTE_REQUIRED, AppealRules.errorOf(400, """{"code":"note_required","status":400}"""))
        assertEquals(AppealError.OTHER, AppealRules.errorOf(400, """{"code":"other"}"""))
        assertEquals(AppealError.PAUSED, AppealRules.errorOf(403, """{"code":"posting_paused","pausedUntil":"2026-10-28T08:00:00Z"}"""))
        assertEquals(AppealError.BANNED, AppealRules.errorOf(403, """{"title":"Forbidden"}"""))
        assertEquals(AppealError.TOO_LARGE, AppealRules.errorOf(413, null))
        assertEquals(AppealError.OFFLINE, AppealRules.errorOf(null, null, noConnection = true))
        assertEquals(AppealError.OTHER, AppealRules.errorOf(null, null))
        assertEquals(AppealError.OTHER, AppealRules.errorOf(500, "not json"))
        assertEquals(Instant.parse("2026-10-28T08:00:00Z"), AppealRules.pausedUntil("""{"code":"posting_paused","pausedUntil":"2026-10-28T08:00:00Z"}"""))
        assertNull(AppealRules.pausedUntil("garbage"))
    }

    // ---------------------------------------------------------------- the posting pause survives a restart

    @Test fun pauseIsEncodedAndOnlyKeptWhileItRuns() {
        val until = t0.plus(Duration.ofHours(20))
        assertEquals(until, PausePersistence.decode(PausePersistence.encode(until), t0))
        assertNull("ended", PausePersistence.decode(PausePersistence.encode(until), until))
        assertNull(PausePersistence.decode("not a time", t0))
        assertNull(PausePersistence.decode(null, t0))
        assertNull(PausePersistence.encode(null))
    }

    @Test fun postingPauseIsWrittenOnChangeAndRestoredAfterARestart() {
        val saved = mutableListOf<Instant?>()
        PostingPause.persist = { saved += it }
        val until = Instant.now().plus(Duration.ofHours(10))
        PostingPause.set(until)
        assertEquals(listOf<Instant?>(until), saved)
        assertEquals(until, PostingPause.active())

        // "restart": a fresh process restores what was saved
        PostingPause.persist = null
        PostingPause.clear()
        assertNull(PostingPause.active())
        PostingPause.restore(PausePersistence.decode(PausePersistence.encode(until)))
        assertEquals(until, PostingPause.active())

        // an old pause is not brought back
        PostingPause.restore(Instant.now().minusSeconds(5))
        assertNull(PostingPause.active())

        PostingPause.persist = { saved += it }
        PostingPause.clear()
        assertNull(saved.last())
    }
}
