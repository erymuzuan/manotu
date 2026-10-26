import Foundation
import Observation

// "Add a place with an AI gate" (docs/api.md "AI check"; design boards A1–C3). Pure logic: what to show for the
// owner's `Place` after POST/PATCH, how error bodies map to screens, and the statuses in "My places".
// Reason codes always map to fixed app copy; the server's (or the model's) text is never shown for a reason.

/// One fixed reason code from `screening.reasons`. Unknown codes read as `unclear`.
enum ScreeningReason: String, CaseIterable, Sendable {
    case spam, scam, gibberish, harassment, adult, illegal, duplicate, security, unclear, ok
    case privateHome = "private_home"
    case wrongCategory = "wrong_category"

    static func parse(_ codes: [String]) -> [ScreeningReason] {
        codes.map { ScreeningReason(rawValue: $0.lowercased()) ?? alias($0.lowercased()) ?? .unclear }
    }

    /// The public-content-safety codes (docs/content-safety.md) that can also come back on a place, shown with the
    /// closest existing copy. Warning-only `sensitive_*` codes are not a rejection (`ok`).
    static func alias(_ code: String) -> ScreeningReason? {
        switch code {
        case "violence", "drugs", "counterfeit": .illegal
        case "personal_data": .privateHome
        case "gambling_promo", "alcohol_promo", "tobacco_promo", "brand_promo", "external_contact", "medical_claims": .spam
        case "high_risk_investment", "loan_shark", "mlm": .scam
        case "sensitive_alcohol", "sensitive_gambling", "sensitive_tobacco": .ok
        default: nil
        }
    }

    /// B4 ("someone's home"): offered "Keep it just for me" and "It's a business: ask for a review".
    var isAboutPeople: Bool { self == .privateHome || self == .harassment }

    /// Which reason the screen explains when several came back: people first, then the most serious.
    static let precedence: [ScreeningReason] = [.privateHome, .harassment, .scam, .illegal, .adult, .spam, .gibberish,
                                                .security, .duplicate, .wrongCategory, .unclear]

    static func primary(_ codes: [String]) -> ScreeningReason {
        let parsed = Set(parse(codes))
        return precedence.first { parsed.contains($0) } ?? .unclear
    }
}

/// What the app shows once `POST /places` (or an edit) answered.
enum AddPlaceOutcome: Equatable, Sendable {
    /// A4 "It's on the map" (pending, listed, "Not verified yet").
    case live
    /// A5 Emas: published at once.
    case published
    /// B2 "A person will check this one".
    case held(ScreeningReason)
    /// B3 not accepted: spam, scam, illegal, adult, gibberish (and any other code).
    case notAccepted(ScreeningReason)
    /// B4 not accepted: `private_home` / `harassment`.
    case aboutPeople(ScreeningReason)
    /// B6 "Sent. We're still checking" (no answer within 4 s; the result comes to the Inbox).
    case checking
    /// The check didn't run (off, over budget, older places): as before the gate. `held` = waiting for a moderator.
    case unscreened(held: Bool)

    static func of(_ place: Place) -> AddPlaceOutcome {
        of(status: place.status, screening: place.screening, heldForReview: place.heldForReview == true)
    }

    static func of(status: PlaceStatus?, screening: PlaceScreening?, heldForReview: Bool) -> AddPlaceOutcome {
        guard let screening else { return .unscreened(held: heldForReview || status == .hidden) }
        switch screening.state {
        case .passed:
            return status == .published ? .published : .live
        case .held:
            return .held(ScreeningReason.primary(screening.reasons))
        case .rejected:
            let reason = ScreeningReason.primary(screening.reasons)
            return reason.isAboutPeople ? .aboutPeople(reason) : .notAccepted(reason)
        case .checking:
            return .checking
        case .none, .skipped:
            // A rejected status without a "rejected" screening shouldn't happen; treat it as not accepted.
            if status == .rejected { return .notAccepted(ScreeningReason.primary(screening.reasons)) }
            return .unscreened(held: heldForReview || status == .hidden)
        }
    }

    /// B3/B4 can be appealed once; the button shows only when the server says so.
    var isNotAccepted: Bool {
        switch self {
        case .notAccepted, .aboutPeople: true
        default: false
        }
    }
}

