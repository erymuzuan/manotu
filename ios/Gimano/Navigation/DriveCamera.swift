import Foundation

// MARK: - Camera modes (docs/driving.md §2)

/// The five navigation camera modes. Priority: Simpang > Tinjau > the speed modes.
enum DriveCameraMode: String, Sendable, CaseIterable {
    case simpang, perlahan, bandar, lebuhRaya, tinjau

    /// MapLibre zoom level (same scale on iOS and Android).
    var zoom: Double {
        switch self {
        case .simpang: 17.2
        case .perlahan: 16.5
        case .bandar: 16.0
        case .lebuhRaya: 15.2
        case .tinjau: 13.5   // replaced by the fitted zoom of the problem ahead
        }
    }

    var pitch: Double {
        switch self {
        case .simpang: 55
        case .tinjau: 30
        default: 50
        }
    }

    /// Where the arrow sits, as a fraction of the map height from the top: lower when more road ahead is shown.
    var puckY: Double {
        switch self {
        case .simpang: 0.62
        case .perlahan: 0.66
        case .bandar: 0.70
        case .lebuhRaya: 0.75
        case .tinjau: 0.78
        }
    }

    var isSpeedMode: Bool { self == .perlahan || self == .bandar || self == .lebuhRaya }

    /// Road visible ahead of the arrow at `zoom` (≈ 800 m at zoom 16, doubling per zoom level out).
    static func roadAheadM(zoom: Double) -> Double { 800 * pow(2, 16 - zoom) }

    /// Zoom that shows `distanceM` of road ahead (with a margin), never below 12.5 and never above Bandar.
    static func zoomShowing(distanceM: Double) -> Double {
        let z = 16 - log2(max(1, distanceM * 1.15) / 800)
        return min(16, max(12.5, z))
    }
}

/// Speed modes with ±5 km/h hysteresis; a change needs the speed past the threshold for 5 s.
struct SpeedModeSelector: Sendable {
    static let dwellS: TimeInterval = 5
    private(set) var mode: DriveCameraMode?
    private var pending: (mode: DriveCameraMode, since: Date)?

    /// The mode the speed asks for, given the current one (hysteresis): Perlahan → Bandar at 35, back at 25;
    /// Bandar → Lebuh raya at 85, back at 75.
    static func target(speedKmh v: Double, current: DriveCameraMode?) -> DriveCameraMode {
        switch current {
        case .perlahan?: return v >= 85 ? .lebuhRaya : v >= 35 ? .bandar : .perlahan
        case .lebuhRaya?: return v < 25 ? .perlahan : v < 75 ? .bandar : .lebuhRaya
        case .bandar?: return v >= 85 ? .lebuhRaya : v < 25 ? .perlahan : .bandar
        default: return v >= 80 ? .lebuhRaya : v >= 30 ? .bandar : .perlahan
        }
    }

    mutating func update(speedKmh: Double, now: Date) -> DriveCameraMode {
        guard let current = mode else {
            let m = Self.target(speedKmh: speedKmh, current: nil)
            mode = m
            return m
        }
        let want = Self.target(speedKmh: speedKmh, current: current)
        if want == current { pending = nil; return current }
        if let p = pending, p.mode == want {
            if now.timeIntervalSince(p.since) >= Self.dwellS { mode = want; pending = nil; return want }
        } else {
            pending = (want, now)
        }
        return current
    }
}

/// A jam, closure, accident or hazard on the route ahead (Tinjau looks at it once).
struct DriveProblem: Sendable, Equatable, Identifiable {
    enum Kind: String, Sendable { case jam, closure, accident, hazard }
    /// Stable across reroutes: the kind and where it starts (≈ 100 m grid).
    var id: String
    var kind: Kind
    var startAlongM: Double
    var lengthM: Double?
    var delayS: Double?
    var start: LatLng

