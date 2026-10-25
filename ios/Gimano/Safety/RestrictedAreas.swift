import Foundation
import Observation

// MARK: - Restricted areas (docs/safety.md part 4, docs/api.md "Restricted areas")

/// `GET /restricted-areas`: outer rings of military, security and strategic sites, plus the sensitive words. Public
/// data, downloaded whole (never a bounding box), so the request says nothing about where the user is.
struct RestrictedAreaSet: Codable, Sendable, Equatable {
    var version: String
    var blockM: Double
    var reviewM: Double
    var terms: [String]
    /// Outer rings, each `[[lng, lat], …]`, closed.
    var areas: [[[Double]]]

    var rings: [[LatLng]] {
        areas.map { ring in ring.compactMap { $0.count >= 2 ? LatLng(lat: $0[1], lng: $0[0]) : nil } }.filter { $0.count >= 3 }
    }
}

/// How close a point is to a restricted area.
enum RestrictedProximity: Equatable, Sendable {
    /// Inside a ring, or within `blockM` of its edge: no public contributions.
    case blocked
    /// Within `reviewM`: places are held for a moderator, photos refused.
    case near
    case clear
}

/// Point-in-ring and distance-to-edge checks, with a bounding-box prefilter per ring. Works offline, sends nothing.
struct RestrictedAreaIndex: Sendable {
    struct Ring: Sendable {
        let points: [LatLng]
        let minLat, maxLat, minLng, maxLng: Double
    }

    let rings: [Ring]
    let blockM: Double
    let reviewM: Double

    init(rings: [[LatLng]], blockM: Double, reviewM: Double) {
        self.blockM = blockM
        self.reviewM = max(reviewM, blockM)
        self.rings = rings.filter { $0.count >= 3 }.map { pts in
            Ring(points: pts, minLat: pts.map(\.lat).min()!, maxLat: pts.map(\.lat).max()!,
                 minLng: pts.map(\.lng).min()!, maxLng: pts.map(\.lng).max()!)
        }
    }

    init(_ set: RestrictedAreaSet) {
        self.init(rings: set.rings, blockM: set.blockM, reviewM: set.reviewM)
    }

    var isEmpty: Bool { rings.isEmpty }

    func proximity(of p: LatLng) -> RestrictedProximity {
        guard let d = distanceToNearestArea(p, within: reviewM) else { return .clear }
        return d <= blockM ? .blocked : .near
    }

    /// True when `p` lies inside any ring (the map's tap sheet D).
    func contains(_ p: LatLng) -> Bool {
        rings.contains { r in
            p.lat >= r.minLat && p.lat <= r.maxLat && p.lng >= r.minLng && p.lng <= r.maxLng && Self.inside(p, r.points)
        }
    }

    /// 0 inside a ring, else metres to the nearest ring edge; nil when no ring is within `limit` metres.
    func distanceToNearestArea(_ p: LatLng, within limit: Double) -> Double? {
        let dLat = limit / 111_320
        let dLng = limit / (111_320 * max(0.01, cos(p.lat * .pi / 180)))
        var best: Double?
        for r in rings where p.lat >= r.minLat - dLat && p.lat <= r.maxLat + dLat && p.lng >= r.minLng - dLng && p.lng <= r.maxLng + dLng {
            if Self.inside(p, r.points) { return 0 }
            let d = Self.edgeDistance(p, r.points)
            if d <= limit, d < (best ?? .infinity) { best = d }
        }
        return best
    }

    /// Ray casting on lng/lat (fine at these sizes).
    static func inside(_ p: LatLng, _ ring: [LatLng]) -> Bool {
        var inside = false
        var j = ring.count - 1
        for i in 0..<ring.count {
            let a = ring[i], b = ring[j]
            if (a.lat > p.lat) != (b.lat > p.lat),
               p.lng < (b.lng - a.lng) * (p.lat - a.lat) / (b.lat - a.lat) + a.lng {
                inside.toggle()
            }
            j = i
        }
        return inside
    }