/// Fixed copy per reason (B2 "Why", B3/B4 titles and bodies).
enum ScreeningCopy {
    /// B3/B4 title.
    static func notAcceptedTitle(_ r: ScreeningReason) -> String.LocalizationValue {
        switch r {
        case .spam: "This looks like an advert, not a place"
        case .scam: "This looks like a scam, not a place"
        case .illegal: "This looks like a sale of illegal goods"
        case .adult: "This looks like an adult service"
        case .gibberish: "We couldn't read this as a place"
        case .privateHome: "This looks like someone's home"
        case .harassment: "This looks like it's about a person"
        case .duplicate: "This looks like a place already on the map"
        case .security: "This mentions security details"
        case .wrongCategory: "The type doesn't match the place"
        case .unclear, .ok: "We couldn't tell what this place is"
        }
    }

    /// B3/B4 body (what we don't accept, and that nobody else saw it).
    static func notAcceptedBody(_ r: ScreeningReason) -> String.LocalizationValue {
        switch r {
        case .spam:
            "Manotu places are locations drivers can visit. We don't accept adverts, investment offers, job offers or promotions. It was not published, and nobody else saw it."
        case .scam:
            "We don't accept get-rich offers, investment schemes or requests for money. It was not published, and nobody else saw it."
        case .illegal:
            "We don't accept places that sell illegal goods or services. It was not published, and nobody else saw it."
        case .adult:
            "We don't accept adult services. It was not published, and nobody else saw it."
        case .gibberish:
            "The name or description doesn't read like a real place. It was not published, and nobody else saw it."
        case .privateHome:
            "To protect people's privacy, we don't publish private homes for everyone. You can still keep it on the map for yourself. A \"Just for me\" place stays on this phone and in your own backup, and never reaches Manotu."
        case .harassment:
            "We don't publish places that name or point at a private person. You can still keep it on the map for yourself. A \"Just for me\" place stays on this phone and in your own backup, and never reaches Manotu."
        case .duplicate:
            "A very similar place is already on the map here. It was not published, and nobody else saw it."
        case .security:
            "We never publish security details such as guards, cameras or back entrances. It was not published, and nobody else saw it."
        case .wrongCategory:
            "The type you chose doesn't fit the name and description. It was not published, and nobody else saw it."
        case .unclear, .ok:
            "The check couldn't tell what drivers would find here. It was not published, and nobody else saw it."
        }
    }

    /// B3 tip / B4 footnote.
    static func notAcceptedTip(_ r: ScreeningReason) -> String.LocalizationValue {
        switch r {
        case .privateHome, .harassment:
            "Home businesses (kuih, tailors, homestays) are welcome. Name the business, not the person, and add opening hours."
        case .wrongCategory:
            "Pick the type that matches what drivers will find, then try again."
        case .security:
            "Remove the sentence about guards, cameras or entrances, then try again."
        default:
            "Is there a real shop or office here? Edit the name to what's on the signboard and describe the place, not the offer."
        }
    }

    /// B2 "Why: …".
    static func heldWhy(_ r: ScreeningReason) -> String.LocalizationValue {
        switch r {
        case .security:
            "The description mentions security details (cameras, guard times). We never publish those, but the place itself may be fine. A maintainer may remove that sentence and publish the rest."
        case .duplicate:
            "It may be the same as a place already on the map. A maintainer will compare them."
        case .privateHome, .harassment:
            "It may be someone's home or about a person. A maintainer will check before anyone else sees it."
        case .wrongCategory:
            "The type may not match the place. A maintainer may correct it and publish it."
        default:
            "The automatic check wasn't sure about this one, so a person decides."
        }
    }
}

// MARK: - Error bodies → B1 / B5 / paused / offline

enum AddPlaceFailure: Equatable, Sendable {
    /// B1: 409 with the similar place.
    case duplicate(PlaceSummary)
    /// 409 without a usable body.
    case conflict
    /// B5: 429; minutes until the limit lifts (nil when the server didn't say).
    case limit(minutes: Int?)
    /// B5 paused variant: 403 `adding_paused`.
    case paused(until: Date?)
    /// 403 for any other reason (suspended by a moderator).
    case suspended
    /// 422 `restricted_area`.
    case restricted
    /// B6 offline: the server couldn't be reached.
    case offline
    /// Endpoint missing (old server).
    case unavailable
    case other(String)

