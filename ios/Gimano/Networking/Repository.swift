import Foundation

/// Everything the app needs from the backend. Implemented by `LiveRepository` (REST, docs/api.md),
/// `DemoRepository` (offline canned Kuala Lumpur data) and `FallbackRepository` (live with demo fallback).
protocol GimanoRepository: PlaceCardDataSource, DepartureTimesSource {
    func signIn() async throws -> DeviceAuthResponse
    /// Legacy device accounts: attach a signing key (`POST /me/keys`). No-op once the pseudonym has a key.
    func ensureIdentity() async
    /// Recovery-code restore: sign in by public key, then adopt that pseudonym on this phone.
    func signIn(recovered keys: IdentityKeys) async throws -> DeviceAuthResponse
    func me() async throws -> User
    func updateMe(_ patch: UserPatch) async throws -> User

    /// One-time migration of personal data the server held for earlier app versions (`GET /me/data/export`).
    func legacyExport() async throws -> LegacyDataMigration.Export
    /// Permanently deletes that legacy server copy (`DELETE /me/data`).
    func deleteLegacyData() async throws
    /// `DELETE /me`: deletes the pseudonymous account (public contributions are anonymised).
    func deleteAccount() async throws

    func search(query: String, near: LatLng, category: PlaceCategory?, limit: Int) async throws -> [PlaceSummary]
    /// Full search answer (spelling fix, suggestions). `exact` searches the text as typed.
    func searchOutcome(query: String, near: LatLng, category: PlaceCategory?, limit: Int, exact: Bool, sort: ResultSort) async throws -> SearchOutcome
    func searchInArea(query: String, near: LatLng, category: PlaceCategory?, limit: Int, exact: Bool, sort: ResultSort, viewport: String) async throws -> SearchOutcome
    func nearby(near: LatLng, category: PlaceCategory, radiusM: Int) async throws -> [PlaceSummary]
    func place(id: String, near: LatLng?) async throws -> Place
    func reverseGeocode(_ p: LatLng) async throws -> ReverseGeocode

    func routes(_ request: RouteRequest) async throws -> [Route]
    func reroute(routeId: String, _ request: RerouteRequest) async throws -> [Route]
    func departureTimes(origin: LatLng, destination: LatLng, date: Date, vehicle: Vehicle) async throws -> [DepartureSlot]

    func live(bbox: BBox) async throws -> LiveResponse
    func createReport(_ report: NewReport) async throws -> Report
    /// `DELETE /reports/{id}` (signed): Undo within 2 min of a quick report (docs/driving.md §6.4); later 409.
    func deleteReport(id: String) async throws
    func vote(reportId: String, stillThere: Bool) async throws -> Report
    func thank(reportId: String) async throws
    func sendLocations(_ batch: LocationBatch) async throws

    func sendFeedback(_ feedback: FeedbackRequest) async throws -> FeedbackCreated
    func myFeedback() async throws -> [FeedbackSummary]
    func deleteFeedbackContact(id: String, contactToken: String?) async throws
    /// `DELETE /crash-reports/{id}/contact` with X-Contact-Token.
    func deleteCrashContact(id: String, contactToken: String) async throws
    /// `POST /places/{id}/flag` (community places only).
    func flagPlace(id: String, reason: FlagReason) async throws
    func sendCrashReport(_ report: CrashReport) async throws -> CrashCreated

    // Community places
    func createPlace(_ place: NewPlace) async throws -> Place
    func updateCommunityPlace(id: String, _ place: NewPlace) async throws -> Place
    func deleteCommunityPlace(id: String) async throws
    /// `POST /places/{id}/appeal` (signed): a person reviews a place the AI check didn't accept (once per place).
    func appealPlace(id: String, note: String?) async throws -> Place
    func suggestEdit(placeId: String, _ s: PlaceEditSuggestion) async throws -> SuggestionAccepted
    func verifyPlace(id: String, _ v: VerifyPlaceRequest) async throws -> VerifyResult
    /// Pending community places in this geohash-6 cell and its neighbours (never the caller's own).
    func pendingNearby(cell: String) async throws -> [PlaceSummary]
    // Complaints (docs/complaints.md): road and place issues
    func createIssue(_ issue: NewIssue) async throws -> Issue
    func issuesNearby(bbox: BBox, kinds: [IssueKind]?) async throws -> [Issue]
    func voteIssue(id: String, _ vote: IssueVote) async throws -> Issue
    func attestChallenge() async throws -> String
    func attest(keyId: String, attestation: String) async throws
    func myContributions() async throws -> [PlaceSummary]

    // Reviews & photos
    func reviews(placeId: String, sort: ReviewSort, cursor: String?) async throws -> ReviewsPage
    func createReview(placeId: String, _ r: NewReview) async throws -> Review
    func updateReview(id: String, _ r: NewReview) async throws -> Review
    func deleteReview(id: String) async throws
    func toggleHelpful(reviewId: String) async throws
    func flagReview(id: String, reason: FlagReason) async throws
    /// Uploads a JPEG (already ≤ 2048 px, metadata-free); the server re-encodes to WebP.
    func uploadPhoto(_ jpeg: Data, placeId: String, caption: String?, progress: @escaping @Sendable (Double) -> Void) async throws -> Photo
    func photos(placeId: String, cursor: String?) async throws -> PhotosPage
    func deletePhoto(id: String) async throws
    func flagPhoto(id: String, reason: FlagReason) async throws

    // Inbox
    func inbox(cursor: String?) async throws -> InboxPage
    func markInboxRead(upTo: Date) async throws

