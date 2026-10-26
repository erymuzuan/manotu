import Foundation
import CoreLocation

// MARK: - Geometry

struct LatLng: Codable, Hashable, Sendable {
    var lat: Double
    var lng: Double

    init(lat: Double, lng: Double) {
        self.lat = lat
        self.lng = lng
    }

    init(_ c: CLLocationCoordinate2D) {
        self.lat = c.latitude
        self.lng = c.longitude
    }

    var coordinate: CLLocationCoordinate2D { .init(latitude: lat, longitude: lng) }
}

// MARK: - Auth & profile

struct DeviceAuthRequest: Codable, Sendable {
    var deviceId: String
    var platform: String = "ios"
    var locale: String
}

struct DeviceAuthResponse: Codable, Sendable {
    var token: String
    var userId: String
    var displayName: String
}

/// docs/identity-and-reputation.md §1
struct RegisterRequest: Codable, Sendable {
    var publicKey: String
    var platform: String = "ios"
    var locale: String
}
struct TokenRequest: Codable, Sendable { var userId: String; var ts: Int64; var sig: String }
struct TokenResponse: Codable, Sendable { var token: String }
struct KeyLoginRequest: Codable, Sendable { var publicKey: String; var ts: Int64; var sig: String }
struct AttachKeyRequest: Codable, Sendable { var publicKey: String; var sigByOldKey: String? }

/// Trust tier of the pseudonym (reputation describes public work, never the person).
enum Tier: String, Codable, Sendable, CaseIterable {
    case baharu, perak, emas
    init(from decoder: any Decoder) throws {
        self = Tier(rawValue: (try decoder.singleValueContainer().decode(String.self)).lowercased()) ?? .baharu
    }
}

struct NextTier: Codable, Sendable, Equatable {
    var name: Tier
    /// e.g. "placesAccepted:7", "accuracy:90", "accountDays:42", "signingKey", "noUpheldDispute90d".
    var missing: [String]
}

/// Travel mode (contract `vehicle`): car → auto, motorcycle, bicycle, walk → pedestrian.
enum Vehicle: String, Codable, Sendable, CaseIterable, Identifiable {
    case car
    case motorcycle
    case bicycle
    case walk
    var id: String { rawValue }

    /// Car and motorcycle use roads with tolls/expressways, live traffic and "avoid" options.
    var isMotorized: Bool { self == .car || self == .motorcycle }

    init(from decoder: any Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = Vehicle(rawValue: raw) ?? .car
    }
}

struct User: Codable, Sendable, Equatable {
    var id: String
    var displayName: String
    var mood: String?
    var vehicle: Vehicle?
    var points: Int?
    var level: Int?
    var joinedAt: Date?
    var tier: Tier?
    var accuracy: Double?
    var placesAccepted: Int?
    var verifierVotes: Int?
    var nextTier: NextTier?
    var suspendedUntil: Date?
}

struct UserPatch: Codable, Sendable {
    var displayName: String?
    var mood: String?
    var vehicle: Vehicle?
    var locale: String?
}

// MARK: - Saved places

enum SavedPlaceKind: String, Codable, Sendable {
    case home, work, favorite
}

struct SavedPlace: Codable, Sendable, Identifiable, Hashable {
    var id: String
    var kind: SavedPlaceKind
    var name: String
    /// One of `FavoriteIcon` raw values; home/work always `home`/`work`.
    var icon: String?
    var lat: Double
    var lng: Double
    var address: String
    var placeId: String?
    var sortOrder: Int?

    init(id: String, kind: SavedPlaceKind, name: String, icon: String? = nil, lat: Double, lng: Double, address: String,
         placeId: String? = nil, sortOrder: Int? = nil) {
        self.id = id; self.kind = kind; self.name = name; self.icon = icon
        self.lat = lat; self.lng = lng; self.address = address; self.placeId = placeId; self.sortOrder = sortOrder
    }

    var location: LatLng { LatLng(lat: lat, lng: lng) }

    var favoriteIcon: FavoriteIcon {
        switch kind {
        case .home: .home
        case .work: .work
        case .favorite: icon.flatMap(FavoriteIcon.init(rawValue:)) ?? .star
        }
    }
}

struct SavedPlaceInput: Codable, Sendable {
    var name: String
    var icon: String?
    var lat: Double
    var lng: Double
    var address: String
    var placeId: String?
}

/// `PATCH /me/places/{id}` body.
struct SavedPlacePatch: Codable, Sendable, Equatable {
    var name: String?
    var icon: String?
    var lat: Double?
    var lng: Double?
    var address: String?
    var sortOrder: Int?
}

/// Favourite icons allowed by the contract.
enum FavoriteIcon: String, CaseIterable, Sendable, Identifiable {
    case home, work, kampung, mertua, star, heart, school, surau, food, gym, shop, hospital
    var id: String { rawValue }

    var gIcon: GIcon {
        switch self {
        case .home: .home
        case .work: .work
        case .kampung: .kampung
        case .mertua: .mertua
        case .star: .star
        case .heart: .heart
        case .school: .school
        case .surau: .surau
        case .food: .food
        case .gym: .gym
        case .shop: .shop
        case .hospital: .hospital
        }
    }

