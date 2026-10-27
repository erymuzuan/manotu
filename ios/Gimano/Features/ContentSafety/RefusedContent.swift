import Foundation
import GRDB

// "Not accepted": public content the check refused (422 `content_rejected`), kept ON THIS PHONE ONLY (device-local
// `refused_content` table + files) for 30 days so the user can appeal it. It is sent to the server only when the user
// taps Send on an appeal (`POST /appeals`), never otherwise, never backed up (docs/privacy-and-backup.md).

enum RefusedKind: String, Codable, CaseIterable, Sendable {
    case review, photo, place

    var symbol: String {
        switch self {
        case .review: "star.bubble.fill"
        case .photo: "camera.fill"
        case .place: "mappin.circle.fill"
        }
    }

    var label: String.LocalizationValue {
        switch self {
        case .review: "Your review"
        case .photo: "Your photo"
        case .place: "Your place note"
        }
    }
}

enum AppealState: String, Codable, Sendable {
    case none, sent, answered

    var symbol: String {
        switch self {
        case .none: "person.fill.questionmark"
        case .sent: "clock.fill"
        case .answered: "checkmark.circle.fill"
        }
    }
}

struct RefusedContent: Identifiable, Equatable, Sendable {
    /// Client UUID; also the `refusalId` of the appeal (one appeal per refusal).
    var id: String
    var kind: RefusedKind
    var placeId: String?
    var placeName: String?
    var text: String
    var reasons: [String]
    /// File names in `refused/<id>/` (refused photos).
    var photoFiles: [String]
    var createdAt: Date
    var appealState: AppealState
    /// The refused review's stars (1…5); `POST /appeals` requires it for `kind=review`.
    var rating: Int?

    init(id: String = UUID().uuidString.lowercased(), kind: RefusedKind, placeId: String?, placeName: String?, text: String = "",
         reasons: [String], photoFiles: [String] = [], createdAt: Date = .now, appealState: AppealState = .none, rating: Int? = nil) {
        self.rating = rating
        self.id = id; self.kind = kind; self.placeId = placeId; self.placeName = placeName; self.text = text
        self.reasons = reasons; self.photoFiles = photoFiles; self.createdAt = createdAt; self.appealState = appealState
    }

    /// The reasons the app explains (fixed codes), never empty.
    var explained: [ContentReason] {
        let r = ContentReason.explaining(reasons)
        return r.isEmpty ? [.unclear] : r
    }
}

// MARK: - Pure rules

enum RefusedRules {
    static let keepDays = 30
    static let maxReasonsKept = 8

    static func isExpired(_ createdAt: Date, now: Date = .now) -> Bool {
        now.timeIntervalSince(createdAt) > Double(keepDays) * 86400
    }

    /// Whole days left before it is deleted (at least 0).
    static func daysLeft(_ createdAt: Date, now: Date = .now) -> Int {
        max(0, Int((Double(keepDays) - now.timeIntervalSince(createdAt) / 86400).rounded(.up)))
    }

    /// Items that still need the user (not yet appealed): the badge in the Inbox.
    static func badge(_ items: [RefusedContent]) -> Int { items.filter { $0.appealState == .none }.count }
}

/// What the user writes on the appeal screen and which files go with it.
enum AppealRules {
    static let maxNote = 200
    static let maxPhotos = 3
    static let maxPhotoBytes = 5 * 1024 * 1024
    static let maxText = 2000
    /// The server keeps at most four reason codes.
    static let maxReasons = 4

    static func trimmed(_ note: String) -> String { note.trimmingCharacters(in: .whitespacesAndNewlines) }
    /// The note is REQUIRED: 1…200 characters once trimmed.
    static func isValidNote(_ note: String) -> Bool { (1...maxNote).contains(trimmed(note).count) }
    static func clamped(_ note: String) -> String { String(note.prefix(maxNote)) }
    static func canSend(note: String, sending: Bool) -> Bool { !sending && isValidNote(note) }

