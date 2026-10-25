import Foundation
import Testing
@testable import Gimano

private let origin = LatLng(lat: 3.10, lng: 101.60)
private func east(_ m: Double, north: Double = 0) -> LatLng { Geo.offset(origin, northM: north, eastM: m) }

/// 10 km straight east, a right turn at 6 km (then 1 km south).
func cameraRoute(traffic: [TrafficSegment] = [], alerts: [AlertOnRoute] = []) -> (Route, RouteGeometry) {
    let corner = east(6000)
    let end = Geo.offset(corner, northM: -1000, eastM: 0)
    let pts = TestGeometry.densify([origin, corner, end], stepM: 50)
    let ci = TestGeometry.cornerIndices(corners: [origin, corner, end], in: pts)[0]
    let m = [
        Maneuver(type: .depart, instruction: "", streetName: "E2", exitNumber: nil, roadRef: nil, distanceM: 6000, durationS: 216,
                 beginShapeIndex: 0, endShapeIndex: ci, verbalPre: nil, verbalPost: nil),
        Maneuver(type: .right, instruction: "", streetName: "Jalan B", exitNumber: nil, roadRef: nil, distanceM: 1000, durationS: 90,
                 beginShapeIndex: ci, endShapeIndex: pts.count - 1, verbalPre: nil, verbalPost: nil),
        Maneuver(type: .arrive, instruction: "", streetName: nil, exitNumber: nil, roadRef: nil, distanceM: 0, durationS: 0,
                 beginShapeIndex: pts.count - 1, endShapeIndex: pts.count - 1, verbalPre: nil, verbalPost: nil),
    ]
    let r = Route(id: "cam", label: "best", durationS: 306, distanceM: 7000, trafficDurationS: 666, summary: "", trafficDescription: nil,
                  hasTolls: false, tollEstimateMyr: nil, polyline: Polyline.encode(pts), bbox: [101.6, 3.09, 101.66, 3.1],
                  legs: [RouteLeg(maneuvers: m)], trafficSegments: traffic, alerts: alerts)
    return (r, RouteGeometry(route: r))
}

@Suite("Camera modes")
struct CameraModeTests {
    let t0 = Date(timeIntervalSince1970: 50_000)

    @Test("Speed modes need 5 s past the threshold and use ±5 km/h hysteresis")
    func speedHysteresis() {
        var s = SpeedModeSelector()
        let v1 = s.update(speedKmh: 60, now: t0)
        #expect(v1 == .bandar)
        let v2 = s.update(speedKmh: 82, now: t0.addingTimeInterval(1))
        #expect(v2 == .bandar)       // 80 is not enough from Bandar
        let v3 = s.update(speedKmh: 86, now: t0.addingTimeInterval(2))
        #expect(v3 == .bandar)
        let v4 = s.update(speedKmh: 90, now: t0.addingTimeInterval(6))
        #expect(v4 == .bandar)       // 4 s
        let v5 = s.update(speedKmh: 90, now: t0.addingTimeInterval(7))
        #expect(v5 == .lebuhRaya)    // 5 s
        let v6 = s.update(speedKmh: 76, now: t0.addingTimeInterval(8))
        #expect(v6 == .lebuhRaya)    // back only below 75
        let v7 = s.update(speedKmh: 70, now: t0.addingTimeInterval(9))
        #expect(v7 == .lebuhRaya)
        let v8 = s.update(speedKmh: 88, now: t0.addingTimeInterval(11))
        #expect(v8 == .lebuhRaya)   // a dip resets the dwell
        let v9 = s.update(speedKmh: 70, now: t0.addingTimeInterval(12))
        #expect(v9 == .lebuhRaya)
        let v10 = s.update(speedKmh: 70, now: t0.addingTimeInterval(17))
        #expect(v10 == .bandar)
        #expect(SpeedModeSelector.target(speedKmh: 33, current: .perlahan) == .perlahan)
        #expect(SpeedModeSelector.target(speedKmh: 35, current: .perlahan) == .bandar)
        #expect(SpeedModeSelector.target(speedKmh: 27, current: .bandar) == .bandar)
        #expect(SpeedModeSelector.target(speedKmh: 24, current: .bandar) == .perlahan)
    }

