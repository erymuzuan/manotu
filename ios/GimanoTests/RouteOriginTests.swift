import Foundation
import Testing
@testable import Gimano

/// Same cases as Android RouteOriginTest (a5b85f0).
@Suite("Route start: only a recent GPS fix is \"Your location\"")
struct RouteOriginTests {
    let klcc = LatLng(lat: 3.157938, lng: 101.712313)
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test("No fix is none")
    func none() {
        #expect(RouteOrigin.classify(fix: nil, at: nil, now: now) == .none)
        #expect(RouteOrigin.classify(fix: klcc, at: nil, now: now) == .none)
        #expect(RouteOrigin.classify(fix: klcc, at: Date(timeIntervalSince1970: 0), now: now) == .none)
    }

    @Test("A fix up to 2 minutes old is fresh")
    func fresh() {
        #expect(RouteOrigin.classify(fix: klcc, at: now - 5, now: now) == .fresh(klcc))
        #expect(RouteOrigin.classify(fix: klcc, at: now - 120, now: now) == .fresh(klcc))
    }

    @Test("Older fixes are stale")
    func stale() {
        #expect(RouteOrigin.classify(fix: klcc, at: now - 121, now: now) == .stale(klcc, age: 121))
        if case .stale = RouteOrigin.classify(fix: klcc, at: now - 3600, now: now) {} else { Issue.record("1 h old must be stale") }
    }

    @Test("A fix from the future beyond clock skew isn't trusted")
    func future() {
        if case .stale = RouteOrigin.classify(fix: klcc, at: now + 600, now: now) {} else { Issue.record("10 min in the future") }
        #expect(RouteOrigin.classify(fix: klcc, at: now + 30, now: now) == .fresh(klcc))
    }

    @Test("Same spot is under 50 m")
    func sameSpot() {
        let suria40m = LatLng(lat: 3.158298, lng: 101.712313)
        let far = LatLng(lat: 3.158938, lng: 101.712313)
        #expect(RouteOrigin.sameSpot(klcc, klcc))
        #expect(RouteOrigin.sameSpot(klcc, suria40m))
        #expect(!RouteOrigin.sameSpot(klcc, far))
    }

    @Test("Only a GPS start can be navigated; unknown and locating have no point")
    func startStates() {
        #expect(RouteStart.gps(klcc).isGPS && RouteStart.gps(klcc).point == klcc)
        let chosen = RouteStart.chosen(name: "Rumah", location: klcc, placeId: nil)
        #expect(!chosen.isGPS && chosen.point == klcc && chosen.chosenName == "Rumah")
        #expect(RouteStart.unknown.point == nil && RouteStart.locating.point == nil)
        #expect(RouteOrigin.waitForFix == 8 && RouteOrigin.maxFixAge == 120)
    }
}

@Suite("Route options before a drive")
struct RouteChoicesTests {
    // Our backend, 26 Oct: Shah Alam → Suria KLCC.
    static func route(_ id: String, _ minutes: Double, _ km: Double, toll: Double?, best: Bool = false, via: [String] = [],
                      reasons: [String] = [], hidden: String? = nil, summary: String = "") -> Route {
        Route(id: id, label: best ? "best" : "alternative", durationS: minutes * 60, distanceM: km * 1000, trafficDurationS: nil,
              summary: summary, trafficDescription: nil, hasTolls: toll != 0, tollEstimateMyr: toll, tollFareComplete: true,
              polyline: "", bbox: [], legs: [], reasons: reasons, viaRoads: via, hidden: hidden)
    }
    let e5 = route("e5", 43, 41.3, toll: 8.56, best: true, via: ["E5"], reasons: ["fastest"])
    let ft2 = route("ft2", 57, 32.0, toll: 3.00, via: ["FT2"], reasons: ["shortest", "lower_toll"])
    let nkve = route("nkve", 58, 56.3, toll: 4.06, via: ["E1"], reasons: ["lower_toll"])
    let copy = route("copy", 44, 42.0, toll: 8.56, hidden: "same_road")

    @Test("Hidden routes are kept apart")
    func hiddenApart() {
        #expect(RouteChoices.shown([e5, ft2, copy, nkve]).map(\.id) == ["e5", "ft2", "nkve"])
        #expect(RouteChoices.hidden([e5, ft2, copy, nkve]).map(\.id) == ["copy"])
    }

    @Test("Long motor trips with a choice open the list")
    func listFirst() {
        #expect(RouteChoices.listFirst([e5, ft2], vehicle: .car, hasStops: false))
        #expect(RouteChoices.listFirst([e5, ft2], vehicle: .motorcycle, hasStops: false))
        #expect(!RouteChoices.listFirst([e5, ft2], vehicle: .car, hasStops: true))
        #expect(!RouteChoices.listFirst([e5, ft2], vehicle: .walk, hasStops: false))
        #expect(!RouteChoices.listFirst([e5, copy], vehicle: .car, hasStops: false))
        var short = e5; short.distanceM = 9_700
        #expect(!RouteChoices.listFirst([short, ft2], vehicle: .car, hasStops: false))
    }

    @Test("Compares with the fastest")
    func compare() {
        let c = RouteChoices.compare(ft2, fastest: e5, shown: [e5, ft2, nkve])
        #expect(abs(c.extraS - 14 * 60) < 0.1)
        #expect(abs((c.tollSavedMyr ?? 0) - 5.56) < 0.001)
        #expect(abs((c.shorterM ?? 0) - 9_300) < 0.1)
        #expect(c.longerM == nil)
        #expect(c.avoids == ["E5", "E1"])
        #expect(RouteChoiceList.compareLine(c).hasPrefix("+14 min"))
        let dearer = RouteChoices.compare(e5, fastest: ft2, shown: [ft2, e5])
        #expect(dearer.tollSavedMyr == nil)
        #expect(abs((dearer.tollExtraMyr ?? 0) - 5.56) < 0.001)
    }

    @Test("Unknown fares save nothing")
    func unknownFare() {
        var unknown = ft2; unknown.tollFareComplete = false
        #expect(RouteChoices.compare(unknown, fastest: e5, shown: [e5, unknown]).tollSavedMyr == nil)
    }

    @Test("The road a route is known by")
    func via() {
        #expect(RouteChoices.via(e5) == "E5")   // no summary: its own main road
        #expect(RouteChoices.via(Self.route("c", 1, 1, toll: 0, via: ["E20"], summary: "Via E5 Lebuhraya Shah Alam")) == "E5")
        #expect(RouteChoices.via(Self.route("a", 1, 1, toll: 0, summary: "Via E23 Damansara Link")) == "E23")
        #expect(RouteChoices.via(Self.route("b", 1, 1, toll: 0, summary: "Via Jalan Klang Lama, FT2")) == "Jalan Klang Lama")
    }
}