    /// "Traffic 4.8 km ahead · 1.2 km long · +6 min" / "Accident 3.2 km ahead".
    func bannerText(distanceM: Double) -> String {
        let d = ManeuverFormatter.distance(distanceM)
        switch kind {
        case .jam:
            var parts = [String(localized: "Traffic \(d) ahead")]
            if let lengthM, lengthM >= 50 { parts.append(String(localized: "\(ManeuverFormatter.distance(lengthM)) long")) }
            if let delayS, let text = ETAFormatter.delay(delayS) { parts.append(text) }
            return parts.joined(separator: " · ")
        case .closure: return String(localized: "Road closed \(d) ahead")
        case .accident: return String(localized: "Accident \(d) ahead")
        case .hazard: return String(localized: "Hazard \(d) ahead")
        }
    }

    /// Jams (traffic level ≥ 3, neighbouring segments merged) and closure / accident / hazard alerts on the route.
    static func onRoute(_ route: Route, geometry g: RouteGeometry) -> [DriveProblem] {
        var out: [DriveProblem] = []
        let segs = (route.trafficSegments ?? []).filter { $0.level >= 3 && $0.toIndex > $0.fromIndex }.sorted { $0.fromIndex < $1.fromIndex }
        var runs: [(from: Double, to: Double)] = []
        for s in segs {
            let a = g.distance(atIndex: s.fromIndex), b = g.distance(atIndex: s.toIndex)
            if let last = runs.last, a - last.to < 100 { runs[runs.count - 1].to = max(last.to, b) } else { runs.append((a, b)) }
        }
        // The route's own traffic delay is only attributed when it has a single jam.
        let routeDelay = route.trafficDurationS.map { $0 - route.durationS }
        for r in runs {
            let p = Geo.point(along: g.points, cumulative: g.cumulative, distance: r.from).point
            out.append(DriveProblem(id: key("jam", p), kind: .jam, startAlongM: r.from, lengthM: r.to - r.from,
                                    delayS: runs.count == 1 ? routeDelay.flatMap { $0 >= 60 ? $0 : nil } : nil, start: p))
        }
        for a in route.alerts ?? [] {
            let kind: Kind
            switch a.report.type {
            case .closure: kind = .closure
            case .accident: kind = .accident
            case .hazard: kind = .hazard
            default: continue
            }
            out.append(DriveProblem(id: "alert-\(a.id)", kind: kind, startAlongM: a.distanceAlongRouteM, lengthM: nil, delayS: nil,
                                    start: a.report.location))
        }
        return out.sorted { $0.startAlongM < $1.startAlongM }
    }

    static func key(_ kind: String, _ p: LatLng) -> String {
        "\(kind)-\(Int((p.lat * 1000).rounded()))-\(Int((p.lng * 1000).rounded()))"
    }
}

/// What the camera should do now.
struct CameraTarget: Sendable, Equatable {
    var mode: DriveCameraMode
    var zoom: Double
    var pitch: Double
    var puckY: Double
    /// Seconds to ease into this target.
    var easeS: Double
}

/// One camera controller for phone and car: picks the mode on every fix. Pure, so it is unit-testable.
struct CameraModeController: Sendable {
    struct Input: Sendable {
        var now: Date
        var speedKmh: Double
        var alongM: Double
        /// Next maneuver ahead (not the arrival) and the last one passed, as distances along the route.
        var nextManeuverAlongM: Double?
        var lastManeuverAlongM: Double?
        var problems: [DriveProblem]
    }

    /// Tinjau timings: zoom out, hold, ease back.
    static let tinjauOutS: TimeInterval = 1.2
    static let tinjauHoldS: TimeInterval = 6
    static let tinjauBackS: TimeInterval = 2
    static let tinjauLookAheadM = 5000.0
    static let speedEaseS: TimeInterval = 2

    private(set) var speed = SpeedModeSelector()
    private(set) var seenProblems: Set<String> = []
    /// The problem Tinjau is showing and when it started.
    private(set) var tinjau: (problem: DriveProblem, since: Date, zoom: Double)?

    init(seenProblems: Set<String> = []) { self.seenProblems = seenProblems }

    static func isSimpang(_ i: Input) -> Bool {
        if let next = i.nextManeuverAlongM {
            let d = next - i.alongM
            if d <= 300 { return true }
            if i.speedKmh > 1, d / (i.speedKmh / 3.6) <= 15 { return true }
        }
        if let last = i.lastManeuverAlongM, i.alongM - last < 50 { return true }
        return false
    }

