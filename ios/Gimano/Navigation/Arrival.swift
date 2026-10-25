import Foundation

// MARK: - Arriving at the entrance (docs/driving.md §4, docs/api.md "Arriving at the entrance")

enum ArrivalRule {
    /// Remaining distance along the route at which the driver has arrived (only while on the route).
    static let alongRouteM = 30.0
    /// Straight-line distance to the pin at which the driver has arrived, on the route or not.
    static let toPinM = 40.0

    /// Arrived when the remaining distance along the route is ≤ 30 m (on route), or the pin is ≤ 40 m away.
    static func arrived(remainingM: Double, onRoute: Bool, distanceToPinM: Double?) -> Bool {
        (onRoute && remainingM <= alongRouteM) || (distanceToPinM.map { $0 <= toPinM } ?? false)
    }
}

/// The dotted last metres: route end → entrance (blue) and entrance → pin (grey, only when the pin is > 15 m from
/// the route end).
struct LastMetres: Equatable, Sendable {
    var blue: [LatLng] = []
    var grey: [LatLng] = []

    static let pinGapM = 15.0

    static func make(routeEnd: LatLng?, arrival: LatLng?, pin: LatLng?) -> LastMetres {
        guard let routeEnd else { return LastMetres() }
        var out = LastMetres()
        if let arrival, Geo.distance(routeEnd, arrival) > 2 { out.blue = [routeEnd, arrival] }
        if let pin, Geo.distance(routeEnd, pin) > pinGapM {
            let from = arrival ?? routeEnd
            if Geo.distance(from, pin) > 2 { out.grey = [from, pin] }
        }
        return out
    }
}

/// "Main entrance on your left · 25 m from the road" (arrival card, car screen's final step).
struct ArrivalInfo: Equatable, Sendable {
    enum Side: Sendable { case left, right }
    enum What: Sendable { case mainEntrance, entrance, place }
    var what: What
    var side: Side
    /// From the route end (the road) to the entrance or place.
    var distanceM: Double

    /// Side of the travel direction at the route end, and what is there. Nil when the route ends at the pin
    /// (no entrance and the pin within 15 m of the road).
    static func make(geometry g: RouteGeometry, arrival: NavigationPoint?, pin: LatLng) -> ArrivalInfo? {
        guard g.points.count >= 2, let end = g.points.last else { return nil }
        let target = arrival?.location ?? pin
        let d = Geo.distance(end, target)
        if arrival == nil, d <= LastMetres.pinGapM { return nil }
        guard d > 1 else { return nil }
        let travel = g.bearing(atAlongM: max(0, g.totalM - 25), aheadM: 25)
        let delta = Geo.angleDelta(travel, Geo.bearing(end, target))
        let what: What = if arrival == nil || arrival?.source == .outline { .place }
            else if arrival?.kind == "main" { .mainEntrance }
            else { .entrance }
        return ArrivalInfo(what: what, side: delta < 0 ? .left : .right, distanceM: d)
    }

    /// "Main entrance on your left" / "Pintu masuk utama di sebelah kiri".
    var sideText: String {
        switch (what, side) {
        case (.mainEntrance, .left): String(localized: "Main entrance on your left")
        case (.mainEntrance, .right): String(localized: "Main entrance on your right")
        case (.entrance, .left): String(localized: "Entrance on your left")
        case (.entrance, .right): String(localized: "Entrance on your right")
        case (.place, .left): String(localized: "The place is on your left")
        case (.place, .right): String(localized: "The place is on your right")
        }
    }

    /// "25 m from the road" (to 5 m).
    var distanceText: String {
        let m = max(5, Int((distanceM / 5).rounded()) * 5)
        let d = m < 1000 ? "\(m) m" : ManeuverFormatter.distance(Double(m))
        return String(localized: "\(d) from the road")
    }

    var text: String { "\(sideText) · \(distanceText)" }
}
