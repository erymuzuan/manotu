import CarPlay
import MapKit
import UIKit

/// Drives the CarPlay templates from the phone's AppModel (docs/driving.md §5): "Ke mana?" list and search, trip
/// previews (≤ 3 routes, "No tolls" / "Tolls RM 2.10"), a CPNavigationSession with our maneuvers while our own map is
/// drawn in the car window, the one-tap report grid, "Masih ada?" / toll / Tinjau / reminder alerts and the arrival
/// step. The phone keeps the only NavigationSession and the only voice: the car never speaks on its own.
@MainActor
final class CarPlayController: NSObject {
    let model: AppModel
    let interface: CPInterfaceController
    let window: CPWindow
    /// What the car map draws: mirrored from the phone's MapState, with the car's own camera.
    let carState: MapState
    let mapVC: CarMapViewController
    let mapTemplate = CPMapTemplate()

    private var syncTimer: Timer?
    private var trip: CPTrip?
    private var navSession: CPNavigationSession?
    /// The phone's session the car session follows.
    private weak var followedNav: NavigationSession?
    private var maneuversKey = ""
    private var paused = false
    private var shownAlertIds: Set<String> = []
    private var lastStillThereAlongM: Double?
    private var arrivalHandled = false
    private var showingAgreementInfo = false
    private var previewRoutesKey = ""
    private var restrictedRevision = -1
    private var searchTask: Task<Void, Never>?
    private var searchResults: [String: PlaceSummary] = [:]

    init(model: AppModel, interface: CPInterfaceController, window: CPWindow) {
        self.model = model
        self.interface = interface
        self.window = window
        self.carState = MapState(styleURL: model.map.styleURL)
        self.mapVC = CarMapViewController(state: carState)
        super.init()
    }

    // MARK: lifecycle