    /// Seconds to the next maneuver at the current speed.
    static func secondsToManeuver(_ i: Input) -> Double? {
        guard let next = i.nextManeuverAlongM, i.speedKmh > 1 else { return nil }
        return (next - i.alongM) / (i.speedKmh / 3.6)
    }

    /// Whether Tinjau is still in its zoom-out / hold / ease-back window at `now`.
    func tinjauActive(at now: Date) -> Bool {
        guard let t = tinjau else { return false }
        return now.timeIntervalSince(t.since) < Self.tinjauOutS + Self.tinjauHoldS
    }

    mutating func update(_ i: Input) -> CameraTarget {
        let speedMode = speed.update(speedKmh: i.speedKmh, now: i.now)
        let simpang = Self.isSimpang(i)
        if tinjau != nil, !tinjauActive(at: i.now) { tinjau = nil }

        // Tinjau once per problem starting ≤ 5 km ahead; skipped while Simpang or with a maneuver within 20 s.
        if tinjau == nil,
           let p = i.problems.first(where: { !seenProblems.contains($0.id) && $0.startAlongM > i.alongM
                                             && $0.startAlongM - i.alongM <= Self.tinjauLookAheadM }),
           !simpang, !(Self.secondsToManeuver(i).map { $0 <= 20 } ?? false) {
            seenProblems.insert(p.id)
            tinjau = (p, i.now, DriveCameraMode.zoomShowing(distanceM: p.startAlongM - i.alongM))
        }

        if simpang {
            return CameraTarget(mode: .simpang, zoom: DriveCameraMode.simpang.zoom, pitch: DriveCameraMode.simpang.pitch,
                                puckY: DriveCameraMode.simpang.puckY, easeS: Self.speedEaseS)
        }
        if let t = tinjau {
            return CameraTarget(mode: .tinjau, zoom: t.zoom, pitch: DriveCameraMode.tinjau.pitch,
                                puckY: DriveCameraMode.tinjau.puckY, easeS: Self.tinjauOutS)
        }
        // Back from Tinjau (or between speed modes): 2 s.
        return CameraTarget(mode: speedMode, zoom: speedMode.zoom, pitch: speedMode.pitch, puckY: speedMode.puckY,
                            easeS: Self.tinjauBackS)
    }

    /// The problem on the Tinjau banner right now.
    func tinjauProblem(at now: Date) -> DriveProblem? { tinjauActive(at: now) ? tinjau?.problem : nil }
}

// MARK: - Steady arrow (docs/driving.md §3)

/// Snap to the route within 25 m (heading within 60° above 10 km/h); release only beyond 40 m for 3 s.
struct SnapHysteresis: Sendable {
    static let snapM = 25.0
    static let releaseM = 40.0
    static let releaseAfterS: TimeInterval = 3
    static let maxHeadingDelta = 60.0

    private(set) var snapped = false
    private var farSince: Date?

    mutating func update(distanceFromRouteM d: Double, speedKmh: Double, course: Double?, routeBearing: Double, now: Date) -> Bool {
        if snapped {
            if d > Self.releaseM {
                if let s = farSince {
                    if now.timeIntervalSince(s) >= Self.releaseAfterS { snapped = false; farSince = nil }
                } else {
                    farSince = now
                }
            } else {
                farSince = nil
            }
        } else if d <= Self.snapM {
            let headingOK = speedKmh <= 10 || course.map { abs(Geo.angleDelta($0, routeBearing)) <= Self.maxHeadingDelta } ?? true
            if headingOK { snapped = true; farSince = nil }
        }
        return snapped
    }
}

/// Low-pass filtered heading with a 90°/s turn-rate limit.
struct HeadingFilter: Sendable {
    static let maxTurnRate = 90.0
    /// Time constant of the low-pass filter (s).
    static let tau = 0.35
    private(set) var value: Double?
    var target: Double?

    mutating func step(dt: Double) -> Double {
        guard let target else { return value ?? 0 }
        guard let v = value else { value = target; return target }
        let delta = Geo.angleDelta(v, target)
        let alpha = 1 - exp(-max(0, dt) / Self.tau)
        let limit = Self.maxTurnRate * max(0, dt)
        let move = max(-limit, min(limit, delta * alpha))
        let next = (v + move + 360).truncatingRemainder(dividingBy: 360)
        value = next
        return next
    }
}

