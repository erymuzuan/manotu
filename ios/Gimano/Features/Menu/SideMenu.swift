import SwiftUI

struct SideMenu: View {
    @Environment(AppModel.self) private var model
    let onSelect: (MenuDestination) -> Void

    @State private var versionTaps: [Date] = []

    /// 7 quick taps on the version copies a diagnostics summary (no personal data) for support.
    private func versionTapped() {
        let now = Date()
        versionTaps = versionTaps.filter { now.timeIntervalSince($0) < 3 } + [now]
        guard versionTaps.count >= 7 else { return }
        versionTaps = []
        UIPasteboard.general.string = AppInfo.diagnostics(model: model)
        model.showToast(String(localized: "Diagnostics copied"))
    }

    var body: some View {
        ZStack(alignment: .leading) {
            Color.black.opacity(0.35)
                .ignoresSafeArea()
                .onTapGesture { model.showMenu = false }

            VStack(alignment: .leading, spacing: 0) {
                Button { onSelect(.profile) } label: {
                    HStack(spacing: 14) {
                        Text(model.user?.mood ?? "🙂")
                            .font(.system(size: 30))
                            .frame(width: 56, height: 56)
                            .background(Color.brand.opacity(0.15), in: Circle())
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Hi, \(model.user?.displayName ?? String(localized: "driver"))")
                                .font(Tokens.Font.title)
                                .lineLimit(1)
                            Text("View profile").font(Tokens.Font.caption).foregroundStyle(Color.brand)
                        }
                    }
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 20)
                .padding(.top, 20)
                .padding(.bottom, 24)

                Divider()

                actionRow("Favourites", icon: "star.fill", id: "menuFavorites") { model.showMenu = false; model.menuSheet = .favorites }
                actionRow("Add a place", icon: "mappin.and.ellipse", id: "menuAddPlace") { model.showMenu = false; model.addPlaceStart = model.position }
                actionRow("My contributions", icon: "person.crop.rectangle.stack.fill", id: "menuContributions") { model.showMenu = false; model.menuSheet = .contributions }
                row("Planned drives", icon: "calendar", .planned)
                actionRow("Events", icon: "party.popper.fill", id: "menuEvents") { model.showMenu = false; model.events.open() }
                actionRow("My routes", icon: "point.topleft.down.to.point.bottomright.curvepath", id: "menuMyRoutes") {
                    model.showMenu = false
                    model.events.openMyRoutes()
                }
                inboxRow
                row("Settings", icon: "gearshape.fill", .settings)
                actionRow("Add feedback", icon: "bubble.left.and.text.bubble.right.fill", id: "menuAddFeedback") {
                    model.showMenu = false
                    Task {
                        // Let the menu close so the screenshot shows the map, not the menu.
                        try? await Task.sleep(for: .milliseconds(450))
                        model.openFeedback(from: .home)
                    }
                }
                actionRow("My feedback", icon: "tray.full.fill", id: "menuMyFeedback") { model.showMenu = false; model.menuSheet = .myFeedback }
                actionRow("Backup & restore", icon: "arrow.clockwise.icloud.fill", id: "menuBackup") { model.showMenu = false; model.menuSheet = .backup }
                row("Help and feedback", icon: "questionmark.circle.fill", .help)
                #if DEBUG
                row("Developer settings", icon: "hammer.fill", .debug)
                #endif

                Spacer()
                VStack(alignment: .leading, spacing: 4) {
                    Text(verbatim: "\(AppInfo.name) \(AppInfo.versionString)")
                        .accessibilityIdentifier("menuVersion")
                        .onTapGesture { versionTapped() }
                    Text("Gimano code is open source (MIT) · Map data © OpenStreetMap contributors")
                }
                .font(Tokens.Font.nunito(11, .semibold))
                .foregroundStyle(Color.textMuted)
                .padding(20)
            }
            .foregroundStyle(Color.textPrimary)
            .frame(width: 300)
            .frame(maxHeight: .infinity)
            .background(Color.surface.ignoresSafeArea())
        }
    }

    private var inboxRow: some View {
        Button { onSelect(.inbox) } label: {
            HStack(spacing: 16) {
                Image(systemName: "tray.fill").frame(width: 24).foregroundStyle(Color.textMuted)
                Text("Inbox").font(Tokens.Font.body)
                Spacer()
                if model.inboxUnread > 0 {
                    Text("\(model.inboxUnread)")
                        .font(Tokens.Font.nunito(13, .black))
                        .foregroundStyle(Color.reportOn)
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(Color.report, in: Capsule())
                        .accessibilityIdentifier("inboxBadge")
                }
            }
            .padding(.horizontal, 20)
            .frame(height: 54)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("menuInbox")
    }

    private func actionRow(_ title: LocalizedStringKey, icon: String, id: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 16) {
                Image(systemName: icon).frame(width: 24).foregroundStyle(Color.textMuted)
                Text(title).font(Tokens.Font.body)
                Spacer()
            }
            .padding(.horizontal, 20)
            .frame(height: 54)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(id)
    }

    private func row(_ title: LocalizedStringKey, icon: String, _ dest: MenuDestination) -> some View {
        Button { onSelect(dest) } label: {
            HStack(spacing: 16) {
                Image(systemName: icon).frame(width: 24).foregroundStyle(Color.textMuted)
                Text(title).font(Tokens.Font.body)
                Spacer()
            }
            .padding(.horizontal, 20)
            .frame(height: 54)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("menu.\(dest.rawValue)")
    }
}

