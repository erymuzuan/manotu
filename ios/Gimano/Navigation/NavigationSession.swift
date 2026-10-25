import Foundation
import Observation

/// One active turn-by-turn drive: tracks progress, speaks guidance, detects off-route → reroute,
/// surfaces alerts ahead and batches location pings to `POST /locations`.
@MainActor
@Observable
final class NavigationSession {
    let destination: Destination
    private(set) var route: Route
    private(set) var progress: RouteProgress?
    private(set) var fix: LocationFix?
    private(set) var isRerouting = false
    private(set) var arrived = false
    private(set) var approachingAlert: AlertOnRoute?
    /// The toll plaza on the "toll ahead" banner (docs/driving.md §1); stays 10 s after passing it.
    private(set) var tollAhead: RouteToll?
    /// "Tolls so far RM x · estimate RM y".
    private(set) var tollTotals = TollTotals(paidMyr: 0, estimateMyr: nil, estimateComplete: true)
    private(set) var rerouteCount = 0
    /// Largest snapped distance from the route seen while on it (diagnostics / UI tests).
    private(set) var maxOffRoadM: Double = 0
    /// The first time the driver left the route at a decision point (on the phone only; asked about after the trip).
    private(set) var deviation: DeviationEvent?
    let startedAt = Date()
    /// Stops not yet reached, in order (the destination is separate).
    private(set) var stops: [TripStop]
    /// Shown briefly after reaching a stop: "Arrived at {stop}".
    private(set) var arrivedAtStop: String?
    var vehicle: Vehicle
    var avoid: AvoidOptions

    @ObservationIgnored private var tracker: RouteTracker
    @ObservationIgnored private var offRoute = OffRouteDetector()
    @ObservationIgnored private var announcer: VoiceAnnouncer
    @ObservationIgnored private(set) var stopTracker: StopTracker
    /// Maneuver index → stop name, for intermediate "arrive" maneuvers.
    @ObservationIgnored private var stopArrivals: [Int: String] = [:]
    @ObservationIgnored private var arrivedTask: Task<Void, Never>?
    /// How many waypoints of the original `POST /routes` request were already passed before the current route
    /// (reroutes keep indexing the original request's waypoints).
    @ObservationIgnored private var originalStopOffset = 0
    @ObservationIgnored private var batcher = LocationPingBatcher()
    @ObservationIgnored private var handledAlerts: Set<String> = []
    @ObservationIgnored private(set) var tollTracker: TollTracker
    /// Arrow animation and camera modes, drawn by the phone map and the car screen (docs/driving.md §2–3).
    let motion: DriveMotion
    @ObservationIgnored private var snapHysteresis = SnapHysteresis()
    /// The arrow is glued to the road (snap within 25 m, released beyond 40 m for 3 s).
    @ObservationIgnored private(set) var puckSnapped = false
    /// Tolls paid before the current route began (reroutes keep the trip's running total).
    @ObservationIgnored private var tollsPaidBeforeRoute: Double = 0
    /// Called once per plaza when the toll banner appears (the car screen shows its own alert).
    @ObservationIgnored var onTollAhead: ((RouteToll) -> Void)?
    /// Set by `stop()`: late reroute / add-stop responses and fixes are ignored afterwards.
    @ObservationIgnored private(set) var isStopped = false
    @ObservationIgnored private let repo: any GimanoRepository
    @ObservationIgnored let voice: VoiceGuide
    /// Called when the active route geometry changes (reroute, add stop, alternative picked).
    @ObservationIgnored var onRouteChanged: ((Route) -> Void)?

