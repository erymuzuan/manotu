import Foundation
import Observation
import SwiftUI

enum BackendStatus: Equatable {
    case unknown, online, demoFallback, demoForced
}

enum Screen: Equatable {
    case home
    case search(SearchPurpose)
    case place(PlaceSummary)
    case routePreview
    case navigating
}

enum SearchPurpose: Equatable {
    case destination
    case addStop
    /// "Search for a start" from the route preview.
    case setOrigin
    case setHome
    case setWork
}

/// Route options + alternatives for the preview screen.
@MainActor
@Observable
final class RoutePlanner {
    var destination: Destination
    var routes: [Route] = []
    var selectedId: String?
    var vehicle: Vehicle
    var avoid = AvoidOptions()
    var departAt: Date?
    var isLoading = false
    var error: String?
    /// Intermediate stops, in order (≤ 5).
    var stops: [TripStop] = []
    /// Where the route starts (only a fresh GPS fix is "Your location").
    var start: RouteStart = .locating
    /// "Drive through anyway": issues ignored for this trip only.
    var ignoredIssues: Set<String> = []
    /// The start is under 50 m from the destination: "You're already here", no route.
    var alreadyHere = false
    /// Opened with one tap (Home, Work, a favourite, a recent, a planned drive), not from a search: the only
    /// trips the optional auto-start countdown may run for.
    var quickPick = false
    /// To an imported event's stop (Acara): not saved to recents, and "Leave later" doesn't copy the stop's name.
    var isEventTrip = false

    init(destination: Destination, vehicle: Vehicle) {
        self.destination = destination
        self.vehicle = vehicle
    }

    var selected: Route? { routes.first { $0.id == selectedId } ?? routes.first }

    /// Seconds from departure to each stop, then the destination.
    var schedule: StopSchedule? { selected.map { StopSchedule.make(route: $0, stops: stops.map(\.location)) } }
}

/// What the feedback sheet was opened for.
struct FeedbackDraft: Identifiable {
    let id = UUID()
    var screen: FeedbackScreen
    var screenshot: Data?
    var device: DeviceInfo
    var location: CoarseLocation?
    var routeId: String?
    var placeId: String?
}

enum MenuSheet: String, Identifiable {
    case favorites, myFeedback, backup, contributions
    var id: String { rawValue }
}

@MainActor
@Observable
final class AppModel {
    let config: AppConfig
    let location = LocationService()
    let live = LiveMapStore()
    let map: MapState
    @ObservationIgnored let voice = VoiceGuide()
    @ObservationIgnored private let simulator = DriveSimulator()

    private(set) var repo: any GimanoRepository
    private(set) var backendStatus: BackendStatus = .unknown
    private(set) var user: User?
    /// Contributors the user blocked (on this phone only; settings table, backed up).
    private(set) var blockedAuthors: [BlockedAuthor] = []
    var blockedRefs: Set<String> { Set(blockedAuthors.map(\.ref)) }
    private(set) var savedPlaces: [SavedPlace] = []
    private(set) var recents: [Recent] = []
    /// "Just for me" places (on device only).
    private(set) var privatePlaces: [PrivatePlace] = []
    /// Planned drives (on device only) and their next computed "Leave by".
    private(set) var plannedDrives: [PlannedDrive] = []
    private(set) var nextLeaveBy: [String: Date] = [:]
    /// Planned-drive editor (new or existing).
    var editingDrive: PlannedDrive?
    /// Inbox: news about the user's public contributions (server) + local read mark.
    private(set) var inboxItems: [InboxItem] = []
    private(set) var inboxAvailable = true
    var inboxUnread: Int {
        InboxReadState.unreadCount(inboxItems, localReadUpTo: LocalStore.date(try? store.setting("inbox.readUpTo")))
    }
    /// Active "Share my drive" (end-to-end encrypted live ETA).
    private(set) var driveShare: DriveShareSession?
    var showShareSheet = false
    private(set) var startingShare = false
    /// Add-a-place flow (nil when closed); the coordinate is where the pin starts.
    var addPlaceStart: LatLng?
    /// Long-press menu: "Navigate here" / "Add a place here".
    var longPressPoint: LatLng?
    /// "Choose on map" in progress, and the actions for a chosen point.
    var pinPick: PinPickRequest?
    /// Backup & restore opened from the first-run "Restore from Gimano or a backup".
    var restoreOnFirstRun = false
    var pinActions: PickedPoint?
    /// The place whose entrance is being moved ("Entrance or parking wrong").
    @ObservationIgnored var entrancePlace: (String, LatLng)?

    var screen: Screen = .home
    /// Home panel detent. Not persisted: every launch, and the end of every drive, starts at Peek.
    var homeDetent: HomeDetent = .peek
    var planner: RoutePlanner?
    private(set) var navigation: NavigationSession?
    var showMenu = false
    var showReport = false
    var showDebug = false
    var showOnboarding = false
    var selectedAlert: Report?
    var toast: String?
    /// Sound button / selector; remembered across drives (local settings table).
    var soundMode: SoundMode = .on {
        didSet {
            voice.mode = soundMode
            try? store.setSetting("sound_mode", soundMode.storageValue)
        }
    }
    /// The mode before a long-press mute, for the next long-press.
    var lastSoundMode: SoundMode = .on { didSet { try? store.setSetting("sound_mode_last", lastSoundMode.storageValue) } }
    /// App voice volume 0…1 (sound selector slider), on the device only.
    var voiceVolume: Double = 0.8 {
        didSet {
            voice.volume = Float(voiceVolume)
            try? store.setSetting("voice_volume", String(format: "%.2f", voiceVolume))
        }
    }
    var vehicle: Vehicle = .car
    /// Settings → "Start navigation automatically" (local settings table; off by default, like Android).
    var autoStartNav = false { didSet { try? store.setSetting("auto_start_nav", autoStartNav ? "1" : nil) } }
    /// Settings → Theme (persisted in the local settings table; default Light).
    var theme: ThemeMode = .light {
        didSet {
            try? store.setSetting("theme", theme.rawValue)
            themeClock = .now
        }
    }
    /// Re-evaluated every minute for Auto day/night.
    var themeClock = Date()
    /// The scheme actually on screen (reported by the root view), drives the map style.
    private(set) var effectiveScheme: ColorScheme = .light
    /// Category pre-selected when opening search from a home shortcut tile.
    var searchCategory: PlaceCategory?
    /// Place being saved from the place card ("Save" sheet).
    var savingPlace: PlaceSummary?
    var feedbackDraft: FeedbackDraft?
    /// Navigation feedback while moving: ask "Are you a passenger?" first.
    var askPassengerForFeedback = false
    var menuSheet: MenuSheet?
    /// A `.gimano` file opened from another app.
    var incomingBackup: URL?
    /// Imported and hosted events (Acara), kept on this phone only and never backed up. Its "Laluan saya" live in
    /// `store` (backed up).
    let events: EventCenter
    /// On-device personal data (favourites, recents, private places, settings).
    let store: LocalStore
    /// Restricted areas + sensitive words (public data from the server, cached in a file; docs/safety.md part 4).
    let restricted = RestrictedAreaStore()
    /// Safety agreement + drive reminder (on this phone only; docs/safety.md parts 1–3).
    private(set) var safety = SafetySettings()
    /// The full-screen user agreement and why it is open.
    var safetyAgreement: SafetyAgreementPurpose?
    /// "Agree first to start driving" (Mula before agreeing).
    var showNotAgreedSheet = false
    /// The reminder card over the route preview; guidance starts after its button.
    var safetyCard: SafetyCardRequest?
    /// "Drive safely. Obey the traffic laws." for 5 s when navigation starts while moving.
    private(set) var showSafetyBanner = false
    /// Sheet D: tapped inside a restricted area on the map.
    var showRestrictedAreaInfo = false
    @ObservationIgnored private var safetyBannerTask: Task<Void, Never>?
    @ObservationIgnored private var launchWaitsForAgreement = false
    /// DEBUG/UI tests (`-GimanoSkipOnboarding` / `-GimanoSkipSafety`): agreement and reminder are skipped for this
    /// launch only, without writing anything to the user's settings.
    @ObservationIgnored private var skipSafetyForTests = false
    let backup: BackupManager
    let feedbackOutbox: FeedbackOutbox
    /// Server-side "My feedback" (merged with the local outbox in the UI).
    private(set) var serverFeedback: [FeedbackSummary] = []
    /// DEBUG/UI tests: fixed position instead of GPS (`-GimanoFakeLocation lat,lng`).
    @ObservationIgnored private var fixedLocation: LatLng?
    @ObservationIgnored private var outboxTimer: Task<Void, Never>?

    /// Latest position (simulated during demo drives) and motion.
    private(set) var position: LatLng = DemoRepository.defaultLocation
    private(set) var hasRealFix = false
    private(set) var speedKmh: Double = 0
    private(set) var heading: Double = 0

    @ObservationIgnored private var toastTask: Task<Void, Never>?

