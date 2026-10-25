import SwiftUI

/// Trip overview: header, 2–3 alternatives with duration bubbles + "Best", Avoid menu, car/motorbike tabs,
/// route card, "Leave later" and a countdown-filling "Go now" that auto-starts.
struct RoutePreviewView: View {
    @Environment(AppModel.self) private var model
    @State private var countdownFill: CGFloat = 0
    @State private var countdownActive = false
    @State private var countdownToken = 0
    @State private var showLeaveLater = false
    @State private var showStartPicker = false
    @State private var showTolls = false
    @State private var showStops = false

    static let countdownSeconds: Double = 10

    var body: some View {
        if let planner = model.planner {
            ZStack {
                bubbles(planner)

                VStack(spacing: 10) {
                    header(planner)
                    if let note = planner.selected?.demoNote {
                        Label(note, systemImage: "play.circle.fill")
                            .font(Tokens.Font.label)
                            .foregroundStyle(Color.brandOn)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .background(Color.brand.opacity(0.94), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                            .padding(.horizontal, Tokens.Space.gutter)
                            .accessibilityIdentifier("demoRouteNote")
                    }
                    HStack {
                        Spacer()
                        if planner.vehicle.isMotorized { avoidMenu(planner) }
                    }
                    .padding(.horizontal, Tokens.Space.gutter)
                    Spacer()
                    if let card = model.safetyCard {
                        // Safety reminder (docs/safety.md §2): over the map with the route drawn behind it; guidance
                        // starts only after its button.
                        SafetyReminderCard(request: card) { model.confirmSafetyCard(dontShowAgain: $0) }
                            .id(card.id)
                            .padding(.horizontal, Tokens.Space.gutter)
                            .padding(.bottom, Tokens.Space.s)
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    } else {
                        bottomCard(planner)
                    }
                }
                .animation(.snappy(duration: 0.25), value: model.safetyCard)
            }
            .sheet(isPresented: $showStartPicker) {
            if let planner = model.planner { StartPickerSheet(planner: planner).presentationDetents([.medium, .large]) }
        }
        .sheet(isPresented: $showLeaveLater) {
                LeaveLaterSheet(planner: planner) { date in
                    stopCountdown()
                    planner.departAt = date
                    Task { await model.fetchRoutes() }
                }
                .presentationDetents([.medium, .large])
            }
            .sheet(isPresented: $showTolls) {
                if let r = planner.selected {
                    TollSheet(route: r, mode: planner.vehicle).presentationDetents([.medium, .large])
                }
            }
            .sheet(isPresented: $showStops) {
                StopsSheet(planner: planner) { stopCountdown() }.presentationDetents([.medium, .large])
            }
            // At the largest text sizes "Go now" was pushed below the screen: cap like the home panel and place card.
            .dynamicTypeSize(...DynamicTypeSize.accessibility2)
            .onChange(of: planner.isLoading) { _, loading in
                // The 10 s countdown is off by default (Settings → Start navigation automatically) and, when on, only runs
                // for one-tap trips from a fresh GPS fix (AutoStart, same rule as Android). `-GimanoNoAutoStart YES` (UI tests)
                // disables it regardless.
                if !loading, planner.selected != nil,
                   AutoStart.shouldCountdown(enabled: model.autoStartNav, quickPick: planner.quickPick, originIsGPS: planner.start.isGPS,
                                             hasStops: !planner.stops.isEmpty, departLater: planner.departAt != nil,
                                             foreground: model.isForeground),
                   // A real choice on a long trip: the list opens and nothing starts until the driver picks.
                   !RouteChoices.listFirst(planner.routes, vehicle: planner.vehicle, hasStops: !planner.stops.isEmpty),
                   !UserDefaults.standard.bool(forKey: "GimanoNoAutoStart") { startCountdown() }
            }
            .task(id: countdownToken) {
                guard countdownActive else { return }
                try? await Task.sleep(for: .seconds(Self.countdownSeconds))
                guard !Task.isCancelled, countdownActive, model.screen == .routePreview else { return }
                model.startNavigation()
            }
        }
    }

    // MARK: countdown

    private func startCountdown() {
        countdownActive = true
        countdownFill = 0
        countdownToken += 1
        withAnimation(.linear(duration: Self.countdownSeconds)) { countdownFill = 1 }
    }

    private func stopCountdown() {
        countdownActive = false
        countdownToken += 1
        var t = Transaction()
        t.disablesAnimations = true
        withTransaction(t) { countdownFill = 0 }
    }

    // MARK: pieces

    private func header(_ planner: RoutePlanner) -> some View {
        HStack(spacing: 12) {
            Button {
                stopCountdown()
                model.planner = nil
                model.go(.home)
            } label: {
                Image(systemName: "arrow.left")
                    .font(.system(size: 20, weight: .semibold))
                    .frame(width: 40, height: 40)
            }
            .accessibilityLabel(Text("Back"))
            VStack(alignment: .leading, spacing: 6) {
                Button { stopCountdown(); showStartPicker = true } label: {
                    HStack(spacing: 8) {
                        Circle().fill(planner.start.isGPS ? Color.brand : Color(uiColor: Tokens.Palette.traffic2)).frame(width: 10, height: 10)
                        Text(startLabel(planner.start)).font(Tokens.Font.caption).foregroundStyle(Color.textMuted).lineLimit(1)
                        Image(systemName: "chevron.down").font(.system(size: 10, weight: .bold)).foregroundStyle(Color.textMuted)
                    }
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("routeStart")
                HStack(spacing: 8) {
                    Image(systemName: "mappin.circle.fill").foregroundStyle(Color.report).font(.system(size: 12))
                    Text(planner.destination.name).font(Tokens.Font.bodyBold).lineLimit(1)
                }
            }
            Spacer()
            Button { stopCountdown(); model.swapRouteEnds() } label: {
                Image(systemName: "arrow.up.arrow.down").font(.system(size: 18, weight: .bold)).frame(width: 40, height: 40)
            }
            .disabled(planner.start.point == nil)
            .accessibilityLabel(Text("Swap start and destination"))
            .accessibilityIdentifier("routeSwap")
            Menu {
                Button { stopCountdown(); model.openFeedback(from: .routePreview, placeId: planner.destination.placeId) } label: {
                    Label("Add feedback", systemImage: "bubble.left.and.text.bubble.right")
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 20, weight: .bold))
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel(Text("More"))
            .accessibilityIdentifier("routeMore")
        }
        .foregroundStyle(Color.textPrimary)
        .padding(12)
        .background(Color.surface, in: RoundedRectangle(cornerRadius: Tokens.Radius.lg, style: .continuous))
        .fabShadow()
        .padding(.horizontal, Tokens.Space.gutter)
        .padding(.top, 8)
    }

    private func avoidMenu(_ planner: RoutePlanner) -> some View {
        @Bindable var planner = planner
        let count = [planner.avoid.tolls, planner.avoid.highways, planner.avoid.ferries].filter { $0 }.count
        return Menu {
            Toggle("Avoid tolls", isOn: $planner.avoid.tolls).accessibilityIdentifier("avoidTolls")
            Toggle("Avoid highways", isOn: $planner.avoid.highways)
            Toggle("Avoid ferries", isOn: $planner.avoid.ferries)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "slider.horizontal.3")
                Text(count == 0 ? String(localized: "Avoid") : String(localized: "Avoid (\(count))"))
                Image(systemName: "chevron.down").font(.system(size: 11, weight: .bold))
            }
            .font(Tokens.Font.label)
            .foregroundStyle(Color.textPrimary)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(Color.surface, in: Capsule())
            .fabShadow()
        }
        .accessibilityIdentifier("avoidMenu")
        .onChange(of: planner.avoid) {
            stopCountdown()
            Task { await model.fetchRoutes() }
        }
    }

