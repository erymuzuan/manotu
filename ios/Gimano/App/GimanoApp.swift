import SwiftUI

import GoogleSignIn

import UserNotifications

/// Handles taps on planned-drive notifications.
final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    @MainActor static var onOpenPlannedDrive: ((String) -> Void)?
    @MainActor static var pendingDriveId: String?

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        CrashReporter.shared.start()
        return true
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        guard let id = response.notification.request.content.userInfo["plannedDriveId"] as? String else { return }
        await MainActor.run {
            if let open = AppDelegate.onOpenPlannedDrive { open(id) } else { AppDelegate.pendingDriveId = id }
        }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }
}

@main
struct GimanoApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model: AppModel

    init() {
        let model = AppModel()
        _model = State(initialValue: model)
        // Daily automatic backup (BGProcessingTask), registered before launch completes.
        BackupManager.registerBackgroundTask { bgTask in
            // BGTask isn't Sendable; it is only completed once, from the main actor.
            nonisolated(unsafe) let task = bgTask
            let work = Task { @MainActor in
                let ok = await model.backup.runAutoBackup()
                task.setTaskCompleted(success: ok)
            }
            task.expirationHandler = { work.cancel() }
        }
        model.backup.syncAutoBackupSchedule()
    }

    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .tint(.brand)
                .font(Tokens.Font.body)
                .task {
                    AppDelegate.onOpenPlannedDrive = { [model] id in model.openPlannedDrive(id: id) }
                    // Short links (docs/events.md §5.6) use the live server; demo mode has none (the full link is used).
                    model.events.dropTransport = { [weak model] in model?.eventDropTransport }
                    // Expired events are deleted on start-up (docs/events.md §7.5).
                    model.events.refresh()
                    // First launches: offer to paste an invitation link copied before installing (§5.6). Once per launch.
                    model.events.checkDeferredLink()
                    await model.bootstrap()
                    await model.updates.checkIfDue(apiBase: model.config.apiBaseURL, demo: model.isDemo)
                    if let id = AppDelegate.pendingDriveId { AppDelegate.pendingDriveId = nil; model.openPlannedDrive(id: id) }
                }
                .onChange(of: scenePhase) { _, phase in
                    model.isForeground = phase == .active
                    if phase == .active {
                        model.events.refresh()
                        // Restricted areas: re-checked at most daily (ETag), cached in a file.
                        Task { await model.refreshRestrictedAreas() }
                        Task { await model.updates.checkIfDue(apiBase: model.config.apiBaseURL, demo: model.isDemo) }
                    }
                }
                // Universal Links (https://manotu.app/j/#…, /a/#…), when the Associated Domains entitlement is on.
                .onContinueUserActivity(NSUserActivityTypeBrowsingWeb) { activity in
                    if let url = activity.webpageURL, !model.openPlaceLink(url) { model.events.handleIncoming(url: url) }
                }
                .onOpenURL { url in
                    // Google sign-in redirects exist only in builds with Drive backup (GIMANO_DRIVE = YES).
                    if GoogleDriveBackupDestination.isEnabled && GIDSignIn.sharedInstance.handle(url) { return }
                    if model.openPlaceLink(url) { return }
                    // Event invitations: manotu://event#…, manotu://event?drop=…#…, gimano://event#…, …/a/#1.… and …/j/#…
                    // links, and .manotu-event files.
                    if model.events.handleIncoming(url: url) { return }
                    // A .manotu (or older .gimano) backup opened from Files / WhatsApp / Mail.
                    if ["manotu", "gimano"].contains(url.pathExtension.lowercased()) { model.incomingBackup = url }
                }
        }
    }
}

enum MenuDestination: String, Identifiable {
    case profile, planned, inbox, settings, help, debug
    var id: String { rawValue }
}