    // Share my drive (server relays ciphertext only)
    func createShare(_ r: ShareCreateRequest) async throws -> ShareCreated
    func putShare(id: String, writeToken: String, _ blob: ShareBlob) async throws
    func deleteShare(id: String, writeToken: String) async throws

    func health() async -> Bool
}

// MARK: - Live (REST)

/// Persists the anonymous device token per backend.
enum TokenStore {
    static func key(for base: URL) -> String { "auth.token.\(base.host() ?? "")\(base.port.map { ":\($0)" } ?? "")" }

    static func load(for base: URL) -> String? { Keychain.get(key(for: base)) }
    static func save(_ token: String?, for base: URL) { Keychain.set(token, for: key(for: base)) }

    static var deviceId: String {
        if let id = Keychain.get("device.id") { return id }
        let id = UUID().uuidString
        Keychain.set(id, for: "device.id")
        return id
    }
}

final class LiveRepository: GimanoRepository {
    let client: APIClient
    private let baseURL: URL
    private let store: LocalStore

    init(baseURL: URL, store: LocalStore = .shared) {
        self.baseURL = baseURL
        self.store = store
        self.client = APIClient(baseURL: baseURL, token: TokenStore.load(for: baseURL))
        let keys = (try? store.identity())?.keys
        Task { [client] in await client.setSigner(keys) }
    }

    private var locale: String { Locale.current.language.languageCode?.identifier ?? "en" }

    // MARK: auth (docs/identity-and-reputation.md §1)

    /// 1. Known pseudonym → signature login (`POST /auth/token`), e.g. after a restore.
    /// 2. Otherwise → new key + `POST /auth/register`.
    /// Servers without identity endpoints (404) → the legacy anonymous device login.
    func signIn() async throws -> DeviceAuthResponse {
        if let id = try? store.identity() {
            let ts = Int64(Date().timeIntervalSince1970)
            let req = TokenRequest(userId: id.userId, ts: ts, sig: id.keys.sign(Canonical.auth(userId: id.userId, ts: ts)))
            do {
                let res: TokenResponse = try await client.send("POST", "auth/token", body: req)
                await adopt(token: res.token, keys: id.keys)
                return DeviceAuthResponse(token: res.token, userId: id.userId, displayName: id.displayName ?? "")
            } catch let e as APIError where e.isServerSideGap {
                return try await legacyDeviceSignIn()
            } catch APIError.http(status: 401, _) {
                // This server doesn't know the pseudonym (e.g. a different backend): register the same key here.
                return try await register(keys: id.keys, createdAt: id.createdAt)
            }
        }
        do {
            return try await register(keys: .generate(), createdAt: LocalStore.timestamp())
        } catch let e as APIError where e.isServerSideGap {
            return try await legacyDeviceSignIn()
        }
    }

    func signIn(recovered keys: IdentityKeys) async throws -> DeviceAuthResponse {
        let ts = Int64(Date().timeIntervalSince1970)
        let body = KeyLoginRequest(publicKey: keys.publicKeyBase64, ts: ts,
                                   sig: keys.sign(Canonical.keyLogin(publicKeyBase64: keys.publicKeyBase64, ts: ts)))
        let res: DeviceAuthResponse = try await client.send("POST", "auth/token", body: body)
        try store.saveIdentity(StoredIdentity(userId: res.userId, displayName: res.displayName, keys: keys, createdAt: LocalStore.timestamp()))
        await adopt(token: res.token, keys: keys)
        return res
    }

    private func register(keys: IdentityKeys, createdAt: String) async throws -> DeviceAuthResponse {
        let res: DeviceAuthResponse = try await client.send("POST", "auth/register", body: RegisterRequest(publicKey: keys.publicKeyBase64, locale: locale))
        try store.saveIdentity(StoredIdentity(userId: res.userId, displayName: res.displayName, keys: keys, createdAt: createdAt))
        await adopt(token: res.token, keys: keys)
        return res
    }

    private func legacyDeviceSignIn() async throws -> DeviceAuthResponse {
        let res: DeviceAuthResponse = try await client.send("POST", "auth/device", body: DeviceAuthRequest(deviceId: TokenStore.deviceId, locale: locale))
        await client.setToken(res.token)
        TokenStore.save(res.token, for: baseURL)
        return res
    }

    private func adopt(token: String, keys: IdentityKeys) async {
        await client.setToken(token)
        await client.setSigner(keys)
        TokenStore.save(token, for: baseURL)
    }

    /// Upgrades a legacy device account (JWT only) by attaching a new key; keeps its pseudonym and reputation.
    func ensureIdentity() async {
        guard (try? store.identity()) == nil, await client.token != nil else { return }
        let keys = IdentityKeys.generate()
        do {
            try await client.sendNoContent("POST", "me/keys", body: AttachKeyRequest(publicKey: keys.publicKeyBase64, sigByOldKey: nil))
            let me: User = try await client.get("me")
            try store.saveIdentity(StoredIdentity(userId: me.id, displayName: me.displayName, keys: keys, createdAt: LocalStore.timestamp()))
            await client.setSigner(keys)
        } catch {
            // Server without identity support yet, or offline: try again next launch.
        }
    }

    /// Ensures a token exists and retries once after signing in again on 401.
    private func authed<T: Sendable>(_ op: @Sendable () async throws -> T) async throws -> T {
        if await client.token == nil { _ = try await signIn() }
        do {
            return try await op()
        } catch APIError.http(status: 401, let problem) {
            if problem?.type?.hasSuffix("/no-key") == true { await ensureIdentity() } else { _ = try await signIn() }
            return try await op()
        }
    }

