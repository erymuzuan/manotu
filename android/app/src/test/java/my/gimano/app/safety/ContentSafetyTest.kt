package my.gimano.app.safety

import kotlinx.coroutines.runBlocking
import my.gimano.app.core.safety.AdTile
import my.gimano.app.core.safety.ContentFailure
import my.gimano.app.core.safety.ContentGate
import my.gimano.app.core.safety.ContentIssue
import my.gimano.app.core.safety.ContentState
import my.gimano.app.core.safety.InboxContent
import my.gimano.app.core.safety.PhotoIssue
import my.gimano.app.core.safety.PlaceWarning
import my.gimano.app.core.safety.ReviewPrefilter
import my.gimano.app.core.safety.ReviewState
import my.gimano.app.data.model.*
import my.gimano.app.data.remote.GimanoJson
import my.gimano.app.data.repo.DemoRepository
import my.gimano.app.data.repo.Moderation
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.ResponseBody.Companion.toResponseBody
import org.junit.Assert.*
import org.junit.Test
import retrofit2.HttpException
import java.time.Instant

/** docs/content-safety.md: fixed reason codes → app categories, the local pre-filter, and the 201 / 422 / 403 answers. */
class ContentReasonCopyTest {
    @Test fun externalContactCrossesOutThePhoneAndTheLink() {
        assertEquals(listOf(ContentIssue.PHONE, ContentIssue.LINK), ContentGate.issues(listOf("external_contact")))
    }

    @Test fun promotionCodesMapToTheirOwnTile() {
        assertEquals(listOf(ContentIssue.GAMBLING), ContentGate.issues(listOf("gambling_promo")))
        assertEquals(listOf(ContentIssue.ALCOHOL), ContentGate.issues(listOf("alcohol_promo")))
        assertEquals(listOf(ContentIssue.TOBACCO), ContentGate.issues(listOf("tobacco_promo")))
        assertEquals(listOf(ContentIssue.OFFER), ContentGate.issues(listOf("spam")))
        assertEquals(listOf(ContentIssue.OFFER), ContentGate.issues(listOf("brand_promo", "spam")))
        assertEquals(listOf(ContentIssue.MONEY), ContentGate.issues(listOf("loan_shark", "mlm", "high_risk_investment")))
    }

    @Test fun harmCodesMapToTheirOwnTile() {
        assertEquals(listOf(ContentIssue.VIOLENCE), ContentGate.issues(listOf("violence")))
        assertEquals(listOf(ContentIssue.PERSONAL), ContentGate.issues(listOf("personal_data", "private_home")))
        assertEquals(listOf(ContentIssue.HATE), ContentGate.issues(listOf("3r", "harassment")))
        assertEquals(listOf(ContentIssue.DRUGS, ContentIssue.ADULT), ContentGate.issues(listOf("drugs", "adult")))
    }

    @Test fun unknownAndVagueCodesBecomeNotAllowedButNeverBeatASpecificOne() {
        assertEquals(listOf(ContentIssue.OTHER), ContentGate.issues(listOf("some_new_code")))
        assertEquals(listOf(ContentIssue.OTHER), ContentGate.issues(emptyList()))
        assertEquals(listOf(ContentIssue.OTHER), ContentGate.issues(listOf("unclear")))
        assertEquals(listOf(ContentIssue.SCAM), ContentGate.issues(listOf("unclear", "scam")))
        // Warning-only and "ok" codes never mark anything as offending.
        assertEquals(listOf(ContentIssue.OTHER), ContentGate.issues(listOf("ok", "sensitive_alcohol")))
    }

    @Test fun atMostFourTilesAndCaseDoesNotMatter() {
        val r = listOf("EXTERNAL_CONTACT", "spam", "scam", "violence", "adult")
        assertEquals(4, ContentGate.issues(r).size)
        assertEquals(ContentIssue.PHONE, ContentGate.issues(r).first())
    }

