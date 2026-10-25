package my.gimano.app.places

import kotlinx.coroutines.flow.first
import kotlinx.coroutines.runBlocking
import my.gimano.app.core.identity.RequestSigning
import my.gimano.app.core.places.AddResult
import my.gimano.app.core.places.CreateFailure
import my.gimano.app.core.places.HoldReason
import my.gimano.app.core.places.MyPlaceStatus
import my.gimano.app.core.places.PlaceGate
import my.gimano.app.core.places.RejectKind
import my.gimano.app.data.model.*
import my.gimano.app.data.places.PlaceDraft
import my.gimano.app.data.places.PlaceDrafts
import my.gimano.app.data.remote.GimanoJson
import my.gimano.app.data.repo.DemoRepository
import my.gimano.app.data.repo.GimanoRepository
import my.gimano.app.data.repo.Moderation
import my.gimano.app.feedback.FakeOutbox
import okhttp3.ResponseBody.Companion.toResponseBody
import org.junit.Assert.*
import org.junit.Test
import retrofit2.HttpException
import java.io.IOException
import java.nio.file.Files
import java.time.Instant

/** Design "Add a place with an AI gate": the owner's screening → which screen; refusals → B1 / B5 / paused. */
class PlaceGateResultTest {
    private fun sc(state: String, vararg reasons: String, canAppeal: Boolean = false, appealed: Boolean = false) =
        PlaceScreening(state, reasons.toList(), canAppeal, appealed)

    @Test fun passedIsLiveAndEmasPublishedIsGold() {
        assertEquals(AddResult.LIVE, PlaceGate.result("pending", false, sc("passed", "ok")))
        assertEquals(AddResult.GOLD, PlaceGate.result("published", false, sc("passed", "ok")))
        // Published with the check skipped (over budget) is still an Emas place: A5.
        assertEquals(AddResult.GOLD, PlaceGate.result("published", false, sc("skipped")))
    }

    @Test fun heldGoesToAPerson() {
        assertEquals(AddResult.HELD, PlaceGate.result("hidden", true, sc("held", "security")))
        // Held by the restricted-area rules (no AI answer): the same B2.
        assertEquals(AddResult.HELD, PlaceGate.result("hidden", true, null))
        assertEquals(AddResult.HELD, PlaceGate.result("hidden", false, sc("held", "unclear")))
    }

    @Test fun rejectedSplitsIntoAdvertAndPersonalScreens() {
        for (r in listOf("spam", "scam", "illegal", "adult", "gibberish", "duplicate", "unclear", "wrong_category"))
            assertEquals(r, AddResult.NOT_ACCEPTED, PlaceGate.result("rejected", false, sc("rejected", r, canAppeal = true)))
        assertEquals(AddResult.NOT_ACCEPTED_PERSONAL, PlaceGate.result("rejected", false, sc("rejected", "private_home")))
        assertEquals(AddResult.NOT_ACCEPTED_PERSONAL, PlaceGate.result("rejected", false, sc("rejected", "harassment")))
        // A rejected status without a screening block still reads as "not accepted".
        assertEquals(AddResult.NOT_ACCEPTED, PlaceGate.result("rejected", false, null))
        assertTrue(AddResult.NOT_ACCEPTED_PERSONAL.notAccepted && AddResult.NOT_ACCEPTED.notAccepted && !AddResult.HELD.notAccepted)
    }

    @Test fun checkingAndThePlainPath() {
        assertEquals(AddResult.CHECKING, PlaceGate.result("pending", false, sc("checking")))
        assertEquals(AddResult.PENDING, PlaceGate.result("pending", false, sc("skipped")))
        assertEquals(AddResult.PENDING, PlaceGate.result("pending", false, sc("none")))
        assertEquals(AddResult.PENDING, PlaceGate.result("pending", false, null))
    }

