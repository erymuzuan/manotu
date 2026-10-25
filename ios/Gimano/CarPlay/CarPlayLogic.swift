import Foundation
import UIKit

// Pure decisions behind the CarPlay scene (docs/driving.md §5), kept free of CPInterfaceController / CPWindow so they
// can be unit-tested without a head unit. CarPlayController only executes what these return.

// MARK: - Following the phone's drive

/// What the car needs to know about the phone's drive, read twice a second.
struct CarNavSnapshot: Equatable, Sendable {
    /// Identity of the phone's NavigationSession (a new drive, or the same drive after the car reconnects).
    var sessionID: ObjectIdentifier
    var routeId: String
    var upcomingIndex: Int?
    var thenIndex: Int?
    var isRerouting: Bool
    var arrived: Bool
    /// "Main entrance on your left" (the final step).
    var arrivalText: String?
    var approachingAlertId: String?
    var alongM: Double

    @MainActor
    init(_ nav: NavigationSession) {
        sessionID = ObjectIdentifier(nav)
        routeId = nav.route.id
        upcomingIndex = nav.progress?.upcomingIndex
        thenIndex = nav.progress?.thenIndex
        isRerouting = nav.isRerouting
        arrived = nav.arrived
        arrivalText = nav.arrivalInfo?.sideText
        approachingAlertId = nav.approachingAlert?.id
        alongM = nav.progress?.snap.distanceAlongM ?? 0
    }

    init(sessionID: ObjectIdentifier, routeId: String, upcomingIndex: Int?, thenIndex: Int?, isRerouting: Bool, arrived: Bool,
         arrivalText: String?, approachingAlertId: String?, alongM: Double) {
        self.sessionID = sessionID; self.routeId = routeId; self.upcomingIndex = upcomingIndex; self.thenIndex = thenIndex
        self.isRerouting = isRerouting; self.arrived = arrived; self.arrivalText = arrivalText
        self.approachingAlertId = approachingAlertId; self.alongM = alongM
    }
}

enum CarNavAction: Equatable, Sendable {
    /// Start a CPNavigationSession for the phone's drive (a new drive, or after the car reconnected mid-drive).
    case startSession
    case cancelSession
    /// Rerouting: pause the trip ("Recalculating…").
    case pause
    /// Replace the upcoming maneuvers (route changed, maneuver passed, arrival text known); resumes a paused trip.
    case showManeuvers
    case updateEstimates
    /// Arrived: finish the trip and show the arrival alert.
    case finishAndShowArrival
    case dismissArrival
    /// "Still there?" for this alert id.
    case stillThere(String)
}

/// Keeps the car's CPNavigationSession in step with the phone's NavigationSession. A fresh instance (the car scene
/// reconnecting) picks up the current drive and its current maneuver on the first update.
struct CarDriveSync: Sendable {
    /// "Still there?" in the car at most once per 2 km.
    static let stillThereSpacingM = 2000.0

    private(set) var followed: ObjectIdentifier?
    private(set) var hasSession = false
    private(set) var paused = false
    private(set) var arrivalShown = false
    private var maneuversKey: String?
    private var shownAlerts: Set<String> = []
    private var lastStillThereAlongM: Double?

    mutating func update(_ s: CarNavSnapshot?) -> [CarNavAction] {
        var out: [CarNavAction] = []
        guard let s else {
            if arrivalShown { out.append(.dismissArrival) }
            if hasSession { out.append(.cancelSession) }
            self = CarDriveSync()
            return out
        }
        if followed != s.sessionID {
            if hasSession { out.append(.cancelSession) }
            if arrivalShown { out.append(.dismissArrival) }
            self = CarDriveSync()
            followed = s.sessionID
            if !s.arrived {
                hasSession = true
                out.append(.startSession)
            }
        }
        if s.arrived {
            if !arrivalShown {
                arrivalShown = true
                hasSession = false
                out.append(.finishAndShowArrival)
            }
            return out
        }
        guard hasSession else { return out }
        if s.isRerouting {
            if !paused { paused = true; out.append(.pause) }
            return out
        }
        let key = "\(s.routeId)|\(s.upcomingIndex ?? -1)|\(s.thenIndex ?? -1)|\(s.arrivalText ?? "")"
        if key != maneuversKey || paused {
            maneuversKey = key
            paused = false
            out.append(.showManeuvers)
        }
        out.append(.updateEstimates)
        if let a = s.approachingAlertId, !shownAlerts.contains(a) {
            shownAlerts.insert(a)
            if lastStillThereAlongM.map({ s.alongM - $0 >= Self.stillThereSpacingM }) ?? true {
                lastStillThereAlongM = s.alongM
                out.append(.stillThere(a))
            }
        }
        return out
    }
}