    func connect() {
        window.rootViewController = mapVC
        mapTemplate.mapDelegate = self
        mapTemplate.guidanceBackgroundColor = Tokens.Palette.navBanner
        mapTemplate.tripEstimateStyle = .light
        mapTemplate.leadingNavigationBarButtons = [CPBarButton(title: String(localized: "Where to?")) { [weak self] _ in self?.showDestinations() }]
        mapTemplate.trailingNavigationBarButtons = [CPBarButton(title: String(localized: "Report")) { [weak self] _ in self?.showReportGrid() }]
        let recenter = CPMapButton { [weak self] _ in self?.recenter() }
        recenter.image = UIImage(systemName: "location.north.line.fill")
        mapTemplate.mapButtons = [recenter]
        carState.setCamera(.trackNorth(zoom: 15))
        if model.needsSafetyAgreement {
            showAgreementInfo(asRoot: true)
        } else {
            interface.setRootTemplate(mapTemplate, animated: false, completion: nil)
        }
        sync()
        syncTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.sync() }
        }
        #if DEBUG
        runDebugCarScene()
        #endif
    }

    func disconnect() {
        syncTimer?.invalidate()
        syncTimer = nil
        searchTask?.cancel()
        mapVC.coordinator.stopDisplayLink()
        if let nav = followedNav {
            nav.onTollAhead = nil
            nav.motion.onTinjau = nil
        }
    }

    // MARK: agreement (never shown in the car)

    /// Not agreed yet: "Open Manotu on your phone to start" + "Got it" (CPInformationTemplate).
    private func showAgreementInfo(asRoot: Bool) {
        let info = CPInformationTemplate(
            title: "Manotu", layout: .leading,
            items: [CPInformationItem(title: nil, detail: String(localized: "Open Manotu on your phone to start"))],
            actions: [CPTextButton(title: String(localized: "Got it"), textStyle: .confirm) { [weak self] _ in
                guard let self else { return }
                self.showingAgreementInfo = false
                self.interface.setRootTemplate(self.mapTemplate, animated: true, completion: nil)
            }])
        showingAgreementInfo = true
        if asRoot {
            interface.setRootTemplate(info, animated: false, completion: nil)
        } else {
            interface.pushTemplate(info, animated: true, completion: nil)
        }
    }

    // MARK: Ke mana?

    func showDestinations() {
        guard !model.needsSafetyAgreement else { showAgreementInfo(asRoot: false); return }
        var items: [CPListItem] = []
        for p in model.savedPlaces where p.kind == .home || p.kind == .work {
            items.append(listItem(title: p.kind == .home ? String(localized: "Home") : String(localized: "Work"), detail: p.name,
                                  symbol: p.kind == .home ? "house.fill" : "briefcase.fill",
                                  destination: Destination(name: p.name, address: p.address, location: p.location, placeId: p.placeId)))
        }
        for p in model.savedPlaces where p.kind == .favorite {
            items.append(listItem(title: p.name, detail: p.address, symbol: "star.fill",
                                  destination: Destination(name: p.name, address: p.address, location: p.location, placeId: p.placeId)))
        }
        for r in model.recents.prefix(8) {
            items.append(listItem(title: r.name, detail: r.address, symbol: "clock.arrow.circlepath",
                                  destination: Destination(name: r.name, address: r.address, location: r.location, placeId: r.placeId)))
        }
        // CarPlay shortens lists further while the car is moving (≤ 6 rows driving on most head units).
        let limit = min(CPListTemplate.maximumItemCount, 12)
        let list = CPListTemplate(title: String(localized: "Where to?"), sections: [CPListSection(items: Array(items.prefix(limit)))])
        list.emptyViewTitleVariants = [String(localized: "No saved places yet")]
        list.trailingNavigationBarButtons = [CPBarButton(title: String(localized: "Search")) { [weak self] _ in self?.showSearch() }]
        interface.pushTemplate(list, animated: true, completion: nil)
    }

    private func listItem(title: String, detail: String?, symbol: String, destination: Destination) -> CPListItem {
        let item = CPListItem(text: title, detailText: detail?.isEmpty == true ? nil : detail,
                              image: UIImage(systemName: symbol)?.withTintColor(Tokens.Palette.brand, renderingMode: .alwaysOriginal))
        item.handler = { [weak self] _, done in
            self?.plan(to: destination)
            done()
        }
        return item
    }

    // MARK: search

    func showSearch() {
        let search = CPSearchTemplate()
        search.delegate = self
        interface.pushTemplate(search, animated: true, completion: nil)
    }

    // MARK: route choice

    func plan(to destination: Destination) {
        guard !model.needsSafetyAgreement else { showAgreementInfo(asRoot: false); return }
        if model.navigation != nil { model.stopNavigation() }
        model.planRoute(to: destination)
        interface.popToRootTemplate(animated: true, completion: nil)
        previewRoutesKey = ""
    }

    /// Trip previews for the routes the phone's planner has (max 3): "No tolls" / "Tolls RM 2.10".
    private func showPreviews(_ planner: RoutePlanner) {
        let routes = Array(planner.routes.prefix(3))
        guard !routes.isEmpty, let origin = planner.start.point else { return }
        let choices: [CPRouteChoice] = routes.map { r in
            let toll: String = switch TollBadge.make(for: r, mode: planner.vehicle) {
            case .none: String(localized: "No tolls")
            case .complete(let v): String(localized: "Tolls \(TollBadge.myr(v))")
            case .from(let v): String(localized: "Tolls from \(TollBadge.myr(v))")
            case .unknown: String(localized: "Tolls")
            }
            let c = CPRouteChoice(summaryVariants: [r.summary], additionalInformationVariants: [toll],
                                  selectionSummaryVariants: ["\(ETAFormatter.duration(r.effectiveDurationS)) · \(toll)"])
            c.userInfo = r.id
            return c
        }
        let dest = MKMapItem(placemark: MKPlacemark(coordinate: planner.destination.location.coordinate))
        dest.name = planner.destination.name
        let from = MKMapItem(placemark: MKPlacemark(coordinate: origin.coordinate))
        let t = CPTrip(origin: from, destination: dest, routeChoices: choices)
        t.userInfo = planner.destination.name
        trip = t
        let text = CPTripPreviewTextConfiguration(startButtonTitle: String(localized: "Start"),
                                                  additionalRoutesButtonTitle: String(localized: "Alternative routes"),
                                                  overviewButtonTitle: nil)
        mapTemplate.showTripPreviews([t], selectedTrip: t, textConfiguration: text)
    }

    // MARK: navigating

    private func startCarSession(for nav: NavigationSession) {
        let t = trip ?? makeTrip(for: nav)
        trip = t
        mapTemplate.hideTripPreviews()
        navSession = mapTemplate.startNavigationSession(for: t)
        followedNav = nav
        maneuversKey = ""
        arrivalHandled = false
        shownAlertIds = []
        lastStillThereAlongM = nil
        nav.onTollAhead = { [weak self, weak nav] toll in
            guard let self, let nav else { return }
            // Shown in the car; the phone's voice already says it once (phone and car never both speak).
            self.presentAlert(title: TollText.title(toll), subtitle: TollText.carSubtitle(toll, distanceM: nav.distanceToToll(toll)),
                              symbol: "building.columns", seconds: 8)
        }
        nav.motion.onTinjau = { [weak self] _, text in
            self?.presentAlert(title: text, subtitle: nil, symbol: "car.2.fill", seconds: 6)
        }
        updateManeuvers(nav, force: true)
    }

    private func makeTrip(for nav: NavigationSession) -> CPTrip {
        let dest = MKMapItem(placemark: MKPlacemark(coordinate: nav.destination.location.coordinate))
        dest.name = nav.destination.name
        let start = nav.geometry.points.first ?? model.position
        let c = CPRouteChoice(summaryVariants: [nav.route.summary], additionalInformationVariants: [], selectionSummaryVariants: [])
        c.userInfo = nav.route.id
        return CPTrip(origin: MKMapItem(placemark: MKPlacemark(coordinate: start.coordinate)), destination: dest, routeChoices: [c])
    }

    private func maneuver(_ m: Maneuver, index: Int?, nav: NavigationSession, distanceM: Double) -> CPManeuver {
        let cp = CPManeuver()
        var text = ManeuverFormatter.roadName(m) ?? ManeuverFormatter.instruction(for: m, mode: nav.vehicle)
        if m.type == .arrive {
            if let stop = nav.stopName(forManeuverAt: index) {
                text = String(localized: "Arrive at \(stop)")
            } else if let side = nav.arrivalInfo?.sideText {
                // Arrival: final step "Main entrance on your left".
                text = side
            } else {
                text = String(localized: "Arrive at \(nav.destination.name)")
            }
        }
        cp.instructionVariants = [text, ManeuverFormatter.instruction(for: m, mode: nav.vehicle)]
        cp.symbolImage = UIImage(systemName: ManeuverFormatter.symbol(for: m.type),
                                 withConfiguration: UIImage.SymbolConfiguration(pointSize: 40, weight: .heavy))
        cp.initialTravelEstimates = CPTravelEstimates(distanceRemaining: Measurement(value: max(0, distanceM), unit: UnitLength.meters),
                                                      timeRemaining: 0)
        cp.userInfo = index
        return cp
    }

    private func updateManeuvers(_ nav: NavigationSession, force: Bool = false) {
        guard let session = navSession else { return }
        let key = "\(nav.route.id)-\(nav.progress?.upcomingIndex ?? -1)-\(nav.progress?.thenIndex ?? -1)-\(nav.arrivalInfo?.sideText ?? "")"
        if nav.isRerouting {
            if !paused || force { session.pauseTrip(for: .rerouting, description: String(localized: "Recalculating…")) }
            paused = true
            return
        }
        // New maneuvers also resume a paused (rerouting) trip.
        if key != maneuversKey || force || paused {
            paused = false
            maneuversKey = key
            var list: [CPManeuver] = []
            if let up = nav.upcoming {
                list.append(maneuver(up, index: nav.progress?.upcomingIndex, nav: nav, distanceM: nav.distanceToUpcoming))
            }
            if let then = nav.then {
                list.append(maneuver(then, index: nav.progress?.thenIndex, nav: nav, distanceM: 0))
            }
            session.upcomingManeuvers = list
        }
        if let first = session.upcomingManeuvers.first {
            session.updateEstimates(CPTravelEstimates(distanceRemaining: Measurement(value: nav.distanceToUpcoming, unit: UnitLength.meters),
                                                      timeRemaining: 0), for: first)
        }
        if let trip {
            mapTemplate.update(CPTravelEstimates(distanceRemaining: Measurement(value: nav.remainingM, unit: UnitLength.meters),
                                                 timeRemaining: nav.remainingS), for: trip, with: .default)
        }
    }

    // MARK: alerts

    /// One alert at a time (CarPlay shows a single navigation alert); a newer one replaces it.
    private func presentAlert(title: String, subtitle: String?, symbol: String?, seconds: TimeInterval,
                              primary: CPAlertAction? = nil, secondary: CPAlertAction? = nil) {
        // CPNavigationAlert needs a primary action; information alerts get a plain dismiss button.
        let ok = primary ?? CPAlertAction(title: String(localized: "OK"), style: .cancel) { _ in }
        let alert = CPNavigationAlert(titleVariants: [title], subtitleVariants: subtitle.map { [$0] } ?? [],
                                      image: symbol.flatMap { UIImage(systemName: $0) }, primaryAction: ok,
                                      secondaryAction: secondary, duration: seconds)
        if mapTemplate.currentNavigationAlert != nil {
            mapTemplate.dismissNavigationAlert(animated: false) { [weak self] _ in
                MainActor.assumeIsolated { self?.mapTemplate.present(navigationAlert: alert, animated: true) }
            }
        } else {
            mapTemplate.present(navigationAlert: alert, animated: true)
        }
    }

    /// "Masih ada?" for an alert on the route ahead: Yes / Gone, 8 s, at most one per 2 km.
    private func considerStillThere(_ nav: NavigationSession) {
        guard let a = nav.approachingAlert, !shownAlertIds.contains(a.id) else { return }
        let along = nav.progress?.snap.distanceAlongM ?? 0
        if let last = lastStillThereAlongM, along - last < 2000 { shownAlertIds.insert(a.id); return }
        shownAlertIds.insert(a.id)
        lastStillThereAlongM = along
        let title = "\(String(localized: a.report.type.title)) · \(ManeuverFormatter.distance(nav.distanceToAlert(a)))"
        let yes = CPAlertAction(title: String(localized: "Yes"), style: .default) { [weak self, weak nav] _ in
            guard let self, let nav else { return }
            Task { if await self.model.ensureRulesAccepted() { nav.vote(stillThere: true) } }
        }
        let gone = CPAlertAction(title: String(localized: "Gone"), style: .cancel) { [weak self, weak nav] _ in
            guard let self, let nav else { return }
            Task { if await self.model.ensureRulesAccepted() { nav.vote(stillThere: false) } }
        }
        presentAlert(title: title, subtitle: String(localized: "Still there?"), symbol: "exclamationmark.bubble", seconds: 8,
                     primary: yes, secondary: gone)
    }

    // MARK: report grid (≤ 8, one tap)

    func showReportGrid() {
        let types: [ReportType] = [.police, .accident, .traffic, .hazard, .closure, .blockedLane]
        let buttons = types.map { type in
            CPGridButton(titleVariants: [String(localized: type.title)], image: GimanoMapView.Coordinator.alertImage(type)) { [weak self] _ in
                self?.report(type)
            }
        }
        interface.pushTemplate(CPGridTemplate(title: String(localized: "Report"), gridButtons: buttons), animated: true, completion: nil)
    }

    private func report(_ type: ReportType) {
        interface.popToRootTemplate(animated: true, completion: nil)
        // Restricted areas: nothing is sent; the car says why for 3 s.
        if model.restricted.proximity(of: model.position) == .blocked {
            presentAlert(title: String(localized: "Reports aren't accepted in restricted areas."), subtitle: nil, symbol: "hand.raised.fill", seconds: 3)
            return
        }
        model.submitReport(type: type, subtype: nil, comment: nil)
        presentAlert(title: String(localized: "Thanks! Your report is live."), subtitle: nil, symbol: "checkmark.circle.fill", seconds: 3)
    }

    // MARK: camera

    private func recenter() {
        if model.navigation != nil { carState.setCamera(.navigation) } else { carState.setCamera(.trackNorth(zoom: 15)) }
    }

    // MARK: sync with the phone (twice a second)

    func sync() {
        if showingAgreementInfo, !model.needsSafetyAgreement {
            showingAgreementInfo = false
            interface.setRootTemplate(mapTemplate, animated: true, completion: nil)
        }
        mirrorMap()

        // Trip previews while the phone's route preview has routes and nothing is driving.
        if model.navigation == nil, model.screen == .routePreview, let planner = model.planner, !planner.routes.isEmpty {
            let key = planner.routes.map(\.id).joined(separator: ",")
            if key != previewRoutesKey {
                previewRoutesKey = key
                showPreviews(planner)
                if let b = BBox.around(planner.routes.flatMap { r in BBox(array: r.bbox).map { [LatLng(lat: $0.minLat, lng: $0.minLng), LatLng(lat: $0.maxLat, lng: $0.maxLng)] } ?? [] }) {
                    carState.overviewInsets = (top: 40, bottom: 40)
                    carState.setCamera(.overview(b))
                }
            }
        } else if model.navigation == nil, !previewRoutesKey.isEmpty {
            previewRoutesKey = ""
            mapTemplate.hideTripPreviews()
            trip = nil
            carState.setCamera(.trackNorth(zoom: 15))
        }

        guard let nav = model.navigation else {
            if arrivalHandled {
                // "Done" on the phone after arriving: close the car's arrival alert too.
                arrivalHandled = false
                followedNav = nil
                trip = nil
                if mapTemplate.currentNavigationAlert != nil { mapTemplate.dismissNavigationAlert(animated: true) { _ in } }
                carState.setCamera(.trackNorth(zoom: 15))
            }
            if let s = navSession {
                // The drive ended on the phone.
                s.cancelTrip()
                navSession = nil
                followedNav = nil
                trip = nil
                carState.setCamera(.trackNorth(zoom: 15))
            }
            return
        }
        if followedNav !== nav {
            if let old = navSession { old.cancelTrip(); navSession = nil; trip = nil }
            startCarSession(for: nav)
            carState.setCamera(.navigation)
        }
        if nav.arrived {
            guard !arrivalHandled else { return }
            arrivalHandled = true
            navSession?.finishTrip()
            navSession = nil
            let done = CPAlertAction(title: String(localized: "Done"), style: .default) { [weak self] _ in self?.model.stopNavigation() }
            presentAlert(title: String(localized: "You've arrived"), subtitle: nav.arrivalInfo?.text ?? nav.destination.name,
                         symbol: "flag.checkered", seconds: 0, primary: done)
            return
        }
        updateManeuvers(nav)
        considerStillThere(nav)
    }

    /// The car map draws what the phone map draws; only the camera is the car's own.
    private func mirrorMap() {
        carState.mirror(from: model.map, restrictedRevision: &restrictedRevision)
    }
}

