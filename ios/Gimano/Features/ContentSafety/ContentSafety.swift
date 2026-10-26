import Foundation

// Public content safety (docs/content-safety.md; design: canvas "Manotu AI Content Safety"). Pure logic: place warnings,
// the fixed reason codes and the app copy for each (the model's text is never shown), the LOCAL advert pre-filter for
// reviews, how 201 / 422 / 403 answers map to screens, photo status badges and report-note outcomes.

// MARK: - Moderation block on the owner's own review / photo

enum ModerationState: String, Codable, Sendable {
    case passed, held, checking, rejected, skipped

    init(from decoder: any Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = ModerationState(rawValue: raw.lowercased()) ?? .skipped
    }
}

/// `moderation` on the author's own `Review` / `Photo` (owner view only).
struct ContentModeration: Codable, Sendable, Hashable {
    var state: ModerationState
    var reasons: [String]
    var canAppeal: Bool

    init(state: ModerationState, reasons: [String] = [], canAppeal: Bool = false) {
        self.state = state; self.reasons = reasons; self.canAppeal = canAppeal
    }

    private enum CodingKeys: String, CodingKey { case state, reasons, canAppeal }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        state = try c.decodeIfPresent(ModerationState.self, forKey: .state) ?? .skipped
        reasons = try c.decodeIfPresent([String].self, forKey: .reasons) ?? []
        canAppeal = try c.decodeIfPresent(Bool.self, forKey: .canAppeal) ?? false
    }
}

/// `POST /reviews/{id}/appeal` and `POST /photos/{id}/appeal`: `{note?: ≤200}` → 202.
struct AppealContentRequest: Codable, Sendable, Hashable {
    static let maxNote = 200
    var note: String?
}

// MARK: - Place warnings (banner)

enum PlaceWarning: String, CaseIterable, Sendable {
    case alcohol, gambling, tobacco

    /// Known warnings only, in a fixed order, no duplicates; unknown words from a newer server are ignored.
    static func parse(_ raw: [String]?) -> [PlaceWarning] {
        let set = Set((raw ?? []).compactMap { PlaceWarning(rawValue: $0.lowercased()) })
        return allCases.filter(set.contains)
    }

    /// Wire values for `POST /places` (`warnings`): nil when there are none.
    static func wire(_ warnings: Set<PlaceWarning>) -> [String]? {
        let list = allCases.filter(warnings.contains).map(\.rawValue)
        return list.isEmpty ? nil : list
    }

    /// SF Symbols (checked by a unit test): glass, dice, cigarette.
    var symbol: String {
        switch self {
        case .alcohol: "wineglass.fill"
        case .gambling: "dice.fill"
        case .tobacco: "smoke.fill"
        }
    }

    var spoken: String.LocalizationValue {
        switch self {
        case .alcohol: "Alcohol"
        case .gambling: "Gambling"
        case .tobacco: "Cigarettes and vape"
        }
    }
}

enum WarningCopy {
    /// The one short line under the icons.
    static func line(_ warnings: [PlaceWarning]) -> String.LocalizationValue {
        switch warnings.count {
        case 0: ""
        case 1:
            switch warnings[0] {
            case .alcohol: "Alcohol is sold here"
            case .gambling: "Gambling happens here"
            case .tobacco: "Cigarettes or vape sold here"
            }
        default: "Alcohol, gambling or tobacco here"
        }
    }

    /// What the `?` explains.
    static let explain: String.LocalizationValue =
        "This place sells or hosts this. It stays on the map and you can still drive there. The warning is only so you know."
}

/// Selection logic of the add-place step "Anything people should know?": three tiles plus "None".
enum WarningSelection {
    static func toggled(_ w: PlaceWarning, in set: Set<PlaceWarning>) -> Set<PlaceWarning> {
        var s = set
        if s.contains(w) { s.remove(w) } else { s.insert(w) }
        return s
    }
    /// "None of these" clears the others.
    static func none(_: Set<PlaceWarning>) -> Set<PlaceWarning> { [] }
}

