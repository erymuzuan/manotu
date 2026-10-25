import Foundation
import Testing
@testable import Gimano

@Suite("Safety: agreement and drive reminder (docs/safety.md §1–3)")
struct SafetyPolicyTests {
    @Test("Agreement is asked once per version; existing users (version 0) see it too")
    func agreement() {
        #expect(SafetyPolicy.agreementVersion == 1)
        #expect(SafetyPolicy.needsAgreement(agreedVersion: 0))
        #expect(!SafetyPolicy.needsAgreement(agreedVersion: 1))
        #expect(!SafetyPolicy.needsAgreement(agreedVersion: 2))
        #expect(SafetyPolicy.parseVersion(nil) == 0 && SafetyPolicy.parseVersion("1") == 1 && SafetyPolicy.parseVersion("x") == 0)
    }

    @Test("Reminder: card when stopped or speed unknown, banner at ≥ 10 km/h, nothing when off")
    func reminderDecision() {
        #expect(SafetyPolicy.reminder(enabled: true, speedKmh: nil) == .card)
        #expect(SafetyPolicy.reminder(enabled: true, speedKmh: -1) == .card, "negative = unknown")
        #expect(SafetyPolicy.reminder(enabled: true, speedKmh: 0) == .card)
        #expect(SafetyPolicy.reminder(enabled: true, speedKmh: 9.9) == .card)
        #expect(SafetyPolicy.reminder(enabled: true, speedKmh: 10) == .banner)
        #expect(SafetyPolicy.reminder(enabled: true, speedKmh: 60) == .banner)
        #expect(SafetyPolicy.reminder(enabled: false, speedKmh: 0) == .none)
        #expect(SafetyPolicy.reminder(enabled: false, speedKmh: 80) == .none)
        #expect(!SafetyPolicy.shouldCloseCard(speedKmh: 9) && SafetyPolicy.shouldCloseCard(speedKmh: 10) && !SafetyPolicy.shouldCloseCard(speedKmh: nil))
    }

    @Test("The rest line is the long-drive one only for routes over 2 hours")
    func longDrive() {
        #expect(!SafetyPolicy.isLongDrive(durationS: nil))
        #expect(!SafetyPolicy.isLongDrive(durationS: 7200))
        #expect(SafetyPolicy.isLongDrive(durationS: 7201))
        #expect(SafetyCardRequest(destination: "Ipoh", durationS: 3 * 3600).isLongDrive)
    }

    @Test("Settings round-trip through the shared settings table; reminder defaults to on")
    func storage() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("safety-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = try LocalStore(path: dir.appendingPathComponent("db.sqlite").path, photosDirectory: dir.appendingPathComponent("p"))
        var s = SafetySettings(store: store)
        #expect(s.agreedVersion == 0 && s.reminderEnabled && !s.hasAgreed)
        s.agreedVersion = 1
        s.agreedAt = Date(timeIntervalSince1970: 1_800_000_000)
        s.reminderEnabled = false
        s.reminderDisabledAt = Date(timeIntervalSince1970: 1_800_000_100)
        s.save(to: store)
        #expect(try store.setting(SafetyPolicy.agreedVersionKey) == "1")
        #expect(try store.setting(SafetyPolicy.reminderEnabledKey) == "false")
        let back = SafetySettings(store: store)
        #expect(back.hasAgreed && !back.reminderEnabled)
        #expect(abs((back.agreedAt?.timeIntervalSince1970 ?? 0) - 1_800_000_000) < 1)
        #expect(back.reminderDisabledAt != nil)
        // Tolerant of either app's boolean spelling.
        #expect(SafetyPolicy.parseBool("1", default: false) && SafetyPolicy.parseBool("true", default: false))
        #expect(!SafetyPolicy.parseBool("0", default: true) && SafetyPolicy.parseBool(nil, default: true))
    }