struct MenuDestinationView: View {
    let destination: MenuDestination
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                switch destination {
                case .profile: ProfileView()
                case .planned: PlannedDrivesView()
                case .inbox: InboxView()
                case .settings: SettingsView()
                case .help: HelpView()
                case .debug:
                    #if DEBUG
                    DebugSettingsView()
                    #else
                    EmptyView()
                    #endif
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } }
            }
        }
    }
}

struct ProfileView: View {
    @Environment(AppModel.self) private var model
    @State private var name = ""
    private let moods = ["🙂", "😎", "🤠", "😇", "😴", "🥳", "🤓", "😤"]

    var body: some View {
        Form {
            Section("Display name") {
                TextField("Name", text: $name)
                    .onSubmit { model.updateProfile(UserPatch(displayName: name)) }
            }
            Section("Mood") {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack {
                        ForEach(moods, id: \.self) { m in
                            Button { model.updateProfile(UserPatch(mood: m)) } label: {
                                Text(m).font(.system(size: 30))
                                    .padding(6)
                                    .background(model.user?.mood == m ? Color.brand.opacity(0.2) : .clear, in: Circle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            Section("Vehicle") {
                Picker("Vehicle", selection: Binding(get: { model.vehicle }, set: { model.updateProfile(UserPatch(vehicle: $0)) })) {
                    Text("Car").tag(Vehicle.car)
                    Text("Motorbike").tag(Vehicle.motorcycle)
                }
                .pickerStyle(.segmented)
            }
            if let u = model.user {
                Section("Stats") {
                    LabeledContent("Points", value: "\(u.points ?? 0)")
                    LabeledContent("Level", value: "\(u.level ?? 1)")
                }
            }
        }
        .navigationTitle("Profile")
        .onAppear { name = model.user?.displayName ?? "" }
    }
}

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openURL) private var openURL

    var body: some View {
        @Bindable var model = model
        Form {
            Section {
                PrivacyCard().listRowInsets(EdgeInsets())
                NavigationLink("Backup & restore") { BackupView() }.accessibilityIdentifier("settingsBackup")
            }
            Section {
                NavigationLink { SafetySettingsView() } label: { Label("Safety", systemImage: "checkmark.shield") }
                    .accessibilityIdentifier("settingsSafety")
            }
            Section("Theme") {
                ThemePicker()
            }
            Section("Sound") {
                Picker("Voice guidance", selection: $model.soundMode) {
                    ForEach(SoundMode.allCases, id: \.self) { Text($0.title).tag($0) }
                }
            }
            Section {
                Toggle("Demo mode", isOn: Binding(get: { model.config.isDemoMode }, set: { model.setDemoMode($0) }))
                    .accessibilityIdentifier("demoModeToggle")
            } footer: {
                Text("Try Manotu anywhere, no account: built-in sample data and a simulated drive. Nothing is sent to the server.")
            }
            Section {
                Toggle("Start navigation automatically", isOn: $model.autoStartNav)
                    .accessibilityIdentifier("autoStartNav")
            } footer: {
                Text("After 10 s on the route preview, for Home, Work, favourites, recent places and planned drives. Never after a search.")
            }
            Section {
                LanguagePicker()
                Button("Language settings for Gimano") {
                    if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                }
            } header: {
                Text("Language")
            } footer: {
                Text("English is the default; Gimano uses Malay when your phone or this setting says so. A change applies the next time you open Gimano.")
            }
            Section("Units") {
                LabeledContent("Distance", value: "km")
                LabeledContent("Speed", value: "km/h")
            }
            Section {
                NavigationLink { AccountView() } label: { Label("Account", systemImage: "person.crop.circle") }
                    .accessibilityIdentifier("settingsAccount")
                NavigationLink { BlockedUsersView() } label: { Label("Blocked users", systemImage: "person.crop.circle.badge.xmark") }
                    .accessibilityIdentifier("settingsBlocked")
                NavigationLink { AboutView() } label: { Label("About Gimano", systemImage: "info.circle") }
                    .accessibilityIdentifier("settingsAbout")
                LabeledContent("Version", value: AppInfo.versionString)
                LabeledContent("Server", value: model.config.serverLabel)
                    .accessibilityIdentifier("serverHost")
                if let name = model.user?.displayName {
                    LabeledContent("Your pseudonym", value: name).accessibilityIdentifier("pseudonym")
                }
            }
            #if DEBUG
            Section {
                NavigationLink("Developer settings") { DebugSettingsView() }
            }
            #endif
        }
        .navigationTitle("Settings")
    }
}

struct HelpView: View {
    @Environment(\.openURL) private var openURL
    var body: some View {
        List {
            Section("About") {
                Text("Gimano is a community-driven navigation app for Malaysia, built on OpenStreetMap data. Gimano's own code is open source (MIT).")
            }
            Section("Attribution") {
                Button("© OpenStreetMap contributors (ODbL)") { openURL(URL(string: "https://www.openstreetmap.org/copyright")!) }
                Button("Map tiles: OpenFreeMap") { openURL(URL(string: "https://openfreemap.org")!) }
                Button("Map renderer: MapLibre Native") { openURL(URL(string: "https://maplibre.org")!) }
            }
        }
        .navigationTitle("Help and feedback")
    }
}

struct OnboardingView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 24) {
            Spacer()
            Image(systemName: "location.north.circle.fill")
                .font(.system(size: 96))
                .foregroundStyle(Color.brandOn, Color.brand)
            Text("Welcome to Gimano").font(Tokens.Font.nunito(30, .extrabold))
            Text("Drive smarter with reports from drivers around you. Gimano needs your location to show where you are and guide you turn by turn.")
                .font(Tokens.Font.body)
                .multilineTextAlignment(.center)
                .foregroundStyle(Color.textMuted)
                .padding(.horizontal, 32)
            PrivacyCard(onBackup: {
                model.finishOnboarding(allowLocation: false)
                model.menuSheet = .backup
            })
            .padding(.horizontal, 24)
            Spacer()
            VStack(spacing: 12) {
                Button("Continue") { model.finishOnboarding(allowLocation: true) }
                    .buttonStyle(PrimaryButtonStyle())
                Button("Not now") { model.finishOnboarding(allowLocation: false) }
                    .buttonStyle(SecondaryButtonStyle())
                // Offered, never automatic: opens Backup & restore; nothing changes until the user picks a backup
                // and confirms Merge or Replace.
                Button {
                    model.finishOnboarding(allowLocation: true)
                    model.restoreOnFirstRun = true
                    model.menuSheet = .backup
                } label: {
                    Label("Restore from backup", systemImage: "arrow.uturn.backward.circle")
                        .font(Tokens.Font.label)
                }
                .accessibilityIdentifier("onboardingRestore")
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 24)
        }
        .background(Color.surface.ignoresSafeArea())
    }
}