    @Test fun reasonCodesMapToFixedCopy() {
        assertEquals(RejectKind.ADVERT, PlaceGate.rejectKind(listOf("spam")))
        assertEquals(RejectKind.SCAM, PlaceGate.rejectKind(listOf("scam")))
        assertEquals(RejectKind.ILLEGAL, PlaceGate.rejectKind(listOf("illegal")))
        assertEquals(RejectKind.ADULT, PlaceGate.rejectKind(listOf("adult")))
        assertEquals(RejectKind.GIBBERISH, PlaceGate.rejectKind(listOf("gibberish")))
        assertEquals(RejectKind.PRIVATE_HOME, PlaceGate.rejectKind(listOf("PRIVATE_HOME")))
        assertEquals(RejectKind.HARASSMENT, PlaceGate.rejectKind(listOf("harassment")))
        assertEquals(RejectKind.OTHER, PlaceGate.rejectKind(listOf("wrong_category")))
        assertEquals(RejectKind.OTHER, PlaceGate.rejectKind(emptyList()))
        // A home with an advert in it: the privacy-safe screen (B4, "Keep it just for me") wins.
        assertEquals(RejectKind.PRIVATE_HOME, PlaceGate.rejectKind(listOf("spam", "private_home")))
        assertTrue(RejectKind.PRIVATE_HOME.personal && RejectKind.HARASSMENT.personal && !RejectKind.SCAM.personal)
    }

    @Test fun holdReasons() {
        assertEquals(HoldReason.APPEALED, PlaceGate.holdReason(sc("held", "private_home", appealed = true)))
        assertEquals(HoldReason.SECURITY, PlaceGate.holdReason(sc("held", "security")))
        assertEquals(HoldReason.DUPLICATE, PlaceGate.holdReason(sc("held", "duplicate")))
        assertEquals(HoldReason.UNSURE, PlaceGate.holdReason(sc("held", "unclear")))
        assertEquals(HoldReason.UNSURE, PlaceGate.holdReason(null))
    }
}

class PlaceGateFailureTest {
    @Test fun duplicateCarriesTheExistingPlace() {
        val body = """{"title":"Conflict","status":409,"existing":{"id":"c-1","name":"99 Speedmart Seksyen 9","category":"convenience","address":"Bangi","lat":2.96,"lng":101.76,"source":"community","status":"published","distanceM":40}}"""
        val f = PlaceGate.failure(409, body, null) as CreateFailure.Duplicate
        assertEquals("c-1", f.existing?.id)
        assertEquals(40.0, f.existing?.distanceM ?: 0.0, 0.0)
    }

    @Test fun olderDuplicateBodiesStillWork() {
        val asPlace = """{"id":"p-9","name":"Kedai Runcit","lat":3.1,"lng":101.6}"""
        assertEquals("p-9", (PlaceGate.failure(409, asPlace, null) as CreateFailure.Duplicate).existing?.id)
        val wrapped = """{"place":{"id":"p-8","name":"Kedai Runcit","lat":3.1,"lng":101.6}}"""
        assertEquals("p-8", (PlaceGate.failure(409, wrapped, null) as CreateFailure.Duplicate).existing?.id)
        assertNull((PlaceGate.failure(409, "not json", null) as CreateFailure.Duplicate).existing)
        assertNull((PlaceGate.failure(409, null, null) as CreateFailure.Duplicate).existing)
    }

    @Test fun rateLimitShowsWholeMinutes() {
        val f = PlaceGate.failure(429, """{"status":429,"retryAfterSeconds":2400}""", "2400") as CreateFailure.RateLimited
        assertEquals(2400, f.retryAfterSeconds)
        assertEquals(40, f.minutes)
        // Only the header (older server): still read.
        assertEquals(41, (PlaceGate.failure(429, "{}", " 2401 ") as CreateFailure.RateLimited).minutes)
        assertNull((PlaceGate.failure(429, null, null) as CreateFailure.RateLimited).minutes)
    }

    @Test fun minutesRoundUp() {
        assertEquals(40, PlaceGate.minutes(2400))
        assertEquals(41, PlaceGate.minutes(2401))
        assertEquals(1, PlaceGate.minutes(5))
        assertNull(PlaceGate.minutes(0))
        assertNull(PlaceGate.minutes(null))
    }

    @Test fun addingPausedHasItsTime() {
        val z = PlaceGate.failure(403, """{"status":403,"code":"adding_paused","pausedUntil":"2026-10-26T13:40:00Z"}""", null) as CreateFailure.Paused
        assertEquals(Instant.parse("2026-10-26T13:40:00Z"), z.until)
        // .NET DateTimeOffset writes an offset.
        val off = PlaceGate.failure(403, """{"code":"adding_paused","pausedUntil":"2026-10-26T21:40:00+08:00"}""", null) as CreateFailure.Paused
        assertEquals(Instant.parse("2026-10-26T13:40:00Z"), off.until)
        assertNull((PlaceGate.failure(403, """{"code":"adding_paused"}""", null) as CreateFailure.Paused).until)
    }