    @Test fun everyIssueHasCopyInBothLanguages() {
        val en = java.io.File("src/main/res/values/strings_content_safety.xml").readText()
        val ms = java.io.File("src/main/res/values-ms/strings_content_safety.xml").readText()
        val names = Regex("""name="(cs_[a-z0-9_]+)"""").findAll(en).map { it.groupValues[1] }.toSet()
        assertTrue(names.size > 60)
        for (n in names) assertTrue("missing in values-ms: $n", ms.contains("name=\"$n\""))
        for (i in ContentIssue.entries) assertTrue("cs_issue_${i.name.lowercase()}", en.contains("name=\"cs_issue_${i.name.lowercase()}\""))
    }

    @Test fun photoTilesCrossOutOnlyTheReasonsThatApply() {
        assertEquals(setOf(PhotoIssue.VIOLENCE), ContentGate.photoIssues(listOf("violence")))
        assertEquals(setOf(PhotoIssue.ADULT), ContentGate.photoIssues(listOf("adult")))
        assertEquals(setOf(PhotoIssue.GAMBLING_DRUGS), ContentGate.photoIssues(listOf("gambling_promo", "drugs")))
        assertEquals(setOf(PhotoIssue.PLATES_FACES), ContentGate.photoIssues(listOf("personal_data")))
        assertEquals(emptySet<PhotoIssue>(), ContentGate.photoIssues(listOf("unclear")))
    }

    @Test fun warningsComeInAStableOrderAndIgnoreUnknowns() {
        assertEquals(listOf(PlaceWarning.ALCOHOL, PlaceWarning.GAMBLING, PlaceWarning.TOBACCO), PlaceWarning.of(listOf("tobacco", "x", "alcohol", "gambling", "alcohol")))
        assertEquals(emptyList<PlaceWarning>(), PlaceWarning.of(null))
        assertEquals(listOf("gambling", "tobacco"), PlaceWarning.wire(setOf(PlaceWarning.TOBACCO, PlaceWarning.GAMBLING)))
        assertNull(PlaceWarning.wire(emptySet()))
    }
}

class ReviewPrefilterTest {
    @Test fun phoneNumbersLightThePhoneTile() {
        assertEquals(setOf(AdTile.PHONE), ReviewPrefilter.tiles("Call me 012-345 6789 for a good price"))
        assertEquals(setOf(AdTile.PHONE), ReviewPrefilter.tiles("hubungi +60 12 345 6789"))
        assertEquals(setOf(AdTile.PHONE), ReviewPrefilter.tiles("0123456789"))
        assertEquals(setOf(AdTile.PHONE), ReviewPrefilter.tiles("WhatsApp saya 0123456789"))
        assertEquals(setOf(AdTile.PHONE), ReviewPrefilter.tiles("telegram @bestdeal88"))
    }

    @Test fun linksLightTheLinkTile() {
        assertEquals(setOf(AdTile.LINK), ReviewPrefilter.tiles("see https://example.org/promo"))
        assertEquals(setOf(AdTile.LINK), ReviewPrefilter.tiles("visit www.example.org"))
        assertEquals(setOf(AdTile.LINK), ReviewPrefilter.tiles("order at kedai-saya.com"))
        assertEquals(setOf(AdTile.LINK), ReviewPrefilter.tiles("wa.me/kedai"))
    }

    @Test fun offersAndRepeatedCharactersLightTheOfferTile() {
        assertEquals(setOf(AdTile.OFFER), ReviewPrefilter.tiles("Use promo code MAKAN10 for 10% off"))
        assertEquals(setOf(AdTile.OFFER), ReviewPrefilter.tiles("Daftar sekarang dapat bonus"))
        assertEquals(setOf(AdTile.OFFER), ReviewPrefilter.tiles("sedappppppppppp"))
        assertEquals(setOf(AdTile.OFFER), ReviewPrefilter.tiles("!!!!!!!!!!"))
    }

    @Test fun severalTilesCanLightAtOnce() {
        assertEquals(setOf(AdTile.PHONE, AdTile.LINK, AdTile.OFFER), ReviewPrefilter.tiles("promo code ABC call 012 345 6789 or www.example.org"))
    }

    @Test fun anOrdinaryReviewAndANeutralMentionAreFine() {
        for (t in listOf(
            "", "   ",
            "A vape shop is next door.",
            "There is a bar upstairs but the cafe is quiet.",
            "Parking percuma selepas jam 6. Sedap!",
            "Paid RM12.50 for two drinks, 3 stars, queue 15 min",
            "Open 24 hours, very clean toilets :)",
            "Bersih, parkir mudah selepas Isyak.",
            "Go on 2026-10-27 at 10:30, great",
        )) assertFalse("'$t' should pass", ReviewPrefilter.looksLikeAdvert(t))
    }