    private func input(_ along: Double, speed: Double = 100, problems: [DriveProblem] = [], at s: Double = 0) -> CameraModeController.Input {
        CameraModeController.Input(now: t0.addingTimeInterval(s), speedKmh: speed, alongM: along, nextManeuverAlongM: along < 6000 ? 6000 : 7000,
                                   lastManeuverAlongM: along >= 6000 ? 6000 : nil, problems: problems)
    }

    @Test("Simpang: 300 m or 15 s before a maneuver, until 50 m after it")
    func simpang() {
        #expect(!CameraModeController.isSimpang(input(5000, speed: 50)))
        #expect(CameraModeController.isSimpang(input(5710, speed: 50)))
        #expect(CameraModeController.isSimpang(input(5600, speed: 100)))   // 400 m at 100 km/h = 14.4 s
        #expect(CameraModeController.isSimpang(input(6040, speed: 50)))
        #expect(!CameraModeController.isSimpang(input(6060, speed: 50)))
        var c = CameraModeController()
        let t = c.update(input(5800, speed: 50))
        #expect(t.mode == .simpang && t.zoom == 17.2 && t.pitch == 55)
    }

    @Test("Tinjau: once per jam ≤ 5 km ahead, zoom fits it (≥ 12.5), 1.2 s out + 6 s hold, then back")
    func tinjau() {
        let jam = DriveProblem(id: "jam-1", kind: .jam, startAlongM: 4800, lengthM: 1200, delayS: 360, start: east(4800))
        var c = CameraModeController()
        var t = c.update(input(100, problems: [jam], at: 1))
        #expect(t.mode == .tinjau)
        #expect(t.zoom >= 12.5 && t.zoom < 15.2 && t.pitch == 30 && t.easeS == 1.2)
        #expect(DriveCameraMode.roadAheadM(zoom: t.zoom) >= 4700)
        t = c.update(input(300, problems: [jam], at: 7))
        #expect(t.mode == .tinjau)
        t = c.update(input(400, problems: [jam], at: 8.3))
        #expect(t.mode == .lebuhRaya && t.easeS == 2)
        // Not again for the same jam.
        let v11 = c.update(input(500, problems: [jam], at: 20))
        #expect(v11.mode == .lebuhRaya)
    }

    @Test("Tinjau is skipped in Simpang and when a maneuver is within 20 s; Simpang wins over a running Tinjau")
    func tinjauPriority() {
        let jam = DriveProblem(id: "jam-2", kind: .jam, startAlongM: 8000, lengthM: 500, delayS: nil, start: east(8000))
        var c = CameraModeController()
        let v12 = c.update(input(5800, speed: 50, problems: [jam]))
        #expect(v12.mode == .simpang)
        #expect(!c.seenProblems.contains("jam-2"))
        var c2 = CameraModeController()
        // 6000 − 5500 = 500 m at 100 km/h = 18 s: not Simpang yet (> 15 s), but within 20 s, so no Tinjau.
        let v13 = c2.update(input(5500, speed: 100, problems: [jam]))
        #expect(v13.mode == .lebuhRaya)
        #expect(!c2.seenProblems.contains("jam-2"))
        var c3 = CameraModeController()
        let far = DriveProblem(id: "jam-3", kind: .jam, startAlongM: 4000, lengthM: 500, delayS: nil, start: east(4000))
        let v14 = c3.update(input(1000, problems: [far]))
        #expect(v14.mode == .tinjau)
        let v15 = c3.update(input(5750, problems: [far], at: 2))
        #expect(v15.mode == .simpang)
    }

