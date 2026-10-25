import Foundation

/// Simulated GPS that drives along a route — used in demo mode, in the Simulator, or when
/// "Simulate drive" is enabled in Debug settings.
@MainActor
final class DriveSimulator {
    private var task: Task<Void, Never>?
    private(set) var isRunning = false

    /// Starts emitting fixes along `points` at roughly `speedKmh`, accelerated by `speedup`.
    /// - Parameters:
    ///   - tick: seconds between fixes (real GPS gives about one a second).
    ///   - profile: speed (km/h) at a distance along the route, e.g. from the maneuvers' durations (DEBUG replays);
    ///     `speedKmh` otherwise.
    func start(points: [LatLng], speedKmh: Double = 50, speedup: Double = 3, tick: Double = 0.5,
               profile: (@Sendable (Double) -> Double)? = nil, onFix: @escaping @MainActor (LocationFix) -> Void) {
        stop()
        guard points.count >= 2 else { return }
        isRunning = true
        let cumulative = Geo.cumulativeDistances(points)
        let total = cumulative.last ?? 0
        task = Task { @MainActor [weak self] in
            var along = 0.0
            var t = 0.0
            while !Task.isCancelled, along <= total {
                let (p, seg) = Geo.point(along: points, cumulative: cumulative, distance: along)
                let next = points[min(seg + 1, points.count - 1)]
                let course = Geo.bearing(points[seg], next)
                // Gentle speed variation so the speedometer looks alive.
                let base = profile?(along) ?? speedKmh
                let v = max(3, base + min(8, base * 0.08) * sin(t / 6))
                onFix(LocationFix(coordinate: p, speedKmh: v, course: course, accuracyM: 5, timestamp: .now))
                try? await Task.sleep(for: .seconds(tick))
                along += v / 3.6 * tick * speedup
                t += tick
            }
            if !Task.isCancelled, let last = points.last {
                onFix(LocationFix(coordinate: last, speedKmh: 0, course: nil, accuracyM: 5, timestamp: .now))
            }
            self?.isRunning = false
        }
    }

    /// Speed along a route from its maneuvers (distance / duration), for realistic highway and city replays.
    nonisolated static func profile(for route: Route) -> @Sendable (Double) -> Double {
        let g = RouteGeometry(route: route)
        let spans: [(start: Double, end: Double, kmh: Double)] = route.maneuvers.compactMap { m in
            guard m.durationS > 0, m.distanceM > 0 else { return nil }
            let a = g.distance(atIndex: m.beginShapeIndex), b = g.distance(atIndex: m.endShapeIndex)
            return (a, max(a + 1, b), min(130, max(8, m.distanceM / m.durationS * 3.6)))
        }
        return { along in spans.first { along >= $0.start && along < $0.end }?.kmh ?? 40 }
    }

    func stop() {
        task?.cancel()
        task = nil
        isRunning = false
    }
}