    func me() async throws -> User { try await authed { try await self.client.get("me") } }

    func updateMe(_ patch: UserPatch) async throws -> User {
        try await authed { try await self.client.send("PATCH", "me", body: patch) }
    }

    // MARK: legacy personal data (migration only — personal data now lives on the device)

    func legacyExport() async throws -> LegacyDataMigration.Export {
        try await authed { try await self.client.get("me/data/export") }
    }

    func deleteLegacyData() async throws {
        try await authed { try await self.client.sendNoContent("DELETE", "me/data", body: Optional<Empty>.none) }
    }

    func deleteAccount() async throws {
        try await authed { try await self.client.sendNoContent("DELETE", "me", body: Optional<Empty>.none) }
    }

    func search(query: String, near: LatLng, category: PlaceCategory?, limit: Int) async throws -> [PlaceSummary] {
        var q = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "lat", value: String(near.lat)),
            URLQueryItem(name: "lng", value: String(near.lng)),
            URLQueryItem(name: "limit", value: String(limit)),
        ]
        if let category { q.append(URLQueryItem(name: "category", value: category.rawValue)) }
        let query = q
        let res: SearchResponse = try await authed { try await self.client.get("search", query: query) }
        return res.results
    }

    func nearby(near: LatLng, category: PlaceCategory, radiusM: Int) async throws -> [PlaceSummary] {
        let q = [
            URLQueryItem(name: "lat", value: String(near.lat)),
            URLQueryItem(name: "lng", value: String(near.lng)),
            URLQueryItem(name: "category", value: category.rawValue),
            URLQueryItem(name: "radius", value: String(radiusM)),
        ]
        let res: SearchResponse = try await authed { try await self.client.get("search/nearby", query: q) }
        return res.results
    }

    func place(id: String, near: LatLng?) async throws -> Place {
        let escaped = id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? id
        let q = near.map { [URLQueryItem(name: "lat", value: String($0.lat)), URLQueryItem(name: "lng", value: String($0.lng))] } ?? []
        return try await authed { try await self.client.get("places/\(escaped)", query: q) }
    }

    /// `GET /geocode/reverse` → address, plus `nearby` places within 50 m on newer servers.
    func reverseGeocode(_ p: LatLng) async throws -> ReverseGeocode {
        let q = [URLQueryItem(name: "lat", value: String(p.lat)), URLQueryItem(name: "lng", value: String(p.lng))]
        return try await authed { try await self.client.get("geocode/reverse", query: q) }
    }

    func searchInArea(query: String, near: LatLng, category: PlaceCategory?, limit: Int, exact: Bool, sort: ResultSort, viewport: String) async throws -> SearchOutcome {
        var items = [URLQueryItem(name: "q", value: query), URLQueryItem(name: "lat", value: String(near.lat)),
            URLQueryItem(name: "lng", value: String(near.lng)), URLQueryItem(name: "limit", value: String(limit)),
            URLQueryItem(name: "viewport", value: viewport), URLQueryItem(name: "exact", value: String(exact)),
            URLQueryItem(name: "sort", value: sort == .nearest ? "nearest" : "relevance")]
        if let category { items.append(URLQueryItem(name: "category", value: category.rawValue)) }
        let request = items
        let res: SearchResponse = try await authed { try await self.client.get("search", query: request) }
        let results = res.results.filter { SearchArea.contains(viewport, $0.location) }
        return SearchOutcome(results: results, correctedQuery: res.correctedQuery, suggestions: [], noMatch: results.isEmpty, interpretation: res.interpretation)
    }

    func searchOutcome(query: String, near: LatLng, category: PlaceCategory?, limit: Int, exact: Bool, sort: ResultSort) async throws -> SearchOutcome {
        var q = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "lat", value: String(near.lat)),
            URLQueryItem(name: "lng", value: String(near.lng)),
            URLQueryItem(name: "limit", value: String(limit)),
        ]
        if let category { q.append(URLQueryItem(name: "category", value: category.rawValue)) }
        if exact { q.append(URLQueryItem(name: "exact", value: "true")) }
        q.append(URLQueryItem(name: "sort", value: sort == .nearest ? "nearest" : "relevance"))
        let query = q
        let res: SearchResponse = try await authed { try await self.client.get("search", query: query) }
        return SearchOutcome(results: res.results, correctedQuery: res.correctedQuery, suggestions: res.suggestions ?? [],
                             noMatch: res.noMatch ?? false, interpretation: res.interpretation)
    }

    // MARK: routing

    func routes(_ request: RouteRequest) async throws -> [Route] {
        let res: RoutesResponse = try await authed { try await self.client.send("POST", "routes", body: request) }
        return res.routes
    }

    func reroute(routeId: String, _ request: RerouteRequest) async throws -> [Route] {
        let res: RoutesResponse = try await authed { try await self.client.send("POST", "routes/\(routeId)/reroute", body: request) }
        return res.routes
    }

    func departureTimes(origin: LatLng, destination: LatLng, date: Date, vehicle: Vehicle) async throws -> [DepartureSlot] {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Asia/Kuala_Lumpur")!
        let c = cal.dateComponents([.year, .month, .day], from: date)
        let day = String(format: "%04d-%02d-%02d", c.year ?? 2026, c.month ?? 1, c.day ?? 1)
        let q = [
            URLQueryItem(name: "vehicle", value: vehicle.isMotorized ? vehicle.rawValue : Vehicle.car.rawValue),
            URLQueryItem(name: "originLat", value: String(origin.lat)), URLQueryItem(name: "originLng", value: String(origin.lng)),
            URLQueryItem(name: "destLat", value: String(destination.lat)), URLQueryItem(name: "destLng", value: String(destination.lng)),
            URLQueryItem(name: "date", value: day),
        ]
        let res: DepartureTimesResponse = try await authed { try await self.client.get("routes/departure-times", query: q) }
        return res.slots
    }

    // MARK: live

    func live(bbox: BBox) async throws -> LiveResponse {
        try await authed {
            try await self.client.get("live", query: [
                URLQueryItem(name: "bbox", value: bbox.queryValue),
                URLQueryItem(name: "types", value: "alerts,jams,drivers"),
            ])
        }
    }

    func createReport(_ report: NewReport) async throws -> Report {
        try await authed { try await self.client.send("POST", "reports", body: report) }
    }

    func deleteReport(id: String) async throws {
        try await authed { try await self.client.sendNoContent("DELETE", "reports/\(id)", body: Optional<Empty>.none) }
    }

    func vote(reportId: String, stillThere: Bool) async throws -> Report {
        try await authed { try await self.client.send("POST", "reports/\(reportId)/votes", body: VoteRequest(stillThere: stillThere)) }
    }

    func thank(reportId: String) async throws {
        try await authed { try await self.client.sendNoContent("POST", "reports/\(reportId)/thanks", body: Optional<Empty>.none) }
    }

    func sendLocations(_ batch: LocationBatch) async throws {
        try await authed { try await self.client.sendNoContent("POST", "locations", body: batch) }
    }

    func sendFeedback(_ feedback: FeedbackRequest) async throws -> FeedbackCreated {
        try await authed { try await self.client.send("POST", "feedback", body: feedback) }
    }

    func myFeedback() async throws -> [FeedbackSummary] {
        try await authed { try await self.client.get("me/feedback") }
    }

    func deleteFeedbackContact(id: String, contactToken: String?) async throws {
        let headers = contactToken.map { ["X-Contact-Token": $0] } ?? [:]
        try await authed { try await self.client.sendNoContent("DELETE", "feedback/\(id)/contact", body: Optional<Empty>.none, headers: headers) }
    }

    func deleteCrashContact(id: String, contactToken: String) async throws {
        try await authed {
            try await self.client.sendNoContent("DELETE", "crash-reports/\(id)/contact", body: Optional<Empty>.none, headers: ["X-Contact-Token": contactToken])
        }
    }

    func flagPlace(id: String, reason: FlagReason) async throws {
        let escaped = id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? id
        try await authed { try await self.client.sendNoContent("POST", "places/\(escaped)/flag", body: FlagRequest(reason: reason)) }
    }

    func sendCrashReport(_ report: CrashReport) async throws -> CrashCreated {
        try await authed { try await self.client.send("POST", "crash-reports", body: report) }
    }

    // MARK: community places, reviews, photos

    func createPlace(_ place: NewPlace) async throws -> Place {
        try await authed { try await self.client.send("POST", "places", body: place) }
    }

    func updateCommunityPlace(id: String, _ place: NewPlace) async throws -> Place {
        try await authed { try await self.client.send("PATCH", "places/\(id)", body: place) }
    }

    func deleteCommunityPlace(id: String) async throws {
        try await authed { try await self.client.sendNoContent("DELETE", "places/\(id)", body: Optional<Empty>.none) }
    }

    func appealPlace(id: String, note: String?) async throws -> Place {
        try await authed { try await self.client.send("POST", "places/\(id)/appeal", body: AppealPlaceRequest(note: note)) }
    }

    func suggestEdit(placeId: String, _ s: PlaceEditSuggestion) async throws -> SuggestionAccepted {
        try await authed { try await self.client.send("POST", "places/\(placeId)/suggest-edit", body: s) }
    }

    func verifyPlace(id: String, _ v: VerifyPlaceRequest) async throws -> VerifyResult {
        try await authed { try await self.client.send("POST", "places/\(id)/verify", body: v) }
    }

    func pendingNearby(cell: String) async throws -> [PlaceSummary] {
        try await authed { try await self.client.get("places/pending-nearby", query: [URLQueryItem(name: "cell", value: cell)]) }
    }

    func createIssue(_ issue: NewIssue) async throws -> Issue {
        try await authed { try await self.client.send("POST", "issues", body: issue) }
    }

    func issuesNearby(bbox: BBox, kinds: [IssueKind]?) async throws -> [Issue] {
        struct R: Decodable, Sendable { var issues: [Issue] }
        var q = [URLQueryItem(name: "bbox", value: bbox.queryValue)]
        if let kinds, !kinds.isEmpty { q.append(URLQueryItem(name: "kinds", value: kinds.map(\.rawValue).joined(separator: ","))) }
        let query = q
        // Accept {issues: [...]} or a bare array.
        if let r: R = try? await authed({ try await self.client.get("issues/nearby", query: query) }) { return r.issues }
        return try await authed { try await self.client.get("issues/nearby", query: query) }
    }

    func voteIssue(id: String, _ vote: IssueVote) async throws -> Issue {
        try await authed { try await self.client.send("POST", "issues/\(id)/votes", body: vote) }
    }

    func attestChallenge() async throws -> String {
        struct C: Decodable, Sendable { var challenge: String }
        let c: C = try await authed { try await self.client.get("me/attest/challenge") }
        return c.challenge
    }

    func attest(keyId: String, attestation: String) async throws {
        struct A: Encodable, Sendable { var keyId: String; var attestation: String }
        try await authed { try await self.client.sendNoContent("POST", "me/attest", body: A(keyId: keyId, attestation: attestation)) }
    }

    func myContributions() async throws -> [PlaceSummary] {
        try await authed { try await self.client.get("me/places/contributed") }
    }

    func reviews(placeId: String, sort: ReviewSort, cursor: String?) async throws -> ReviewsPage {
        var q = [URLQueryItem(name: "sort", value: sort.rawValue)]
        if let cursor { q.append(URLQueryItem(name: "cursor", value: cursor)) }
        let query = q
        return try await authed { try await self.client.get("places/\(placeId)/reviews", query: query) }
    }

    func createReview(placeId: String, _ r: NewReview) async throws -> Review {
        try await authed { try await self.client.send("POST", "places/\(placeId)/reviews", body: r) }
    }

    func updateReview(id: String, _ r: NewReview) async throws -> Review {
        try await authed { try await self.client.send("PATCH", "reviews/\(id)", body: r) }
    }

    func deleteReview(id: String) async throws {
        try await authed { try await self.client.sendNoContent("DELETE", "reviews/\(id)", body: Optional<Empty>.none) }
    }

    func toggleHelpful(reviewId: String) async throws {
        try await authed { try await self.client.sendNoContent("POST", "reviews/\(reviewId)/helpful", body: Optional<Empty>.none) }
    }

    func flagReview(id: String, reason: FlagReason) async throws {
        try await authed { try await self.client.sendNoContent("POST", "reviews/\(id)/flag", body: FlagRequest(reason: reason)) }
    }

    func uploadPhoto(_ jpeg: Data, placeId: String, caption: String?, progress: @escaping @Sendable (Double) -> Void) async throws -> Photo {
        var fields = ["placeId": placeId]
        if let caption, !caption.isEmpty { fields["caption"] = caption }
        let f = fields
        return try await authed {
            try await self.client.upload("photos", fields: f, file: jpeg, fileName: "photo.jpg", mimeType: "image/jpeg", progress: progress)
        }
    }

    func photos(placeId: String, cursor: String?) async throws -> PhotosPage {
        let q = cursor.map { [URLQueryItem(name: "cursor", value: $0)] } ?? []
        return try await authed { try await self.client.get("places/\(placeId)/photos", query: q) }
    }

    func deletePhoto(id: String) async throws {
        try await authed { try await self.client.sendNoContent("DELETE", "photos/\(id)", body: Optional<Empty>.none) }
    }

    func flagPhoto(id: String, reason: FlagReason) async throws {
        try await authed { try await self.client.sendNoContent("POST", "photos/\(id)/flag", body: FlagRequest(reason: reason)) }
    }

    func createShare(_ r: ShareCreateRequest) async throws -> ShareCreated {
        try await authed { try await self.client.send("POST", "shares", body: r) }
    }

    func inbox(cursor: String?) async throws -> InboxPage {
        let q = cursor.map { [URLQueryItem(name: "cursor", value: $0)] } ?? []
        return try await authed { try await self.client.get("me/inbox", query: q) }
    }

    func markInboxRead(upTo: Date) async throws {
        try await authed { try await self.client.sendNoContent("POST", "me/inbox/read", body: InboxReadRequest(upTo: upTo)) }
    }

    func putShare(id: String, writeToken: String, _ blob: ShareBlob) async throws {
        try await client.sendNoContent("PUT", "shares/\(id)", body: blob, authorization: "Share \(writeToken)")
    }

    func deleteShare(id: String, writeToken: String) async throws {
        try await client.sendNoContent("DELETE", "shares/\(id)", body: Optional<Empty>.none, authorization: "Share \(writeToken)")
    }

    func health() async -> Bool {
        // healthz lives at the host root, not under /api/v1.
        var c = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)!
        c.path = "/healthz"
        guard let url = c.url else { return false }
        var req = URLRequest(url: url)
        req.timeoutInterval = 3
        guard let (_, res) = try? await URLSession.shared.data(for: req) else { return false }
        return (res as? HTTPURLResponse)?.statusCode == 200
    }
}