    /// Room left for evidence photos once the refused photo(s) themselves ride along.
    static func evidenceSlots(refusedPhotos: Int) -> Int { max(0, maxPhotos - refusedPhotos) }

    /// At most 3 photos, each ≤ 5 MB (oversized ones are dropped, the rest keep their order).
    static func filesToSend(_ photos: [Data]) -> [Data] {
        Array(photos.filter { $0.count <= maxPhotoBytes }.prefix(maxPhotos))
    }
}

// MARK: - Appeal request / answer

/// `POST /appeals` (multipart/form-data), docs/content-safety.md "Appeals".
struct AppealRequest: Sendable, Equatable {
    var refusalId: String
    var kind: RefusedKind
    var placeId: String?
    var text: String
    var reasons: [String]
    var note: String
    var photos: [Data]
    /// 1…5, sent for `kind=review` only.
    var rating: Int?

    /// Text fields in wire order; `reasons` is repeated, empty values are left out.
    var fields: [(name: String, value: String)] {
        var out: [(String, String)] = [("refusalId", refusalId), ("kind", kind.rawValue)]
        if let placeId, !placeId.isEmpty { out.append(("placeId", placeId)) }
        out.append(("text", String(text.prefix(AppealRules.maxText))))
        for r in reasons.filter({ !$0.isEmpty }).prefix(AppealRules.maxReasons) { out.append(("reasons", r)) }
        out.append(("note", AppealRules.trimmed(note)))
        if kind == .review, let rating, (1...5).contains(rating) { out.append(("rating", String(rating))) }
        return out
    }

    static func == (a: AppealRequest, b: AppealRequest) -> Bool {
        a.refusalId == b.refusalId && a.kind == b.kind && a.placeId == b.placeId && a.text == b.text && a.reasons == b.reasons
            && a.note == b.note && a.photos == b.photos && a.rating == b.rating
    }
}

/// 202 `{id, status: "pending"}`.
struct AppealCreated: Codable, Sendable, Equatable {
    var id: String
    var status: String
}

/// How a failed appeal reads to the user.
enum AppealFailure: Equatable, Sendable {
    case alreadyAppealed
    case noteRequired
    case paused(until: Date?)
    case suspended
    case offline
    case tooBig
    case tooMany
    case other(String)

    static func classify(_ error: any Error) -> AppealFailure {
        if let u = error as? URLError { return classify(APIError.transport(u)) }
        guard let e = error as? APIError else { return .other(error.localizedDescription) }
        if e.isUnreachable { return .offline }
        switch e {
        case .conflict: return .alreadyAppealed
        case .http(let status, let p):
            switch status {
            case 409: return .alreadyAppealed
            case 400 where p?.code == "note_required": return .noteRequired
            case 413: return .tooBig
            case 429: return .tooMany
            case 403 where p?.code == "posting_paused": return .paused(until: p?.pausedUntil.flatMap(JSON.parseDate))
            case 403: return .suspended
            default: break
            }
        case .transport: return .offline
        default: break
        }
        return .other(e.localizedDescription)
    }

    var symbol: String {
        switch self {
        case .alreadyAppealed: "checkmark.circle.fill"
        case .noteRequired: "square.and.pencil"
        case .paused: "pause.circle.fill"
        case .suspended: "hand.raised.fill"
        case .offline: "wifi.slash"
        case .tooBig: "photo.badge.exclamationmark"
        case .tooMany: "calendar.badge.clock"
        case .other: "exclamationmark.triangle.fill"
        }
    }

    var message: String {
        switch self {
        case .alreadyAppealed: String(localized: "Already sent for this one.")
        case .noteRequired: String(localized: "Write a short reason, without links.")
        case .paused(let until):
            if let until, PostingPause.isActive(until: until) { String(localized: "Paused. Back in \(PostingPause.hoursLeft(until: until)) h") }
            else { String(localized: "Posting is paused for now. It lifts by itself.") }
        case .suspended: String(localized: "Your account can't post right now.")
        case .offline: String(localized: "No connection. Your note is kept, try again.")
        case .tooBig: String(localized: "A photo is too big (5 MB at most).")
        case .tooMany: String(localized: "Too many appeals today. Try again tomorrow.")
        case .other(let s): s
        }
    }