/// Big icon tiles: Light (default) · Dark · Follow phone · Auto day/night.
struct ThemePicker: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 2), spacing: 12) {
                ForEach(ThemeMode.allCases) { t in
                    let on = model.theme == t
                    Button { model.theme = t } label: {
                        VStack(alignment: .leading, spacing: 8) {
                            ThemePreview(mode: t)
                                .frame(height: 110)
                                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                            Label { Text(t.title).font(Tokens.Font.bodyBold) } icon: { Image(systemName: t.systemImage) }
                                .lineLimit(1).minimumScaleFactor(0.8)
                            Text(t.subtitle).font(Tokens.Font.small).foregroundStyle(Color.textMuted).lineLimit(1)
                        }
                        .foregroundStyle(Color.textPrimary)
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .selectableTile(on, radius: 20, tint: .surface, width: 3)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("theme.\(t.rawValue)")
                }
            }
            Text("Light is the default: easier to read in sunshine while driving, even when your phone is in dark mode. The map changes too.")
                .font(Tokens.Font.caption).foregroundStyle(Color.textMuted)
        }
        .listRowBackground(Color.clear)
        .listRowInsets(EdgeInsets())
    }
}

/// A tiny drawing of the home screen in that theme (board "Tema").
private struct ThemePreview: View {
    let mode: ThemeMode