    init(config: AppConfig = AppConfig(), store: LocalStore = .shared) {
        self.config = config
        self.map = MapState(styleURL: config.styleURL)
        self.repo = DemoRepository()
        self.store = store
        // Schema 3: "Laluan saya" saved by earlier builds in the events database move here once (never into the
        // in-memory fallback store, which would lose them).
        if !store.isInMemory { try? PersonalRouteMove.run(from: .shared, to: store) }
        self.events = EventCenter(store: .shared, personalStore: store)
        self.backup = BackupManager(store: store)
        #if DEBUG
        Self.applyTestLaunchArguments(store: store)
        #endif
        self.feedbackOutbox = FeedbackOutbox(storage: LocalStoreOutboxStorage(store: store))
        #if DEBUG
        // `-GimanoResetCommunityRules YES` (UI tests): ask the community rules again.
        if UserDefaults.standard.bool(forKey: "GimanoResetCommunityRules") {
            try? store.setSetting(CommunityRules.versionKey, nil)
            try? store.setSetting(CommunityRules.acceptedAtKey, nil)
        }
        if let raw = UserDefaults.standard.string(forKey: "GimanoFakeLocation") {
            let parts = raw.split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
            if parts.count == 2 { fixedLocation = LatLng(lat: parts[0], lng: parts[1]); position = fixedLocation! }
        }
        #endif
        safety = SafetySettings(store: store)
        #if DEBUG
        let d = UserDefaults.standard
        skipSafetyForTests = (d.bool(forKey: "GimanoSkipSafety") || d.bool(forKey: "GimanoSkipOnboarding")) && !d.bool(forKey: "GimanoSafetyTest")
        // `-GimanoResetSafety YES`: "never agreed" + reminder on, touching nothing else (device tests keep the user's data).
        if d.bool(forKey: "GimanoResetSafety") { safety = SafetySettings(); safety.save(to: store) }
        // `-GimanoAgreeSafety YES`: agreed now, reminder on (device screenshots of the card without tapping).
        if d.bool(forKey: "GimanoAgreeSafety") {
            safety = SafetySettings(); safety.agreedVersion = SafetyPolicy.agreementVersion; safety.agreedAt = .now; safety.save(to: store)
        }
        // `-GimanoRestrictedFixture lat,lng`: a 400 m test restricted area there (memory only, DEBUG builds only).
        if let raw = d.string(forKey: "GimanoRestrictedFixture") {
            let parts = raw.split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
            if parts.count == 2 { restricted.installFixture(around: LatLng(lat: parts[0], lng: parts[1])) }
        }
        #endif
        if let raw = UserDefaults.standard.string(forKey: "travelMode"), let v = Vehicle(rawValue: raw) { vehicle = v }
        if let raw = try? store.setting("theme"), let t = ThemeMode(rawValue: raw) { theme = t }
        autoStartNav = (try? store.setting("auto_start_nav")) == "1"
        blockedAuthors = store.blockedAuthors()
        if let m = SoundMode(storageValue: try? store.setting("sound_mode")) { soundMode = m }
        if let m = SoundMode(storageValue: try? store.setting("sound_mode_last")) { lastSoundMode = m }
        if let raw = try? store.setting("voice_volume"), let v = Double(raw) { voiceVolume = min(1, max(0, v)) } else { voice.volume = Float(voiceVolume) }
        #if DEBUG
        if let raw = UserDefaults.standard.string(forKey: "GimanoTheme"), let t = ThemeMode(rawValue: raw) { theme = t }
        #endif
        wireMap()
        location.onFix = { [weak self] fix in self?.handleRealFix(fix) }
        rebuildRepository()
        moveToPinned()
        startOutboxTimer()
    }

    #if DEBUG
    /// `-GimanoFreshDevice YES`: new anonymous device + empty local state (UI tests start clean).
    private static func applyTestLaunchArguments(store: LocalStore) {
        let d = UserDefaults.standard
        if d.bool(forKey: "GimanoFreshDevice") {
            Keychain.set(nil, for: "device.id")
            for key in ["travelMode", "location.askedAlways"] { d.removeObject(forKey: key) }
            for base in [AppConfig().apiBaseURL] { TokenStore.save(nil, for: base) }
            try? store.wipePersonalData()
            try? store.replaceOutbox(kind: "feedback", items: [])
            try? store.setSetting(LegacyDataMigration.doneKey, nil)
            try? store.setSetting("theme", nil)
            try? store.clearIdentitySettings()
        }
        if d.bool(forKey: "GimanoSkipOnboarding") { d.set(true, forKey: "onboarding.done") }
        if d.bool(forKey: "GimanoFreshDevice") {
            UserDefaults.standard.removeObject(forKey: "vetting.lastPromptAt")
            UserDefaults.standard.removeObject(forKey: "recovery.roundTrip")
            UserDefaults.standard.removeObject(forKey: "crash.lastSent")
            UserDefaults.standard.removeObject(forKey: "vetting.voted")
        }
        // `-GimanoFakeCrash YES`: a crash record as MetricKit would deliver it (UI tests of the crash prompt).
        if d.bool(forKey: "GimanoFakeCrash") {
            UserDefaults.standard.removeObject(forKey: "crash.preference")
            CrashReporter.shared.save(CrashReport(
                occurredAt: .now.addingTimeInterval(-120), kind: "crash", exception: "EXC_BAD_ACCESS · SIG 11",
                message: "Test crash near 3.152613, 101.703718 for ali@example.com",
                stack: #"{"callStackTree":"0 Gimano 0x104a3c000 NavigationSession.applyFix + 128\n1 /var/mobile/Containers/Data/Application/ABC/Library/x.sqlite"}"#,
                screen: "navigation", uptimeS: 312))
        }
    }
    #endif

    // MARK: bootstrap

    func bootstrap() async {
        // The safety agreement comes after the splash and before the location permission prompt (docs/safety.md §1).
        var launchAgreement = needsSafetyAgreement
        #if DEBUG
        // `-GimanoNoLaunchAgreement YES`: stay "not agreed" without the launch screen (device shots of the Go-now sheet).
        if UserDefaults.standard.bool(forKey: "GimanoNoLaunchAgreement") { launchAgreement = false }
        #endif
        if launchAgreement {
            safetyAgreement = .launch
            launchWaitsForAgreement = location.needsPermission
        }
        if !launchWaitsForAgreement { continueLaunch() }
        syncRestrictedLayer()
        Task { await refreshRestrictedAreas() }
        map.puck = position
        await refreshUserData()
        #if DEBUG
        await runDemoScene()
        #endif
    }