// MARK: - Fallback (auto mode)

/// Tries the live backend; when it is unreachable (or an endpoint is missing) serves demo data instead,
/// so the app stays fully demoable while the backend is being built.
final class FallbackRepository: GimanoRepository {
    let live: LiveRepository
    let demo: DemoRepository
    private let state = FallbackState()
    private let onStatus: @Sendable @MainActor (Bool) -> Void

    init(live: LiveRepository, demo: DemoRepository, onStatus: @escaping @Sendable @MainActor (Bool) -> Void) {
        self.live = live
        self.demo = demo
        self.onStatus = onStatus
    }

    /// - Parameter gapFallback: serve demo data when the endpoint is missing (404/5xx). Off for writes, so
    ///   user data is never silently written to the local demo store while the backend is online.
    private func run<T: Sendable>(gapFallback: Bool = true,
                                  _ liveOp: @Sendable (LiveRepository) async throws -> T,
                                  demoOp: @Sendable (DemoRepository) async throws -> T) async throws -> T {
        if await state.shouldSkipLive() { return try await demoOp(demo) }
        do {
            let value = try await liveOp(live)
            if await state.markOnline() { await onStatus(false) }
            return value
        } catch let e as APIError where e.isUnreachable {
            if await state.markOffline() { await onStatus(true) }
            return try await demoOp(demo)
        } catch let e as APIError where e.isServerSideGap && gapFallback {
            return try await demoOp(demo)
        }
    }

