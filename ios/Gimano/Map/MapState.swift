import CoreGraphics
import Foundation
import Observation

/// A route as drawn on the map.
struct RouteLine: Equatable {
    var id: String
    var points: [LatLng]
    var selected: Bool
    var traffic: [TrafficSegment]
}

struct JamLine: Equatable {
    var id: String
    var level: Int
    var points: [LatLng]
}

enum CameraMode: Equatable {
    /// Free map; user is panning.
    case free
    /// Centered on the puck, north up.
    case trackNorth(zoom: Double)
    /// Driving camera: tilted, heading up, puck low on screen.
    case navigation
    /// Fit a bounding box (route overview).
    case overview(BBox)
    /// Center on a coordinate once.
    case center(LatLng, zoom: Double)
    /// Place card: the place's pin centred in the map left visible above the card (`placeBottomInset`),
    /// re-centred whenever the card changes height.
    case place(LatLng, zoom: Double)
}

/// Everything the map renders. Owned by `AppModel`, observed by the map coordinator.
@MainActor
@Observable
final class MapState {
    var styleURL: URL
    var puck: LatLng?
    var puckHeading: Double = 0
    /// Horizontal accuracy (m) drawn as a circle around the puck.
    var puckAccuracyM: Double?
    var navigationPuck = false
    var routes: [RouteLine] = []
    var destination: LatLng?
    var alerts: [Report] = []
    var jams: [JamLine] = []
    var drivers: [Driver] = []
    /// "Just for me" places, drawn from the local DB only.
    var privatePins: [LatLng] = []
    /// Restricted areas (docs/safety.md D): grey fill + dashed outline from zoom 12, under the basemap labels.
    var restrictedAreas: [[LatLng]] = [] { didSet { restrictedRevision += 1 } }
    private(set) var restrictedRevision = 0
    /// Hit test for a tap inside an area (the map only draws; the app owns the index).
    @ObservationIgnored var isInsideRestrictedArea: ((LatLng) -> Bool)?
    @ObservationIgnored var onRestrictedAreaTapped: (() -> Void)?
    var camera: CameraMode = .trackNorth(zoom: 14)
    var cameraRevision = 0
    /// Extra insets (sheet/banners) so fitted content stays visible.
    var overviewInsets = (top: 140.0, bottom: 360.0)
    /// Height (pt) the home panel covers at the bottom; north-up tracking keeps the puck centred above it.
    var homeBottomInset: Double = 0
    /// Height (pt) the place card covers at the bottom; the place camera centres the pin above it.
    var placeBottomInset: Double = 0

    /// Coordinates to project to screen points (route duration bubbles).
    var bubbleAnchors: [String: LatLng] = [:]
    /// Screen positions of `bubbleAnchors`, updated by the map as it moves.
    var bubblePoints: [String: CGPoint] = [:]
    var visibleBBox: BBox?
    var zoom: Double = 14

    @ObservationIgnored var onRouteTapped: ((String) -> Void)?
    @ObservationIgnored var onAlertTapped: ((Report) -> Void)?
    @ObservationIgnored var onUserGesture: (() -> Void)?
    /// A tap on the map that hit no alert or route.
    @ObservationIgnored var onMapTap: (() -> Void)?
    @ObservationIgnored var onLongPress: ((LatLng) -> Void)?

    init(styleURL: URL) {
        self.styleURL = styleURL
    }

    func setCamera(_ mode: CameraMode) {
        camera = mode
        cameraRevision += 1
    }

    /// The place camera is holding the card's pin centred (until the user pans).
    var isPlaceCentred: Bool {
        if case .place = camera { return true }
        return false
    }

    var isFollowing: Bool {
        switch camera {
        case .trackNorth, .navigation: true
        default: false
        }
    }
}