/// Where the arrow is drawn: interpolated from the drawn position to each new fix over the measured fix interval
/// (0.3–1.2 s), along the route when snapped; then on along the route at the last speed for ≤ 1 s (never past the next
/// maneuver), then held. Times are monotonic seconds.
struct PuckAnimator: Sendable {
    struct Target: Sendable, Equatable {
        var point: LatLng
        /// Distance along the route when snapped (nil when off the route: straight-line interpolation).
        var alongM: Double?
        var speedMps: Double
        /// Extrapolation stops here (the next maneuver point).
        var stopAlongM: Double?
    }

    static let minDuration = 0.3
    static let maxDuration = 1.2
    static let maxExtrapolationS = 1.0

    let geometry: RouteGeometry?
    private(set) var from: Target?
    private(set) var to: Target?
    private(set) var startT: Double = 0
    private(set) var duration: Double = 1
    private var lastFixT: Double?

    init(geometry: RouteGeometry?) { self.geometry = geometry }

    mutating func push(_ target: Target, at t: Double) {
        let interval = lastFixT.map { t - $0 } ?? 1
        lastFixT = t
        if to == nil {
            from = target; to = target; startT = t; duration = Self.minDuration
            return
        }
        let current = sample(at: t)
        from = current
        to = target
        startT = t
        duration = min(Self.maxDuration, max(Self.minDuration, interval))
    }

    /// The drawn position at time `t`.
    func sample(at t: Double) -> Target {
        guard let to else { return Target(point: LatLng(lat: 0, lng: 0), alongM: nil, speedMps: 0) }
        guard let from else { return to }
        let u = duration > 0 ? (t - startT) / duration : 1
        if u < 1 {
            let k = max(0, u)
            if let a = from.alongM, let b = to.alongM, let g = geometry, abs(b - a) < 500 {
                let along = a + (b - a) * k
                return Target(point: g.point(atAlongM: along), alongM: along, speedMps: to.speedMps, stopAlongM: to.stopAlongM)
            }
            return Target(point: Geo.interpolate(from.point, to.point, k), alongM: nil, speedMps: to.speedMps, stopAlongM: to.stopAlongM)
        }
        // After the interpolation: keep rolling along the route for up to 1 s, never past the maneuver point.
        guard let b = to.alongM, let g = geometry, to.speedMps > 0.5 else { return to }
        let extra = min(Self.maxExtrapolationS, t - (startT + duration)) * to.speedMps
        var along = b + max(0, extra)
        if let stop = to.stopAlongM, b <= stop { along = min(along, stop) }
        along = min(along, g.totalM)
        return Target(point: g.point(atAlongM: along), alongM: along, speedMps: to.speedMps, stopAlongM: to.stopAlongM)
    }
}

extension RouteGeometry {
    func point(atAlongM d: Double) -> LatLng { Geo.point(along: points, cumulative: cumulative, distance: d).point }

    /// Direction of the route from `alongM` to `aheadM` further on.
    func bearing(atAlongM d: Double, aheadM: Double = 20) -> Double {
        let a = point(atAlongM: d)
        var b = point(atAlongM: min(totalM, d + aheadM))
        if Geo.distance(a, b) < 1 { b = point(atAlongM: min(totalM, d + aheadM * 3)) }
        if Geo.distance(a, b) < 1, d > 1 { return Geo.bearing(point(atAlongM: max(0, d - aheadM)), a) }
        return Geo.bearing(a, b)
    }
}

/// Eases a camera value from where it is towards a target over a duration (smoothstep), driven by frame time.
struct EasedValue: Sendable {
    private(set) var start: Double
    private(set) var target: Double
    private(set) var startT: Double = 0
    private(set) var duration: Double = 0

    init(_ v: Double) { start = v; target = v }

    func value(at t: Double) -> Double {
        guard duration > 0 else { return target }
        let u = min(1, max(0, (t - startT) / duration))
        let s = u * u * (3 - 2 * u)
        return start + (target - start) * s
    }

    mutating func set(_ v: Double, over seconds: Double, at t: Double) {
        guard abs(v - target) > 0.0001 else { return }
        start = value(at: t)
        target = v
        startT = t
        duration = seconds
    }
}