    @Test("Problems on the route: jams merged from traffic level ≥ 3, closures and accidents from alerts")
    func problems() {
        let report = Report(id: "acc", type: .accident, subtype: nil, lat: east(3000).lat, lng: east(3000).lng, heading: nil, street: nil,
                            reportedBy: nil, createdAt: .now, expiresAt: .now, confirmations: 1, thanks: 0)
        let police = Report(id: "pol", type: .police, subtype: nil, lat: east(2000).lat, lng: east(2000).lng, heading: nil, street: nil,
                            reportedBy: nil, createdAt: .now, expiresAt: .now, confirmations: 1, thanks: 0)
        let (r, g) = cameraRoute(traffic: [TrafficSegment(fromIndex: 20, toIndex: 30, level: 3), TrafficSegment(fromIndex: 31, toIndex: 40, level: 4),
                                           TrafficSegment(fromIndex: 60, toIndex: 70, level: 2)],
                                 alerts: [AlertOnRoute(report: report, distanceAlongRouteM: 3000), AlertOnRoute(report: police, distanceAlongRouteM: 2000)])
        let p = DriveProblem.onRoute(r, geometry: g)
        #expect(p.count == 2)
        #expect(p[0].kind == .jam && abs(p[0].startAlongM - g.distance(atIndex: 20)) < 0.1)
        #expect(abs(p[0].lengthM! - (g.distance(atIndex: 40) - g.distance(atIndex: 20))) < 0.1)
        #expect(p[0].delayS == 360)
        #expect(p[1].kind == .accident && p[1].id == "alert-acc")
        #expect(p[0].bannerText(distanceM: 4800) == "Traffic 4.8 km ahead · 1.0 km long · +6 min")
        #expect(p[1].bannerText(distanceM: 3200) == "Accident 3.2 km ahead")
    }
}

@Suite("Steady arrow")
struct SteadyArrowTests {
    let t0 = Date(timeIntervalSince1970: 60_000)

    @Test("Snap within 25 m (heading within 60° above 10 km/h); release only beyond 40 m for 3 s")
    func snapHysteresis() {
        var s = SnapHysteresis()
        let v16 = s.update(distanceFromRouteM: 30, speedKmh: 50, course: 90, routeBearing: 90, now: t0)
        #expect(!v16)
        let v17 = s.update(distanceFromRouteM: 10, speedKmh: 50, course: 180, routeBearing: 90, now: t0)
        #expect(!v17)
        let v18 = s.update(distanceFromRouteM: 10, speedKmh: 5, course: 180, routeBearing: 90, now: t0)
        #expect(v18)
        let v19 = s.update(distanceFromRouteM: 39, speedKmh: 50, course: 90, routeBearing: 90, now: t0.addingTimeInterval(1))
        #expect(v19)
        let v20 = s.update(distanceFromRouteM: 45, speedKmh: 50, course: 90, routeBearing: 90, now: t0.addingTimeInterval(2))
        #expect(v20)
        let v21 = s.update(distanceFromRouteM: 45, speedKmh: 50, course: 90, routeBearing: 90, now: t0.addingTimeInterval(4.9))
        #expect(v21)
        let v22 = s.update(distanceFromRouteM: 45, speedKmh: 50, course: 90, routeBearing: 90, now: t0.addingTimeInterval(5))
        #expect(!v22)
    }

    @Test("Heading: low-pass filtered, never faster than 90°/s")
    func heading() {
        var h = HeadingFilter()
        h.target = 10
        let v23 = h.step(dt: 0.016)
        #expect(v23 == 10)
        h.target = 190
        var v = 10.0
        for _ in 0..<10 { v = h.step(dt: 0.1) }
        #expect(abs(Geo.angleDelta(10, v)) <= 90.5)
        for _ in 0..<60 { v = h.step(dt: 0.1) }
        #expect(abs(Geo.angleDelta(v, 190)) < 1)
        // Across north: 350 → 10 goes the short way.
        var n = HeadingFilter()
        n.target = 350; _ = n.step(dt: 0)
        n.target = 10
        let x = n.step(dt: 0.1)
        #expect(x > 350 || x < 10)
    }