    /// Success-like: the appeal exists on the server already, so the saved item is marked sent.
    var countsAsSent: Bool { self == .alreadyAppealed }
}

// MARK: - Multipart

/// Builds a `multipart/form-data` body (pure, so it is unit-tested).
enum MultipartForm {
    struct File: Sendable { var field: String; var fileName: String; var mimeType: String; var data: Data }

    static func body(boundary: String, fields: [(name: String, value: String)], files: [File]) -> Data {
        var out = Data()
        func add(_ s: String) { out.append(Data(s.utf8)) }
        for f in fields {
            add("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(escape(f.name))\"\r\n\r\n\(f.value)\r\n")
        }
        for f in files {
            add("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(escape(f.field))\"; filename=\"\(escape(f.fileName))\"\r\nContent-Type: \(f.mimeType)\r\n\r\n")
            out.append(f.data)
            add("\r\n")
        }
        add("--\(boundary)--\r\n")
        return out
    }

    private static func escape(_ s: String) -> String { s.replacingOccurrences(of: "\"", with: "%22").replacingOccurrences(of: "\r", with: "").replacingOccurrences(of: "\n", with: "") }
}

// MARK: - Persistence (device-local, GRDB)

extension LocalStore {
    /// Refused photos (JPEG, metadata already stripped) live here, next to but apart from private-place photos.
    var refusedDirectory: URL { photosDirectory.deletingLastPathComponent().appendingPathComponent("refused", isDirectory: true) }

    /// `refused/<id>/<name>`.
    func refusedFileURL(id: String, _ name: String) -> URL {
        refusedDirectory.appendingPathComponent(id, isDirectory: true).appendingPathComponent(name)
    }

    /// Writes the photos and the row. Photo data stays on this phone.
    @discardableResult
    func saveRefused(_ item: RefusedContent, photos: [Data] = []) throws -> RefusedContent {
        var item = item
        if !photos.isEmpty {
            try FileManager.default.createDirectory(at: refusedDirectory.appendingPathComponent(item.id, isDirectory: true),
                                                    withIntermediateDirectories: true)
            item.photoFiles = try photos.enumerated().map { i, data in
                let name = "\(i).jpg"
                try data.write(to: refusedFileURL(id: item.id, name), options: .atomic)
                return name
            }
        }
        let reasons = String(data: try JSONEncoder().encode(Array(item.reasons.prefix(RefusedRules.maxReasonsKept))), encoding: .utf8) ?? "[]"
        let files = String(data: try JSONEncoder().encode(item.photoFiles), encoding: .utf8) ?? "[]"
        try dbQueue.write { db in
            try db.execute(sql: """
                INSERT OR REPLACE INTO refused_content (id, kind, place_id, place_name, text, reasons_json, photos_json, created_at, appeal_state, rating)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """, arguments: [item.id, item.kind.rawValue, item.placeId, item.placeName, item.text, reasons, files,
                                 Self.timestamp(item.createdAt), item.appealState.rawValue, item.rating])
        }
        return item
    }

