import Foundation
import Observation

#if DEBUG
extension Route {
    /// DEBUG route replays only: a level-4 jam from `atM` for `lengthM` along this route, with a 6 min delay.
    func withDebugJam(atM: Double, lengthM: Double = 1200) -> Route {
        let g = RouteGeometry(route: self)
        guard g.points.count > 2 else { return self }
        let from = g.cumulative.firstIndex { $0 >= atM } ?? 0
        let to = g.cumulative.firstIndex { $0 >= atM + lengthM } ?? (g.points.count - 1)
        guard to > from else { return self }
        var r = self
        r.trafficSegments = (trafficSegments ?? []) + [TrafficSegment(fromIndex: from, toIndex: to, level: 4)]
        r.trafficDurationS = (trafficDurationS ?? durationS) + 360
        r.durationS = durationS
        return r
    }
}
#endif

/// One frame of the drive as the maps draw it: the animated arrow and the camera that follows it.
struct DriveFrame: Sendable, Equatable {
    var point: LatLng
    var heading: Double
    var zoom: Double
    var pitch: Double
    /// Arrow position as a fraction of the map height from the top.
    var puckY: Double
    var mode: DriveCameraMode
}

/// The moving picture of a drive (docs/driving.md §2–3), shared by the phone map and the car screen: fixes go in,
/// per-frame arrow positions and camera values come out. Both maps call `frame(at:)` from their display links.
@MainActor
@Observable
final class DriveMotion {
    /// Current camera mode (diagnostics, car screen).
    private(set) var mode: DriveCameraMode = .bandar
    /// The jam / closure Tinjau is showing, and how far ahead it starts (banner).
    private(set) var tinjauProblem: DriveProblem?
    private(set) var tinjauDistanceM: Double = 0
    /// Called when Tinjau starts on a problem (the car screen shows its text as an alert).
    @ObservationIgnored var onTinjau: ((DriveProblem, String) -> Void)?
    /// Monotonic seconds (same clock as CADisplayLink / CACurrentMediaTime).
    @ObservationIgnored var clock: () -> Double = { ProcessInfo.processInfo.systemUptime }

    @ObservationIgnored private(set) var geometry: RouteGeometry
    @ObservationIgnored private var animator: PuckAnimator
    @ObservationIgnored private var heading = HeadingFilter()
    @ObservationIgnored private var controller = CameraModeController()
    @ObservationIgnored private var zoom = EasedValue(DriveCameraMode.bandar.zoom)
    @ObservationIgnored private var pitch = EasedValue(DriveCameraMode.bandar.pitch)
    @ObservationIgnored private var puckY = EasedValue(DriveCameraMode.bandar.puckY)
    @ObservationIgnored private var problems: [DriveProblem]
    /// Distance along the route of each maneuver after the departure.
    @ObservationIgnored private var maneuverAlongs: [Double]
    @ObservationIgnored private var lastFrame: (t: Double, frame: DriveFrame)?
    @ObservationIgnored private var hasFix = false

    init(route: Route, geometry: RouteGeometry) {
        self.geometry = geometry
        self.animator = PuckAnimator(geometry: geometry)
        self.problems = DriveProblem.onRoute(route, geometry: geometry)
        self.maneuverAlongs = Self.alongs(route: route, geometry: geometry)
    }

    private static func alongs(route: Route, geometry: RouteGeometry) -> [Double] {
        route.maneuvers.sorted { $0.beginShapeIndex < $1.beginShapeIndex }.dropFirst().map { geometry.distance(atIndex: $0.beginShapeIndex) }
    }

    /// A new route (reroute, stop added): the arrow continues from where it is drawn.
    func setRoute(_ route: Route, geometry: RouteGeometry) {
        let drawn = hasFix ? animator.sample(at: clock()) : nil
        self.geometry = geometry
        animator = PuckAnimator(geometry: geometry)
        if let drawn { animator.push(PuckAnimator.Target(point: drawn.point, alongM: nil, speedMps: 0), at: clock()) }
        problems = DriveProblem.onRoute(route, geometry: geometry)
        maneuverAlongs = Self.alongs(route: route, geometry: geometry)
    }

    /// Feeds one fix. `snapped`: the arrow is glued to the road (snap hysteresis); `snap` is the projection on the route.
    func push(fix: LocationFix, snap: Snap?, snapped: Bool) {
        let t = clock()
        hasFix = true
        let along = snap?.distanceAlongM ?? 0
        let next = maneuverAlongs.first { $0 > along + 0.5 }
        let last = maneuverAlongs.last { $0 <= along + 0.5 }
        let point = snapped ? (snap?.point ?? fix.coordinate) : fix.coordinate
        animator.push(PuckAnimator.Target(point: point, alongM: snapped ? snap?.distanceAlongM : nil, speedMps: max(0, fix.speedKmh / 3.6),
                                          stopAlongM: next), at: t)
        // Heading: the route 20 m ahead when snapped; GPS course only off-route and above 10 km/h; else hold.
        if snapped, let s = snap {
            heading.target = geometry.bearing(atAlongM: s.distanceAlongM, aheadM: 20)
        } else if fix.speedKmh > 10, let c = fix.course {
            heading.target = c
        }

        let target = controller.update(CameraModeController.Input(now: fix.timestamp, speedKmh: fix.speedKmh, alongM: along,
                                                                  nextManeuverAlongM: next, lastManeuverAlongM: last, problems: problems))
        zoom.set(target.zoom, over: target.easeS, at: t)
        pitch.set(target.pitch, over: target.easeS, at: t)
        puckY.set(target.puckY, over: target.easeS, at: t)
        if mode != target.mode { mode = target.mode }

        let problem = controller.tinjauProblem(at: fix.timestamp)
        if problem?.id != tinjauProblem?.id {
            tinjauProblem = problem
            if let problem { onTinjau?(problem, problem.bannerText(distanceM: max(0, problem.startAlongM - along))) }
        }
        if let problem { tinjauDistanceM = max(0, problem.startAlongM - along) }
    }

    /// The frame to draw at monotonic time `t` (cached for a second map drawing the same frame).
    func frame(at t: Double) -> DriveFrame? {
        guard hasFix else { return nil }
        if let last = lastFrame, abs(last.t - t) < 0.002 { return last.frame }
        let dt = lastFrame.map { min(0.25, max(0, t - $0.t)) } ?? 0
        let p = animator.sample(at: t)
        let f = DriveFrame(point: p.point, heading: heading.step(dt: dt), zoom: zoom.value(at: t), pitch: pitch.value(at: t),
                           puckY: puckY.value(at: t), mode: mode)
        lastFrame = (t, f)
        return f
    }
}
