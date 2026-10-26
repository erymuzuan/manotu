import Foundation

/// Offline demo backend: Kuala Lumpur places, captured real-road routes, and live alerts/jams/drivers placed on those roads.
/// Everything is generated locally so the whole UI can be demoed without the .NET backend.
actor DemoRepository: GimanoRepository {
    static let defaultLocation = LatLng(lat: 3.152613, lng: 101.703718) // on Jalan Sultan Ismail, KL (road-snapped; origin of DemoRoutes.json)

    private var user = User(id: "demo-user", displayName: "Pemandu Manotu", mood: "😎", vehicle: .car, points: 1280, level: 3, joinedAt: .now.addingTimeInterval(-86400 * 40))
    private var reports: [Report]
    private var routeDestinations: [String: (dest: RouteEndpoint, waypoints: [RouteEndpoint], vehicle: Vehicle, avoid: AvoidOptions)] = [:]
    private var feedback: [FeedbackSummary] = []
    private var community: [Place] = []
    private var myPlaceIds: Set<String> = []
    private var reviewsByPlace: [String: [Review]] = [:]
    private var photosByPlace: [String: [(photo: Photo, readyAt: Date)]] = [:]
    private var helpful: Set<String> = []
    // Public content check (docs/content-safety.md), mirrored with `DemoContentCheck`.
    private var contentRejections: [Date] = []
    private var postingPausedUntil: Date?
    private var reviewChecking: [String: Date] = [:]
    private var photoVerdicts: [String: DemoContentCheck.Verdict] = [:]
    private var contentInbox: [InboxItem] = []
    private var notedPhotos: Set<String> = []
    private var appealedPhotos: Set<String> = []
    /// Demo user's display name for authored content.
    private var me: PersonRef { PersonRef(displayName: user.displayName, level: user.level, reviewCount: reviewsByPlace.values.flatMap { $0 }.filter { $0.author.displayName == user.displayName }.count) }
    private var routeCounter = 0
    private let latency: Duration

    init(latency: Duration = .milliseconds(250)) {
        self.latency = latency
        let now = Date()
        func r(_ id: String, _ type: ReportType, _ sub: String?, _ lat: Double, _ lng: Double, _ street: String, _ minsAgo: Double, conf: Int) -> Report {
            Report(id: id, type: type, subtype: sub, lat: lat, lng: lng, heading: nil, street: street,
                   reportedBy: ReportAuthor(displayName: ["Aina", "Raj", "Mei Ling", "Hafiz", "Siti"][abs(id.hashValue) % 5], mood: "🙂"),
                   createdAt: now.addingTimeInterval(-minsAgo * 60), expiresAt: now.addingTimeInterval(3600), confirmations: conf, thanks: conf / 2)
        }
        // Every demo alert sits on a vertex of a captured real-road route (never off-road).
        let seeds: [(String, ReportType, String?, String, Int, Double, Double, Int)] = [
            ("demo-route-police", .police, "visible", "midvalley", 0, 0.18, 4, 6),
            ("demo-route-hazard", .hazard, "pothole", "midvalley", 0, 0.55, 11, 3),
            ("demo-a1", .police, "visible", "klcc", 0, 0.5, 6, 4),
            ("demo-a2", .hazard, "pothole", "batucaves", 0, 0.35, 18, 2),
            ("demo-a3", .accident, "minor", "klsentral", 0, 0.6, 9, 7),
            ("demo-a4", .traffic, "heavy", "home", 0, 0.45, 3, 12),
            ("demo-a5", .weather, "heavy_rain", "batucaves", 1, 0.7, 25, 5),
            ("demo-a6", .hazard, "flood", "work", 0, 0.7, 40, 9),
            ("demo-a7", .closure, nil, "pavilion", 1, 0.5, 55, 1),
            ("demo-a8", .animal, "on_shoulder", "sunway", 0, 0.8, 12, 1),
        ]
        reports = seeds.compactMap { id, type, sub, key, route, fraction, mins, conf in
            guard let v = CannedRoutes.shared.vertex(key: key, routeIndex: route, fraction: fraction) else { return nil }
            return r(id, type, sub, v.point.lat, v.point.lng, v.street ?? "", mins, conf: conf)
        }
        // A sample road closure on the Mid Valley demo route, so a demo drive shows the "Still closed?" prompt.
        // Answers stay in this demo store (nothing is sent).
        if let v = CannedRoutes.shared.vertex(key: "midvalley", routeIndex: 0, fraction: 0.12) {
            issues = [Issue(id: "demo-closure-1", kind: .roadClosedTemp, subtype: "roadworks", state: .confirmed, lat: v.point.lat, lng: v.point.lng,
                            roadName: v.street, summary: nil, confirmations: 2, required: 2, createdAt: now.addingTimeInterval(-5 * 3600),
                            expiresAt: now.addingTimeInterval(3 * 86400), lastEvidenceAt: now.addingTimeInterval(-5 * 3600))]
        }
    }

    private func pause() async { try? await Task.sleep(for: latency) }

    // MARK: auth/profile

    func ensureIdentity() async {}
    func signIn(recovered keys: IdentityKeys) async throws -> DeviceAuthResponse {
        DeviceAuthResponse(token: "demo", userId: "demo-recovered", displayName: "Rusa 2368")
    }

    func signIn() async throws -> DeviceAuthResponse {
        DeviceAuthResponse(token: "demo-token", userId: user.id, displayName: user.displayName)
    }

    func me() async throws -> User { user }

    /// Demo mode has no server account to delete.
    func deleteAccount() async throws {}

    func updateMe(_ patch: UserPatch) async throws -> User {
        if let n = patch.displayName { user.displayName = n }
        if let m = patch.mood { user.mood = m }
        if let v = patch.vehicle { user.vehicle = v }
        return user
    }

    // MARK: legacy (nothing to migrate in demo mode)

    func legacyExport() async throws -> LegacyDataMigration.Export { LegacyDataMigration.Export(savedPlaces: [], recents: []) }
    func deleteLegacyData() async throws {}

    /// Demo: corrects a couple of common misspellings and suggests a category when nothing matches.
    func searchOutcome(query: String, near: LatLng, category: PlaceCategory?, limit: Int, exact: Bool, sort: ResultSort) async throws -> SearchOutcome {
        let fixes = ["famly mart": "FamilyMart", "familymart": "FamilyMart", "mcd": "McDonald's", "petronass": "Petronas"]
        let key = query.lowercased().trimmingCharacters(in: .whitespaces)
        let corrected = exact ? nil : fixes[key]
        let results = try await search(query: corrected ?? query, near: near, category: category, limit: limit)
        var suggestions: [SearchSuggestion] = []
        if results.isEmpty, let cat = SearchLogic.categoryHint(in: query) {
            let n = try await nearby(near: near, category: cat, radiusM: 5000).count
            if n > 0 { suggestions.append(SearchSuggestion(label: "", category: cat, count: n)) }
        }
        return SearchOutcome(results: results, correctedQuery: corrected, suggestions: suggestions)
    }

    func search(query: String, near: LatLng, category: PlaceCategory?, limit: Int) async throws -> [PlaceSummary] {
        await pause()
        let q = query.lowercased().trimmingCharacters(in: .whitespaces)
        let pool = DemoData.places + community.filter { $0.status != .hidden }.map(\.summary)
        let scored: [(PlaceSummary, Double)] = pool.compactMap { p in
            if let category, p.category != category { return nil }
            let name = p.name.lowercased()
            var score: Double
            if q.isEmpty { score = 1 }
            else if name.hasPrefix(q) { score = 3 }
            else if name.split(separator: " ").contains(where: { $0.hasPrefix(q) }) { score = 2.5 }
            else if name.contains(q) { score = 2 }
            else if (p.brand?.lowercased().hasPrefix(q) ?? false) || p.category.rawValue.replacingOccurrences(of: "_", with: " ").hasPrefix(q) { score = 1.8 }
            else if p.address.lowercased().contains(q) { score = 1 }
            else { return nil }
            var s = p
            s.distanceM = Geo.distance(near, p.location)
            // Proximity decay (~ 10 km scale), but exact matches far away still show.
            score *= 1 / (1 + (s.distanceM ?? 0) / 10_000)
            return (s, score)
        }
        return scored.sorted { $0.1 > $1.1 }.prefix(limit).map(\.0)
    }

    func nearby(near: LatLng, category: PlaceCategory, radiusM: Int) async throws -> [PlaceSummary] {
        await pause()
        // Surau and mosque are one "prayer" group for the quick chips.
        let group: Set<PlaceCategory> = category == .surau || category == .mosque ? [.surau, .mosque] : [category]
        return DemoData.places.filter { group.contains($0.category) }
            .map { var s = $0; s.distanceM = Geo.distance(near, $0.location); return s }
            .filter { ($0.distanceM ?? 0) <= Double(radiusM) * 4 }
            .sorted { ($0.distanceM ?? 0) < ($1.distanceM ?? 0) }
    }

    func place(id: String, near: LatLng?) async throws -> Place {
        settleChecks()
        if var c = community.first(where: { $0.id == id }) {
            c.distanceM = near.map { Geo.distance($0, LatLng(lat: c.lat, lng: c.lng)) }
            c.photos = publishedPhotos(id)
            (c.rating, c.reviewCount) = ratingOf(id)
            return c
        }
        guard let s = DemoData.places.first(where: { $0.id == id }) else { throw APIError.http(status: 404, problem: nil) }
        let amenities: [String] = switch s.category {
        case .fuel: ["toilets", "convenience_store", "air_pump", "cards", "touch_n_go"]
        case .restArea: ["toilets", "surau", "food_court", "fuel"]
        case .mall: ["parking", "toilets", "surau", "ev_charging"]
        default: ["toilets", "wheelchair"]
        }
        return Place(id: s.id, name: s.name, category: s.category, address: s.address, lat: s.lat, lng: s.lng, distanceM: near.map { Geo.distance($0, s.location) },
                     brand: s.brand, phone: "+60 3-2123 4567", website: "https://www.openstreetmap.org",
                     openingHours: s.category == .fuel || s.category == .restArea ? "24/7" : "Mo-Su 10:00-22:00",
                     openNow: true, amenities: amenities, tags: [:], osmType: "node", osmId: Int64(abs(s.id.hashValue) % 1_000_000_000),
                     source: .osm, status: .published, rating: ratingOf(id).0, reviewCount: ratingOf(id).1,
                     photos: publishedPhotos(id), warnings: DemoContentCheck.warnings(forPlaceNamed: s.name))
    }

    // MARK: community places (demo)

    private func ratingOf(_ placeId: String) -> (Double?, Int) {
        let r = reviewsByPlace[placeId] ?? []
        guard !r.isEmpty else { return (nil, 0) }
        return (Double(r.map(\.rating).reduce(0, +)) / Double(r.count), r.count)
    }

    /// What everyone sees: processing or published photos; held and rejected ones stay hidden.
    private func publishedPhotos(_ placeId: String) -> [Photo] {
        (photosByPlace[placeId] ?? []).compactMap { item in
            let p = ownView(item.photo, readyAt: item.readyAt)
            return p.moderation?.state == .rejected || p.moderation?.state == .held ? nil : { var q = p; q.moderation = nil; return q }()
        }
    }

    /// The uploader's view: status after the demo check, plus `moderation`.
    private func ownView(_ photo: Photo, readyAt: Date) -> Photo {
        var p = photo
        let v = photoVerdicts[photo.id] ?? DemoContentCheck.Verdict(state: .passed, reasons: ["ok"])
        let done = Date() >= readyAt
        switch (done, v.state) {
        case (false, _): p.status = .processing; p.moderation = ContentModeration(state: .checking)
        case (true, .rejected): p.status = .rejected; p.moderation = ContentModeration(state: .rejected, reasons: v.reasons, canAppeal: !appealedPhotos.contains(photo.id))
        case (true, .held): p.status = .processing; p.moderation = ContentModeration(state: .held, reasons: v.reasons)
        case (true, .checking): p.status = .processing; p.moderation = ContentModeration(state: .checking)
        default: p.status = .published; p.moderation = ContentModeration(state: .passed, reasons: ["ok"])
        }
        return p
    }

    func photo(id: String) async throws -> Photo {
        for list in photosByPlace.values {
            if let item = list.first(where: { $0.photo.id == id }) { return ownView(item.photo, readyAt: item.readyAt) }
        }
        throw APIError.http(status: 404, problem: nil)
    }

    // Server rules mirrored for the demo (docs/api.md "AI check"): pause → limit → duplicate → the check.
    private var publicCreates: [Date] = []
    private var rejections: [Date] = []
    private var pausedUntil: Date?
    /// `checking` places and when the demo check "finishes" (B6 → Inbox place_live).
    private var checkingUntil: [String: Date] = [:]
    private var screeningInbox: [InboxItem] = []
    /// How long a `#slow` demo check takes.
    static let demoSlowCheck: TimeInterval = 20

    func createPlace(_ new: NewPlace) async throws -> Place {
        await pause()
        let now = Date()
        let name = new.name.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, name.count <= 80, !name.lowercased().contains("http") else {
            throw APIError.http(status: 400, problem: ProblemDetails(title: "Invalid name"))
        }
        let text = (name + " " + (new.description ?? "")).lowercased()
        // 403 adding_paused (3 not accepted in 24 h, or `#paused`).
        if text.contains("#paused") { pausedUntil = now.addingTimeInterval(86400) }
        if let until = pausedUntil, until > now {
            throw APIError.http(status: 403, problem: ProblemDetails(title: "Adding paused", status: 403, detail: "Adding places is paused.",
                                                                     code: "adding_paused", pausedUntil: JSON.makeISO(until)))
        }
        // 429: 3 public places an hour (or `#limit`).
        publicCreates.removeAll { now.timeIntervalSince($0) > 3600 }
        if text.contains("#limit") {
            throw APIError.http(status: 429, problem: ProblemDetails(title: "Too many requests", status: 429, retryAfterSeconds: 2400))
        }
        if publicCreates.count >= 3, let oldest = publicCreates.min() {
            let wait = Int(max(1, 3600 - now.timeIntervalSince(oldest)).rounded(.up))
            throw APIError.http(status: 429, problem: ProblemDetails(title: "Too many requests", status: 429, retryAfterSeconds: wait))
        }
        let here = LatLng(lat: new.lat, lng: new.lng)
        // Duplicate: similar name within 100 m → 409 with the existing place (as the API: `{…, existing: PlaceSummary}`),
        // unless the user said it's different (B1 → notDuplicateOf).
        let existing = (community.map(\.summary) + DemoData.places).first {
            $0.id != new.notDuplicateOf && Geo.distance($0.location, here) <= 100 && Self.similar($0.name, name)
        }
        if var existing {
            existing.distanceM = Geo.distance(existing.location, here)
            struct Conflict: Encodable { var status = 409; var title = "Similar place nearby"; var existing: PlaceSummary }
            throw APIError.conflict(try JSON.makeEncoder().encode(Conflict(existing: existing)))
        }
        var p = Place(id: "demo-community-\(UUID().uuidString.prefix(8).lowercased())", name: name, category: new.category,
                      address: new.address ?? "", lat: new.lat, lng: new.lng, phone: new.phone, website: new.website,
                      openingHours: new.openingHours, amenities: new.amenities ?? [], tags: [:], source: .community, status: .pending,
                      reviewCount: 0, description: new.description, addedBy: PersonRef(displayName: user.displayName), verifiedCount: 0, photos: [], warnings: new.warnings)
        p.confirmationsWeighted = 0
        p.required = 3
        apply(DemoScreening.verdict(name: name, description: new.description, emas: user.tier == .emas), to: &p, now: now)
        publicCreates.append(now)
        community.append(p)
        myPlaceIds.insert(p.id)
        user.points = (user.points ?? 0) + 5
        return p
    }

    /// The demo check's answer applied as the server does (docs/api.md "AI check" table).
    private func apply(_ v: DemoScreening.Verdict, to p: inout Place, now: Date) {
        p.heldForReview = nil
        switch v.state {
        case .passed:
            p.status = v.emas ? .published : .pending
            p.screening = PlaceScreening(state: .passed, reasons: ["ok"])
        case .held:
            p.status = .hidden
            p.heldForReview = true
            p.screening = PlaceScreening(state: .held, reasons: v.reasons)
            screeningInbox.append(InboxItem(id: "demo-held-\(p.id)-\(screeningInbox.count)", kind: .placeHeld,
                                            title: String(localized: "A person will check \(p.name)"),
                                            body: String(localized: "Usually within 24 hours. Only you can see it until then."),
                                            refType: "place", refId: p.id, createdAt: now, read: nil, count: nil))
        case .rejected:
            p.status = .rejected
            p.screening = PlaceScreening(state: .rejected, reasons: v.reasons, canAppeal: true)
            rejections.removeAll { now.timeIntervalSince($0) > 86400 }
            rejections.append(now)
            if rejections.count >= 3 { pausedUntil = now.addingTimeInterval(86400) }
            screeningInbox.append(InboxItem(id: "demo-rej-\(p.id)-\(screeningInbox.count)", kind: .placeNotAccepted,
                                            title: String(localized: "\(p.name) was not accepted"),
                                            body: String(localized: "Open My contributions to edit it or ask for a review."),
                                            refType: "place", refId: p.id, createdAt: now, read: nil, count: nil))
        case .checking:
            p.status = .pending
            p.screening = PlaceScreening(state: .checking)
            checkingUntil[p.id] = now.addingTimeInterval(Self.demoSlowCheck)
        case .none, .skipped:
            p.status = .pending
            p.screening = PlaceScreening(state: .skipped)
        }
    }

    /// Finishes demo checks that ran past the wait (B6): live, with a place_live Inbox note.
    private func settleChecks(now: Date = .now) {
        for (id, until) in checkingUntil where until <= now {
            checkingUntil[id] = nil
            guard let i = community.firstIndex(where: { $0.id == id }), community[i].screening?.state == .checking else { continue }
            community[i].screening = PlaceScreening(state: .passed, reasons: ["ok"])
            screeningInbox.append(InboxItem(id: "demo-live-\(id)", kind: .placeLive, title: String(localized: "\(community[i].name) is on the map"),
                                            body: String(localized: "The check finished. People nearby will be asked to confirm it."),
                                            refType: "place", refId: id, createdAt: now, read: nil, count: nil))
        }
    }

    /// Demo only: finish every `checking` place now (tests).
    func finishChecksNow() { settleChecks(now: .distantFuture) }

    func appealPlace(id: String, note: String?) async throws -> Place {
        await pause()
        guard myPlaceIds.contains(id), let i = community.firstIndex(where: { $0.id == id }) else { throw APIError.http(status: 403, problem: nil) }
        guard community[i].status == .rejected, community[i].screening?.appealed != true else {
            throw APIError.conflict(Data(#"{"status":409,"title":"Conflict","detail":"This place can't be appealed."}"#.utf8))
        }
        community[i].status = .hidden
        community[i].heldForReview = true
        community[i].screening = PlaceScreening(state: .held, reasons: community[i].screening?.reasons ?? [], canAppeal: false, appealed: true)
        return community[i]
    }

    static func similar(_ a: String, _ b: String) -> Bool {
        let x = a.lowercased().filter { $0.isLetter || $0.isNumber }, y = b.lowercased().filter { $0.isLetter || $0.isNumber }
        return x == y || (min(x.count, y.count) >= 5 && (x.contains(y) || y.contains(x)))
    }

    func updateCommunityPlace(id: String, _ new: NewPlace) async throws -> Place {
        guard myPlaceIds.contains(id), let i = community.firstIndex(where: { $0.id == id }) else { throw APIError.http(status: 403, problem: nil) }
        community[i].name = new.name
        community[i].category = new.category
        community[i].lat = new.lat
        community[i].lng = new.lng
        community[i].phone = new.phone
        community[i].website = new.website
        community[i].openingHours = new.openingHours
        community[i].description = new.description
        community[i].amenities = new.amenities
        community[i].warnings = new.warnings
        // A changed place is checked again ("Edit and try again" on a rejected one).
        if community[i].status != .published {
            apply(DemoScreening.verdict(name: new.name, description: new.description, emas: user.tier == .emas), to: &community[i], now: .now)
        }
        return community[i]
    }

    func deleteCommunityPlace(id: String) async throws {
        guard myPlaceIds.contains(id), let i = community.firstIndex(where: { $0.id == id }) else { throw APIError.http(status: 403, problem: nil) }
        if community[i].status == .published { community[i].status = .closed } else { community.remove(at: i) }
    }

    func suggestEdit(placeId: String, _ s: PlaceEditSuggestion) async throws -> SuggestionAccepted {
        await pause()
        return SuggestionAccepted(suggestionId: "demo-sugg-\(UUID().uuidString.prefix(6))")
    }

    private var demoVotes: Set<String> = []

    func verifyPlace(id: String, _ v: VerifyPlaceRequest) async throws -> VerifyResult {
        if myPlaceIds.contains(id) {
            throw APIError.http(status: 403, problem: ProblemDetails(title: "Forbidden", status: 403, detail: "You can't verify your own place."))
        }
        guard !demoVotes.contains(id) else {
            throw APIError.http(status: 409, problem: ProblemDetails(title: "Already voted", status: 409, detail: "You already answered for this place."))
        }
        guard let i = community.firstIndex(where: { $0.id == id }) else { throw APIError.http(status: 404, problem: nil) }
        let cell = Geohash.encode(lat: community[i].lat, lng: community[i].lng)
        guard v.proximity.cell.prefix(4) == cell.prefix(4) else {
            throw APIError.http(status: 403, problem: ProblemDetails(title: "Too far", status: 403, detail: "You need to be near the place to confirm it."))
        }
        demoVotes.insert(id)
        let p = try confirm(id: id, answer: v.answer, locationCorrect: v.locationCorrect)
        return VerifyResult(status: p.status ?? .pending, confirmationsWeighted: Double(p.verifiedCount ?? 0), required: 3)
    }

    func pendingNearby(cell: String) async throws -> [PlaceSummary] {
        settleChecks()
        return community.filter { $0.status == .pending && $0.screening?.state != .checking && !myPlaceIds.contains($0.id) && !demoVotes.contains($0.id)
            && Geohash.encode(lat: $0.lat, lng: $0.lng).prefix(5) == cell.prefix(5) }.map(\.summary)
    }

    // MARK: complaints (demo)

    private(set) var issues: [Issue] = []

    func createIssue(_ n: NewIssue) async throws -> Issue {
        // Dedupe within 50 m of the same kind (the server merges into the existing issue).
        if let i = issues.firstIndex(where: { $0.kind == n.kind && $0.placeId == n.placeId
            && Geo.distance($0.location, LatLng(lat: n.lat, lng: n.lng)) < 50 && $0.state.isOpen }) {
            issues[i].confirmations = (issues[i].confirmations ?? 1) + 1
            if (issues[i].confirmations ?? 0) >= 2 { issues[i].state = .confirmed }
            return issues[i]
        }
        let issue = Issue(id: "demo-issue-\(issues.count + 1)", kind: n.kind, subtype: n.subtype, state: .suspected, lat: n.lat, lng: n.lng,
                          placeId: n.placeId, roadName: n.payload?["roadName"], summary: nil, confirmations: 1, required: 2,
                          createdAt: .now, expiresAt: nil, lastEvidenceAt: .now, until: nil,
                          payload: n.payload?["until"].map { IssuePayload(until: $0) })
        issues.append(issue)
        return issue
    }

    func issuesNearby(bbox: BBox, kinds: [IssueKind]?) async throws -> [Issue] {
        issues.filter { $0.state.isOpen && bbox.contains($0.location) && (kinds == nil || kinds!.contains($0.kind)) }
    }

    func voteIssue(id: String, _ vote: IssueVote) async throws -> Issue {
        guard let i = issues.firstIndex(where: { $0.id == id }) else { throw APIError.http(status: 404, problem: nil) }
        switch vote.answer {
        case .still:
            issues[i].confirmations = (issues[i].confirmations ?? 1) + 1
            if (issues[i].confirmations ?? 0) >= 2 { issues[i].state = .confirmed }
        case .cleared: issues[i].state = .refuted
        case .unsure: break
        }
        return issues[i]
    }

    /// Demo: seed an issue (UI tests / screenshots).
    func seedIssue(_ issue: Issue) { issues.append(issue) }

    func attestChallenge() async throws -> String { Data((0..<32).map { _ in UInt8.random(in: 0...255) }).base64EncodedString() }
    func attest(keyId: String, attestation: String) async throws {}

    /// Demo only: other drivers confirming a place (the owner can't).
    func simulateOtherDriversVerify(placeId: String, count: Int) throws {
        for _ in 0..<count { _ = try confirm(id: placeId, answer: .yes, locationCorrect: true) }
    }

    /// Demo only: a pending place added by someone else near `at` (for the nearby verify prompt).
    func seedPendingPlace(name: String, at: LatLng) -> String {
        let id = "demo-pending-\(UUID().uuidString.prefix(6))"
        community.append(Place(id: id, name: name, category: .restaurant, address: "Jalan Sultan Ismail", lat: at.lat, lng: at.lng,
                               openingHours: "Mo-Sa 07:00-14:00", source: .community, status: .pending,
                               addedBy: PersonRef(displayName: "Rusa 2368"), verifiedCount: 1))
        return id
    }

    private func confirm(id: String, answer: VoteAnswer, locationCorrect: Bool?) throws -> Place {
        guard let i = community.firstIndex(where: { $0.id == id }) else { throw APIError.http(status: 404, problem: nil) }
        if answer == .yes && locationCorrect != false {
            community[i].verifiedCount = (community[i].verifiedCount ?? 0) + 1
            if (community[i].verifiedCount ?? 0) >= 3 { community[i].status = .published }
        }
        return community[i]
    }

    func myContributions() async throws -> [PlaceSummary] {
        settleChecks()
        return community.filter { myPlaceIds.contains($0.id) }.map(\.summary)
    }

    // MARK: reviews & photos (demo)

    func reviews(placeId: String, sort: ReviewSort, cursor: String?) async throws -> ReviewsPage {
        settleContent()
        // Every demo place starts with one sample review by another (sample) contributor, so reporting and blocking
        // can be tried in Demo mode. It stays in this demo store.
        if reviewsByPlace[placeId] == nil {
            reviewsByPlace[placeId] = [Review(id: "demo-sample-\(placeId)", placeId: placeId, rating: 4, text: String(localized: "Sample review (demo data)."),
                                              photos: nil, author: PersonRef(displayName: "Kancil 2041", level: 2, reviewCount: 7, authorRef: "demo-author-kancil"),
                                              helpfulCount: 3, createdAt: Date().addingTimeInterval(-2 * 86400), editedAt: nil, status: nil)]
        }
        var r = (reviewsByPlace[placeId] ?? []).map { rv -> Review in
            var x = rv
            x.photos = rv.photos?.map { p in publishedPhotos(placeId).first { $0.id == p.id } ?? p }
            return x
        }
        r.sort { sort == .helpful ? $0.helpfulCount > $1.helpfulCount : $0.createdAt > $1.createdAt }
        return ReviewsPage(reviews: r, next: nil)
    }

    func createReview(placeId: String, _ new: NewReview) async throws -> Review {
        await pause()
        guard (1...5).contains(new.rating) else { throw APIError.http(status: 400, problem: nil) }
        if (reviewsByPlace[placeId] ?? []).contains(where: { $0.author.displayName == user.displayName }) {
            throw APIError.http(status: 409, problem: ProblemDetails(title: "One review per place"))
        }
        let verdict = try screen(new.text)
        let photos = publishedPhotos(placeId).filter { (new.photoIds ?? []).contains($0.id) }
        var r = Review(id: "demo-review-\(UUID().uuidString.prefix(8))", placeId: placeId, rating: new.rating, text: new.text, photos: photos,
                       author: me, helpfulCount: 0, createdAt: .now, editedAt: nil, status: "published")
        apply(verdict, to: &r)
        reviewsByPlace[placeId, default: []].insert(r, at: 0)
        user.points = (user.points ?? 0) + 3
        return r
    }

    /// 403 posting_paused, then the check: a rejection throws 422 content_rejected (nothing stored); 3 in 24 h pause posting.
    private func screen(_ text: String?) throws -> DemoContentCheck.Verdict {
        let now = Date()
        if let until = postingPausedUntil, until > now {
            throw APIError.http(status: 403, problem: ProblemDetails(title: "Posting paused", status: 403, code: "posting_paused", pausedUntil: JSON.makeISO(until)))
        }
        let v = DemoContentCheck.verdict(text: text)
        if v.state == .rejected {
            contentRejections.removeAll { now.timeIntervalSince($0) > 86400 }
            contentRejections.append(now)
            if contentRejections.count >= 3 { postingPausedUntil = now.addingTimeInterval(86400) }
            throw APIError.http(status: 422, problem: ProblemDetails(title: "Not accepted", status: 422, code: "content_rejected",
                                                                     reasons: v.reasons, safeText: v.safeText))
        }
        return v
    }

    private func apply(_ v: DemoContentCheck.Verdict, to r: inout Review) {
        switch v.state {
        case .held:
            r.status = "hidden"; r.heldForReview = true
            r.moderation = ContentModeration(state: .held, reasons: v.reasons, canAppeal: true)
        case .checking:
            r.status = "hidden"
            r.moderation = ContentModeration(state: .checking)
            reviewChecking[r.id] = Date().addingTimeInterval(DemoContentCheck.slowCheck)
        default:
            r.moderation = ContentModeration(state: .passed, reasons: ["ok"])
        }
    }

    /// Finishes `#slow` reviews: published, with a content_published note in the Inbox.
    private func settleContent(now: Date = .now) {
        for (id, until) in reviewChecking where until <= now {
            reviewChecking[id] = nil
            for pid in reviewsByPlace.keys {
                guard let i = reviewsByPlace[pid]!.firstIndex(where: { $0.id == id }) else { continue }
                reviewsByPlace[pid]![i].status = "published"
                reviewsByPlace[pid]![i].moderation = ContentModeration(state: .passed, reasons: ["ok"])
                contentInbox.append(InboxItem(id: "demo-content-\(id)", kind: .contentPublished, title: String(localized: "Your review is up"),
                                              body: nil, refType: "review", refId: id, createdAt: now, read: nil, count: nil,
                                              subjectKind: "review", subjectId: id, placeId: pid, reasons: ["ok"], canAppeal: false))
            }
        }
    }

    /// Demo only: finish every `checking` review now (tests).
    func finishContentChecksNow() { settleContent(now: .distantFuture) }

    func updateReview(id: String, _ new: NewReview) async throws -> Review {
        for (pid, list) in reviewsByPlace {
            if let i = list.firstIndex(where: { $0.id == id }) {
                var r = list[i]
                let verdict = try screen(new.text)
                r.rating = new.rating
                r.text = new.text
                apply(verdict, to: &r)
                if let ids = new.photoIds { r.photos = publishedPhotos(pid).filter { ids.contains($0.id) } }
                r.editedAt = .now
                reviewsByPlace[pid]![i] = r
                return r
            }
        }
        throw APIError.http(status: 404, problem: nil)
    }

    func deleteReview(id: String) async throws {
        for pid in reviewsByPlace.keys { reviewsByPlace[pid]!.removeAll { $0.id == id } }
    }

    func toggleHelpful(reviewId: String) async throws {
        let on = !helpful.contains(reviewId)
        if on { helpful.insert(reviewId) } else { helpful.remove(reviewId) }
        for pid in reviewsByPlace.keys {
            if let i = reviewsByPlace[pid]!.firstIndex(where: { $0.id == reviewId }) { reviewsByPlace[pid]![i].helpfulCount += on ? 1 : -1 }
        }
    }

    func flagReview(id: String, reason: FlagReason) async throws {}

    func appealReview(id: String, note: String?) async throws {
        await pause()
        for pid in reviewsByPlace.keys {
            guard let i = reviewsByPlace[pid]!.firstIndex(where: { $0.id == id }) else { continue }
            guard reviewsByPlace[pid]![i].moderation?.canAppeal != false else { throw APIError.conflict(Data(#"{"status":409,"title":"Conflict"}"#.utf8)) }
            reviewsByPlace[pid]![i].heldForReview = true
            reviewsByPlace[pid]![i].moderation = ContentModeration(state: .held, reasons: reviewsByPlace[pid]![i].moderation?.reasons ?? [], canAppeal: false)
            return
        }
        throw APIError.http(status: 404, problem: nil)
    }

    func appealPhoto(id: String, note: String?) async throws {
        await pause()
        guard photoVerdicts[id] != nil else { throw APIError.http(status: 404, problem: nil) }
        photoVerdicts[id] = DemoContentCheck.Verdict(state: .held, reasons: photoVerdicts[id]?.reasons ?? [])
        appealedPhotos.insert(id)
    }

    /// Stores the photo as WebP (like the server) and serves it from a local file URL ending in .webp.
    func uploadPhoto(_ jpeg: Data, placeId: String, caption: String?, progress: @escaping @Sendable (Double) -> Void) async throws -> Photo {
        for step in 1...5 {
            try? await Task.sleep(for: .milliseconds(80))
            progress(Double(step) / 5)
        }
        guard let webp = ImageProcessing.webp(jpeg, maxPixels: 1600, quality: 80),
              let thumb = ImageProcessing.webp(jpeg, maxPixels: 400, quality: 70) else { throw APIError.http(status: 400, problem: nil) }
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("demo-media", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let id = UUID().uuidString.lowercased()
        let full = dir.appendingPathComponent("\(id).webp"), small = dir.appendingPathComponent("\(id)-thumb.webp")
        try webp.write(to: full)
        try thumb.write(to: small)
        let size = ImageProcessing.pixelSize(webp) ?? .zero
        let photo = Photo(id: id, url: full.absoluteString, thumbUrl: small.absoluteString, width: Int(size.width), height: Int(size.height),
                          caption: caption, uploadedBy: PersonRef(displayName: user.displayName), createdAt: .now, status: .processing)
        photosByPlace[placeId, default: []].insert((photo, Date().addingTimeInterval(1.5)), at: 0)
        photoVerdicts[id] = DemoContentCheck.photoVerdict(caption: caption)
        if let i = community.firstIndex(where: { $0.id == placeId }), community[i].thumbnailUrl == nil { community[i].thumbnailUrl = photo.thumbUrl }
        user.points = (user.points ?? 0) + 2
        return photo
    }

    func photos(placeId: String, cursor: String?) async throws -> PhotosPage {
        PhotosPage(photos: publishedPhotos(placeId), next: nil)
    }

    func deletePhoto(id: String) async throws {
        for pid in photosByPlace.keys { photosByPlace[pid]!.removeAll { $0.photo.id == id } }
    }

    func flagPhoto(id: String, reason: FlagReason) async throws {}

    // MARK: inbox (demo: derived from the demo user's own contributions)

    private var inboxReadUpTo: Date = .distantPast

    func inbox(cursor: String?) async throws -> InboxPage {
        settleChecks()
        var items: [InboxItem] = [InboxItem(id: "demo-ann-1", kind: .announcement, title: "Selamat datang ke Gimano!",
                                            body: "Laporkan trafik dan tambah tempat untuk membantu pemandu lain.",
                                            refType: "url", refId: "https://www.bukitbunga.com/gimano", createdAt: Date(timeIntervalSince1970: 1_792_000_000),
                                            read: nil, count: nil)]
        for p in community where myPlaceIds.contains(p.id) && p.status == .published {
            items.append(InboxItem(id: "demo-pub-\(p.id)", kind: .placePublished, title: "\(p.name) is now on the map",
                                   body: "\(p.verifiedCount ?? 3) drivers confirmed it.", refType: "place", refId: p.id,
                                   createdAt: .now.addingTimeInterval(-60), read: nil, count: nil))
        }
        items += screeningInbox
        settleContent()
        items += contentInbox
        for list in photosByPlace.values {
            for item in list where Date() >= item.readyAt && !notedPhotos.contains(item.photo.id) {
                guard let v = photoVerdicts[item.photo.id], v.state == .rejected else { continue }
                notedPhotos.insert(item.photo.id)
                contentInbox.append(InboxItem(id: "demo-content-\(item.photo.id)", kind: .contentRejected, title: String(localized: "A photo wasn't accepted"),
                                              body: nil, refType: "photo", refId: item.photo.id, createdAt: .now, read: nil, count: nil,
                                              subjectKind: "photo", subjectId: item.photo.id, placeId: nil, reasons: v.reasons, canAppeal: true))
                items.append(contentInbox[contentInbox.count - 1])
            }
        }
        let helpfulMine = reviewsByPlace.values.flatMap { $0 }.filter { $0.author.displayName == user.displayName }.map(\.helpfulCount).reduce(0, +)
        if helpfulMine > 0 {
            items.append(InboxItem(id: "demo-helpful", kind: .reviewHelpful, title: "\(helpfulMine) drivers found your review helpful",
                                   body: nil, refType: nil, refId: nil, createdAt: .now.addingTimeInterval(-30), read: nil, count: helpfulMine))
        }
        items.sort { $0.createdAt > $1.createdAt }
        for i in items.indices { items[i].read = items[i].createdAt <= inboxReadUpTo }
        return InboxPage(items: items, next: nil, unread: items.filter { $0.read != true }.count)
    }

    func markInboxRead(upTo: Date) async throws { inboxReadUpTo = max(inboxReadUpTo, upTo) }

    // MARK: shares (demo relay: keeps only the latest ciphertext, like the server)

    private var shares: [String: (token: String, expiresAt: Date, blob: ShareBlob?)] = [:]

    func createShare(_ r: ShareCreateRequest) async throws -> ShareCreated {
        guard (15...720).contains(r.expiresInMinutes) else { throw APIError.http(status: 400, problem: nil) }
        guard shares.values.filter({ $0.expiresAt > .now }).count < 3 else { throw APIError.http(status: 429, problem: nil) }
        let id = ShareCrypto.base64url([UInt8]((0..<16).map { _ in UInt8.random(in: 0...255) }))
        let token = ShareCrypto.base64url([UInt8]((0..<32).map { _ in UInt8.random(in: 0...255) }))
        let exp = Date().addingTimeInterval(TimeInterval(r.expiresInMinutes * 60))
        shares[id] = (token, exp, nil)
        return ShareCreated(shareId: id, writeToken: token, expiresAt: exp)
    }

    func putShare(id: String, writeToken: String, _ blob: ShareBlob) async throws {
        guard let s = shares[id], s.token == writeToken else { throw APIError.http(status: 403, problem: nil) }
        guard Data(base64Encoded: blob.ciphertext).map({ $0.count <= 1024 }) ?? false else { throw APIError.http(status: 413, problem: nil) }
        shares[id]?.blob = blob
    }

    func deleteShare(id: String, writeToken: String) async throws {
        guard shares[id]?.token == writeToken else { throw APIError.http(status: 403, problem: nil) }
        shares[id] = nil
    }

    /// What a viewer would GET (test hook).
    func sharedBlob(_ id: String) -> ShareBlob? { shares[id]?.blob }

    func reverseGeocode(_ p: LatLng) async throws -> ReverseGeocode {
        let nearest = DemoData.places.min { Geo.distance(p, $0.location) < Geo.distance(p, $1.location) }
        let close = nearest.flatMap { Geo.distance(p, $0.location) <= 50 ? $0 : nil }
        return ReverseGeocode(name: nil, address: "Near \(nearest?.name ?? "Kuala Lumpur")", lat: p.lat, lng: p.lng,
                              nearby: close.map { [$0] })
    }

    // MARK: routing

    func routes(_ request: RouteRequest) async throws -> [Route] {
        await pause()
        let o = LatLng(lat: request.origin.lat, lng: request.origin.lng)
        let d = LatLng(lat: request.destination.lat, lng: request.destination.lng)
        var routes: [Route]
        let canned = CannedRoutes.shared
        if let exact = canned.match(origin: o, destination: d) {
            // Real road geometry (OSM/OSRM fixture) so demo drives stay on roads.
            routes = DemoRouteBuilder.decorate(exact, vehicle: request.vehicle, avoid: request.avoid, departAt: request.departAt,
                                               seed: routeCounter, alerts: reports)
            if !request.waypoints.isEmpty {
                // Stops are honoured only when they lie on the captured road; otherwise say so instead of inventing a detour.
                let stops = request.waypoints.map { (LatLng(lat: $0.lat, lng: $0.lng), $0.name) }
                let onRoad = routes.compactMap { DemoRouteBuilder.splitIntoLegs($0, stops: stops) }
                if onRoad.isEmpty {
                    for i in routes.indices {
                        routes[i].demoNote = String(localized: "Demo route: these stops aren't on a captured demo road, so they are skipped.")
                    }
                } else {
                    routes = onRoad
                }
            }
        } else if let nearest = canned.nearest(to: d) {
            // No captured route for this trip: never fabricate geometry — offer the nearest captured route, labelled.
            let place = DemoData.places.min { Geo.distance($0.location, LatLng(lat: nearest.lat, lng: nearest.lng)) < Geo.distance($1.location, LatLng(lat: nearest.lat, lng: nearest.lng)) }
            let name = place?.name ?? nearest.key
            routes = DemoRouteBuilder.decorate(nearest.routes, vehicle: request.vehicle, avoid: request.avoid, departAt: request.departAt,
                                               seed: routeCounter, alerts: reports)
            for i in routes.indices {
                routes[i].demoNote = String(localized: "Demo route: no captured route for this trip. Showing the nearest one, to \(name).")
            }
        } else {
            throw APIError.notAvailable
        }
        routeCounter += 1
        routes = Array(routes.prefix(max(1, request.alternatives + 1)))
        for r in routes { routeDestinations[r.id] = (request.destination, request.waypoints, request.vehicle, request.avoid) }
        return routes
    }

    func reroute(routeId: String, _ request: RerouteRequest) async throws -> [Route] {
        guard let ctx = routeDestinations[routeId] else { throw APIError.http(status: 404, problem: nil) }
        let remaining = Array(ctx.waypoints.dropFirst(min(request.nextStopIndex ?? 0, ctx.waypoints.count)))
        let req = RouteRequest(origin: RouteEndpoint(lat: request.lat, lng: request.lng), destination: ctx.dest, waypoints: remaining,
                               vehicle: ctx.vehicle, avoid: ctx.avoid, alternatives: 0)
        return try await routes(req)
    }

    func departureTimes(origin: LatLng, destination: LatLng, date: Date, vehicle: Vehicle) async throws -> [DepartureSlot] {
        await pause()
        let base = Geo.distance(origin, destination) * 1.3 / ((vehicle == .motorcycle ? 46 : 40) / 3.6)
        let start = Calendar.current.date(bySetting: .minute, value: 0, of: date) ?? date
        return (0..<16).map { i in
            let t = start.addingTimeInterval(Double(i) * 1800)
            let hour = Double(Calendar.current.component(.hour, from: t))
            // Rush hours around 08:00 and 18:00.
            let rush = exp(-pow(hour - 8, 2) / 3) + exp(-pow(hour - 18, 2) / 3)
            return DepartureSlot(departAt: t, durationS: base * (1 + 0.8 * rush))
        }
    }

    // MARK: live

    func live(bbox: BBox) async throws -> LiveResponse {
        let now = Date()
        reports.removeAll { $0.expiresAt < now }
        let center = LatLng(lat: (bbox.minLat + bbox.maxLat) / 2, lng: (bbox.minLng + bbox.maxLng) / 2)
        var gen = SeededGenerator(seed: UInt64(abs(Int(center.lat * 100)) * 1000 + abs(Int(center.lng * 100))))
        // Other drivers are placed on real road vertices inside the viewport.
        let onRoad = CannedRoutes.shared.roadVertices.filter { bbox.contains($0.point) }
        let drivers: [Driver] = onRoad.isEmpty ? [] : (0..<min(18, onRoad.count)).map { _ in
            let v = onRoad.randomElement(using: &gen)!
            return Driver(lat: v.point.lat, lng: v.point.lng, heading: v.bearing, mood: ["🙂", "😎", "😴", "🤠", "😇"].randomElement(using: &gen))
        }
        return LiveResponse(alerts: reports.filter { bbox.contains($0.location) }, jams: DemoData.jams, drivers: drivers, serverTime: now)
    }

    func createReport(_ new: NewReport) async throws -> Report {
        await pause()
        let ttl: TimeInterval = switch new.type {
        case .police: 30 * 60
        case .traffic: 20 * 60
        case .closure: 24 * 3600
        case .weather: 120 * 60
        default: 60 * 60
        }
        var r = Report(id: "demo-\(UUID().uuidString.prefix(8))", type: new.type, subtype: new.subtype, lat: new.lat, lng: new.lng,
                       heading: new.heading, street: nil, reportedBy: ReportAuthor(displayName: user.displayName, mood: user.mood),
                       createdAt: .now, expiresAt: .now.addingTimeInterval(ttl), confirmations: 1, thanks: 0)
        // A note that looks like an advert is dropped; the report still goes out (docs/content-safety.md "Report notes").
        if let note = new.comment, DemoContentCheck.verdict(text: note).state == .rejected {
            r.noteDropped = true
            r.noteReasons = DemoContentCheck.verdict(text: note).reasons
        }
        reports.append(r)
        user.points = (user.points ?? 0) + 6
        return r
    }

    func deleteReport(id: String) async throws {
        guard let i = reports.firstIndex(where: { $0.id == id }) else { throw APIError.http(status: 404, problem: nil) }
        reports.remove(at: i)
        user.points = max(0, (user.points ?? 0) - 6)
    }

    func vote(reportId: String, stillThere: Bool) async throws -> Report {
        guard let i = reports.firstIndex(where: { $0.id == reportId }) else { throw APIError.http(status: 404, problem: nil) }
        if stillThere {
            reports[i].confirmations += 1
            reports[i].expiresAt = reports[i].expiresAt.addingTimeInterval(15 * 60)
        } else {
            reports[i].expiresAt = reports[i].expiresAt.addingTimeInterval(-20 * 60)
        }
        return reports[i]
    }

    func thank(reportId: String) async throws {
        if let i = reports.firstIndex(where: { $0.id == reportId }) { reports[i].thanks += 1 }
    }

    func sendLocations(_ batch: LocationBatch) async throws {}

    func sendFeedback(_ f: FeedbackRequest) async throws -> FeedbackCreated {
        await pause()
        guard FeedbackRules.validate(message: f.message) else { throw APIError.http(status: 400, problem: ProblemDetails(title: "Invalid message")) }
        let item = FeedbackSummary(id: "demo-fb-\(UUID().uuidString.prefix(8))", category: f.category, message: f.message, status: .received,
                                   createdAt: .now, hasContact: f.contact != nil)
        feedback.insert(item, at: 0)
        return FeedbackCreated(id: item.id, createdAt: item.createdAt)
    }

    func myFeedback() async throws -> [FeedbackSummary] { feedback }

    func deleteCrashContact(id: String, contactToken: String) async throws {}
    func flagPlace(id: String, reason: FlagReason) async throws {}

    func deleteFeedbackContact(id: String, contactToken: String?) async throws {
        if let i = feedback.firstIndex(where: { $0.id == id }) { feedback[i].hasContact = false }
    }

    private(set) var crashReports: [CrashReport] = []
    func sendCrashReport(_ report: CrashReport) async throws -> CrashCreated {
        crashReports.append(report)
        return CrashCreated(id: "demo-crash-\(crashReports.count)", signature: nil)
    }

    func health() async -> Bool { true }
}

/// Deterministic RNG so demo drivers don't jump around between polls of the same area.
struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed &+ 0x9E37_79B9_7F4A_7C15 }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// Decorates captured real-road demo routes per request. Demo mode never fabricates route geometry.
enum DemoRouteBuilder {
    /// Applies per-request decoration to canned real-road routes: unique ids, traffic factor, avoid-tolls,
    /// localized instructions and alerts projected onto the geometry.
    static func decorate(_ canned: [Route], vehicle: Vehicle, avoid: AvoidOptions, departAt: Date?, seed: Int, alerts: [Report]) -> [Route] {
        let descriptions: [LocalizedStringResource] = ["Typical traffic", "Heavier than usual", "Light traffic"]
        var routes: [Route] = []
        for (i, base) in canned.enumerated() {
            if vehicle.isMotorized && avoid.tolls && base.hasTolls { continue }
            var r = base
            r.id = "\(base.id)-\(seed)"
            r.vehicle = vehicle
            // Walking/cycling reuse the captured roads (never invented paths) with mode speeds and no tolls/traffic.
            if !vehicle.isMotorized {
                let speedKmh = vehicle == .walk ? 4.8 : 15.0
                r.durationS = r.distanceM / (speedKmh / 3.6)
                r.hasTolls = false
                r.trafficSegments = []
            }
            var factor = vehicle.isMotorized ? [1.12, 1.25, 1.35][i % 3] * (vehicle == .motorcycle ? 0.85 : 1) : 1
            if let departAt {
                let hour = Double(Calendar.current.component(.hour, from: departAt))
                factor *= 1 + 0.4 * (exp(-pow(hour - 8, 2) / 3) + exp(-pow(hour - 18, 2) / 3)) - 0.1
            }
            r.trafficDurationS = r.durationS * factor
            r.trafficDescription = vehicle.isMotorized ? String(localized: descriptions[i % 3]) : nil
            (r.tolls, r.tollEstimateMyr, r.tollFareComplete) = demoTolls(for: r, vehicle: vehicle)
            var legs = r.legs
            for li in legs.indices {
                for mi in legs[li].maneuvers.indices {
                    legs[li].maneuvers[mi].instruction = ManeuverFormatter.instruction(for: legs[li].maneuvers[mi], mode: vehicle)
                }
            }
            r.legs = legs
            let pts = Polyline.decode(r.polyline)
            r.alerts = alertsOnRoute(pts, alerts: alerts)
            routes.append(r)
        }
        if routes.isEmpty { return decorate(canned, vehicle: vehicle, avoid: AvoidOptions(), departAt: departAt, seed: seed, alerts: alerts) }
        routes.sort { $0.effectiveDurationS < $1.effectiveDurationS }
        for i in routes.indices { routes[i].label = i == 0 ? "best" : "alternative" }
        return routes
    }

    /// Demo-only toll plazas: one per expressway the route enters, placed on the route vertex where the expressway
    /// maneuver begins (on-road). Fares come from a tiny demo table and are labelled as demo data, not real tariffs.
    static let demoFares: [String: Double] = ["E10": 1.60, "E23": 2.50, "E11": 2.10]

    static func demoTolls(for r: Route, vehicle: Vehicle) -> ([TollPlaza], Double?, Bool) {
        guard vehicle.isMotorized, r.hasTolls else { return ([], nil, false) }
        let pts = Polyline.decode(r.polyline)
        var seen = Set<String>()
        var plazas: [TollPlaza] = []
        for m in r.maneuvers {
            guard let ref = m.roadRef, ref.hasPrefix("E"), ref.dropFirst().allSatisfy(\.isNumber), !seen.contains(ref),
                  pts.indices.contains(m.beginShapeIndex) else { continue }
            seen.insert(ref)
            let p = pts[m.beginShapeIndex]
            let fare: Double? = vehicle == .motorcycle ? (demoFares[ref] == nil ? nil : 0) : demoFares[ref]
            plazas.append(TollPlaza(plazaId: "demo-\(ref)", name: "Plaza Tol \(ref) (demo)", highway: [ref, m.streetName].compactMap { $0 }.joined(separator: " "),
                                    lat: p.lat, lng: p.lng, fareMyr: fare, system: "open", source: "Demo data, not a real tariff"))
        }
        if plazas.isEmpty { return ([], nil, false) }
        let known = plazas.compactMap(\.fareMyr)
        return (plazas, known.isEmpty ? nil : known.reduce(0, +), known.count == plazas.count)
    }

    /// Splits a captured route into legs at the given stops when every stop lies within 300 m of the road.
    /// Returns nil when a stop is off the captured road (demo never invents a detour).
    static func splitIntoLegs(_ route: Route, stops: [(LatLng, String?)], within: Double = 300) -> Route? {
        let pts = Polyline.decode(route.polyline)
        guard pts.count > 2 else { return nil }
        let cum = Geo.cumulativeDistances(pts)
        var idx: [Int] = []
        var from = 0
        for (s, _) in stops {
            var best = (d: Double.infinity, i: from)
            for i in from..<pts.count {
                let d = Geo.distance(s, pts[i])
                if d < best.d { best = (d, i) }
            }
            guard best.d <= within, best.i > from, best.i < pts.count - 1 else { return nil }
            idx.append(best.i)
            from = best.i
        }
        let all = route.maneuvers
        var legs: [RouteLeg] = []
        var start = 0
        let scale = route.distanceM > 0 ? 1.0 : 0
        for (k, end) in (idx + [pts.count - 1]).enumerated() {
            var ms = all.filter { $0.beginShapeIndex >= start && $0.beginShapeIndex < end && !($0.type == .arrive) }
            if k > 0 {
                ms.removeAll { $0.type == .depart }
                ms.insert(Maneuver(type: .depart, instruction: "", streetName: ms.first?.streetName, distanceM: 0, durationS: 0,
                                   beginShapeIndex: start, endShapeIndex: ms.first?.beginShapeIndex ?? end), at: 0)
            }
            ms.append(Maneuver(type: .arrive, instruction: "", distanceM: 0, durationS: 0, beginShapeIndex: end, endShapeIndex: end))
            for j in 0..<(ms.count - 1) { ms[j].endShapeIndex = ms[j + 1].beginShapeIndex }
            let legM = cum[end] - cum[start]
            let name = k < stops.count ? stops[k].1 : nil
            legs.append(RouteLeg(durationS: route.durationS * legM / max(1, cum.last ?? 1) * scale, distanceM: legM,
                                 to: LegEnd(lat: pts[end].lat, lng: pts[end].lng, name: name), maneuvers: ms))
            start = end
        }
        var r = route
        r.legs = legs
        return r
    }

    static func alertsOnRoute(_ pts: [LatLng], alerts: [Report], within: Double = 120) -> [AlertOnRoute] {
        guard pts.count > 1 else { return [] }
        let cum = Geo.cumulativeDistances(pts)
        return alerts.compactMap { a in
            var best = (d: Double.infinity, along: 0.0)
            for k in 0..<(pts.count - 1) {
                let pr = Geo.project(a.location, onto: pts[k], pts[k + 1])
                if pr.distanceM < best.d { best = (pr.distanceM, cum[k] + (cum[k + 1] - cum[k]) * pr.t) }
            }
            return best.d < within ? AlertOnRoute(report: a, distanceAlongRouteM: best.along) : nil
        }
    }

}

enum DemoData {
    static let places: [PlaceSummary] = [
        p("demo:klcc", "Suria KLCC", .mall, "Jalan Ampang, 50088 Kuala Lumpur", 3.1579, 101.7123),
        p("demo:pavilion", "Pavilion Kuala Lumpur", .mall, "168 Jalan Bukit Bintang, 55100 Kuala Lumpur", 3.1490, 101.7133),
        p("demo:midvalley", "Mid Valley Megamall", .mall, "Lingkaran Syed Putra, Mid Valley City, 59200 Kuala Lumpur", 3.1178, 101.6773),
        p("demo:1u", "1 Utama Shopping Centre", .mall, "Lebuh Bandar Utama, 47800 Petaling Jaya", 3.1502, 101.6152),
        p("demo:sunway", "Sunway Pyramid", .mall, "Jalan PJS 11/15, Bandar Sunway, 47500 Petaling Jaya", 3.0731, 101.6070),
        p("demo:masjidnegara", "Masjid Negara", .mosque, "Jalan Perdana, Tasik Perdana, 50480 Kuala Lumpur", 3.1420, 101.6918),
        p("demo:masjidwilayah", "Masjid Wilayah Persekutuan", .mosque, "Jalan Duta, 50480 Kuala Lumpur", 3.1716, 101.6680),
        p("demo:surau-ttdi", "Surau Al-Ikhlas TTDI", .surau, "Jalan Tun Mohd Fuad, Taman Tun Dr Ismail", 3.1395, 101.6310),
        p("demo:petronas-ampang", "PETRONAS Jalan Ampang", .fuel, "Jalan Ampang, 50450 Kuala Lumpur", 3.1606, 101.7240, brand: "PETRONAS"),
        p("demo:petronas-duta", "PETRONAS Jalan Duta", .fuel, "Jalan Duta, 50480 Kuala Lumpur", 3.1690, 101.6720, brand: "PETRONAS"),
        p("demo:shell-razak", "Shell Jalan Tun Razak", .fuel, "Jalan Tun Razak, 50400 Kuala Lumpur", 3.1640, 101.7190, brand: "Shell"),
        p("demo:petron-bangsar", "Petron Bangsar", .fuel, "Jalan Bangsar, 59200 Kuala Lumpur", 3.1290, 101.6790, brand: "Petron"),
        p("demo:bhp-damansara", "BHPetrol Damansara Heights", .fuel, "Jalan Semantan, 50490 Kuala Lumpur", 3.1470, 101.6590, brand: "BHPetrol"),
        p("demo:caltex-cheras", "Caltex Cheras", .fuel, "Jalan Cheras, 56100 Kuala Lumpur", 3.1050, 101.7300, brand: "Caltex"),
        p("demo:rnr-sgbuloh", "R&R Sungai Buloh", .restArea, "Lebuhraya Utara–Selatan (E1), Sungai Buloh", 3.2085, 101.5794),
        p("demo:rnr-seremban", "R&R Seremban", .restArea, "Lebuhraya Utara–Selatan (E2), Seremban", 2.7700, 101.9100),
        p("demo:hkl", "Hospital Kuala Lumpur", .hospital, "Jalan Pahang, 50586 Kuala Lumpur", 3.1715, 101.7004),
        p("demo:klsentral", "KL Sentral", .transitStation, "Jalan Stesen Sentral, 50470 Kuala Lumpur", 3.1340, 101.6862),
        p("demo:klia", "KLIA Terminal 1", .airport, "64000 Sepang, Selangor", 2.7456, 101.7072),
        p("demo:batucaves", "Batu Caves", .tourism, "Gombak, 68100 Batu Caves, Selangor", 3.2379, 101.6840),
        p("demo:pelita", "Restoran Nasi Kandar Pelita", .restaurant, "149 Jalan Ampang, 50450 Kuala Lumpur", 3.1588, 101.7166),
        p("demo:villagepark", "Village Park Restaurant", .restaurant, "Damansara Uptown, 47400 Petaling Jaya", 3.1356, 101.6237),
        p("demo:mamak-bangsar", "Restoran Rasa Utara Mamak", .restaurant, "Jalan Telawi, Bangsar Baru", 3.1305, 101.6710),
        p("demo:kopitiam", "Old Town Kopitiam Bukit Bintang", .cafe, "Jalan Bukit Bintang, 55100 Kuala Lumpur", 3.1466, 101.7101),
        p("demo:toll-sgbesi", "Plaza Tol Sungai Besi", .tollBooth, "Lebuhraya Utara–Selatan (E2), 57000 Kuala Lumpur", 3.0590, 101.7100),
        p("demo:ev-pavilion", "ChargEV Pavilion KL", .evCharging, "Pavilion KL P3, Jalan Bukit Bintang", 3.1488, 101.7140),
        p("demo:ev-midvalley", "DC Handal Mid Valley", .evCharging, "Mid Valley City, 59200 Kuala Lumpur", 3.1170, 101.6780),
        p("demo:park-klcc", "KLCC Parking", .parking, "Jalan Ampang, 50088 Kuala Lumpur", 3.1569, 101.7140),
        p("demo:police-dangwangi", "Balai Polis Dang Wangi", .police, "Jalan Stesen Sentral 2, 50470 Kuala Lumpur", 3.1554, 101.6981),
        p("demo:um", "Universiti Malaya", .university, "Lembah Pantai, 50603 Kuala Lumpur", 3.1209, 101.6538),
        p("demo:putrajaya", "Dataran Putra, Putrajaya", .government, "Persiaran Perdana, 62000 Putrajaya", 2.9360, 101.6897),
        p("demo:merdeka118", "Merdeka 118", .tourism, "Jalan Hang Jebat, 50150 Kuala Lumpur", 3.1415, 101.7005),
        p("demo:jalanalor", "Jalan Alor Food Street", .restaurant, "Jalan Alor, Bukit Bintang, 50200 Kuala Lumpur", 3.1456, 101.7088),
    ]

    private static func p(_ id: String, _ name: String, _ cat: PlaceCategory, _ addr: String, _ lat: Double, _ lng: Double, brand: String? = nil) -> PlaceSummary {
        PlaceSummary(id: id, name: name, category: cat, address: addr, lat: lat, lng: lng, distanceM: nil, brand: brand)
    }

    /// Demo jams are 300–800 m slices of captured real-road routes.
    static let jams: [Jam] = {
        let specs: [(String, Int, String, Int, Double, Double)] = [
            ("demo-j1", 3, "midvalley", 0, 0.30, 600),
            ("demo-j2", 2, "klcc", 0, 0.35, 500),
            ("demo-j3", 4, "home", 0, 0.50, 800),
            ("demo-j4", 1, "batucaves", 0, 0.40, 700),
            ("demo-j5", 2, "sunway", 0, 0.55, 800),
        ]
        return specs.compactMap { id, level, key, route, from, len in
            guard let slice = CannedRoutes.shared.slice(key: key, routeIndex: route, fromFraction: from, lengthM: len) else { return nil }
            return Jam(id: id, level: level, speedKmh: [0, 25, 15, 8, 2][level], delayS: Double(level) * 120,
                       lengthM: Geo.cumulativeDistances(slice.points).last ?? 0, polyline: Polyline.encode(slice.points), street: slice.street, updatedAt: .now)
        }
    }()
}

/// Real-road demo routes captured once from OpenStreetMap data (OSRM demo server, ODbL) into
/// `Resources/DemoRoutes.json`, in the Gimano `Route` contract shape (precision-6 polylines).
struct CannedRoutes: Sendable {
    struct Destination: Decodable, Sendable {
        var key: String
        var lat: Double
        var lng: Double
        var routes: [Route]
    }

    struct File: Decodable, Sendable {
        var attribution: String
        var origin: LatLng
        var destinations: [Destination]
    }

    let file: File?

    static let shared = CannedRoutes(bundle: .main)

    init(bundle: Bundle) {
        if let url = bundle.url(forResource: "DemoRoutes", withExtension: "json"), let data = try? Data(contentsOf: url) {
            file = try? JSON.makeDecoder().decode(File.self, from: data)
        } else {
            file = nil
        }
    }

    /// Captured destination closest to `destination` (used when no exact fixture matches).
    func nearest(to destination: LatLng) -> Destination? {
        file?.destinations.min { Geo.distance(destination, LatLng(lat: $0.lat, lng: $0.lng)) < Geo.distance(destination, LatLng(lat: $1.lat, lng: $1.lng)) }
    }

    func route(key: String, routeIndex: Int) -> Route? {
        guard let d = file?.destinations.first(where: { $0.key == key }), !d.routes.isEmpty else { return nil }
        return d.routes[min(routeIndex, d.routes.count - 1)]
    }

    private static func street(of route: Route, atVertex i: Int) -> String? {
        let m = route.maneuvers.last { $0.beginShapeIndex <= i && $0.type != .arrive }
        return m.flatMap { ManeuverFormatter.roadName($0) }
    }

    /// The route vertex at a fraction of the route length, with the street it is on.
    func vertex(key: String, routeIndex: Int, fraction: Double) -> (point: LatLng, street: String?)? {
        guard let r = route(key: key, routeIndex: routeIndex) else { return nil }
        let pts = Polyline.decode(r.polyline)
        let cum = Geo.cumulativeDistances(pts)
        guard let total = cum.last, total > 0 else { return nil }
        let target = total * fraction
        let i = cum.indices.min { abs(cum[$0] - target) < abs(cum[$1] - target) } ?? 0
        return (pts[i], Self.street(of: r, atVertex: i))
    }

    /// A stretch of a captured route between `fromFraction` and `fromFraction + lengthM` (points on the polyline).
    func slice(key: String, routeIndex: Int, fromFraction: Double, lengthM: Double) -> (points: [LatLng], street: String?)? {
        guard let r = route(key: key, routeIndex: routeIndex) else { return nil }
        let pts = Polyline.decode(r.polyline)
        let cum = Geo.cumulativeDistances(pts)
        guard let total = cum.last, total > lengthM else { return nil }
        let d0 = total * fromFraction, d1 = min(total, d0 + lengthM)
        let start = Geo.point(along: pts, cumulative: cum, distance: d0)
        let end = Geo.point(along: pts, cumulative: cum, distance: d1)
        var out = [start.point]
        for i in pts.indices where cum[i] > d0 && cum[i] < d1 { out.append(pts[i]) }
        out.append(end.point)
        return (out, Self.street(of: r, atVertex: start.segment))
    }

    /// Every vertex of every captured route with its travel bearing (for placing demo drivers on roads).
    var roadVertices: [(point: LatLng, bearing: Double)] {
        guard let file else { return [] }
        return file.destinations.flatMap(\.routes).flatMap { r -> [(point: LatLng, bearing: Double)] in
            let pts = Polyline.decode(r.polyline)
            guard pts.count > 1 else { return [] }
            return stride(from: 0, to: pts.count - 1, by: 3).map { (pts[$0], Geo.bearing(pts[$0], pts[$0 + 1])) }
        }
    }

    /// All captured route polylines, decoded.
    var allPolylines: [[LatLng]] {
        file?.destinations.flatMap(\.routes).map { Polyline.decode($0.polyline) } ?? []
    }

    /// Canned alternatives when the request starts near the fixture origin and ends near a fixture destination.
    func match(origin: LatLng, destination: LatLng, originToleranceM: Double = 500, destinationToleranceM: Double = 400) -> [Route]? {
        guard let file, Geo.distance(origin, file.origin) <= originToleranceM else { return nil }
        let best = file.destinations.min { Geo.distance(destination, LatLng(lat: $0.lat, lng: $0.lng)) < Geo.distance(destination, LatLng(lat: $1.lat, lng: $1.lng)) }
        guard let best, Geo.distance(destination, LatLng(lat: best.lat, lng: best.lng)) <= destinationToleranceM else { return nil }
        return best.routes
    }
}

/// The demo stand-in for the server's AI check. It never calls a model: a few keywords produce the outcomes the design
/// shows, so every screen can be seen offline (Developer settings → Data: Demo).
/// - adverts/scams/illegal/adult/gibberish → rejected (B3); "Rumah …" / "house of" → rejected private_home (B4);
///   CCTV / guards → held security (B2); `#slow` → checking (B6, live after 20 s); `#emas` or an Emas user → published (A5);
///   `#limit` → 429 (B5); `#paused` → 403 adding_paused (B5); a similar name within 100 m → 409 (B1); otherwise passed (A4).
enum DemoScreening {
    struct Verdict: Equatable {
        var state: ScreeningState
        var reasons: [String] = []
        var emas = false
    }

    static func verdict(name: String, description: String?, emas: Bool) -> Verdict {
        let text = (name + " " + (description ?? "")).lowercased()
        let n = name.lowercased().trimmingCharacters(in: .whitespaces)
        func has(_ words: [String]) -> Bool { words.contains { text.contains($0) } }
        if has(["#slow"]) { return Verdict(state: .checking) }
        if has(["pil kurus", "ubat kuat", "dadah", "ganja", "vape haram"]) { return Verdict(state: .rejected, reasons: ["illegal"]) }
        if has(["urut batin", "escort", "adult only"]) { return Verdict(state: .rejected, reasons: ["adult"]) }
        if has(["pelaburan", "investment", "skim cepat kaya", "double your money", "gandakan wang"]) { return Verdict(state: .rejected, reasons: ["scam"]) }
        if has(["forex", "untung rm", "whatsapp", "join group", "promo", "iklan", "kerja kosong", "job offer"]) {
            return Verdict(state: .rejected, reasons: ["spam"])
        }
        let letters = n.filter(\.isLetter)
        if letters.count < 2 || has(["asdf", "qwerty", "zxcv"]) || (letters.count >= 4 && !letters.contains(where: { "aeiou".contains($0) })) {
            return Verdict(state: .rejected, reasons: ["gibberish"])
        }
        if n.hasPrefix("rumah ") || has(["house of", "'s house", "my house", "rumah saya"]) {
            return Verdict(state: .rejected, reasons: ["private_home"])
        }
        if has(["cctv", "guard", "pengawal", "pintu belakang", "back entrance"]) { return Verdict(state: .held, reasons: ["security"]) }
        return Verdict(state: .passed, reasons: ["ok"], emas: emas || has(["#emas"]))
    }
}
