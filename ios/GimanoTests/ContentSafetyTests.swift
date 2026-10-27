import Foundation
import Testing
import UIKit
@testable import Gimano

/// Public content safety (docs/content-safety.md): reason codes → fixed copy, the local review pre-filter, 201 / 422 / 403
/// handling, photo badges, report notes and the demo backend.
@Suite("Content safety")
struct ContentSafetyTests {
    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try JSON.makeDecoder().decode(T.self, from: Data(json.utf8))
    }

    private func problem(_ status: Int, code: String, reasons: [String]? = nil, safeText: String? = nil, pausedUntil: String? = nil) -> APIError {
        .http(status: status, problem: ProblemDetails(status: status, code: code, pausedUntil: pausedUntil, reasons: reasons, safeText: safeText))
    }

    // MARK: reason code → copy

    @Test("Every fixed reason code has its own short app copy; unknown codes read as unclear")
    func copy() {
        let all = ContentReason.allCases.filter { $0 != .ok }
        let lines = all.map { String(localized: $0.copy) }
        #expect(lines.allSatisfy { !$0.isEmpty })
        #expect(Set(lines).count == all.count, "one distinct line per code")
        #expect(ContentReason.parse(["external_contact", "3R", "something_new_from_2027"]) == [.externalContact, .threeR, .unclear])
        #expect(ContentReason.explaining(["ok", "sensitive_alcohol", "violence", "violence"]) == [.violence], "no ok, no warning-only, no repeats")
        #expect(ContentReason.sensitiveGambling.isWarningOnly && !ContentReason.gamblingPromo.isWarningOnly)
    }

    @Test("Every code from docs/api.md is known")
    func contractCodes() {
        let codes = ["violence", "drugs", "personal_data", "3r", "gambling_promo", "alcohol_promo", "tobacco_promo", "brand_promo",
                     "external_contact", "high_risk_investment", "loan_shark", "mlm", "counterfeit", "medical_claims",
                     "sensitive_alcohol", "sensitive_gambling", "sensitive_tobacco",
                     "spam", "scam", "gibberish", "harassment", "private_home", "adult", "illegal", "security", "unclear", "ok"]
        for c in codes { #expect(ContentReason(rawValue: c) != nil, "\(c)") }
    }

    @Test("Reasons cross out the matching icon tiles, at most four, no repeats")
    func tiles() {
        #expect(ContentReason.externalContact.tiles == [.phone, .link])
        #expect(ContentReason.brandPromo.tiles == [.offer])
        #expect(ContentFailure.tiles(for: [.externalContact, .brandPromo, .gamblingPromo]) == [.phone, .link, .offer])
        #expect(ContentFailure.tiles(for: [.violence, .adult, .drugs, .personalData, .threeR]).count == 4)
        #expect(ContentReason.violence.photoTile == .violence && ContentReason.drugs.photoTile == .gamblingDrugs
                && ContentReason.personalData.photoTile == .personal && ContentReason.adult.photoTile == .adult)
        #expect(PhotoWatcher.litTiles(["violence", "personal_data", "ok"]) == [.violence, .personal])
    }

    @Test("Place codes from the content check read as the closest place copy; warning-only codes are not a rejection")
    func placeAliases() {
        #expect(ScreeningReason.primary(["gambling_promo"]) == .spam)
        #expect(ScreeningReason.primary(["loan_shark"]) == .scam)
        #expect(ScreeningReason.primary(["drugs"]) == .illegal)
        #expect(ScreeningReason.primary(["new_code_from_2027"]) == .unclear)
        #expect(ScreeningReason.parse(["sensitive_alcohol"]) == [.ok])
    }

    @Test("Every icon the screens use exists as an SF Symbol")
    func symbols() {
        let names = PlaceWarning.allCases.map(\.symbol) + ContentTile.allCases.map(\.symbol)
            + ["xmark.shield.fill", "eye.slash.fill", "person.fill.questionmark", "pause.circle.fill", "questionmark.circle.fill", "flag.fill", "location.slash.fill"]
            + [PhotoBadge.published, .checking, .rejected].map(\.symbol)
            + ["checkmark.circle.fill", "person.fill", "clock.fill", "xmark.circle.fill"]
        for n in names { #expect(UIImage(systemName: n) != nil, "\(n)") }
    }

    // MARK: place warnings

    @Test("Warnings decode, keep a fixed order, ignore unknown words and encode only when set")
    func warnings() throws {
        let p = try decode(Place.self, #"{"id":"osm-n-1","name":"Pub","category":"other","address":"","lat":3.1,"lng":101.6,"warnings":["tobacco","alcohol","tobacco","mystery"]}"#)
        #expect(PlaceWarning.parse(p.warnings) == [.alcohol, .tobacco])
        #expect(p.summary.warnings == p.warnings)
        let none = try decode(PlaceSummary.self, #"{"id":"a","name":"A","category":"cafe","address":"","lat":1,"lng":2}"#)
        #expect(PlaceWarning.parse(none.warnings).isEmpty)

        #expect(PlaceWarning.wire([]) == nil)
        #expect(PlaceWarning.wire([.tobacco, .gambling]) == ["gambling", "tobacco"])
        let enc = JSON.makeEncoder()
        let plain = String(decoding: try enc.encode(NewPlace(name: "A", category: .cafe, lat: 1, lng: 2)), as: UTF8.self)
        #expect(!plain.contains("warnings"))
        let tagged = String(decoding: try enc.encode(NewPlace(name: "A", category: .cafe, lat: 1, lng: 2, warnings: ["alcohol"])), as: UTF8.self)
        #expect(tagged.contains("\"warnings\":[\"alcohol\"]"))

        #expect(String(localized: WarningCopy.line([.alcohol])) != String(localized: WarningCopy.line([.gambling])))
        #expect(!String(localized: WarningCopy.line([.alcohol, .tobacco])).isEmpty)
    }

    @Test("Add-place tiles toggle; None clears")
    func selection() {
        var s = WarningSelection.toggled(.alcohol, in: [])
        s = WarningSelection.toggled(.gambling, in: s)
        #expect(s == [.alcohol, .gambling])
        #expect(WarningSelection.toggled(.alcohol, in: s) == [.gambling])
        #expect(WarningSelection.none(s).isEmpty)
    }

    // MARK: local pre-filter

    @Test("Phone numbers, WhatsApp, links and offers light the three tiles")
    func prefilterHits() {
        #expect(ReviewPrefilter.hints("Call 012-345 6789 for a table") == [.phone])
        #expect(ReviewPrefilter.hints("hubungi +60 12 3456789") == [.phone])
        #expect(ReviewPrefilter.hints("WhatsApp me") == [.phone])
        #expect(ReviewPrefilter.hints("see www.bestdeal.com") == [.link])
        #expect(ReviewPrefilter.hints("order at bestdeal.my today") == [.link])
        #expect(ReviewPrefilter.hints("https://t.me/winbig") .contains(.link))
        #expect(ReviewPrefilter.hints("Use promo code MAKAN10").contains(.offer))
        #expect(ReviewPrefilter.hints("daftar sekarang dapat bonus").contains(.offer))
        #expect(ReviewPrefilter.hints("Sedappppppp!!!!!!!") == [.offer], "repeated characters")
        #expect(ReviewPrefilter.hints("buy buy buy buy now") == [.offer], "repeated word")
        #expect(ReviewPrefilter.looksLikeAdvert("call 0123456789 or visit bestdeal.com"))
        #expect(ReviewPrefilter.hints("call 0123456789 or visit bestdeal.com") == [.phone, .link])
    }

    @Test("Honest reviews pass, including a neutral mention of a vape or liquor shop")
    func prefilterMisses() {
        for t in ["A vape shop is next door.", "There is a liquor store beside the petrol station", "Nasi lemak RM8, open 24 hours, parking for 30 cars",
                  "Great service!!!", "Waited 15 minutes for table 12", "Siap cantik, harga berpatutan. Saya pergi pukul 10.30 pagi", "", "Good food. Good price. Good staff. Good"] {
            #expect(!ReviewPrefilter.looksLikeAdvert(t), "\(t)")
        }
    }

    // MARK: 201 outcomes

    @Test("201 Review: passed, held and checking")
    func reviewOutcomes() throws {
        func review(_ extra: String) throws -> Review {
            try decode(Review.self, #"{"id":"r1","placeId":"p","rating":5,"text":"Nice","author":{"displayName":"Me"},"helpfulCount":0,"createdAt":"2026-10-25T02:00:00Z"\#(extra)}"#)
        }
        let passed = try review(#","moderation":{"state":"passed","reasons":["ok"],"canAppeal":false}"#)
        #expect(ReviewOutcome.of(passed) == .published && passed.moderation?.reasons == ["ok"])
        let held = try review(#","status":"hidden","heldForReview":true,"moderation":{"state":"held","reasons":["unclear"],"canAppeal":true}"#)
        #expect(ReviewOutcome.of(held) == .held && held.moderation?.canAppeal == true)
        #expect(ReviewOutcome.of(try review(#","status":"hidden","moderation":{"state":"checking"}"#)) == .checking)
        #expect(ReviewOutcome.of(try review(#","moderation":{"state":"skipped"}"#)) == .published)
        #expect(ReviewOutcome.of(try review("")) == .published, "an older server sends no moderation block")
        #expect(ReviewOutcome.of(try review(#","status":"hidden","heldForReview":true"#)) == .held)
        #expect(ReviewOutcome.of(try review(#","moderation":{"state":"pondering"}"#)) == .published, "unknown state reads as skipped")
    }

    // MARK: 422 / 403

    @Test("422 content_rejected: reasons become fixed codes, safeText is offered only when it differs")
    func rejected() {
        let original = "Great food. Call 012-345 6789 for a promo."
        let f = ContentFailure.classify(problem(422, code: "content_rejected", reasons: ["external_contact", "ok", "brand_promo"], safeText: "Great food."), original: original)
        #expect(f == .rejected(reasons: [.externalContact, .brandPromo], safeText: "Great food."))
        #expect(ContentFailure.classify(problem(422, code: "content_rejected", reasons: ["violence"]), original: original)
                == .rejected(reasons: [.violence], safeText: nil))
        #expect(ContentFailure.classify(problem(422, code: "content_rejected", reasons: ["spam"], safeText: "  "), original: original)
                == .rejected(reasons: [.spam], safeText: nil))
        #expect(ContentFailure.classify(problem(422, code: "content_rejected", reasons: ["spam"], safeText: original), original: original)
                == .rejected(reasons: [.spam], safeText: nil), "the same text is not 'the safe part'")
        // No usable reason → unclear.
        #expect(ContentFailure.classify(problem(422, code: "content_rejected", reasons: ["ok"]))
                == .rejected(reasons: [.unclear], safeText: nil))
        #expect(ContentFailure.isContentError(problem(422, code: "content_rejected")))
        #expect(!ContentFailure.isContentError(problem(422, code: "restricted_area")))
    }

    @Test("The real 422 body decodes into reasons and safeText")
    func rejectedBody() throws {
        let body = #"{"type":"about:blank","title":"Not accepted","status":422,"code":"content_rejected","reasons":["external_contact"],"safeText":"Lovely place."}"#
        let p = try JSONDecoder().decode(ProblemDetails.self, from: Data(body.utf8))
        #expect(ContentFailure.classify(APIError.http(status: 422, problem: p)) == .rejected(reasons: [.externalContact], safeText: "Lovely place."))
    }

    @Test("403 posting_paused → Paused with its time; other 403 → suspended; unreachable → offline")
    func paused() {
        let f = ContentFailure.classify(problem(403, code: "posting_paused", pausedUntil: "2026-10-26T08:00:00Z"))
        #expect(f == .paused(until: JSON.parseDate("2026-10-26T08:00:00Z")))
        #expect(ContentFailure.classify(APIError.http(status: 403, problem: nil)) == .suspended)
        #expect(ContentFailure.classify(APIError.transport(URLError(.notConnectedToInternet))) == .offline)
        #expect(ContentFailure.isContentError(problem(403, code: "posting_paused")))
        #expect(!ContentFailure.isContentError(APIError.http(status: 403, problem: nil)))

        let until = Date(timeIntervalSince1970: 1_000_000)
        #expect(PostingPause.isActive(until: until, now: until.addingTimeInterval(-1)))
        #expect(!PostingPause.isActive(until: until, now: until))
        #expect(!PostingPause.isActive(until: nil))
        #expect(PostingPause.hoursLeft(until: until, now: until.addingTimeInterval(-5400)) == 2)
        #expect(PostingPause.hoursLeft(until: until, now: until.addingTimeInterval(-10)) == 1)
        #expect(APIError.http(status: 403, problem: ProblemDetails(code: "posting_paused")).errorDescription?.isEmpty == false)
    }

    @Test("Review and photo appeals are signed requests")
    func appealsSigned() throws {
        #expect(SignedEndpoints.requiresSignature(method: "POST", path: "reviews/r1/appeal"))
        #expect(SignedEndpoints.requiresSignature(method: "POST", path: "photos/p1/appeal"))
        #expect(!SignedEndpoints.requiresSignature(method: "GET", path: "photos/p1"))
        let body = String(decoding: try JSON.makeEncoder().encode(AppealContentRequest(note: "It is my shop")), as: UTF8.self)
        #expect(body == #"{"note":"It is my shop"}"#)
    }

    // MARK: photos

    @Test("Photo badge: tick published, clock processing / checking / held, cross rejected")
    func photoBadges() throws {
        func photo(_ json: String) throws -> Photo { try decode(Photo.self, json) }
        #expect(PhotoBadge.of(try photo(#"{"id":"1","url":"/media/1.webp","status":"published"}"#)) == .published)
        #expect(PhotoBadge.of(try photo(#"{"id":"1","status":"processing"}"#)) == .checking)
        #expect(PhotoBadge.of(try photo(#"{"id":"1","status":"rejected"}"#)) == .rejected)
        #expect(PhotoBadge.of(try photo(#"{"id":"1","status":"processing","moderation":{"state":"held","reasons":["unclear"],"canAppeal":false}}"#)) == .checking)
        #expect(PhotoBadge.of(try photo(#"{"id":"1","url":"/m.webp","status":"published","moderation":{"state":"rejected","reasons":["violence"],"canAppeal":true}}"#)) == .rejected)
        #expect(PhotoBadge.of(try photo(#"{"id":"1","url":"/m.webp","status":"published","moderation":{"state":"passed","reasons":["ok"],"canAppeal":false}}"#)) == .published)
        #expect(PhotoBadge.published.isFinal && PhotoBadge.rejected.isFinal && !PhotoBadge.checking.isFinal)
    }

    private actor Counter { var n = 0; func next() -> Int { n += 1; return n } }

    @Test("Polling GET /photos/{id} stops at a final answer and keeps the upload's URLs")
    func photoPolling() async throws {
        let first = try decode(Photo.self, #"{"id":"p1","thumbUrl":"/t.webp","status":"processing"}"#)
        let counter = Counter()
        let done = await PhotoWatcher.watch(first, interval: .zero, maxTries: 10) { id in
            #expect(id == "p1")
            let n = await counter.next()
            return try self.decode(Photo.self, n < 3 ? #"{"id":"p1","status":"processing"}"# : #"{"id":"p1","url":"/f.webp","status":"published"}"#)
        }
        #expect(PhotoBadge.of(done) == .published)
        #expect(await counter.n == 3)
        #expect(done.thumbUrl == "/t.webp", "kept from the upload response")

        // A final photo is not polled at all; a stuck one gives up after maxTries.
        let calls = Counter()
        _ = await PhotoWatcher.watch(done, interval: .zero) { _ in _ = await calls.next(); return done }
        #expect(await calls.n == 0)
        let stuck = await PhotoWatcher.watch(first, interval: .zero, maxTries: 4) { _ in _ = await calls.next(); return first }
        #expect(PhotoBadge.of(stuck) == .checking)
        #expect(await calls.n == 4)
        // A failing poll doesn't crash or change the photo.
        let failed = await PhotoWatcher.watch(first, interval: .zero, maxTries: 2) { _ in throw URLError(.timedOut) }
        #expect(failed == first)
    }

    // MARK: report notes

    @Test("Report note: 140 characters; noteDropped is a one-line toast and the report is still live")
    func reportNote() throws {
        #expect(ReportNote.clamped(String(repeating: "a", count: 200)).count == 140)
        #expect(ReportNote.clamped("short") == "short")
        let p = LatLng(lat: 3.1, lng: 101.6)
        let long = String(repeating: "x", count: 300)
        #expect(QuickReportFan.newReport(.hazard, subtype: nil, comment: long, at: p, heading: nil).comment?.count == 140)
        #expect(QuickReportFan.newReport(.hazard, subtype: nil, comment: "", at: p, heading: nil).comment == nil)

        let dropped = try decode(Report.self, #"{"id":"r","type":"hazard","lat":1,"lng":2,"createdAt":"2026-10-25T02:00:00Z","expiresAt":"2026-10-25T03:00:00Z","confirmations":1,"thanks":0,"noteDropped":true,"noteReasons":["external_contact"]}"#)
        #expect(ReportNote.result(of: dropped) == .noteDropped && dropped.noteReasons == ["external_contact"])
        let plain = try decode(Report.self, #"{"id":"r","type":"hazard","lat":1,"lng":2,"createdAt":"2026-10-25T02:00:00Z","expiresAt":"2026-10-25T03:00:00Z","confirmations":1,"thanks":0}"#)
        #expect(ReportNote.result(of: plain) == .sent)
    }

    // MARK: inbox

    @Test("Inbox content_* kinds decode with their subject and reasons; rejected rows offer Edit and Appeal")
    func inbox() throws {
        let json = """
        {"items":[{"id":"1","kind":"content_published","title":"t","createdAt":"2026-10-25T02:00:00Z","subjectKind":"review","subjectId":"r1","placeId":"p1","reasons":["ok"]},
                  {"id":"2","kind":"content_held","title":"t","createdAt":"2026-10-25T02:00:00Z","subjectKind":"photo","subjectId":"f1","placeId":"p1","reasons":["unclear"]},
                  {"id":"3","kind":"content_rejected","title":"t","createdAt":"2026-10-25T02:00:00Z","subjectKind":"review","subjectId":"r2","placeId":"p1","reasons":["external_contact"],"canAppeal":true},
                  {"id":"4","kind":"content_rejected","title":"t","createdAt":"2026-10-25T02:00:00Z","subjectKind":"photo","subjectId":"f2","reasons":["violence"],"canAppeal":false},
                  {"id":"5","kind":"review_helpful","title":"t","createdAt":"2026-10-25T02:00:00Z"}]}
        """
        let items = try decode(InboxPage.self, json).items
        #expect(items.map(\.kind) == [.contentPublished, .contentHeld, .contentRejected, .contentRejected, .reviewHelpful])
        #expect(items[2].subjectKind == "review" && items[2].subjectId == "r2" && items[2].placeId == "p1" && items[2].reasons == ["external_contact"])
        let s = items.map(ContentInboxStatus.of)
        #expect(s[0] == .published && s[1] == .heldForPerson && s[2] == .rejected(canAppeal: true) && s[3] == .rejected(canAppeal: false) && s[4] == nil)
        #expect(s[2]!.canEdit && s[2]!.canAppeal && s[3]!.canEdit && !s[3]!.canAppeal)
        #expect(!s[0]!.canEdit && !s[1]!.canAppeal)
        #expect(Set([s[0]!, s[1]!, .checking, s[2]!].map(\.symbol)).count == 4, "tick, person, clock, cross")
        #expect(InboxKind.contentRejected.icon == .close)
    }

    // MARK: demo backend (offline)

    private func jpeg() -> Data {
        UIGraphicsImageRenderer(size: CGSize(width: 64, height: 64)).jpegData(withCompressionQuality: 0.8) { ctx in
            UIColor.blue.setFill(); ctx.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
        }
    }

    @Test("Demo: an advert review is 422 with reasons and the safe part; a neutral mention is accepted")
    func demoReviews() async throws {
        let repo = DemoRepository(latency: .zero)
        do {
            _ = try await repo.createReview(placeId: "demo-a", NewReview(rating: 5, text: "Lovely nasi lemak. Call 012-345 6789 for a free promo code!"))
            Issue.record("expected 422")
        } catch {
            guard case .rejected(let reasons, let safe) = ContentFailure.classify(error) else { Issue.record("not a rejection: \(error)"); return }
            #expect(reasons.contains(.externalContact))
            #expect(safe == "Lovely nasi lemak.")
        }
        let ok = try await repo.createReview(placeId: "demo-b", NewReview(rating: 4, text: "A vape shop is next door. Quiet place."))
        #expect(ReviewOutcome.of(ok) == .published)
        let held = try await repo.createReview(placeId: "demo-c", NewReview(rating: 3, text: "Hmm #held"))
        #expect(ReviewOutcome.of(held) == .held && held.heldForReview == true)
        let slow = try await repo.createReview(placeId: "demo-d", NewReview(rating: 3, text: "Okay #slow"))
        #expect(ReviewOutcome.of(slow) == .checking)
        await repo.finishContentChecksNow()
        let after = try await repo.reviews(placeId: "demo-d", sort: .recent, cursor: nil).reviews.first { $0.id == slow.id }
        #expect(after.map(ReviewOutcome.of) == .published)
        let inbox = try await repo.inbox(cursor: nil).items
        #expect(inbox.contains { $0.kind == .contentPublished && $0.subjectId == slow.id })

        // Appeal a held review once.
        try await repo.appealReview(id: held.id, note: "It is my own review", photos: [])
        let appealed = try await repo.reviews(placeId: "demo-c", sort: .recent, cursor: nil).reviews.first { $0.id == held.id }
        #expect(appealed?.moderation?.canAppeal == false)
    }

    @Test("Demo: three rejections in 24 hours pause posting (403 posting_paused)")
    func demoPause() async throws {
        let repo = DemoRepository(latency: .zero)
        for i in 1...3 {
            do { _ = try await repo.createReview(placeId: "demo-\(i)", NewReview(rating: 1, text: "visit www.bestdeal.com")) } catch {}
        }
        do {
            _ = try await repo.createReview(placeId: "demo-9", NewReview(rating: 5, text: "Fine place"))
            Issue.record("expected 403")
        } catch {
            guard case .paused(let until) = ContentFailure.classify(error) else { Issue.record("not paused: \(error)"); return }
            #expect(until != nil && PostingPause.isActive(until: until))
        }
    }

    @Test("Demo: a photo is checking, then published; a #reject photo ends rejected with a reason and can be appealed")
    func demoPhotos() async throws {
        let repo = DemoRepository(latency: .zero)
        let good = try await repo.uploadPhoto(jpeg(), placeId: "demo-p", caption: nil) { _ in }
        let bad = try await repo.uploadPhoto(jpeg(), placeId: "demo-p", caption: "#reject") { _ in }
        #expect(PhotoBadge.of(try await repo.photo(id: good.id)) == .checking)
        try await Task.sleep(for: .seconds(1.7))
        #expect(PhotoBadge.of(try await repo.photo(id: good.id)) == .published)
        let rejected = try await repo.photo(id: bad.id)
        #expect(PhotoBadge.of(rejected) == .rejected && rejected.moderation?.reasons == ["adult"] && rejected.moderation?.canAppeal == true)
        // Others never see it.
        #expect(try await repo.photos(placeId: "demo-p", cursor: nil).photos.map(\.id) == [good.id])
        #expect(try await repo.inbox(cursor: nil).items.contains { $0.kind == .contentRejected && $0.subjectId == bad.id && $0.canAppeal == true })

        try await repo.appealPhoto(id: bad.id, note: "not adult", photos: [])
        let after = try await repo.photo(id: bad.id)
        #expect(PhotoBadge.of(after) == .checking && after.moderation?.canAppeal != true)
        do { _ = try await repo.photo(id: "nope"); Issue.record("expected 404") } catch {}
    }

    @Test("Demo: report notes that look like adverts are dropped, the report still goes out; places get warnings")
    func demoReportsAndPlaces() async throws {
        let repo = DemoRepository(latency: .zero)
        let p = LatLng(lat: 3.1, lng: 101.6)
        let dropped = try await repo.createReport(NewReport(type: .hazard, subtype: nil, lat: p.lat, lng: p.lng, heading: nil, comment: "call 0123456789 now"))
        #expect(ReportNote.result(of: dropped) == .noteDropped)
        let kept = try await repo.createReport(NewReport(type: .hazard, subtype: nil, lat: p.lat, lng: p.lng, heading: nil, comment: "big pothole left lane"))
        #expect(ReportNote.result(of: kept) == .sent)

        #expect(DemoContentCheck.warnings(forPlaceNamed: "Kasino Genting") == ["gambling"])
        #expect(DemoContentCheck.warnings(forPlaceNamed: "Vape Corner") == ["tobacco"])
        #expect(DemoContentCheck.warnings(forPlaceNamed: "Nasi Lemak Wanjo") == nil)
        let created = try await repo.createPlace(NewPlace(name: "Kedai Bir Pak Ali", category: .other, lat: 3.2, lng: 101.7, warnings: ["alcohol"]))
        #expect(PlaceWarning.parse(created.warnings) == [.alcohol])
        #expect(PlaceWarning.parse(try await repo.place(id: created.id, near: nil).warnings) == [.alcohol])
    }
}
