import Foundation
import Testing
@testable import Gimano

/// A straight 6 km eastbound expressway with three plazas: an open plaza at 2 km (server distance), a closed-system
/// entry at 3.5 km (projected from lat/lng, 20 m off the road) and a plaza 2 km off the route (ignored).
private enum TollFixture {
    static let start = LatLng(lat: 3.05, lng: 101.60)
    static func at(_ eastM: Double, northM: Double = 0) -> LatLng { Geo.offset(start, northM: northM, eastM: eastM) }

    static func route(fareComplete: Bool = true) -> Route {
        let pts = TestGeometry.densify([at(0), at(6000)], stepM: 100)
        let maneuvers = [
            Maneuver(type: .depart, instruction: "", streetName: "E2", exitNumber: nil, roadRef: "E2", distanceM: 6000, durationS: 216,
                     beginShapeIndex: 0, endShapeIndex: pts.count - 1, verbalPre: nil, verbalPost: nil),
            Maneuver(type: .arrive, instruction: "", streetName: nil, exitNumber: nil, roadRef: nil, distanceM: 0, durationS: 0,
                     beginShapeIndex: pts.count - 1, endShapeIndex: pts.count - 1, verbalPre: nil, verbalPost: nil),
        ]
        let open = at(2000)
        let entry = at(3500, northM: 20)
        let far = at(4000, northM: 2000)
        let tolls = [
            TollPlaza(plazaId: "entry", name: "Plaza Tol Sungai Besi", highway: "E2", lat: entry.lat, lng: entry.lng, fareMyr: 0,
                      system: "closed_entry", source: nil),
            TollPlaza(plazaId: "open", name: "Plaza Tol Petaling Jaya", highway: "E11", lat: open.lat, lng: open.lng, fareMyr: 2.10,
                      system: "open", source: nil, distanceAlongRouteM: 2000),
            TollPlaza(plazaId: "far", name: "Plaza Tol Elsewhere", highway: "E5", lat: far.lat, lng: far.lng, fareMyr: 3, system: "open", source: nil),
        ]
        return Route(id: "toll-route", label: "best", durationS: 216, distanceM: 6000, trafficDurationS: nil, summary: "Via E2",
                     trafficDescription: nil, vehicle: .car, hasTolls: true, tollEstimateMyr: 2.10, tollFareComplete: fareComplete, tolls: tolls,
                     polyline: Polyline.encode(pts), bbox: [101.60, 3.05, 101.66, 3.06], legs: [RouteLeg(maneuvers: maneuvers)],
                     trafficSegments: [], alerts: [])
    }
}

@Suite("Toll ahead")
struct TollAheadTests {
    private let t0 = Date(timeIntervalSince1970: 10_000)

    @Test("Plazas are placed by the server's distance, else projected; plazas off the route are dropped")
    func placement() {
        let r = TollFixture.route()
        let tolls = TollTracker.place(r.tolls!, on: RouteGeometry(route: r))
        #expect(tolls.map(\.id) == ["open", "entry"])
        #expect(tolls[0].alongM == 2000)
        #expect(abs(tolls[1].alongM - 3500) < 5)
    }

    @Test("Banner from 1 km ahead at highway speed, 500 m below 60 km/h; spoken once per plaza")
    func bannerDistance() {
        let r = TollFixture.route()
        var t = TollTracker(route: r, geometry: RouteGeometry(route: r))
        #expect(t.update(alongM: 900, speedKmh: 100, now: t0) == nil)
        #expect(t.current == nil)
        let first = t.update(alongM: 1010, speedKmh: 100, now: t0)
        #expect(first?.id == "open")
        #expect(t.current?.id == "open")
        #expect(t.distanceAhead(t.current!, alongM: 1010) == 990)
        // Not spoken again; slowing down does not hide it.
        #expect(t.update(alongM: 1200, speedKmh: 20, now: t0) == nil)
        #expect(t.current?.id == "open")

        var slow = TollTracker(route: r, geometry: RouteGeometry(route: r))
        #expect(slow.update(alongM: 1200, speedKmh: 40, now: t0) == nil)
        #expect(slow.current == nil)
        #expect(slow.update(alongM: 1510, speedKmh: 40, now: t0)?.id == "open")
    }

    @Test("Hidden 10 s after passing; the running total adds the fare; a closed entry adds nothing")
    func passing() {
        let r = TollFixture.route()
        var t = TollTracker(route: r, geometry: RouteGeometry(route: r))
        _ = t.update(alongM: 1500, speedKmh: 90, now: t0)
        _ = t.update(alongM: 2010, speedKmh: 90, now: t0)
        #expect(t.paidMyr == 2.10)
        #expect(t.current?.id == "open")
        _ = t.update(alongM: 2200, speedKmh: 90, now: t0.addingTimeInterval(9))
        #expect(t.current?.id == "open")
        _ = t.update(alongM: 2300, speedKmh: 90, now: t0.addingTimeInterval(10.5))
        #expect(t.current == nil)
        // Closed entry: announced, nothing paid there.
        let entry = t.update(alongM: 2600, speedKmh: 90, now: t0.addingTimeInterval(20))
        #expect(entry?.id == "entry")
        #expect(entry?.fare == nil)
        _ = t.update(alongM: 3600, speedKmh: 90, now: t0.addingTimeInterval(60))
        #expect(t.paidMyr == 2.10)
        #expect(t.passed == ["open", "entry"])
    }

    @Test("The next plaza in range replaces a passed one at once")
    func nextReplacesPassed() {
        let r = TollFixture.route()
        var t = TollTracker(route: r, geometry: RouteGeometry(route: r))
        _ = t.update(alongM: 1500, speedKmh: 120, now: t0)
        _ = t.update(alongM: 2010, speedKmh: 120, now: t0)
        #expect(t.current?.id == "open")
        #expect(t.update(alongM: 2600, speedKmh: 120, now: t0.addingTimeInterval(2))?.id == "entry")
        #expect(t.current?.id == "entry")
    }

