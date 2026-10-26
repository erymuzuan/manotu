import CoreGraphics
import Foundation

/// Reporting while driving (docs/driving.md §6.4, boards RpHold / RpDetail / RpSent): the arc of 5 bubbles around the
/// report button, which one the finger is on, the detail sheet's defaults and 3 s auto-send, and the 5 s Undo after
/// sending. Pure logic, no UI.
enum QuickReportFan {
    /// Hold this long on the report button to open the arc (a shorter touch is a tap: the drawer).
    static let holdS = 0.3
    /// All five bubbles sit on one arc this far from the button centre.
    static let arcRadius: CGFloat = 170
    static let diameter: CGFloat = 60
    /// The bubble under the finger grows to this.
    static let selectedDiameter: CGFloat = 80
    /// A finger within this distance of a bubble's centre is on it (bigger than the bubble: easy to hit at speed).
    static let hitRadius: CGFloat = 44
    /// Within this distance of the button centre nothing is selected (the finger hasn't left the button yet).
    static let deadZone: CGFloat = 50

    struct Item: Equatable, Identifiable {
        let type: ReportType
        let angleDeg: Double    // 90 = straight up, 180 = straight left (the button sits on the right edge)
        var id: String { type.rawValue }
        var radius: CGFloat { QuickReportFan.arcRadius }
        var diameter: CGFloat { QuickReportFan.diameter }
        /// Offset of the bubble centre from the button centre, in screen points (y grows downwards).
        var offset: CGVector {
            let a = angleDeg * .pi / 180
            return CGVector(dx: radius * cos(a), dy: -radius * sin(a))
        }
    }

    /// Hazard, Police, Crash, Traffic, Closed: the five most reported, from straight up round to the left.
    /// Weather, Animal, Blocked lane and Map issue are in the drawer only.
    static let items: [Item] = [
        Item(type: .hazard, angleDeg: 90),
        Item(type: .police, angleDeg: 112.5),
        Item(type: .accident, angleDeg: 135),
        Item(type: .traffic, angleDeg: 157.5),
        Item(type: .closure, angleDeg: 180),
    ]

    /// The bubble under the finger at `translation` from the button centre, or nil (on the button, or outside the arc).
    static func hit(_ translation: CGVector) -> ReportType? {
        let d = hypot(translation.dx, translation.dy)
        guard d > deadZone else { return nil }
        var best: (ReportType, CGFloat)?
        for item in items {
            let o = item.offset
            let dist = hypot(translation.dx - o.dx, translation.dy - o.dy)
            if dist <= hitRadius, dist < (best?.1 ?? .infinity) { best = (item.type, dist) }
        }
        return best?.0
    }

    /// The colour of each quick action (amber, blue, red, orange, grey, purple, teal, green) and the glyph colour on it.
    static func colors(_ t: ReportType) -> (fill: UInt32, ink: UInt32) {
        switch t {
        case .hazard: (0xF2B01E, 0x3A2600)
        case .police: (0x2563EB, 0xFFFFFF)
        case .accident: (0xC62828, 0xFFFFFF)
        case .traffic: (0xF97316, 0x2A1200)
        case .closure: (0x4B5563, 0xFFFFFF)
        case .blockedLane: (0x7C3AED, 0xFFFFFF)
        case .weather: (0x0F766E, 0xFFFFFF)
        case .animal: (0x4D7C0F, 0xFFFFFF)
        case .mapIssue: (0x0EA5E9, 0xFFFFFF)
        }
    }

    static func newReport(_ t: ReportType, subtype: String? = nil, comment: String? = nil, at p: LatLng, heading: Double?) -> NewReport {
        NewReport(type: t, subtype: subtype, lat: p.lat, lng: p.lng, heading: heading, comment: comment?.isEmpty == true ? nil : comment.map(ReportNote.clamped))
    }
}

/// The detail sheet both doors end on (tap drawer, hold arc): the default subtype is picked already and the report sends
/// itself after `autoSendS` unless the driver touches an option or presses Cancel / Report (docs/driving.md §6.4).
enum ReportDefaults {
    static let autoSendS: Double = 3

    /// The first subtype, except Traffic (heavy); none for Closed and Map issue.
    static func defaultSubtype(_ t: ReportType) -> String? { t == .traffic ? "heavy" : t.subtypes.first?.id }

    /// Map issue has its own sheet (road problems) and is never sent by a timer.
    static func autoSends(_ t: ReportType) -> Bool { t != .mapIssue }
}

