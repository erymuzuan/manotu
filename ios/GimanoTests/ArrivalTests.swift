import Foundation
import Testing
@testable import Gimano

/// 500 m eastbound to the road point in front of a mall; its main entrance 25 m north (on the left), the pin 70 m north.
private enum ArrivalFixture {
    static let start = LatLng(lat: 3.117, lng: 101.672)
    static let end = Geo.offset(start, northM: 0, eastM: 500)
    static let entrance = Geo.offset(end, northM: 25, eastM: 0)
    static let pin = Geo.offset(end, northM: 70, eastM: 5)

    static func route(arrival: NavigationPoint?) -> Route {
        let pts = TestGeometry.densify([start, end], stepM: 25)
        let m = [
            Maneuver(type: .depart, instruction: "", streetName: "Jalan A", exitNumber: nil, roadRef: nil, distanceM: 500, durationS: 60,
                     beginShapeIndex: 0, endShapeIndex: pts.count - 1, verbalPre: nil, verbalPost: nil),
            Maneuver(type: .arrive, instruction: "", streetName: nil, exitNumber: nil, roadRef: nil, distanceM: 0, durationS: 0,
                     beginShapeIndex: pts.count - 1, endShapeIndex: pts.count - 1, verbalPre: nil, verbalPost: nil),
        ]
        return Route(id: "arr", label: "best", durationS: 60, distanceM: 500, trafficDurationS: nil, summary: "", trafficDescription: nil,
                     hasTolls: false, tollEstimateMyr: nil, polyline: Polyline.encode(pts), bbox: [101.672, 3.117, 101.677, 3.118],
                     legs: [RouteLeg(maneuvers: m)], trafficSegments: [], alerts: [], arrival: arrival)
    }

    static let main = NavigationPoint(lat: entrance.lat, lng: entrance.lng, issueId: nil, source: .osmEntrance, kind: "main")
}

@Suite("Arriving at the entrance")
struct ArrivalTests {
    @Test("Decodes Route.arrival and Place.navigationPoint (source, kind; unknown sources tolerated)")
    func decode() throws {
        let json = #"{"lat":3.1180302,"lng":101.6768485,"source":"osm_entrance","kind":"main"}"#
        let p = try JSONDecoder().decode(NavigationPoint.self, from: Data(json.utf8))
        #expect(p.source == .osmEntrance && p.kind == "main" && p.issueId == nil)
        let odd = try JSONDecoder().decode(NavigationPoint.self, from: Data(#"{"lat":1,"lng":2,"source":"magic","issueId":"i1"}"#.utf8))
        #expect(odd.source == .other && odd.issueId == "i1")
    }

    @Test("Arrived at ≤ 30 m along the route (on it) or ≤ 40 m from the pin, whichever first")
    func rule() {
        #expect(ArrivalRule.arrived(remainingM: 25, onRoute: true, distanceToPinM: 90))
        #expect(!ArrivalRule.arrived(remainingM: 25, onRoute: false, distanceToPinM: 90))
        #expect(ArrivalRule.arrived(remainingM: 200, onRoute: false, distanceToPinM: 39))
        #expect(!ArrivalRule.arrived(remainingM: 31, onRoute: true, distanceToPinM: 41))
    }

    @Test("Last metres: blue to the entrance, grey on to a pin more than 15 m from the route end")
    func lastMetres() {
        let a = LastMetres.make(routeEnd: ArrivalFixture.end, arrival: ArrivalFixture.entrance, pin: ArrivalFixture.pin)
        #expect(a.blue == [ArrivalFixture.end, ArrivalFixture.entrance])
        #expect(a.grey == [ArrivalFixture.entrance, ArrivalFixture.pin])
        let near = LastMetres.make(routeEnd: ArrivalFixture.end, arrival: nil, pin: Geo.offset(ArrivalFixture.end, northM: 10, eastM: 0))
        #expect(near.blue.isEmpty && near.grey.isEmpty)
        let noEntrance = LastMetres.make(routeEnd: ArrivalFixture.end, arrival: nil, pin: ArrivalFixture.pin)
        #expect(noEntrance.blue.isEmpty && noEntrance.grey == [ArrivalFixture.end, ArrivalFixture.pin])
    }

    @Test("Side of the entrance relative to the direction of travel, and its distance from the road")
    func side() throws {
        let r = ArrivalFixture.route(arrival: ArrivalFixture.main)
        let info = try #require(ArrivalInfo.make(geometry: RouteGeometry(route: r), arrival: r.arrival, pin: ArrivalFixture.pin))
        #expect(info.what == .mainEntrance && info.side == .left)
        #expect(info.text == "Main entrance on your left · 25 m from the road")
        let south = Geo.offset(ArrivalFixture.end, northM: -18, eastM: 0)
        let other = NavigationPoint(lat: south.lat, lng: south.lng, issueId: nil, source: .osmEntrance, kind: "yes")
        let right = try #require(ArrivalInfo.make(geometry: RouteGeometry(route: r), arrival: other, pin: ArrivalFixture.pin))
        #expect(right.text == "Entrance on your right · 20 m from the road")
        let outline = NavigationPoint(lat: south.lat, lng: south.lng, issueId: nil, source: .outline, kind: nil)
        #expect(ArrivalInfo.make(geometry: RouteGeometry(route: r), arrival: outline, pin: ArrivalFixture.pin)?.sideText == "The place is on your right")
        #expect(ArrivalInfo.make(geometry: RouteGeometry(route: r), arrival: nil, pin: Geo.offset(ArrivalFixture.end, northM: 8, eastM: 0)) == nil)
    }
}

@Suite("Arrival in a navigation session")
@MainActor
struct ArrivalSessionTests {
    private func session(_ r: Route, placeId: String? = "w922804567") -> NavigationSession {
        let voice = VoiceGuide()
        voice.mode = .off
        return NavigationSession(destination: Destination(name: "Mid Valley Megamall", address: "", location: ArrivalFixture.pin, placeId: placeId),
                                 route: r, vehicle: .car, avoid: AvoidOptions(), repo: DemoRepository(latency: .zero), voice: voice)
    }

    private func fix(_ p: LatLng) -> LocationFix { LocationFix(coordinate: p, speedKmh: 20, course: 90, accuracyM: 5, timestamp: .now) }

    @Test("Arrives near the end of the route, with the side line and the dotted last metres")
    func arrives() {
        let nav = session(ArrivalFixture.route(arrival: ArrivalFixture.main))
        defer { nav.stop() }
        #expect(nav.lastMetres.blue.count == 2 && nav.lastMetres.grey.count == 2)
        #expect(nav.arrivalInfo?.side == .left)
        #expect(nav.canReportWrongEntrance)
        nav.handle(fix(Geo.offset(ArrivalFixture.start, northM: 0, eastM: 300)))
        #expect(!nav.arrived)
        nav.handle(fix(Geo.offset(ArrivalFixture.start, northM: 0, eastM: 475)))
        #expect(nav.arrived)
    }

    @Test("Arrives by the pin when the road ends farther than 30 m away (e.g. a parallel street)")
    func arrivesByPin() {
        let nav = session(ArrivalFixture.route(arrival: nil), placeId: "pin:1,2")
        defer { nav.stop() }
        #expect(!nav.canReportWrongEntrance)
        nav.handle(fix(Geo.offset(ArrivalFixture.start, northM: 0, eastM: 300)))
        #expect(!nav.arrived)
        // 70 m off the road and 35 m from the pin: off-route, but at the place.
        nav.handle(fix(Geo.offset(ArrivalFixture.pin, northM: 0, eastM: 35)))
        #expect(nav.arrived)
    }
}