    init(destination: Destination, route: Route, stops: [TripStop] = [], vehicle: Vehicle, avoid: AvoidOptions,
         repo: any GimanoRepository, voice: VoiceGuide) {
        self.destination = destination
        self.route = route
        self.stops = stops
        self.vehicle = vehicle
        self.avoid = avoid
        self.repo = repo
        self.voice = voice
        let tracker = RouteTracker(route: route)
        self.tracker = tracker
        self.tollTracker = TollTracker(route: route, geometry: tracker.geometry)
        self.motion = DriveMotion(route: route, geometry: tracker.geometry)
        self.announcer = VoiceAnnouncer(mode: vehicle)
        self.stopTracker = StopTracker(schedule: StopSchedule.make(route: route, stops: stops.map(\.location)), stopCount: stops.count)
        self.stopArrivals = Self.arrivalLabels(maneuvers: tracker.maneuvers, stops: stops)
        self.tollTotals = Self.totals(route: route, paidBefore: 0, paidNow: 0)
    }

    static func totals(route: Route, paidBefore: Double, paidNow: Double) -> TollTotals {
        let badge = TollBadge.make(for: route, mode: route.vehicle ?? .car)
        switch badge {
        case .complete(let v): return TollTotals(paidMyr: paidNow, estimateMyr: paidBefore + v, estimateComplete: true)
        case .from(let v): return TollTotals(paidMyr: paidNow, estimateMyr: paidBefore + v, estimateComplete: false)
        case .unknown, .none: return TollTotals(paidMyr: paidNow, estimateMyr: paidBefore > 0 ? paidBefore : nil, estimateComplete: badge == .none)
        }
    }

    /// The trip has tolls to talk about (route preview showed some, or some were already paid).
    var showsTollTotals: Bool { route.hasTolls || !(route.tolls ?? []).isEmpty || tollTotals.paidMyr > 0 }

    func distanceToToll(_ t: RouteToll) -> Double { tollTracker.distanceAhead(t, alongM: progress?.snap.distanceAlongM ?? 0) }

    /// Intermediate "arrive" maneuvers, in order, map to the stops.
    static func arrivalLabels(maneuvers: [Maneuver], stops: [TripStop]) -> [Int: String] {
        let arrives = maneuvers.indices.filter { maneuvers[$0].type == .arrive }.dropLast()
        var out: [Int: String] = [:]
        for (k, i) in arrives.enumerated() where k < stops.count { out[i] = stops[k].name }
        return out
    }

    func stopName(forManeuverAt index: Int?) -> String? { index.flatMap { stopArrivals[$0] } }

    /// Seconds from now to each remaining stop, then the destination: the schedule's per-leg offsets (the same ones
    /// route preview shows) minus the time already driven, so the ETAs agree with the preview.
    var etaOffsets: [Double] {
        let sched = stopTracker.schedule
        let elapsed = sched.elapsedS(atAlongM: progress?.snap.distanceAlongM ?? 0)
        return (stopTracker.nextStopIndex..<sched.offsetsS.count).map { max(0, sched.offsetsS[$0] - elapsed) }
    }

    var geometry: RouteGeometry { tracker.geometry }
    var maneuvers: [Maneuver] { tracker.maneuvers }

    var upcoming: Maneuver? { progress?.upcomingIndex.map { tracker.maneuvers[$0] } ?? tracker.maneuvers.dropFirst().first }
    var then: Maneuver? { progress?.thenIndex.map { tracker.maneuvers[$0] } }
    var distanceToUpcoming: Double { progress?.distanceToUpcomingM ?? (tracker.maneuvers.dropFirst().first.map { tracker.geometry.distance(atIndex: $0.beginShapeIndex) } ?? 0) }
    var remainingM: Double { progress?.remainingM ?? route.distanceM }
    var remainingS: Double { progress?.remainingS ?? route.effectiveDurationS }
    var speedKmh: Double { fix?.speedKmh ?? 0 }

    func begin() {
        if let first = tracker.maneuvers.first {
            voice.speak(ManeuverFormatter.instruction(for: first, mode: vehicle))
        }
    }

