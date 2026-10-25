import MapLibre
import UIKit

/// Our own map drawn in the CarPlay window: the same layers (route, traffic, alerts, tolls, restricted areas, dotted
/// last metres) and the same per-frame arrow and camera as the phone (one shared DriveMotion), plus the © OSM line.
@MainActor
final class CarMapViewController: UIViewController {
    let state: MapState
    let coordinator: GimanoMapView.Coordinator
    private(set) var map: MLNMapView?

    init(state: MapState) {
        self.state = state
        self.coordinator = GimanoMapView.Coordinator(state: state)
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func loadView() {
        let map = GimanoMapView.makeMap(state: state, coordinator: coordinator)
        map.isUserInteractionEnabled = false
        map.accessibilityIdentifier = "carMap"
        // The guidance panel sits on the left of the car screen: keep the arrow in the visible part on the right.
        coordinator.puckPadding = { size, y in CarMapLayout.padding(size: size, puckY: y) }
        self.map = map
        view = map

        let osm = UILabel()
        osm.text = String(localized: "© OpenStreetMap contributors")
        osm.font = UIFont(name: Tokens.Font.Weight.bold.postScriptName, size: 10) ?? .boldSystemFont(ofSize: 10)
        osm.textColor = UIColor(hex: 0x0B1B3A).withAlphaComponent(0.8)
        osm.backgroundColor = UIColor.white.withAlphaComponent(0.7)
        osm.layer.cornerRadius = 6
        osm.layer.masksToBounds = true
        osm.textAlignment = .center
        osm.translatesAutoresizingMaskIntoConstraints = false
        map.addSubview(osm)
        NSLayoutConstraint.activate([
            osm.trailingAnchor.constraint(equalTo: map.safeAreaLayoutGuide.trailingAnchor, constant: -6),
            osm.bottomAnchor.constraint(equalTo: map.safeAreaLayoutGuide.bottomAnchor, constant: -4),
            osm.heightAnchor.constraint(equalToConstant: 16),
        ])
        osm.setContentHuggingPriority(.required, for: .horizontal)
        osm.text = "  " + (osm.text ?? "") + "  "
        coordinator.observe()
    }
}

extension MapState {
    /// Copies what the phone map draws (route, traffic, alerts, tolls, restricted areas, last metres, the arrow and
    /// its motion) into a second map's state; the camera and the day/night style stay that map's own.
    func mirror(from m: MapState, restrictedRevision: inout Int) {
        if routes != m.routes { routes = m.routes }
        if destination != m.destination { destination = m.destination }
        if alerts != m.alerts { alerts = m.alerts }
        if jams != m.jams { jams = m.jams }
        if tolls != m.tolls { tolls = m.tolls }
        if lastMetres != m.lastMetres { lastMetres = m.lastMetres }
        if restrictedRevision != m.restrictedRevision {
            restrictedRevision = m.restrictedRevision
            restrictedAreas = m.restrictedAreas
        }
        if puck != m.puck { puck = m.puck }
        if puckHeading != m.puckHeading { puckHeading = m.puckHeading }
        motion = m.motion
        if navigationPuck != m.navigationPuck { navigationPuck = m.navigationPuck }
    }
}

#if DEBUG
/// `-GimanoCarPreview YES` (DEBUG only): a **map preview** of the car's map surface (CarMapViewController,
/// 800 × 480, scaled) on the phone, mirroring the drive with the car's own camera. Map-only debugging: it is not a
/// CarPlay template session and nothing from it counts as CarPlay validation.
@MainActor
enum CarSurfacePreview {
    private static var window: UIWindow?
    private static var timer: Timer?
    private static var revision = -1

    static func show(model: AppModel) {
        guard window == nil, let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first else { return }
        let state = MapState(styleURL: model.map.styleURL)
        state.setCamera(.trackNorth(zoom: 15))
        let car = CarMapViewController(state: state)
        let width = scene.screen.bounds.width
        let scale = width / 800
        let w = UIWindow(windowScene: scene)
        w.frame = CGRect(x: 0, y: scene.screen.bounds.height - 480 * scale - 64, width: width, height: 480 * scale + 30)
        w.windowLevel = .alert + 1
        w.isUserInteractionEnabled = false
        let host = UIViewController()
        host.view.backgroundColor = .black
        w.rootViewController = host
        host.addChild(car)
        car.view.bounds = CGRect(x: 0, y: 0, width: 800, height: 480)
        car.view.transform = CGAffineTransform(scaleX: scale, y: scale)
        car.view.center = CGPoint(x: width / 2, y: 22 + 240 * scale)
        host.view.addSubview(car.view)
        car.didMove(toParent: host)
        let label = UILabel(frame: CGRect(x: 8, y: 2, width: width - 16, height: 18))
        label.text = "Map preview 800×480 (DEBUG) · not a CarPlay test"
        label.font = .systemFont(ofSize: 11, weight: .semibold)
        label.textColor = .white
        host.view.addSubview(label)
        w.isHidden = false
        window = w
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in
            MainActor.assumeIsolated {
                state.mirror(from: model.map, restrictedRevision: &revision)
                let navigating = model.navigation != nil
                if navigating, state.camera != .navigation { state.setCamera(.navigation) }
                if !navigating, state.camera == .navigation { state.setCamera(.trackNorth(zoom: 15)) }
            }
        }
    }
}
#endif