    var body: some View {
        switch mode {
        case .light: mini(dark: false)
        case .dark: mini(dark: true)
        case .system, .auto:
            HStack(spacing: 0) { mini(dark: false); mini(dark: true) }
        }
    }

    private func mini(dark: Bool) -> some View {
        let bg = Color(uiColor: UIColor(hex: dark ? 0x0B1220 : 0xEEF2F8))
        let card = Color(uiColor: UIColor(hex: dark ? 0x121B2E : 0xFFFFFF))
        let accent = Color(uiColor: UIColor(hex: dark ? 0x5B8DEF : 0x0047AB))
        return ZStack(alignment: .bottom) {
            bg
            Path { p in p.move(to: CGPoint(x: 8, y: 70)); p.addCurve(to: CGPoint(x: 140, y: 20), control1: CGPoint(x: 50, y: 20), control2: CGPoint(x: 90, y: 80)) }
                .stroke(accent, style: StrokeStyle(lineWidth: 4, lineCap: .round))
            RoundedRectangle(cornerRadius: 8).fill(card).frame(height: 30).padding(6)
                .overlay(alignment: .leading) { Capsule().fill(accent.opacity(0.5)).frame(width: 40, height: 6).padding(.leading, 16) }
        }
    }
}

/// Menu → Inbox: news about your public contributions + announcements.
struct InboxView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openURL) private var openURL
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        List {
            if model.inboxItems.isEmpty {
                ContentUnavailableView("Inbox is empty", systemImage: "tray",
                                       description: Text(model.inboxAvailable
                                                         ? "News about places you added, reviews and reports you shared will appear here."
                                                         : "Inbox isn't available on the server yet. News about your public contributions will appear here."))
                    .accessibilityIdentifier("inboxEmpty")
            }
            if !model.inboxItems.isEmpty {
                Text("News about your contributions: places, reviews, reports and feedback.")
                    .font(Tokens.Font.caption).foregroundStyle(Color.textMuted)
                    .listRowBackground(Color.clear)
            }
            ForEach(model.inboxItems) { item in
                Button { open(item) } label: {
                    HStack(alignment: .top, spacing: 12) {
                        GimanoIcon(icon: item.kind.icon, size: 28)
                            .frame(width: 48, height: 48)
                            .background(item.kind.tint, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        VStack(alignment: .leading, spacing: 3) {
                            Text(item.title).font(Tokens.Font.bodyBold).foregroundStyle(Color.textPrimary)
                            if let b = item.body { Text(b).font(Tokens.Font.caption).foregroundStyle(Color.textMuted) }
                            Text(item.createdAt.formatted(.relative(presentation: .named))).font(Tokens.Font.small).foregroundStyle(Color.textMuted)
                        }
                        Spacer()
                        if item.read != true {
                            Circle().fill(Color.report).frame(width: 10, height: 10).accessibilityLabel(Text("Unread"))
                        }
                    }
                }
                .accessibilityIdentifier("inboxItem")
                .listRowBackground(
                    HStack(spacing: 0) {
                        if item.read != true { Color.report.frame(width: 4) }
                        Color.surface
                    }
                )
            }
        }
        .navigationTitle("Inbox")
        .toolbar {
            if model.inboxUnread > 0 {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Mark all as read") { model.markInboxRead() }
                        .font(Tokens.Font.label)
                        .accessibilityIdentifier("inboxMarkAllRead")
                }
            }
        }
        .refreshable { await model.refreshInbox() }
        .task {
            await model.refreshInbox()
            // Let the unread dots show briefly, then mark as read.
            try? await Task.sleep(for: .seconds(2))
            model.markInboxRead()
        }
    }

    private func open(_ item: InboxItem) {
        switch item.refType {
        case "place":
            if let id = item.refId {
                dismiss()
                model.openPlace(PlaceSummary(id: id, name: item.title, category: .other, address: "", lat: model.position.lat, lng: model.position.lng))
            }
        case "url":
            if let s = item.refId, let url = URL(string: s) { openURL(url) }
        case "feedback":
            dismiss()
            model.menuSheet = .myFeedback
        default:
            break
        }
    }
}