    func signIn() async throws -> DeviceAuthResponse { try await run({ try await $0.signIn() }, demoOp: { try await $0.signIn() }) }
    func ensureIdentity() async { await live.ensureIdentity() }
    func signIn(recovered keys: IdentityKeys) async throws -> DeviceAuthResponse { try await live.signIn(recovered: keys) }
    func me() async throws -> User { try await run({ try await $0.me() }, demoOp: { try await $0.me() }) }
    func updateMe(_ patch: UserPatch) async throws -> User { try await run(gapFallback: false, { try await $0.updateMe(patch) }, demoOp: { try await $0.updateMe(patch) }) }
    /// Migration calls go only to the real backend (never demo).
    func legacyExport() async throws -> LegacyDataMigration.Export { try await live.legacyExport() }
    func deleteLegacyData() async throws { try await live.deleteLegacyData() }
    /// Never answered by the demo data: a deletion either reaches the server or fails visibly.
    func deleteAccount() async throws { try await live.deleteAccount() }
    func search(query: String, near: LatLng, category: PlaceCategory?, limit: Int) async throws -> [PlaceSummary] {
        try await run({ try await $0.search(query: query, near: near, category: category, limit: limit) },
                      demoOp: { try await $0.search(query: query, near: near, category: category, limit: limit) })
    }
    func searchInArea(query: String, near: LatLng, category: PlaceCategory?, limit: Int, exact: Bool, sort: ResultSort, viewport: String) async throws -> SearchOutcome {
        try await live.searchInArea(query: query, near: near, category: category, limit: limit, exact: exact, sort: sort, viewport: viewport)
    }