    private func bubbles(_ planner: RoutePlanner) -> some View {
        ZStack(alignment: .topLeading) {
            let positions = Self.separated(planner.visibleRoutes.compactMap { r in model.map.bubblePoints[r.id].map { (r.id, $0) } })
            ForEach(planner.visibleRoutes) { r in
                if let pt = positions[r.id] {
                    let selected = r.id == planner.selected?.id
                    Button {
                        stopCountdown()
                        model.selectRoute(r.id)
                    } label: {
                        VStack(spacing: 0) {
                            if r.isBest {
                                Text("Best")
                                    .font(Tokens.Font.nunito(10, .black))
                                    .textCase(.uppercase)
                                    .foregroundStyle(selected ? Color.white.opacity(0.9) : Color.brand)
                            }
                            Text(ETAFormatter.duration(r.effectiveDurationS))
                                .font(Tokens.Font.nunito(15, .extrabold))
                        }
                        .foregroundStyle(selected ? Color.white : Color.textPrimary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(selected ? Color.routeActive : Color.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .fabShadow()
                    }
                    .buttonStyle(.plain)
                    .position(x: pt.x, y: pt.y - 22)
                    .accessibilityIdentifier("routeBubble")
                }
            }
        }
        .ignoresSafeArea()
    }

    /// Nudges bubbles apart in screen space so they never stack (alternatives often share road).
    static func separated(_ points: [(String, CGPoint)], minDX: CGFloat = 110, minDY: CGFloat = 56) -> [String: CGPoint] {
        var placed: [(String, CGPoint)] = []
        for (id, p) in points {
            var q = p
            var guardCount = 0
            while let hit = placed.first(where: { abs($0.1.x - q.x) < minDX && abs($0.1.y - q.y) < minDY }), guardCount < 6 {
                q.y = hit.1.y + (q.y >= hit.1.y ? minDY : -minDY)
                guardCount += 1
            }
            placed.append((id, q))
        }
        return Dictionary(uniqueKeysWithValues: placed)
    }

    private func bottomCard(_ planner: RoutePlanner) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            // With the route list showing, slimmer tabs leave room for the map (design RoPilihan).
            TravelModeTabs(selection: Binding(get: { planner.vehicle }, set: { v in
                stopCountdown()
                model.setTravelMode(v)
            }), compact: planner.listMode && !planner.isLoading)

            StopsStrip(planner: planner, onAdd: {
                stopCountdown()
                model.screen = .search(.addStop)
            }, onEdit: {
                stopCountdown()
                showStops = true
            })

            if planner.start == .locating {
                HStack(spacing: 10) { ProgressView(); Text("Finding your location…").font(Tokens.Font.bodyBold) }
                    .frame(maxWidth: .infinity, minHeight: 90)
                    .accessibilityIdentifier("startLocating")
            } else if planner.start == .unknown {
                unknownStart
            } else if planner.alreadyHere {
                Label("You're already here", systemImage: "mappin.and.ellipse")
                    .font(Tokens.Font.title).frame(maxWidth: .infinity, minHeight: 90)
                    // One element with the text only (the SF Symbol's own label read "Remove Map Pin").
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(Text("You're already here"))
                    .accessibilityIdentifier("alreadyHere")
            } else if planner.isLoading && planner.routes.isEmpty {
                HStack { Spacer(); ProgressView(); Spacer() }.frame(height: 90)
            } else if let error = planner.error, planner.routes.isEmpty {
                Text(error).foregroundStyle(Color.speeding).frame(maxWidth: .infinity, minHeight: 90)
                    .accessibilityIdentifier("routeError")
            } else if let r = planner.selected {
                if !(r.issues ?? []).isEmpty { RouteIssuesBanner(route: r) }
                if planner.listMode {
                    RouteChoiceList(planner: planner) { id in stopCountdown(); model.selectRoute(id) } onShowHidden: {
                        stopCountdown(); model.showHiddenRoutes()
                    } onTolls: { stopCountdown(); showTolls = true }
                } else {
                    routeSummary(r, planner: planner)
                    OtherRoutesRow(planner: planner) { stopCountdown(); model.openRouteList() }
                }
            }

            if case .chosen(let name, _, _) = planner.start, planner.selected != nil {
                // A chosen start is previewed only; navigation starts from where the phone is.
                Label("This route starts at \(name), not where you are. Navigation can only start from your location.",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(Tokens.Font.caption)
                    .foregroundStyle(Color.amberInk)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.amberMist, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .accessibilityIdentifier("chosenStartNote")
                HStack(spacing: 12) {
                    Button("Save trip") {
                        model.editingDrive = model.newPlannedDrive(from: planner)
                    }
                    .buttonStyle(SecondaryButtonStyle())
                    .accessibilityIdentifier("saveTrip")
                    Button("Drive to \(name) first") { model.driveToStartFirst() }
                        .buttonStyle(PrimaryButtonStyle())
                        .accessibilityIdentifier("driveToStartFirst")
                }
            } else if planner.start.isGPS && !planner.alreadyHere {
            HStack(spacing: 12) {
                Button {
                    stopCountdown()
                    showLeaveLater = true
                } label: {
                    Text(planner.departAt == nil ? String(localized: "Leave later") : planner.departAt!.formatted(date: .omitted, time: .shortened))
                }
                .buttonStyle(SecondaryButtonStyle())

                Button {
                    stopCountdown()
                    model.startNavigation()
                } label: {
                    Text(startLabel(planner) ?? String(localized: "Go now"))
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                        .padding(.horizontal, 10)
                        .frame(maxWidth: .infinity, minHeight: 52)
                        .background(alignment: .leading) {
                            // Fills left→right during the auto-start countdown.
                            GeometryReader { g in
                                Rectangle()
                                    .fill(Color.white.opacity(0.28))
                                    .frame(width: g.size.width * countdownFill)
                            }
                        }
                }
                .buttonStyle(PrimaryButtonStyle())
                .clipShape(RoundedRectangle(cornerRadius: Tokens.Radius.md, style: .continuous))
                .disabled(planner.selected == nil)
                .accessibilityIdentifier("goNow")
            }
            }
        }
        .padding(Tokens.Space.gutter)
        .background(
            UnevenRoundedRectangle(topLeadingRadius: Tokens.Radius.sheetTop, topTrailingRadius: Tokens.Radius.sheetTop)
                .fill(Color.surface)
                .shadow(color: .black.opacity(0.15), radius: 10, y: -2)
                .ignoresSafeArea(edges: .bottom)
        )
    }

    /// "Start · 43 min via E5" while the route list is showing; nil keeps "Go now".
    private func startLabel(_ planner: RoutePlanner) -> String? {
        guard planner.listMode, let r = planner.selected else { return nil }
        let time = ETAFormatter.duration(r.effectiveDurationS)
        if let via = RouteChoices.via(r) { return String(localized: "Start · \(time) via \(via)") }
        return String(localized: "Start · \(time)")
    }

    private func startLabel(_ start: RouteStart) -> String {
        switch start {
        case .gps: String(localized: "Your location")
        case .locating: String(localized: "Finding your location…")
        case .unknown: String(localized: "Your location unknown")
        case .chosen(let name, _, _): name
        }
    }

    /// No fresh GPS fix: no route request; three ways forward.
    private var unknownStart: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Your location unknown", systemImage: "location.slash")
                .font(Tokens.Font.title)
                .accessibilityIdentifier("startUnknown")
            Text("We only start routes from where you really are, or from a place you choose.")
                .font(Tokens.Font.caption).foregroundStyle(Color.textMuted)
            Button {
                if model.location.needsPermission { model.location.requestPermission() }
                else if let u = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(u) }
            } label: { Label("Allow location", systemImage: "location.fill") }
                .buttonStyle(PrimaryButtonStyle())
                .accessibilityIdentifier("startAllowLocation")
            HStack(spacing: 10) {
                Button { model.startPinPick(.setOrigin, start: model.planner?.destination.location) } label: {
                    Label("Choose start on map", systemImage: "map")
                }
                .buttonStyle(SecondaryButtonStyle())
                .accessibilityIdentifier("startChooseOnMap")
                Button { model.go(.search(.setOrigin)) } label: {
                    Label("Search for a start", systemImage: "magnifyingglass")
                }
                .buttonStyle(SecondaryButtonStyle())
                .accessibilityIdentifier("startSearch")
            }
        }
    }

    private func routeSummary(_ r: Route, planner: RoutePlanner) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(ETAFormatter.duration(r.effectiveDurationS))
                    .font(Tokens.Font.nunito(32, .black))
                    .foregroundStyle(r.isBest ? Color.brand : Color.textPrimary)
                Text(ManeuverFormatter.distance(r.distanceM))
                    .font(Tokens.Font.body)
                    .foregroundStyle(Color.textMuted)
                Spacer()
                if let text = TollBadge.make(for: r, mode: planner.vehicle).text {
                    Button { stopCountdown(); showTolls = true } label: {
                        HStack(spacing: 6) {
                            GimanoIcon(icon: .fare, size: 24)
                            Text(text).font(Tokens.Font.nunito(16, .black))
                        }
                        .foregroundStyle(Color.brandInk)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(Color.brandMist, in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("tollBadge")
                    .accessibilityLabel(Text(text))
                }
            }
            Text(r.summary)
                .font(Tokens.Font.body)
                .foregroundStyle(Color.textPrimary)
                .lineLimit(1)
            HStack(spacing: 6) {
                if r.isBest { Text("Best route").fontWeight(.semibold).foregroundStyle(Color.brand); Text("·") }
                if planner.vehicle.isMotorized {
                    Text(r.trafficDescription ?? String(localized: "Typical traffic"))
                    Text("·")
                }
                Text("Arrive \(ETAFormatter.arrivalTime(now: planner.departAt ?? .now, remainingS: r.effectiveDurationS))")
            }
            .font(Tokens.Font.caption)
            .foregroundStyle(Color.textMuted)
            .lineLimit(1)
        }
    }
}

