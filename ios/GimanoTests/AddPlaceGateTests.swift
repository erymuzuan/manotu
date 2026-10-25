import Foundation
import Testing
@testable import Gimano

/// "Add a place with an AI gate" (docs/api.md "AI check", boards A1–C3): which screen and copy each answer gets.
@Suite("Add a place: AI gate")
struct AddPlaceGateTests {
    private func screening(_ state: ScreeningState, _ reasons: [String] = [], canAppeal: Bool = false, appealed: Bool = false) -> PlaceScreening {
        PlaceScreening(state: state, reasons: reasons, canAppeal: canAppeal, appealed: appealed)
    }

    // MARK: screening → screen

    @Test("Passed: A4 live while pending, A5 when an Emas place is published at once")
    func passed() {
        #expect(AddPlaceOutcome.of(status: .pending, screening: screening(.passed, ["ok"]), heldForReview: false) == .live)
        #expect(AddPlaceOutcome.of(status: .published, screening: screening(.passed, ["ok"]), heldForReview: false) == .published)
    }

    @Test("Held: B2 with the reason that explains it")
    func held() {
        #expect(AddPlaceOutcome.of(status: .hidden, screening: screening(.held, ["security"]), heldForReview: true) == .held(.security))
        #expect(AddPlaceOutcome.of(status: .hidden, screening: screening(.held, []), heldForReview: true) == .held(.unclear))
    }

    @Test("Rejected: B3 for adverts, scams, illegal goods, adult services and gibberish; B4 for homes and people")
    func rejected() {
        for code in ["spam", "scam", "illegal", "adult", "gibberish"] {
            let r = ScreeningReason(rawValue: code)!
            #expect(AddPlaceOutcome.of(status: .rejected, screening: screening(.rejected, [code]), heldForReview: false) == .notAccepted(r), "\(code)")
        }
        #expect(AddPlaceOutcome.of(status: .rejected, screening: screening(.rejected, ["private_home"]), heldForReview: false) == .aboutPeople(.privateHome))
        #expect(AddPlaceOutcome.of(status: .rejected, screening: screening(.rejected, ["harassment"]), heldForReview: false) == .aboutPeople(.harassment))
        // A home among other codes still offers "Keep it just for me".
        #expect(AddPlaceOutcome.of(status: .rejected, screening: screening(.rejected, ["spam", "private_home"]), heldForReview: false) == .aboutPeople(.privateHome))
        // The most serious reason is explained first; unknown codes read as "unclear".
        #expect(AddPlaceOutcome.of(status: .rejected, screening: screening(.rejected, ["spam", "scam"]), heldForReview: false) == .notAccepted(.scam))
        #expect(AddPlaceOutcome.of(status: .rejected, screening: screening(.rejected, ["new_code_from_2027"]), heldForReview: false) == .notAccepted(.unclear))
        #expect(AddPlaceOutcome.notAccepted(.spam).isNotAccepted && AddPlaceOutcome.aboutPeople(.privateHome).isNotAccepted)
        #expect(!AddPlaceOutcome.live.isNotAccepted && !AddPlaceOutcome.held(.security).isNotAccepted)
    }

    @Test("Checking: B6 slow; none / skipped / no screening: the flow as before the gate")
    func checkingAndUnscreened() {
        #expect(AddPlaceOutcome.of(status: .pending, screening: screening(.checking), heldForReview: false) == .checking)
        #expect(AddPlaceOutcome.of(status: .pending, screening: screening(.skipped), heldForReview: false) == .unscreened(held: false))
        #expect(AddPlaceOutcome.of(status: .hidden, screening: screening(.none), heldForReview: true) == .unscreened(held: true))
        #expect(AddPlaceOutcome.of(status: .pending, screening: nil, heldForReview: false) == .unscreened(held: false))
        #expect(AddPlaceOutcome.of(status: .hidden, screening: nil, heldForReview: false) == .unscreened(held: true))
    }

    @Test("Every reason has its own fixed app copy (the model's text is never shown)")
    func copy() {
        let reasons = ScreeningReason.allCases.filter { $0 != .ok }
        let titles = reasons.map { String(localized: ScreeningCopy.notAcceptedTitle($0)) }
        #expect(Set(titles).count == reasons.count, "one title per reason")
        for r in ScreeningReason.allCases {
            #expect(!String(localized: ScreeningCopy.notAcceptedBody(r)).isEmpty)
            #expect(!String(localized: ScreeningCopy.notAcceptedTip(r)).isEmpty)
            #expect(!String(localized: ScreeningCopy.heldWhy(r)).isEmpty)
        }
        #expect(ScreeningReason.primary(["SPAM"]) == .spam, "codes are matched case-insensitively")
    }