    func searchOutcome(query: String, near: LatLng, category: PlaceCategory?, limit: Int, exact: Bool, sort: ResultSort) async throws -> SearchOutcome {
        try await run({ try await $0.searchOutcome(query: query, near: near, category: category, limit: limit, exact: exact, sort: sort) },
                      demoOp: { try await $0.searchOutcome(query: query, near: near, category: category, limit: limit, exact: exact, sort: sort) })
    }
    func nearby(near: LatLng, category: PlaceCategory, radiusM: Int) async throws -> [PlaceSummary] {
        try await run({ try await $0.nearby(near: near, category: category, radiusM: radiusM) },
                      demoOp: { try await $0.nearby(near: near, category: category, radiusM: radiusM) })
    }
    func place(id: String, near: LatLng?) async throws -> Place { try await run({ try await $0.place(id: id, near: near) }, demoOp: { try await $0.place(id: id, near: near) }) }
    func reverseGeocode(_ p: LatLng) async throws -> ReverseGeocode { try await run({ try await $0.reverseGeocode(p) }, demoOp: { try await $0.reverseGeocode(p) }) }
    func routes(_ request: RouteRequest) async throws -> [Route] { try await run({ try await $0.routes(request) }, demoOp: { try await $0.routes(request) }) }
    func reroute(routeId: String, _ request: RerouteRequest) async throws -> [Route] {
        try await run({ try await $0.reroute(routeId: routeId, request) }, demoOp: { try await $0.reroute(routeId: routeId, request) })
    }
    func departureTimes(origin: LatLng, destination: LatLng, date: Date, vehicle: Vehicle) async throws -> [DepartureSlot] {
        try await run({ try await $0.departureTimes(origin: origin, destination: destination, date: date, vehicle: vehicle) },
                      demoOp: { try await $0.departureTimes(origin: origin, destination: destination, date: date, vehicle: vehicle) })
    }
    func live(bbox: BBox) async throws -> LiveResponse { try await run({ try await $0.live(bbox: bbox) }, demoOp: { try await $0.live(bbox: bbox) }) }
    func createReport(_ report: NewReport) async throws -> Report { try await run(gapFallback: false, { try await $0.createReport(report) }, demoOp: { try await $0.createReport(report) }) }
    /// A report kept in the demo store (auto mode fell back) is withdrawn there; anything else goes to the server.
    func deleteReport(id: String) async throws {
        if id.hasPrefix("demo-") { try await demo.deleteReport(id: id) } else { try await live.deleteReport(id: id) }
    }
    func vote(reportId: String, stillThere: Bool) async throws -> Report {
        try await run({ try await $0.vote(reportId: reportId, stillThere: stillThere) }, demoOp: { try await $0.vote(reportId: reportId, stillThere: stillThere) })
    }
    func thank(reportId: String) async throws { try await run({ try await $0.thank(reportId: reportId) }, demoOp: { try await $0.thank(reportId: reportId) }) }
    func sendLocations(_ batch: LocationBatch) async throws {
        try await run({ try await $0.sendLocations(batch) }, demoOp: { try await $0.sendLocations(batch) })
    }
    /// Feedback never goes to the demo store while in auto mode: failures leave it in the outbox for retry.
    func sendFeedback(_ feedback: FeedbackRequest) async throws -> FeedbackCreated { try await live.sendFeedback(feedback) }
    func myFeedback() async throws -> [FeedbackSummary] { try await live.myFeedback() }
    func deleteFeedbackContact(id: String, contactToken: String?) async throws { try await live.deleteFeedbackContact(id: id, contactToken: contactToken) }
    func deleteCrashContact(id: String, contactToken: String) async throws { try await live.deleteCrashContact(id: id, contactToken: contactToken) }
    func flagPlace(id: String, reason: FlagReason) async throws {
        try await run(gapFallback: false, { try await $0.flagPlace(id: id, reason: reason) }, demoOp: { try await $0.flagPlace(id: id, reason: reason) })
    }
    /// Crash reports never fall back to demo: they wait locally until the server takes them.
    func sendCrashReport(_ report: CrashReport) async throws -> CrashCreated { try await live.sendCrashReport(report) }