/// Four big icon tabs: Car, Motorcycle, Bicycle, Walk.
struct TravelModeTabs: View {
    @Binding var selection: Vehicle
    var compact = false

    var body: some View {
        HStack(spacing: 8) {
            ForEach(Vehicle.allCases) { v in
                Button { selection = v } label: {
                    VStack(spacing: 2) {
                        GimanoIcon(icon: v.gIcon, size: compact ? 28 : 34)
                        if !compact { Text(v.shortTitle).font(Tokens.Font.nunito(12, .extrabold)) }
                    }
                    .foregroundStyle(Color.brandInk)
                    .frame(maxWidth: .infinity, minHeight: compact ? 44 : 64)
                    .selectableTile(selection == v, radius: 18)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(v.title))
                .accessibilityIdentifier("mode.\(v.rawValue)")
                .accessibilityAddTraits(selection == v ? .isSelected : [])
            }
        }
    }
}

extension Vehicle {
    var gIcon: GIcon {
        switch self {
        case .car: .car
        case .motorcycle: .motorcycle
        case .bicycle: .bicycle
        case .walk: .walk
        }
    }

    var shortTitle: LocalizedStringKey {
        switch self {
        case .car: "Car"
        case .motorcycle: "Moto"
        case .bicycle: "Bike"
        case .walk: "Walk"
        }
    }