    func refusedItems() throws -> [RefusedContent] {
        try dbQueue.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM refused_content ORDER BY created_at DESC").map(Self.refused)
        }
    }

    func refusedItem(id: String) throws -> RefusedContent? {
        try dbQueue.read { db in
            try Row.fetchOne(db, sql: "SELECT * FROM refused_content WHERE id = ?", arguments: [id]).map(Self.refused)
        }
    }

    private static func refused(_ r: Row) -> RefusedContent {
        func list(_ s: String?) -> [String] { s.flatMap { try? JSONDecoder().decode([String].self, from: Data($0.utf8)) } ?? [] }
        return RefusedContent(id: r["id"], kind: RefusedKind(rawValue: r["kind"]) ?? .review, placeId: r["place_id"], placeName: r["place_name"],
                              text: r["text"] ?? "", reasons: list(r["reasons_json"]), photoFiles: list(r["photos_json"]),
                              createdAt: Self.date(r["created_at"]) ?? .now, appealState: AppealState(rawValue: r["appeal_state"] ?? "") ?? .none, rating: r["rating"])
    }

    func setRefusedState(id: String, _ state: AppealState) throws {
        try dbQueue.write { db in
            try db.execute(sql: "UPDATE refused_content SET appeal_state = ? WHERE id = ?", arguments: [state.rawValue, id])
        }
    }

    func deleteRefused(id: String) throws {
        try dbQueue.write { db in try db.execute(sql: "DELETE FROM refused_content WHERE id = ?", arguments: [id]) }
        try? FileManager.default.removeItem(at: refusedDirectory.appendingPathComponent(id, isDirectory: true))
    }

    /// Deletes everything older than 30 days (rows and photo files); returns how many items went.
    @discardableResult
    func purgeRefused(now: Date = .now) throws -> Int {
        let old = try refusedItems().filter { RefusedRules.isExpired($0.createdAt, now: now) }
        for item in old { try deleteRefused(id: item.id) }
        return old.count
    }

    func refusedPhotoData(_ item: RefusedContent) -> [Data] {
        item.photoFiles.compactMap { try? Data(contentsOf: refusedFileURL(id: item.id, $0)) }
    }

    // MARK: device_state (device-local flags)

    func deviceState(_ key: String) -> String? {
        try? dbQueue.read { db in try String.fetchOne(db, sql: "SELECT value FROM device_state WHERE key = ?", arguments: [key]) }
    }

    func setDeviceState(_ key: String, _ value: String?) {
        try? dbQueue.write { db in
            if let value {
                try db.execute(sql: "INSERT INTO device_state (key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value", arguments: [key, value])
            } else {
                try db.execute(sql: "DELETE FROM device_state WHERE key = ?", arguments: [key])
            }
        }
    }
}

// MARK: - Posting pause, kept across restarts

extension PostingPause {
    static let stateKey = "postingPausedUntil"

    static func load(from store: LocalStore, now: Date = .now) -> Date? {
        guard let raw = store.deviceState(stateKey), let d = LocalStore.date(raw), d > now else {
            store.setDeviceState(stateKey, nil)
            return nil
        }
        return d
    }

    static func save(_ until: Date?, to store: LocalStore, now: Date = .now) {
        if let until, until > now { store.setDeviceState(stateKey, LocalStore.timestamp(until)) } else { store.setDeviceState(stateKey, nil) }
    }
}

/// Which saved items an Inbox answer settles (docs/content-safety.md "Appeals", "What happens next").
enum AppealAnswers {
    /// Ids of the `sent` items an Inbox note answers:
    /// - denied (`content_rejected`) and approved photo / place results carry `subjectId` = the `refusalId` (photo id for a photo);
    /// - an approved **review** is a new review: `content_published`, `subjectKind: "review"`, `subjectId` = the new review id, same
    ///   `placeId`, so it matches the sent review refusal of that place made before the note arrived.
    static func answered(_ sent: [RefusedContent], by items: [InboxItem]) -> Set<String> {
        var out = Set<String>()
        for r in sent where r.appealState == .sent {
            for i in items {
                let answers = i.kind == .contentPublished || i.kind == .contentRejected || i.kind == .placeLive
                guard answers else { continue }
                if i.subjectId == r.id || (i.kind == .placeLive && r.kind == .place && i.refId == r.placeId) { out.insert(r.id); break }
                if i.kind == .contentPublished, i.subjectKind == "review", r.kind == .review, r.placeId != nil, i.placeId == r.placeId,
                   i.createdAt >= r.createdAt { out.insert(r.id); break }
            }
        }
        return out
    }
}