// MARK: - Fixed reason codes → icon tiles and copy

/// What an offending item looks like in the "Can't post this" sheet (one crossed-out tile each).
enum ContentTile: String, CaseIterable, Sendable {
    case phone, link, offer, violence, adult, gamblingDrugs, personal, hate, other

    var symbol: String {
        switch self {
        case .phone: "phone.fill"
        case .link: "link"
        case .offer: "tag.fill"
        case .violence: "bolt.fill"
        case .adult: "eye.slash.fill"
        case .gamblingDrugs: "dice.fill"
        case .personal: "person.crop.rectangle.fill"
        case .hate: "bubble.left.and.exclamationmark.bubble.right.fill"
        case .other: "exclamationmark.triangle.fill"
        }
    }

    var label: String.LocalizationValue {
        switch self {
        case .phone: "Phone number"
        case .link: "Link"
        case .offer: "Offer"
        case .violence: "Violence"
        case .adult: "Adult"
        case .gamblingDrugs: "Gambling or drugs"
        case .personal: "Plates or faces"
        case .hate: "Hate or harassment"
        case .other: "Not allowed"
        }
    }
}

/// A fixed `reasons[]` code on a review, photo or note (docs/api.md "Community places" + docs/content-safety.md).
enum ContentReason: String, CaseIterable, Sendable {
    // Place-check codes that can also come back on reviews and photos.
    case spam, scam, gibberish, harassment, adult, illegal, security, unclear, ok
    case privateHome = "private_home"
    // Content-safety codes.
    case violence, drugs
    case personalData = "personal_data"
    case threeR = "3r"
    case gamblingPromo = "gambling_promo"
    case alcoholPromo = "alcohol_promo"
    case tobaccoPromo = "tobacco_promo"
    case brandPromo = "brand_promo"
    case externalContact = "external_contact"
    case highRiskInvestment = "high_risk_investment"
    case loanShark = "loan_shark"
    case mlm, counterfeit
    case medicalClaims = "medical_claims"
    // Warning only (places).
    case sensitiveAlcohol = "sensitive_alcohol"
    case sensitiveGambling = "sensitive_gambling"
    case sensitiveTobacco = "sensitive_tobacco"

    /// Unknown codes read as `unclear` (the server does the same for the model's output).
    static func parse(_ codes: [String]) -> [ContentReason] {
        codes.map { ContentReason(rawValue: $0.lowercased()) ?? .unclear }
    }

    /// Reasons that actually explain a rejection (not `ok`, not warning-only).
    static func explaining(_ codes: [String]) -> [ContentReason] {
        var seen = Set<ContentReason>()
        return parse(codes).filter { $0 != .ok && !$0.isWarningOnly && seen.insert($0).inserted }
    }

    var isWarningOnly: Bool { self == .sensitiveAlcohol || self == .sensitiveGambling || self == .sensitiveTobacco }

    var tiles: [ContentTile] {
        switch self {
        case .externalContact: [.phone, .link]
        case .spam, .brandPromo, .gamblingPromo, .alcoholPromo, .tobaccoPromo, .scam, .highRiskInvestment, .loanShark, .mlm,
             .counterfeit, .medicalClaims, .gibberish: [.offer]
        case .violence: [.violence]
        case .adult: [.adult]
        case .drugs, .illegal: [.gamblingDrugs]
        case .personalData, .privateHome: [.personal]
        case .harassment, .threeR: [.hate]
        case .security, .unclear, .ok, .sensitiveAlcohol, .sensitiveGambling, .sensitiveTobacco: [.other]
        }
    }

    /// The photo tile this reason lights up (violence / adult / gambling-drugs / plates-faces), when it maps to one.
    var photoTile: ContentTile? {
        switch self {
        case .violence: .violence
        case .adult: .adult
        case .drugs, .illegal, .gamblingPromo, .alcoholPromo, .tobaccoPromo: .gamblingDrugs
        case .personalData, .privateHome: .personal
        default: nil
        }
    }