    var title: LocalizedStringKey {
        switch self {
        case .car: "Car"
        case .motorcycle: "Motorbike"
        case .bicycle: "Bicycle"
        case .walk: "Walk"
        }
    }
}

/// Stops on the trip with their ETA, plus "Add a stop".
struct StopsStrip: View {
    @Environment(AppModel.self) private var model
    let planner: RoutePlanner
    let onAdd: () -> Void
    let onEdit: () -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                let offsets = planner.schedule?.offsetsS ?? []
                ForEach(Array(planner.stops.enumerated()), id: \.element.id) { i, stop in
                    Button(action: onEdit) {
                        HStack(spacing: 8) {
                            Text("\(i + 1)")
                                .font(Tokens.Font.nunito(14, .black))
                                .foregroundStyle(Color.brandOn)
                                .frame(width: 26, height: 26)
                                .background(Color.brand, in: Circle())
                            VStack(alignment: .leading, spacing: 0) {
                                Text(stop.name).font(Tokens.Font.label).lineLimit(1)
                                if i < offsets.count {
                                    Text(ETAFormatter.arrivalTime(now: planner.departAt ?? .now, remainingS: offsets[i]))
                                        .font(Tokens.Font.small).foregroundStyle(Color.textMuted)
                                        .accessibilityIdentifier("stopEta.\(i)")
                                }
                            }
                            .frame(maxWidth: 130, alignment: .leading)
                        }
                        .foregroundStyle(Color.textPrimary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Color.surfaceAlt, in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("stop.\(i)")
                }
                if planner.stops.count < TripStop.maxStops {
                    Button(action: onAdd) {
                        HStack(spacing: 6) {
                            GimanoIcon(icon: .addStop, size: 26)
                            Text("Stop").font(Tokens.Font.label)
                        }
                        .foregroundStyle(Color.brandInk)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(Color.brandMist, in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text("Add a stop"))
                    .accessibilityIdentifier("addStopButton")
                }
                if !planner.stops.isEmpty {
                    Button(action: onEdit) {
                        Image(systemName: "arrow.up.arrow.down")
                            .font(.system(size: 16, weight: .bold))
                            .foregroundStyle(Color.brandInk)
                            .frame(width: 40, height: 40)
                            .background(Color.brandMist, in: Circle())
                    }
                    .accessibilityLabel(Text("Edit stops"))
                    .accessibilityIdentifier("editStops")
                }
            }
        }
    }
}