    func handle(_ fix: LocationFix) {
        guard !isStopped else { return }
        self.fix = fix
        guard !arrived else { return }
        guard let p = tracker.update(location: fix.coordinate) else { return }
        progress = p
        puckSnapped = snapHysteresis.update(distanceFromRouteM: p.snap.distanceFromRouteM, speedKmh: fix.speedKmh, course: fix.course,
                                            routeBearing: tracker.geometry.bearing(atAlongM: p.snap.distanceAlongM), now: fix.timestamp)
        motion.push(fix: fix, snap: p.snap, snapped: puckSnapped)
        if p.snap.distanceFromRouteM <= 30 { maxOffRoadM = max(maxOffRoadM, p.snap.distanceFromRouteM) }
        // Stops and the destination are only reached on the route: on a parallel road the snapped distance along
        // can pass a stop while the driver is nowhere near it (the off-route check below then reroutes instead).
        let onRoute = p.snap.distanceFromRouteM <= offRoute.tolerance(accuracyM: fix.accuracyM)

        if onRoute, let reached = stopTracker.update(alongM: p.snap.distanceAlongM), reached < stops.count {
            let name = stops[reached].name
            arrivedAtStop = name
            voice.speak(String(localized: "Arrived at \(name)"))
            arrivedTask?.cancel()
            arrivedTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(5))
                if !Task.isCancelled { self?.arrivedAtStop = nil }
            }
        }

        if let batch = batcher.add(LocationPoint(lat: fix.coordinate.lat, lng: fix.coordinate.lng, speedKmh: fix.speedKmh,
                                                  heading: fix.course ?? 0, accuracyM: fix.accuracyM, ts: fix.timestamp)) {
            send(batch)
        }

        if p.arrived, onRoute {
            arrived = true
            voice.speak(String(localized: "You have arrived at \(destination.name)"))
            arrivedTask?.cancel()
            send(batcher.drain())
            return
        }

        if !isRerouting, offRoute.evaluate(distanceFromRouteM: p.snap.distanceFromRouteM, accuracyM: fix.accuracyM, at: fix.timestamp) {
            offRoute.didReroute(at: fix.timestamp)
            reroute(from: fix)
            return
        }

        if let i = p.upcomingIndex,
           let text = announcer.prompt(maneuverIndex: i, maneuver: tracker.maneuvers[i], distanceM: p.distanceToUpcomingM,
                                       speedKmh: fix.speedKmh, stopName: stopArrivals[i]) {
            voice.speak(text)
        }

        updateAlerts(along: p.snap.distanceAlongM)
        updateTolls(along: p.snap.distanceAlongM, speedKmh: fix.speedKmh, now: fix.timestamp)
    }

    private func updateTolls(along: Double, speedKmh: Double, now: Date) {
        let announce = tollTracker.update(alongM: along, speedKmh: speedKmh, now: now)
        if tollAhead != tollTracker.current { tollAhead = tollTracker.current }
        if tollTotals.paidMyr != tollTracker.paidMyr {
            tollTotals = Self.totals(route: route, paidBefore: tollsPaidBeforeRoute, paidNow: tollTracker.paidMyr)
        }
        guard let announce else { return }
        // Full and Alerts only (never Mute): an alert-kind prompt.
        voice.speak(TollSpeech.text(for: announce, language: VoiceGuide.languageCode), kind: .alert)
        onTollAhead?(announce)
    }

    private func updateAlerts(along: Double) {
        if let current = approachingAlert, current.distanceAlongRouteM < along - 30 {
            approachingAlert = nil
        }
        guard approachingAlert == nil else { return }
        let ahead = (route.alerts ?? [])
            .filter { !handledAlerts.contains($0.id) && $0.distanceAlongRouteM - along > 0 && $0.distanceAlongRouteM - along < 600 }
            .min { $0.distanceAlongRouteM < $1.distanceAlongRouteM }
        if let ahead {
            handledAlerts.insert(ahead.id)
            approachingAlert = ahead
            voice.speak(String(localized: "\(String(localized: ahead.report.type.title)) reported ahead"), kind: .alert)
        }
    }

    func distanceToAlert(_ a: AlertOnRoute) -> Double {
        max(0, a.distanceAlongRouteM - (progress?.snap.distanceAlongM ?? 0))
    }

    func dismissAlert() { approachingAlert = nil }

    func vote(stillThere: Bool) {
        guard let a = approachingAlert else { return }
        approachingAlert = nil
        Task { _ = try? await repo.vote(reportId: a.id, stillThere: stillThere) }
    }

    /// Replace the active route (alternative picked / stop added / reroute). `stops` are the stops still ahead.
    /// - Parameter newRequest: the route came from a fresh `POST /routes` (stop added / alternative), so stop
    ///   indexes restart at 0 for later reroutes.
    func setRoute(_ r: Route, stops newStops: [TripStop]? = nil, newRequest: Bool = true) {
        guard !isStopped else { return }
        route = r
        if let newStops { stops = newStops }
        if newRequest { originalStopOffset = 0 }
        tracker = RouteTracker(route: r)
        tollsPaidBeforeRoute = tollTracker.paidMyr
        tollTracker = TollTracker(route: r, geometry: tracker.geometry, announced: tollTracker.announced, passed: tollTracker.passed,
                                  paidMyr: tollTracker.paidMyr)
        tollAhead = nil
        motion.setRoute(r, geometry: tracker.geometry)
        tollTotals = Self.totals(route: r, paidBefore: tollsPaidBeforeRoute, paidNow: tollTracker.paidMyr)
        stopTracker = StopTracker(schedule: StopSchedule.make(route: r, stops: stops.map(\.location)), stopCount: stops.count)
        stopArrivals = Self.arrivalLabels(maneuvers: tracker.maneuvers, stops: stops)
        announcer.reset()
        offRoute.reset()
        progress = nil
        if let fix { handle(fix) }
        onRouteChanged?(r)
    }

    func reroute(from fix: LocationFix) {
        isRerouting = true
        if deviation == nil {
            let road = progress?.upcomingIndex.flatMap { tracker.maneuvers.indices.contains($0) ? ManeuverFormatter.roadName(tracker.maneuvers[$0]) : nil }
            deviation = DeviationEvent(lat: fix.coordinate.lat, lng: fix.coordinate.lng, heading: fix.course, roadName: road,
                                       at: fix.timestamp, vehicle: vehicle)
        }
        voice.speak(String(localized: "Recalculating route"))
        let origin = fix.coordinate
        let heading = fix.course ?? 0
        let routeId = route.id
        let next = stopTracker.nextStopIndex
        let remaining = Array(stops.dropFirst(min(next, stops.count)))
        Task {
            defer { isRerouting = false }
            guard !isStopped else { return }
            // The server keeps the stops not yet reached (nextStopIndex into this route's stops).
            let absoluteNext = originalStopOffset + next
            var routes = (try? await repo.reroute(routeId: routeId, RerouteRequest(lat: origin.lat, lng: origin.lng, heading: heading,
                                                                                    nextStopIndex: stops.isEmpty && absoluteNext == 0 ? nil : absoluteNext))) ?? []
            var viaReroute = !routes.isEmpty
            if routes.isEmpty {
                let req = RouteRequest(origin: RouteEndpoint(lat: origin.lat, lng: origin.lng),
                                       destination: RouteEndpoint(lat: destination.location.lat, lng: destination.location.lng, placeId: destination.placeId),
                                       waypoints: remaining.map(\.endpoint), vehicle: vehicle, avoid: avoid, alternatives: 0)
                routes = (try? await repo.routes(req)) ?? []
                viaReroute = false
            }
            guard !isStopped, let best = routes.first(where: \.isBest) ?? routes.first else { return }
            rerouteCount += 1
            setRoute(best, stops: remaining, newRequest: !viaReroute)
            if viaReroute { originalStopOffset = absoluteNext }
        }
    }

    func stop() {
        isStopped = true
        arrivedTask?.cancel()
        voice.stop()
        send(batcher.drain())
    }

    private func send(_ points: [LocationPoint]) {
        guard !points.isEmpty else { return }
        let batch = LocationBatch(routeId: route.id, points: points)
        Task { try? await repo.sendLocations(batch) }
    }
}