    /// Icons a user may pick for a favourite (home/work are reserved).
    static let pickable: [FavoriteIcon] = [.kampung, .mertua, .star, .heart, .school, .surau, .food, .gym, .shop, .hospital]
}

/// Quick label chips on the "Save place" sheet. Labels are Malay proper names and stay as typed.
struct QuickLabel: Identifiable, Sendable, Hashable {
    let label: String
    let icon: FavoriteIcon
    var id: String { label }

    static let all: [QuickLabel] = [
        QuickLabel(label: "Kampung", icon: .kampung),
        QuickLabel(label: "Rumah Mertua", icon: .mertua),
        QuickLabel(label: "Sekolah", icon: .school),
        QuickLabel(label: "Surau", icon: .surau),
        QuickLabel(label: "Gym", icon: .gym),
        QuickLabel(label: "Kedai", icon: .shop),
    ]

    /// Suggests an icon for a free-text label ("Sekolah Aina" → school).
    static func suggestedIcon(for label: String) -> FavoriteIcon? {
        let l = label.lowercased()
        let rules: [(String, FavoriteIcon)] = [
            ("mertua", .mertua), ("kampung", .kampung), ("sekolah", .school), ("school", .school), ("tadika", .school),
            ("surau", .surau), ("masjid", .surau), ("mosque", .surau), ("gym", .gym), ("kedai", .shop), ("shop", .shop),
            ("hospital", .hospital), ("klinik", .hospital), ("clinic", .hospital), ("makan", .food), ("restoran", .food),
            ("food", .food), ("cafe", .food),
        ]
        return rules.first { l.contains($0.0) }?.1
    }
}

/// Orders saved places as the contract specifies: home, work, then favourites by sortOrder.
enum SavedPlaceOrdering {
    static func sorted(_ places: [SavedPlace], localOrder: [String: Int] = [:]) -> [SavedPlace] {
        func rank(_ p: SavedPlace) -> (Int, Int, String) {
            switch p.kind {
            case .home: (0, 0, "")
            case .work: (1, 0, "")
            case .favorite: (2, localOrder[p.id] ?? p.sortOrder ?? Int.max, p.name)
            }
        }
        return places.sorted { rank($0) < rank($1) }
    }
}

struct Recent: Codable, Sendable, Identifiable, Hashable {
    var id: String
    var name: String
    var address: String
    var lat: Double
    var lng: Double
    var placeId: String?
    var lastUsedAt: Date?

    var location: LatLng { LatLng(lat: lat, lng: lng) }
}

// MARK: - Search & places

enum PlaceCategory: String, Codable, Sendable, CaseIterable {
    case fuel
    case evCharging = "ev_charging"
    case restArea = "rest_area"
    case tollBooth = "toll_booth"
    case parking, restaurant, cafe
    case fastFood = "fast_food"
    case mall, supermarket, convenience, mosque, surau, temple, church, hospital, clinic
    case pharmacy, police, school, university, hotel, atm, bank
    case carRepair = "car_repair"
    case carWash = "car_wash"
    case tourism
    case transitStation = "transit_station"
    case airport, government, toilets
    /// Search-only kinds (ids st-/ad-/pc-/pt-): not openable as places, routed by lat/lng.
    case street, address, postcode, point
    case other

    init(from decoder: any Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = PlaceCategory(rawValue: raw) ?? .other
    }

    var isSearchOnly: Bool { [.street, .address, .postcode, .point].contains(self) }
}

/// `chainGroup: {key, name, countNearby}` (outlets of the same chain within 10 km).
struct ChainGroup: Codable, Sendable, Hashable {
    var key: String
    var name: String
    var countNearby: Int?

    init(key: String, name: String, countNearby: Int? = nil) { self.key = key; self.name = name; self.countNearby = countNearby }

    /// Also accepts a plain string (early servers).
    init(from decoder: any Decoder) throws {
        if let s = try? decoder.singleValueContainer().decode(String.self) { self.init(key: s.lowercased(), name: s); return }
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(key: try c.decode(String.self, forKey: .key), name: try c.decode(String.self, forKey: .name),
                  countNearby: try c.decodeIfPresent(Int.self, forKey: .countNearby))
    }
}

enum PlaceSource: String, Codable, Sendable {
    case osm, community
    /// "Just for me": on this device only (never from or to the server).
    case `private`

    init(from decoder: any Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = PlaceSource(rawValue: raw) ?? .osm
    }
}

enum PlaceStatus: String, Codable, Sendable {
    /// `rejected`: the AI check didn't accept it (owner only; may be edited or appealed once). `expired`: never confirmed.
    case pending, published, closed, hidden, rejected, expired

    init(from decoder: any Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = PlaceStatus(rawValue: raw) ?? .published
    }
}