    static func classify(_ error: any Error) -> AddPlaceFailure {
        guard let e = error as? APIError else {
            if let u = error as? URLError { return classify(APIError.transport(u)) }
            return .other(error.localizedDescription)
        }
        if case .conflict(let body) = e {
            return DuplicatePlace.existing(in: body).map(AddPlaceFailure.duplicate) ?? .conflict
        }
        if e.isUnreachable { return .offline }
        if case .http(let status, let p) = e {
            switch status {
            case 429: return .limit(minutes: p?.retryAfterSeconds.map(minutes(fromSeconds:)))
            case 403 where p?.code == "adding_paused": return .paused(until: p?.pausedUntil.flatMap(JSON.parseDate))
            case 403: return .suspended
            case 422 where p?.code == "restricted_area": return .restricted
            default: break
            }
        }
        if e.isServerSideGap { return .unavailable }
        return .other(e.localizedDescription)
    }

    /// Whole minutes, rounded up, at least 1 ("You can add more in 40 minutes").
    static func minutes(fromSeconds s: Int) -> Int { max(1, Int((Double(s) / 60).rounded(.up))) }

    /// When a draft saved because of this failure can be shared again.
    func shareAfter(now: Date = .now) -> Date? {
        switch self {
        case .limit(let m): now.addingTimeInterval(TimeInterval((m ?? 60) * 60))
        case .paused(let until): until
        default: nil
        }
    }
}

// MARK: - "My places" statuses (C3)

enum MyPlaceStatus: Equatable, Sendable {
    case communityVerified
    /// Passed the check, listed, waiting for people nearby ("Live · not verified yet", "x of y").
    case live(confirmed: Int, required: Int?)
    /// Not checked by the AI (off / older): pending, not listed yet.
    case waiting(confirmed: Int, required: Int?)
    /// The automatic check is still running (B6).
    case beingChecked
    /// Held for a maintainer (also after an appeal).
    case beingCheckedByPerson
    case notAccepted(canAppeal: Bool, appealed: Bool)
    /// Hidden after reports ("not here") or by a moderator.
    case hidden
    case closed
    case expired
    /// On the phone only, waiting for the user (B5): shareable from `shareAfter`.
    case draft(shareAfter: Date?)
    /// On the phone, sent when back online (B6).
    case queued
    /// "Just for me".
    case justForMe

    static func of(_ s: PlaceSummary) -> MyPlaceStatus {
        let confirmed = Int((s.confirmationsWeighted ?? 0).rounded(.down))
        let required = s.required.map { Int($0.rounded(.up)) }
        switch s.status {
        case .published: return .communityVerified
        case .rejected: return .notAccepted(canAppeal: s.screening?.canAppeal == true, appealed: s.screening?.appealed == true)
        case .hidden:
            return s.heldForReview == true || s.screening?.state == .held ? .beingCheckedByPerson : .hidden
        case .closed: return .closed
        case .expired: return .expired
        case .pending, nil:
            if s.heldForReview == true { return .beingCheckedByPerson }
            switch s.screening?.state {
            case .checking: return .beingChecked
            case .held: return .beingCheckedByPerson
            case .rejected: return .notAccepted(canAppeal: s.screening?.canAppeal == true, appealed: s.screening?.appealed == true)
            case .passed: return .live(confirmed: confirmed, required: required)
            case .some(.none), .skipped, nil: return .waiting(confirmed: confirmed, required: required)
            }
        }
    }

    /// Tapping a not-accepted place offers the review (once) instead of opening the place.
    var opensOutcome: Bool { if case .notAccepted = self { true } else { false } }
}

// MARK: - Drafts and the offline queue (B5, B6)

/// A public place kept on the phone: a draft (B5, the user shares it later) or queued (B6, sent when back online).
/// Lives in the device-local `outbox` table (kind "place"), never in backups, never on the server until shared.
/// Photos are not kept with a draft (they can be added on the place card once it's shared).
struct PlaceDraft: Codable, Identifiable, Hashable, Sendable {
    enum State: String, Codable, Sendable { case draft, queued }

    var id = UUID()
    var place: NewPlace
    var createdAt = Date()
    var state: State
    /// B5: when the limit lifts (or the pause ends).
    var shareAfter: Date?
    var attempts = 0
    var nextAttemptAt = Date.distantPast

