import Foundation
import Testing
@testable import Gimano

/// docs/driving.md §6.3 (board NavDilalui): the travelled part behind the arrow, traffic only ahead, reset on reroute.
@Suite("Travelled route")
struct TravelledRouteTests {
    /// Five vertices 100 m apart going north.
    let points: [LatLng] = (0..<5).map { Geo.offset(LatLng(lat: 3.1, lng: 101.6), northM: Double($0) * 100, eastM: 0) }
    var cumulative: [Double] { Geo.cumulativeDistances(points) }

    @Test("Split at 150 m: behind ends at the cut, ahead starts at it, nothing lost")
    func splitMiddle() {
        let s = TravelledRoute.split(points: points, cumulative: cumulative, alongM: 150)
        #expect(s.behind.count == 3)          // v0, v1, cut
        #expect(s.ahead.count == 4)           // cut, v2, v3, v4
        #expect(s.aheadFromIndex == 2)
        #expect(s.behind.last == s.cut && s.ahead.first == s.cut)
        #expect(abs(Geo.distance(points[0], s.cut) - 150) < 0.5)
        #expect(abs(Geo.cumulativeDistances(s.behind).last! + Geo.cumulativeDistances(s.ahead).last! - cumulative.last!) < 0.5)
    }

    @Test("At the start nothing is travelled; past the end everything is")
    func splitEnds() {
        let a = TravelledRoute.split(points: points, cumulative: cumulative, alongM: 0)
        #expect(a.behind.isEmpty && a.ahead.count == 5 && a.aheadFromIndex == 1)
        let b = TravelledRoute.split(points: points, cumulative: cumulative, alongM: 10_000)
        #expect(b.behind.count == 5 && b.behind.last == points[4] && b.ahead.count == 1 && b.aheadFromIndex == 5)
        // Exactly on a vertex: that vertex is behind.
        let c = TravelledRoute.split(points: points, cumulative: cumulative, alongM: cumulative[2])
        #expect(c.aheadFromIndex == 3)
    }

    @Test("Traffic colours only ahead: behind dropped, straddling clipped at the arrow, ahead kept")
    func trafficAhead() {
        let segs = [TrafficSegment(fromIndex: 0, toIndex: 1, level: 3),   // behind
                    TrafficSegment(fromIndex: 1, toIndex: 3, level: 4),   // straddles 150 m
                    TrafficSegment(fromIndex: 3, toIndex: 4, level: 2),   // ahead
                    TrafficSegment(fromIndex: 2, toIndex: 2, level: 2)]   // empty
        let s = TravelledRoute.split(points: points, cumulative: cumulative, alongM: 150)
        let out = TravelledRoute.trafficAhead(points: points, segments: segs, split: s)
        #expect(out.map(\.level) == [4, 2])
        #expect(out[0].points.first == s.cut && out[0].points.count == 3)
        #expect(out[1].points == [points[3], points[4]])
    }

    @Test("Progress only grows, is throttled, and starts again on a new route")
    func progress() {
        var p = TravelledProgress()
        func upd(routeKey: String?, alongM: Double?, at t: Double) -> Bool { p.update(routeKey: routeKey, alongM: alongM, at: t) }
        #expect(upd(routeKey: "r1", alongM: 10, at: 0))           // first draw
        #expect(!upd(routeKey: "r1", alongM: 10.5, at: 1))        // moved < 1 m
        #expect(upd(routeKey: "r1", alongM: 20, at: 1.01))
        #expect(!upd(routeKey: "r1", alongM: 5, at: 2))           // backwards jitter never un-travels
        #expect(p.alongM == 20)
        #expect(!upd(routeKey: "r1", alongM: nil, at: 3))         // off the route: keep
        #expect(p.alongM == 20)
        #expect(upd(routeKey: "r1", alongM: 30, at: 3.0))
        #expect(!upd(routeKey: "r1", alongM: 40, at: 3.02))       // 20 ms after the last draw: wait
        #expect(upd(routeKey: "r1", alongM: 40, at: 3.2))
        // Reroute: only the new route, nothing travelled on it yet.
        #expect(upd(routeKey: "r2", alongM: nil, at: 3.21))
        #expect(p.alongM == 0)
        #expect(!upd(routeKey: nil, alongM: 50, at: 4))
    }

    @Test("Colours: light grey #C3CAD6 on a white casing")
    func colours() {
        #expect(TravelledRoute.lineHex == 0xC3CAD6)
        #expect(TravelledRoute.casingHex == 0xFFFFFF)
    }

    @MainActor
    @Test("The drawn frame carries the arrow's along-route distance (the travelled line follows the animated arrow)")
    func frameAlong() throws {
        let (r, g) = cameraRoute()
        let m = DriveMotion(route: r, geometry: g)
        var now = 100.0
        m.clock = { now }
        let p = g.point(atAlongM: 120)
        let fix = LocationFix(coordinate: p, speedKmh: 36, course: 90, accuracyM: 5, timestamp: .now)
        let snap = Snap(segment: 0, distanceAlongM: 120, distanceFromRouteM: 0, point: p)
        m.push(fix: fix, snap: snap, snapped: true)
        now += 0.01
        let f = try #require(m.frame(at: now))
        #expect(abs((f.alongM ?? -1) - 120) < 1)
    }
}