struct PlaceSummary: Codable, Sendable, Identifiable, Hashable {
    var id: String
    var name: String
    var category: PlaceCategory
    var address: String
    var lat: Double
    var lng: Double
    var distanceM: Double?
    var brand: String?
    var source: PlaceSource?
    var status: PlaceStatus?
    var rating: Double?
    var reviewCount: Int?
    var thumbnailUrl: String?
    /// Same chain (e.g. all FamilyMart branches) for grouping results; falls back to `brand`.
    var chainGroup: ChainGroup?
    var openNow: Bool?
    var confirmationsWeighted: Double?
    var required: Double?
    /// Held for a moderator (restricted area nearby or sensitive words): "Being checked" in My contributions.
    var heldForReview: Bool?
    /// The AI check, for the owner only (`GET /me/places/contributed`); absent for everyone else.
    var screening: PlaceScreening?

    init(id: String, name: String, category: PlaceCategory, address: String, lat: Double, lng: Double, distanceM: Double? = nil,
         brand: String? = nil, source: PlaceSource? = nil, status: PlaceStatus? = nil, rating: Double? = nil,
         reviewCount: Int? = nil, thumbnailUrl: String? = nil, chainGroup: ChainGroup? = nil, openNow: Bool? = nil) {
        self.id = id; self.name = name; self.category = category; self.address = address; self.lat = lat; self.lng = lng
        self.distanceM = distanceM; self.brand = brand; self.source = source; self.status = status; self.rating = rating
        self.reviewCount = reviewCount; self.thumbnailUrl = thumbnailUrl; self.chainGroup = chainGroup; self.openNow = openNow
    }

    var location: LatLng { LatLng(lat: lat, lng: lng) }
    var isCommunity: Bool { source == .community }
    /// Streets, addresses, postcodes and points from search: no place page, route by lat/lng.
    var isSearchOnly: Bool {
        category.isSearchOnly || ["st-", "ad-", "pc-", "pt-"].contains { id.hasPrefix($0) }
    }
    var isPrivate: Bool { source == .private || id.hasPrefix(PrivatePlace.idPrefix) }
}

struct SearchResponse: Codable, Sendable {
    var results: [PlaceSummary]
    /// Set when the server corrected the spelling ("famly mart" → "FamilyMart").
    var correctedQuery: String?
    /// "Did you mean" for few/no results: a category nearby, a similar name, etc.
    var suggestions: [SearchSuggestion]?
    var noMatch: Bool?
    var interpretation: SearchInterpretation?
}

/// How the server read the query (informational).
struct SearchInterpretation: Codable, Sendable, Hashable {
    var kind: String
    var normalized: String?
    var categories: [String]?
    var area: String?
}

struct SearchSuggestion: Codable, Sendable, Hashable, Identifiable {
    var label: String
    var query: String?
    var category: PlaceCategory?
    var count: Int?
    var placeId: String?
    var lat: Double?
    var lng: Double?
    var distanceM: Double?
    var id: String { "\(label)|\(query ?? "")|\(category?.rawValue ?? "")|\(placeId ?? "")" }

    enum CodingKeys: String, CodingKey { case label, query, category, count, placeId, lat, lng, distanceM }
}

/// What a search returned, with the server's spelling fix and suggestions when present.
struct SearchOutcome: Sendable {
    var results: [PlaceSummary]
    var correctedQuery: String?
    var suggestions: [SearchSuggestion]
    var noMatch = false
    var interpretation: SearchInterpretation?
}

struct Place: Codable, Sendable, Identifiable, Hashable {
    var id: String
    var name: String
    var category: PlaceCategory
    var address: String
    var lat: Double
    var lng: Double
    var distanceM: Double?
    var brand: String?
    var phone: String?
    var website: String?
    var openingHours: String?
    var openNow: Bool?
    var amenities: [String]?
    var tags: [String: String]?
    var osmType: String?
    var osmId: Int64?
    var source: PlaceSource?
    var status: PlaceStatus?
    var rating: Double?
    var reviewCount: Int?
    var thumbnailUrl: String?
    var description: String?
    var addedBy: PersonRef?
    var verifiedCount: Int?
    var photos: [Photo]?
    var confirmationsWeighted: Double?
    var required: Double?
    var heldForReview: Bool?
    /// Where routes to this place end (its entrance); the display pin stays `lat`/`lng`.
    var navigationPoint: NavigationPoint?
    /// The AI check, in the owner's view only (POST/PATCH/appeal responses).
    var screening: PlaceScreening?

    var summary: PlaceSummary {
        var s = PlaceSummary(id: id, name: name, category: category, address: address, lat: lat, lng: lng, distanceM: distanceM, brand: brand,
                             source: source, status: status, rating: rating, reviewCount: reviewCount, thumbnailUrl: thumbnailUrl)
        s.heldForReview = heldForReview
        s.screening = screening
        s.confirmationsWeighted = confirmationsWeighted
        s.required = required
        return s
    }
}

struct PersonRef: Codable, Sendable, Hashable {
    var displayName: String
    var level: Int?
    var reviewCount: Int?
    /// Opaque, stable handle of the contributor (no user id): what "Block this user" stores on the phone.
    /// Decoded from `authorRef`, or `authorHandle` / `handle` / `ref` until docs/api.md names it (same as Android).
    var authorRef: String?

    init(displayName: String, level: Int? = nil, reviewCount: Int? = nil, authorRef: String? = nil) {
        self.displayName = displayName; self.level = level; self.reviewCount = reviewCount; self.authorRef = authorRef
    }