    /// Metres from `p` to the nearest segment of the ring (local equirectangular projection around `p`).
    static func edgeDistance(_ p: LatLng, _ ring: [LatLng]) -> Double {
        let kx = 111_320 * cos(p.lat * .pi / 180), ky = 110_540.0
        func xy(_ q: LatLng) -> (Double, Double) { ((q.lng - p.lng) * kx, (q.lat - p.lat) * ky) }
        var best = Double.infinity
        for i in 0..<ring.count {
            let (ax, ay) = xy(ring[i]), (bx, by) = xy(ring[(i + 1) % ring.count])
            let dx = bx - ax, dy = by - ay
            let len2 = dx * dx + dy * dy
            let t = len2 == 0 ? 0 : max(0, min(1, -(ax * dx + ay * dy) / len2))
            let cx = ax + t * dx, cy = ay + t * dy
            best = min(best, (cx * cx + cy * cy).squareRoot())
        }
        return best
    }
}

// MARK: - Sensitive words (part 4 C)

/// Whole-word / whole-phrase match of the server's `terms`, case- and accent-insensitive.
struct SensitiveTerms: Sendable {
    private let phrases: [[String]]

    init(_ terms: [String]) {
        phrases = terms.map { Self.words($0) }.filter { !$0.isEmpty }
    }

    var isEmpty: Bool { phrases.isEmpty }

    /// Lower-cased, accent-free words (letters and digits).
    static func words(_ s: String) -> [String] {
        s.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
            .lowercased()
            .split { !($0.isLetter || $0.isNumber) }
            .map(String.init)
    }

    func matches(_ text: String) -> Bool {
        guard !phrases.isEmpty else { return false }
        let w = Self.words(text)
        guard !w.isEmpty else { return false }
        return phrases.contains { phrase in
            guard phrase.count <= w.count else { return false }
            return (0...(w.count - phrase.count)).contains { i in Array(w[i..<(i + phrase.count)]) == phrase }
        }
    }

    /// Sentences of `text`, each with its own ending punctuation and following whitespace.
    static func sentences(_ text: String) -> [String] {
        var out: [String] = []
        var cur = ""
        var ended = false
        for ch in text {
            if ended && !(ch == " " || ch == "\t" || ch == "\n" || ".!?…".contains(ch)) {
                out.append(cur)
                cur = ""
                ended = false
            }
            cur.append(ch)
            if ".!?…\n".contains(ch) { ended = true }
        }
        if !cur.isEmpty { out.append(cur) }
        return out
    }