    // MARK: contract JSON

    @Test("The owner's Place decodes screening and the rejected status; NewPlace sends notDuplicateOf only when set")
    func contract() throws {
        let json = #"""
        {"id":"c1","name":"BEST FOREX SIGNAL","category":"other","address":"","lat":3.1,"lng":101.6,"source":"community",
         "status":"rejected","heldForReview":false,
         "screening":{"state":"rejected","reasons":["spam"],"canAppeal":true,"appealed":false}}
        """#
        let p = try JSON.makeDecoder().decode(Place.self, from: Data(json.utf8))
        #expect(p.status == .rejected)
        #expect(p.screening == PlaceScreening(state: .rejected, reasons: ["spam"], canAppeal: true, appealed: false))
        #expect(p.summary.screening?.canAppeal == true)
        #expect(AddPlaceOutcome.of(p) == .notAccepted(.spam))

        // Unknown state → none; missing fields default.
        let s = try JSONDecoder().decode(PlaceScreening.self, from: Data(#"{"state":"pondering"}"#.utf8))
        #expect(s.state == .none && s.reasons.isEmpty && !s.canAppeal && !s.appealed)

        let enc = JSON.makeEncoder()
        let plain = String(decoding: try enc.encode(NewPlace(name: "A", category: .cafe, lat: 1, lng: 2)), as: UTF8.self)
        #expect(!plain.contains("notDuplicateOf"))
        let different = String(decoding: try enc.encode(NewPlace(name: "A", category: .cafe, lat: 1, lng: 2, notDuplicateOf: "osm-n-9")), as: UTF8.self)
        #expect(different.contains("\"notDuplicateOf\":\"osm-n-9\""))

        #expect(SignedEndpoints.requiresSignature(method: "POST", path: "places/c1/appeal"))
        let appeal = String(decoding: try enc.encode(AppealPlaceRequest(note: "Kuih every morning")), as: UTF8.self)
        #expect(appeal == #"{"note":"Kuih every morning"}"#)
    }

    @Test("Inbox kinds place_held, place_not_accepted, place_live decode; held and not accepted open My contributions")
    func inboxKinds() throws {
        let json = """
        {"items":[{"id":"1","kind":"place_held","title":"t","createdAt":"2026-10-25T02:00:00Z","refType":"place","refId":"c1"},
                  {"id":"2","kind":"place_not_accepted","title":"t","createdAt":"2026-10-25T02:00:00Z","refType":"place","refId":"c2"},
                  {"id":"3","kind":"place_live","title":"t","createdAt":"2026-10-25T02:00:00Z","refType":"place","refId":"c3"}]}
        """
        let page = try JSON.makeDecoder().decode(InboxPage.self, from: Data(json.utf8))
        #expect(page.items.map(\.kind) == [.placeHeld, .placeNotAccepted, .placeLive])
        #expect(InboxKind.placeHeld.opensContributions && InboxKind.placeNotAccepted.opensContributions)
        #expect(!InboxKind.placeLive.opensContributions)
    }

    // MARK: error bodies → B1 / B5 / paused

    @Test("409 with existing → B1; 409 without a place → a plain conflict")
    func duplicate() throws {
        let body = #"{"status":409,"title":"Similar place nearby","detail":"…","existing":{"id":"osm-n-1","name":"99 Speedmart Seksyen 9","category":"convenience","address":"Bangi","lat":2.96,"lng":101.78,"status":"published","source":"osm"}}"#
        guard case .duplicate(let e) = AddPlaceFailure.classify(APIError.conflict(Data(body.utf8))) else {
            Issue.record("expected B1"); return
        }
        #expect(e.id == "osm-n-1" && e.category == .convenience)
        #expect(AddPlaceFailure.classify(APIError.conflict(Data(#"{"title":"Conflict"}"#.utf8))) == .conflict)
    }

    @Test("429 → B5 with whole minutes from retryAfterSeconds; 403 adding_paused → paused with its time; other 403 → suspended")
    func limits() throws {
        func http(_ status: Int, _ p: ProblemDetails?) -> APIError { .http(status: status, problem: p) }
        #expect(AddPlaceFailure.classify(http(429, ProblemDetails(status: 429, retryAfterSeconds: 2400))) == .limit(minutes: 40))
        #expect(AddPlaceFailure.classify(http(429, ProblemDetails(status: 429, retryAfterSeconds: 61))) == .limit(minutes: 2))
        #expect(AddPlaceFailure.classify(http(429, ProblemDetails(status: 429, retryAfterSeconds: 5))) == .limit(minutes: 1))
        #expect(AddPlaceFailure.classify(http(429, nil)) == .limit(minutes: nil))

        // The backend's body, as ApiExceptionHandler writes it.
        let paused = #"{"type":"https://tools.ietf.org/html/rfc9110#section-15.5.4","title":"Adding paused","status":403,"detail":"x","code":"adding_paused","pausedUntil":"2026-10-26T13:40:00+00:00"}"#
        let p = try JSON.makeDecoder().decode(ProblemDetails.self, from: Data(paused.utf8))
        let until = try #require(JSON.parseDate("2026-10-26T13:40:00+00:00"))
        #expect(AddPlaceFailure.classify(http(403, p)) == .paused(until: until))
        #expect(AddPlaceFailure.classify(http(403, ProblemDetails(status: 403, code: "adding_paused"))) == .paused(until: nil))
        #expect(AddPlaceFailure.classify(http(403, ProblemDetails(title: "Forbidden", status: 403))) == .suspended)

        let tooMany = #"{"title":"Too many requests","status":429,"detail":"x","retryAfterSeconds":2400}"#
        #expect(try JSON.makeDecoder().decode(ProblemDetails.self, from: Data(tooMany.utf8)).retryAfterSeconds == 2400)
        #expect(ProblemDetails.retryAfter(header: " 120 ") == 120 && ProblemDetails.retryAfter(header: "Wed, 21 Oct 2026 07:28:00 GMT") == nil)

        let now = Date(timeIntervalSince1970: 1_800_000_000)
        #expect(AddPlaceFailure.limit(minutes: 40).shareAfter(now: now) == now.addingTimeInterval(2400))
        #expect(AddPlaceFailure.paused(until: until).shareAfter(now: now) == until)
    }

    @Test("Offline → B6 queue; restricted area → A; a missing endpoint → not available yet")
    func otherFailures() {
        #expect(AddPlaceFailure.classify(APIError.transport(URLError(.notConnectedToInternet))) == .offline)
        #expect(AddPlaceFailure.classify(URLError(.timedOut)) == .offline)
        #expect(AddPlaceFailure.classify(APIError.http(status: 422, problem: ProblemDetails(status: 422, code: "restricted_area"))) == .restricted)
        #expect(AddPlaceFailure.classify(APIError.http(status: 404, problem: nil)) == .unavailable)
        if case .other = AddPlaceFailure.classify(APIError.http(status: 400, problem: ProblemDetails(title: "Bad", status: 400, detail: "Name too long"))) {} else {
            Issue.record("400 is shown as is")
        }
    }

    // MARK: C3 statuses

    @Test("My places: one status for every state")
    func myPlaces() {
        func s(_ status: PlaceStatus?, _ scr: PlaceScreening?, held: Bool = false, c: Double? = nil, r: Double? = nil) -> MyPlaceStatus {
            var p = PlaceSummary(id: "c", name: "n", category: .cafe, address: "", lat: 0, lng: 0, source: .community, status: status)
            p.screening = scr; p.heldForReview = held; p.confirmationsWeighted = c; p.required = r
            return MyPlaceStatus.of(p)
        }
        #expect(s(.published, screening(.passed)) == .communityVerified)
        #expect(s(.pending, screening(.passed), c: 0, r: 1) == .live(confirmed: 0, required: 1))
        #expect(s(.pending, screening(.skipped), c: 1.5, r: 3) == .waiting(confirmed: 1, required: 3))
        #expect(s(.pending, nil) == .waiting(confirmed: 0, required: nil))
        #expect(s(.pending, screening(.checking)) == .beingChecked)
        #expect(s(.hidden, screening(.held, ["security"]), held: true) == .beingCheckedByPerson)
        #expect(s(.hidden, screening(.held, [], appealed: true)) == .beingCheckedByPerson, "an appealed place waits for a person")
        #expect(s(.pending, nil, held: true) == .beingCheckedByPerson, "restricted-area holds")
        #expect(s(.rejected, screening(.rejected, ["spam"], canAppeal: true)) == .notAccepted(canAppeal: true, appealed: false))
        #expect(s(.rejected, screening(.rejected, ["spam"], appealed: true)) == .notAccepted(canAppeal: false, appealed: true))
        #expect(s(.hidden, screening(.passed)) == .hidden, "hidden after reports")
        #expect(s(.closed, nil) == .closed && s(.expired, nil) == .expired)
        #expect(MyPlaceStatus.notAccepted(canAppeal: true, appealed: false).opensOutcome && !MyPlaceStatus.live(confirmed: 0, required: 1).opensOutcome)
        let draft = PlaceDraft(place: NewPlace(name: "d", category: .surau, lat: 0, lng: 0), state: .draft, shareAfter: nil)
        #expect(draft.status == .draft(shareAfter: nil))
        #expect(PlaceDraft(place: draft.place, state: .queued).status == .queued)
    }

    @Test("A1 is shown once, only before the first shared place and never for Just for me")
    func intro() {
        #expect(AddPlaceIntro.shouldShow(seen: false, sharedBefore: false, privateOnly: false))
        #expect(!AddPlaceIntro.shouldShow(seen: true, sharedBefore: false, privateOnly: false))
        #expect(!AddPlaceIntro.shouldShow(seen: false, sharedBefore: true, privateOnly: false))
        #expect(!AddPlaceIntro.shouldShow(seen: false, sharedBefore: false, privateOnly: true))
    }

    // MARK: drafts and the offline queue

    @Test("Offline queue: sent → removed; offline → retried later; a limit → kept as a draft with its time")
    @MainActor
    func outbox() async {
        let box = PlaceOutbox(storage: MemoryPlaceDraftStorage())
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        box.save(NewPlace(name: "Offline", category: .cafe, lat: 3, lng: 101), state: .queued)
        await box.flush(now: now) { _ in throw APIError.transport(URLError(.notConnectedToInternet)) }
        #expect(box.items.first?.state == .queued && box.items.first!.nextAttemptAt > now)
        // Not due yet: not sent.
        var calls = 0
        await box.flush(now: now) { _ in calls += 1; throw APIError.transport(URLError(.notConnectedToInternet)) }
        #expect(calls == 0)
        let later = now.addingTimeInterval(3600)
        await box.flush(now: later) { _ in throw APIError.http(status: 429, problem: ProblemDetails(status: 429, retryAfterSeconds: 600)) }
        #expect(box.items.first?.state == .draft && box.items.first?.shareAfter == later.addingTimeInterval(600))
        // A draft is never sent by itself.
        await box.flush(now: later.addingTimeInterval(7200)) { _ in calls += 1; throw APIError.notAvailable }
        #expect(calls == 0)
        let id = box.items[0].id
        box.save(box.items[0].place, state: .queued, replacing: id)
        #expect(box.items.count == 1 && box.items[0].id == id)
        let sent = await box.flush(now: later.addingTimeInterval(7200)) { n in
            Place(id: "c9", name: n.name, category: n.category, address: "", lat: n.lat, lng: n.lng)
        }
        #expect(sent.map(\.id) == ["c9"] && box.items.isEmpty)
    }

    // MARK: demo backend (offline stand-in for the check)

    @Test("Demo check: keywords reach every outcome (never calls a model)")
    func demoVerdicts() {
        func v(_ name: String, _ d: String? = nil, emas: Bool = false) -> DemoScreening.Verdict { DemoScreening.verdict(name: name, description: d, emas: emas) }
        #expect(v("Gerai Nasi Kerabu Mek Na").state == .passed)
        #expect(v("BEST FOREX SIGNAL 100% UNTUNG") == .init(state: .rejected, reasons: ["spam"]))
        #expect(v("Skim pelaburan emas").reasons == ["scam"])
        #expect(v("Jual pil kurus & ubat kuat").reasons == ["illegal"])
        #expect(v("Rumah Mak Teh").reasons == ["private_home"])
        #expect(v("asdfgh").reasons == ["gibberish"])
        #expect(v("Parkir IPD", "CCTV and guard times at the back") == .init(state: .held, reasons: ["security"]))
        #expect(v("Gerai #slow").state == .checking)
        #expect(v("Bengkel Ah Seng #emas").emas && v("Bengkel Ah Seng", emas: true).emas)
    }

    @Test("Demo: rejected → appeal once → held for a person; Inbox notes; 3 rejections pause adding")
    func demoRejectAppealPause() async throws {
        let repo = DemoRepository(latency: .zero)
        let ad = try await repo.createPlace(NewPlace(name: "BEST FOREX SIGNAL", category: .other, lat: 3.10, lng: 101.60))
        #expect(ad.status == .rejected && AddPlaceOutcome.of(ad) == .notAccepted(.spam) && ad.screening?.canAppeal == true)
        let appealed = try await repo.appealPlace(id: ad.id, note: "A real office")
        #expect(appealed.status == .hidden && appealed.screening?.appealed == true && appealed.screening?.canAppeal == false)
        #expect(MyPlaceStatus.of(appealed.summary) == .beingCheckedByPerson)
        await #expect(throws: APIError.self) { try await repo.appealPlace(id: ad.id, note: nil) }

        let home = try await repo.createPlace(NewPlace(name: "Rumah Mak Teh", category: .other, lat: 3.20, lng: 101.50))
        #expect(AddPlaceOutcome.of(home) == .aboutPeople(.privateHome))
        _ = try await repo.createPlace(NewPlace(name: "Jual pil kurus", category: .other, lat: 3.30, lng: 101.40))
        let inbox = try await repo.inbox(cursor: nil).items
        #expect(inbox.filter { $0.kind == .placeNotAccepted }.count == 3)
        do {
            _ = try await repo.createPlace(NewPlace(name: "Kedai Runcit Ali", category: .convenience, lat: 3.40, lng: 101.30))
            Issue.record("expected adding_paused")
        } catch {
            guard case .paused(let until?) = AddPlaceFailure.classify(error) else { Issue.record("expected paused, got \(error)"); return }
            #expect(until > .now.addingTimeInterval(86000))
        }
    }

    @Test("Demo: B1 → notDuplicateOf lets it through; #slow → checking, then live with a place_live note; held → place_held")
    func demoDuplicateSlowHeld() async throws {
        let repo = DemoRepository(latency: .zero)
        let first = try await repo.createPlace(NewPlace(name: "Kedai Runcit Pak Mat", category: .convenience, lat: 3.16, lng: 101.70))
        #expect(AddPlaceOutcome.of(first) == .live && first.screening?.state == .passed)
        var existingId: String?
        do {
            _ = try await repo.createPlace(NewPlace(name: "kedai runcit pak mat", category: .convenience, lat: 3.1601, lng: 101.7001))
        } catch {
            if case .duplicate(let e) = AddPlaceFailure.classify(error) { existingId = e.id; #expect(e.distanceM != nil) }
        }
        #expect(existingId == first.id)
        let second = try await repo.createPlace(NewPlace(name: "kedai runcit pak mat", category: .convenience, lat: 3.1601, lng: 101.7001,
                                                         notDuplicateOf: existingId))
        #expect(second.id != first.id)

        let slow = try await repo.createPlace(NewPlace(name: "Gerai #slow", category: .restaurant, lat: 3.0, lng: 101.0))
        #expect(AddPlaceOutcome.of(slow) == .checking)
        #expect(try await repo.pendingNearby(cell: Geohash.encode(lat: 3.0, lng: 101.0)).allSatisfy { $0.id != slow.id })
        await repo.finishChecksNow()
        #expect(try await repo.place(id: slow.id, near: nil).screening?.state == .passed)
        #expect(try await repo.inbox(cursor: nil).items.contains { $0.kind == .placeLive && $0.refId == slow.id })

        // 3 an hour: the 4th is a B5 limit with the minutes to wait.
        do {
            _ = try await repo.createPlace(NewPlace(name: "Parkir CCTV", category: .parking, lat: 2.9, lng: 101.1))
            Issue.record("expected the hourly limit")
        } catch {
            guard case .limit(let m?) = AddPlaceFailure.classify(error) else { Issue.record("expected 429"); return }
            #expect(m > 0 && m <= 60)
        }
        let other = DemoRepository(latency: .zero)
        let held = try await other.createPlace(NewPlace(name: "Parkir IPD", category: .parking, lat: 2.9, lng: 101.1, description: "Guard at the back gate"))
        #expect(AddPlaceOutcome.of(held) == .held(.security) && held.heldForReview == true)
        #expect(try await other.inbox(cursor: nil).items.contains { $0.kind == .placeHeld && $0.refId == held.id })
    }
}