extension CarPlayController: CPMapTemplateDelegate {
    func mapTemplate(_ mapTemplate: CPMapTemplate, selectedPreviewFor trip: CPTrip, using routeChoice: CPRouteChoice) {
        if let id = routeChoice.userInfo as? String { model.selectRoute(id) }
    }

    func mapTemplate(_ mapTemplate: CPMapTemplate, startedTrip trip: CPTrip, using routeChoice: CPRouteChoice) {
        if let id = routeChoice.userInfo as? String { model.selectRoute(id) }
        self.trip = trip
        mapTemplate.hideTripPreviews()
        guard let reminder = model.startNavigationFromCar() else {
            if model.needsSafetyAgreement { showAgreementInfo(asRoot: false) }
            return
        }
        sync()
        // Drive reminder: no card in the car, a 5 s alert at the start when the reminder is on.
        if reminder {
            presentAlert(title: String(localized: "Drive safely. Obey the traffic laws."), subtitle: nil, symbol: "checkmark.shield.fill", seconds: 5)
        }
    }

    func mapTemplateDidCancelNavigation(_ mapTemplate: CPMapTemplate) {
        model.stopNavigation()
    }
}

extension CarPlayController: CPSearchTemplateDelegate {
    func searchTemplate(_ searchTemplate: CPSearchTemplate, updatedSearchText searchText: String,
                        completionHandler: @escaping ([CPListItem]) -> Void) {
        searchTask?.cancel()
        let q = searchText.trimmingCharacters(in: .whitespaces)
        guard q.count >= 2 else { completionHandler([]); return }
        let near = model.position
        let repo = model.repo
        searchTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            let results = (try? await repo.search(query: q, near: near, category: nil, limit: 12)) ?? []
            guard !Task.isCancelled, let self else { return }
            self.searchResults = Dictionary(results.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            completionHandler(results.map { p in
                let item = CPListItem(text: p.name, detailText: p.address)
                item.userInfo = p.id
                return item
            })
        }
    }

    func searchTemplate(_ searchTemplate: CPSearchTemplate, selectedResult item: CPListItem, completionHandler: @escaping () -> Void) {
        defer { completionHandler() }
        guard let id = item.userInfo as? String, let p = searchResults[id] else { return }
        plan(to: Destination(name: p.name, address: p.address, location: p.location,
                             placeId: p.id.hasPrefix("pin:") || p.isSearchOnly ? nil : p.id, category: p.category))
    }
}

#if DEBUG
extension CarPlayController {
    /// `-GimanoCarScene places|search|report|agreement`: open that car screen on connect (CarPlay Simulator screenshots).
    private func runDebugCarScene() {
        guard let scene = UserDefaults.standard.string(forKey: "GimanoCarScene") else { return }
        Task {
            try? await Task.sleep(for: .seconds(2))
            switch scene {
            case "places": showDestinations()
            case "search": showSearch()
            case "report": showReportGrid()
            case "agreement": showAgreementInfo(asRoot: false)
            default: break
            }
        }
    }
}
#endif