    /// One short fixed line per code.
    var copy: String.LocalizationValue {
        switch self {
        case .spam: "Looks like an advert"
        case .scam: "Looks like a scam"
        case .gibberish: "Hard to read"
        case .harassment: "Targets a person"
        case .adult: "Adult content"
        case .illegal: "Illegal goods or services"
        case .security: "Security details"
        case .unclear, .ok: "We couldn't tell what this is"
        case .privateHome: "Someone's home"
        case .violence: "Violence"
        case .drugs: "Drugs"
        case .personalData: "Personal details"
        case .threeR: "Race, religion or royalty"
        case .gamblingPromo: "Gambling offer"
        case .alcoholPromo: "Alcohol offer"
        case .tobaccoPromo: "Cigarette or vape offer"
        case .brandPromo: "Brand promotion"
        case .externalContact: "Phone number or link"
        case .highRiskInvestment: "Risky investment offer"
        case .loanShark: "Loan offer"
        case .mlm: "Network marketing offer"
        case .counterfeit: "Fake goods"
        case .medicalClaims: "Medical claims"
        case .sensitiveAlcohol: "Alcohol is sold here"
        case .sensitiveGambling: "Gambling happens here"
        case .sensitiveTobacco: "Cigarettes or vape sold here"
        }
    }
}

// MARK: - Local pre-filter for reviews (a hint only; the server decides)

/// The three crossed-out tiles under the review box.
enum AdHint: String, CaseIterable, Sendable {
    case phone, link, offer

    var tile: ContentTile {
        switch self { case .phone: .phone; case .link: .link; case .offer: .offer }
    }
}

enum ReviewPrefilter {
    /// Shown in the counter; typing stops here (the API itself allows 2000).
    static let maxChars = 500
    static let apiMaxChars = 2000

    /// Which kinds of advert the text looks like. Neutral mentions ("a vape shop is next door") raise nothing.
    static func hints(_ text: String) -> Set<AdHint> {
        var out = Set<AdHint>()
        let lower = text.lowercased()
        if hasPhoneNumber(lower) || mentionsMessenger(lower) { out.insert(.phone) }
        if hasLink(lower) { out.insert(.link) }
        if hasOfferWords(lower) || hasRepeats(text) { out.insert(.offer) }
        return out
    }

    static func looksLikeAdvert(_ text: String) -> Bool { !hints(text).isEmpty }

    /// 8 or more digits, allowing spaces, dashes, dots and a leading +.
    static func hasPhoneNumber(_ lower: String) -> Bool {
        var digits = 0, gap = 0
        for ch in lower {
            if ch.isASCII, ch.isNumber { digits += 1; gap = 0 }
            else if ch == " " || ch == "-" || ch == "." || ch == "+" || ch == "(" || ch == ")" { gap += 1; if gap > 2 { if digits >= 8 { return true }; digits = 0 } }
            else { if digits >= 8 { return true }; digits = 0; gap = 0 }
        }
        return digits >= 8
    }

    static func mentionsMessenger(_ lower: String) -> Bool {
        ["whatsapp", "wasap", "wassap", "telegram", "t.me/", "wa.me/", "line id", "wechat"].contains { lower.contains($0) }
    }