/// The text of a maneuver on the car's guidance panel.
enum CarManeuverText {
    /// Road name, else the instruction; the arrival step says which side the entrance is on.
    @MainActor
    static func primary(_ m: Maneuver, index: Int?, nav: NavigationSession) -> String {
        primary(m, mode: nav.vehicle, stopName: nav.stopName(forManeuverAt: index), arrivalSide: nav.arrivalInfo?.sideText,
                destination: nav.destination.name)
    }

    static func primary(_ m: Maneuver, mode: Vehicle, stopName: String?, arrivalSide: String?, destination: String) -> String {
        if m.type == .arrive {
            if let stopName { return String(localized: "Arrive at \(stopName)") }
            if let arrivalSide { return arrivalSide }
            return String(localized: "Arrive at \(destination)")
        }
        return ManeuverFormatter.roadName(m) ?? ManeuverFormatter.instruction(for: m, mode: mode)
    }
}

// MARK: - Distraction-safe controls

/// CarPlay's own list limits (CPListTemplate.maximumItemCount / maximumSectionCount; smaller while driving on many
/// head units) and ours: at most 12 places, home and work first.
enum CarListLimits {
    static let ourMaximumItems = 12

    /// Cuts sections and items to the limits, keeping order and dropping empty sections.
    static func clamp<T>(_ sections: [[T]], maxItems: Int, maxSections: Int) -> [[T]] {
        var left = min(maxItems, ourMaximumItems)
        var out: [[T]] = []
        for s in sections where !s.isEmpty && out.count < max(1, maxSections) && left > 0 {
            let take = Array(s.prefix(left))
            left -= take.count
            out.append(take)
        }
        return out
    }
}

/// A place the car offers under "Where to?": only what the phone already keeps on the device (never sent anywhere
/// by listing it). "Just for me" places stay on the phone screen only.
struct CarDestination: Equatable, Sendable {
    enum Kind: Sendable { case home, work, favorite, recent }
    var kind: Kind
    var title: String
    var detail: String?
    var destination: Destination

    static func make(saved: [SavedPlace], recents: [Recent], maxRecents: Int = 8) -> [[CarDestination]] {
        func dest(_ name: String, _ address: String, _ p: LatLng, _ placeId: String?) -> Destination {
            // A private or dropped-pin id never goes into a route request from the car.
            let id = placeId.flatMap { $0.hasPrefix(PrivatePlace.idPrefix) || $0.hasPrefix("pin:") ? nil : $0 }
            return Destination(name: name, address: address, location: p, placeId: id)
        }
        let homeWork = saved.filter { $0.kind == .home || $0.kind == .work }.sorted { ($0.kind == .home ? 0 : 1) < ($1.kind == .home ? 0 : 1) }.map {
            CarDestination(kind: $0.kind == .home ? .home : .work, title: $0.kind == .home ? String(localized: "Home") : String(localized: "Work"),
                           detail: $0.name, destination: dest($0.name, $0.address, $0.location, $0.placeId))
        }
        let favourites = saved.filter { $0.kind == .favorite && !($0.placeId?.hasPrefix(PrivatePlace.idPrefix) ?? false) }.map {
            CarDestination(kind: .favorite, title: $0.name, detail: $0.address, destination: dest($0.name, $0.address, $0.location, $0.placeId))
        }
        let recent = recents.filter { !($0.placeId?.hasPrefix(PrivatePlace.idPrefix) ?? false) }.prefix(maxRecents).map {
            CarDestination(kind: .recent, title: $0.name, detail: $0.address, destination: dest($0.name, $0.address, $0.location, $0.placeId))
        }
        return [homeWork, favourites, Array(recent)].filter { !$0.isEmpty }
    }
}