    @Test fun postIsBlockedExactlyWhileATileIsLit() {
        assertTrue(ReviewPrefilter.looksLikeAdvert("call 0123456789"))
        assertFalse(ReviewPrefilter.looksLikeAdvert("call the manager"))
    }

    @Test fun theLimitsMatchTheContract() {
        assertEquals(500, ReviewPrefilter.SHOWN_MAX)
        assertEquals(140, ContentGate.NOTE_MAX)
    }
}

class ContentAnswerTest {
    private val reasons = """{"title":"Content rejected","status":422,"code":"content_rejected","reasons":["external_contact","spam"],"safeText":"Nice food, clean toilets."}"""

    @Test fun a422WithASafePartIsRejectedWithThatPart() {
        val f = ContentGate.failure(422, reasons) as ContentFailure.Rejected
        assertEquals(listOf("external_contact", "spam"), f.reasons)
        assertEquals(listOf(ContentIssue.PHONE, ContentIssue.LINK, ContentIssue.OFFER), f.issues)
        assertEquals("Nice food, clean toilets.", ContentGate.safePart(f))
    }

    @Test fun a422WithoutASafePartHasNoPostThisPart() {
        val f = ContentGate.failure(422, """{"code":"content_rejected","reasons":["violence"]}""") as ContentFailure.Rejected
        assertNull(f.safeText)
        assertNull(ContentGate.safePart(f))
        val blank = ContentGate.failure(422, """{"code":"content_rejected","reasons":["violence"],"safeText":"  "}""") as ContentFailure.Rejected
        assertNull(blank.safeText)
    }

    @Test fun theSafePartIsNeverLongerThanTheAppsLimit() {
        val long = "a".repeat(900)
        val f = ContentGate.failure(422, """{"code":"content_rejected","reasons":["spam"],"safeText":"$long"}""") as ContentFailure.Rejected
        assertEquals(ReviewPrefilter.SHOWN_MAX, ContentGate.safePart(f)!!.length)
    }

    @Test fun a422ThatIsNotContentRejectedStaysAnOrdinaryFailure() {
        assertTrue(ContentGate.failure(422, """{"code":"restricted_area","detail":"x"}""") is ContentFailure.Other)
        assertTrue(ContentGate.failure(422, null) is ContentFailure.Other)
        assertTrue(ContentGate.failure(500, "<html>").let { it is ContentFailure.Other && it.status == 500 })
    }

    @Test fun a403PostingPausedCarriesTheTime() {
        val f = ContentGate.failure(403, """{"code":"posting_paused","pausedUntil":"2026-10-28T03:00:00Z"}""") as ContentFailure.Paused
        assertEquals(Instant.parse("2026-10-28T03:00:00Z"), f.until)
        assertTrue(ContentGate.failure(403, """{"code":"posting_paused"}""").let { it is ContentFailure.Paused && it.until == null })
        // A ban (plain 403) is not a pause.
        assertTrue(ContentGate.failure(403, """{"title":"Forbidden"}""") is ContentFailure.Other)
    }

    @Test fun postingPausedIsNotTreatedAsABan() {
        val body = """{"code":"posting_paused","pausedUntil":"2026-10-28T03:00:00Z"}"""
        val e = HttpException(retrofit2.Response.error<Any>(403, body.toResponseBody("application/problem+json".toMediaType())))
        assertTrue(Moderation.isAddingPaused(e))
        assertFalse(Moderation.isAddingPaused(HttpException(retrofit2.Response.error<Any>(403, """{"title":"Forbidden"}""".toResponseBody("application/json".toMediaType())))))
    }

    private fun review(state: String?, held: Boolean = false) =
        Review("r", "p", 5, "x", moderation = state?.let { ContentModeration(it) }, heldForReview = held, status = if (held) "hidden" else "published")

    @Test fun a201IsPassedHeldOrCheckingFromTheModerationState() {
        assertEquals(ReviewState.PASSED, ContentGate.reviewState(review("passed")))
        assertEquals(ReviewState.PASSED, ContentGate.reviewState(review("skipped")))
        assertEquals(ReviewState.PASSED, ContentGate.reviewState(review(null)))
        assertEquals(ReviewState.HELD, ContentGate.reviewState(review("held", held = true)))
        assertEquals(ReviewState.CHECKING, ContentGate.reviewState(review("checking")))
        assertEquals(ReviewState.REJECTED, ContentGate.reviewState(review("rejected")))
        // An older server that only says heldForReview.
        assertEquals(ReviewState.HELD, ContentGate.reviewState(review(null, held = true)))
    }