    // Community contributions are public writes: no silent demo fallback while the backend is online.
    /// Never into the demo store, even when the backend can't be reached: offline, the app keeps the place on the phone
    /// and sends it when back online (design B6), instead of a demo "It's on the map" nobody else can see.
    func createPlace(_ place: NewPlace) async throws -> Place {
        try await live.createPlace(place)
    }
    func updateCommunityPlace(id: String, _ place: NewPlace) async throws -> Place {
        try await run(gapFallback: false, { try await $0.updateCommunityPlace(id: id, place) }, demoOp: { try await $0.updateCommunityPlace(id: id, place) })
    }
    func deleteCommunityPlace(id: String) async throws {
        try await run(gapFallback: false, { try await $0.deleteCommunityPlace(id: id) }, demoOp: { try await $0.deleteCommunityPlace(id: id) })
    }
    func appealPlace(id: String, note: String?) async throws -> Place {
        try await run(gapFallback: false, { try await $0.appealPlace(id: id, note: note) }, demoOp: { try await $0.appealPlace(id: id, note: note) })
    }
    func suggestEdit(placeId: String, _ s: PlaceEditSuggestion) async throws -> SuggestionAccepted {
        try await run(gapFallback: false, { try await $0.suggestEdit(placeId: placeId, s) }, demoOp: { try await $0.suggestEdit(placeId: placeId, s) })
    }
    func verifyPlace(id: String, _ v: VerifyPlaceRequest) async throws -> VerifyResult {
        try await run(gapFallback: false, { try await $0.verifyPlace(id: id, v) }, demoOp: { try await $0.verifyPlace(id: id, v) })
    }
    func pendingNearby(cell: String) async throws -> [PlaceSummary] {
        try await run(gapFallback: false, { try await $0.pendingNearby(cell: cell) }, demoOp: { try await $0.pendingNearby(cell: cell) })
    }
    /// Complaints never fall back to demo data while online (they're public contributions).
    func createIssue(_ issue: NewIssue) async throws -> Issue {
        try await run(gapFallback: false, { try await $0.createIssue(issue) }, demoOp: { try await $0.createIssue(issue) })
    }
    func issuesNearby(bbox: BBox, kinds: [IssueKind]?) async throws -> [Issue] {
        try await run(gapFallback: false, { try await $0.issuesNearby(bbox: bbox, kinds: kinds) }, demoOp: { try await $0.issuesNearby(bbox: bbox, kinds: kinds) })
    }
    func voteIssue(id: String, _ vote: IssueVote) async throws -> Issue {
        try await run(gapFallback: false, { try await $0.voteIssue(id: id, vote) }, demoOp: { try await $0.voteIssue(id: id, vote) })
    }
    func attestChallenge() async throws -> String { try await live.attestChallenge() }
    func attest(keyId: String, attestation: String) async throws { try await live.attest(keyId: keyId, attestation: attestation)
    }
    func myContributions() async throws -> [PlaceSummary] {
        try await run({ try await $0.myContributions() }, demoOp: { try await $0.myContributions() })
    }
    func reviews(placeId: String, sort: ReviewSort, cursor: String?) async throws -> ReviewsPage {
        try await run({ try await $0.reviews(placeId: placeId, sort: sort, cursor: cursor) }, demoOp: { try await $0.reviews(placeId: placeId, sort: sort, cursor: cursor) })
    }
    func createReview(placeId: String, _ r: NewReview) async throws -> Review {
        try await run(gapFallback: false, { try await $0.createReview(placeId: placeId, r) }, demoOp: { try await $0.createReview(placeId: placeId, r) })
    }
    func updateReview(id: String, _ r: NewReview) async throws -> Review {
        try await run(gapFallback: false, { try await $0.updateReview(id: id, r) }, demoOp: { try await $0.updateReview(id: id, r) })
    }
    func deleteReview(id: String) async throws {
        try await run(gapFallback: false, { try await $0.deleteReview(id: id) }, demoOp: { try await $0.deleteReview(id: id) })
    }
    func toggleHelpful(reviewId: String) async throws {
        try await run(gapFallback: false, { try await $0.toggleHelpful(reviewId: reviewId) }, demoOp: { try await $0.toggleHelpful(reviewId: reviewId) })
    }
    func flagReview(id: String, reason: FlagReason) async throws {
        try await run(gapFallback: false, { try await $0.flagReview(id: id, reason: reason) }, demoOp: { try await $0.flagReview(id: id, reason: reason) })
    }
    func uploadPhoto(_ jpeg: Data, placeId: String, caption: String?, progress: @escaping @Sendable (Double) -> Void) async throws -> Photo {
        try await run(gapFallback: false, { try await $0.uploadPhoto(jpeg, placeId: placeId, caption: caption, progress: progress) },
                      demoOp: { try await $0.uploadPhoto(jpeg, placeId: placeId, caption: caption, progress: progress) })
    }
    func photos(placeId: String, cursor: String?) async throws -> PhotosPage {
        try await run({ try await $0.photos(placeId: placeId, cursor: cursor) }, demoOp: { try await $0.photos(placeId: placeId, cursor: cursor) })
    }
    func deletePhoto(id: String) async throws {
        try await run(gapFallback: false, { try await $0.deletePhoto(id: id) }, demoOp: { try await $0.deletePhoto(id: id) })
    }
    func flagPhoto(id: String, reason: FlagReason) async throws {
        try await run(gapFallback: false, { try await $0.flagPhoto(id: id, reason: reason) }, demoOp: { try await $0.flagPhoto(id: id, reason: reason) })
    }