/// Reorder / remove stops (up to 5), with ETA per stop.
struct StopsSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let planner: RoutePlanner
    let onChange: () -> Void

    var body: some View {
        NavigationStack {
            List {
                let offsets = planner.schedule?.offsetsS ?? []
                Section {
                    ForEach(Array(planner.stops.enumerated()), id: \.element.id) { i, stop in
                        HStack(spacing: 12) {
                            Text("\(i + 1)")
                                .font(Tokens.Font.nunito(15, .black))
                                .foregroundStyle(Color.brandOn)
                                .frame(width: 30, height: 30)
                                .background(Color.brand, in: Circle())
                            Text(stop.name).font(Tokens.Font.bodyBold).lineLimit(1)
                            Spacer()
                            if i < offsets.count {
                                Text(ETAFormatter.arrivalTime(now: planner.departAt ?? .now, remainingS: offsets[i]))
                                    .font(Tokens.Font.label).foregroundStyle(Color.textMuted)
                            }
                        }
                    }
                    .onMove { from, to in onChange(); model.moveStops(from: from, to: to) }
                    .onDelete { idx in
                        onChange()
                        for i in idx { model.removeStop(planner.stops[i].id) }
                    }
                    HStack(spacing: 12) {
                        GimanoIcon(icon: .home, size: 28)
                        Text(planner.destination.name).font(Tokens.Font.bodyBold).lineLimit(1)
                        Spacer()
                        if let last = offsets.last {
                            Text(ETAFormatter.arrivalTime(now: planner.departAt ?? .now, remainingS: last))
                                .font(Tokens.Font.label).foregroundStyle(Color.textMuted)
                        }
                    }
                }
                if planner.stops.count < TripStop.maxStops {
                    Button {
                        onChange()
                        dismiss()
                        model.screen = .search(.addStop)
                    } label: { Label("Add a stop", systemImage: "plus.circle.fill") }
                }
            }
            .environment(\.editMode, .constant(.active))
            .navigationTitle("Stops")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } } }
        }
    }
}

/// Toll plazas on the route with fare and source.
struct TollSheet: View {
    let route: Route
    let mode: Vehicle

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack {
                        GimanoIcon(icon: .fare, size: 40)
                        Text(TollBadge.make(for: route, mode: mode).text ?? "")
                            .font(Tokens.Font.nunito(28, .black))
                            .accessibilityIdentifier("tollTotal")
                    }
                } footer: {
                    if route.tollFareComplete == false {
                        Text("Some fares are unknown, so the total is a minimum.")
                    }
                }
                if let plazas = route.tolls, !plazas.isEmpty {
                    Section("Toll plazas") {
                        ForEach(plazas) { p in
                            HStack(alignment: .top, spacing: 12) {
                                GimanoIcon(icon: .toll, size: 30)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(p.name).font(Tokens.Font.bodyBold)
                                    if let h = p.highway { Text(h).font(Tokens.Font.caption).foregroundStyle(Color.textMuted) }
                                    if let src = p.source {
                                        // Show "Source: llm.gov.my" rather than a long URL.
                                        Text("Source: \(URL(string: src)?.host() ?? src)").font(Tokens.Font.small).foregroundStyle(Color.textMuted)
                                    }
                                }
                                Spacer()
                                Text(p.fareMyr.map(TollBadge.myr) ?? String(localized: "Unknown"))
                                    .font(Tokens.Font.nunito(16, .black))
                            }
                            .accessibilityIdentifier("tollPlaza")
                        }
                    }
                } else {
                    Section {
                        Text("This route has tolls, but plaza details aren't available yet.")
                            .foregroundStyle(Color.textMuted)
                    }
                }
            }
            .navigationTitle("Tolls")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}