    var status: MyPlaceStatus { state == .queued ? .queued : .draft(shareAfter: shareAfter) }
    var location: LatLng { LatLng(lat: place.lat, lng: place.lng) }
}

protocol PlaceDraftStorage: Sendable {
    func load() -> [PlaceDraft]
    func save(_ items: [PlaceDraft])
}

/// Rows in `outbox` with kind = "place"; `payload_json` holds the whole draft.
struct LocalStorePlaceDraftStorage: PlaceDraftStorage {
    static let kind = "place"
    let store: LocalStore
    func load() -> [PlaceDraft] {
        let rows = (try? store.outboxItems(kind: Self.kind)) ?? []
        return rows.compactMap { try? JSON.makeDecoder().decode(PlaceDraft.self, from: Data($0.payload.utf8)) }
            .sorted { $0.createdAt > $1.createdAt }
    }
    func save(_ items: [PlaceDraft]) {
        let enc = JSON.makeEncoder()
        let rows = items.compactMap { i -> (id: String, payload: String, attempts: Int, nextAttemptAt: Date)? in
            guard let d = try? enc.encode(i) else { return nil }
            return (i.id.uuidString, String(decoding: d, as: UTF8.self), i.attempts,
                    i.nextAttemptAt == .distantPast ? Date(timeIntervalSince1970: 0) : i.nextAttemptAt)
        }
        try? store.replaceOutbox(kind: Self.kind, items: rows)
    }
}

/// In memory (tests).
final class MemoryPlaceDraftStorage: PlaceDraftStorage, @unchecked Sendable {
    private var items: [PlaceDraft] = []
    func load() -> [PlaceDraft] { items }
    func save(_ items: [PlaceDraft]) { self.items = items }
}

@MainActor
@Observable
final class PlaceOutbox {
    private(set) var items: [PlaceDraft] = []
    @ObservationIgnored private let storage: any PlaceDraftStorage
    @ObservationIgnored private var flushing = false

    init(storage: any PlaceDraftStorage) {
        self.storage = storage
        items = storage.load()
    }

    @discardableResult
    func save(_ place: NewPlace, state: PlaceDraft.State, shareAfter: Date? = nil, replacing id: UUID? = nil) -> PlaceDraft {
        var draft = PlaceDraft(place: place, state: state, shareAfter: shareAfter)
        if let id { draft.id = id; items.removeAll { $0.id == id } }
        items.insert(draft, at: 0)
        storage.save(items)
        return draft
    }

    func remove(_ id: UUID) {
        items.removeAll { $0.id == id }
        storage.save(items)
    }

    func reset() {
        items = []
        storage.save(items)
    }

    /// Sends the queued places that are due. Sent → removed and returned; offline → retried with backoff; any other
    /// answer (duplicate, limit, pause, …) → kept as a draft for the user to open and resolve.
    @discardableResult
    func flush(now: Date = .now, send: (NewPlace) async throws -> Place) async -> [Place] {
        guard !flushing else { return [] }
        flushing = true
        defer { flushing = false }
        var sent: [Place] = []
        for id in items.filter({ $0.state == .queued && $0.nextAttemptAt <= now }).map(\.id) {
            guard let i = items.firstIndex(where: { $0.id == id }) else { continue }
            items[i].attempts += 1
            let place = items[i].place
            do {
                let created = try await send(place)
                items.removeAll { $0.id == id }
                sent.append(created)
            } catch {
                guard let j = items.firstIndex(where: { $0.id == id }) else { continue }
                let failure = AddPlaceFailure.classify(error)
                if failure == .offline {
                    items[j].nextAttemptAt = now.addingTimeInterval(OutboxPolicy.backoff(attempts: items[j].attempts))
                } else {
                    items[j].state = .draft
                    items[j].shareAfter = failure.shareAfter(now: now)
                }
            }
            storage.save(items)
        }
        return sent
    }
}

/// A1 is shown once, before the first shared place (device-local flag).
enum AddPlaceIntro {
    static let seenKey = "GimanoAddPlaceIntroSeen"

    static func shouldShow(seen: Bool, sharedBefore: Bool, privateOnly: Bool) -> Bool {
        !seen && !sharedBefore && !privateOnly
    }
}
