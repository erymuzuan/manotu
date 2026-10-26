import SwiftUI

/// Idle screen: full-bleed map, menu top-left, round FABs top-right, and the home panel at the bottom
/// (boards HomeIntai / HomeSejarah / HomePenuh). Peek (search + one row of chips) is the default, so the map
/// keeps ~80 % of the screen; speed, vehicle, recentre and report sit just above the panel.
struct HomeView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        @Bindable var model = model
        GeometryReader { geo in
            let ax = typeSize.isAccessibilitySize
            let inset = geo.safeAreaInsets.bottom
            let panel = HomePanelMetrics.height(model.homeDetent, available: geo.size.height, accessibilitySize: ax) + inset
            ZStack(alignment: .bottom) {
                VStack {
                    HStack(alignment: .top) {
                        MenuButton { model.showMenu = true }
                        Spacer()
                        VStack(spacing: 12) {
                            SoundFab()
                            LayersButton()
                        }
                    }
                    .padding(.horizontal, Tokens.Space.gutter)
                    .padding(.top, 8)
                    if model.homeDetent != .full, let area = model.map.visibleSearchArea {
                        Button("Search this area") {
                            model.searchViewport = area
                            model.screen = .search(.destination)
                        }
                        .buttonStyle(.borderedProminent)
                        .accessibilityIdentifier("searchThisArea")
                    }
                    // After installing from an invitation page (§5.6): one tap to paste the copied link.
                    if model.events.showDeferredLinkCard && model.homeDetent != .full {
                        EventDeferredLinkCard()
                            .background(Color.surface, in: RoundedRectangle(cornerRadius: Tokens.Radius.md, style: .continuous))
                            .fabShadow()
                            .padding(.horizontal, Tokens.Space.gutter)
                            .padding(.top, Tokens.Space.s)
                            .transition(.move(edge: .top).combined(with: .opacity))
                    }
                    Spacer()
                }

                if model.homeDetent != .full {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(alignment: .bottom) {
                            HStack(alignment: .center, spacing: 8) {
                                Speedometer(speedKmh: model.speedKmh)
                                VehiclePill()
                            }
                            Spacer()
                            VStack(spacing: 10) {
                                if !model.map.isFollowing {
                                    RoundFab(icon: .logo, accessibilityLabel: "Recenter", stroke: .brand, fill: .brand) { model.recenter() }
                                }
                                ReportFab { model.showReport = true }
                            }
                        }
                        OSMAttribution()
                    }
                    .padding(.horizontal, Tokens.Space.gutter)
                    .padding(.bottom, panel + 8)
                    // Map controls keep their size at accessibility text sizes so the peek map stays usable.
                    .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
                    .transition(.opacity)
                }

                HomeSheet(detent: $model.homeDetent, maxHeight: geo.size.height, bottomInset: inset)
            }
            .ignoresSafeArea(edges: .bottom)
            .onAppear { updateMapInset(geo: geo, ax: ax) }
            .onChange(of: model.homeDetent) { updateMapInset(geo: geo, ax: ax) }
            .onChange(of: ax) { updateMapInset(geo: geo, ax: ax) }
            .onDisappear { model.map.homeBottomInset = 0 }
        }
        .animation(.snappy, value: model.homeDetent)
    }

    /// The map centres the puck in what the panel leaves visible (Full keeps the Half inset: the map is hidden anyway).
    private func updateMapInset(geo: GeometryProxy, ax: Bool) {
        let d: HomeDetent = model.homeDetent == .full ? .half : model.homeDetent
        model.map.homeBottomInset = Double(HomePanelMetrics.height(d, available: geo.size.height, accessibilitySize: ax) + geo.safeAreaInsets.bottom)
    }
}

struct LayersButton: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        Menu {
            Button {
                model.recenter()
            } label: { Label("Center on me", systemImage: "location.fill") }
            Button {
                Task { await model.live.refresh() }
            } label: { Label("Refresh traffic & reports", systemImage: "arrow.clockwise") }
        } label: {
            GimanoIcon(icon: .layers, size: Tokens.Size.fabIcon)
                .frame(width: Tokens.Size.fab, height: Tokens.Size.fab)
                .background(Color.surface, in: Circle())
                .fabShadow()
        }
        .accessibilityLabel(Text("Layers"))
    }
}