extension InboxKind {
    /// Board tints: published = teal, thanks = coral, helpful = amber, everything else cobalt.
    var tint: Color {
        switch self {
        case .placePublished, .editAccepted, .issueConfirmed, .issueResolved: .tealMist
        case .reportThanked: .coralMist
        case .reviewHelpful: .amberMist
        default: .brandMist
        }
    }

    var icon: GIcon {
        switch self {
        case .placePublished: .map
        case .placeRejected: .close
        case .reportThanked: .heart
        case .reviewHelpful: .star
        case .editAccepted: .addStop
        case .feedbackStatus: .feedback
        case .issueConfirmed, .issueRefuted, .issueResolved: .hazard
        case .announcement, .unknown: .logo
        }
    }
}

enum AppInfo {
    static var version: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?" }
    static var build: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?" }
    static var versionString: String { "\(version) (\(build))" }

    /// The product name shown to users (formerly Gimano; bundle id, API host and share links are unchanged).
    static let name = "Manotu"
    static let websiteURL = URL(string: "https://manotu.app/")!
    static let privacyURL = URL(string: "https://manotu.app/privacy/")!
    static let termsURL = URL(string: "https://manotu.app/terms/")!
    static let sourceURL = URL(string: "https://github.com/erymuzuan/manotu")!
    static let osmCopyrightURL = URL(string: "https://www.openstreetmap.org/copyright")!

    /// Support summary: device block + server + mode. No location, ids or personal data.
    @MainActor
    static func diagnostics(model: AppModel) -> String {
        let device = DeviceInfoToggle.json(model.currentDevice())
        return """
        \(name) \(versionString)
        server: \(model.config.apiBaseURL.host() ?? "?") · \(model.backendStatus == .online ? "live" : "\(model.backendStatus)")
        device: \(device)
        """
    }

    /// Platform dependencies to disclose (docs/supply-chain.md).
    static var platformComponents: [(String, LocalizedStringKey)] { [
        ("Core Location", "Your position, on the phone. Sent only as anonymous pings while navigating."),
    ] + (ICloudBackupDestination.isEnabled ? [
        ("CloudKit (iCloud)", "Only if you choose iCloud backup: your backup goes to your own iCloud."),
    ] : []) + [
        ("MetricKit", "Crash and hang diagnostics delivered to the app; sent only if you agree."),
        ("App Attest (DeviceCheck)", "Proves a vote comes from a genuine iPhone. No device ID is stored."),
        ("AVFoundation speech", "Spoken directions, generated on the phone."),
        (ICloudBackupDestination.isEnabled || GoogleDriveBackupDestination.isEnabled)
            ? ("UserNotifications, BackgroundTasks", "Planned-drive reminders and daily backups, scheduled on the phone.")
            : ("UserNotifications, BackgroundTasks", "Planned-drive reminders, scheduled on the phone."),
    ] + (GoogleDriveBackupDestination.isEnabled ? [
        ("Google Sign-In (open source)", "Only if you choose Google Drive backup: signs in to your own Drive."),
    ] : []) }

    /// The footer under "Platform components", naming only what this build has.
    static var platformComponentsFooter: LocalizedStringKey {
        switch (GoogleDriveBackupDestination.isEnabled, ICloudBackupDestination.isEnabled) {
        case (true, true): "Apple frameworks that are part of iOS, and Google Sign-In only if you choose Google Drive backup. None of them receives your favourites, places or trips, except your own iCloud backup."
        case (true, false): "Apple frameworks that are part of iOS, and Google Sign-In only if you choose Google Drive backup. None of them receives your favourites, places or trips."
        case (false, true): "Apple frameworks that are part of iOS. None of them receives your favourites, places or trips, except your own iCloud backup."
        case (false, false): "Apple frameworks that are part of iOS. None of them receives your favourites, places or trips."
        }
    }