    static func hasLink(_ lower: String) -> Bool {
        if lower.contains("http://") || lower.contains("https://") || lower.contains("www.") { return true }
        return lower.range(of: #"\b[a-z0-9][a-z0-9-]*\.(com|net|org|my|co|io|me|ly|app|biz|xyz|info|shop|link)\b"#, options: .regularExpression) != nil
    }

    static func hasOfferWords(_ lower: String) -> Bool {
        let words = ["promo code", "kod promo", "use code", "guna kod", "voucher", "rebate", "bonus", "jackpot", "casino", "togel",
                     "% off", "diskaun", "discount", "free credit", "kredit percuma", "daftar sekarang", "sign up now", "click here",
                     "dm me", "hubungi kami", "order now", "beli sekarang"]
        return words.contains { lower.contains($0) }
    }

    /// 6 or more of the same character in a row, or the same word 4 or more times in a row.
    static func hasRepeats(_ text: String) -> Bool {
        var run = 1, prev: Character?
        for ch in text {
            if ch == prev, !ch.isWhitespace { run += 1; if run >= 6 { return true } } else { run = 1 }
            prev = ch
        }
        let words = text.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
        var same = 1
        for i in words.indices.dropFirst() {
            if words[i] == words[i - 1] { same += 1; if same >= 4 { return true } } else { same = 1 }
        }
        return false
    }
}

// MARK: - Review answers

/// What the app shows after `POST/PATCH` a review answered 201.
enum ReviewOutcome: Equatable, Sendable {
    case published
    /// `heldForReview` / moderation `held`: a maintainer decides within 24 h.
    case held
    /// No answer within 4 s: the result arrives in the Inbox.
    case checking

    static func of(_ r: Review) -> ReviewOutcome {
        switch r.moderation?.state {
        case .held: return .held
        case .checking: return .checking
        case .passed, .skipped: return .published
        case .rejected: return .held   // a stored rejected review is shown by the Inbox / the row, never as "posted"
        case nil: return r.heldForReview == true || r.status == "hidden" ? .held : .published
        }
    }
}

/// A non-201 answer to posting public content.
enum ContentFailure: Equatable, Sendable {
    /// 422 `content_rejected`: nothing was stored. `safeText` is the text without the offending part, when there is one.
    case rejected(reasons: [ContentReason], safeText: String?)
    /// 403 `posting_paused` (3 rejections in 24 h).
    case paused(until: Date?)
    /// 403 for any other reason (suspended by a moderator).
    case suspended
    case offline
    case other(String)

    static func classify(_ error: any Error, original: String? = nil) -> ContentFailure {
        guard let e = error as? APIError else {
            if let u = error as? URLError { return classify(APIError.transport(u), original: original) }
            return .other(error.localizedDescription)
        }
        if e.isUnreachable { return .offline }
        if case .http(let status, let p) = e {
            switch status {
            case 422 where p?.code == "content_rejected":
                let reasons = ContentReason.explaining(p?.reasons ?? [])
                let safe = p?.safeText?.trimmingCharacters(in: .whitespacesAndNewlines)
                // A safe text equal to the original (or empty) offers nothing new.
                let usable = (safe?.isEmpty == false && safe != original?.trimmingCharacters(in: .whitespacesAndNewlines)) ? safe : nil
                return .rejected(reasons: reasons.isEmpty ? [.unclear] : reasons, safeText: usable)
            case 403 where p?.code == "posting_paused":
                return .paused(until: p?.pausedUntil.flatMap(JSON.parseDate))
            case 403: return .suspended
            default: break
            }
        }
        return .other(e.localizedDescription)
    }

    /// 422 `content_rejected` or 403 `posting_paused`: answers the content check gives (vs. a plain failure).
    static func isContentError(_ error: any Error) -> Bool {
        guard case .http(let status, let p)? = error as? APIError else { return false }
        return (status == 422 && p?.code == "content_rejected") || (status == 403 && p?.code == "posting_paused")
    }

    /// Tiles to cross out, without repeats, at most four.
    static func tiles(for reasons: [ContentReason]) -> [ContentTile] {
        var seen = Set<ContentTile>(), out: [ContentTile] = []
        for t in reasons.flatMap(\.tiles) where seen.insert(t).inserted { out.append(t) }
        return Array(out.prefix(4))
    }
}

/// The "Paused" card: posting is paused until `until`.
enum PostingPause {
    static func isActive(until: Date?, now: Date = .now) -> Bool { until.map { $0 > now } ?? false }
    /// Whole hours left, rounded up, at least 1.
    static func hoursLeft(until: Date, now: Date = .now) -> Int { max(1, Int((until.timeIntervalSince(now) / 3600).rounded(.up))) }
}

// MARK: - Photos

/// The round badge on a photo tile.
enum PhotoBadge: Equatable, Sendable {
    case published      // tick
    case checking       // clock: processing, being checked, or held for a person
    case rejected       // cross