    private enum CodingKeys: String, CodingKey { case displayName, level, reviewCount, authorRef, authorHandle, handle, ref }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        displayName = try c.decode(String.self, forKey: .displayName)
        level = try c.decodeIfPresent(Int.self, forKey: .level)
        reviewCount = try c.decodeIfPresent(Int.self, forKey: .reviewCount)
        authorRef = try c.decodeIfPresent(String.self, forKey: .authorRef) ?? c.decodeIfPresent(String.self, forKey: .authorHandle)
            ?? c.decodeIfPresent(String.self, forKey: .handle) ?? c.decodeIfPresent(String.self, forKey: .ref)
    }

    func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(displayName, forKey: .displayName)
        try c.encodeIfPresent(level, forKey: .level)
        try c.encodeIfPresent(reviewCount, forKey: .reviewCount)
        try c.encodeIfPresent(authorRef, forKey: .authorRef)
    }
}

// MARK: - Community places, reviews, photos

/// `POST /places` (and the owner's `PATCH /places/{id}`).
struct NewPlace: Codable, Sendable, Hashable {
    var name: String
    var category: PlaceCategory
    var lat: Double
    var lng: Double
    var address: String?
    var description: String?
    var phone: String?
    var website: String?
    var openingHours: String?
    var amenities: [String]?
    /// The `existing.id` of a 409 the user answered "No, mine is a different place" (B1). Only on `POST /places`.
    var notDuplicateOf: String?
}

/// The AI check on a community place (docs/api.md "AI check"), in the owner's view only.
/// `reasons` are fixed codes; the app shows its own copy for each and never the model's text.
struct PlaceScreening: Codable, Sendable, Hashable {
    var state: ScreeningState
    var reasons: [String]
    var canAppeal: Bool
    var appealed: Bool

    init(state: ScreeningState, reasons: [String] = [], canAppeal: Bool = false, appealed: Bool = false) {
        self.state = state; self.reasons = reasons; self.canAppeal = canAppeal; self.appealed = appealed
    }

    private enum CodingKeys: String, CodingKey { case state, reasons, canAppeal, appealed }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        state = try c.decodeIfPresent(ScreeningState.self, forKey: .state) ?? .none
        reasons = try c.decodeIfPresent([String].self, forKey: .reasons) ?? []
        canAppeal = try c.decodeIfPresent(Bool.self, forKey: .canAppeal) ?? false
        appealed = try c.decodeIfPresent(Bool.self, forKey: .appealed) ?? false
    }
}

enum ScreeningState: String, Codable, Sendable {
    /// none: not checked (older places, restricted-area holds); skipped: the check is off or over its weekly budget.
    case none, checking, passed, held, rejected, skipped

    init(from decoder: any Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = ScreeningState(rawValue: raw.lowercased()) ?? .none
    }
}

/// `POST /places/{id}/appeal` (signed): ask a person to review a place the check didn't accept (once per place).
struct AppealPlaceRequest: Codable, Sendable, Hashable {
    static let maxNote = 200
    var note: String?
}

/// `POST /places/{id}/suggest-edit`.
struct PlaceEditSuggestion: Codable, Sendable, Hashable {
    var name: String?
    var category: PlaceCategory?
    var lat: Double?
    var lng: Double?
    var phone: String?
    var website: String?
    var openingHours: String?
    var comment: String?
}

struct SuggestionAccepted: Codable, Sendable { var suggestionId: String }


enum PhotoStatus: String, Codable, Sendable {
    case processing, published, rejected

    init(from decoder: any Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = PhotoStatus(rawValue: raw) ?? .published
    }
}

struct Photo: Codable, Sendable, Hashable, Identifiable {
    var id: String
    /// Null while the server is still processing the upload (status "processing").
    var url: String?
    var thumbUrl: String?
    var width: Int?
    var height: Int?
    var caption: String?
    var uploadedBy: PersonRef?
    var createdAt: Date?
    var status: PhotoStatus?
    /// Opaque contributor handle (`authorRef`), at the top level or inside `uploadedBy`.
    var authorRef: String?

    var blockRef: String? { authorRef ?? uploadedBy?.authorRef }
}

struct PhotosPage: Codable, Sendable {
    var photos: [Photo]
    var next: String?
}

enum ReviewSort: String, Sendable, CaseIterable {
    case recent, helpful
}

struct Review: Codable, Sendable, Hashable, Identifiable {
    var id: String
    var placeId: String
    var rating: Int
    var text: String?
    var photos: [Photo]?
    var author: PersonRef
    var helpfulCount: Int
    var createdAt: Date
    var editedAt: Date?
    var status: String?
    /// Hidden until a moderator checks it (sensitive words): docs/api.md "Restricted areas".
    var heldForReview: Bool?
    /// Opaque contributor handle (`authorRef`), at the top level or inside `author`.
    var authorRef: String?

    var blockRef: String? { authorRef ?? author.authorRef }
}

struct ReviewsPage: Codable, Sendable {
    var reviews: [Review]
    var next: String?
}

struct NewReview: Codable, Sendable, Hashable {
    var rating: Int
    var text: String?
    var photoIds: [String]?
}