    @Test("Merge restore: the later agreement version wins, with its date")
    func merge() {
        let a = SafetyPolicy.mergedAgreement(local: ("1", "2026-10-25T00:00:00Z"), backup: (nil, nil))
        #expect(a.version == "1")
        let b = SafetyPolicy.mergedAgreement(local: (nil, nil), backup: ("1", "2026-10-20T00:00:00Z"))
        #expect(b.version == "1" && b.at == "2026-10-20T00:00:00Z")
        let c = SafetyPolicy.mergedAgreement(local: ("1", "L"), backup: ("2", "B"))
        #expect(c.version == "2" && c.at == "B")
        let d = SafetyPolicy.mergedAgreement(local: ("2", "L"), backup: ("1", "B"))
        #expect(d.version == "2" && d.at == "L")
    }
}

@Suite("Sensitive places: geofence and words (docs/safety.md §4)")
struct RestrictedAreaTests {
    /// A ~1 km square around a point in Sungai Besi (lng/lat ring as the server sends it).
    static let center = LatLng(lat: 3.0700, lng: 101.7100)
    static func square(_ c: LatLng, halfM: Double) -> [[Double]] {
        let dLat = halfM / 111_320, dLng = halfM / (111_320 * cos(c.lat * .pi / 180))
        return [[c.lng - dLng, c.lat - dLat], [c.lng + dLng, c.lat - dLat], [c.lng + dLng, c.lat + dLat],
                [c.lng - dLng, c.lat + dLat], [c.lng - dLng, c.lat - dLat]]
    }
    static let set = RestrictedAreaSet(version: "t1", blockM: 100, reviewM: 300, terms: ["kem", "pintu masuk", "cctv", "pengawal"],
                                       areas: [square(center, halfM: 500)])

    /// A point `m` metres east of the square's east edge.
    static func eastOfEdge(_ m: Double) -> LatLng {
        LatLng(lat: center.lat, lng: center.lng + (500 + m) / (111_320 * cos(center.lat * .pi / 180)))
    }

    @Test("Decodes the server shape")
    func decode() throws {
        let json = #"{"version":"3f9a","blockM":100,"reviewM":300,"terms":["kem"],"areas":[[[101.7,3.0],[101.71,3.0],[101.71,3.01],[101.7,3.0]]]}"#
        let s = try JSONDecoder().decode(RestrictedAreaSet.self, from: Data(json.utf8))
        #expect(s.blockM == 100 && s.reviewM == 300 && s.rings.count == 1 && s.rings[0].count == 4)
        #expect(s.rings[0][1].lng == 101.71 && s.rings[0][1].lat == 3.0, "pairs are [lng, lat]")
    }

    @Test("Inside a ring or ≤ blockM is blocked; ≤ reviewM is near; beyond is clear")
    func proximity() {
        let idx = RestrictedAreaIndex(Self.set)
        #expect(idx.proximity(of: Self.center) == .blocked)
        #expect(idx.contains(Self.center))
        #expect(idx.proximity(of: Self.eastOfEdge(50)) == .blocked)
        #expect(!idx.contains(Self.eastOfEdge(50)))
        #expect(idx.proximity(of: Self.eastOfEdge(150)) == .near)
        #expect(idx.proximity(of: Self.eastOfEdge(290)) == .near)
        #expect(idx.proximity(of: Self.eastOfEdge(320)) == .clear)
        #expect(idx.proximity(of: LatLng(lat: 3.1478, lng: 101.6153)) == .clear)
    }

    @Test("Edge distance is metric (within a few metres)")
    func distance() {
        let idx = RestrictedAreaIndex(Self.set)
        let d = idx.distanceToNearestArea(Self.eastOfEdge(200), within: 1000) ?? -1
        #expect(abs(d - 200) < 3, "got \(d)")
        #expect(idx.distanceToNearestArea(Self.center, within: 10) == 0)
        #expect(idx.distanceToNearestArea(Self.eastOfEdge(2000), within: 300) == nil)
    }