    static func of(_ p: Photo) -> PhotoBadge {
        if let m = p.moderation {
            switch m.state {
            case .rejected: return .rejected
            case .held, .checking: return .checking
            case .passed: return p.status == .rejected ? .rejected : .published
            case .skipped: break
            }
        }
        switch p.status {
        case .rejected: return .rejected
        case .processing: return .checking
        case .published, nil: return p.url == nil ? .checking : .published
        }
    }

    var symbol: String {
        switch self { case .published: "checkmark"; case .checking: "clock.fill"; case .rejected: "xmark" }
    }

    /// Polling stops on a final answer.
    var isFinal: Bool { self != .checking }
}

/// Polls `GET /photos/{id}` until the check is final (published or rejected) or the tries run out.
enum PhotoWatcher {
    static func watch(_ photo: Photo, interval: Duration = .seconds(3), maxTries: Int = 20,
                      fetch: @Sendable (String) async throws -> Photo) async -> Photo {
        var current = photo
        for _ in 0..<maxTries {
            if PhotoBadge.of(current).isFinal { return current }
            try? await Task.sleep(for: interval)
            if Task.isCancelled { return current }
            if let next = try? await fetch(current.id) { current = merged(current, next) }
        }
        return current
    }

    /// A poll answer replaces the status, URLs and moderation but never loses what the upload response had.
    static func merged(_ old: Photo, _ new: Photo) -> Photo {
        var p = new
        if p.url == nil { p.url = old.url }
        if p.thumbUrl == nil { p.thumbUrl = old.thumbUrl }
        if p.uploadedBy == nil { p.uploadedBy = old.uploadedBy }
        return p
    }

    /// Which of the four rejected-photo tiles are lit for these reasons (violence, adult, gambling/drugs, plates/faces).
    static func litTiles(_ reasons: [String]) -> Set<ContentTile> {
        Set(ContentReason.explaining(reasons).compactMap(\.photoTile))
    }
    static let photoTiles: [ContentTile] = [.violence, .adult, .gamblingDrugs, .personal]
}

// MARK: - Report note

enum ReportNote {
    static let maxChars = 140

    static func clamped(_ s: String) -> String { String(s.prefix(maxChars)) }

    enum Result: Equatable { case sent, noteDropped }

    /// A dropped note leaves the report live; the app says so in one line.
    static func result(of report: Report) -> Result { report.noteDropped == true ? .noteDropped : .sent }
}

// MARK: - Inbox

/// How an inbox row for the content check looks: icon, tint and the actions offered.
enum ContentInboxStatus: Equatable, Sendable {
    case published       // tick
    case heldForPerson   // person
    case checking        // clock
    case rejected(canAppeal: Bool)

    static func of(_ item: InboxItem) -> ContentInboxStatus? {
        switch item.kind {
        case .contentPublished: .published
        case .contentHeld: .heldForPerson
        case .contentRejected: .rejected(canAppeal: item.canAppeal ?? false)
        default: nil
        }
    }

    var symbol: String {
        switch self {
        case .published: "checkmark.circle.fill"
        case .heldForPerson: "person.fill"
        case .checking: "clock.fill"
        case .rejected: "xmark.circle.fill"
        }
    }

    /// Edit and Appeal are offered on a rejected item only; Appeal only when the server says it can be appealed.
    var canEdit: Bool { if case .rejected = self { true } else { false } }
    var canAppeal: Bool { if case .rejected(let a) = self { a } else { false } }
}