    @Test fun aBanIsNotAPause() {
        assertTrue(PlaceGate.failure(403, """{"title":"Forbidden","status":403}""", null) is CreateFailure.Other)
        val other = PlaceGate.failure(400, """{"title":"Bad request","detail":"Name is required"}""", null) as CreateFailure.Other
        assertEquals("Name is required", other.detail)
    }
}

class MyPlacesStatusTest {
    private fun s(status: String?, screening: PlaceScreening? = null, held: Boolean = false, conf: Double? = null, req: Double? = null) =
        PlaceSummary("c", "Kuih Mak Teh", "restaurant", "", 3.0, 101.0, source = "community", status = status, screening = screening,
            heldForReview = held, confirmationsWeighted = conf, required = req)

    @Test fun everyStatusHasItsLabel() {
        assertEquals(MyPlaceStatus.COMMUNITY_VERIFIED, PlaceGate.myStatus(s("published", PlaceScreening("passed"))))
        assertEquals(MyPlaceStatus.LIVE_UNVERIFIED, PlaceGate.myStatus(s("pending", PlaceScreening("passed"))))
        assertEquals(MyPlaceStatus.WAITING, PlaceGate.myStatus(s("pending", PlaceScreening("skipped"))))
        assertEquals(MyPlaceStatus.WAITING, PlaceGate.myStatus(s("pending")))
        assertEquals(MyPlaceStatus.CHECKING, PlaceGate.myStatus(s("pending", PlaceScreening("checking"))))
        assertEquals(MyPlaceStatus.HELD, PlaceGate.myStatus(s("hidden", PlaceScreening("held"), held = true)))
        assertEquals(MyPlaceStatus.HELD, PlaceGate.myStatus(s("hidden", held = true)))
        assertEquals(MyPlaceStatus.NOT_ACCEPTED, PlaceGate.myStatus(s("rejected", PlaceScreening("rejected", listOf("spam")))))
        assertEquals(MyPlaceStatus.HIDDEN, PlaceGate.myStatus(s("hidden", PlaceScreening("passed"))))
        assertEquals(MyPlaceStatus.EXPIRED, PlaceGate.myStatus(s("expired")))
        assertEquals(MyPlaceStatus.CLOSED, PlaceGate.myStatus(s("closed")))
    }

    @Test fun progressReadsLikeTheBoard() {
        assertEquals("0" to "1", PlaceGate.progress(s("pending", conf = 0.0, req = 1.0)))
        assertEquals("1.5" to "3", PlaceGate.progress(s("pending", conf = 1.5, req = 3.0)))
        assertEquals("0" to "3", PlaceGate.progress(s("pending", req = 3.0)))
        assertNull(PlaceGate.progress(s("pending")))
    }
}

class PlaceGateWireTest {
    @Test fun ownersPlaceCarriesScreeningAndRejectedStatus() {
        val json = """{"id":"c-2","name":"BEST FOREX","lat":3.1,"lng":101.6,"source":"community","status":"rejected",
            "screening":{"state":"rejected","reasons":["spam"],"canAppeal":true,"appealed":false},"heldForReview":false}"""
        val p = GimanoJson.decodeFromString(Place.serializer(), json)
        assertEquals("rejected", p.status)
        assertEquals(listOf("spam"), p.screening?.reasons)
        assertTrue(p.screening!!.canAppeal)
        assertEquals("the summary keeps it for My places", "rejected", p.summary().screening?.state)
        assertEquals(AddResult.NOT_ACCEPTED, PlaceGate.result(p))
    }

    @Test fun notDuplicateOfIsSentOnlyWhenSet() {
        val plain = GimanoJson.encodeToString(CreatePlaceRequest.serializer(), CreatePlaceRequest("Kedai", "shop", 3.0, 101.0))
        assertFalse(plain, plain.contains("notDuplicateOf"))
        val different = GimanoJson.encodeToString(CreatePlaceRequest.serializer(), CreatePlaceRequest("Kedai", "shop", 3.0, 101.0, notDuplicateOf = "c-1"))
        assertTrue(different, different.contains("\"notDuplicateOf\":\"c-1\""))
    }