/// Alerts reported after the route was calculated (docs/driving.md §6.1): the phone already listens to the live feed for
/// its map area, so it matches those reports to its own road ahead. The server never learns the route.
enum LiveAlertMatcher {
    /// A report counts as "on the road" within this distance of the route line.
    static let lateralM = 40.0
    /// Voice once + chip from this far ahead.
    static let announceM = 1000.0
    /// "Still there?" window: from `askBeforeM` before the spot to `askAfterM` after it.
    static let askBeforeM = 150.0
    static let askAfterM = 100.0

    /// Reports that sit on the route in the driver's direction, with their along-route distance.
    static func match(points: [LatLng], reports: [Report]) -> [AlertOnRoute] {
        guard points.count > 1 else { return [] }
        let cum = Geo.cumulativeDistances(points)
        return reports.compactMap { r in
            if r.subtype == "other_side" { return nil }
            var best = (d: Double.infinity, along: 0.0, bearing: 0.0)
            for k in 0..<(points.count - 1) {
                let pr = Geo.project(r.location, onto: points[k], points[k + 1])
                if pr.distanceM < best.d {
                    best = (pr.distanceM, cum[k] + (cum[k + 1] - cum[k]) * pr.t, Geo.bearing(points[k], points[k + 1]))
                }
            }
            guard best.d <= lateralM else { return nil }
            // A report facing the other way is for the other carriageway.
            if let h = r.heading, abs(Geo.angleDelta(h, best.bearing)) > 100 { return nil }
            return AlertOnRoute(report: r, distanceAlongRouteM: best.along)
        }
    }

    /// Ask "still there?" only when the spot is within the window: `deltaM` = alert along-distance minus ours.
    static func asks(_ deltaM: Double) -> Bool { deltaM >= -askAfterM && deltaM <= askBeforeM }
}

/// The "Hazard reported · street · just now" card: Undo for 5 s. Undo withdraws the report on the server
/// (`DELETE /reports/{id}`), or cancels it if the POST hasn't come back yet (and withdraws it as soon as it does).
struct QuickReportUndo: Equatable {
    static let windowS: Double = 5

    enum Phase: Equatable {
        case sending
        case sent(id: String)
        /// Undo pressed; `id` once known.
        case undone(id: String?)
        case failed
    }

    /// What the app must do after an event.
    enum Action: Equatable {
        case none
        /// Cancel the POST still in flight.
        case cancelSend
        /// `DELETE /reports/{id}`.
        case delete(id: String)
    }

    let type: ReportType
    let position: LatLng
    let startedAt: Date
    private(set) var phase: Phase = .sending
    var street: String?

    init(type: ReportType, position: LatLng, startedAt: Date) {
        self.type = type
        self.position = position
        self.startedAt = startedAt
    }

    /// Whole seconds left on the Undo ring (5 → 0).
    func remaining(at now: Date) -> Int {
        max(0, Int((Self.windowS - now.timeIntervalSince(startedAt)).rounded(.up)))
    }

    /// Ring fill 1 → 0.
    func progress(at now: Date) -> Double { max(0, min(1, 1 - now.timeIntervalSince(startedAt) / Self.windowS)) }

    /// The card (and its Undo) is still showing.
    func isOpen(at now: Date) -> Bool {
        switch phase {
        case .undone, .failed: false
        case .sending, .sent: now.timeIntervalSince(startedAt) < Self.windowS
        }
    }

    var reportId: String? {
        switch phase {
        case .sent(let id): id
        case .undone(let id): id
        default: nil
        }
    }

    var isUndone: Bool { if case .undone = phase { return true } else { return false } }

    mutating func undo(at now: Date) -> Action {
        guard isOpen(at: now) else { return .none }
        switch phase {
        case .sending:
            phase = .undone(id: nil)
            return .cancelSend
        case .sent(let id):
            phase = .undone(id: id)
            return .delete(id: id)
        default:
            return .none
        }
    }

    /// The POST came back with the created report. If Undo was pressed meanwhile, withdraw it now.
    mutating func sent(id: String) -> Action {
        switch phase {
        case .sending:
            phase = .sent(id: id)
            return .none
        case .undone(nil):
            phase = .undone(id: id)
            return .delete(id: id)
        default:
            return .none
        }
    }

    mutating func failed() {
        if case .sending = phase { phase = .failed }
    }
}