/// "Leave later" — departure-time slots from `GET /routes/departure-times`.
struct LeaveLaterSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let planner: RoutePlanner
    let onPick: (Date?) -> Void
    @State private var slots: [DepartureSlot] = []
    @State private var loading = true

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button {
                        onPick(nil); dismiss()
                    } label: { Label("Leave now", systemImage: "bolt.fill") }
                    Button {
                        dismiss()
                        model.editingDrive = model.newPlannedDrive(from: planner)
                    } label: { Label("Plan this drive (reminder)", systemImage: "calendar.badge.clock") }
                        .accessibilityIdentifier("planThisDrive")
                }
                Section("Best time to leave") {
                    if loading { ProgressView() }
                    let maxD = slots.map(\.durationS).max() ?? 1
                    let minD = slots.map(\.durationS).min() ?? 0
                    ForEach(slots) { s in
                        Button {
                            onPick(s.departAt); dismiss()
                        } label: {
                            HStack {
                                Text(s.departAt.formatted(date: .omitted, time: .shortened))
                                    .font(Tokens.Font.body.monospacedDigit())
                                    .frame(width: 90, alignment: .leading)
                                GeometryReader { g in
                                    Capsule()
                                        .fill(s.durationS <= minD * 1.05 ? Color.brand : Color.routeAlt)
                                        .frame(width: max(12, g.size.width * s.durationS / maxD), height: 10)
                                        .frame(maxHeight: .infinity)
                                }
                                Text(ETAFormatter.duration(s.durationS))
                                    .font(Tokens.Font.caption.monospacedDigit())
                                    .foregroundStyle(Color.textMuted)
                                    .frame(width: 70, alignment: .trailing)
                            }
                            .foregroundStyle(Color.textPrimary)
                        }
                    }
                }
            }
            .navigationTitle("Leave later")
            .navigationBarTitleDisplayMode(.inline)
        }
        .task {
            slots = (try? await model.repo.departureTimes(origin: model.position, destination: planner.destination.location, date: .now, vehicle: planner.vehicle)) ?? []
            loading = false
        }
    }
}

