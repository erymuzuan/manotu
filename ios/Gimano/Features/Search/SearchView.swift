import SwiftUI

/// Full-screen search: field pinned on top, autocomplete as you type, distance right-aligned.
struct SearchView: View {
    @Environment(AppModel.self) private var model
    let purpose: SearchPurpose

    @State private var query = ""
    @State private var viewport: String?
    @State private var searchFailed = false
    @State private var results: [PlaceSummary] = []
    @State private var corrected: String?
    @State private var didYouMean: [SearchSuggestion] = []
    @State private var exact = false
    @State private var sort: ResultSort = .bestMatch
    @State private var expanded: Set<String> = []
    @State private var searchedOnce = false
    @State private var isSearching = false
    @State private var category: PlaceCategory?
    @FocusState private var focused: Bool

    private static let quickCategories: [(PlaceCategory, LocalizedStringKey)] = [
        (.fuel, "Fuel"), (.restaurant, "Food"), (.surau, "Surau"), (.parking, "Parking"),
        (.evCharging, "EV"), (.restArea, "R&R"), (.tollBooth, "Toll"), (.hospital, "Hospital"),
    ]

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Button {
                    if model.navigation != nil { model.screen = .navigating }
                    else if purpose == .addStop || purpose == .setOrigin, model.planner != nil { model.screen = .routePreview }
                    else { model.go(.home) }
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 20, weight: .semibold))
                        .frame(width: 40, height: 44)
                }
                .foregroundStyle(Color.textPrimary)
                .accessibilityLabel(Text("Back"))

                HStack(spacing: 10) {
                    GimanoIcon(icon: .search, size: 26)
                    TextField(placeholder, text: $query)
                        .font(Tokens.Font.nunito(19, .bold))
                        .focused($focused)
                        .submitLabel(.search)
                        .autocorrectionDisabled()
                        .accessibilityIdentifier("searchField")
                    if !query.isEmpty {
                        Button { query = ""; category = nil } label: {
                            Image(systemName: "xmark.circle.fill").foregroundStyle(Color.textMuted)
                        }
                        .accessibilityLabel(Text("Clear"))
                        .accessibilityIdentifier("searchClear")
                    }
                }
                .padding(.horizontal, 16)
                .frame(height: Tokens.Size.searchField)
                .background(Color.surfaceAlt, in: RoundedRectangle(cornerRadius: Tokens.Radius.searchField, style: .continuous))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            if viewport != nil {
                Text("Searching only the selected map area. Move the map to choose another area.")
                    .font(Tokens.Font.body).padding(.horizontal, 16).padding(.vertical, 8)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(Self.quickCategories, id: \.0) { cat, title in
                        Button {
                            category = category == cat ? nil : cat
                        } label: {
                            HStack(spacing: 6) {
                                if let g = cat.gIcon {
                                    GimanoIcon(icon: g, size: 22, stroke: category == cat ? .brandOn : .brandInk, fill: category == cat ? .brandOn : .brandTint)
                                } else {
                                    Image(systemName: cat.systemImage).font(.system(size: 15, weight: .bold))
                                }
                                Text(title).font(Tokens.Font.label)
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
                            .foregroundStyle(category == cat ? Color.brandOn : Color.brandInk)
                            .background(category == cat ? Color.brand : Color.brandMist, in: Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, Tokens.Space.gutter)
            }
            .padding(.bottom, 8)

            Divider()

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if query.isEmpty && category == nil {
                        suggestions
                    } else if results.isEmpty && !isSearching && searchedOnce && model.localMatches(query).filter { viewport == nil || SearchArea.contains(viewport!, $0.location) }.isEmpty && model.privateMatches(query).filter { viewport == nil || SearchArea.contains(viewport!, $0.location) }.isEmpty {
                        noResults
                    } else {
                        // On-device favourites first (they never leave the phone).
                        ForEach(model.localMatches(query).filter { viewport == nil || SearchArea.contains(viewport!, $0.location) }) { f in
                            Button {
                                pick(PlaceSummary(id: f.placeId ?? "local:\(f.id)", name: f.name, category: .other, address: f.address,
                                                  lat: f.lat, lng: f.lng, distanceM: Geo.distance(model.position, f.location), brand: nil))
                            } label: {
                                PlaceRow(gIcon: model.icon(for: f).gIcon, title: f.name, subtitle: f.address, distanceM: Geo.distance(model.position, f.location))
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("localResult")
                            Divider().padding(.leading, 68)
                        }
                        ForEach(model.privateMatches(query).filter { viewport == nil || SearchArea.contains(viewport!, $0.location) }) { p in
                            Button { pick(p.summary) } label: {
                                PlaceRow(gIcon: .heart, title: p.name, subtitle: p.address ?? String(localized: "Just for me"),
                                         distanceM: Geo.distance(model.position, p.location))
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("privateResult")
                            Divider().padding(.leading, 68)
                        }
                        if !results.isEmpty { resultHeader }
                        ForEach(SearchLogic.sections(results, sort: sort)) { section in
                            switch section {
                            case .place(let r):
                                resultRow(r)
                            case .chain(let name, let places):
                                chainHeader(name: name, count: SearchLogic.chainCount(places))
                                if expanded.contains(name.lowercased()) {
                                    ForEach(places) { resultRow($0, indent: true) }
                                }
                            }
                        }
                        if !results.isEmpty { Color.clear.frame(height: 90) }
                    }
                }
            }
            .scrollDismissesKeyboard(.immediately)
            .overlay(alignment: .bottom) {
                // Board "Search results": "Choose on map" always under the results, pinned.
                if !query.isEmpty, searchedOnce, !isSearching || !results.isEmpty {
                    chooseOnMapButton(primary: results.isEmpty)
                        .shadow(color: .black.opacity(0.14), radius: 7, y: 4)
                        .padding(.horizontal, Tokens.Space.gutter)
                        .padding(.bottom, 12)
                }
            }
        }
        .background(Color.surface.ignoresSafeArea())
        .overlay(alignment: .top) {
            if isSearching { ProgressView().padding(.top, 70) }
        }
        .onAppear {
            viewport = model.searchViewport
            model.searchViewport = nil
            #if DEBUG
            if let q = UserDefaults.standard.string(forKey: "GimanoDemoQuery"), query.isEmpty { query = q; return }
            #endif
            if let c = model.searchCategory {
                category = c
                model.searchCategory = nil
            } else {
                focused = true
            }
        }
        .task(id: "\(query)|\(category?.rawValue ?? "")|\(exact)|\(sort == .nearest)|\(viewport ?? "")") { await runSearch() }
        .onChange(of: query) { exact = false }
    }

    private var pinPurpose: PinPurpose {
        switch purpose {
        case .destination: .destination
        case .addStop: .addStop
        case .setOrigin: .setOrigin
        case .setHome: .setHome
        case .setWork: .setWork
        }
    }

    private func resultRow(_ r: PlaceSummary, indent: Bool = false) -> some View {
        VStack(spacing: 0) {
            Button { pick(r) } label: {
                PlaceRow(category: r.category, title: r.name, subtitle: subtitle(r), distanceM: r.distanceM)
                    .padding(.leading, indent ? 24 : 0)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("searchResult")
            Divider().padding(.leading, indent ? 92 : 68)
        }
    }

    private func subtitle(_ r: PlaceSummary) -> String {
        guard let open = r.openNow else { return r.address }
        let state = open ? String(localized: "Open now") : String(localized: "Closed")
        return r.address.isEmpty ? state : "\(r.address) · \(state)"
    }

    /// Sort chips + the spelling-fix line (board "Search results with spelling fix").
    @ViewBuilder private var resultHeader: some View {
        HStack(spacing: 8) {
            sortChip(.nearest, "Nearest")
            sortChip(.bestMatch, "Best match")
            if SearchLogic.knowsOpening(results) { sortChip(.openNow, "Open now") }
            Spacer()
        }
        .padding(.horizontal, Tokens.Space.gutter)
        .padding(.vertical, 8)
        if let corrected, !exact {
            HStack(spacing: 4) {
                Text("Showing results for \(Text(corrected).bold())")
                    .accessibilityIdentifier("correctedHeader")
                Text("·")
                Button("Search “\(query)” only") { exact = true }
                    .foregroundStyle(Color.brand)
                    .accessibilityIdentifier("searchExact")
            }
            .font(Tokens.Font.caption)
            .foregroundStyle(Color.amberInk)
            .padding(.horizontal, 14).padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.amberMist, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .padding(.horizontal, Tokens.Space.gutter)
            .padding(.bottom, 6)
        }
    }

    private func sortChip(_ s: ResultSort, _ title: LocalizedStringKey) -> some View {
        Button { sort = s } label: {
            Text(title).font(Tokens.Font.nunito(13, .black))
                .padding(.horizontal, 14).frame(height: 34)
                .foregroundStyle(sort == s ? Color.brandOn : Color.brandInk)
                .background(sort == s ? Color.brand : Color.brandMist, in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("sort.\(s.rawValue)")
        .accessibilityAddTraits(sort == s ? .isSelected : [])
    }

    private func chainHeader(name: String, count: Int) -> some View {
        let key = name.lowercased()
        let open = expanded.contains(key)
        return Button {
            if open { expanded.remove(key) } else { expanded.insert(key) }
        } label: {
            HStack(spacing: 12) {
                Text(SearchLogic.initials(name))
                    .font(Tokens.Font.nunito(13, .black)).foregroundStyle(Color.brand)
                    .frame(width: 48, height: 48)
                    .background(Color.brandMist, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: name).font(Tokens.Font.nunito(17, .black)).foregroundStyle(Color.textPrimary)
                    Text("\(count) branches nearby · nearest first").font(Tokens.Font.caption).foregroundStyle(Color.textMuted)
                }
                Spacer()
                Image(systemName: open ? "chevron.up" : "chevron.down").font(.system(size: 17, weight: .black)).foregroundStyle(Color.brand)
            }
            .padding(12)
            .background(Color.surfaceAlt, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .padding(.horizontal, Tokens.Space.gutter)
            .padding(.vertical, 4)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("chainGroup")
    }

    private func chooseOnMapButton(primary: Bool) -> some View {
        Button {
            focused = false
            model.startPinPick(pinPurpose)
        } label: {
            Label("Choose on map", systemImage: "map")
                .font(Tokens.Font.nunito(primary ? 19 : 18, .black))
                .frame(maxWidth: .infinity, minHeight: primary ? 72 : 64)
                .foregroundStyle(primary ? Color.brandOn : Color.brandInk)
                .background(primary ? Color.brand : Color.brandMist, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("chooseOnMap")
    }

    /// Board "No results": never a dead end.
    private var noResults: some View {
        VStack(spacing: 16) {
            Image(systemName: "magnifyingglass").font(.system(size: 64, weight: .bold)).foregroundStyle(Color.brandTint)
                .padding(.top, 24)
            Text(searchFailed ? "Search is unavailable. Try again." : viewport != nil ? "No matching places in this area" : "Can't find “\(query)”").font(Tokens.Font.nunito(22, .black)).multilineTextAlignment(.center)
                .accessibilityIdentifier("noResultsTitle")
            Text(viewport != nil ? "Move or zoom the map, then choose Search this area again." : "Small places are often not on the map yet. Know where it is? Show it on the map and go.")
                .font(Tokens.Font.body).foregroundStyle(Color.textMuted).multilineTextAlignment(.center)
            if !didYouMean.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Did you mean").font(Tokens.Font.label).foregroundStyle(Color.textMuted)
                    FlowLayout(spacing: 8) {
                        ForEach(didYouMean) { sg in
                            Button { apply(sg) } label: {
                                Text(suggestionLabel(sg)).font(Tokens.Font.nunito(14, .black)).foregroundStyle(Color.brandInk)
                                    .padding(.horizontal, 14).frame(height: 40)
                                    .background(Color.brandMist, in: Capsule())
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("searchSuggestion")
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Button {
                focused = false
                model.addPlaceStart = model.position
            } label: {
                Text("+ Add a missing place").font(Tokens.Font.nunito(16, .black)).foregroundStyle(Color.brandInk)
                    .frame(maxWidth: .infinity, minHeight: 56)
                    .background(Color.surfaceAlt, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("addPlaceFromSearch")
            Color.clear.frame(height: 90)      // room for the pinned "Choose on map"
        }
        .padding(Tokens.Space.gutter)
    }

    private func suggestionLabel(_ sg: SearchSuggestion) -> String {
        if !sg.label.isEmpty {
            // Category suggestions carry how many are within 5 km: "Kedai runcit · 20".
            return sg.count.map { "\(sg.label) · \($0)" } ?? sg.label
        }
        if let c = sg.category {
            let name = String(localized: AddPlaceCategories.title(c))
            return sg.count.map { String(localized: "\(name) nearby · \($0)") } ?? String(localized: "\(name) nearby")
        }
        return sg.query ?? ""
    }

    private func apply(_ sg: SearchSuggestion) {
        if let id = sg.placeId, let lat = sg.lat, let lng = sg.lng {
            pick(PlaceSummary(id: id, name: sg.label, category: sg.category ?? .other, address: "", lat: lat, lng: lng, distanceM: sg.distanceM))
        } else if let c = sg.category {
            query = ""
            category = c
        } else if let q = sg.query {
            query = q
        }
    }

    private var addPlaceButton: some View {
        Button {
            focused = false
            model.addPlaceStart = model.position
        } label: {
            HStack(spacing: 12) {
                GimanoIcon(icon: .addStop, size: 34)
                    .frame(width: 56, height: 56)
                    .background(Color.brandMist, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text("Can't find it?").font(Tokens.Font.caption).foregroundStyle(Color.textMuted)
                    Text("Add a place").font(Tokens.Font.nunito(19, .extrabold)).foregroundStyle(Color.brandInk)
                }
                Spacer()
            }
            .padding(10)
            .background(Color.surfaceAlt, in: RoundedRectangle(cornerRadius: Tokens.Radius.lg, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("addPlaceFromSearch")
    }

    private var placeholder: String {
        switch purpose {
        case .destination: String(localized: "Where to?")
        case .addStop: String(localized: "Add a stop")
        case .setOrigin: String(localized: "Search for a start")
        case .setHome: String(localized: "Set home address")
        case .setWork: String(localized: "Set work address")
        }
    }

    @ViewBuilder private var suggestions: some View {
        if !model.recents.filter({ viewport == nil || SearchArea.contains(viewport!, $0.location) }).isEmpty {
            Text("Recent")
                .font(Tokens.Font.label)
                .foregroundStyle(Color.textMuted)
                .textCase(.uppercase)
                .padding(.horizontal, Tokens.Space.gutter)
                .padding(.top, 12)
            ForEach(model.recents.filter { viewport == nil || SearchArea.contains(viewport!, $0.location) }) { r in
                Button {
                    pick(PlaceSummary(id: r.placeId ?? r.id, name: r.name, category: .other, address: r.address, lat: r.lat, lng: r.lng,
                                      distanceM: Geo.distance(model.position, r.location), brand: nil))
                } label: {
                    PlaceRow(gIcon: .recent, title: r.name, subtitle: r.address, distanceM: Geo.distance(model.position, r.location))
                }
                .buttonStyle(.plain)
                Divider().padding(.leading, 68)
            }
        }
    }

    private func runSearch() async {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty || category != nil else { results = []; return }
        try? await Task.sleep(for: .milliseconds(250)) // debounce
        guard !Task.isCancelled else { return }
        isSearching = true
        searchFailed = false
        defer { isSearching = false }
        let repo = model.repo
        let near = model.position
        let exactNow = exact
        let sortNow = sort
        do {
            if let viewport {
                let o = try await repo.searchInArea(query: q.isEmpty ? (category?.rawValue ?? "") : q, near: near,
                    category: category, limit: 25, exact: exactNow, sort: sortNow, viewport: viewport)
                guard !Task.isCancelled else { return }
                results = o.results; corrected = o.correctedQuery; didYouMean = []
            } else if q.isEmpty, let category {
                let r = try await repo.nearby(near: near, category: category, radiusM: 5000)
                guard !Task.isCancelled else { return }
                results = r; corrected = nil; didYouMean = []
            } else {
                let o = try await repo.searchOutcome(query: q, near: near, category: category, limit: 25, exact: exactNow, sort: sortNow)
                guard !Task.isCancelled else { return }
                results = o.results
                corrected = o.correctedQuery.flatMap { $0.caseInsensitiveCompare(q) == .orderedSame ? nil : $0 }
                var sg = o.suggestions
                // Older servers send no suggestions: offer the category the words point at.
                if o.results.isEmpty, sg.isEmpty, let cat = SearchLogic.categoryHint(in: q) {
                    let n = (try? await repo.nearby(near: near, category: cat, radiusM: 5000).count) ?? 0
                    if n > 0 { sg.append(SearchSuggestion(label: "", category: cat, count: n)) }
                }
                didYouMean = sg
                if let firstChain = SearchLogic.sections(o.results, sort: sort).first, case .chain(let name, _) = firstChain {
                    expanded.insert(name.lowercased())
                }
            }
        } catch {
            if !Task.isCancelled { results = []; corrected = nil; didYouMean = []; searchFailed = true }
        }
        searchedOnce = true
    }

    private func pick(_ p: PlaceSummary) {
        focused = false
        switch purpose {
        case .destination:
            // Streets, addresses, postcodes and coordinates have no place page: go straight to the pin actions.
            if p.isSearchOnly && !p.id.hasPrefix("st-") {
                model.pinActions = PickedPoint(location: p.location, address: p.address.isEmpty ? nil : p.address, placeName: p.name)
            } else {
                model.openPlace(p)
            }
        case .addStop:
            model.addStop(p)
        case .setOrigin:
            model.setRouteStart(.chosen(name: p.name, location: p.location, placeId: p.isSearchOnly || p.id.hasPrefix("pin:") ? nil : p.id))
            model.screen = .routePreview
        case .setHome:
            model.setSaved(kind: .home, place: p)
            model.go(.home)
        case .setWork:
            model.setSaved(kind: .work, place: p)
            model.go(.home)
        }
    }
}