struct RootView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.colorScheme) private var colorScheme
    @State private var menuDestination: MenuDestination?

    private var updatePresentation: UpdateDecision {
        if model.showOnboarding || model.safetyAgreement != nil { return .none }
        return model.updates.presentation(busy: model.navigation != nil)
    }

    var body: some View {
        @Bindable var model = model
        ZStack {
            GimanoMapView(state: model.map)
                .ignoresSafeArea()

            Group {
                switch model.screen {
                case .home:
                    HomeView()
                case .search(let purpose):
                    SearchView(purpose: purpose)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                case .place(let p):
                    PlaceCardView(summary: p)
                        .id(p.id)
                case .routePreview:
                    RoutePreviewView()
                case .navigating:
                    DriveView()
                }
            }
            .animation(.snappy(duration: 0.25), value: model.screen)

            if model.showMenu {
                SideMenu { dest in
                    model.showMenu = false
                    menuDestination = dest
                }
                .transition(.move(edge: .leading))
                .zIndex(10)
            }

            if model.isDemo && model.screen == .home && model.homeDetent != .full {
                VStack {
                    DemoBadge()
                        .padding(.top, 4)
                    Spacer()
                }
                .zIndex(19)
            }

            VStack {
                Spacer()
                if let toast = model.toast {
                    Toast(text: toast)
                        .padding(.bottom, 180)
                        .transition(.opacity.combined(with: .scale(scale: 0.9)))
                }
            }
            .allowsHitTesting(false)
            .animation(.easeInOut, value: model.toast)
            .zIndex(20)
        }
        .animation(.snappy(duration: 0.25), value: model.showMenu)
        .sheet(isPresented: $model.showReport, onDismiss: { model.reportInitialType = nil }) {
            ReportSheet(initialType: model.reportInitialType)
                .presentationDetents([.fraction(0.62), .large])
                .presentationCornerRadius(Tokens.Radius.sheetTop)
        }
        .sheet(item: $model.selectedAlert) { alert in
            AlertDetailSheet(report: alert)
                .presentationDetents([.height(300)])
                .presentationCornerRadius(Tokens.Radius.sheetTop)
        }
        .sheet(item: $menuDestination) { dest in
            MenuDestinationView(destination: dest)
        }
        .sheet(item: $model.editingDrive) { d in
            PlannedDriveEditor(drive: d)
        }
        .sheet(item: $model.savingPlace) { p in
            SavePlaceSheet(place: p).presentationDetents([.large])
        }
        .sheet(isPresented: $model.showCrashPrompt) { CrashReportSheet() }
        .sheet(isPresented: Bindable(model.events).isPresented, onDismiss: { model.clearEventFromMap() }) {
            EventsSheet()
        }
        .sheet(item: $model.deviationPrompt) { d in DeviationPromptSheet(event: d).presentationDetents([.medium]) }
        .sheet(item: $model.vettingPrompt) { p in
            VettingPromptSheet(place: p).presentationDetents([.medium, .large])
        }
        .sheet(item: $model.feedbackDraft) { d in
            FeedbackForm(draft: d)
        }
        .sheet(item: $model.menuSheet) { s in
            switch s {
            case .favorites: FavoritesManagerView()
            case .myFeedback: MyFeedbackView()
            case .backup: NavigationStack { BackupView().toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { model.menuSheet = nil } } } }
            case .contributions: MyContributionsView()
            }
        }
        .sheet(item: Binding(get: { model.incomingBackup.map { IncomingFile(url: $0) } }, set: { model.incomingBackup = $0?.url })) { f in
            RestoreSheet(pending: BackupView.PendingRestore(file: f.url, manifest: model.backup.manifest(of: f.url))) {
                model.showToast(String(localized: "Restored"))
            }
        }
        .alert("Are you a passenger?", isPresented: $model.askPassengerForFeedback) {
            Button("I'm a passenger") { model.openFeedback(from: .navigation, passengerConfirmed: true) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("For safety, drivers can send feedback only when stopped.")
        }
        .fullScreenCover(item: Binding(get: { model.addPlaceStart.map(IdentifiedPoint.init) }, set: { model.addPlaceStart = $0?.point })) { p in
            AddPlaceFlow(start: p.point, seed: model.addPlaceSeed)
        }
        // Long-press on the home map → the pin's actions directly.
        .onChange(of: model.longPressPoint) { _, p in
            if let p { model.pinActions = PickedPoint(location: p); model.longPressPoint = nil }
        }
        .fullScreenCover(item: $model.pinPick) { req in
            SelectOnMapView(request: req) { picked in
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { model.handlePicked(picked, purpose: req.purpose) }
            }
        }
        .sheet(item: $model.pinActions) { p in
            PinActionsSheet(point: p).presentationDetents([.height(380), .medium])
        }
        .fullScreenCover(isPresented: $model.showOnboarding) {
            OnboardingView()
        }
        // Safety agreement (docs/safety.md §1): first launch before the location prompt, or "Read and agree".
        .fullScreenCover(item: $model.safetyAgreement) { _ in
            SafetyAgreementView { agreed in model.answerSafetyAgreement(agreed) }
        }
        .sheet(isPresented: $model.showNotAgreedSheet) {
            SafetyNotAgreedSheet(onAgree: {
                model.showNotAgreedSheet = false
                Task {
                    try? await Task.sleep(for: .milliseconds(450))
                    model.safetyAgreement = .startDriving
                }
            }, onLater: { model.showNotAgreedSheet = false })
            .presentationDetents([.height(470), .large])
            .presentationCornerRadius(Tokens.Radius.sheetTop)
        }
        .sheet(isPresented: $model.showRestrictedAreaInfo) {
            RestrictedAreaInfoSheet()
                .presentationDetents([.height(400), .large])
                .presentationCornerRadius(Tokens.Radius.sheetTop)
        }
        // New version (soft, once per launch) or update required (blocking). Never during navigation; not over onboarding/agreement.
        .fullScreenCover(isPresented: Binding(
            get: { updatePresentation != .none },
            set: { if !$0 { model.updates.later() } }
        )) {
            UpdateCardView(forced: updatePresentation == .forced, current: AppInfo.version, latest: model.updates.latestVersion,
                           onUpdate: { model.updates.open() }, onLater: { model.updates.later() })
                .interactiveDismissDisabled()
        }
        .preferredColorScheme(model.preferredScheme)
        .onAppear { model.schemeChanged(colorScheme) }
        .onChange(of: colorScheme) { _, s in model.schemeChanged(s) }
        .task {
            // Auto day/night: re-check every minute.
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                if model.theme == .auto { model.themeClock = .now }
            }
        }
        .onChange(of: model.live.revision) { model.syncLiveLayers() }
        .onChange(of: model.map.visibleBBox) { _, bbox in
            if let bbox { model.live.viewportChanged(bbox) }
        }
    }
}