/// Start picker: Your location, Home, Work, favourites, recents, search, choose on map.
struct StartPickerSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let planner: RoutePlanner

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button { pick(.locating) } label: { Label("Your location", systemImage: "location.fill") }
                        .accessibilityIdentifier("startPick.gps")
                    Button { dismiss(); model.go(.search(.setOrigin)) } label: { Label("Search for a start", systemImage: "magnifyingglass") }
                    Button {
                        dismiss()
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { model.startPinPick(.setOrigin, start: planner.destination.location) }
                    } label: { Label("Choose start on map", systemImage: "map") }
                        .accessibilityIdentifier("startPick.map")
                }
                let saved = model.savedPlaces
                if !saved.isEmpty {
                    Section("Saved") {
                        ForEach(saved) { s in
                            Button { pick(.chosen(name: s.name, location: s.location, placeId: s.placeId)) } label: {
                                Label { Text(verbatim: s.name) } icon: { GimanoIcon(icon: model.icon(for: s).gIcon, size: 22) }
                            }
                            .accessibilityIdentifier("startPick.saved")
                        }
                    }
                }
                if !model.recents.isEmpty {
                    Section("Recent") {
                        ForEach(model.recents.prefix(8)) { r in
                            Button { pick(.chosen(name: r.name, location: r.location, placeId: r.placeId)) } label: {
                                Label { Text(verbatim: r.name) } icon: { Image(systemName: "clock") }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Start from")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarLeading) { Button("Cancel") { dismiss() } } }
        }
    }

    private func pick(_ s: RouteStart) {
        dismiss()
        model.setRouteStart(s)
    }
}

// MARK: - Route options before a drive (design RoPilihan / RoBanding / RoPendek / RoSatu)

private extension Color {
    static let tollTag = Color(light: 0xFFE7C7, dark: 0x3D2A10)
    static let tollTagInk = Color(light: 0x7A4100, dark: 0xF5C98A)
    static let roadTag = Color(light: 0xD6F2E8, dark: 0x123A2E)
    static let roadTagInk = Color(light: 0x0B4A3A, dark: 0x9EE3C8)
    static let worse = Color(light: 0x9A3412, dark: 0xFFB08A)
    static let better = Color(light: 0x0B5D45, dark: 0x8FE0BE)
}

/// Every shown route as a card; with another route picked, it grows a comparison and the rest shrink to rows.
struct RouteChoiceList: View {
    let planner: RoutePlanner
    let onSelect: (String) -> Void
    let onShowHidden: () -> Void
    let onTolls: () -> Void

    var body: some View {
        let shown = RouteChoices.shown(planner.routes)
        let fastest = shown.first ?? planner.routes.first
        let selected = planner.selected
        let altPicked = selected != nil && selected?.id != fastest?.id
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                Text("\(planner.visibleRoutes.count) routes")
                    .font(Tokens.Font.nunito(18, .black))
                    .padding(.horizontal, 4)
                    .accessibilityIdentifier("routeCount")
                if let fastest {
                    ForEach(planner.visibleRoutes) { r in
                        let isSel = r.id == selected?.id
                        if altPicked && !isSel {
                            compactRow(r)
                        } else {
                            card(r, fastest: fastest, shown: shown, selected: isSel, expanded: isSel && altPicked)
                        }
                    }
                }
                let hidden = RouteChoices.hidden(planner.routes)
                if !hidden.isEmpty && !planner.showHidden { hiddenRow(hidden) }
            }
        }
        .scrollBounceBehavior(.basedOnSize)
        .frame(maxHeight: 400)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func card(_ r: Route, fastest: Route, shown: [Route], selected: Bool, expanded: Bool) -> some View {
        let cmp = RouteChoices.compare(r, fastest: fastest, shown: shown)
        return Button { onSelect(r.id) } label: {
            HStack(alignment: .top, spacing: 10) {
                Capsule().fill(selected ? Color.brand : Color.textMuted.opacity(0.5)).frame(width: 6).frame(minHeight: 56)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 8) {
                        Text(ETAFormatter.duration(r.effectiveDurationS))
                            .font(Tokens.Font.nunito(selected ? 24 : 22, .black))
                            .foregroundStyle(selected ? Color.brand : Color.textPrimary)
                        RouteTags(route: r)
                        Spacer(minLength: 4)
                        Text(ManeuverFormatter.distance(r.distanceM)).font(Tokens.Font.nunito(14, .extrabold)).foregroundStyle(Color.textMuted)
                    }
                    Text([tollText(r), r.summary.isEmpty ? nil : r.summary].compactMap { $0 }.joined(separator: " · "))
                        .font(Tokens.Font.nunito(14, .bold))
                        .foregroundStyle(Color.textPrimary)
                        .lineLimit(1)
                    if r.id == fastest.id {
                        let bits = [planner.vehicle.isMotorized ? (r.trafficDescription ?? String(localized: "Typical traffic")) : nil,
                                    (r.alerts ?? []).isEmpty ? nil : String(localized: "\((r.alerts ?? []).count) reports on route")].compactMap { $0 }
                        if !bits.isEmpty { Text(bits.joined(separator: " · ")).font(Tokens.Font.nunito(13, .bold)).foregroundStyle(Color.textMuted) }
                    } else if !expanded {
                        Text(Self.compareLine(cmp)).font(Tokens.Font.nunito(13, .bold)).foregroundStyle(Color.textMuted)
                    }
                    if expanded { tiles(cmp, route: r) }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(selected ? Color.brandMist : Color.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(selected ? Color.brand : Color.surfaceAlt, lineWidth: 2))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("routeCard")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func tiles(_ cmp: RouteChoices.Compare, route r: Route) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Compared with the fastest").textCase(.uppercase)
                .font(Tokens.Font.nunito(12, .black)).foregroundStyle(Color.brandInk).padding(.top, 4)
            HStack(spacing: 6) {
                if cmp.extraS >= 60 {
                    tile("+" + ETAFormatter.duration(cmp.extraS), String(localized: "slower"), .worse)
                } else {
                    tile("=", String(localized: "same time"), .textPrimary)
                }
                if let saved = cmp.tollSavedMyr {
                    tile(TollBadge.myr(saved), String(localized: "less toll"), .better)
                } else if let extra = cmp.tollExtraMyr {
                    tile(TollBadge.myr(extra), String(localized: "more toll"), .worse)
                } else {
                    tile("=", String(localized: "same toll"), .textPrimary)
                }
                if let m = cmp.shorterM {
                    tile(ManeuverFormatter.distance(m), String(localized: "shorter"), .better)
                } else if let m = cmp.longerM {
                    tile(ManeuverFormatter.distance(m), String(localized: "longer"), .worse)
                } else {
                    Color.clear.frame(maxWidth: .infinity, maxHeight: 1)
                }
            }
            if let n = r.alerts?.count, n > 0 {
                Text("\(n) reports on route").font(Tokens.Font.nunito(13, .bold)).foregroundStyle(Color.textMuted)
            }
            if !(r.tolls ?? []).isEmpty {
                Button("Toll plazas", action: onTolls).font(Tokens.Font.nunito(14, .black)).foregroundStyle(Color.brand)
                    .accessibilityIdentifier("routeTolls")
            }
        }
    }

    private func tile(_ value: String, _ label: String, _ colour: Color) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(value).font(Tokens.Font.nunito(17, .black)).foregroundStyle(colour).lineLimit(1).minimumScaleFactor(0.8)
            Text(label).font(Tokens.Font.nunito(12, .bold)).foregroundStyle(Color.textMuted).lineLimit(1)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func compactRow(_ r: Route) -> some View {
        Button { onSelect(r.id) } label: {
            HStack(spacing: 10) {
                Capsule().fill(Color.textMuted.opacity(0.5)).frame(width: 6, height: 30)
                Text(ETAFormatter.duration(r.effectiveDurationS)).font(Tokens.Font.nunito(18, .black)).foregroundStyle(Color.textPrimary)
                Text([r.reasons?.first.flatMap(RouteTags.label), RouteChoices.via(r), tollText(r)].compactMap { $0 }.joined(separator: " · "))
                    .font(Tokens.Font.nunito(13, .bold)).foregroundStyle(Color.textMuted).lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
            .background(Color.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(Color.surfaceAlt, lineWidth: 2))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("routeRow")
    }

    private func hiddenRow(_ hidden: [Route]) -> some View {
        Button(action: onShowHidden) {
            HStack {
                Group {
                    if hidden.count == 1, let r = hidden.first {
                        Text("1 more route hidden: \(ETAFormatter.duration(r.effectiveDurationS)), \(RouteTags.hiddenLabel(r.hidden))")
                    } else {
                        Text("\(hidden.count) more routes hidden")
                    }
                }
                .font(Tokens.Font.nunito(13, .bold)).foregroundStyle(Color.textMuted)
                Spacer()
                Text("Show anyway").font(Tokens.Font.nunito(14, .black)).foregroundStyle(Color.brand)
            }
            .frame(minHeight: 44)
            .padding(.horizontal, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("showHiddenRoutes")
    }

    static func compareLine(_ c: RouteChoices.Compare) -> String {
        var bits = ["+" + ETAFormatter.duration(max(60, c.extraS))]
        if let s = c.tollSavedMyr { bits.append(String(localized: "saves \(TollBadge.myr(s))")) }
        if let e = c.tollExtraMyr { bits.append(String(localized: "\(TollBadge.myr(e)) more toll")) }
        if let m = c.shorterM { bits.append(String(localized: "\(ManeuverFormatter.distance(m)) shorter")) }
        if let m = c.longerM { bits.append(String(localized: "\(ManeuverFormatter.distance(m)) longer")) }
        if !c.avoids.isEmpty {
            let roads = c.avoids.prefix(2).joined(separator: " " + String(localized: "and") + " ")
            bits.append(String(localized: "avoids \(roads)"))
        }
        return bits.joined(separator: " · ")
    }
}

/// Up to two reason tags ("Fastest", "Lower toll", …), or why a hidden route was hidden.
struct RouteTags: View {
    let route: Route

    var body: some View {
        HStack(spacing: 6) {
            let codes = Array((route.reasons ?? []).prefix(2))
            if codes.isEmpty, route.hidden != nil {
                tag(Self.hiddenLabel(route.hidden), .surfaceAlt, .textMuted)
            }
            ForEach(codes, id: \.self) { code in
                if let label = Self.label(code) {
                    let (bg, ink) = Self.colours(code)
                    tag(label, bg, ink)
                }
            }
        }
    }

    private func tag(_ text: String, _ bg: Color, _ ink: Color) -> some View {
        Text(text).font(Tokens.Font.nunito(12, .black)).foregroundStyle(ink).lineLimit(1)
            .padding(.horizontal, 8).padding(.vertical, 2)
            .background(bg, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    static func label(_ code: String) -> String? {
        switch code {
        case "fastest": String(localized: "Fastest")
        case "shortest": String(localized: "Shortest")
        case "lower_toll": String(localized: "Lower toll")
        case "no_tolls": String(localized: "No tolls")
        case "fewer_reports": String(localized: "Fewer reports")
        case "other_main_road": String(localized: "Other main road")
        default: nil
        }
    }

    static func hiddenLabel(_ code: String?) -> String {
        switch code {
        case "same_road": String(localized: "almost the same road")
        case "slower": String(localized: "much slower")
        default: String(localized: "slower, longer and more toll")
        }
    }

    private static func colours(_ code: String) -> (Color, Color) {
        switch code {
        case "fastest": (.brand, .brandOn)
        case "shortest": (.surfaceAlt, .brandInk)
        case "lower_toll", "no_tolls": (.tollTag, .tollTagInk)
        default: (.roadTag, .roadTagInk)
        }
    }
}

/// Short trips (design RoPendek): "2 other routes · +6 min via FT20 · …"; Show opens the list and stops the countdown.
struct OtherRoutesRow: View {
    let planner: RoutePlanner
    let onShow: () -> Void

    var body: some View {
        let shown = RouteChoices.shown(planner.routes)
        let others = shown.filter { $0.id != planner.selected?.id }
        if shown.count >= 2, let fastest = shown.first, !others.isEmpty {
            Button(action: onShow) {
                HStack {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(others.count == 1 ? String(localized: "1 other route") : String(localized: "\(others.count) other routes"))
                            .font(Tokens.Font.nunito(16, .black)).foregroundStyle(Color.textPrimary)
                        Text(others.map { r in
                            let t = r.id == fastest.id ? ETAFormatter.duration(r.effectiveDurationS)
                                : "+" + ETAFormatter.duration(max(60, r.effectiveDurationS - fastest.effectiveDurationS))
                            // Same road name as the fastest says nothing: show the distance instead.
                            let via = RouteChoices.via(r)
                            let road = via != nil && via != RouteChoices.via(fastest) ? via! : ManeuverFormatter.distance(r.distanceM)
                            return "\(t) \(road)"
                        }.joined(separator: " · "))
                        .font(Tokens.Font.nunito(13, .bold)).foregroundStyle(Color.textMuted).lineLimit(1)
                    }
                    Spacer()
                    Text("Show").font(Tokens.Font.nunito(14, .black)).foregroundStyle(Color.brand)
                }
                .padding(.horizontal, 12)
                .frame(maxWidth: .infinity, minHeight: 52)
                .background(Color.surfaceAlt, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("otherRoutes")
        }
    }
}

/// "toll RM 8.56", "toll from RM 2.50", "no tolls"; nil for bicycle and walk.
private func tollText(_ r: Route) -> String? {
    if r.vehicle == .bicycle || r.vehicle == .walk { return nil }
    if !r.hasTolls { return String(localized: "no tolls") }
    guard let v = r.tollEstimateMyr else { return nil }
    return r.tollFareComplete == true ? String(localized: "toll \(TollBadge.myr(v))") : String(localized: "toll from \(TollBadge.myr(v))")
}