struct VehiclePill: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        Button {
            model.vehicle = model.vehicle == .car ? .motorcycle : .car
            model.updateProfile(UserPatch(vehicle: model.vehicle))
        } label: {
            Image(systemName: model.vehicle == .car ? "car.fill" : "motorcycle")
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(Color.brandInk)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(Color.surface, in: Capsule())
                .fabShadow()
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(model.vehicle == .car ? "Car" : "Motorbike"))
    }
}

/// Home panel with three detents: Peek (default), Half (Terkini first) and Full.
struct HomeSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dynamicTypeSize) private var typeSize
    @Binding var detent: HomeDetent
    let maxHeight: CGFloat
    let bottomInset: CGFloat
    @GestureState private var drag: CGFloat = 0

    private var ax: Bool { typeSize.isAccessibilitySize }

    private func height(_ d: HomeDetent) -> CGFloat {
        HomePanelMetrics.height(d, available: maxHeight, accessibilitySize: ax)
    }

    var body: some View {
        let gap = HomePanelMetrics.gap(accessibilitySize: ax)
        let h = max(height(.peek) - 24, min(height(.full), height(detent) - drag))
        let radius: CGFloat = detent == .full ? 0 : 26
        VStack(spacing: 0) {
            handle
                .padding(.top, HomePanelMetrics.handleTop)
                .padding(.bottom, gap)
            HomeSearchBar()
                .padding(.horizontal, 14)
            if detent != .full {
                HomeChips(rows: HomePanelMetrics.chipRows(accessibilitySize: ax))
                    .padding(.top, gap)
            }
            if detent != .peek {
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        HomeRecents(limit: detent == .full ? 8 : 6)
                        if detent == .full {
                            HomeSavedPlaces()
                            HomeCategoryGrid()
                            HomePrivacyCard()
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.top, 14)
                    .padding(.bottom, bottomInset + 24)
                }
                .scrollDisabled(detent != .full)
                .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: h + bottomInset, alignment: .top)
        .clipped()
        .background(
            UnevenRoundedRectangle(topLeadingRadius: radius, topTrailingRadius: radius)
                .fill(Color.surface)
                .shadow(color: Color(red: 11 / 255, green: 27 / 255, blue: 58 / 255).opacity(0.14), radius: 9, y: -4)
        )
        .contentShape(Rectangle())
        .gesture(panelDrag)
    }

    private var panelDrag: some Gesture {
        DragGesture(minimumDistance: 8, coordinateSpace: .global)
            .updating($drag) { v, s, _ in s = v.translation.height }
            .onEnded { v in
                detent = HomePanelMetrics.snap(from: detent, predictedTranslation: v.predictedEndTranslation.height,
                                               available: maxHeight, accessibilitySize: ax)
            }
    }

    /// Grab handle: tap cycles Peek → Half → Full → Peek; VoiceOver swipes up/down to expand/collapse.
    private var handle: some View {
        // Not a Button: on a real device a button swallows the drag that starts on the handle.
        GrabHandle()
            .frame(maxWidth: .infinity, minHeight: HomePanelMetrics.handleHeight)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
            .onTapGesture { detent = detent.next }
            .gesture(panelDrag)
            .padding(.vertical, -10)
            .accessibilityElement()
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { detent = detent.next }
            .accessibilityLabel(Text(handleLabel))
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: detent = detent.expanded
            case .decrement: detent = detent.collapsed
            @unknown default: break
            }
        }
        .accessibilityIdentifier("homePanelHandle")
    }

    private var handleLabel: LocalizedStringKey {
        switch detent {
        case .peek: "Search panel, collapsed. Swipe up for recent places."
        case .half: "Search panel, half open. Swipe up for saved places and categories."
        case .full: "Search panel, expanded. Swipe down to show the map."
        }
    }
}