    static let licences: [(String, String)] = [
        ("MapLibre Native", "BSD-2-Clause"), ("GRDB.swift", "MIT"), ("swift-sodium / libsodium", "ISC"),
        ("ZIPFoundation", "MIT"), ("GoogleSignIn-iOS", "Apache-2.0"), ("libwebp", "BSD-3-Clause"),
        ("Nunito font", "SIL Open Font License 1.1"), ("BIP-39 English wordlist", "MIT"),
        ("Map data © OpenStreetMap contributors", "ODbL 1.0"), ("Basemap: OpenFreeMap", "OpenMapTiles / ODbL"),
    ]
}

/// Settings → About Gimano.
struct AboutView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        List {
            Section {
                HStack(spacing: 14) {
                    GimanoIcon(icon: .logo, size: 40)
                        .frame(width: 60, height: 60)
                        .background(Color.brandMist, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(verbatim: AppInfo.name).font(Tokens.Font.title)
                        Text(verbatim: AppInfo.versionString).font(Tokens.Font.caption).foregroundStyle(Color.textMuted)
                            .accessibilityIdentifier("aboutVersion")
                    }
                }
                LabeledContent("Server") {
                    Text(verbatim: "\(model.config.serverLabel) · \(statusText)")
                }
                .accessibilityIdentifier("aboutServer")
                LabeledContent("Latest version", value: AppInfo.version)
                #if DEBUG
                if let s = UserDefaults.standard.string(forKey: "crash.lastSent") {
                    Text(verbatim: "crash: \(s)").font(Tokens.Font.small).accessibilityIdentifier("debugCrashLastSent")
                }
                if let s = UserDefaults.standard.string(forKey: "recovery.roundTrip") {
                    Text(verbatim: "recovery: \(s)").font(Tokens.Font.small).accessibilityIdentifier("debugRecovery")
                }
                #endif
            } footer: {
                Text("Update checks will appear here once Gimano is on TestFlight / the App Store.")
            }
            Section {
                Link(destination: AppInfo.privacyURL) { Label("Privacy", systemImage: "lock.shield") }
                Link(destination: AppInfo.termsURL) { Label("Terms", systemImage: "doc.text") }
                Link(destination: URL(string: "mailto:privacy@bukitbunga.com")!) {
                    Label { Text(verbatim: "privacy@bukitbunga.com") } icon: { Image(systemName: "envelope") }
                }
                .accessibilityIdentifier("aboutContact")
                Link(destination: AppInfo.sourceURL) { Label("Manotu code is open source (MIT)", systemImage: "chevron.left.forwardslash.chevron.right") }
                NavigationLink { LicencesView() } label: { Label("Licences", systemImage: "text.book.closed") }
            }
            Section {
                ForEach(AppInfo.platformComponents, id: \.0) { name, use in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(verbatim: name).font(Tokens.Font.bodyBold)
                        Text(use).font(Tokens.Font.caption).foregroundStyle(Color.textMuted)
                    }
                }
            } header: {
                Text("Platform components")
            } footer: {
                Text(AppInfo.platformComponentsFooter)
            }
            .accessibilityIdentifier("platformComponents")
            Section {
                Link(destination: AppInfo.osmCopyrightURL) {
                    Text("Map data © OpenStreetMap contributors")
                }
            } footer: {
                Text("Routing by Valhalla. Tiles by OpenFreeMap. No ads, no trackers.")
            }
        }
        .navigationTitle("About Gimano")
    }

    private var statusText: String {
        switch model.backendStatus {
        case .demoForced, .demoFallback: String(localized: "Demo")
        default: String(localized: "Live")
        }
    }
}

struct LicencesView: View {
    var body: some View {
        List(AppInfo.licences, id: \.0) { name, licence in
            LabeledContent(name, value: licence)
        }
        .navigationTitle("Licences")
    }
}

/// "Language: Follow phone / English / Bahasa Melayu".
struct LanguagePicker: View {
    @State private var choice = AppLanguage.choice
    @State private var changed = false

    var body: some View {
        Picker(selection: $choice) {
            ForEach(AppLanguage.allCases, id: \.self) { Text($0.title).tag($0) }
        } label: {
            Text("Language")
        }
        .accessibilityIdentifier("languagePicker")
        .onChange(of: choice) { _, v in
            AppLanguage.choice = v
            changed = true
        }
        if changed {
            Label("Close and reopen Gimano to switch language.", systemImage: "arrow.clockwise")
                .font(Tokens.Font.caption).foregroundStyle(Color.brand)
                .accessibilityIdentifier("languageRestartNote")
        }
    }
}