enum FlagReason: String, Codable, Sendable, CaseIterable, Identifiable {
    case spam, offensive
    case offTopic = "off_topic"
    case conflictOfInterest = "conflict_of_interest"
    /// Military / strategic site, shelter, private home, or security details: hidden after one report (docs/safety.md E).
    case sensitiveLocation = "sensitive_location"
    case other
    var id: String { rawValue }
}

struct FlagRequest: Codable, Sendable { var reason: FlagReason }

/// A "Just for me" place: stored only in the on-device DB (`private_places`), never sent to the server.
struct PrivatePlace: Identifiable, Hashable, Sendable {
    static let idPrefix = "private:"
    var id: String
    var name: String
    var category: PlaceCategory
    var lat: Double
    var lng: Double
    var address: String?
    var description: String?
    var phone: String?
    var website: String?
    var openingHours: String?
    var amenities: [String]
    var photoFiles: [String] = []
    var createdAt: Date?
    var updatedAt: Date?

    var location: LatLng { LatLng(lat: lat, lng: lng) }

    var summary: PlaceSummary {
        PlaceSummary(id: Self.idPrefix + id, name: name, category: category, address: address ?? "", lat: lat, lng: lng, source: .private)
    }
}

/// Rating summary shown on the place card ("New" under 3 reviews).
struct RatingSummary: Equatable, Sendable {
    var average: Double
    var count: Int
    /// Count per star, index 0 = 1 star … index 4 = 5 stars.
    var distribution: [Int]

    var isNew: Bool { count < 3 }

    static func make(reviews: [Review], serverAverage: Double? = nil, serverCount: Int? = nil) -> RatingSummary {
        var dist = [0, 0, 0, 0, 0]
        for r in reviews where (1...5).contains(r.rating) { dist[r.rating - 1] += 1 }
        let localCount = dist.reduce(0, +)
        let localAvg = localCount > 0 ? Double(dist.enumerated().reduce(0) { $0 + ($1.offset + 1) * $1.element }) / Double(localCount) : 0
        return RatingSummary(average: serverAverage ?? localAvg, count: max(serverCount ?? 0, localCount), distribution: dist)
    }
}

struct ReverseGeocode: Codable, Sendable {
    var name: String?
    var address: String?
    /// Ready-made line in the request language: "Dekat 18, Jalan SS 2/24, SS2, Petaling Jaya" / "Near …".
    var label: String?
    var houseNumber: String?
    var street: String?
    var area: String?
    var city: String?
    var postcode: String?
    var lat: Double
    var lng: Double
    /// Known places within 50 m ("Is this …?"), nearest first.
    var nearby: [PlaceSummary]?
}

/// Where a route to a place ends (docs/api.md "Arriving at the entrance"): a confirmed entrance correction, an OSM
/// `entrance=*` node, or the outline point nearest the road.
struct NavigationPoint: Codable, Sendable, Hashable {
    enum Source: String, Codable, Sendable {
        case confirmed
        case osmEntrance = "osm_entrance"
        case outline
        case other

        init(from decoder: any Decoder) throws {
            self = Source(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .other
        }
    }

    var lat: Double
    var lng: Double
    var issueId: String?
    var source: Source?
    /// OSM `entrance=*` value ("main", "yes", "service"…).
    var kind: String?

    var location: LatLng { LatLng(lat: lat, lng: lng) }
}

/// What the user picked as a destination, regardless of origin (search, saved, recent, map).
struct Destination: Hashable, Sendable {
    var name: String
    var address: String
    var location: LatLng
    var placeId: String?
    var category: PlaceCategory = .other
    /// Chosen on the map (no name yet): after arriving we offer "Name this place?".
    var isPin = false
}

// MARK: - Routing

struct AvoidOptions: Codable, Sendable, Hashable {
    var tolls = false
    var highways = false
    var ferries = false
}

struct RouteEndpoint: Codable, Sendable, Hashable {
    var lat: Double
    var lng: Double
    var placeId: String?
    /// Waypoint display name (sent for waypoints).
    var name: String?
}

struct RouteRequest: Codable, Sendable, Hashable {
    var origin: RouteEndpoint
    var destination: RouteEndpoint
    var waypoints: [RouteEndpoint] = []
    var vehicle: Vehicle = .car
    var avoid = AvoidOptions()
    var departAt: Date?
    var alternatives = 2
    /// "Drive through anyway": issues to ignore for this trip only.
    var ignoreIssues: [String] = []

    enum CodingKeys: String, CodingKey { case origin, destination, waypoints, vehicle, avoid, departAt, alternatives, ignoreIssues }

    func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(origin, forKey: .origin)
        try c.encode(destination, forKey: .destination)
        try c.encode(waypoints, forKey: .waypoints)
        try c.encode(vehicle, forKey: .vehicle)
        try c.encode(avoid, forKey: .avoid)
        // Contract shows explicit null.
        if let departAt { try c.encode(departAt, forKey: .departAt) } else { try c.encodeNil(forKey: .departAt) }
        try c.encode(alternatives, forKey: .alternatives)
        if !ignoreIssues.isEmpty { try c.encode(ignoreIssues, forKey: .ignoreIssues) }
    }
}

struct RoutesResponse: Codable, Sendable {
    var routes: [Route]
}

