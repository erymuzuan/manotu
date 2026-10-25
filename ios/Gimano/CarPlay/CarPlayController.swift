import CarPlay
import MapKit
import UIKit

/// Drives the CarPlay templates from the phone's AppModel (docs/driving.md §5): "Where to?" list and search, trip
/// previews (≤ 3 routes, "No tolls" / "Tolls RM 2.10"), a CPNavigationSession with our maneuvers while our own map is
/// drawn in the car window, the one-tap report grid, "Still there?" / toll / Tinjau / reminder / arrival alerts.
/// The phone keeps the only NavigationSession and the only voice: the car never speaks, and a car that disconnects
/// and reconnects mid-drive picks the drive up again (CarDriveSync). Decisions live in CarPlayLogic.swift.
@MainActor
final class CarPlayController: NSObject {
    let model: AppModel
    let interface: CPInterfaceController
    let window: CPWindow
    /// What the car map draws: mirrored from the phone's MapState, with the car's own camera and day/night style.
    let carState: MapState
    let mapVC: CarMapViewController
    let mapTemplate = CPMapTemplate()

    private var syncTimer: Timer?
    private var trip: CPTrip?
    private var navSession: CPNavigationSession?
    private weak var followedNav: NavigationSession?
    private var drive = CarDriveSync()
    private var showingAgreementInfo = false
    private var previewRoutesKey = ""
    private var restrictedRevision = -1
    private var searchTask: Task<Void, Never>?
    private var searchResults: [String: PlaceSummary] = [:]

    init(model: AppModel, interface: CPInterfaceController, window: CPWindow) {
        self.model = model
        self.interface = interface
        self.window = window
        self.carState = MapState(styleURL: model.config.styleURL)
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

    /// The car went away: the drive (and its voice) carries on on the phone; only the car's hooks are removed.
    func disconnect() {
        syncTimer?.invalidate()
        syncTimer = nil
        searchTask?.cancel()
        mapVC.coordinator.stopDisplayLink()
        if let nav = followedNav { Self.detachHooks(from: nav) }
        followedNav = nil
        navSession = nil
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
            push(info)
        }
    }

    /// Pushes within CarPlay's template depth limit (back to the map first when it would be exceeded).
    private func push(_ t: CPTemplate) {
        if CarTemplateStack.mustPopToRoot(beforePushingOnto: interface.templates.count) {
            interface.popToRootTemplate(animated: false, completion: nil)
        }
        interface.pushTemplate(t, animated: true, completion: nil)
    }

    // MARK: Where to?

    func showDestinations() {
        guard !model.needsSafetyAgreement else { showAgreementInfo(asRoot: false); return }
        let groups = CarListLimits.clamp(CarDestination.make(saved: model.savedPlaces, recents: model.recents),
                                         maxItems: Int(CPListTemplate.maximumItemCount), maxSections: Int(CPListTemplate.maximumSectionCount))
        let sections = groups.map { CPListSection(items: $0.map(listItem)) }
        let list = CPListTemplate(title: String(localized: "Where to?"), sections: sections)
        list.emptyViewTitleVariants = [String(localized: "No saved places yet")]
        // Typing only when parked.
        if CarInputPolicy.allowsKeyboard(speedKmh: model.speedKmh) {
            list.trailingNavigationBarButtons = [CPBarButton(title: String(localized: "Search")) { [weak self] _ in self?.showSearch() }]
        }
        push(list)
    }

    private func listItem(_ d: CarDestination) -> CPListItem {
        let symbol = switch d.kind {
        case .home: "house.fill"
        case .work: "briefcase.fill"
        case .favorite: "star.fill"
        case .recent: "clock.arrow.circlepath"
        }
        let item = CPListItem(text: d.title, detailText: d.detail?.isEmpty == true ? nil : d.detail,
                              image: UIImage(systemName: symbol)?.withTintColor(Tokens.Palette.brand, renderingMode: .alwaysOriginal))
        item.handler = { [weak self] _, done in
            self?.plan(to: d.destination)
            done()
        }
        return item
    }

    // MARK: search

