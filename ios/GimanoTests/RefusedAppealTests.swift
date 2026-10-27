import Foundation
import GRDB
import Testing
@testable import Gimano

/// Refused content kept on the phone, the appeal screen's rules, `POST /appeals` pieces and the persisted posting pause.
@Suite("Refused content and appeals")
struct RefusedAppealTests {
    private func makeStore() throws -> LocalStore {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("refused-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return try LocalStore(path: dir.appendingPathComponent("db.sqlite").path, photosDirectory: dir.appendingPathComponent("photos"))
    }

    private func item(_ kind: RefusedKind = .review, text: String = "Call 0123456789", at: Date = .now) -> RefusedContent {
        RefusedContent(kind: kind, placeId: "osm:node:1", placeName: "Kedai Ali", text: text, reasons: ["external_contact", "spam"], createdAt: at)
    }

    // MARK: on-device store

    @Test("A refused item is saved, read back and its state moves none → sent → answered")
    func saveReadState() throws {
        let s = try makeStore()
        let saved = try s.saveRefused({ var i = item(); i.rating = 4; return i }())
        let back = try #require(try s.refusedItem(id: saved.id))
        #expect(back.text == "Call 0123456789" && back.kind == .review && back.placeName == "Kedai Ali" && back.placeId == "osm:node:1")
        #expect(back.reasons == ["external_contact", "spam"] && back.appealState == .none && back.rating == 4)
        try s.setRefusedState(id: saved.id, .sent)
        #expect(try s.refusedItem(id: saved.id)?.appealState == .sent)
        try s.setRefusedState(id: saved.id, .answered)
        #expect(try s.refusedItems().first?.appealState == .answered)
    }

    @Test("Newest first; the badge counts only items not yet appealed")
    func orderAndBadge() throws {
        let s = try makeStore()
        let old = try s.saveRefused(item(at: .now.addingTimeInterval(-3600)))
        let new = try s.saveRefused(item(.place))
        #expect(try s.refusedItems().map(\.id) == [new.id, old.id])
        try s.setRefusedState(id: old.id, .sent)
        #expect(RefusedRules.badge(try s.refusedItems()) == 1)
    }

    @Test("Refused photos are files under refused/<id>/ and go with the item; delete removes both")
    func photoFiles() throws {
        let s = try makeStore()
        let jpeg = Data([0xFF, 0xD8, 0xFF, 0xD9])
        let saved = try s.saveRefused(item(.photo, text: ""), photos: [jpeg, jpeg])
        #expect(saved.photoFiles.count == 2)
        let urls = saved.photoFiles.map { s.refusedFileURL(id: saved.id, $0) }
        #expect(urls.allSatisfy { FileManager.default.fileExists(atPath: $0.path) })
        #expect(urls[0].path.contains("/refused/\(saved.id)/"))
        #expect(s.refusedPhotoData(try #require(try s.refusedItem(id: saved.id))) == [jpeg, jpeg])
        try s.deleteRefused(id: saved.id)
        #expect(try s.refusedItems().isEmpty)
        #expect(urls.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) })
    }

    @Test("Items older than 30 days are deleted with their files; newer ones stay")
    func purge() throws {
        let s = try makeStore()
        let now = Date()
        let jpeg = Data([1, 2, 3])
        let stale = try s.saveRefused(item(.photo, at: now.addingTimeInterval(-31 * 86400)), photos: [jpeg])
        let fresh = try s.saveRefused(item(at: now.addingTimeInterval(-29 * 86400)))
        #expect(try s.purgeRefused(now: now) == 1)
        #expect(try s.refusedItems().map(\.id) == [fresh.id])
        #expect(!FileManager.default.fileExists(atPath: s.refusedFileURL(id: stale.id, stale.photoFiles[0]).path))
        #expect(RefusedRules.isExpired(now.addingTimeInterval(-31 * 86400), now: now))
        #expect(!RefusedRules.isExpired(now.addingTimeInterval(-29 * 86400), now: now))
        #expect(RefusedRules.daysLeft(now.addingTimeInterval(-29 * 86400), now: now) == 1)
        #expect(RefusedRules.daysLeft(now, now: now) == 30)
    }

    @Test("Refused content and device flags never go into a backup, and 'delete all my data' wipes them")
    func neverBackedUp() throws {
        let s = try makeStore()
        try s.saveRefused(item())
        s.setDeviceState("k", "v")
        let file = try BackupService(store: s, kdfLimits: .interactive).makeBackup()
        defer { try? FileManager.default.removeItem(at: file) }
        let dst = try makeStore()
        try BackupService(store: dst).restore(file, mode: .replace)
        #expect(try dst.refusedItems().isEmpty && dst.deviceState("k") == nil, "restored phone gets none of it")
        try s.wipePersonalData()
        #expect(try s.refusedItems().isEmpty && s.deviceState("k") == nil)
    }

    @Test("The device-local tables do not bump the shared schema version")
    func noSchemaBump() throws {
        let s = try makeStore()
        #expect(try s.dbQueue.read { try Int.fetchOne($0, sql: "PRAGMA user_version") } == 3)
        #expect(LocalStore.schemaVersion == 3)
    }

    // MARK: posting pause

    @Test("pausedUntil is kept across a restart and dropped once it has passed")
    func pausePersists() throws {
        let s = try makeStore()
        let now = Date()
        PostingPause.save(now.addingTimeInterval(3600), to: s, now: now)
        #expect(PostingPause.load(from: s, now: now.addingTimeInterval(10)) != nil)
        #expect(PostingPause.load(from: s, now: now.addingTimeInterval(7200)) == nil)
        #expect(s.deviceState(PostingPause.stateKey) == nil, "an expired pause is cleared")
        PostingPause.save(now.addingTimeInterval(-5), to: s, now: now)
        #expect(s.deviceState(PostingPause.stateKey) == nil)
    }

    @Test("The model restores the pause on launch and keeps refused items on the phone")
    @MainActor
    func modelRestores() throws {
        let s = try makeStore()
        let model = AppModel(store: s)
        let until = Date().addingTimeInterval(7200)
        model.pausePosting(until: until)
        let saved = try #require(model.recordRefusal(kind: .review, placeId: "p1", placeName: "Kedai", text: "visit www.x.com", reasons: [.externalContact]))
        #expect(model.refusedBadge == 1 && model.refusedItems.first?.id == saved.id)
        let again = AppModel(store: s)
        #expect(PostingPause.isActive(until: again.postingPausedUntil))
        #expect(again.refusedItems.map(\.id) == [saved.id])
        model.markRefused(id: saved.id, .sent)
        #expect(model.refusedBadge == 0)
        model.pausePosting(until: nil)
        #expect(model.postingPausedUntil.map { $0 > .now.addingTimeInterval(80000) } == true, "no server time: a day")
    }

    // MARK: appeal rules

    @Test("The note is required: 1…200 once trimmed; Send is off while sending")
    func note() {
        #expect(!AppealRules.isValidNote("") && !AppealRules.isValidNote("   \n "))
        #expect(AppealRules.isValidNote(" ok ") && AppealRules.isValidNote(String(repeating: "a", count: 200)))
        #expect(!AppealRules.isValidNote(String(repeating: "a", count: 201)))
        #expect(AppealRules.clamped(String(repeating: "b", count: 250)).count == 200)
        #expect(AppealRules.canSend(note: "why", sending: false) && !AppealRules.canSend(note: "why", sending: true) && !AppealRules.canSend(note: " ", sending: false))
    }

    @Test("At most 3 photos of 5 MB; the refused photo takes one slot")
    func photos() {
        #expect(AppealRules.evidenceSlots(refusedPhotos: 0) == 3 && AppealRules.evidenceSlots(refusedPhotos: 1) == 2 && AppealRules.evidenceSlots(refusedPhotos: 5) == 0)
        let big = Data(count: AppealRules.maxPhotoBytes + 1), ok = Data(count: 10)
        #expect(AppealRules.filesToSend([ok, big, ok, ok, ok]).count == 3)
        #expect(!AppealRules.filesToSend([big]).contains(big))
    }

    // MARK: POST /appeals

    @Test("Fields follow the contract: refusalId, kind, placeId, text ≤ 2000, repeated reasons, trimmed note")
    func fields() {
        let req = AppealRequest(refusalId: "r-1", kind: .review, placeId: "osm:node:9", text: String(repeating: "x", count: 2500),
                                reasons: ["spam", "external_contact"], note: "  It is my shop  ", photos: [], rating: 4)
        let f = req.fields
        #expect(f.map(\.name) == ["refusalId", "kind", "placeId", "text", "reasons", "reasons", "note", "rating"])
        #expect(f.first { $0.name == "text" }?.value.count == 2000)
        #expect(f.filter { $0.name == "reasons" }.map(\.value) == ["spam", "external_contact"])
        #expect(f.first { $0.name == "note" }?.value == "It is my shop" && f.first { $0.name == "kind" }?.value == "review")
        #expect(f.last?.value == "4", "stars ride along for a review")
        let noPlace = AppealRequest(refusalId: "r", kind: .photo, placeId: nil, text: "", reasons: [], note: "n", photos: [], rating: 4)
        #expect(!noPlace.fields.contains { $0.name == "placeId" || $0.name == "reasons" || $0.name == "rating" }, "no rating for a photo")
        let many = AppealRequest(refusalId: "r", kind: .review, placeId: "p", text: "", reasons: ["a", "b", "c", "d", "e"], note: "n", photos: [], rating: 9)
        #expect(many.fields.filter { $0.name == "reasons" }.count == 4 && !many.fields.contains { $0.name == "rating" }, "4 reasons at most; a bad rating is left out")
    }

    @Test("The multipart body has repeated fields, one part per photo and the closing boundary")
    func multipart() throws {
        let jpeg = Data([0xFF, 0xD8, 0x01, 0xFF, 0xD9])
        let body = MultipartForm.body(boundary: "B", fields: [("reasons", "spam"), ("reasons", "scam"), ("note", "why \"me\"")],
                                      files: [.init(field: "photos", fileName: "a.jpg", mimeType: "image/jpeg", data: jpeg),
                                              .init(field: "photos", fileName: "b.jpg", mimeType: "image/jpeg", data: jpeg)])
        let text = String(decoding: body, as: UTF8.self)
        #expect(text.components(separatedBy: "name=\"reasons\"").count == 3)
        #expect(text.components(separatedBy: "name=\"photos\"; filename=").count == 3)
        #expect(text.contains("Content-Type: image/jpeg") && text.hasSuffix("--B--\r\n"))
        #expect(body.range(of: jpeg) != nil)
        #expect(text.contains("name=\"note\"\r\n\r\nwhy \"me\"\r\n"), "values are sent as they are")
    }

    @Test("POST /appeals is a signed contribution endpoint")
    func signed() {
        #expect(SignedEndpoints.requiresSignature(method: "POST", path: "appeals"))
        #expect(SignedEndpoints.requiresSignature(method: "POST", path: "reviews/abc/appeal"))
        #expect(!SignedEndpoints.requiresSignature(method: "GET", path: "appeals"))
    }

    @Test("202 answer decodes")
    func created() throws {
        let a = try JSON.makeDecoder().decode(AppealCreated.self, from: Data(#"{"id":"a1","status":"pending"}"#.utf8))
        #expect(a == AppealCreated(id: "a1", status: "pending"))
    }

    // MARK: errors

    @Test("409, 400, 403, 413 and network errors read as their own icon-led message")
    func failures() {
        #expect(AppealFailure.classify(APIError.conflict(Data(#"{"code":"already_appealed"}"#.utf8))) == .alreadyAppealed)
        #expect(AppealFailure.classify(APIError.http(status: 409, problem: nil)) == .alreadyAppealed && AppealFailure.alreadyAppealed.countsAsSent)
        #expect(AppealFailure.classify(APIError.http(status: 400, problem: ProblemDetails(status: 400, code: "note_required"))) == .noteRequired)
        let until = Date().addingTimeInterval(3600)
        if case .paused(let u) = AppealFailure.classify(APIError.http(status: 403, problem: ProblemDetails(status: 403, code: "posting_paused", pausedUntil: JSON.makeISO(until)))) {
            #expect(u != nil)
        } else { Issue.record("expected paused") }
        #expect(AppealFailure.classify(APIError.http(status: 403, problem: ProblemDetails(status: 403, code: "banned"))) == .suspended)
        #expect(AppealFailure.classify(APIError.http(status: 413, problem: ProblemDetails(status: 413, code: "photo_too_large"))) == .tooBig)
        #expect(AppealFailure.classify(APIError.http(status: 429, problem: nil)) == .tooMany)
        #expect(AppealFailure.classify(URLError(.notConnectedToInternet)) == .offline)
        #expect(AppealFailure.classify(APIError.transport(URLError(.timedOut))) == .offline)
        let all: [AppealFailure] = [.alreadyAppealed, .noteRequired, .paused(until: nil), .suspended, .offline, .tooBig, .tooMany, .other("x")]
        #expect(Set(all.map(\.symbol)).count == all.count && all.allSatisfy { !$0.message.isEmpty })
    }

    // MARK: Inbox answer, review photos

    @Test("Inbox answers settle the matching sent items (denied/photo by refusalId, approved review by place)")
    func answers() throws {
        func inbox(_ kind: String, subject: String, subjectId: String, place: String?, at: String = "2026-10-27T02:00:00Z") -> String {
            #"{"id":"i-\#(subjectId)","kind":"\#(kind)","title":"t","createdAt":"\#(at)","subjectKind":"\#(subject)","subjectId":"\#(subjectId)""# + (place.map { #","placeId":"\#($0)""# } ?? "") + "}"
        }
        let created = LocalStore.date("2026-10-27T01:00:00Z")!
        var denied = RefusedContent(id: "r-denied", kind: .review, placeId: "p1", placeName: nil, reasons: [], createdAt: created, appealState: .sent)
        var approved = RefusedContent(id: "r-approved", kind: .review, placeId: "p2", placeName: nil, reasons: [], createdAt: created, appealState: .sent)
        let photo = RefusedContent(id: "ph-1", kind: .photo, placeId: nil, placeName: nil, reasons: [], createdAt: created, appealState: .sent)
        let notSent = RefusedContent(id: "r-none", kind: .review, placeId: "p2", placeName: nil, reasons: [], createdAt: created)
        let earlier = RefusedContent(id: "r-old", kind: .review, placeId: "p3", placeName: nil, reasons: [], createdAt: created.addingTimeInterval(86400), appealState: .sent)
        let json = "[" + [inbox("content_rejected", subject: "review", subjectId: "r-denied", place: "p1"),
                           inbox("content_published", subject: "review", subjectId: "new-review-id", place: "p2"),
                           inbox("content_published", subject: "photo", subjectId: "ph-1", place: nil),
                           inbox("content_published", subject: "review", subjectId: "other", place: "p3"),
                           inbox("content_held", subject: "review", subjectId: "r-none", place: "p2")].joined(separator: ",") + "]"
        let items = try JSON.makeDecoder().decode([InboxItem].self, from: Data(json.utf8))
        #expect(AppealAnswers.answered([denied, approved, photo, notSent, earlier], by: items) == ["r-denied", "r-approved", "ph-1"])
        denied.appealState = .answered; approved.appealState = .none
        #expect(AppealAnswers.answered([denied, approved], by: items).isEmpty, "only items still waiting are settled")
    }

    @Test("A review shows the badge grid when the server sent a moderation block on its photos")
    func reviewPhotos() throws {
        let mine = try JSON.makeDecoder().decode(Photo.self, from: Data(#"{"id":"p","url":"/m/p.webp","status":"published","moderation":{"state":"held","reasons":[],"canAppeal":false},"createdAt":"2026-10-27T01:00:00Z"}"#.utf8))
        let other = try JSON.makeDecoder().decode(Photo.self, from: Data(#"{"id":"q","url":"/m/q.webp","status":"published","createdAt":"2026-10-27T01:00:00Z"}"#.utf8))
        #expect(ReviewPhotoDisplay.usesBadgeGrid([other, mine]) && !ReviewPhotoDisplay.usesBadgeGrid([other]) && !ReviewPhotoDisplay.usesBadgeGrid(nil))
        #expect(PhotoBadge.of(mine) == .checking)
    }

    @Test("A refused item with no known reason is explained as unclear")
    func explained() {
        #expect(RefusedContent(kind: .photo, placeId: nil, placeName: nil, reasons: ["ok", "sensitive_alcohol"]).explained == [.unclear])
        #expect(RefusedContent(kind: .photo, placeId: nil, placeName: nil, reasons: ["adult"]).explained == [.adult])
    }

    // MARK: demo backend

    @Test("Demo POST /appeals: blank note is 400, the second appeal for one refusal is 409, then 202")
    func demoAppeal() async throws {
        let repo = DemoRepository(latency: .zero)
        let req = AppealRequest(refusalId: "r-9", kind: .review, placeId: "demo-a", text: "t", reasons: ["spam"], note: "my shop", photos: [], rating: 3)
        var blank = req; blank.note = "  "
        do { _ = try await repo.appeal(blank); Issue.record("expected 400") } catch let e as APIError {
            #expect(AppealFailure.classify(e) == .noteRequired)
        }
        #expect(try await repo.appeal(req).status == "pending")
        do { _ = try await repo.appeal(req); Issue.record("expected 409") } catch let e as APIError {
            #expect(AppealFailure.classify(e) == .alreadyAppealed)
        }
        do { try await repo.appealReview(id: "x", note: " ", photos: []); Issue.record("expected 400") } catch let e as APIError {
            #expect(AppealFailure.classify(e) == .noteRequired)
        }
    }
}
