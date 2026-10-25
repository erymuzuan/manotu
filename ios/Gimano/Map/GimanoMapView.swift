import MapLibre
import SwiftUI
import UIKit

/// MapLibre Native map wrapped for SwiftUI. Renders the basemap (OpenFreeMap / OSM vector tiles),
/// routes with traffic, live jams, alerts, other drivers and the own-position puck.
struct GimanoMapView: UIViewRepresentable {
    let state: MapState

    func makeCoordinator() -> Coordinator { Coordinator(state: state) }

    func makeUIView(context: Context) -> MLNMapView {
        let map = MLNMapView(frame: .zero, styleURL: state.styleURL)
        map.delegate = context.coordinator
        map.logoView.isHidden = true
        // We show our own "© OpenStreetMap contributors" label (see OSMAttribution) which links to the full notice.
        map.attributionButton.isHidden = true
        map.compassView.compassVisibility = .hidden
        map.showsUserLocation = false
        map.allowsRotating = true
        map.setCenter(DemoRepository.defaultLocation.coordinate, zoomLevel: 14, animated: false)
        map.accessibilityIdentifier = "map"

        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleTap(_:)))
        for g in map.gestureRecognizers ?? [] where (g as? UITapGestureRecognizer)?.numberOfTapsRequired == 2 {
            tap.require(toFail: g)
        }
        map.addGestureRecognizer(tap)
        let long = UILongPressGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleLongPress(_:)))
        map.addGestureRecognizer(long)

        context.coordinator.map = map
        context.coordinator.observe()
        return map
    }

    func updateUIView(_ map: MLNMapView, context: Context) {}

    static func dismantleUIView(_ map: MLNMapView, coordinator: Coordinator) {
        coordinator.stopDisplayLink()
        coordinator.map = nil
    }

    @MainActor
    final class Coordinator: NSObject {
        let state: MapState
        weak var map: MLNMapView?
        private var style: MLNStyle?
        private var appliedCameraRevision = -1
        private var lastStyleURL: URL?
        private var lastRoutes: [RouteLine] = []
        private var lastJams: [JamLine] = []
        private var lastAlerts: [Report] = []
        private var lastDrivers: [Driver] = []
        private var lastPrivate: [LatLng] = []
        private var lastRestrictedRevision = -1
        private var lastDestination: LatLng?
        private var lastTolls: [LatLng] = []
        private var lastLastMetres = LastMetres()
        private var lastPuckMove = Date.distantPast
        private var lastHomeInset: Double = 0
        private var lastPlaceInset: Double = 0

        init(state: MapState) {
            self.state = state
        }

        /// Re-applies state whenever any observed property changes.
        func observe() {
            withObservationTracking {
                apply()
            } onChange: { [weak self] in
                Task { @MainActor in self?.observe() }
            }
        }

        private func apply() {
            // Touch everything we depend on so observation tracks it.
            let styleURL = state.styleURL
            let routes = state.routes
            let jams = state.jams
            let alerts = state.alerts
            let drivers = state.drivers
            let privatePins = state.privatePins
            let restrictedRevision = state.restrictedRevision
            let destination = state.destination
            let tolls = state.tolls
            let lastMetres = state.lastMetres
            let puck = state.puck
            let heading = state.puckHeading
            let accuracy = state.puckAccuracyM
            let navPuck = state.navigationPuck
            let cameraRevision = state.cameraRevision
            let camera = state.camera
            _ = state.bubbleAnchors
            let homeInset = state.homeBottomInset
            let placeInset = state.placeBottomInset

            guard let map else { return }
            if lastStyleURL != styleURL {
                if lastStyleURL != nil { map.styleURL = styleURL; style = nil }
                lastStyleURL = styleURL
            }
            guard let style else { return }

            if routes != lastRoutes { updateRoutes(routes, style: style); lastRoutes = routes }
            if jams != lastJams { updateJams(jams, style: style); lastJams = jams }
            if alerts != lastAlerts { updateAlerts(alerts, style: style); lastAlerts = alerts }
            if drivers != lastDrivers { updateDrivers(drivers, style: style); lastDrivers = drivers }
            if privatePins != lastPrivate { updatePrivate(privatePins); lastPrivate = privatePins }
            if restrictedRevision != lastRestrictedRevision { updateRestricted(state.restrictedAreas); lastRestrictedRevision = restrictedRevision }
            if destination != lastDestination { updateDestination(destination, style: style); lastDestination = destination }
            if tolls != lastTolls { updatePoints(tolls, source: "tolls"); lastTolls = tolls }
            if lastMetres != lastLastMetres { updateLastMetres(lastMetres); lastLastMetres = lastMetres }
            syncDisplayLink()
            if !isDrivenByMotion {
                updatePuck(puck, heading: heading, nav: navPuck, style: style)
                updateAccuracy(puck, accuracyM: accuracy)
            }

            if homeInset != lastHomeInset {
                lastHomeInset = homeInset
                if case .trackNorth = camera {
                    // Keep the puck centred in the part of the map the home panel leaves visible.
                    map.setContentInset(trackInsets, animated: true, completionHandler: nil)
                    if let puck { map.setCenter(puck.coordinate, animated: true) }
                }
            }
            if placeInset != lastPlaceInset {
                lastPlaceInset = placeInset
                if case .place(let p, _) = camera, cameraRevision == appliedCameraRevision {
                    // The card changed height (peek ↔ full, Dynamic Type): keep the pin centred in the visible map.
                    map.setContentInset(placeInsets, animated: false, completionHandler: nil)
                    map.setCenter(p.coordinate, animated: true)
                }
            }
            if cameraRevision != appliedCameraRevision {
                appliedCameraRevision = cameraRevision
                applyCamera(camera, puck: puck, heading: heading, animated: true)
            } else if let puck, state.isFollowing, !isDrivenByMotion {
                followPuck(camera, puck: puck, heading: heading)
            }
            projectBubbles()
        }

        // MARK: camera

        private func applyCamera(_ mode: CameraMode, puck: LatLng?, heading: Double, animated: Bool) {
            guard let map else { return }
            switch mode {
            case .free:
                break
            case .trackNorth(let zoom):
                map.setContentInset(trackInsets, animated: false, completionHandler: nil)
                let c = puck?.coordinate ?? map.centerCoordinate
                map.setCenter(c, zoomLevel: zoom, direction: 0, animated: animated)
                let cam = map.camera
                cam.pitch = 0
                map.setCamera(cam, animated: animated)
            case .navigation:
                if isDrivenByMotion {
                    // The display link moves the camera every frame; the first frame eases in from wherever the map is.
                    map.setContentInset(.zero, animated: false, completionHandler: nil)
                    easeInUntil = 0
                } else {
                    let h = map.bounds.height
                    map.setContentInset(UIEdgeInsets(top: h * 0.35, left: 0, bottom: 0, right: 0), animated: false, completionHandler: nil)
                    if let puck { followPuck(.navigation, puck: puck, heading: heading, duration: 0.6) }
                }
            case .overview(let bbox):
                map.setContentInset(.zero, animated: false, completionHandler: nil)
                let bounds = MLNCoordinateBounds(sw: CLLocationCoordinate2D(latitude: bbox.minLat, longitude: bbox.minLng),
                                                 ne: CLLocationCoordinate2D(latitude: bbox.maxLat, longitude: bbox.maxLng))
                let insets = UIEdgeInsets(top: state.overviewInsets.top, left: 48, bottom: state.overviewInsets.bottom, right: 48)
                let cam = map.cameraThatFitsCoordinateBounds(bounds, edgePadding: insets)
                cam.pitch = 0
                cam.heading = 0
                map.setCamera(cam, withDuration: animated ? 0.6 : 0, animationTimingFunction: CAMediaTimingFunction(name: .easeInEaseOut))
            case .center(let p, let zoom):
                map.setContentInset(.zero, animated: false, completionHandler: nil)
                map.setCenter(p.coordinate, zoomLevel: zoom, direction: map.direction, animated: animated)
            case .place(let p, let zoom):
                map.setContentInset(placeInsets, animated: false, completionHandler: nil)
                map.setCenter(p.coordinate, zoomLevel: zoom, direction: 0, animated: animated)
            }
        }

        private var placeInsets: UIEdgeInsets {
            UIEdgeInsets(top: 0, left: 0, bottom: CGFloat(state.placeBottomInset), right: 0)
        }

        private var trackInsets: UIEdgeInsets {
            UIEdgeInsets(top: 0, left: 0, bottom: CGFloat(state.homeBottomInset), right: 0)
        }

        private func followPuck(_ mode: CameraMode, puck: LatLng, heading: Double, duration: TimeInterval = 0.5) {
            guard let map else { return }
            // Throttle: fixes can arrive several times a second.
            let now = Date()
            guard now.timeIntervalSince(lastPuckMove) > 0.25 else { return }
            lastPuckMove = now
            switch mode {
            case .navigation:
                let cam = MLNMapCamera(lookingAtCenter: puck.coordinate, acrossDistance: 700, pitch: 50, heading: heading)
                map.setCamera(cam, withDuration: duration, animationTimingFunction: CAMediaTimingFunction(name: .linear))
            case .trackNorth:
                map.setCenter(puck.coordinate, animated: true)
            default:
                break
            }
        }

        func projectBubbles() {
            guard let map else { return }
            var pts: [String: CGPoint] = [:]
            for (id, c) in state.bubbleAnchors {
                pts[id] = map.convert(c.coordinate, toPointTo: map)
            }
            if pts != state.bubblePoints { state.bubblePoints = pts }
        }

        fileprivate func regionChanged(final: Bool) {
            guard let map else { return }
            if !state.bubbleAnchors.isEmpty || !state.bubblePoints.isEmpty { projectBubbles() }
            guard final else { return }
            // While the camera follows the arrow every frame, publish the viewport at most once a second: these writes
            // are observed (live-data subscriptions) and must never feed back into the per-frame camera (apply() no
            // longer reads them).
            let now = CACurrentMediaTime()
            if isDrivenByMotion, now - lastRegionPublish < 1 { return }
            lastRegionPublish = now
            let b = map.visibleCoordinateBounds
            let bbox = BBox(minLng: b.sw.longitude, minLat: b.sw.latitude, maxLng: b.ne.longitude, maxLat: b.ne.latitude)
            if state.visibleBBox != bbox { state.visibleBBox = bbox }
            if abs(state.zoom - map.zoomLevel) > 0.01 { state.zoom = map.zoomLevel }
            if !isDrivenByMotion { updateAccuracy(state.puck, accuracyM: state.puckAccuracyM) }
        }

        // MARK: per-frame arrow and camera (docs/driving.md §2–3)

        private var displayLink: CADisplayLink?
        private var lastRegionPublish: CFTimeInterval = 0
        private var lastDrawn: (LatLng, Double)?
        /// The camera eases (animated) back onto the arrow until this time, then follows it frame by frame; 0 = ease next.
        private var easeInUntil: CFTimeInterval = 0

        /// Navigating with a motion model: the display link draws the arrow and moves the camera.
        var isDrivenByMotion: Bool { state.navigationPuck && state.motion != nil }

        func syncDisplayLink() {
            if isDrivenByMotion {
                guard displayLink == nil else { return }
                let link = CADisplayLink(target: FrameTarget(self), selector: #selector(FrameTarget.tick(_:)))
                link.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 60, preferred: 60)
                link.add(to: .main, forMode: .common)
                displayLink = link
                lastDrawn = nil
                lastRegionPublish = 0
                easeInUntil = 0
            } else if let link = displayLink {
                link.invalidate()
                displayLink = nil
            }
        }

        func stopDisplayLink() {
            displayLink?.invalidate()
            displayLink = nil
        }

        /// Top padding that puts the arrow `puckY` of the way down the map.
        var puckPadding: (CGFloat, Double) -> UIEdgeInsets = { h, y in UIEdgeInsets(top: max(0, (2 * y - 1) * h), left: 0, bottom: 0, right: 0) }

        func drawFrame(_ link: CADisplayLink) {
            guard let map, style != nil, let motion = state.motion, let f = motion.frame(at: CACurrentMediaTime()) else { return }
            // Only the arrow changes per frame; route, traffic and alerts are redrawn only when they change (apply()).
            if lastDrawn.map({ Geo.distance($0.0, f.point) > 0.05 || abs(Geo.angleDelta($0.1, f.heading)) > 0.2 }) ?? true {
                let p = MLNPointFeature()
                p.coordinate = f.point.coordinate
                p.attributes = ["icon": "puck-nav", "heading": f.heading]
                source("puck")?.shape = p
                if lastDrawn == nil { source("puck-accuracy")?.shape = nil }
                lastDrawn = (f.point, f.heading)
            }
            guard case .navigation = state.camera, map.bounds.height > 0 else { return }
            let size = map.bounds.size
            let altitude = MLNAltitudeForZoomLevel(f.zoom, CGFloat(f.pitch), f.point.lat, size)
            let cam = MLNMapCamera(lookingAtCenter: f.point.coordinate, altitude: altitude, pitch: CGFloat(f.pitch), heading: f.heading)
            let padding = puckPadding(size.height, f.puckY)
            let now = CACurrentMediaTime()
            if easeInUntil == 0 {
                // Start / recentre: one short animated move onto the arrow, then per-frame following.
                easeInUntil = now + 0.7
                map.setCamera(cam, withDuration: 0.7, animationTimingFunction: CAMediaTimingFunction(name: .easeInEaseOut),
                              edgePadding: padding, completionHandler: nil)
                return
            }
            guard now >= easeInUntil else { return }
            map.setCamera(cam, withDuration: 0, animationTimingFunction: nil, edgePadding: padding, completionHandler: nil)
        }

        // MARK: style setup

        fileprivate func styleLoaded(_ style: MLNStyle) {
            self.style = style
            // Resolve dynamic colours against the map's own traits (follows the app's forced theme).
            let traits = map?.traitCollection ?? .current
            Self.registerImages(in: style)
            // Cobalt land colour.
            if let bg = style.layers.first(where: { $0 is MLNBackgroundStyleLayer }) as? MLNBackgroundStyleLayer {
                bg.backgroundColor = NSExpression(forConstantValue: Tokens.Palette.mapBackground.resolvedColor(with: traits))
            }

            func lineLayer(_ id: String, source: MLNSource, color: UIColor, width: Double, opacity: Double = 1, predicate: NSPredicate? = nil) -> MLNLineStyleLayer {
                let l = MLNLineStyleLayer(identifier: id, source: source)
                l.lineColor = NSExpression(forConstantValue: color)
                l.lineWidth = NSExpression(forConstantValue: width)
                l.lineOpacity = NSExpression(forConstantValue: opacity)
                l.lineCap = NSExpression(forConstantValue: "round")
                l.lineJoin = NSExpression(forConstantValue: "round")
                l.predicate = predicate
                return l
            }

            // Restricted areas: translucent grey fill + dashed outline from zoom 12, under the basemap's labels, labelled
            // "Restricted area" (no names, no kinds).
            let restricted = MLNShapeSource(identifier: "restricted", shape: nil)
            style.addSource(restricted)
            let firstLabel = style.layers.first { $0 is MLNSymbolStyleLayer }
            let grey = UIColor(hex: 0x5B6475)
            let fill = MLNFillStyleLayer(identifier: "restricted-fill", source: restricted)
            fill.fillColor = NSExpression(forConstantValue: grey)
            fill.fillOpacity = NSExpression(forConstantValue: 0.22)
            fill.minimumZoomLevel = 12
            let outline = MLNLineStyleLayer(identifier: "restricted-outline", source: restricted)
            outline.lineColor = NSExpression(forConstantValue: grey)
            outline.lineWidth = NSExpression(forConstantValue: 1.6)
            outline.lineOpacity = NSExpression(forConstantValue: 0.8)
            outline.lineDashPattern = NSExpression(forConstantValue: [3, 2])
            outline.minimumZoomLevel = 12
            let label = MLNSymbolStyleLayer(identifier: "restricted-label", source: restricted)
            label.text = NSExpression(forConstantValue: String(localized: "Restricted area"))
            label.textFontNames = NSExpression(forConstantValue: ["Noto Sans Regular"])
            label.textFontSize = NSExpression(forConstantValue: 12)
            label.textColor = NSExpression(forConstantValue: UIColor(hex: 0x3A4250))
            label.textHaloColor = NSExpression(forConstantValue: UIColor.white.withAlphaComponent(0.85))
            label.textHaloWidth = NSExpression(forConstantValue: 1.2)
            label.symbolPlacement = NSExpression(forConstantValue: "point")
            label.minimumZoomLevel = 13
            if let firstLabel {
                style.insertLayer(fill, below: firstLabel)
                style.insertLayer(outline, below: firstLabel)
                style.insertLayer(label, below: firstLabel)
            } else {
                [fill, outline, label].forEach { style.addLayer($0) }
            }

            let jams = MLNShapeSource(identifier: "jams", shape: nil)
            let alt = MLNShapeSource(identifier: "routes-alt", shape: nil)
            let sel = MLNShapeSource(identifier: "route-sel", shape: nil)
            let traffic = MLNShapeSource(identifier: "route-traffic", shape: nil)
            let dest = MLNShapeSource(identifier: "dest", shape: nil)
            let alerts = MLNShapeSource(identifier: "alerts", shape: nil)
            let drivers = MLNShapeSource(identifier: "drivers", shape: nil)
            let puck = MLNShapeSource(identifier: "puck", shape: nil)
            let priv = MLNShapeSource(identifier: "private", shape: nil)
            let tolls = MLNShapeSource(identifier: "tolls", shape: nil)
            let lastM = MLNShapeSource(identifier: "last-metres", shape: nil)
            [jams, alt, sel, traffic, dest, alerts, drivers, puck, priv, tolls, lastM].forEach { style.addSource($0) }

            for level in 1...4 {
                style.addLayer(lineLayer("jam-\(level)", source: jams, color: Tokens.Palette.traffic(level: level), width: 5, opacity: 0.8,
                                         predicate: NSPredicate(format: "level == %d", level)))
            }
            style.addLayer(lineLayer("route-alt-casing", source: alt, color: .white, width: 11))
            style.addLayer(lineLayer("route-alt", source: alt, color: Tokens.Palette.routeAlt.resolvedColor(with: traits), width: 7))
            style.addLayer(lineLayer("route-sel-casing", source: sel, color: Tokens.Palette.brandInk.resolvedColor(with: traits), width: 13))
            style.addLayer(lineLayer("route-sel", source: sel, color: Tokens.Palette.routeActive.resolvedColor(with: traits), width: 9))
            for level in 1...4 {
                style.addLayer(lineLayer("route-traffic-\(level)", source: traffic, color: Tokens.Palette.traffic(level: level), width: 9,
                                         predicate: NSPredicate(format: "level == %d", level)))
            }

            // Last metres: round dots (zero-length dashes with round caps), blue to the entrance, grey on to the pin.
            for (id, color) in [("blue", Tokens.Palette.routeActive.resolvedColor(with: traits)), ("grey", UIColor(hex: 0x8A94A6))] {
                let dots = lineLayer("last-metres-\(id)", source: lastM, color: color, width: 5,
                                     predicate: NSPredicate(format: "kind == %@", id))
                dots.lineDashPattern = NSExpression(forConstantValue: [0, 2])
                style.addLayer(dots)
            }

            let driverLayer = MLNSymbolStyleLayer(identifier: "drivers", source: drivers)
            driverLayer.iconImageName = NSExpression(forConstantValue: "driver")
            driverLayer.iconAllowsOverlap = NSExpression(forConstantValue: true)
            driverLayer.iconScale = NSExpression(forConstantValue: 0.9)
            style.addLayer(driverLayer)

            let privLayer = MLNSymbolStyleLayer(identifier: "private", source: priv)
            privLayer.iconImageName = NSExpression(forConstantValue: "private")
            privLayer.iconAllowsOverlap = NSExpression(forConstantValue: true)
            privLayer.iconAnchor = NSExpression(forConstantValue: "bottom")
            style.addLayer(privLayer)

            let tollLayer = MLNSymbolStyleLayer(identifier: "tolls", source: tolls)
            tollLayer.iconImageName = NSExpression(forConstantValue: "toll")
            tollLayer.iconAllowsOverlap = NSExpression(forConstantValue: true)
            tollLayer.iconAnchor = NSExpression(forConstantValue: "bottom")
            tollLayer.minimumZoomLevel = 9
            style.addLayer(tollLayer)

            let alertLayer = MLNSymbolStyleLayer(identifier: "alerts", source: alerts)
            alertLayer.iconImageName = NSExpression(forKeyPath: "icon")
            alertLayer.iconAllowsOverlap = NSExpression(forConstantValue: true)
            alertLayer.iconAnchor = NSExpression(forConstantValue: "bottom")
            style.addLayer(alertLayer)

            let destLayer = MLNSymbolStyleLayer(identifier: "dest", source: dest)
            destLayer.iconImageName = NSExpression(forConstantValue: "dest")
            destLayer.iconAllowsOverlap = NSExpression(forConstantValue: true)
            destLayer.iconAnchor = NSExpression(forConstantValue: "bottom")
            style.addLayer(destLayer)

            // Accuracy circle under the puck (radius in points, recomputed on zoom).
            let accuracySource = MLNShapeSource(identifier: "puck-accuracy", shape: nil)
            style.addSource(accuracySource)
            let accLayer = MLNCircleStyleLayer(identifier: "puck-accuracy", source: accuracySource)
            accLayer.circleRadius = NSExpression(forKeyPath: "radius")
            accLayer.circleColor = NSExpression(forConstantValue: UIColor(hex: 0x0047AB))
            accLayer.circleOpacity = NSExpression(forConstantValue: 0.12)
            accLayer.circleStrokeColor = NSExpression(forConstantValue: UIColor(hex: 0x0047AB))
            accLayer.circleStrokeOpacity = NSExpression(forConstantValue: 0.35)
            accLayer.circleStrokeWidth = NSExpression(forConstantValue: 1)
            accLayer.circlePitchAlignment = NSExpression(forConstantValue: "map")
            style.addLayer(accLayer)

            let puckLayer = MLNSymbolStyleLayer(identifier: "puck", source: puck)
            puckLayer.iconImageName = NSExpression(forKeyPath: "icon")
            puckLayer.iconRotation = NSExpression(forKeyPath: "heading")
            puckLayer.iconRotationAlignment = NSExpression(forConstantValue: "map")
            puckLayer.iconPitchAlignment = NSExpression(forConstantValue: "map")
            puckLayer.iconAllowsOverlap = NSExpression(forConstantValue: true)
            puckLayer.iconIgnoresPlacement = NSExpression(forConstantValue: true)
            style.addLayer(puckLayer)

            lastRoutes = []; lastJams = []; lastAlerts = []; lastDrivers = []; lastDestination = nil; lastPrivate = []; lastRestrictedRevision = -1
            lastTolls = []; lastLastMetres = LastMetres()
            appliedCameraRevision = -1
            apply()
        }

        private func source(_ id: String) -> MLNShapeSource? { style?.source(withIdentifier: id) as? MLNShapeSource }

        private func polyline(_ pts: [LatLng], attrs: [String: Any] = [:]) -> MLNPolylineFeature {
            var coords = pts.map(\.coordinate)
            let f = MLNPolylineFeature(coordinates: &coords, count: UInt(coords.count))
            f.attributes = attrs
            return f
        }

        private func updateRoutes(_ routes: [RouteLine], style: MLNStyle) {
            let alts = routes.filter { !$0.selected }.map { polyline($0.points, attrs: ["id": $0.id]) }
            source("routes-alt")?.shape = MLNShapeCollectionFeature(shapes: alts)
            if let s = routes.first(where: \.selected) {
                source("route-sel")?.shape = MLNShapeCollectionFeature(shapes: [polyline(s.points, attrs: ["id": s.id])])
                let segs: [MLNPolylineFeature] = s.traffic.compactMap { t in
                    let from = max(0, t.fromIndex), to = min(s.points.count - 1, t.toIndex)
                    guard to > from, t.level > 0 else { return nil }
                    return polyline(Array(s.points[from...to]), attrs: ["level": t.level])
                }
                source("route-traffic")?.shape = MLNShapeCollectionFeature(shapes: segs)
            } else {
                source("route-sel")?.shape = nil
                source("route-traffic")?.shape = nil
            }
        }

        private func updateJams(_ jams: [JamLine], style: MLNStyle) {
            source("jams")?.shape = MLNShapeCollectionFeature(shapes: jams.map { polyline($0.points, attrs: ["level": $0.level, "id": $0.id]) })
        }

        private func updateAlerts(_ alerts: [Report], style: MLNStyle) {
            let features: [MLNPointFeature] = alerts.map { a in
                let f = MLNPointFeature()
                f.coordinate = a.location.coordinate
                f.attributes = ["icon": "alert-\(a.type.rawValue)", "id": a.id]
                return f
            }
            source("alerts")?.shape = MLNShapeCollectionFeature(shapes: features)
        }

        private func updateDrivers(_ drivers: [Driver], style: MLNStyle) {
            let features: [MLNPointFeature] = drivers.map { d in
                let f = MLNPointFeature()
                f.coordinate = CLLocationCoordinate2D(latitude: d.lat, longitude: d.lng)
                return f
            }
            source("drivers")?.shape = MLNShapeCollectionFeature(shapes: features)
        }

        private func updatePrivate(_ pins: [LatLng]) {
            let features: [MLNPointFeature] = pins.map { p in
                let f = MLNPointFeature()
                f.coordinate = p.coordinate
                return f
            }
            source("private")?.shape = MLNShapeCollectionFeature(shapes: features)
        }

        private func updateLastMetres(_ m: LastMetres) {
            var lines: [MLNPolylineFeature] = []
            if m.blue.count > 1 { lines.append(polyline(m.blue, attrs: ["kind": "blue"])) }
            if m.grey.count > 1 { lines.append(polyline(m.grey, attrs: ["kind": "grey"])) }
            source("last-metres")?.shape = lines.isEmpty ? nil : MLNShapeCollectionFeature(shapes: lines)
        }

        private func updatePoints(_ pts: [LatLng], source id: String) {
            let features: [MLNPointFeature] = pts.map { p in
                let f = MLNPointFeature()
                f.coordinate = p.coordinate
                return f
            }
            source(id)?.shape = MLNShapeCollectionFeature(shapes: features)
        }

        private func updateRestricted(_ rings: [[LatLng]]) {
            let polys: [MLNPolygonFeature] = rings.map { ring in
                var coords = ring.map(\.coordinate)
                return MLNPolygonFeature(coordinates: &coords, count: UInt(coords.count))
            }
            source("restricted")?.shape = polys.isEmpty ? nil : MLNShapeCollectionFeature(shapes: polys)
        }

        private func updateDestination(_ p: LatLng?, style: MLNStyle) {
            guard let p else { source("dest")?.shape = nil; return }
            let f = MLNPointFeature()
            f.coordinate = p.coordinate
            source("dest")?.shape = f
        }

        private func updateAccuracy(_ p: LatLng?, accuracyM: Double?) {
            guard let p, let accuracyM, accuracyM > 15, let map else { source("puck-accuracy")?.shape = nil; return }
            let f = MLNPointFeature()
            f.coordinate = p.coordinate
            f.attributes = ["radius": min(400, accuracyM / max(0.01, map.metersPerPoint(atLatitude: p.lat)))]
            source("puck-accuracy")?.shape = f
        }

        private func updatePuck(_ p: LatLng?, heading: Double, nav: Bool, style: MLNStyle) {
            guard let p else { source("puck")?.shape = nil; return }
            let f = MLNPointFeature()
            f.coordinate = p.coordinate
            f.attributes = ["icon": nav ? "puck-nav" : "puck", "heading": nav ? heading : 0]
            source("puck")?.shape = f
        }

        // MARK: gestures

        @objc func handleTap(_ g: UITapGestureRecognizer) {
            guard let map else { return }
            let pt = g.location(in: map)
            let rect = CGRect(x: pt.x - 22, y: pt.y - 22, width: 44, height: 44)
            if let a = map.visibleFeatures(in: rect, styleLayerIdentifiers: ["alerts"]).first,
               let id = a.attribute(forKey: "id") as? String,
               let report = state.alerts.first(where: { $0.id == id }) {
                state.onAlertTapped?(report)
                return
            }
            if let r = map.visibleFeatures(in: rect, styleLayerIdentifiers: ["route-alt", "route-sel"]).first,
               let id = r.attribute(forKey: "id") as? String {
                state.onRouteTapped?(id)
                return
            }
            if map.zoomLevel >= 12, let inside = state.isInsideRestrictedArea,
               inside(LatLng(map.convert(pt, toCoordinateFrom: map))) {
                state.onRestrictedAreaTapped?()
                return
            }
            state.onMapTap?()
        }

        @objc func handleLongPress(_ g: UILongPressGestureRecognizer) {
            guard g.state == .began, let map else { return }
            let c = map.convert(g.location(in: map), toCoordinateFrom: map)
            state.onLongPress?(LatLng(c))
        }

        // MARK: images (Gimano's own glyphs)

        static func registerImages(in style: MLNStyle) {
            for type in ReportType.allCases {
                style.setImage(alertImage(type), forName: "alert-\(type.rawValue)")
            }
            style.setImage(puckImage(nav: false), forName: "puck")
            style.setImage(puckImage(nav: true), forName: "puck-nav")
            style.setImage(driverImage(), forName: "driver")
            style.setImage(destinationImage(), forName: "dest")
            style.setImage(privateImage(), forName: "private")
            style.setImage(tollImage(), forName: "toll")
        }

        private static func symbol(_ name: String, size: CGFloat, color: UIColor) -> UIImage? {
            UIImage(systemName: name, withConfiguration: UIImage.SymbolConfiguration(pointSize: size, weight: .bold))?
                .withTintColor(color, renderingMode: .alwaysOriginal)
        }

        static func alertImage(_ type: ReportType) -> UIImage {
            let size = CGSize(width: 44, height: 52)
            let tone = type.duotone
            return UIGraphicsImageRenderer(size: size).image { ctx in
                let c = ctx.cgContext
                // Rounded pebble with a small tail, white rim, duotone glyph.
                let body = UIBezierPath(roundedRect: CGRect(x: 2, y: 2, width: 40, height: 40), cornerRadius: 15)
                let tail = UIBezierPath()
                tail.move(to: CGPoint(x: 16, y: 40)); tail.addLine(to: CGPoint(x: 22, y: 50)); tail.addLine(to: CGPoint(x: 28, y: 40)); tail.close()
                c.setShadow(offset: CGSize(width: 0, height: 2), blur: 4, color: UIColor(hex: 0x0B1B3A, alpha: 0.25).cgColor)
                UIColor.white.setFill(); body.fill(); tail.fill()
                c.setShadow(offset: .zero, blur: 0, color: nil)
                UIColor(hex: tone.tile).setFill()
                UIBezierPath(roundedRect: CGRect(x: 5, y: 5, width: 34, height: 34), cornerRadius: 12).fill()
                type.gIcon.draw(in: c, rect: CGRect(x: 10, y: 10, width: 24, height: 24), stroke: UIColor(hex: tone.stroke), fill: UIColor(hex: tone.fill))
            }
        }

        static func puckImage(nav: Bool) -> UIImage {
            let size = CGSize(width: 44, height: 44)
            let brand = Tokens.Palette.brand.resolvedColor(with: UITraitCollection(userInterfaceStyle: .light))
            return UIGraphicsImageRenderer(size: size).image { ctx in
                let c = ctx.cgContext
                if nav {
                    let p = UIBezierPath()
                    p.move(to: CGPoint(x: 22, y: 4)); p.addLine(to: CGPoint(x: 38, y: 38)); p.addLine(to: CGPoint(x: 22, y: 30)); p.addLine(to: CGPoint(x: 6, y: 38)); p.close()
                    c.setShadow(offset: CGSize(width: 0, height: 1), blur: 3, color: UIColor.black.withAlphaComponent(0.35).cgColor)
                    UIColor.white.setFill(); p.lineWidth = 4; UIColor.white.setStroke(); p.stroke(); p.fill()
                    c.setShadow(offset: .zero, blur: 0, color: nil)
                    brand.setFill(); p.fill()
                } else {
                    brand.withAlphaComponent(0.18).setFill()
                    UIBezierPath(ovalIn: CGRect(x: 0, y: 0, width: 44, height: 44)).fill()
                    c.setShadow(offset: CGSize(width: 0, height: 1), blur: 3, color: UIColor.black.withAlphaComponent(0.3).cgColor)
                    UIColor.white.setFill(); UIBezierPath(ovalIn: CGRect(x: 11, y: 11, width: 22, height: 22)).fill()
                    c.setShadow(offset: .zero, blur: 0, color: nil)
                    brand.setFill(); UIBezierPath(ovalIn: CGRect(x: 14, y: 14, width: 16, height: 16)).fill()
                }
            }
        }

        static func driverImage() -> UIImage {
            let brand = Tokens.Palette.brand.resolvedColor(with: UITraitCollection(userInterfaceStyle: .light))
            return UIGraphicsImageRenderer(size: CGSize(width: 18, height: 16)).image { _ in
                UIColor.white.setFill()
                UIBezierPath(roundedRect: CGRect(x: 0, y: 0, width: 18, height: 16), cornerRadius: 7).fill()
                brand.withAlphaComponent(0.85).setFill()
                UIBezierPath(roundedRect: CGRect(x: 2, y: 2, width: 14, height: 12), cornerRadius: 5).fill()
            }
        }

        /// "Just for me" pin: heart duotone pebble.
        static func privateImage() -> UIImage {
            UIGraphicsImageRenderer(size: CGSize(width: 36, height: 44)).image { ctx in
                let c = ctx.cgContext
                c.setShadow(offset: CGSize(width: 0, height: 2), blur: 3, color: UIColor(hex: 0x0B1B3A, alpha: 0.25).cgColor)
                UIColor.white.setFill()
                UIBezierPath(roundedRect: CGRect(x: 2, y: 2, width: 32, height: 32), cornerRadius: 12).fill()
                let tail = UIBezierPath()
                tail.move(to: CGPoint(x: 13, y: 33)); tail.addLine(to: CGPoint(x: 18, y: 42)); tail.addLine(to: CGPoint(x: 23, y: 33)); tail.close()
                tail.fill()
                c.setShadow(offset: .zero, blur: 0, color: nil)
                UIColor(hex: 0xE3ECFA).setFill()
                UIBezierPath(roundedRect: CGRect(x: 5, y: 5, width: 26, height: 26), cornerRadius: 10).fill()
                GIcon.heart.draw(in: c, rect: CGRect(x: 8, y: 8, width: 20, height: 20), stroke: UIColor(hex: 0x0A2E6E), fill: UIColor(hex: 0x8FB0E8))
            }
        }

        /// Toll plaza on the route: small white pebble with the duotone toll glyph.
        static func tollImage() -> UIImage {
            UIGraphicsImageRenderer(size: CGSize(width: 32, height: 38)).image { ctx in
                let c = ctx.cgContext
                c.setShadow(offset: CGSize(width: 0, height: 1.5), blur: 3, color: UIColor(hex: 0x0B1B3A, alpha: 0.25).cgColor)
                UIColor.white.setFill()
                UIBezierPath(roundedRect: CGRect(x: 2, y: 2, width: 28, height: 28), cornerRadius: 10).fill()
                let tail = UIBezierPath()
                tail.move(to: CGPoint(x: 11, y: 29)); tail.addLine(to: CGPoint(x: 16, y: 36)); tail.addLine(to: CGPoint(x: 21, y: 29)); tail.close()
                tail.fill()
                c.setShadow(offset: .zero, blur: 0, color: nil)
                UIColor(hex: 0xE3ECFA).setFill()
                UIBezierPath(roundedRect: CGRect(x: 4.5, y: 4.5, width: 23, height: 23), cornerRadius: 8).fill()
                GIcon.toll.draw(in: c, rect: CGRect(x: 7, y: 7, width: 18, height: 18), stroke: UIColor(hex: 0x0A2E6E), fill: UIColor(hex: 0x8FB0E8))
            }
        }

        static func destinationImage() -> UIImage {
            let brand = Tokens.Palette.brand.resolvedColor(with: UITraitCollection(userInterfaceStyle: .light))
            return UIGraphicsImageRenderer(size: CGSize(width: 36, height: 46)).image { ctx in
                ctx.cgContext.setShadow(offset: CGSize(width: 0, height: 1), blur: 2, color: UIColor.black.withAlphaComponent(0.3).cgColor)
                symbol("mappin.circle.fill", size: 30, color: brand)?.draw(in: CGRect(x: 0, y: 0, width: 36, height: 36))
                brand.setFill()
                UIBezierPath(roundedRect: CGRect(x: 16.5, y: 32, width: 3, height: 12), cornerRadius: 1.5).fill()
            }
        }
    }
}

/// Breaks the CADisplayLink → target retain cycle.
@MainActor
final class FrameTarget: NSObject {
    weak var coordinator: GimanoMapView.Coordinator?
    init(_ c: GimanoMapView.Coordinator) { coordinator = c }
    @objc func tick(_ link: CADisplayLink) {
        guard let coordinator else { link.invalidate(); return }
        coordinator.drawFrame(link)
    }
}

extension GimanoMapView.Coordinator: @preconcurrency MLNMapViewDelegate {
    func mapView(_ mapView: MLNMapView, didFinishLoading style: MLNStyle) {
        styleLoaded(style)
    }

    func mapView(_ mapView: MLNMapView, regionWillChangeWith reason: MLNCameraChangeReason, animated: Bool) {
        if reason.contains(.gesturePan) || reason.contains(.gesturePinch) || reason.contains(.gestureRotate) {
            state.onUserGesture?()
        }
    }

    func mapViewRegionIsChanging(_ mapView: MLNMapView) {
        regionChanged(final: false)
    }

    func mapView(_ mapView: MLNMapView, regionDidChangeWith reason: MLNCameraChangeReason, animated: Bool) {
        regionChanged(final: true)
    }
}