    @Test("The arrow moves along the route between fixes over the measured interval, rolls ≤ 1 s, stops at the maneuver")
    func animator() {
        let (_, g) = cameraRoute()
        var a = PuckAnimator(geometry: g)
        func target(_ along: Double, stop: Double? = 6000) -> PuckAnimator.Target {
            PuckAnimator.Target(point: g.point(atAlongM: along), alongM: along, speedMps: 20, stopAlongM: stop)
        }
        a.push(target(1000), at: 10)
        #expect(abs(a.sample(at: 10).alongM! - 1000) < 0.01)
        // After the first fix it rolls on at 20 m/s (0.7 s past its 0.3 s settle = 1014 m) …
        #expect(abs(a.sample(at: 11).alongM! - 1014) < 0.5)
        a.push(target(1020), at: 11)                    // … and a 1 s fix interval gives a 1 s animation from there.
        #expect(abs(a.sample(at: 11.5).alongM! - 1017) < 0.5)
        #expect(abs(a.sample(at: 12).alongM! - 1020) < 0.5)
        #expect(abs(a.sample(at: 12.5).alongM! - 1030) < 0.5) // rolling on at 20 m/s
        #expect(abs(a.sample(at: 15).alongM! - 1040) < 0.5)   // held after 1 s
        a.push(target(1060), at: 16.5)                  // 5.5 s gap → clamped to 1.2 s
        #expect(a.duration == 1.2)
        // Never extrapolated past the maneuver point.
        var b = PuckAnimator(geometry: g)
        b.push(target(5990), at: 0)
        b.push(target(5995), at: 1)
        #expect(b.sample(at: 2.9).alongM! <= 6000)
        // Off the route: straight-line interpolation.
        var c = PuckAnimator(geometry: g)
        c.push(PuckAnimator.Target(point: east(100, north: 100), alongM: nil, speedMps: 10), at: 0)
        c.push(PuckAnimator.Target(point: east(200, north: 100), alongM: nil, speedMps: 10), at: 0.5)
        #expect(abs(Geo.distance(c.sample(at: 0.65).point, east(130, north: 100))) < 1)
    }

    @Test("Eased camera values move smoothly to the target")
    func eased() {
        var z = EasedValue(16)
        z.set(15.2, over: 2, at: 0)
        #expect(z.value(at: 0) == 16)
        #expect(abs(z.value(at: 1) - 15.6) < 0.01)
        #expect(z.value(at: 2) == 15.2)
        z.set(17.2, over: 2, at: 1)                     // retarget mid-way starts from the current value
        #expect(abs(z.value(at: 1) - 15.6) < 0.01)
    }
}

@Suite("Drive motion")
@MainActor
struct DriveMotionTests {
    @Test("Fixes in, smooth frames out: the arrow sits between fixes and follows the road direction")
    func frames() throws {
        let (r, g) = cameraRoute()
        let m = DriveMotion(route: r, geometry: g)
        var now = 100.0
        m.clock = { now }
        func fix(_ along: Double, _ s: Double) -> (LocationFix, Snap) {
            let p = g.point(atAlongM: along)
            return (LocationFix(coordinate: p, speedKmh: 72, course: 90, accuracyM: 5, timestamp: Date(timeIntervalSince1970: s)),
                    Snap(segment: 0, distanceAlongM: along, distanceFromRouteM: 0, point: p))
        }
        #expect(m.frame(at: now) == nil)
        let (f1, s1) = fix(1000, 0)
        m.push(fix: f1, snap: s1, snapped: true)
        now = 101
        let (f2, s2) = fix(1020, 1)
        m.push(fix: f2, snap: s2, snapped: true)
        let mid = try #require(m.frame(at: 101.5))
        #expect(abs(Geo.distance(mid.point, g.point(atAlongM: 1017))) < 0.5)
        #expect(abs(Geo.angleDelta(mid.heading, 90)) < 1)
        #expect(m.mode == .bandar)
        #expect(m.frame(at: 101.5) == mid)
    }

    @Test("A jam 4 km ahead on the highway starts Tinjau once, with its banner text")
    func tinjauFromRoute() throws {
        let (r0, _) = cameraRoute()
        let r = r0.withDebugJam(atM: 4000)
        let g = RouteGeometry(route: r)
        let m = DriveMotion(route: r, geometry: g)
        var now = 0.0
        m.clock = { now }
        var started: [String] = []
        m.onTinjau = { _, text in started.append(text) }
        for k in 0..<5 {
            now = Double(k)
            let along = 100 + Double(k) * 28
            let p = g.point(atAlongM: along)
            m.push(fix: LocationFix(coordinate: p, speedKmh: 100, course: 90, accuracyM: 5, timestamp: Date(timeIntervalSince1970: now)),
                   snap: Snap(segment: 0, distanceAlongM: along, distanceFromRouteM: 0, point: p), snapped: true)
        }
        #expect(m.mode == .tinjau)
        #expect(started.count == 1)
        #expect(started.first?.hasPrefix("Traffic 3.9 km ahead · 1.2 km long") == true)
    }
}