enum ManeuverType: String, Codable, Sendable, CaseIterable {
    case depart, arrive, straight
    case slightLeft = "slight_left"
    case left
    case sharpLeft = "sharp_left"
    case slightRight = "slight_right"
    case right
    case sharpRight = "sharp_right"
    case uturnLeft = "uturn_left"
    case uturnRight = "uturn_right"
    case roundaboutEnter = "roundabout_enter"
    case roundaboutExit = "roundabout_exit"
    case merge
    case rampLeft = "ramp_left"
    case rampRight = "ramp_right"
    case exitLeft = "exit_left"
    case exitRight = "exit_right"
    case keepLeft = "keep_left"
    case keepRight = "keep_right"
    case ferry

    init(from decoder: any Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = ManeuverType(rawValue: raw) ?? .straight
    }
}

struct Maneuver: Codable, Sendable, Hashable {
    var type: ManeuverType
    var instruction: String
    var streetName: String?
    var exitNumber: String?
    var roadRef: String?
    var distanceM: Double
    var durationS: Double
    var beginShapeIndex: Int
    var endShapeIndex: Int
    var verbalPre: String?
    var verbalPost: String?
}

struct LegEnd: Codable, Sendable, Hashable {
    var lat: Double
    var lng: Double
    var name: String?
}

struct RouteLeg: Codable, Sendable, Hashable {
    var durationS: Double?
    var distanceM: Double?
    var to: LegEnd?
    var maneuvers: [Maneuver]

    init(durationS: Double? = nil, distanceM: Double? = nil, to: LegEnd? = nil, maneuvers: [Maneuver]) {
        self.durationS = durationS; self.distanceM = distanceM; self.to = to; self.maneuvers = maneuvers
    }
}

/// A toll plaza on the route with its curated fare (contract `tolls[]`).
struct TollPlaza: Codable, Sendable, Hashable, Identifiable {
    var plazaId: String
    var name: String
    var highway: String?
    var lat: Double
    var lng: Double
    var fareMyr: Double?
    var system: String?
    var source: String?
    /// Metres from the route start to the plaza ("toll ahead" alert); older servers leave it out.
    var distanceAlongRouteM: Double?
    var id: String { plazaId }
}

struct TrafficSegment: Codable, Sendable, Hashable {
    var fromIndex: Int
    var toIndex: Int
    var level: Int
}

struct Route: Codable, Sendable, Identifiable, Hashable {
    var id: String
    var label: String
    var durationS: Double
    var distanceM: Double
    var trafficDurationS: Double?
    var summary: String
    var trafficDescription: String?
    var vehicle: Vehicle?
    var hasTolls: Bool
    var tollEstimateMyr: Double?
    var tollFareComplete: Bool?
    var tolls: [TollPlaza]?
    var polyline: String
    var bbox: [Double]
    var legs: [RouteLeg]
    var trafficSegments: [TrafficSegment]?
    var alerts: [AlertOnRoute]?
    /// Road issues on or avoided by this route (complaints v1).
    var issues: [RouteIssue]?
    /// A place destination routed to its entrance: where this route ends (docs/driving.md §4).
    var arrival: NavigationPoint?
    /// Why this route is offered: fastest, shortest, lower_toll, no_tolls, fewer_reports, other_main_road (docs/api.md "Route options").
    var reasons: [String]?
    /// Main roads only this route uses, e.g. ["FT2"].
    var viaRoads: [String]?
    /// Not worth offering (same_road, slower, worse): shown only after "Show anyway".
    var hidden: String?
    /// Client-side only (demo mode): explains that a captured route was substituted. Not part of the API contract.
    var demoNote: String?

    var isBest: Bool { label == "best" }
    /// Duration including live traffic when available.
    var effectiveDurationS: Double { trafficDurationS ?? durationS }
    var maneuvers: [Maneuver] { legs.flatMap(\.maneuvers) }
}

struct RerouteRequest: Codable, Sendable {
    var lat: Double
    var lng: Double
    var heading: Double
    /// Index (into the original waypoints) of the next stop not yet reached; the server keeps the remaining stops.
    var nextStopIndex: Int?
}

struct DepartureSlot: Codable, Sendable, Hashable, Identifiable {
    var departAt: Date
    var durationS: Double
    var id: Date { departAt }
}

struct DepartureTimesResponse: Codable, Sendable {
    var slots: [DepartureSlot]
}

// MARK: - Live map

enum ReportType: String, Codable, Sendable, CaseIterable, Identifiable {
    case traffic, police, accident, hazard, closure
    case blockedLane = "blocked_lane"
    case mapIssue = "map_issue"
    case weather, animal
    var id: String { rawValue }

    init(from decoder: any Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = ReportType(rawValue: raw) ?? .hazard
    }
}

struct ReportAuthor: Codable, Sendable, Hashable {
    var displayName: String
    var mood: String?
}

struct Report: Codable, Sendable, Identifiable, Hashable {
    var id: String
    var type: ReportType
    var subtype: String?
    var lat: Double
    var lng: Double
    var heading: Double?
    var street: String?
    var reportedBy: ReportAuthor?
    var createdAt: Date
    var expiresAt: Date
    var confirmations: Int
    var thanks: Int