    /// "Buang ayat ini": drops every sentence that contains a term.
    func removingMatchingSentences(_ text: String) -> String {
        Self.sentences(text).filter { !matches($0) }.joined().trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - Store (ETag, file cache, daily re-check)

@MainActor
@Observable
final class RestrictedAreaStore {
    private(set) var set: RestrictedAreaSet?
    private(set) var index: RestrictedAreaIndex?
    private(set) var terms = SensitiveTerms([])
    /// The rings as drawn on the map.
    private(set) var rings: [[LatLng]] = []

    @ObservationIgnored private var fetching = false
    @ObservationIgnored private let fileURL: URL
    @ObservationIgnored private let defaults: UserDefaults
    static let maxAge: TimeInterval = 24 * 3600
    private static let etagKey = "restrictedAreas.etag"
    private static let fetchedKey = "restrictedAreas.fetchedAt"

    init(fileURL: URL? = nil, defaults: UserDefaults = .standard) {
        let dir = (try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true))
            ?? FileManager.default.temporaryDirectory
        self.fileURL = fileURL ?? dir.appendingPathComponent("restricted-areas.json")
        self.defaults = defaults
        if let data = try? Data(contentsOf: self.fileURL), let s = try? JSONDecoder().decode(RestrictedAreaSet.self, from: data) {
            apply(s)
        }
    }

    /// No copy yet (404 / offline on first start): no client-side check; the server still refuses.
    var isAvailable: Bool { index != nil }

    func proximity(of p: LatLng) -> RestrictedProximity { index?.proximity(of: p) ?? .clear }
    func isInsideArea(_ p: LatLng) -> Bool { index?.contains(p) ?? false }

    func apply(_ s: RestrictedAreaSet) {
        set = s
        let idx = RestrictedAreaIndex(s)
        index = idx
        terms = SensitiveTerms(s.terms)
        rings = idx.rings.map(\.points)
    }

    /// At start-up and at most daily. `base` is the API base URL (…/api/v1/).
    func refreshIfNeeded(base: URL, force: Bool = false) async {
        // An empty copy (server not imported yet) is re-checked at every start instead of daily.
        if !force, let at = defaults.object(forKey: Self.fetchedKey) as? Date, Date().timeIntervalSince(at) < Self.maxAge,
           set?.areas.isEmpty == false { return }
        guard !fetching else { return }
        fetching = true
        defer { fetching = false }
        var req = URLRequest(url: base.appendingPathComponent("restricted-areas"))
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.timeoutInterval = 20
        if set != nil, let etag = defaults.string(forKey: Self.etagKey) { req.setValue(etag, forHTTPHeaderField: "If-None-Match") }
        let cfg = URLSessionConfiguration.ephemeral   // anonymous: no cookies, no token
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        let session = URLSession(configuration: cfg)
        defer { session.finishTasksAndInvalidate() }
        guard let (data, resp) = try? await session.data(for: req), let http = resp as? HTTPURLResponse else { return }
        switch http.statusCode {
        case 200:
            guard let s = try? JSONDecoder().decode(RestrictedAreaSet.self, from: data) else { return }
            apply(s)
            try? data.write(to: fileURL, options: .atomic)
            defaults.set(http.value(forHTTPHeaderField: "ETag"), forKey: Self.etagKey)
            defaults.set(Date(), forKey: Self.fetchedKey)
        case 304:
            defaults.set(Date(), forKey: Self.fetchedKey)
        default:
            // 404 (not deployed yet) or a server error: keep the last good copy.
            break
        }
    }

    #if DEBUG
    /// DEBUG only (never in release builds): a square restricted area of `sideM` around `center`, plus sample terms,
    /// kept in memory, so the geofence can be tried on a device before the endpoint exists.
    func installFixture(around center: LatLng, sideM: Double = 400) {
        let dLat = sideM / 2 / 111_320, dLng = sideM / 2 / (111_320 * cos(center.lat * .pi / 180))
        let ring = [[center.lng - dLng, center.lat - dLat], [center.lng + dLng, center.lat - dLat],
                    [center.lng + dLng, center.lat + dLat], [center.lng - dLng, center.lat + dLat], [center.lng - dLng, center.lat - dLat]]
        var areas = set?.version == "debug-fixture" ? set!.areas : []
        areas.append(ring)
        apply(RestrictedAreaSet(version: "debug-fixture", blockM: 100, reviewM: 300,
                                terms: ["kem tentera", "pangkalan", "pengawal", "cctv", "pintu belakang", "rondaan", "security guard", "back entrance", "patrol"],
                                areas: areas))
    }

    /// Back to the cached server copy (or nothing).
    func clearFixture() {
        set = nil; index = nil; terms = SensitiveTerms([]); rings = []
        if let data = try? Data(contentsOf: fileURL), let s = try? JSONDecoder().decode(RestrictedAreaSet.self, from: data) { apply(s) }
    }
    #endif
}

extension APIError {
    /// 422 ProblemDetails `code: "restricted_area"` (the `detail` is already localized by the server).
    var isRestrictedArea: Bool {
        if case .http(422, let p) = self { return p?.code == "restricted_area" }
        return false
    }
}
