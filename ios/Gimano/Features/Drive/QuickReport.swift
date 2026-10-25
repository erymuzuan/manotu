import CoreGraphics
import Foundation

/// Hold-to-report (docs/driving.md §6.4, boards NavLaporTahan / NavLaporPilih / NavLaporHantar): the fan of 8 quick
/// actions around the report button, which one the finger is on, and the 5 s Undo after sending. Pure logic, no UI.
enum QuickReportFan {
    /// Hold this long on the report button to open the fan (a shorter touch is a tap: the full sheet).
    static let holdS = 0.3
    /// Ring radii from the button centre (board: 68 pt button, inner ring 122 pt, outer ring 228 pt).
    static let innerRadius: CGFloat = 122
    static let outerRadius: CGFloat = 228
    /// Bubble diameters (inner, outer); the bubble under the finger grows to `selectedDiameter`.
    static let innerDiameter: CGFloat = 62
    static let outerDiameter: CGFloat = 56
    static let selectedDiameter: CGFloat = 80
    /// A finger within this distance of a bubble's centre is on it (bigger than the bubble: easy to hit at speed).
    static let hitRadius: CGFloat = 44
    /// Within this distance of the button centre nothing is selected (the finger hasn't left the button yet).
    static let deadZone: CGFloat = 50

    struct Item: Equatable, Identifiable {
        let type: ReportType
        let ring: Int           // 0 inner, 1 outer
        let angleDeg: Double    // 90 = straight up, 180 = straight left (the button sits on the right edge)
        var id: String { type.rawValue }
        var radius: CGFloat { ring == 0 ? QuickReportFan.innerRadius : QuickReportFan.outerRadius }
        var diameter: CGFloat { ring == 0 ? QuickReportFan.innerDiameter : QuickReportFan.outerDiameter }
        /// Offset of the bubble centre from the button centre, in screen points (y grows downwards).
        var offset: CGVector {
            let a = angleDeg * .pi / 180
            return CGVector(dx: radius * cos(a), dy: -radius * sin(a))
        }
    }

    /// Inner ring: Hazard, Police, Accident. Outer ring: Traffic, Closure, Blocked lane, Weather, Animal.
    /// "Map issue" stays in the full sheet only.
    static let items: [Item] = [
        Item(type: .hazard, ring: 0, angleDeg: 90),
        Item(type: .police, ring: 0, angleDeg: 135),
        Item(type: .accident, ring: 0, angleDeg: 180),
        Item(type: .traffic, ring: 1, angleDeg: 90),
        Item(type: .closure, ring: 1, angleDeg: 112.5),
        Item(type: .blockedLane, ring: 1, angleDeg: 135),
        Item(type: .weather, ring: 1, angleDeg: 157.5),
        Item(type: .animal, ring: 1, angleDeg: 180),
    ]

    /// The bubble under the finger at `translation` from the button centre, or nil (on the button, or outside the fan).
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

    /// Sent at once from the fan: no subtype (Details can add one afterwards).
    static func newReport(_ t: ReportType, at p: LatLng, heading: Double?) -> NewReport {
        NewReport(type: t, subtype: nil, lat: p.lat, lng: p.lng, heading: heading, comment: nil)
    }
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