    /// No demo items in auto mode: an inbox must only show real news about the user's contributions.
    func inbox(cursor: String?) async throws -> InboxPage {
        try await run(gapFallback: false, { try await $0.inbox(cursor: cursor) }, demoOp: { _ in InboxPage(items: [], next: nil, unread: 0) })
    }
    func markInboxRead(upTo: Date) async throws {
        try await run(gapFallback: false, { try await $0.markInboxRead(upTo: upTo) }, demoOp: { _ in })
    }

    func createShare(_ r: ShareCreateRequest) async throws -> ShareCreated {
        try await run(gapFallback: false, { try await $0.createShare(r) }, demoOp: { try await $0.createShare(r) })
    }
    func putShare(id: String, writeToken: String, _ blob: ShareBlob) async throws {
        try await run(gapFallback: false, { try await $0.putShare(id: id, writeToken: writeToken, blob) },
                      demoOp: { try await $0.putShare(id: id, writeToken: writeToken, blob) })
    }
    func deleteShare(id: String, writeToken: String) async throws {
        try await run(gapFallback: false, { try await $0.deleteShare(id: id, writeToken: writeToken) },
                      demoOp: { try await $0.deleteShare(id: id, writeToken: writeToken) })
    }

    func health() async -> Bool { await live.health() }

    var isOffline: Bool { get async { await state.offline } }
}

/// After a transport failure, skip the live backend for a while so the UI isn't stuck on timeouts.
actor FallbackState {
    private(set) var offline = false
    private var retryAfter: Date = .distantPast
    var backoffS: TimeInterval = 30

    func shouldSkipLive() -> Bool { offline && Date() < retryAfter }

    /// Returns true when the status changed.
    func markOffline() -> Bool {
        retryAfter = Date().addingTimeInterval(backoffS)
        defer { offline = true }
        return !offline
    }

    func markOnline() -> Bool {
        defer { offline = false }
        return offline
    }
}

// MARK: - Route builder ("Bina laluan"): stateless leg routing and map matching

extension LiveRepository: RouteBuilderTransport {
    /// `POST /routes` with `"store": false`: coordinates and travel mode only.
    func builderRoute(_ request: BuilderRouteRequest) async throws -> BuilderRoutesResponse {
        try await authed { try await self.client.send("POST", "routes", body: request) }
    }

    /// `POST /routes/match`: the drawn line's coordinates and travel mode only.
    func builderMatch(_ request: BuilderMatchRequest) async throws -> BuilderMatchResponse {
        try await authed { try await self.client.send("POST", "routes/match", body: request) }
    }
}

// MARK: - Event short links (docs/events.md §5.6): the encrypted blob only

extension LiveRepository: EventDropTransport {
    func createDrop(blob: [UInt8], expiresAt: Date) async throws -> EventDropCreated {
        let headers = ["X-Drop-Expires": EventDropHTTP.expiresHeader(expiresAt)]
        let data = try await authed { try await self.client.raw("POST", "drops", body: Data(blob), headers: headers) }
        do {
            return try JSON.makeDecoder().decode(EventDropCreated.self, from: data)
        } catch {
            throw APIError.decoding(String(describing: error))
        }
    }

    func putDrop(id: String, writeToken: String, blob: [UInt8], expiresAt: Date) async throws {
        _ = try await client.raw("PUT", "drops/\(id)", body: Data(blob), authorization: "Drop \(writeToken)",
                                 headers: ["X-Drop-Expires": EventDropHTTP.expiresHeader(expiresAt)])
    }

    func getDrop(id: String) async throws -> [UInt8] {
        [UInt8](try await client.raw("GET", "drops/\(id)", body: nil, anonymous: true, accept: "application/octet-stream"))
    }

    func deleteDrop(id: String, writeToken: String) async throws {
        _ = try await client.raw("DELETE", "drops/\(id)", body: nil, authorization: "Drop \(writeToken)")
    }
}

/// Auto mode: short links always use the real server (never the demo store).
extension FallbackRepository: EventDropTransport {
    func createDrop(blob: [UInt8], expiresAt: Date) async throws -> EventDropCreated { try await live.createDrop(blob: blob, expiresAt: expiresAt) }
    func putDrop(id: String, writeToken: String, blob: [UInt8], expiresAt: Date) async throws {
        try await live.putDrop(id: id, writeToken: writeToken, blob: blob, expiresAt: expiresAt)
    }
    func getDrop(id: String) async throws -> [UInt8] { try await live.getDrop(id: id) }
    func deleteDrop(id: String, writeToken: String) async throws { try await live.deleteDrop(id: id, writeToken: writeToken) }
}

/// Auto mode: the builder always asks the real server (never demo geometry); unreachable reads as offline.
extension FallbackRepository: RouteBuilderTransport {
    func builderRoute(_ request: BuilderRouteRequest) async throws -> BuilderRoutesResponse { try await live.builderRoute(request) }
    func builderMatch(_ request: BuilderMatchRequest) async throws -> BuilderMatchResponse { try await live.builderMatch(request) }
}

extension GimanoRepository {
    func searchInArea(query: String, near: LatLng, category: PlaceCategory?, limit: Int, exact: Bool, sort: ResultSort, viewport: String) async throws -> SearchOutcome {
        var result = try await searchOutcome(query: query, near: near, category: category, limit: limit, exact: exact, sort: sort)
        result.results = result.results.filter { SearchArea.contains(viewport, $0.location) }
        result.suggestions = []; result.noMatch = result.results.isEmpty
        return result
    }
}