/// The visible Demo badge: tap for what demo means and one tap to turn it off.
struct DemoBadge: View {
    @Environment(AppModel.self) private var model
    @State private var showInfo = false

    var body: some View {
        Button { showInfo = true } label: {
            HStack(spacing: 6) {
                Image(systemName: "play.circle.fill")
                Text(model.backendStatus == .demoForced ? "Demo" : "Demo data · server unreachable")
                Image(systemName: "info.circle")
            }
            .font(Tokens.Font.nunito(13, .black))
            .foregroundStyle(Color.brandOn)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(Color.brand.opacity(0.94), in: Capsule())
            .fabShadow()
        }
        .buttonStyle(.plain)
        .accessibilityHint(Text("Shows what demo mode is and how to turn it off"))
        .accessibilityIdentifier("demoBadge")
        .sheet(isPresented: $showInfo) {
            DemoInfoSheet().presentationDetents([.medium, .large])
        }
    }
}

/// What demo mode is, honestly: sample data on this phone, a simulated drive, nothing sent; and one tap to leave it.
struct DemoInfoSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                Group {
                    if model.backendStatus == .demoForced {
                        Text("Demo mode uses built-in sample places, reports and routes around Kuala Lumpur, and drives along the route by itself (a simulated drive), so you can try everything from anywhere, without an account.\n\nNothing you do is sent to Manotu's server: searches, routes, reports, reviews, photos, complaints, feedback and crash reports stay on this phone (feedback is not delivered). Favourites, planned drives and backups work as usual. Map tiles still load from OpenFreeMap.")
                            .accessibilityIdentifier("demoInfoBody")
                    } else {
                        Text("Manotu can't reach its server right now, so it is showing sample data.")
                    }
                }
                .font(Tokens.Font.body)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(Tokens.Space.gutter)
            }
            // The choice is always on screen, above the text (which scrolls).
            .safeAreaInset(edge: .bottom) {
                if model.backendStatus == .demoForced {
                    VStack(spacing: 8) {
                        Button {
                            dismiss()
                            model.setDemoMode(false)
                        } label: {
                            Label("Turn off demo mode", systemImage: "xmark.circle")
                        }
                        .buttonStyle(PrimaryButtonStyle())
                        .accessibilityIdentifier("demoTurnOff")
                        Button("Keep demo") { dismiss() }
                            .buttonStyle(SecondaryButtonStyle())
                            .accessibilityIdentifier("demoKeep")
                    }
                    .padding(Tokens.Space.gutter)
                    .background(Color.surface)
                }
            }
            .navigationTitle(model.backendStatus == .demoForced ? "Demo mode" : "Demo data")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } } }
        }
    }
}


struct IncomingFile: Identifiable {
    let url: URL
    var id: String { url.absoluteString }
}

struct IdentifiedPoint: Identifiable {
    let point: LatLng
    var id: String { "\(point.lat),\(point.lng)" }
}