    func showSearch() {
        guard CarInputPolicy.allowsKeyboard(speedKmh: model.speedKmh) else { return }
        let search = CPSearchTemplate()
        search.delegate = self
        push(search)
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
            let toll = Self.tollText(TollBadge.make(for: r, mode: planner.vehicle))
            let c = CPRouteChoice(summaryVariants: [r.summary], additionalInformationVariants: [toll],
                                  selectionSummaryVariants: ["\(ETAFormatter.duration(r.effectiveDurationS)) · \(toll)"])
            c.userInfo = r.id
            return c
        }
        let dest = MKMapItem(placemark: MKPlacemark(coordinate: planner.destination.location.coordinate))
        dest.name = planner.destination.name
        let from = MKMapItem(placemark: MKPlacemark(coordinate: origin.coordinate))
        let t = CPTrip(origin: from, destination: dest, routeChoices: choices)
        trip = t
        let text = CPTripPreviewTextConfiguration(startButtonTitle: String(localized: "Start"),
                                                  additionalRoutesButtonTitle: String(localized: "Alternative routes"),
                                                  overviewButtonTitle: nil)
        mapTemplate.showTripPreviews([t], selectedTrip: t, textConfiguration: text)
    }

    static func tollText(_ badge: TollBadge) -> String {
        switch badge {
        case .none: String(localized: "No tolls")
        case .complete(let v): String(localized: "Tolls \(TollBadge.myr(v))")
        case .from(let v): String(localized: "Tolls from \(TollBadge.myr(v))")
        case .unknown: String(localized: "Tolls")
        }
    }

    // MARK: navigating

    /// The car's alerts for a drive (toll ahead, Tinjau). Shown only: the phone's voice already says the toll once.
    static func attachHooks(to nav: NavigationSession, present: @escaping @MainActor (CarAlertSpec) -> Void) {
        nav.onTollAhead = { [weak nav] toll in
            guard let nav else { return }
            present(.toll(toll, distanceM: nav.distanceToToll(toll)))
        }
        nav.motion.onTinjau = { _, text in present(.tinjau(text)) }
    }

    static func detachHooks(from nav: NavigationSession) {
        nav.onTollAhead = nil
        nav.motion.onTinjau = nil
    }

    /// The guidance panel: the upcoming maneuver and, when close, the one after (the final step names the entrance side).
    static func maneuvers(for nav: NavigationSession) -> [CPManeuver] {
        var list: [CPManeuver] = []
        if let up = nav.upcoming {
            list.append(maneuver(up, index: nav.progress?.upcomingIndex, nav: nav, distanceM: nav.distanceToUpcoming))
        }
        if let then = nav.then {
            list.append(maneuver(then, index: nav.progress?.thenIndex, nav: nav, distanceM: 0))
        }
        return list
    }

    private static func maneuver(_ m: Maneuver, index: Int?, nav: NavigationSession, distanceM: Double) -> CPManeuver {
        let cp = CPManeuver()
        cp.instructionVariants = [CarManeuverText.primary(m, index: index, nav: nav), ManeuverFormatter.instruction(for: m, mode: nav.vehicle)]
        cp.symbolImage = UIImage(systemName: ManeuverFormatter.symbol(for: m.type),
                                 withConfiguration: UIImage.SymbolConfiguration(pointSize: 40, weight: .heavy))
        cp.initialTravelEstimates = CPTravelEstimates(distanceRemaining: Measurement(value: max(0, distanceM), unit: UnitLength.meters),
                                                      timeRemaining: 0)
        cp.userInfo = index
        return cp
    }

    private func makeTrip(for nav: NavigationSession) -> CPTrip {
        let dest = MKMapItem(placemark: MKPlacemark(coordinate: nav.destination.location.coordinate))
        dest.name = nav.destination.name
        let start = nav.geometry.points.first ?? model.position
        let c = CPRouteChoice(summaryVariants: [nav.route.summary], additionalInformationVariants: [], selectionSummaryVariants: [])
        c.userInfo = nav.route.id
        return CPTrip(origin: MKMapItem(placemark: MKPlacemark(coordinate: start.coordinate)), destination: dest, routeChoices: [c])
    }

    private func perform(_ action: CarNavAction, nav: NavigationSession?) {
        switch action {
        case .startSession:
            guard let nav else { return }
            if let old = followedNav, old !== nav { Self.detachHooks(from: old) }
            let t = trip ?? makeTrip(for: nav)
            trip = t
            mapTemplate.hideTripPreviews()
            navSession = mapTemplate.startNavigationSession(for: t)
            followedNav = nav
            Self.attachHooks(to: nav) { [weak self] spec in self?.present(spec) }
            carState.setCamera(.navigation)
        case .cancelSession:
            navSession?.cancelTrip()
            navSession = nil
            if let old = followedNav { Self.detachHooks(from: old) }
            followedNav = nil
            trip = nil
            carState.setCamera(.trackNorth(zoom: 15))
        case .pause:
            navSession?.pauseTrip(for: .rerouting, description: String(localized: "Recalculating…"))
        case .showManeuvers:
            guard let nav else { return }
            navSession?.upcomingManeuvers = Self.maneuvers(for: nav)
        case .updateEstimates:
            guard let nav, let session = navSession else { return }
            if let first = session.upcomingManeuvers.first {
                session.updateEstimates(CPTravelEstimates(distanceRemaining: Measurement(value: nav.distanceToUpcoming, unit: UnitLength.meters),
                                                          timeRemaining: 0), for: first)
            }
            if let trip {
                mapTemplate.update(CPTravelEstimates(distanceRemaining: Measurement(value: nav.remainingM, unit: UnitLength.meters),
                                                     timeRemaining: nav.remainingS), for: trip, with: .default)
            }
        case .finishAndShowArrival:
            navSession?.finishTrip()
            navSession = nil
            if let nav { present(.arrived(text: nav.arrivalInfo?.text ?? nav.destination.name)) }
        case .dismissArrival:
            if mapTemplate.currentNavigationAlert != nil { mapTemplate.dismissNavigationAlert(animated: true) { _ in } }
            if let old = followedNav { Self.detachHooks(from: old) }
            followedNav = nil
            trip = nil
            carState.setCamera(.trackNorth(zoom: 15))
        case .stillThere(let id):
            guard let nav, let a = nav.approachingAlert, a.id == id else { return }
            present(.stillThere(type: a.report.type, distanceM: nav.distanceToAlert(a)), alertId: id)
        }
    }

    // MARK: alerts

    /// One alert at a time (CarPlay shows a single navigation alert); a newer one replaces it. All dismiss themselves.
    private func present(_ spec: CarAlertSpec, alertId: String? = nil) {
        let alert = CPNavigationAlert(titleVariants: [spec.title], subtitleVariants: spec.subtitle.map { [$0] } ?? [],
                                      image: spec.symbol.flatMap { UIImage(systemName: $0) },
                                      primaryAction: action(spec.primary), secondaryAction: spec.secondary.map(action),
                                      duration: spec.seconds)
        if mapTemplate.currentNavigationAlert != nil {
            mapTemplate.dismissNavigationAlert(animated: false) { [weak self] _ in
                MainActor.assumeIsolated { self?.mapTemplate.present(navigationAlert: alert, animated: true) }
            }
        } else {
            mapTemplate.present(navigationAlert: alert, animated: true)
        }
    }

    private func action(_ b: CarAlertSpec.Button) -> CPAlertAction {
        switch b {
        case .ok: return CPAlertAction(title: String(localized: "OK"), style: .cancel) { _ in }
        case .done: return CPAlertAction(title: String(localized: "Done"), style: .default) { [weak self] _ in self?.model.stopNavigation() }
        case .yes, .gone:
            let stillThere = b == .yes
            return CPAlertAction(title: stillThere ? String(localized: "Yes") : String(localized: "Gone"), style: stillThere ? .default : .cancel) {
                [weak self] _ in
                guard let self, let nav = self.model.navigation else { return }
                Task { if await self.model.ensureRulesAccepted() { nav.vote(stillThere: stillThere) } }
            }
        }
    }

    // MARK: report grid (≤ 8, one tap)

    static let reportTypes: [ReportType] = [.police, .accident, .traffic, .hazard, .closure, .blockedLane]

    func showReportGrid() {
        let buttons = Self.reportTypes.map { type in
            CPGridButton(titleVariants: [String(localized: type.title)], image: GimanoMapView.Coordinator.alertImage(type)) { [weak self] _ in
                self?.report(type)
            }
        }
        push(CPGridTemplate(title: String(localized: "Report"), gridButtons: buttons))
    }

    private func report(_ type: ReportType) {
        interface.popToRootTemplate(animated: true, completion: nil)
        // Restricted areas: nothing is sent; the car says why for 3 s.
        if model.restricted.proximity(of: model.position) == .blocked {
            present(.restricted)
            return
        }
        model.submitReport(type: type, subtype: nil, comment: nil)
        present(.reportSent)
    }

    // MARK: camera

    private func recenter() {
        carState.setCamera(model.navigation != nil ? .navigation : .trackNorth(zoom: 15))
    }

    // MARK: sync with the phone (twice a second)

    func sync() {
        if showingAgreementInfo, !model.needsSafetyAgreement {
            showingAgreementInfo = false
            interface.setRootTemplate(mapTemplate, animated: true, completion: nil)
        }
        carState.mirror(from: model.map, restrictedRevision: &restrictedRevision)
        let carDark = mapVC.traitCollection.userInterfaceStyle == .dark
        let style = CarMapLayout.styleURL(carIsDark: carDark, light: model.config.styleURL, dark: model.config.darkStyleURL)
        if carState.styleURL != style { carState.styleURL = style }

        // Trip previews while the phone's route preview has routes and nothing is driving.
        if model.navigation == nil, model.screen == .routePreview, let planner = model.planner, !planner.routes.isEmpty {
            let key = planner.routes.map(\.id).joined(separator: ",")
            if key != previewRoutesKey {
                previewRoutesKey = key
                showPreviews(planner)
                let corners = planner.routes.flatMap { r in
                    BBox(array: r.bbox).map { [LatLng(lat: $0.minLat, lng: $0.minLng), LatLng(lat: $0.maxLat, lng: $0.maxLng)] } ?? []
                }
                if let b = BBox.around(corners) {
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

        let nav = model.navigation
        for action in drive.update(nav.map(CarNavSnapshot.init)) { perform(action, nav: nav) }
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
        if reminder { present(.reminder) }
    }

    /// "End" in the car stops the drive everywhere (the phone too); the next sync cancels the car's session.
    func mapTemplateDidCancelNavigation(_ mapTemplate: CPMapTemplate) {
        model.stopNavigation()
        sync()
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
            // Only the typed text and the position go to the server, as on the phone; no history is sent.
            let results = (try? await repo.search(query: q, near: near, category: nil, limit: 12)) ?? []
            guard !Task.isCancelled, let self else { return }
            self.searchResults = Dictionary(results.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            completionHandler(results.prefix(Int(CPListTemplate.maximumItemCount)).map { p in
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
    /// `-GimanoCarScene places|search|report|agreement`: open that car screen on connect (head-unit screenshots).
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