    var location: LatLng { LatLng(lat: lat, lng: lng) }
}

/// `AlertOnRoute = Report + {distanceAlongRouteM}` — decoded flat.
struct AlertOnRoute: Codable, Sendable, Hashable, Identifiable {
    var report: Report
    var distanceAlongRouteM: Double
    var id: String { report.id }

    init(report: Report, distanceAlongRouteM: Double) {
        self.report = report
        self.distanceAlongRouteM = distanceAlongRouteM
    }

    private enum K: String, CodingKey { case distanceAlongRouteM }

    init(from decoder: any Decoder) throws {
        report = try Report(from: decoder)
        distanceAlongRouteM = try decoder.container(keyedBy: K.self).decode(Double.self, forKey: .distanceAlongRouteM)
    }

    func encode(to encoder: any Encoder) throws {
        try report.encode(to: encoder)
        var c = encoder.container(keyedBy: K.self)
        try c.encode(distanceAlongRouteM, forKey: .distanceAlongRouteM)
    }
}

struct Jam: Codable, Sendable, Identifiable, Hashable {
    var id: String
    var level: Int
    var speedKmh: Double
    var delayS: Double
    var lengthM: Double
    var polyline: String
    var street: String?
    var updatedAt: Date
}

struct Driver: Codable, Sendable, Hashable {
    var lat: Double
    var lng: Double
    var heading: Double
    var mood: String?
}

struct LiveResponse: Codable, Sendable {
    var alerts: [Report]
    var jams: [Jam]
    var drivers: [Driver]
    var serverTime: Date?
}

struct NewReport: Codable, Sendable {
    var type: ReportType
    var subtype: String?
    var lat: Double
    var lng: Double
    var heading: Double?
    var comment: String?
}

struct VoteRequest: Codable, Sendable {
    var stillThere: Bool
}

// MARK: - Location pings

struct LocationPoint: Codable, Sendable, Hashable {
    var lat: Double
    var lng: Double
    var speedKmh: Double
    var heading: Double
    var accuracyM: Double
    var ts: Date
}

struct LocationBatch: Codable, Sendable {
    var routeId: String?
    var points: [LocationPoint]
}

/// Bounding box `[minLng, minLat, maxLng, maxLat]`.
struct BBox: Hashable, Sendable {
    var minLng: Double
    var minLat: Double
    var maxLng: Double
    var maxLat: Double

    var queryValue: String {
        [minLng, minLat, maxLng, maxLat].map { String(format: "%.5f", $0) }.joined(separator: ",")
    }

    var array: [Double] { [minLng, minLat, maxLng, maxLat] }

    func contains(_ p: LatLng) -> Bool {
        p.lat >= minLat && p.lat <= maxLat && p.lng >= minLng && p.lng <= maxLng
    }

    init(minLng: Double, minLat: Double, maxLng: Double, maxLat: Double) {
        self.minLng = minLng
        self.minLat = minLat
        self.maxLng = maxLng
        self.maxLat = maxLat
    }

    init?(array: [Double]) {
        guard array.count == 4 else { return nil }
        self.init(minLng: array[0], minLat: array[1], maxLng: array[2], maxLat: array[3])
    }

    static func around(_ points: [LatLng]) -> BBox? {
        guard let first = points.first else { return nil }
        var b = BBox(minLng: first.lng, minLat: first.lat, maxLng: first.lng, maxLat: first.lat)
        for p in points.dropFirst() {
            b.minLng = min(b.minLng, p.lng); b.maxLng = max(b.maxLng, p.lng)
            b.minLat = min(b.minLat, p.lat); b.maxLat = max(b.maxLat, p.lat)
        }
        return b
    }
}

// MARK: - Feedback

enum FeedbackCategory: String, Codable, Sendable, CaseIterable, Identifiable {
    case bug
    case idea
    case mapData = "map_data"
    case route
    case search
    case other
    var id: String { rawValue }

    init(from decoder: any Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = FeedbackCategory(rawValue: raw) ?? .other
    }
}

enum FeedbackScreen: String, Codable, Sendable {
    case home, search, place
    case routePreview = "route_preview"
    case navigation, report, settings, other
}

enum FeedbackStatus: String, Codable, Sendable {
    case received, triaged, planned, done
    case wontFix = "wont_fix"

    init(from decoder: any Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = FeedbackStatus(rawValue: raw) ?? .received
    }
}

struct FeedbackContext: Codable, Sendable, Hashable {
    var appVersion: String?
    var platform: String? = "ios"
    var osVersion: String?
    var deviceModel: String?
    var locale: String?
    var lat: Double?
    var lng: Double?
    var routeId: String?
    var placeId: String?
}

/// docs/api.md "Feedback": sent only when the user ticks "Include device info" (shown in a preview first).
struct DeviceInfo: Codable, Sendable, Hashable {
    struct Screen: Codable, Sendable, Hashable {
        var widthPx: Int, heightPx: Int, density: Double, widthDp: Int, heightDp: Int
    }
    var appVersion: String
    var appBuild: Int
    var platform: String = "ios"
    var osVersion: String
    var deviceModel: String
    var manufacturer: String = "Apple"
    var screen: Screen
    var locale: String
    var theme: String
    var dataMode: String
    /// "precise" | "approximate" and the last horizontal accuracy (m). Never coordinates.
    var locationPrecision: String?
    var lastAccuracyM: Int?
}