    #if DEBUG
    /// Screenshot / demo hook: `-GimanoDemoScene search|place|route|nav|report|menu`.
    private func runDemoScene() async {
        // `-GimanoDriveTo "Name|lat,lng|placeId"`: plan a trip there from the (fake) location and start it (route replays).
        if let raw = UserDefaults.standard.string(forKey: "GimanoDriveTo") {
            let parts = raw.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
            let ll = parts.count > 1 ? parts[1].split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) } : []
            guard ll.count == 2 else { return }
            let placeId = parts.count > 2 && !parts[2].isEmpty ? parts[2] : nil
            try? await Task.sleep(for: .seconds(1.5))
            planRoute(to: Destination(name: parts[0], address: "", location: LatLng(lat: ll[0], lng: ll[1]), placeId: placeId), remember: false)
            for _ in 0..<60 where planner?.selected == nil { try? await Task.sleep(for: .milliseconds(500)) }
            try? await Task.sleep(for: .seconds(1))
            startNavigation()
            return
        }
        guard let scene = UserDefaults.standard.string(forKey: "GimanoDemoScene") else { return }
        let target = DemoData.places.first { $0.id == "demo:midvalley" }!
        let dest = Destination(name: target.name, address: target.address, location: target.location, placeId: target.id, category: target.category)
        try? await Task.sleep(for: .seconds(1.5))
        switch scene {
        case "search":
            screen = .search(.destination)
        case "place":
            openPlace(target)
        case "route":
            planRoute(to: dest)
        case "nav":
            planRoute(to: dest)
            try? await Task.sleep(for: .seconds(1.5))
            startNavigation()
        case "overview":
            map.setCamera(.center(LatLng(lat: 3.13, lng: 101.68), zoom: 11.6))
        case "route-far":
            // Not a captured destination → nearest captured route, labelled "Demo route".
            if let klia = DemoData.places.first(where: { $0.id == "demo:klia" }) {
                planRoute(to: Destination(name: klia.name, address: klia.address, location: klia.location, placeId: klia.id, category: klia.category))
            }
        case "report":
            showReport = true
        case "menu":
            showMenu = true
        case "addplace":
            addPlaceStart = position
        case "restrictedinfo":
            showRestrictedAreaInfo = true
        default:
            break
        }
    }
    #endif

    /// Location onboarding / start, once the agreement (if any) is answered.
    private func continueLaunch() {
        if location.needsPermission && !UserDefaults.standard.bool(forKey: "onboarding.done") {
            showOnboarding = true
        } else {
            location.start()
        }
    }

    // MARK: safety (docs/safety.md parts 1–3)

    var needsSafetyAgreement: Bool { !skipSafetyForTests && !safety.hasAgreed }
    /// The reminder as it applies to this launch (UI tests skip it).
    var reminderEnabled: Bool { safety.reminderEnabled && !skipSafetyForTests }

    func answerSafetyAgreement(_ agreed: Bool) {
        let purpose = safetyAgreement
        safetyAgreement = nil
        if agreed {
            safety.agreedVersion = SafetyPolicy.agreementVersion
            safety.agreedAt = .now
            safety.save(to: store)
        }
        Task {
            // Let the full-screen cover finish closing before the next one (onboarding) or navigation.
            try? await Task.sleep(for: .milliseconds(450))
            switch purpose {
            case .launch:
                if launchWaitsForAgreement { launchWaitsForAgreement = false; continueLaunch() }
            case .startDriving:
                if agreed { startNavigation() }
            case .reread, nil:
                break
            }
        }
    }

    func setReminderEnabled(_ on: Bool) {
        safety.reminderEnabled = on
        safety.reminderDisabledAt = on ? nil : .now
        safety.save(to: store)
    }

    /// The card's button: "Got it, start driving" (optionally "Don't show again").
    func confirmSafetyCard(dontShowAgain: Bool) {
        safetyCard = nil
        if dontShowAgain {
            setReminderEnabled(false)
            showToast(String(localized: "Turned off. Turn it back on in Settings › Safety."), seconds: 4)
        }
        guard planner != nil, navigation == nil, screen == .routePreview else { return }
        beginNavigation()
    }

    private func startWithReminder() {
        guard let planner, let route = planner.selected else { return }
        let speed: Double? = hasRealFix || isSimulatingDrive || pinnedLocation != nil ? speedKmh : nil
        switch SafetyPolicy.reminder(enabled: reminderEnabled, speedKmh: speed) {
        case .none:
            beginNavigation()
        case .banner:
            beginNavigation()
            flashSafetyBanner()
        case .card:
            safetyCard = SafetyCardRequest(destination: planner.destination.name, durationS: route.effectiveDurationS)
        }
    }

    private func flashSafetyBanner() {
        showSafetyBanner = true
        safetyBannerTask?.cancel()
        safetyBannerTask = Task {
            try? await Task.sleep(for: .seconds(SafetyPolicy.bannerSeconds))
            if !Task.isCancelled { showSafetyBanner = false }
        }
    }

    #if DEBUG
    /// Developer settings: back to "never agreed" + reminder on (the next launch shows the agreement again).
    func debugResetSafety() {
        safety = SafetySettings()
        safety.save(to: store)
        skipSafetyForTests = false
        showToast("Safety settings reset")
    }
    #endif

    // MARK: restricted areas (docs/safety.md part 4)

    func refreshRestrictedAreas(force: Bool = false) async {
        guard config.dataMode != .demo else { return }
        await restricted.refreshIfNeeded(base: config.apiBaseURL, force: force)
        syncRestrictedLayer()
    }

    func syncRestrictedLayer() {
        map.restrictedAreas = restricted.rings
        map.isInsideRestrictedArea = { [restricted] p in restricted.isInsideArea(p) }
    }

    /// Road reports and complaints are not sent from inside a restricted area (≤ blockM).
    private func refuseReportInRestrictedArea(_ p: LatLng) -> Bool {
        guard restricted.proximity(of: p) == .blocked else { return false }
        showToast(String(localized: "Reports aren't accepted in restricted areas."))
        return true
    }

    func finishOnboarding(allowLocation: Bool) {
        UserDefaults.standard.set(true, forKey: "onboarding.done")
        showOnboarding = false
        if allowLocation { location.requestPermission() }
    }

    func rebuildRepository() {
        let base = config.apiBaseURL
        let demo = DemoRepository()
        let liveRepo = LiveRepository(baseURL: base)
        switch config.dataMode {
        case .demo:
            repo = demo
            backendStatus = .demoForced
        case .live:
            repo = liveRepo
            backendStatus = .unknown
        case .auto:
            repo = FallbackRepository(live: liveRepo, demo: demo) { [weak self] offline in
                self?.backendStatus = offline ? .demoFallback : .online
            }
            backendStatus = .unknown
        }
        backup.demoMode = config.isDemoMode
        map.styleURL = effectiveScheme == .dark ? config.darkStyleURL : config.styleURL
        let hubURL: URL? = config.dataMode == .demo ? nil : config.liveHubURL
        live.configure(repo: repo, hubURL: hubURL, tokenProvider: { TokenStore.load(for: base) })
        Task { await refreshUserData() }
        Task { await refreshRestrictedAreas() }
    }

    func refreshUserData() async {
        CrashReporter.shared.onPending = { [weak self] in Task { await self?.checkCrashReports() } }
        if vettingTask == nil { startVettingTicker() }
        #if DEBUG
        // `-GimanoFakeDeviation YES`: the after-trip "Why didn't you follow the route?" prompt (simulator screenshots).
        if UserDefaults.standard.bool(forKey: "GimanoFakeDeviation") {
            UserDefaults.standard.removeObject(forKey: "deviation.lastAsked")
            UserDefaults.standard.removeObject(forKey: "deviation.optedOut")
            deviationPrompt = DeviationEvent(lat: position.lat, lng: position.lng, heading: 90, roadName: "Jalan SS 2/24", at: .now, vehicle: .car)
        }
        // `-GimanoVetNow YES` (demo): a pending place by someone else 250 m away, and the prompt right away.
        if UserDefaults.standard.bool(forKey: "GimanoVetNow") {
            if let demo = repo as? DemoRepository {
                let p = LatLng(lat: position.lat + 0.0018, lng: position.lng + 0.0012)
                _ = await demo.seedPendingPlace(name: "Gerai Nasi Kerabu Mek Na", at: p)
            }
            // Live: ask about a real pending place nearby (another pseudonym's) right away.
            await considerVettingPrompt(force: true)
        }
        #endif
        let repo = self.repo
        if config.dataMode != .demo, TokenStore.load(for: config.apiBaseURL) == nil {
            _ = try? await repo.signIn()
        }
        if config.dataMode != .demo { await repo.ensureIdentity() }
        #if DEBUG
        await debugRecoveryRoundTrip()
        #endif
        if let u = try? await repo.me() {
            user = u
            if let v = u.vehicle, UserDefaults.standard.string(forKey: "travelMode") == nil { vehicle = v }
            if backendStatus == .unknown, config.dataMode == .live { backendStatus = .online }
        }
        await migrateLegacyDataIfNeeded()
        reloadLocal()
        await flushFeedback()
        await rescheduleAllPlannedDrives()
        await refreshInbox()
        await checkCrashReports()
    }

    func refreshInbox() async {
        do {
            inboxItems = try await repo.inbox(cursor: nil).items
            inboxAvailable = true
        } catch {
            inboxAvailable = false
        }
    }

    /// Opening the inbox marks everything shown as read (locally, and on the server when available).
    func markInboxRead() {
        guard let newest = inboxItems.map(\.createdAt).max() else { return }
        try? store.setSetting("inbox.readUpTo", LocalStore.timestamp(newest))
        inboxItems = inboxItems.map { var i = $0; i.read = true; return i }
        Task { try? await repo.markInboxRead(upTo: newest) }
    }

    // MARK: own contributions

    /// Ids of community places added from this device (owners can't verify their own place).
    var ownPlaceIds: Set<String> {
        let raw = (try? store.setting("ownPlaces")) ?? nil
        return Set((raw.flatMap { try? JSONDecoder().decode([String].self, from: Data($0.utf8)) }) ?? [])
    }

    func rememberOwnPlace(_ id: String) {
        var ids = ownPlaceIds
        ids.insert(id)
        if let d = try? JSONEncoder().encode(Array(ids)) { try? store.setSetting("ownPlaces", String(decoding: d, as: UTF8.self)) }
    }

    // MARK: share my drive

    func startSharing() {
        guard let nav = navigation, !startingShare else { return }
        if driveShare != nil { showShareSheet = true; return }
        startingShare = true
        Task {
            defer { startingShare = false }
            do {
                let s = try await DriveShareSession.start(destinationName: nav.destination.name, remainingS: nav.remainingS, repo: repo)
                // Navigation stopped (or arrived) while the share was being created: never leave it live on the server.
                guard navigation === nav, !nav.arrived else {
                    await s.end(fix: nil, status: .ended)
                    return
                }
                driveShare = s
                showShareSheet = true
                if let fix = nav.fix { s.update(fix: fix, remainingS: nav.remainingS, remainingM: nav.remainingM) }
            } catch let e as APIError where e.isServerSideGap {
                showToast(String(localized: "Sharing isn't available on the server yet"))
            } catch {
                showToast(error.localizedDescription)
            }
        }
    }

    func stopSharing() {
        guard let s = driveShare else { return }
        driveShare = nil
        showShareSheet = false
        let fix = navigation?.fix
        Task { await s.end(fix: fix, status: .ended) }
    }

    // MARK: planned drives

    /// A new planned drive for the trip in route preview (or an empty one from the menu).
    func newPlannedDrive(from planner: RoutePlanner?) -> PlannedDrive {
        let dest = planner?.destination
        // An event stop's name stays with the event (planned drives are backed up).
        let eventTrip = planner?.isEventTrip == true
        let destName = eventTrip ? nil : dest?.name
        var arrival = Calendar.current.date(bySettingHour: 8, minute: 30, second: 0, of: .now.addingTimeInterval(24 * 3600)) ?? .now
        if let d = planner?.departAt { arrival = d.addingTimeInterval(planner?.selected?.effectiveDurationS ?? 1800) }
        let origin: PlannedDrive.Place? = if case .chosen(let n, let p, let id) = planner?.start {
            PlannedDrive.Place(lat: p.lat, lng: p.lng, name: n, address: nil, placeId: id)
        } else { nil }
        return PlannedDrive(id: UUID().uuidString.lowercased(), name: destName, origin: origin,
                            destination: PlannedDrive.Place(lat: dest?.location.lat ?? home?.lat ?? position.lat, lng: dest?.location.lng ?? home?.lng ?? position.lng,
                                                            name: dest == nil ? home?.name : destName,
                                                            address: eventTrip ? nil : (dest?.address ?? home?.address), placeId: dest?.placeId),
                            waypoints: planner?.stops ?? [], vehicle: planner?.vehicle ?? vehicle, departAt: nil,
                            schedule: PlannedDrive.Schedule(arriveAt: arrival), createdAt: .now)
    }

    func savePlannedDrive(_ d: PlannedDrive) {
        Task {
            _ = await PlannedDriveNotifier.requestPermission()
            var drive = d
            // Saving is the user asking for this drive's time: the fresh fix (if any) may be the origin.
            let leaveBy = await PlannedDriveNotifier.reschedule(drive, trigger: .userAsked(fix: freshFix), repo: repo)
            if drive.schedule.arriveAt != nil { drive.departAt = leaveBy }
            try? store.savePlannedDrive(drive)
            nextLeaveBy[drive.id] = leaveBy
            reloadLocal()
            showToast(leaveBy.map { String(localized: "Leave by \($0.formatted(date: .omitted, time: .shortened))") } ?? String(localized: "Planned"))
        }
    }

    func deletePlannedDrive(_ d: PlannedDrive) {
        try? store.deletePlannedDrive(id: d.id)
        nextLeaveBy[d.id] = nil
        reloadLocal()
        Task { await PlannedDriveNotifier.cancel(d.id) }
    }

    /// Launch and the list: automatic, so drives without a fixed start get no traffic-based time (no position is sent).
    func rescheduleAllPlannedDrives() async {
        for d in plannedDrives {
            let lb = await PlannedDriveNotifier.reschedule(d, trigger: .automatic, repo: repo)
            if lb != nil || d.origin != nil { nextLeaveBy[d.id] = lb }
        }
    }

    /// "Open for the best time" on a drive without a fixed start: computed from the fresh fix, only now.
    func bestTime(for d: PlannedDrive) async {
        guard let fix = freshFix else {
            showToast(String(localized: "Your location unknown"))
            return
        }
        let lb = await PlannedDriveNotifier.reschedule(d, trigger: .userAsked(fix: fix), repo: repo)
        nextLeaveBy[d.id] = lb
        showToast(lb.map { String(localized: "Leave by \($0.formatted(date: .omitted, time: .shortened))") } ?? String(localized: "Couldn't send. Try again."))
    }

    /// A GPS fix under 2 minutes old (route-start rules), else nil; never the default map position.
    var freshFix: LatLng? {
        if case .fresh(let p) = currentGPS() { return p }
        return nil
    }

    /// Notification tap → route preview for that drive.
    func openPlannedDrive(id: String) {
        guard let d = (try? store.plannedDrives())?.first(where: { $0.id == id }) else { return }
        vehicle = d.vehicle
        showMenu = false
        menuSheet = nil
        planRoute(to: Destination(name: d.destination.name ?? d.title, address: d.destination.address ?? "",
                                  location: d.destination.location, placeId: d.destination.placeId), stops: d.waypoints, quickPick: true)
    }

    /// Reloads favourites and recents from the on-device store.
    /// Forced scheme for the whole app (nil = follow the phone).
    var preferredScheme: ColorScheme? { theme.colorScheme(now: themeClock, location: position) }

    /// Called by the root view whenever the visible scheme changes: switches the basemap.
    func schemeChanged(_ scheme: ColorScheme) {
        effectiveScheme = scheme
        let url = scheme == .dark ? config.darkStyleURL : config.styleURL
        if map.styleURL != url { map.styleURL = url }
    }

    func reloadLocal() {
        savedPlaces = (try? store.savedPlaces()) ?? []
        recents = (try? store.recents()) ?? []
        privatePlaces = (try? store.privatePlaces()) ?? []
        plannedDrives = (try? store.plannedDrives()) ?? []
        map.privatePins = privatePlaces.map { $0.location }
        events.reloadPersonalRoutes()
        safety = SafetySettings(store: store)
    }

    /// Local "Just for me" places matching a query.
    func privateMatches(_ query: String) -> [PrivatePlace] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return [] }
        return privatePlaces.filter { $0.name.lowercased().contains(q) || ($0.address ?? "").lowercased().contains(q) }
    }

    /// First launch after the on-device switch: download any server-side copy once, import it, then delete it
    /// on the server. A 404/410 (not deployed yet / already gone) just marks the migration done.
    func migrateLegacyDataIfNeeded() async {
        guard config.dataMode != .demo, (try? store.setting(LegacyDataMigration.doneKey)) == nil else { return }
        do {
            let export = try await repo.legacyExport()
            let n = try LegacyDataMigration.importExport(export, into: store)
            try? await repo.deleteLegacyData()
            try? store.setSetting(LegacyDataMigration.doneKey, LocalStore.timestamp())
            if n > 0 { showToast(String(localized: "Moved \(n) saved places to this phone")) }
        } catch let e as APIError {
            if case .http(let status, _) = e, status == 404 || status == 410 || status == 405 {
                try? store.setSetting(LegacyDataMigration.doneKey, LocalStore.timestamp())
            }
            // Offline: try again next launch.
        } catch {}
    }

    var home: SavedPlace? { savedPlaces.first { $0.kind == .home } }
    var work: SavedPlace? { savedPlaces.first { $0.kind == .work } }
    var favorites: [SavedPlace] { savedPlaces.filter { $0.kind == .favorite } }

    var isDemo: Bool { backendStatus == .demoFallback || backendStatus == .demoForced }

    /// Turns the public Demo mode on or off (Settings, the Demo badge). Demo puts you at the sample start in
    /// Kuala Lumpur wherever the phone is, so search, routes and simulated drives work from anywhere.
    func setDemoMode(_ on: Bool) {
        guard on != config.isDemoMode else { return }
        config.setDemoMode(on)
        navigation.map { _ in stopNavigation() }
        planner = nil
        go(.home)
        rebuildRepository()
        if on || fixedLocation != nil {
            moveToPinned()
        } else if let fix = location.lastFix {
            applyFix(fix)
        }
        recenter()
        showToast(String(localized: on ? "Demo mode on: sample data, nothing is sent" : "Demo mode off"))
    }

    /// Where the app pretends to be: the demo start in Demo mode (wherever the phone really is), else a DEBUG/UI-test
    /// fixed location.
    private var pinnedLocation: LatLng? {
        config.isDemoMode ? DemoRepository.defaultLocation : fixedLocation
    }

    private func moveToPinned() {
        guard let p = pinnedLocation else { return }
        position = p
        map.puck = p
        map.puckAccuracyM = nil
    }

    // MARK: location

    private func handleRealFix(_ fix: LocationFix) {
        guard pinnedLocation == nil else { return }
        hasRealFix = true
        guard !simulator.isRunning else { return }
        applyFix(fix)
    }

    private func applyFix(_ fix: LocationFix) {
        position = fix.coordinate
        speedKmh = fix.speedKmh
        if let c = fix.course { heading = c }
        map.puck = fix.coordinate
        map.puckHeading = heading
        map.puckAccuracyM = fix.accuracyM
        retryStartIfWaiting()
        if safetyCard != nil, SafetyPolicy.shouldCloseCard(speedKmh: fix.speedKmh) {
            safetyCard = nil
            if planner != nil, navigation == nil, screen == .routePreview { beginNavigation(); flashSafetyBanner() }
        }
        checkStillClosed(at: fix.coordinate)
        gpsQuality.update(accuracyM: fix.accuracyM, at: fix.timestamp)
        // Poor fixes (> 100 m, e.g. approximate location) never advance instructions or trigger reroutes.
        if GpsQuality.usableForGuidance(fix) { navigation?.handle(fix) }
        if let share = driveShare, let nav = navigation {
            if nav.arrived {
                driveShare = nil
                Task { await share.end(fix: fix, status: .arrived) }
            } else {
                share.update(fix: fix, remainingS: nav.remainingS, remainingM: nav.remainingM)
            }
        }
        // Only a fix that was just snapped (usable for guidance) may move the puck to the road; a poor fix shows raw.
        if GpsQuality.usableForGuidance(fix), let nav = navigation, let snapped = nav.progress?.snap, snapped.distanceFromRouteM <= 30 {
            // Keep the puck glued to the road while on route (≤ 30 m); otherwise show the raw fix (off-route logic runs on it).
            map.puck = snapped.point
        }
    }

    func recenter() {
        // While a place card is open, recentre returns to the place's pin, not to the user.
        if case .place(let p) = screen { map.setCamera(.place(p.location, zoom: 16)); return }
        map.setCamera(screen == .navigating ? .navigation : .trackNorth(zoom: 15))
    }

    // MARK: map wiring

    private func wireMap() {
        map.onUserGesture = { [weak self] in
            guard let self else { return }
            if self.map.isFollowing || self.map.isPlaceCentred { self.map.camera = .free }
            // While navigating, follow the puck again 10 s after the last pan.
            self.followResume?.cancel()
            guard self.screen == .navigating else { return }
            self.followResume = Task { [weak self] in
                try? await Task.sleep(for: .seconds(10))
                guard let self, !Task.isCancelled, self.screen == .navigating, !self.map.isFollowing else { return }
                self.recenter()
            }
        }
        map.onRouteTapped = { [weak self] id in
            guard let self, self.screen == .routePreview else { return }
            self.selectRoute(id)
        }
        map.onAlertTapped = { [weak self] r in self?.selectedAlert = r }
        // Tapping the map (not an alert or route) folds the home panel back to Peek.
        map.onMapTap = { [weak self] in
            guard let self, self.screen == .home else { return }
            self.homeDetent = .peek
        }
        map.onLongPress = { [weak self] p in
            guard let self, self.screen == .home else { return }
            self.longPressPoint = p
        }
        map.onRestrictedAreaTapped = { [weak self] in
            guard let self, self.screen != .navigating else { return }
            self.showRestrictedAreaInfo = true
        }
    }

    /// Pushes live data into the map (called when the live store changes).
    func syncLiveLayers() {
        map.alerts = Array(live.alerts.values)
        map.jams = live.jams.values.map { JamLine(id: $0.id, level: $0.level, points: Polyline.decode($0.polyline)) }
        map.drivers = screen == .navigating ? [] : live.drivers
    }

    private func syncRouteLayers() {
        switch screen {
        case .routePreview:
            guard let planner else { break }
            let sel = planner.selected?.id
            map.routes = planner.routes.map {
                RouteLine(id: $0.id, points: Polyline.decode($0.polyline), selected: $0.id == sel, traffic: $0.trafficSegments ?? [])
            }
            // A substituted demo route ends at its own (captured) destination; pin that, not the requested place.
            if let r = planner.selected, r.demoNote != nil, let end = Polyline.decode(r.polyline).last {
                map.destination = end
            } else {
                map.destination = planner.destination.location
            }
            map.bubbleAnchors = Self.bubbleAnchors(for: planner.routes.map { ($0.id, Polyline.decode($0.polyline)) })
            map.tolls = (planner.selected?.tolls ?? []).map { LatLng(lat: $0.lat, lng: $0.lng) }
        case .navigating:
            guard let nav = navigation else { break }
            map.tolls = nav.tollTracker.tolls.map { LatLng(lat: $0.plaza.lat, lng: $0.plaza.lng) }
            map.routes = [RouteLine(id: nav.route.id, points: nav.geometry.points, selected: true, traffic: nav.route.trafficSegments ?? [])]
            map.destination = nav.route.demoNote != nil ? (nav.geometry.points.last ?? nav.destination.location) : nav.destination.location
            map.bubbleAnchors = [:]
        case .place(let p):
            map.routes = []
            map.tolls = []
            map.destination = p.location
            map.bubbleAnchors = [:]
        default:
            map.routes = []
            map.tolls = []
            map.destination = nil
            map.bubbleAnchors = [:]
        }
    }

    /// Places each route's duration bubble on the stretch of that route farthest from the other routes
    /// (and from bubbles already placed), so bubbles don't stack where alternatives share road.
    static func bubbleAnchors(for routes: [(id: String, points: [LatLng])]) -> [String: LatLng] {
        func sample(_ pts: [LatLng], _ n: Int) -> [LatLng] {
            guard pts.count > n else { return pts }
            return (0..<n).map { pts[$0 * (pts.count - 1) / (n - 1)] }
        }
        let samples = routes.map { sample($0.points, 60) }
        var anchors: [String: LatLng] = [:]
        var placed: [LatLng] = []
        for (i, r) in routes.enumerated() where r.points.count > 1 {
            let others = samples.enumerated().filter { $0.offset != i }.flatMap(\.element)
            // Skip the first/last 15 % so bubbles don't sit on the origin or destination pin.
            let cand = samples[i].dropFirst(samples[i].count * 15 / 100).dropLast(samples[i].count * 15 / 100)
            let best = cand.max { a, b in
                score(a, others, placed) < score(b, others, placed)
            } ?? r.points[r.points.count / 2]
            anchors[r.id] = best
            placed.append(best)
        }
        return anchors
    }

    private static func score(_ p: LatLng, _ others: [LatLng], _ placed: [LatLng]) -> Double {
        let dOther = others.map { Geo.distance(p, $0) }.min() ?? 10_000
        let dPlaced = placed.map { Geo.distance(p, $0) }.min() ?? 10_000
        return min(dOther, 3_000) + min(dPlaced, 1_500)
    }

    // MARK: flows

    func go(_ s: Screen) {
        screen = s
        if s != .routePreview { safetyCard = nil }
        syncRouteLayers()
        syncLiveLayers()
        map.navigationPuck = s == .navigating
        switch s {
        case .home:
            map.setCamera(.trackNorth(zoom: 15))
        case .place(let p):
            // The card reports its height (placeBottomInset); the pin is centred in the map above it.
            map.setCamera(.place(p.location, zoom: 16))
        case .routePreview, .search:
            break
        case .navigating:
            map.setCamera(.navigation)
        }
    }

    func openPlace(_ p: PlaceSummary) {
        go(.place(p))
    }

    func startPinPick(_ purpose: PinPurpose, start: LatLng? = nil) {
        pinPick = PinPickRequest(purpose: purpose, start: start ?? position)
    }

    /// What a chosen point becomes, by where "Choose on map" was opened.
    func handlePicked(_ p: PickedPoint, purpose: PinPurpose) {
        switch purpose {
        case .destination:
            if let id = p.placeId, !id.hasPrefix("pin:") { openPlace(p.summary) } else { pinActions = p }
        case .addStop: addStop(p.summary)
        case .setOrigin:
            setRouteStart(.chosen(name: p.title, location: p.location, placeId: p.placeId))
            go(.routePreview)
        case .placeEntrance:
            guard let (placeId, loc) = entrancePlace else { return }
            entrancePlace = nil
            Task {
                _ = await reportIssue(.placeEntranceWrong, placeId: placeId, at: loc, source: .placeEdit,
                                      payload: ["navLat": String(format: "%.6f", p.location.lat), "navLng": String(format: "%.6f", p.location.lng)])
            }
        case .favorite: savingPlace = p.favoriteSummary
        case .setHome: setSaved(kind: .home, place: p.summary); go(.home)
        case .setWork: setSaved(kind: .work, place: p.summary); go(.home)
        }
    }

    func pickDroppedPin(_ p: LatLng) async {
        let rg = try? await repo.reverseGeocode(p)
        let summary = PlaceSummary(id: "pin:\(p.lat),\(p.lng)", name: rg?.name ?? String(localized: "Dropped pin"), category: .other,
                                   address: rg?.address ?? String(format: "%.5f, %.5f", p.lat, p.lng), lat: p.lat, lng: p.lng,
                                   distanceM: Geo.distance(position, p), brand: nil)
        openPlace(summary)
    }

    func planRoute(to d: Destination, stops: [TripStop] = [], quickPick: Bool = false, remember: Bool = true,
                   vehicle tripVehicle: Vehicle? = nil, eventTrip: Bool = false) {
        // Recents stay on the device. Event stops are never remembered: event data must not outlive the event
        // or end up in a backup (docs/events.md §7.5–7.6).
        if remember {
            try? store.recordRecent(name: d.name, address: d.address, lat: d.location.lat, lng: d.location.lng, placeId: d.placeId)
            recents = (try? store.recents()) ?? recents
        }
        let planner = RoutePlanner(destination: d, vehicle: tripVehicle ?? vehicle)
        planner.stops = stops
        planner.quickPick = quickPick
        planner.isEventTrip = eventTrip
        self.planner = planner
        go(.routePreview)
        Task { await resolveStartAndFetch(planner) }
    }

    // MARK: route start (never the map centre)

    /// GPS as the route-start rules see it: a DEBUG fixed location counts as a fresh fix.
    func currentGPS(now: Date = .now) -> RouteOrigin.GPS {
        if let f = pinnedLocation { return .fresh(f) }
        return RouteOrigin.classify(fix: location.lastFix?.coordinate, at: location.lastFix?.timestamp, now: now)
    }

    /// Fresh fix → route from it. Otherwise wait up to 8 s for one ("Finding your location…"), then "unknown"
    /// with no route request. A start the user chose is kept.
    func resolveStartAndFetch(_ planner: RoutePlanner) async {
        if case .chosen = planner.start { await fetchRoutes(); return }
        if case .fresh(let p) = currentGPS() {
            planner.start = .gps(p)
        } else if location.isAuthorized || location.needsPermission {
            planner.start = .locating
            let deadline = Date().addingTimeInterval(RouteOrigin.waitForFix)
            while Date() < deadline, self.planner === planner {
                if case .fresh(let p) = currentGPS() { planner.start = .gps(p); break }
                try? await Task.sleep(for: .milliseconds(250))
            }
            if planner.start == .locating { planner.start = .unknown }
        } else {
            planner.start = .unknown
        }
        guard self.planner === planner else { return }
        await fetchRoutes()
    }

    /// The user picked a start (or Your location again).
    func setRouteStart(_ start: RouteStart) {
        guard let planner else { return }
        planner.start = start
        planner.routes = []
        planner.selectedId = nil
        Task { await resolveStartAndFetch(planner) }
    }

    /// ⇅: the start becomes the destination and vice versa.
    func swapRouteEnds() {
        guard let planner, let from = planner.start.point else { return }
        let oldDest = planner.destination
        let fromName = planner.start.chosenName ?? String(localized: "Your location")
        let fromId: String? = if case .chosen(_, _, let id) = planner.start { id } else { nil }
        planner.destination = Destination(name: fromName, address: "", location: from, placeId: fromId, isPin: fromId == nil)
        planner.start = .chosen(name: oldDest.name, location: oldDest.location, placeId: oldDest.placeId)
        planner.routes = []
        Task { await resolveStartAndFetch(planner) }
    }

    /// "Drive to {start} first": navigation only ever starts from GPS, so plan a trip to the chosen start.
    func driveToStartFirst() {
        guard let planner, case .chosen(let name, let p, let id) = planner.start else { return }
        planRoute(to: Destination(name: name, address: "", location: p, placeId: id))
    }

    /// A fix arriving after "unknown" retries the route.
    private func retryStartIfWaiting() {
        guard let planner, planner.start == .unknown, screen == .routePreview, case .fresh = currentGPS() else { return }
        Task { await resolveStartAndFetch(planner) }
    }

    /// Travel mode tabs: remembered locally and on the profile (`PATCH /me vehicle`).
    func setTravelMode(_ v: Vehicle) {
        vehicle = v
        UserDefaults.standard.set(v.rawValue, forKey: "travelMode")
        updateProfile(UserPatch(vehicle: v))
        if let planner, planner.vehicle != v {
            planner.vehicle = v
            Task { await fetchRoutes() }
        }
    }

    // MARK: stops

    func removeStop(_ id: UUID) {
        guard let planner else { return }
        planner.stops.removeAll { $0.id == id }
        Task { await fetchRoutes() }
    }

    func moveStops(from: IndexSet, to: Int) {
        guard let planner else { return }
        StopPlanner.move(&planner.stops, from: from, to: to)
        Task { await fetchRoutes() }
    }

    func fetchRoutes() async {
        guard let planner else { return }
        planner.error = nil
        planner.alreadyHere = false
        // No known start → no route request (never the map centre).
        guard let origin = planner.start.point else {
            planner.routes = []
            planner.isLoading = false
            syncRouteLayers()
            return
        }
        let firstTarget = planner.stops.first?.location ?? planner.destination.location
        if RouteOrigin.sameSpot(origin, firstTarget) {
            planner.routes = []
            planner.alreadyHere = true
            planner.isLoading = false
            syncRouteLayers()
            return
        }
        planner.isLoading = true
        let req = RouteRequest(
            origin: RouteEndpoint(lat: origin.lat, lng: origin.lng),
            destination: RouteEndpoint(lat: planner.destination.location.lat, lng: planner.destination.location.lng, placeId: planner.destination.placeId),
            waypoints: planner.stops.map(\.endpoint),
            vehicle: planner.vehicle, avoid: planner.vehicle.isMotorized ? planner.avoid : AvoidOptions(),
            departAt: planner.departAt, alternatives: 2, ignoreIssues: planner.ignoredIssues.sorted())
        do {
            let routes = try await repo.routes(req)
            guard self.planner === planner else { return }
            planner.routes = routes
            planner.selectedId = (routes.first(where: \.isBest) ?? routes.first)?.id
            if routes.isEmpty { planner.error = String(localized: "No route found") }
        } catch {
            planner.error = error.localizedDescription
        }
        planner.isLoading = false
        syncRouteLayers()
        if let r = planner.selected, let bbox = BBox(array: r.bbox) {
            let all = planner.routes.compactMap { BBox(array: $0.bbox) }
            let union = BBox.around(all.flatMap { [LatLng(lat: $0.minLat, lng: $0.minLng), LatLng(lat: $0.maxLat, lng: $0.maxLng)] } + [origin]) ?? bbox
            map.overviewInsets = (top: 170, bottom: 400)
            map.setCamera(.overview(union))
        }
    }

    func selectRoute(_ id: String) {
        planner?.selectedId = id
        syncRouteLayers()
    }

    func startNavigation() {
        // Navigation only ever starts from a fresh GPS fix, never from a chosen start.
        guard let planner, planner.selected != nil, planner.start.isGPS, navigation == nil, !startingNavigation, safetyCard == nil else { return }
        // Not agreed yet: the map, search and route preview work, but turn-by-turn waits for the agreement.
        if needsSafetyAgreement {
            showNotAgreedSheet = true
            return
        }
        startingNavigation = true
        Task {
            defer { startingNavigation = false }
            // Approximate location: ask once for precise location for this drive.
            if !shouldSimulate { await location.requestTemporaryPrecision() }
            // The user may have left route preview while the precision prompt was up.
            guard self.planner === planner, navigation == nil, screen == .routePreview else { return }
            startWithReminder()
        }
    }

    @ObservationIgnored private var startingNavigation = false

    private func beginNavigation() {
        guard let planner, let route = planner.selected else { return }
        let session = NavigationSession(destination: planner.destination, route: route, stops: planner.stops, vehicle: planner.vehicle,
                                        avoid: planner.avoid, repo: repo, voice: voice)
        Task {
            await loadTripIssues(for: route)
            #if DEBUG
            // `-GimanoFakeStillClosed YES`: a "Still closed?" prompt 3 s into the drive (device screenshots; never sent).
            if UserDefaults.standard.bool(forKey: "GimanoFakeStillClosed") {
                try? await Task.sleep(for: .seconds(3))
                let p = position
                stillClosedPrompt = Issue(id: "debug-still-closed", kind: .turnNotAllowed, state: .confirmed, lat: p.lat, lng: p.lng,
                                          roadName: "Jalan SS 2/3", lastEvidenceAt: Date().addingTimeInterval(-5 * 3600))
            }
            #endif
        }
        session.onRouteChanged = { [weak self] r in
            guard let self else { return }
            self.syncRouteLayers()
            if self.shouldSimulate { self.startSimulator(on: r) }
        }
        navigation = session
        location.setNavigating(true, requestAlways: !shouldSimulate)
        go(.navigating)
        session.begin()
        if shouldSimulate { startSimulator(on: route) } else if let fix = location.lastFix { applyFix(fix) }
        UIApplication.shared.isIdleTimerDisabled = true
    }

    /// True while a simulated drive moves the puck (then real-GPS warnings don't apply).
    var isSimulatingDrive: Bool { simulator.isRunning }

    /// Demo drives: no backend, no real GPS fix (e.g. Simulator), or forced from Debug settings.
    var shouldSimulate: Bool {
        // Demo routes are captured fixtures that may not start where the device is, so always simulate them.
        #if DEBUG
        // Simulator / UI tests: no real GPS fix yet → simulate along the route.
        config.simulateDrive || isDemo || !hasRealFix || pinnedLocation != nil || planner?.selected?.demoNote != nil
        #else
        // A real user waits for real GPS; only demo data (server unreachable) drives a simulated trip.
        isDemo || planner?.selected?.demoNote != nil
        #endif
    }

    private func startSimulator(on route: Route) {
        let pts = Polyline.decode(route.polyline)
        let mode = navigation?.vehicle ?? planner?.vehicle ?? .car
        let speed: Double = switch mode {
        case .car: 50
        case .motorcycle: 55
        case .bicycle: 16
        case .walk: 5
        }
        // Slow modes get a bigger speed-up so demos don't take an hour.
        let speedup = config.simulationSpeedup * (mode.isMotorized ? 1 : 4)
        var tick = 0.5
        var profile: (@Sendable (Double) -> Double)?
        #if DEBUG
        // Route replays (device checks of the toll alert, camera modes and arrival): `-GimanoSimSpeed route` drives at
        // the maneuvers' own speeds (highway ≈ 100 km/h, streets slower); `-GimanoSimTick 1` gives one fix a second.
        let d = UserDefaults.standard
        if d.string(forKey: "GimanoSimSpeed") == "route" { profile = DriveSimulator.profile(for: route) }
        if d.double(forKey: "GimanoSimTick") > 0 { tick = min(2, max(0.2, d.double(forKey: "GimanoSimTick"))) }
        #endif
        simulator.start(points: pts, speedKmh: speed, speedup: speedup, tick: tick, profile: profile) { [weak self] fix in
            self?.applyFix(fix)
        }
    }

    // MARK: complaints (docs/complaints.md)

    /// Open road issues around the active route ("Still closed?" prompts).
    private(set) var tripIssues: [Issue] = []
    @ObservationIgnored private var askedStillClosed: Set<String> = []
    var stillClosedPrompt: Issue?
    /// "Why didn't you follow the route?" after the trip (never while driving).
    var deviationPrompt: DeviationEvent?

    func loadTripIssues(for route: Route) async {
        guard let b = BBox(array: route.bbox)?.expanded(byM: StillClosedPolicy.radiusM) else { return }
        tripIssues = (try? await repo.issuesNearby(bbox: b, kinds: IssueKind.allCases.filter(\.isRoad))) ?? []
        askedStillClosed = []
    }

    private func checkStillClosed(at p: LatLng) {
        guard navigation != nil, stillClosedPrompt == nil,
              let issue = StillClosedPolicy.nearest(tripIssues, to: p, asked: askedStillClosed) else { return }
        askedStillClosed.insert(issue.id)
        stillClosedPrompt = issue
    }

    func voteIssue(_ issue: Issue, _ answer: IssueVoteAnswer) {
        stillClosedPrompt = nil
        // DEBUG sample prompts (`-GimanoFakeStillClosed`) are never sent.
        if issue.id.hasPrefix("debug-") { showToast(String(localized: "Thanks for checking!")); return }
        Task {
            guard await ensureRulesAccepted() else { return }
            do {
                _ = try await repo.voteIssue(id: issue.id, IssueVote(answer: answer))
                showToast(String(localized: "Thanks for checking!"))
            } catch let e as APIError where e.isServerSideGap {
                showToast(String(localized: "Road problem reports aren't available on the server yet."))
            } catch { showToast(error.localizedDescription) }
        }
    }

    /// "Masalah jalan": one tap + Send, at the current fix and heading.
    func reportIssue(_ kind: IssueKind, subtype: String? = nil, duration: ClosureDuration? = nil, placeId: String? = nil,
                     at point: LatLng? = nil, source: NewIssue.Source = .report, payload: [String: String]? = nil) async -> Bool {
        guard let p = point ?? reportPosition else {
            showToast(String(localized: "Waiting for your location. Try again in a moment."))
            return false
        }
        if refuseReportInRestrictedArea(p) { return false }
        guard await ensureRulesAccepted() else { return false }
        var data = payload ?? [:]
        if let nav = navigation { data["routeId"] = nav.route.id }
        let new = NewIssue(kind: kind, subtype: subtype, lat: p.lat, lng: p.lng, heading: point == nil ? heading : nil, placeId: placeId,
                           vehicle: navigation?.vehicle ?? vehicle, durationHint: duration, source: source, payload: data.isEmpty ? nil : data)
        do {
            _ = try await repo.createIssue(new)
            showToast(isDemo ? String(localized: "Demo mode: kept on this phone, not sent") : String(localized: "Thanks! Drivers nearby will be asked to confirm."))
            return true
        } catch let e as APIError where e.isRestrictedArea {
            showToast(e.localizedDescription)
        } catch let e as APIError where e.isServerSideGap {
            showToast(String(localized: "Road problem reports aren't available on the server yet."))
        } catch {
            showToast(error.localizedDescription)
        }
        return false
    }

    /// Answer to "Why didn't you follow the route?": only the answer + that spot are sent; jams and own choices aren't.
    func answerDeviation(_ d: DeviationEvent, _ reason: DeviationReason?, neverAskAgain: Bool) {
        deviationPrompt = nil
        UserDefaults.standard.set(Date(), forKey: "deviation.lastAsked")
        if neverAskAgain { UserDefaults.standard.set(true, forKey: "deviation.optedOut") }
        guard let kind = reason?.issueKind else { return }
        Task {
            _ = await reportIssue(kind, at: d.location, source: .deviation,
                                  payload: d.roadName.map { ["roadName": $0] })
        }
    }

    private func considerDeviationPrompt(_ d: DeviationEvent?) {
        guard let d else { return }
        let ok = DeviationAskPolicy.shouldAsk(lastAsked: UserDefaults.standard.object(forKey: "deviation.lastAsked") as? Date,
                                              optedOut: UserDefaults.standard.bool(forKey: "deviation.optedOut"),
                                              speedKmh: speedKmh, navigating: navigation != nil, now: .now)
        if ok { deviationPrompt = d }
    }

    /// "Lalu juga": recompute this trip without that exclusion.
    func driveThroughAnyway(_ issue: RouteIssue) {
        guard let planner else { return }
        planner.ignoredIssues.insert(issue.id)
        Task { await fetchRoutes() }
    }

    func stopNavigation() {
        let deviation = navigation?.deviation
        let speedBefore = speedKmh
        stopSharing()
        simulator.stop()
        navigation?.stop()
        navigation = nil
        planner = nil
        location.setNavigating(false)
        UIApplication.shared.isIdleTimerDisabled = false
        speedKmh = 0
        homeDetent = .peek
        go(.home)
        reloadLocal()
        tripIssues = []
        stillClosedPrompt = nil
        // Asked after the trip only, and only if the phone isn't moving (never while driving).
        if speedBefore < 5 { considerDeviationPrompt(deviation) }
    }

    /// "Add a stop" from search: appends to the trip being previewed, or to the active drive.
    func addStop(_ p: PlaceSummary) {
        let stop = TripStop(name: p.name, location: p.location, placeId: p.id.hasPrefix("pin:") || p.isSearchOnly ? nil : p.id)
        if let nav = navigation {
            var remaining = Array(nav.stops.dropFirst(nav.stopTracker.nextStopIndex))
            guard StopPlanner.add(stop, to: &remaining) else {
                showToast(String(localized: "A trip can have up to 5 stops"))
                go(.navigating)
                return
            }
            let req = RouteRequest(
                origin: RouteEndpoint(lat: position.lat, lng: position.lng),
                destination: RouteEndpoint(lat: nav.destination.location.lat, lng: nav.destination.location.lng, placeId: nav.destination.placeId),
                waypoints: remaining.map(\.endpoint), vehicle: nav.vehicle, avoid: nav.avoid, alternatives: 0)
            go(.navigating)
            Task {
                do {
                    if let r = try await repo.routes(req).first {
                        nav.setRoute(r, stops: remaining)
                        showToast(String(localized: "Stop added: \(p.name)"))
                    }
                } catch {
                    showToast(error.localizedDescription)
                }
            }
        } else if let planner {
            guard StopPlanner.add(stop, to: &planner.stops) else {
                showToast(String(localized: "A trip can have up to 5 stops"))
                go(.routePreview)
                return
            }
            go(.routePreview)
            Task { await fetchRoutes() }
        } else {
            openPlace(p)
        }
    }

    // MARK: saved places (on device)

    func setSaved(kind: SavedPlaceKind, place p: PlaceSummary, label: String? = nil, icon: FavoriteIcon? = nil) {
        let placeId = p.id.hasPrefix("pin:") || p.id.hasPrefix("local:") || p.isSearchOnly ? nil : p.id
        do {
            switch kind {
            case .home, .work:
                try store.setHomeWork(kind, name: kind == .home ? String(localized: "Home") : String(localized: "Work"),
                                      lat: p.lat, lng: p.lng, address: p.address, placeId: placeId)
            case .favorite:
                let name = (label?.trimmingCharacters(in: .whitespaces)).flatMap { $0.isEmpty ? nil : $0 } ?? p.name
                try store.addFavorite(name: name, icon: icon ?? QuickLabel.suggestedIcon(for: name) ?? .star,
                                      lat: p.lat, lng: p.lng, address: p.address, placeId: placeId)
            }
            reloadLocal()
            showToast(String(localized: "Saved"))
        } catch {
            showToast(error.localizedDescription)
        }
    }

    func icon(for place: SavedPlace) -> FavoriteIcon { place.favoriteIcon }

    func updateFavorite(_ place: SavedPlace, name: String, icon: FavoriteIcon) {
        try? store.updateFavorite(id: place.id, name: name.trimmingCharacters(in: .whitespaces), icon: icon)
        reloadLocal()
    }

    func deleteFavorite(_ place: SavedPlace) {
        try? store.deleteSavedPlace(id: place.id)
        reloadLocal()
    }

    func moveFavorites(from: IndexSet, to: Int) {
        var favs = favorites
        favs.move(fromOffsets: from, toOffset: to)
        try? store.reorderFavorites(favs.map(\.id))
        reloadLocal()
    }

    /// Promotes a favourite to Home or Work.
    func promote(_ place: SavedPlace, to kind: SavedPlaceKind) {
        let p = PlaceSummary(id: place.placeId ?? "local:\(place.id)", name: place.name, category: .other, address: place.address,
                             lat: place.lat, lng: place.lng, distanceM: nil, brand: nil)
        setSaved(kind: kind, place: p)
    }

    func navigate(to saved: SavedPlace) {
        planRoute(to: Destination(name: saved.name, address: saved.address, location: saved.location, placeId: saved.placeId), quickPick: true)
    }

    /// Local favourites matching a search query (shown before server results).
    func localMatches(_ query: String) -> [SavedPlace] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return [] }
        return savedPlaces.filter {
            $0.name.lowercased().contains(q) || $0.address.lowercased().contains(q)
                || ($0.kind == .home && String(localized: "Home").lowercased().hasPrefix(q))
                || ($0.kind == .work && String(localized: "Work").lowercased().hasPrefix(q))
        }
    }

    // MARK: feedback

    /// Opens "Add feedback": captures the current screen first, then shows the form.
    /// During navigation it's only allowed when stopped (< 5 km/h) or after the user confirms they're a passenger.
    func openFeedback(from screen: FeedbackScreen, placeId: String? = nil, passengerConfirmed: Bool = false) {
        if screen == .navigation, !FeedbackRules.allowedWhileDriving(speedKmh: speedKmh, isPassenger: passengerConfirmed) {
            askPassengerForFeedback = true
            return
        }
        let shot = FeedbackAttachments.captureWindowJPEG()
        let routeId = navigation?.route.id ?? planner?.selected?.id
        // Privacy: location in diagnostics is rounded to 2 dp (~1 km); diagnostics are opt-in in the form.
        feedbackDraft = FeedbackDraft(screen: screen, screenshot: shot, device: currentDevice(),
                                      location: CoarseLocation(position), routeId: routeId, placeId: placeId)
    }

    /// The device block shown in the feedback / crash previews.
    func currentDevice() -> DeviceInfo {
        DeviceInfo.current(theme: effectiveScheme == .dark ? "dark" : "light",
                           dataMode: backendStatus == .online || (config.dataMode != .demo && backendStatus == .unknown) ? "live" : "demo",
                           precise: location.isPrecise, lastAccuracyM: location.lastFix?.accuracyM)
    }

    func deleteFeedbackContact(_ id: String, contactToken: String? = nil, localId: UUID? = nil) async {
        do {
            try await repo.deleteFeedbackContact(id: id, contactToken: contactToken)
            if let localId { feedbackOutbox.markContactWithdrawn(localId) }
            showToast(String(localized: "Contact details deleted"))
            await refreshMyFeedback()
        } catch {
            showToast(error.localizedDescription)
        }
    }

    /// Crash reports sent with a contact (kept on the phone with their token).
    private(set) var crashContacts: [CrashContactEntry] = CrashContactStore.load()

    func deleteCrashContact(_ entry: CrashContactEntry) async {
        do {
            try await repo.deleteCrashContact(id: entry.id, contactToken: entry.token)
            var list = CrashContactStore.load()
            if let i = list.firstIndex(where: { $0.id == entry.id }) { list[i].withdrawn = true; list[i].token = "" }
            CrashContactStore.save(list)
            crashContacts = list
            showToast(String(localized: "Contact details deleted"))
        } catch {
            showToast(error.localizedDescription)
        }
    }

    #if DEBUG
    private func debugRecoveryRoundTrip() async {
        // `-GimanoRecoveryRoundTrip YES`: this phone's (fresh) identity → 24 words → forget identity + token →
        // sign in by key (POST /auth/token {publicKey, ts, sig}) → must come back as the same userId.
        if UserDefaults.standard.bool(forKey: "GimanoRecoveryRoundTrip"), config.dataMode != .demo,
           UserDefaults.standard.string(forKey: "recovery.roundTrip") == nil, let id = try? store.identity() {
            let words = RecoveryCode.encode(id.keys.seed).joined(separator: " ")
            try? store.deleteIdentity()
            TokenStore.save(nil, for: config.apiBaseURL)
            // A client with no token and no key, as on a new phone.
            let fresh = LiveRepository(baseURL: config.apiBaseURL, store: store)
            var err: String?
            do {
                let keys = try IdentityKeys(seed: RecoveryCode.decode(words))!
                _ = try await fresh.signIn(recovered: keys)
            } catch { err = error.localizedDescription }
            let back = try? store.identity()
            let ok = err == nil && back?.userId == id.userId
            UserDefaults.standard.set("\(ok ? "PASS" : "FAIL") userId=\(back?.userId ?? "-") expected=\(id.userId) \(err ?? "")",
                                      forKey: "recovery.roundTrip")
        }
    }
    #endif

    // MARK: identity / account

    var identityName: String? { (try? store.identity())?.displayName }

    /// 0…1 towards the next tier (by the first numeric requirement), for the tier ring.
    var tierProgress: Double {
        guard let u = user else { return 0 }
        if u.tier == .emas { return 1 }
        let target = u.tier == .perak ? 50.0 : 10.0
        return Double(u.placesAccepted ?? 0) / target
    }

    func refreshMe() async {
        if let u = try? await repo.me() { user = u }
    }

    /// Recovery code → seed. The server can only sign in a pseudonym by userId today, so a code is accepted
    /// only when it matches this phone's identity or the server can register it as new. Returns an error text.
    func restoreIdentity(fromCode code: String) async -> String? {
        let seed: [UInt8]
        do { seed = try RecoveryCode.decode(code) } catch RecoveryCode.Failure.unknownWord(let w) {
            return String(localized: "“\(w)” isn't a recovery-code word.")
        } catch {
            return String(localized: "That code isn't valid. Check the words and their order.")
        }
        guard let keys = IdentityKeys(seed: seed) else { return String(localized: "That code isn't valid.") }
        if let current = try? store.identity(), current.keys == keys { return String(localized: "This is already your pseudonym.") }
        do {
            let res = try await repo.signIn(recovered: keys)
            await refreshMe()
            showToast(String(localized: "Welcome back, \(res.displayName)"))
            return nil
        } catch APIError.http(status: 401, _) {
            return String(localized: "No pseudonym uses this code (or its key was replaced). Check the words.")
        } catch APIError.http(status: 429, _) {
            return String(localized: "Too many tries. Wait a minute and try again.")
        } catch {
            return error.localizedDescription
        }
    }

    // MARK: vetting (nearby verify prompt)

    var isForeground = true
    /// GPS quality while navigating ("Weak GPS signal ±xx m" chip).
    private(set) var gpsQuality = GpsQuality()
    @ObservationIgnored private var followResume: Task<Void, Never>?
    /// The nearby pending place we're asking about (sheet).
    var vettingPrompt: Place?
    @ObservationIgnored private var vettingGate = VettingPromptGate(
        lastPromptAt: UserDefaults.standard.object(forKey: "vetting.lastPromptAt") as? Date)
    @ObservationIgnored private var vettingTask: Task<Void, Never>?
    @ObservationIgnored private var lookingForVetting = false

    func startVettingTicker() {
        vettingTask?.cancel()
        vettingTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(20))
                await self?.considerVettingPrompt()
            }
        }
    }

    /// Asks about at most one nearby pending place when parked (< 5 km/h for 60 s), not navigating,
    /// app in the foreground, at most once per 30 min. Distance is computed here; nothing about it is stored.
    func considerVettingPrompt(now: Date = .now, force: Bool = false) async {
        guard config.dataMode == .demo || backendStatus != .demoFallback, vettingPrompt == nil, !lookingForVetting else { return }
        let ok = force || vettingGate.shouldPrompt(speedKmh: speedKmh, at: now, navigating: navigation != nil, foreground: isForeground)
        guard ok else { return }
        lookingForVetting = true
        defer { lookingForVetting = false }
        let me = position
        guard let list = try? await repo.pendingNearby(cell: Geohash.encode(me)) else { return }
        let voted = Set(UserDefaults.standard.stringArray(forKey: "vetting.voted") ?? [])
        let candidates = list.filter { !voted.contains($0.id) && !ownPlaceIds.contains($0.id) && Proximity.claim(me: me, place: $0.location) != nil }
            .sorted { Geo.distance(me, $0.location) < Geo.distance(me, $1.location) }
        guard let nearest = candidates.first else { return }
        var detail = (try? await repo.place(id: nearest.id, near: me)) ?? Place(summary: nearest)
        detail.confirmationsWeighted = detail.confirmationsWeighted ?? nearest.confirmationsWeighted
        detail.required = detail.required ?? nearest.required
        vettingGate.didPrompt(at: now)
        UserDefaults.standard.set(now, forKey: "vetting.lastPromptAt")
        vettingPrompt = detail
    }

    /// Signed vote with the phone-computed proximity bucket and (where supported) an App Attest assertion.
    func vote(on place: Place, answer: VoteAnswer, nameCorrect: Bool?, locationCorrect: Bool?) async throws -> VerifyResult {
        let me = position
        guard let proximity = Proximity.claim(me: me, place: LatLng(lat: place.lat, lng: place.lng),
                                              rural: place.tags?["rural"] == "yes") else {
            throw VettingError.tooFar
        }
        guard await ensureRulesAccepted() else { throw CancellationError() }
        let ts = Int64(Date().timeIntervalSince1970)
        let repo = self.repo
        let token = await AppAttestor.shared.voteToken(placeId: place.id, ts: ts, repo: repo)
        let req = VerifyPlaceRequest(answer: answer, nameCorrect: nameCorrect, locationCorrect: locationCorrect, proximity: proximity,
                                     attestation: token.map { AttestationClaim(token: $0) })
        let result = try await SigningClock.$fixedTs.withValue(ts) { try await repo.verifyPlace(id: place.id, req) }
        var voted = UserDefaults.standard.stringArray(forKey: "vetting.voted") ?? []
        voted.append(place.id)
        UserDefaults.standard.set(Array(voted.suffix(500)), forKey: "vetting.voted")
        return result
    }

    // MARK: crash reports

    var pendingCrashes: [CrashReport] = []
    var showCrashPrompt = false

    func checkCrashReports() async {
        let reporter = CrashReporter.shared
        await reporter.retryApproved(repo: repo)
        let pending = reporter.pending
        guard !pending.isEmpty else { return }
        switch reporter.preference {
        case .never: reporter.discardAll()
        case .always:
            // Automatic sending can't ask, so device info (opt-in) is left out.
            for r in pending { _ = await reporter.send(r, device: nil, contact: nil, repo: repo) }
        case .ask:
            pendingCrashes = pending
            showCrashPrompt = true
        }
    }

    func sendCrashReports(contact: ContactDetails?, includeDevice: Bool = false) async {
        let reporter = CrashReporter.shared
        var sent = 0
        for r in pendingCrashes where await reporter.send(r, device: includeDevice ? currentDevice() : nil, contact: contact, repo: repo) { sent += 1 }
        pendingCrashes = reporter.pending
        crashContacts = CrashContactStore.load()
        showToast(sent > 0 ? String(localized: "Thanks! Crash report sent") : String(localized: "Saved. We'll send it when we can."))
    }

    func discardCrashReports() {
        CrashReporter.shared.discardAll()
        pendingCrashes = []
    }

    func submitFeedback(_ request: FeedbackRequest) {
        _ = feedbackOutbox.enqueue(request)
        feedbackDraft = nil
        Task {
            let sent = await feedbackOutbox.flush { [repo] in try await repo.sendFeedback($0) }
            if isDemo {
                // Demo data: kept on this phone, never delivered. Say so (no fake "sent").
                showToast(String(localized: "Demo mode: feedback kept on this phone, not sent"))
            } else {
                showToast(sent > 0 ? String(localized: "Thanks! Feedback sent") : String(localized: "Saved. We'll send it when we can."))
            }
        }
    }

    func flushFeedback() async {
        let repo = self.repo
        await feedbackOutbox.flush { try await repo.sendFeedback($0) }
    }

    func refreshMyFeedback() async {
        await flushFeedback()
        if let list = try? await repo.myFeedback() {
            serverFeedback = list
            feedbackOutbox.applyServerStatuses(list)
        }
    }

    private func startOutboxTimer() {
        outboxTimer = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                await self?.flushFeedback()
            }
        }
    }

    // MARK: reports

    /// Where a one-tap report goes: a fresh GPS fix (or the simulated drive), never the default map position or a
    /// fix from hours ago.
    var reportPosition: LatLng? {
        if simulator.isRunning { return position }
        if case .fresh(let p) = currentGPS() { return p }
        return nil
    }

    func submitReport(type: ReportType, subtype: String?, comment: String?) {
        guard let position = reportPosition else {
            showToast(String(localized: "Waiting for your location. Try again in a moment."))
            return
        }
        let new = NewReport(type: type, subtype: subtype, lat: position.lat, lng: position.lng,
                            heading: heading, comment: comment?.isEmpty == true ? nil : comment)
        showReport = false
        if refuseReportInRestrictedArea(position) { return }
        Task {
            guard await ensureRulesAccepted() else { return }
            do {
                let r = try await repo.createReport(new)
                live.upsert(r)
                syncLiveLayers()
                showToast(isDemo ? String(localized: "Demo mode: kept on this phone, not sent") : String(localized: "Thanks! Your report is live."))
            } catch let e as APIError where e.isRestrictedArea {
                showToast(e.localizedDescription)
            } catch {
                showToast(String(localized: "Couldn't send report"))
            }
        }
    }

    func vote(_ report: Report, stillThere: Bool) {
        selectedAlert = nil
        Task {
            guard await ensureRulesAccepted() else { return }
            if let r = try? await repo.vote(reportId: report.id, stillThere: stillThere) { live.upsert(r); syncLiveLayers() }
            showToast(String(localized: "Thanks for confirming"))
        }
    }

    func thank(_ report: Report) {
        Task { try? await repo.thank(reportId: report.id) }
        showToast(String(localized: "Thanks sent"))
    }

    func updateProfile(_ patch: UserPatch) {
        Task {
            if let u = try? await repo.updateMe(patch) {
                user = u
                if let v = u.vehicle { vehicle = v }
            }
        }
    }

    // MARK: community (UGC rules, blocking, account deletion)

    /// Before a public contribution: the community rules once per terms version (stored with the date on the phone).
    func ensureRulesAccepted() async -> Bool {
        if CommunityRules.isAccepted(storedVersion: try? store.setting(CommunityRules.versionKey)) { return true }
        let ok = await TopPresenter.askRules()
        if ok {
            try? store.setSetting(CommunityRules.versionKey, CommunityRules.version)
            try? store.setSetting(CommunityRules.acceptedAtKey, LocalStore.timestamp())
        }
        return ok
    }

    /// "Block this user": hides their reviews and photos on this phone. Nothing is sent.
    func blockAuthor(ref: String, name: String) {
        guard !blockedRefs.contains(ref) else { return }
        blockedAuthors.append(BlockedAuthor(ref: ref, name: name, blockedAt: .now))
        try? store.setBlockedAuthors(blockedAuthors)
        showToast(String(localized: "Blocked. You won't see their reviews and photos."))
    }

    func unblockAuthor(_ ref: String) {
        blockedAuthors.removeAll { $0.ref == ref }
        try? store.setBlockedAuthors(blockedAuthors)
    }

    /// `DELETE /me`, then forget the pseudonym and tokens on this phone (and optionally the local places).
    /// Returns an error message, or nil on success.
    func deleteAccount(clearLocal: Bool) async -> String? {
        do {
            try await repo.deleteAccount()
        } catch {
            return String(localized: "Couldn't delete your account: \(error.localizedDescription). Nothing was deleted.")
        }
        TokenStore.save(nil, for: config.apiBaseURL)
        Keychain.set(nil, for: "device.id")
        try? store.deleteIdentity()
        if clearLocal {
            try? store.wipePersonalData()
            for key in [CommunityRules.versionKey, CommunityRules.acceptedAtKey, BlockList.settingsKey] { try? store.setSetting(key, nil) }
            blockedAuthors = []
        }
        user = nil
        reloadLocal()
        rebuildRepository()   // drop the deleted account's token and signer from the API client
        showToast(String(localized: "Your Manotu account was deleted"))
        return nil
    }

    func showToast(_ text: String, seconds: Double = 2.5) {
        toast = text
        toastTask?.cancel()
        toastTask = Task {
            try? await Task.sleep(for: .seconds(seconds))
            if !Task.isCancelled { toast = nil }
        }
    }
}