/// "Where to?" field (52 pt): always visible, one tap from every detent.
struct HomeSearchBar: View {
    @Environment(AppModel.self) private var model
    @ScaledMetric(relativeTo: .body) private var font: CGFloat = HomePanelMetrics.searchFont

    var body: some View {
        Button {
            model.screen = .search(.destination)
        } label: {
            HStack(spacing: 10) {
                GimanoIcon(icon: .search, size: 24, stroke: .brand, fill: .brandTint)
                Text("Where to?")
                    .font(.custom(Tokens.Font.Weight.black.postScriptName, fixedSize: min(font, HomePanelMetrics.searchFontMax)))
                    .foregroundStyle(Color.textMuted)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Spacer(minLength: 4)
                GimanoIcon(icon: .mic, size: 24, stroke: .brand, fill: .brandMist)
            }
            .padding(.horizontal, 14)
            .frame(height: HomePanelMetrics.searchHeight)
            .background(Color.appBackground, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Color.outline, lineWidth: 2))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("Where to?"))
        .accessibilityIdentifier("whereTo")
    }
}

/// One shortcut on the home panel (chip row, category grid).
struct HomeShortcut: Identifiable {
    enum Style { case saved, favorite, category }
    let id: String
    let icon: FlatIcon
    let title: Text
    let style: Style
    let action: () -> Void
}

struct HomeCategory {
    let icon: FlatIcon
    let title: LocalizedStringKey
    let category: PlaceCategory
}

extension AppModel {
    /// Home and Work: plan the route, or set them first.
    func openSaved(_ saved: SavedPlace?, purpose: SearchPurpose) {
        if let saved { navigate(to: saved) } else { screen = .search(purpose) }
    }

    /// Opens search pre-filtered to a category (nil: plain search).
    func openCategory(_ c: PlaceCategory?) {
        searchCategory = c
        screen = .search(.destination)
    }

    /// Category shortcuts, in board order (chips after the saved places; the 4×2 grid adds "More").
    var homeCategories: [HomeCategory] {
        [HomeCategory(icon: .fuel, title: "Fuel", category: .fuel),
         HomeCategory(icon: .food, title: "Food", category: .restaurant),
         HomeCategory(icon: .surau, title: "Surau", category: .surau),
         HomeCategory(icon: .parking, title: "Parking", category: .parking),
         HomeCategory(icon: .ev, title: "EV", category: .evCharging),
         HomeCategory(icon: .atm, title: "ATM", category: .atm),
         HomeCategory(icon: .shop, title: "Shop", category: .convenience)]
    }

    /// Rumah, Kerja, the saved favourites (gold star), then categories.
    var homeChips: [HomeShortcut] {
        var out: [HomeShortcut] = [
            HomeShortcut(id: "shortcut.home", icon: .home, title: Text("Home"), style: .saved) { [unowned self] in openSaved(home, purpose: .setHome) },
            HomeShortcut(id: "shortcut.work", icon: .work, title: Text("Work"), style: .saved) { [unowned self] in openSaved(work, purpose: .setWork) },
        ]
        out += favorites.map { f in
            HomeShortcut(id: "favoriteTile.\(f.name)", icon: .star, title: Text(verbatim: f.name), style: .favorite) { [unowned self] in navigate(to: f) }
        }
        out += homeCategories.map { c in
            HomeShortcut(id: "shortcut.\(c.icon.rawValue)", icon: c.icon, title: Text(c.title), style: .category) { [unowned self] in openCategory(c.category) }
        }
        return out
    }
}

/// Horizontally scrolling pill chips (44 pt, 26 pt icons). At accessibility text sizes they wrap to 2 rows.
struct HomeChips: View {
    @Environment(AppModel.self) private var model
    let rows: Int