    @Test fun photoBadgeIsTickClockOrCross() {
        fun ph(status: String, m: String? = null) = Photo("p", status = status, moderation = m?.let { ContentModeration(it) })
        assertEquals(ContentState.PUBLISHED, ContentGate.photoState(ph("published")))
        assertEquals(ContentState.PUBLISHED, ContentGate.photoState(ph("published", "passed")))
        assertEquals(ContentState.PROCESSING, ContentGate.photoState(ph("processing", "checking")))
        assertEquals(ContentState.PROCESSING, ContentGate.photoState(ph("processing", "held")))
        assertEquals(ContentState.REJECTED, ContentGate.photoState(ph("rejected")))
        assertEquals(ContentState.REJECTED, ContentGate.photoState(ph("processing", "rejected")))
        assertTrue(ContentGate.shouldPoll(ph("processing")))
        assertFalse(ContentGate.shouldPoll(ph("published", "passed")))
        assertFalse(ContentGate.shouldPoll(ph("rejected")))
    }

    @Test fun inboxKindsAndTheirButtons() {
        val rej = InboxItem("1", "content_rejected", subjectKind = "review", subjectId = "r1", reasons = listOf("spam"), canAppeal = true)
        assertEquals(InboxContent.REJECTED, ContentGate.inboxContent(rej.kind))
        assertTrue(ContentGate.canAppeal(rej))
        assertFalse(ContentGate.canAppeal(rej.copy(canAppeal = false)))
        assertFalse(ContentGate.canAppeal(rej.copy(kind = "content_held")))
        assertEquals(InboxContent.HELD, ContentGate.inboxContent("content_held"))
        assertEquals(InboxContent.PUBLISHED, ContentGate.inboxContent("content_published"))
        assertNull(ContentGate.inboxContent("place_held"))
    }

    @Test fun theWireFormatParses() {
        val place = GimanoJson.decodeFromString(Place.serializer(), """{"id":"a","name":"B","lat":1.0,"lng":2.0,"warnings":["alcohol","gambling"]}""")
        assertEquals(listOf("alcohol", "gambling"), place.warnings)
        assertEquals(listOf("alcohol", "gambling"), place.summary().warnings)
        val review = GimanoJson.decodeFromString(Review.serializer(),
            """{"id":"r","placeId":"p","rating":4,"status":"hidden","heldForReview":true,"moderation":{"state":"held","reasons":["unclear"],"canAppeal":false}}""")
        assertEquals("held", review.moderation?.state)
        val photo = GimanoJson.decodeFromString(Photo.serializer(), """{"id":"x","status":"rejected","moderation":{"state":"rejected","reasons":["violence"],"canAppeal":true}}""")
        assertTrue(ContentGate.canAppeal(photo))
        val report = GimanoJson.decodeFromString(Report.serializer(),
            """{"id":"r","type":"hazard","lat":1.0,"lng":2.0,"createdAt":"2026-10-27T00:00:00Z","expiresAt":"2026-10-27T01:00:00Z","noteDropped":true,"noteReasons":["external_contact"]}""")
        assertTrue(ContentGate.noteDropped(report))
        val item = GimanoJson.decodeFromString(InboxItem.serializer(),
            """{"id":"i","kind":"content_rejected","placeId":"p","subjectKind":"photo","subjectId":"x","reasons":["adult"],"canAppeal":true}""")
        assertEquals("photo", item.subjectKind)
        assertEquals("p", item.placeRef)
    }

    @Test fun warningsAreSentOnlyWhenChosen() {
        val none = GimanoJson.encodeToString(CreatePlaceRequest.serializer(), CreatePlaceRequest("n", "cafe", 1.0, 2.0))
        assertFalse(none.contains("warnings"))
        val some = GimanoJson.encodeToString(CreatePlaceRequest.serializer(), CreatePlaceRequest("n", "cafe", 1.0, 2.0, warnings = PlaceWarning.wire(setOf(PlaceWarning.TOBACCO, PlaceWarning.ALCOHOL))))
        assertTrue(some.contains(""""warnings":["alcohol","tobacco"]"""))
    }
}

/** The demo backend answers like the real one, so the 201 / 422 / 403 handling can be tried offline. */
class DemoContentSafetyTest {
    private fun code(e: HttpException) = e.code()
    private fun body(e: HttpException) = e.response()?.errorBody()?.string()