/// Typing in the car only when parked (the head unit also limits its keyboard while driving).
enum CarInputPolicy {
    static let parkedBelowKmh = 5.0
    static func allowsKeyboard(speedKmh: Double) -> Bool { speedKmh < parkedBelowKmh }
}

/// CarPlay limits a navigation app's template stack (root map + pushed templates).
enum CarTemplateStack {
    static let maxDepth = 5
    /// Whether to pop back to the map before pushing onto a stack of `depth` templates.
    static func mustPopToRoot(beforePushingOnto depth: Int) -> Bool { depth + 1 > maxDepth }
}

/// Every alert the car shows, with how long it stays (all dismiss themselves; nothing waits for a tap).
struct CarAlertSpec: Equatable, Sendable {
    enum Button: Equatable, Sendable { case ok, done, yes, gone }
    var title: String
    var subtitle: String?
    var symbol: String?
    var seconds: TimeInterval
    var primary: Button
    var secondary: Button?

    static func toll(_ t: RouteToll, distanceM: Double) -> CarAlertSpec {
        CarAlertSpec(title: TollText.title(t), subtitle: TollText.carSubtitle(t, distanceM: distanceM), symbol: "building.columns",
                     seconds: 8, primary: .ok, secondary: nil)
    }

    static func tinjau(_ text: String) -> CarAlertSpec {
        CarAlertSpec(title: text, subtitle: nil, symbol: "car.2.fill", seconds: 6, primary: .ok, secondary: nil)
    }

    static func stillThere(type: ReportType, distanceM: Double) -> CarAlertSpec {
        CarAlertSpec(title: "\(String(localized: type.title)) · \(ManeuverFormatter.distance(distanceM))", subtitle: String(localized: "Still there?"),
                     symbol: "exclamationmark.bubble", seconds: 8, primary: .yes, secondary: .gone)
    }

    static var reminder: CarAlertSpec {
        CarAlertSpec(title: String(localized: "Drive safely. Obey the traffic laws."), subtitle: nil, symbol: "checkmark.shield.fill",
                     seconds: 5, primary: .ok, secondary: nil)
    }

    static var restricted: CarAlertSpec {
        CarAlertSpec(title: String(localized: "Reports aren't accepted in restricted areas."), subtitle: nil, symbol: "hand.raised.fill",
                     seconds: 3, primary: .ok, secondary: nil)
    }

    static var reportSent: CarAlertSpec {
        CarAlertSpec(title: String(localized: "Thanks! Your report is live."), subtitle: nil, symbol: "checkmark.circle.fill",
                     seconds: 3, primary: .ok, secondary: nil)
    }

    static func arrived(text: String) -> CarAlertSpec {
        CarAlertSpec(title: String(localized: "You've arrived"), subtitle: text, symbol: "flag.checkered", seconds: 10, primary: .done, secondary: nil)
    }
}

// MARK: - Map surface

/// Where the arrow sits on the car screen: clear of the guidance panel on the left, lower at wider zooms.
enum CarMapLayout {
    /// The guidance panel covers about a third of a small screen, and a fixed width on wide ones.
    static func guidanceWidth(screenWidth w: CGFloat) -> CGFloat { min(w * 0.38, 340) }

    static func padding(size: CGSize, puckY: Double) -> UIEdgeInsets {
        UIEdgeInsets(top: max(0, (2 * puckY - 1) * size.height), left: guidanceWidth(screenWidth: size.width), bottom: 0, right: 0)
    }

    /// The arrow's screen position for that padding (the camera centre of the padded viewport).
    static func arrowPoint(size: CGSize, puckY: Double) -> CGPoint {
        let p = padding(size: size, puckY: puckY)
        return CGPoint(x: p.left + (size.width - p.left) / 2, y: p.top + (size.height - p.top) / 2)
    }

    /// The head unit's day / night appearance picks the map style (not the phone's theme).
    static func styleURL(carIsDark: Bool, light: URL, dark: URL) -> URL { carIsDark ? dark : light }
}
