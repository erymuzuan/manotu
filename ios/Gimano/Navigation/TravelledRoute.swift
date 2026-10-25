import Foundation

/// Travelled route (docs/driving.md §6.3, board NavDilalui): the part of the route behind the animated arrow is drawn
/// light grey on a white casing, the road ahead stays blue, and traffic colours are drawn only ahead of the arrow.
enum TravelledRoute {
    /// Grey of the travelled part (#C3CAD6) and its white casing.
    static let lineHex: UInt32 = 0xC3CAD6
    static let casingHex: UInt32 = 0xFFFFFF

    /// The route cut at `alongM` (clamped to the route): `behind` runs from the start to the cut point, `ahead` from the
    /// cut point to the end; both contain the cut point, so they meet exactly under the arrow.
    struct Split: Equatable {
        var behind: [LatLng]
        var ahead: [LatLng]
        /// First route vertex strictly ahead of the cut.
        var aheadFromIndex: Int
        var cut: LatLng
    }

    static func split(points: [LatLng], cumulative: [Double], alongM: Double) -> Split {
        guard points.count > 1, cumulative.count == points.count, let total = cumulative.last else {
            return Split(behind: [], ahead: points, aheadFromIndex: 0, cut: points.first ?? LatLng(lat: 0, lng: 0))
        }
        let d = min(max(0, alongM), total)
        let (cut, seg) = Geo.point(along: points, cumulative: cumulative, distance: d)
        // Vertices up to and including `seg` are behind (or at) the cut; the first one after it is ahead.
        var next = seg + 1
        while next < points.count && cumulative[next] <= d { next += 1 }
        let behind = d <= 0 ? [] : Array(points[0...min(seg, points.count - 1)]) + [cut]
        let ahead = next >= points.count ? [cut] : [cut] + Array(points[next...])
        return Split(behind: behind, ahead: ahead, aheadFromIndex: min(next, points.count), cut: cut)
    }

    /// Traffic segments (vertex index ranges) clipped to the part ahead of the cut: one polyline per coloured stretch.
    static func trafficAhead(points: [LatLng], segments: [TrafficSegment], split: Split) -> [(level: Int, points: [LatLng])] {
        guard points.count > 1 else { return [] }
        return segments.compactMap { t in
            let from = max(0, t.fromIndex), to = min(points.count - 1, t.toIndex)
            guard to > from, t.level > 0 else { return nil }
            // Entirely behind the arrow.
            if to < split.aheadFromIndex { return nil }
            // Entirely ahead.
            if from >= split.aheadFromIndex { return (t.level, Array(points[from...to])) }
            // Straddles the arrow: start at the cut point.
            return (t.level, [split.cut] + Array(points[split.aheadFromIndex...to]))
        }
    }
}

/// How far along the shown route the travelled part reaches. It only grows while you drive (a jittery or off-route fix
/// never "un-travels" the road), starts again from zero on a new route (reroute: the old route, travelled or not, is
/// gone), and asks for a redraw only when the cut moved enough to be seen.
struct TravelledProgress: Equatable {
    /// Redraw when the cut moved this far (m) …
    static let minStepM = 1.0
    /// … but not more often than this (s).
    static let minIntervalS = 1.0 / 15

    private(set) var routeKey: String?
    private(set) var alongM: Double = 0
    private(set) var drawnAlongM: Double = -1
    private(set) var drawnAt: Double = -.infinity

    /// Feeds the arrow's along-route distance (nil when off the route) for route `routeKey` at time `t`.
    /// Returns true when the travelled line should be redrawn.
    mutating func update(routeKey: String?, alongM along: Double?, at t: Double) -> Bool {
        if routeKey != self.routeKey {
            self.routeKey = routeKey
            alongM = 0
            drawnAlongM = -1
            drawnAt = -.infinity
        }
        if let along { alongM = max(alongM, along) }
        guard routeKey != nil else { return false }
        if drawnAlongM < 0 || (alongM - drawnAlongM >= Self.minStepM && t - drawnAt >= Self.minIntervalS) {
            drawnAlongM = alongM
            drawnAt = t
            return true
        }
        return false
    }
}
