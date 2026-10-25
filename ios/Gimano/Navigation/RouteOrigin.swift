import Foundation

/// Where a route starts (Android `RouteOrigin.kt`, commit a5b85f0). Only a recent GPS fix may be called
/// "Your location"; never the map centre or a default point.
enum RouteOrigin {
    /// Older fixes are refreshed (or the user is asked) before routing from them.
    static let maxFixAge: TimeInterval = 120
    /// Closer than this to the destination → "You're already here", no route.
    static let sameSpotM = 50.0
    /// How long to wait for a fresh fix before saying the location is unknown.
    static let waitForFix: TimeInterval = 8

    enum GPS: Equatable {
        case fresh(LatLng)
        case stale(LatLng, age: TimeInterval)
        case none
    }

    static func classify(fix: LatLng?, at fixTime: Date?, now: Date, maxAge: TimeInterval = maxFixAge) -> GPS {
        guard let fix, let fixTime, fixTime.timeIntervalSince1970 > 0 else { return .none }
        let age = now.timeIntervalSince(fixTime)
        // Up to 60 s in the future tolerates clock skew; anything else isn't trusted.
        return (-60...maxAge).contains(age) ? .fresh(fix) : .stale(fix, age: age)
    }

    static func sameSpot(_ a: LatLng, _ b: LatLng) -> Bool { Geo.distance(a, b) < sameSpotM }
}

/// The start row of a route preview.
enum RouteStart: Equatable {
    /// Waiting (≤ 8 s) for a fresh GPS fix: "Finding your location…".
    case locating
    /// No fresh fix: no route request; offer Allow location / Choose start on map / Search for a start.
    case unknown
    /// A fresh GPS fix: "Your location"; the only start navigation may begin from.
    case gps(LatLng)
    /// A start the user picked (favourite, recent, search, map): routes are previewed, never navigated.
    case chosen(name: String, location: LatLng, placeId: String?)

    var point: LatLng? {
        switch self {
        case .gps(let p): p
        case .chosen(_, let p, _): p
        default: nil
        }
    }

    var isGPS: Bool { if case .gps = self { true } else { false } }

    var chosenName: String? { if case .chosen(let n, _, _) = self { n } else { nil } }
}

/// The route preview's 10 s "Go" countdown (Android `AutoStart`). Off by default (Settings → "Start navigation
/// automatically"); even then only for one-tap destinations (Home, Work, a favourite, a recent, a planned drive), never
/// after a search, never with a chosen start, stops or a departure time, and never while the app is in the background.
enum AutoStart {
    static func shouldCountdown(enabled: Bool, quickPick: Bool, originIsGPS: Bool, hasStops: Bool, departLater: Bool, foreground: Bool) -> Bool {
        enabled && quickPick && originIsGPS && !hasStops && !departLater && foreground
    }
}

/// Route options before a drive (design "Route options before driving", docs/api.md "Route options"; Android
/// `RouteChoices`). The server decides which routes are worth offering (`hidden`) and why (`reasons`); this decides how
/// the preview shows them.
enum RouteChoices {
    /// Trips at least this long by road open with the route list and no countdown.
    static let longTripM: Double = 10_000

    static func shown(_ routes: [Route]) -> [Route] { routes.filter { $0.hidden == nil } }
    static func hidden(_ routes: [Route]) -> [Route] { routes.filter { $0.hidden != nil } }

    /// The list opens by itself: a long car/motorcycle trip without stops and with a real choice.
    static func listFirst(_ routes: [Route], vehicle: Vehicle, hasStops: Bool) -> Bool {
        let s = shown(routes)
        guard vehicle.isMotorized, !hasStops, s.count >= 2, let first = s.first else { return false }
        return first.distanceM >= longTripM
    }

    /// What choosing a route instead of the fastest costs and saves; nil = no difference worth saying.
    struct Compare: Equatable {
        var extraS: Double
        var tollSavedMyr: Double?
        var shorterM: Double?
        var longerM: Double?
        var avoids: [String]
        var tollExtraMyr: Double?
    }

    static func compare(_ r: Route, fastest: Route, shown: [Route]) -> Compare {
        var saved: Double?, extra: Double?
        if let f = knownToll(fastest), let t = knownToll(r) {
            if f - t >= 0.5 { saved = f - t } else if t - f >= 0.5 { extra = t - f }
        }
        let diff = fastest.distanceM - r.distanceM
        var avoids: [String] = []
        for o in shown where o.id != r.id { for v in o.viaRoads ?? [] where !avoids.contains(v) { avoids.append(v) } }
        return Compare(extraS: max(0, r.effectiveDurationS - fastest.effectiveDurationS), tollSavedMyr: saved,
                       shorterM: diff >= 500 ? diff : nil, longerM: -diff >= 500 ? -diff : nil, avoids: avoids,
                       tollExtraMyr: extra)
    }

    /// Known total toll in RM: 0 without tolls, nil when a fare is unknown.
    static func knownToll(_ r: Route) -> Double? {
        if !r.hasTolls { return 0 }
        return r.tollFareComplete == true ? r.tollEstimateMyr : nil
    }

    /// The road a route is known by: its own main road, else the first road of "Via E5 …".
    static func via(_ r: Route) -> String? {
        if let v = r.viaRoads?.first { return v }
        let first = r.summary.hasPrefix("Via ") ? String(r.summary.dropFirst(4)) : r.summary
        let road = first.split(separator: ",").first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
        let ref = road.split(separator: " ").first.map(String.init) ?? ""
        let isRef = ref.range(of: #"^(AH|FT|[A-Z])?\d{1,4}[A-Z]?$"#, options: .regularExpression) != nil
        let out = isRef ? ref : road
        return out.isEmpty ? nil : out
    }
}