    @Test("A concave ring: the notch is outside")
    func concave() {
        // U shape: 0..3 x 0..3 with the middle top cut out (1..2 x 1..3).
        let u = [LatLng(lat: 0, lng: 0), LatLng(lat: 0, lng: 0.03), LatLng(lat: 0.03, lng: 0.03), LatLng(lat: 0.03, lng: 0.02),
                 LatLng(lat: 0.01, lng: 0.02), LatLng(lat: 0.01, lng: 0.01), LatLng(lat: 0.03, lng: 0.01), LatLng(lat: 0.03, lng: 0)]
        #expect(RestrictedAreaIndex.inside(LatLng(lat: 0.005, lng: 0.015), u))
        #expect(!RestrictedAreaIndex.inside(LatLng(lat: 0.02, lng: 0.015), u))
    }

    @Test("No copy (404/offline on first start): no client-side check")
    @MainActor func noData() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ra-\(UUID().uuidString).json")
        let store = RestrictedAreaStore(fileURL: url, defaults: UserDefaults(suiteName: "ra-\(UUID().uuidString)")!)
        #expect(!store.isAvailable)
        #expect(store.proximity(of: Self.center) == .clear)
        store.apply(Self.set)
        #expect(store.proximity(of: Self.center) == .blocked && store.isInsideArea(Self.center))
    }

    @Test("Terms: whole words and phrases, case- and accent-insensitive")
    func terms() {
        let t = SensitiveTerms(["kem", "pintu masuk", "CCTV", "pengawal"])
        #expect(t.matches("Ada pengawal di sini"))
        #expect(t.matches("KEM tentera"))
        #expect(t.matches("Kém"), "accent-insensitive")
        #expect(t.matches("Lalu pintu masuk belakang"))
        #expect(t.matches("cctv: 3 unit"))
        #expect(!t.matches("Kemboja restoran"), "whole word only")
        #expect(!t.matches("pintu utama, masuk kiri"), "phrase words must be adjacent")
        #expect(!t.matches("Nasi lemak sedap"))
        #expect(!SensitiveTerms([]).matches("kem"))
    }

    @Test("\"Remove this sentence\" drops each sentence with a term and keeps the rest")
    func removeSentences() {
        let t = SensitiveTerms(["pengawal", "cctv"])
        let text = "Nasi lemak sedap. Pengawal tukar syif pukul 7! Parking luas? Ada CCTV di pintu belakang.\nBuka 24 jam"
        #expect(t.removingMatchingSentences(text) == "Nasi lemak sedap. Parking luas? Buka 24 jam")
        #expect(t.removingMatchingSentences("Pengawal ramai") == "")
        #expect(!t.matches(t.removingMatchingSentences(text)))
    }

    @Test("422 restricted_area is recognised from ProblemDetails.code")
    func problem() throws {
        let p = try JSONDecoder().decode(ProblemDetails.self, from: Data(#"{"status":422,"code":"restricted_area","detail":"Tidak boleh dikongsi di sini."}"#.utf8))
        let e = APIError.http(status: 422, problem: p)
        #expect(e.isRestrictedArea && e.localizedDescription == "Tidak boleh dikongsi di sini.")
        #expect(!APIError.http(status: 422, problem: ProblemDetails(code: "validation")).isRestrictedArea)
        #expect(!APIError.http(status: 404, problem: nil).isRestrictedArea)
    }

    @Test("heldForReview decodes on places and reviews; sensitive_location is a flag reason")
    func held() throws {
        let p = try JSON.makeDecoder().decode(PlaceSummary.self, from: Data(#"{"id":"c1","name":"Gerai","category":"restaurant","address":"","lat":3,"lng":101,"status":"hidden","heldForReview":true}"#.utf8))
        #expect(p.heldForReview == true && p.status == .hidden)
        #expect(FlagReason(rawValue: "sensitive_location") == .sensitiveLocation)
        let body = try JSONEncoder().encode(FlagRequest(reason: .sensitiveLocation))
        #expect(String(decoding: body, as: UTF8.self).contains("sensitive_location"))
    }
}