    var body: some View {
        let chips = model.homeChips
        ScrollView(.horizontal, showsIndicators: false) {
            Group {
                if rows <= 1 {
                    HStack(spacing: HomePanelMetrics.chipGap) { ForEach(chips) { HomeChip(item: $0) } }
                } else {
                    LazyHGrid(rows: Array(repeating: GridItem(.fixed(HomePanelMetrics.chipHeight), spacing: 6, alignment: .leading), count: rows),
                              alignment: .top, spacing: HomePanelMetrics.chipGap) {
                        ForEach(chips) { HomeChip(item: $0) }
                    }
                }
            }
            .padding(.horizontal, 14)
        }
        .frame(height: CGFloat(rows) * HomePanelMetrics.chipHeight + CGFloat(rows - 1) * 6)
    }
}

struct HomeChip: View {
    let item: HomeShortcut
    @ScaledMetric(relativeTo: .footnote) private var font: CGFloat = HomePanelMetrics.chipFont

    var body: some View {
        let (bg, fg): (Color, Color) = switch item.style {
        case .saved: (.brandMist, .brandInk)
        case .favorite: (.amberMist, .amberInk)
        case .category: (.appBackground, .textMuted)
        }
        Button(action: item.action) {
            HStack(spacing: 6) {
                FlatIconView(icon: item.icon, size: 26)
                item.title
                    .font(.custom(Tokens.Font.Weight.bold.postScriptName, fixedSize: min(font, HomePanelMetrics.chipFontMax)))
                    .lineLimit(1)
                    .fixedSize()
            }
            .foregroundStyle(fg)
            .padding(.leading, 10)
            .padding(.trailing, 14)
            .frame(height: HomePanelMetrics.chipHeight)
            .background(bg, in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(item.id)
    }
}

/// Uppercase section header (TERKINI, TEMPAT DISIMPAN, KATEGORI).
struct HomeSectionHeader<Trailing: View>: View {
    let title: LocalizedStringKey
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack {
            Text(title)
                .textCase(.uppercase)
                .font(Tokens.Font.nunito(12, .black, relativeTo: .caption))
                .tracking(0.6)
                .foregroundStyle(Color.sectionLabel)
                .accessibilityAddTraits(.isHeader)
            Spacer()
            trailing
        }
        .padding(.top, 4)
    }
}

extension HomeSectionHeader where Trailing == EmptyView {
    init(title: LocalizedStringKey) { self.init(title: title) { EmptyView() } }
}

/// Panel list row: 38 pt icon tile · name / address · distance (boards HomeSejarah / HomePenuh).
struct HomePanelRow: View {
    let icon: FlatIcon
    var tile: Color = .recentTile
    let title: String
    let subtitle: String
    var distanceM: Double?

    var body: some View {
        HStack(spacing: 12) {
            FlatIconView(icon: icon, size: 28)
                .frame(width: 38, height: 38)
                .background(tile, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(Tokens.Font.nunito(15, .black)).foregroundStyle(Color.textPrimary).lineLimit(1)
                Text(subtitle).font(Tokens.Font.nunito(12, .extrabold, relativeTo: .caption)).foregroundStyle(Color.textMuted).lineLimit(1)
            }
            Spacer(minLength: 8)
            if let distanceM {
                Text(ManeuverFormatter.distance(distanceM))
                    .font(Tokens.Font.nunito(12, .black, relativeTo: .caption).monospacedDigit())
                    .foregroundStyle(Color.textMuted)
            }
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 2)
        .overlay(alignment: .bottom) { Rectangle().fill(Color.rowDivider).frame(height: 1) }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

/// TERKINI: recent destinations (on this phone only), first thing after swiping up.
struct HomeRecents: View {
    @Environment(AppModel.self) private var model
    let limit: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HomeSectionHeader(title: "Recent").padding(.bottom, 4)
            if model.recents.isEmpty {
                Text("No recent places yet")
                    .font(Tokens.Font.caption)
                    .foregroundStyle(Color.textMuted)
                    .padding(.vertical, 8)
            }
            ForEach(model.recents.prefix(limit)) { r in
                Button {
                    model.planRoute(to: Destination(name: r.name, address: r.address, location: r.location, placeId: r.placeId), quickPick: true)
                } label: {
                    HomePanelRow(icon: .recent, title: r.name, subtitle: r.address, distanceM: Geo.distance(model.position, r.location))
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("recentRow")
            }
        }
    }
}

/// TEMPAT DISIMPAN: Home, Work and favourites (gold star), on this phone only.
struct HomeSavedPlaces: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HomeSectionHeader(title: "Saved places") {
                Button("Edit") { model.menuSheet = .favorites }
                    .font(Tokens.Font.nunito(13, .extrabold, relativeTo: .footnote))
                    .foregroundStyle(Color.brand)
                    .accessibilityLabel(Text("Edit favourites"))
                    .accessibilityIdentifier("editFavorites")
            }
            .padding(.bottom, 4)
            savedRow(model.home, icon: .home, title: String(localized: "Home"), unset: String(localized: "Set home address"), purpose: .setHome)
            savedRow(model.work, icon: .work, title: String(localized: "Work"), unset: String(localized: "Set work address"), purpose: .setWork)
            ForEach(model.favorites) { f in
                Button { model.navigate(to: f) } label: {
                    HomePanelRow(icon: .star, tile: .amberMist, title: f.name, subtitle: f.address, distanceM: Geo.distance(model.position, f.location))
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("savedRow.\(f.name)")
            }
        }
    }