    @Test("Reroutes keep what was announced and paid")
    func keepsAcrossReroute() {
        let r = TollFixture.route()
        var t = TollTracker(route: r, geometry: RouteGeometry(route: r))
        _ = t.update(alongM: 1500, speedKmh: 90, now: t0)
        _ = t.update(alongM: 2100, speedKmh: 90, now: t0)
        var again = TollTracker(route: r, geometry: RouteGeometry(route: r), announced: t.announced, passed: t.passed, paidMyr: t.paidMyr)
        #expect(again.update(alongM: 1500, speedKmh: 90, now: t0) == nil)
        #expect(again.paidMyr == 2.10)
    }

    @Test("Banner text: short plaza names and the three fare cases")
    func text() {
        #expect(TollText.shortName("Plaza Tol Sungai Besi") == "Sungai Besi")
        #expect(TollText.shortName("Jalan Duta Toll Plaza") == "Jalan Duta")
        #expect(TollText.shortName("Plaza Tol") == "Plaza Tol")
        let r = TollFixture.route()
        let tolls = TollTracker.place(r.tolls!, on: RouteGeometry(route: r))
        #expect(TollText.fareLine(tolls[0]) == nil)
        #expect(TollText.fareLine(tolls[1]) == "Toll entry · pay at the exit")
        var unknown = tolls[0]
        unknown.plaza.fareMyr = nil
        #expect(TollText.fareLine(unknown) == "Toll ahead · fare unknown")
        #expect(TollText.carSubtitle(tolls[0], distanceM: 900) == "900 m · RM 2.10")
    }

    @Test("Voice: fare in words, closed entry and unknown fare, in English and Malay")
    func speech() {
        let r = TollFixture.route()
        var tolls = TollTracker.place(r.tolls!, on: RouteGeometry(route: r))
        tolls[0].plaza.name = "Plaza Tol Sungai Besi"
        #expect(TollSpeech.text(for: tolls[0], language: "en") == "Sungai Besi toll ahead, two ringgit ten.")
        #expect(TollSpeech.text(for: tolls[0], language: "ms") == "Tol Sungai Besi di hadapan, dua ringgit sepuluh sen.")
        #expect(TollSpeech.text(for: tolls[1], language: "en") == "Sungai Besi toll entry ahead.")
        #expect(TollSpeech.text(for: tolls[1], language: "ms") == "Tol masuk Sungai Besi di hadapan.")
        tolls[0].plaza.fareMyr = nil
        #expect(TollSpeech.text(for: tolls[0], language: "ms") == "Tol Sungai Besi di hadapan.")
    }

    @Test("Money in words")
    func money() {
        #expect(MoneyWords.english(2.10) == "two ringgit ten")
        #expect(MoneyWords.english(5.25) == "five ringgit twenty-five")
        #expect(MoneyWords.english(12) == "twelve ringgit")
        #expect(MoneyWords.english(0.5) == "fifty sen")
        #expect(MoneyWords.malay(2.10) == "dua ringgit sepuluh sen")
        #expect(MoneyWords.malay(5.25) == "lima ringgit dua puluh lima sen")
        #expect(MoneyWords.malay(11.19) == "sebelas ringgit sembilan belas sen")
        #expect(MoneyWords.malayNumber(100) == "seratus")
        #expect(MoneyWords.malayNumber(250) == "dua ratus lima puluh")
        #expect(MoneyWords.englishNumber(101) == "one hundred and one")
    }

    @Test("Trip totals: so far and the estimate, 'from' when not every fare is known")
    func totals() {
        #expect(TollTotals(paidMyr: 2.1, estimateMyr: 9.35, estimateComplete: true).text == "Tolls so far RM 2.10 · estimate RM 9.35")
        #expect(TollTotals(paidMyr: 0, estimateMyr: 4, estimateComplete: false).text == "Tolls so far RM 0.00 · estimate from RM 4.00")
        #expect(TollTotals(paidMyr: 1, estimateMyr: nil, estimateComplete: true).text == "Tolls so far RM 1.00")
    }
}

@Suite("Toll ahead in a navigation session")
@MainActor
struct TollSessionTests {
    @Test("Driving past a plaza shows the banner, then adds its fare to the trip total")
    func session() {
        let voice = VoiceGuide()
        voice.mode = .off
        let r = TollFixture.route()
        let nav = NavigationSession(destination: Destination(name: "Seremban", address: "", location: TollFixture.at(6000)), route: r,
                                    vehicle: .car, avoid: AvoidOptions(), repo: DemoRepository(latency: .zero), voice: voice)
        defer { nav.stop() }
        var announced: [String] = []
        nav.onTollAhead = { announced.append($0.id) }
        let t0 = Date()
        func drive(_ eastM: Double, _ s: Double) {
            nav.handle(LocationFix(coordinate: TollFixture.at(eastM), speedKmh: 100, course: 90, accuracyM: 5, timestamp: t0.addingTimeInterval(s)))
        }
        drive(500, 0)
        #expect(nav.tollAhead == nil)
        drive(1100, 20)
        #expect(nav.tollAhead?.id == "open")
        #expect(abs(nav.distanceToToll(nav.tollAhead!) - 900) < 5)
        #expect(nav.tollTotals.estimateMyr == 2.10)
        drive(2100, 40)
        #expect(nav.tollTotals.paidMyr == 2.10)
        drive(2700, 60)
        #expect(nav.tollAhead?.id == "entry")
        #expect(announced == ["open", "entry"])
        #expect(nav.showsTollTotals)
    }
}