    @Test fun inboxPlaceKindsPointAtThePlace() {
        val json = """[{"id":"i1","kind":"place_not_accepted","title":"Kedai was not accepted","body":"Open it to see why.","refType":"place","refId":"c-7","createdAt":"2026-10-25T00:00:00Z","read":false,"count":1},
            {"id":"i2","kind":"place_live","refType":"place","refId":"c-8"},{"id":"i3","kind":"announcement"}]"""
        val items = GimanoJson.decodeFromString(kotlinx.serialization.builtins.ListSerializer(InboxItem.serializer()), json)
        assertEquals("c-7", items[0].placeRef)
        assertEquals("c-8", items[1].placeRef)
        assertNull(items[2].placeRef)
        assertEquals("legacy rows used placeId", "p-1", InboxItem("x", "place_published", placeId = "p-1").placeRef)
    }

    @Test fun appealIsSigned() {
        assertTrue(RequestSigning.isSigned("POST", "/api/v1/places/c-1/appeal"))
        assertFalse(RequestSigning.isSigned("GET", "/api/v1/places/c-1/appeal"))
    }

    @Test fun appealNoteLimitMatchesTheContract() = assertEquals(200, PlaceGate.APPEAL_MAX)
}

/** Demo mode: a pass by default, and every other outcome reachable by a word in the name. */
class DemoGateTest {
    private fun req(name: String, description: String? = null, notDuplicateOf: String? = null) =
        CreatePlaceRequest(name, "restaurant", 3.07, 101.52, description = description, notDuplicateOf = notDuplicateOf)

    private suspend fun failureOf(d: DemoRepository, r: CreatePlaceRequest): CreateFailure = try {
        d.createPlace(r); error("expected a refusal")
    } catch (e: HttpException) {
        PlaceGate.failure(e.code(), e.response()?.errorBody()?.string(), null)
    }

    @Test fun outcomes() = runBlocking {
        val d = DemoRepository()
        assertEquals(AddResult.LIVE, PlaceGate.result(d.createPlace(req("Gerai Nasi Kerabu Mek Na"))))
        assertEquals(AddResult.GOLD, PlaceGate.result(d.createPlace(req("Kedai Emas Bangi"))))
        assertEquals(AddResult.HELD, PlaceGate.result(d.createPlace(req("Parkir IPD", "CCTV dan pengawal 24 jam"))))
        assertEquals(AddResult.NOT_ACCEPTED, PlaceGate.result(d.createPlace(req("BEST FOREX SIGNAL"))))
        assertEquals(AddResult.NOT_ACCEPTED_PERSONAL, PlaceGate.result(d.createPlace(req("Rumah Mak Teh"))))
        assertEquals(AddResult.CHECKING, PlaceGate.result(d.createPlace(req("Warung Lambat"))))
    }

    @Test fun refusals() = runBlocking {
        val d = DemoRepository()
        val dup = failureOf(d, req("99 Speedmart Seksyen 9")) as CreateFailure.Duplicate
        assertNotNull(dup.existing)
        // "No, mine is a different place": sent again with notDuplicateOf, it goes through.
        assertEquals(AddResult.LIVE, PlaceGate.result(d.createPlace(req("99 Speedmart Seksyen 9", notDuplicateOf = dup.existing!!.id))))
        assertEquals(40, (failureOf(d, req("Limit test")) as CreateFailure.RateLimited).minutes)
        assertNotNull((failureOf(d, req("Pause test")) as CreateFailure.Paused).until)
    }

    @Test fun pausedIsNotReportedAsBanned() = runBlocking {
        val e = try { DemoRepository().createPlace(req("Pause test")); null } catch (e: HttpException) { e }!!
        assertTrue(Moderation.isAddingPaused(e))
        assertFalse(Moderation.isBanned(e))
        // The body can still be read after the check (peeked, not consumed).
        assertTrue(PlaceGate.failure(403, e.response()?.errorBody()?.string(), null) is CreateFailure.Paused)
    }