struct CoarseLocation: Codable, Sendable, Hashable {
    var lat: Double
    var lng: Double
    /// Rounded to 2 dp (~1 km) on the phone.
    init(_ p: LatLng) {
        lat = (p.lat * 100).rounded() / 100
        lng = (p.lng * 100).rounded() / 100
    }
}

/// Optional, volunteered per report; never prefilled, never stored on the profile.
struct ContactDetails: Codable, Sendable, Hashable {
    var email: String?
    var whatsapp: String?
    var consent: Bool
}

struct FeedbackRequest: Codable, Sendable, Hashable {
    var category: FeedbackCategory
    var message: String
    var rating: Int?
    var screen: FeedbackScreen
    var device: DeviceInfo?
    var location: CoarseLocation?
    var contact: ContactDetails?
    var routeId: String?
    var placeId: String?
    /// Base64 JPEG/PNG, ≤ 1.5 MB decoded.
    var screenshot: String?
}

struct FeedbackCreated: Codable, Sendable, Hashable {
    var id: String
    var createdAt: Date?
    /// Returned once when the feedback carries a volunteered contact (stored without the user id): keep it on the
    /// phone and send it as X-Contact-Token to withdraw the contact.
    var contactToken: String?
}

struct FeedbackSummary: Codable, Sendable, Hashable, Identifiable {
    var id: String
    var category: FeedbackCategory
    var message: String
    var status: FeedbackStatus
    var createdAt: Date
    var hasContact: Bool?
}

// MARK: - Inbox (news about the user's public contributions only)

enum InboxKind: String, Codable, Sendable {
    case placePublished = "place_published"
    case placeRejected = "place_rejected"
    case reportThanked = "report_thanked"
    case reviewHelpful = "review_helpful"
    case editAccepted = "edit_accepted"
    case feedbackStatus = "feedback_status"
    /// Complaints: the reporter's issue was confirmed / refuted / resolved (OSM now matches).
    case issueConfirmed = "issue_confirmed"
    case issueRefuted = "issue_refuted"
    case issueResolved = "issue_resolved"
    case placeExpired = "place_expired"
    /// The AI check held the user's place for a person / didn't accept it / it went live after the app stopped waiting
    /// (or a maintainer accepted a held or appealed place). All three: refType "place", refId = the community place id.
    case placeHeld = "place_held"
    case placeNotAccepted = "place_not_accepted"
    case placeLive = "place_live"
    case announcement
    case unknown

    init(from decoder: any Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = InboxKind(rawValue: raw) ?? .unknown
    }
}

struct InboxItem: Codable, Sendable, Hashable, Identifiable {
    var id: String
    var kind: InboxKind
    var title: String
    var body: String?
    var refType: String?
    var refId: String?
    var createdAt: Date
    var read: Bool?
    var count: Int?
}

struct InboxPage: Codable, Sendable {
    var items: [InboxItem]
    var next: String?
    var unread: Int?
}

struct InboxReadRequest: Codable, Sendable { var upTo: Date }

/// Unread = newer than both the server's read flag and the local read mark (local state keeps the badge right
/// offline and before the server endpoint exists).
enum InboxReadState {
    static func unreadCount(_ items: [InboxItem], localReadUpTo: Date?) -> Int {
        items.filter { item in
            if item.read == true { return false }
            if let mark = localReadUpTo, item.createdAt <= mark { return false }
            return true
        }.count
    }
}

/// Photo URLs from the server may be root-relative (`/media/{key}.webp`); resolve them against the API host.
@MainActor
enum MediaURL {
    static func resolve(_ raw: String?, apiBase: URL = AppConfig().apiBaseURL) -> URL? {
        guard let raw, !raw.isEmpty else { return nil }
        if let u = URL(string: raw), u.scheme != nil { return u }
        return URL(string: raw, relativeTo: apiBase)?.absoluteURL
    }
}

/// A snapshot of visible ground. Kept in memory only, never saved with recents.
enum SearchArea {
    static func contains(_ wire: String, _ p: LatLng) -> Bool {
        let points = wire.split(separator: ";").compactMap { pair -> (Double, Double)? in
            let v = pair.split(separator: ","); guard v.count == 2, let x = Double(v[0]), let y = Double(v[1]) else { return nil }; return (x,y)
        }
        guard points.count >= 3 else { return false }
        var inside = false
        for i in points.indices {
            let (x,y) = points[i], (px,py) = points[(i + points.count - 1) % points.count]
            let cross = (p.lng-px)*(y-py)-(p.lat-py)*(x-px)
            if abs(cross) < 1e-10 && p.lng >= min(x,px) && p.lng <= max(x,px) && p.lat >= min(y,py) && p.lat <= max(y,py) { return true }
            if (y > p.lat) != (py > p.lat) && p.lng < (px-x)*(p.lat-y)/(py-y)+x { inside.toggle() }
        }
        return inside
    }
}