    private func savedRow(_ p: SavedPlace?, icon: FlatIcon, title: String, unset: String, purpose: SearchPurpose) -> some View {
        Button { model.openSaved(p, purpose: purpose) } label: {
            HomePanelRow(icon: icon, tile: .brandMist, title: title, subtitle: p?.address ?? unset,
                         distanceM: p.map { Geo.distance(model.position, $0.location) })
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("savedRow.\(icon.rawValue)")
    }
}

/// KATEGORI: 4×2 grid of 76 pt tiles, 32 pt icons, 11 pt labels.
struct HomeCategoryGrid: View {
    @Environment(AppModel.self) private var model
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 8), count: 4)

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HomeSectionHeader(title: "Categories")
            LazyVGrid(columns: columns, spacing: 8) {
                ForEach(model.homeCategories, id: \.icon) { c in
                    tile(c.icon, c.title) { model.openCategory(c.category) }
                }
                tile(.more, "More") { model.openCategory(nil) }
            }
        }
    }

    private func tile(_ icon: FlatIcon, _ title: LocalizedStringKey, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 4) {
                FlatIconView(icon: icon, size: 32)
                Text(title)
                    .font(Tokens.Font.nunito(11, .bold, relativeTo: .caption2))
                    .foregroundStyle(Color.tileLabel)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            .frame(maxWidth: .infinity, minHeight: 76)
            .background(Color.appBackground, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("category.\(icon.rawValue)")
    }
}

/// Privacy reminder at the end of the full panel.
struct HomePrivacyCard: View {
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "lock.fill")
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(Color.brand)
                .accessibilityHidden(true)
            Text("Recent and saved places stay on this phone. Manotu never sees them.")
                .font(Tokens.Font.nunito(14, .bold, relativeTo: .footnote))
                .foregroundStyle(Color.brandInk)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.brandMist, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .padding(.top, 8)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("homePrivacyCard")
    }
}

/// Shared list row: icon tile · name / address · distance right-aligned.
struct PlaceRow: View {
    var gIcon: GIcon?
    var category: PlaceCategory?
    var title: String
    var subtitle: String
    var distanceM: Double?

    var body: some View {
        HStack(spacing: 12) {
            Group {
                if let gIcon {
                    GimanoIcon(icon: gIcon, size: 26)
                        .frame(width: 44, height: 44)
                        .background(Color.brandMist, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                } else {
                    CategoryIcon(category: category ?? .other)
                }
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(Tokens.Font.bodyBold).foregroundStyle(Color.textPrimary).lineLimit(1)
                Text(subtitle).font(Tokens.Font.caption).foregroundStyle(Color.textMuted).lineLimit(1)
            }
            Spacer(minLength: 8)
            if let distanceM {
                Text(ManeuverFormatter.distance(distanceM))
                    .font(Tokens.Font.label.monospacedDigit())
                    .foregroundStyle(Color.textMuted)
            }
        }
        .padding(.horizontal, Tokens.Space.gutter)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
    }
}