    @Test fun appealOnceThenHeld() = runBlocking {
        val d = DemoRepository()
        val p = d.createPlace(req("Rumah Mak Teh"))
        assertTrue(p.screening!!.canAppeal)
        val held = d.appealPlace(p.id, "Mak Teh sells kuih every morning.")
        assertEquals(AddResult.HELD, PlaceGate.result(held))
        assertEquals(HoldReason.APPEALED, PlaceGate.holdReason(held.screening))
        val again = try { d.appealPlace(p.id, null); null } catch (e: HttpException) { e }
        assertEquals(409, again?.code())
    }

    @Test fun myPlacesShowEveryStatusInDemo() = runBlocking {
        val statuses = DemoRepository().contributedPlaces().map(PlaceGate::myStatus).toSet()
        for (s in listOf(MyPlaceStatus.COMMUNITY_VERIFIED, MyPlaceStatus.LIVE_UNVERIFIED, MyPlaceStatus.HELD, MyPlaceStatus.NOT_ACCEPTED, MyPlaceStatus.HIDDEN))
            assertTrue("$s in $statuses", s in statuses)
        val inbox = DemoRepository().inbox().map { it.kind }
        assertTrue(inbox.toString(), "place_held" in inbox && "place_not_accepted" in inbox)
    }
}

/** B5 / B6: drafts stay on the phone; offline ones go out by themselves when the server answers. */
class PlaceDraftsTest {
    private class Flaky(var fail: Exception?) : GimanoRepository by DemoRepository() {
        val sent = ArrayList<CreatePlaceRequest>()
        override suspend fun createPlace(body: CreatePlaceRequest): Place {
            fail?.let { throw it }
            sent += body
            return Place("c-${sent.size}", body.name, body.category, "", body.lat, body.lng, source = "community", status = "pending",
                screening = PlaceScreening("passed", listOf("ok")))
        }
    }

    private val dir = Files.createTempDirectory("drafts").toFile()
    private val now = Instant.parse("2026-10-25T10:00:00Z")
    private fun draft(id: String, reason: String) =
        PlaceDraft(id, CreatePlaceRequest("Surau Al-Ikhlas", "surau", 3.0, 101.0), reason, createdAt = now.toString())

    @Test fun offlineDraftIsSentWhenBackOnline() = runBlocking {
        val outbox = FakeOutbox(); val repo = Flaky(IOException("offline"))
        val drafts = PlaceDrafts(outbox, repo, dir) { now }
        drafts.save(draft("d1", PlaceDraft.OFFLINE))
        drafts.save(draft("d2", PlaceDraft.LIMIT).copy(notBefore = now.plusSeconds(2400).toString()))
        assertEquals(0, drafts.retryQueued())
        assertEquals(2, drafts.drafts.first().size)
        repo.fail = null
        assertEquals("only the offline one goes by itself", 1, drafts.retryQueued())
        assertEquals(listOf("d2"), drafts.drafts.first().map { it.id })
    }

    @Test fun aRefusedQueuedDraftWaitsForTheUser() = runBlocking {
        val outbox = FakeOutbox()
        val limited = HttpException(retrofit2.Response.error<Any>(429, """{"retryAfterSeconds":600}""".toResponseBody(null)))
        val repo = Flaky(limited)
        val drafts = PlaceDrafts(outbox, repo, dir) { now }
        drafts.save(draft("d1", PlaceDraft.OFFLINE))
        assertTrue(drafts.send(draft("d1", PlaceDraft.OFFLINE)).isFailure)
        val d = drafts.get("d1")!!
        assertEquals(PlaceDraft.LIMIT, d.reason)
        assertEquals(now.plusSeconds(600), d.readyAt())
        assertFalse(d.ready(now))
        assertTrue(d.ready(now.plusSeconds(600)))
        assertEquals("no longer retried by itself", 0, drafts.retryQueued())
    }

    @Test fun discardRemovesThePhotoCopies() = runBlocking {
        val drafts = PlaceDrafts(FakeOutbox(), Flaky(null), dir) { now }
        val f = drafts.photoFile("d3", 0).also { it.writeBytes(byteArrayOf(1, 2, 3)) }
        drafts.save(draft("d3", PlaceDraft.LIMIT).copy(photos = listOf(f.path)))
        drafts.delete("d3")
        assertFalse(f.exists())
        assertNull(drafts.get("d3"))
    }
}