    @Test fun anOrdinaryReviewPassesAHeldOneWaitsAndASlowOneIsChecking() = runBlocking {
        val repo = DemoRepository()
        val a = repo.createReview("klcc", ReviewRequest(5, "Clean and quiet."))
        assertEquals(ReviewState.PASSED, ContentGate.reviewState(a))
        val b = repo.createReview("pavilion", ReviewRequest(4, "Polis ada di sini"))
        assertEquals(ReviewState.HELD, ContentGate.reviewState(b))
        assertEquals("hidden", b.status)
        val c = repo.createReview("sunway", ReviewRequest(4, "Servis agak lambat"))
        assertEquals(ReviewState.CHECKING, ContentGate.reviewState(c))
    }

    @Test fun anAdvertGets422WithTheSafePart() = runBlocking {
        val repo = DemoRepository()
        val e = try { repo.createReview("klcc", ReviewRequest(5, "Nice food. Call 012-345 6789 for a promo code.")); null } catch (e: HttpException) { e }!!
        assertEquals(422, code(e))
        val f = ContentGate.failure(code(e), body(e)) as ContentFailure.Rejected
        assertTrue("external_contact" in f.reasons)
        assertEquals("Nice food.", f.safeText)
        // Nothing was stored.
        assertTrue(repo.reviews("klcc").reviews.none { it.mine })
    }

    @Test fun threeRejectionsPausePosting() = runBlocking {
        val repo = DemoRepository()
        repeat(3) {
            val e = try { repo.createReview("klcc", ReviewRequest(1, "judi online")); null } catch (e: HttpException) { e }!!
            assertEquals(422, code(e))
        }
        val e = try { repo.createReview("klcc", ReviewRequest(5, "Fine place.")); null } catch (e: HttpException) { e }!!
        assertEquals(403, code(e))
        val f = ContentGate.failure(403, body(e)) as ContentFailure.Paused
        assertTrue(f.until!!.isAfter(Instant.now()))
    }

    @Test fun aDroppedNoteStillSendsTheReport() = runBlocking {
        val repo = DemoRepository()
        val r = repo.createReport(CreateReportRequest("hazard", null, 3.1, 101.6, null, "ring 0123456789 now"))
        assertTrue(r.noteDropped)
        assertNull(r.comment)
        assertEquals(listOf("external_contact"), r.noteReasons)
        val ok = repo.createReport(CreateReportRequest("hazard", null, 3.1, 101.6, null, "oil on the road"))
        assertFalse(ok.noteDropped)
        assertEquals("oil on the road", ok.comment)
    }

    @Test fun everyThirdPhotoIsRejectedAfterAMomentAndCanBeAppealed() = runBlocking {
        val repo = DemoRepository()
        val ids = (1..3).map { repo.uploadPhoto("klcc", byteArrayOf(1, 2, 3), null).id }
        assertEquals(ContentState.PROCESSING, ContentGate.photoState(repo.photo(ids[0])))
        Thread.sleep(2_100)
        assertEquals(ContentState.PUBLISHED, ContentGate.photoState(repo.photo(ids[0])))
        assertEquals(ContentState.PUBLISHED, ContentGate.photoState(repo.photo(ids[1])))
        val bad = repo.photo(ids[2])
        assertEquals(ContentState.REJECTED, ContentGate.photoState(bad))
        assertTrue(ContentGate.canAppeal(bad))
        repo.appealPhoto(ids[2], "It is the shop sign")
        assertEquals(ContentState.PROCESSING, ContentGate.photoState(repo.photo(ids[2])))
    }

    @Test fun placesWithWarningsAndTheInboxKindsExist() = runBlocking {
        val repo = DemoRepository()
        assertEquals(listOf("alcohol"), repo.place("alehouse").warnings)
        assertEquals(listOf("alcohol", "gambling"), repo.place("sports-lounge").warnings)
        assertTrue(repo.place("klcc").warnings.isEmpty())
        val kinds = repo.inbox().map { it.kind }
        assertTrue(kinds.containsAll(listOf("content_rejected", "content_held", "content_published")))
        val created = repo.createPlace(CreatePlaceRequest("Kopi Corner", "cafe", 3.1, 101.6, warnings = listOf("tobacco")))
        assertEquals(listOf("tobacco"), created.warnings)
    }
}
