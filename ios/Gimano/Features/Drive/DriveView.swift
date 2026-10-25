import SwiftUI

/// Driving screen: dark turn banner + "then" strip, speedometer, report button, ETA bottom bar that
/// expands (Add a stop · Share drive · Stop), "Still there? / Not there" alert cards.
struct DriveView: View {
    @Environment(AppModel.self) private var model
    @State private var expanded = false
    @State private var showAlternatives = false

    var body: some View {
        if let nav = model.navigation {
            ZStack(alignment: .bottom) {
                VStack(spacing: 0) {
                    TurnBanner(nav: nav)
                    if model.showSafetyBanner {
                        SafetyMovingBanner()
                            .padding(.horizontal, 10)
                            .padding(.top, 6)
                            .transition(.move(edge: .top).combined(with: .opacity))
                    }
                    if let stop = nav.arrivedAtStop {
                        HStack(spacing: 10) {
                            GimanoIcon(icon: .addStop, size: 30, stroke: .brandOn, fill: .brandOn)
                            Text("Arrived at \(stop)").font(Tokens.Font.nunito(18, .black))
                            Spacer()
                        }
                        .foregroundStyle(Color.brandOn)
                        .padding(14)
                        .background(Color.brand, in: RoundedRectangle(cornerRadius: Tokens.Radius.lg, style: .continuous))
                        .padding(.horizontal, 10)
                        .padding(.top, 6)
                        .transition(.move(edge: .top).combined(with: .opacity))
                        .accessibilityIdentifier("arrivedAtStop")
                    }
                    if !model.location.isPrecise && !model.isSimulatingDrive {
                        HStack(spacing: 10) {
                            Image(systemName: "location.slash.fill")
                            Text("Approximate location only: directions may be wrong").font(Tokens.Font.label)
                            Spacer(minLength: 4)
                            Button("Settings") {
                                if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                            }
                            .font(Tokens.Font.label.bold())
                        }
                        .foregroundStyle(Color.white)
                        .padding(12)
                        .background(Color.report, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                        .padding(.horizontal, 10)
                        .padding(.top, 6)
                        .accessibilityIdentifier("approximateLocationBanner")
                    }
                    TimelineView(.periodic(from: .now, by: 1)) { ctx in
                    if model.gpsQuality.isWeak(at: ctx.date), let acc = model.gpsQuality.lastAccuracyM {
                        HStack {
                            Label("Weak GPS signal ±\(Int(acc.rounded())) m", systemImage: "antenna.radiowaves.left.and.right.slash")
                                .font(Tokens.Font.label)
                                .foregroundStyle(Color.textPrimary)
                                .padding(.horizontal, 12).frame(height: 36)
                                .background(Color.surface, in: Capsule())
                                .fabShadow()
                                .accessibilityIdentifier("weakGpsChip")
                            Spacer()
                        }
                        .padding(.horizontal, 12)
                        .padding(.top, 6)
                    }
                    }
                    if model.driveShare != nil {
                        HStack {
                            // One coral chip: "● Sharing | Stop" (board "Kongsi perjalanan").
                            HStack(spacing: 0) {
                                Button { model.showShareSheet = true } label: {
                                    HStack(spacing: 8) {
                                        Circle().fill(Color.white).frame(width: 8, height: 8)
                                        Text("Sharing").font(Tokens.Font.label)
                                    }
                                    .padding(.leading, 14).padding(.trailing, 10).frame(height: 40)
                                }
                                .accessibilityIdentifier("sharingChip")
                                Rectangle().fill(Color.white.opacity(0.4)).frame(width: 1, height: 20)
                                Button { model.stopSharing() } label: {
                                    Text("Stop").font(Tokens.Font.label).padding(.leading, 10).padding(.trailing, 14).frame(height: 40)
                                }
                                .accessibilityLabel(Text("Stop sharing"))
                                .accessibilityIdentifier("stopSharingChip")
                            }
                            .foregroundStyle(Color.white)
                            .background(Color.report, in: Capsule())
                            .shadow(color: .black.opacity(0.15), radius: 6, y: 2)
                            Spacer()
                        }
                        .padding(.horizontal, 12)
                        .padding(.top, 6)
                    }
                    // Hidden diagnostics for UI tests (max off-road distance while on route, reroutes).
                    Text(verbatim: "offroad=\(Int(nav.maxOffRoadM.rounded()));reroutes=\(nav.rerouteCount);stopsLeft=\(nav.stops.count - nav.stopTracker.nextStopIndex)")
                        .font(.system(size: 1))
                        .opacity(0.01)
                        .accessibilityIdentifier("navDebug")
                    HStack {
                        Spacer()
                        VStack(spacing: 12) {
                            SoundFab()
                            if !model.map.isFollowing {
                                RoundFab(icon: .logo, accessibilityLabel: "Recenter", stroke: .brand, fill: .brand) { model.recenter() }
                            }
                        }
                    }
                    .padding(.horizontal, Tokens.Space.gutter)
                    .padding(.top, 12)
                    Spacer()
                }

                VStack(spacing: 12) {
                    if nav.approachingAlert == nil, let issue = model.stillClosedPrompt {
                        StillClosedCard(issue: issue)
                            .padding(.horizontal, Tokens.Space.gutter)
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                    if let alert = nav.approachingAlert {
                        AlertCard(report: alert.report, distanceM: nav.distanceToAlert(alert),
                                  onStillThere: { Task { if await model.ensureRulesAccepted() { nav.vote(stillThere: true) } } },
                                  onNotThere: { Task { if await model.ensureRulesAccepted() { nav.vote(stillThere: false) } } },
                                  onClose: { nav.dismissAlert() })
                            .padding(.horizontal, Tokens.Space.gutter)
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                    HStack(alignment: .bottom) {
                        Speedometer(speedKmh: nav.speedKmh)
                        Spacer()
                        ReportFab { model.showReport = true }
                    }
                    .padding(.horizontal, Tokens.Space.gutter)
                    HStack {
                        OSMAttribution()
                        Spacer()
                    }
                    .padding(.horizontal, Tokens.Space.gutter)
                    .padding(.top, -6)
                    BottomBar(nav: nav, expanded: $expanded, showAlternatives: $showAlternatives)
                }
                .animation(.snappy, value: nav.approachingAlert?.id)

                if nav.arrived {
                    ArrivedCard(destination: nav.destination, onDone: { model.stopNavigation() },
                                onName: nav.destination.isPin ? {
                                    let d = nav.destination
                                    model.stopNavigation()
                                    model.savingPlace = PlaceSummary(id: "pin:\(d.location.lat),\(d.location.lng)", name: "",
                                                                     category: .other, address: d.address, lat: d.location.lat, lng: d.location.lng)
                                } : nil)
                        .transition(.move(edge: .bottom))
                }
            }
            // Glanceable while driving: the largest text sizes are capped so the banner, sound button, cards and Stop stay on screen.
            .dynamicTypeSize(...DynamicTypeSize.accessibility1)
            .sheet(isPresented: Binding(get: { model.showShareSheet }, set: { model.showShareSheet = $0 })) {
                if let s = model.driveShare { ShareDriveSheet(session: s, nav: nav).presentationDetents([.medium]) }
            }
            .sheet(isPresented: $showAlternatives) {
                DriveAlternativesSheet(nav: nav)
                    .presentationDetents([.medium])
            }
        }
    }
}

struct TurnBanner: View {
    @Environment(AppModel.self) private var model
    let nav: NavigationSession

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 16) {
                if nav.isRerouting {
                    ProgressView().tint(.white).frame(width: 56, height: 56)
                    Text("Recalculating…").font(Tokens.Font.title).foregroundStyle(Color.navBannerOn)
                } else if let m = nav.upcoming {
                    Image(systemName: ManeuverFormatter.symbol(for: m.type))
                        .font(.system(size: 46, weight: .heavy))
                        .foregroundStyle(Color.navBannerOn)
                        .frame(width: 60, height: 60)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(ManeuverFormatter.distance(nav.distanceToUpcoming))
                            .font(Tokens.Font.navDistance)
                            .monospacedDigit()
                            .foregroundStyle(Color.navBannerOn)
                            .accessibilityIdentifier("maneuverDistance")
                        Text(nav.stopName(forManeuverAt: nav.progress?.upcomingIndex).map { String(localized: "Arrive at \($0)") }
                             ?? ManeuverFormatter.roadName(m) ?? ManeuverFormatter.instruction(for: m, mode: nav.vehicle))
                            .font(Tokens.Font.nunito(20, .bold))
                            .foregroundStyle(Color.navBannerOn.opacity(0.9))
                            .lineLimit(2)
                            .minimumScaleFactor(0.8)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 14)
            .background(Color.navBanner, in: RoundedRectangle(cornerRadius: Tokens.Radius.lg, style: .continuous))
            .accessibilityElement(children: .combine)
            .accessibilityLabel(Text(nav.upcoming.map { "\(ManeuverFormatter.distance(nav.distanceToUpcoming)), \(ManeuverFormatter.instruction(for: $0))" } ?? ""))

            if let then = nav.then, !nav.isRerouting {
                HStack(spacing: 8) {
                    Text("then").font(Tokens.Font.nunito(15, .bold))
                    Image(systemName: ManeuverFormatter.symbol(for: then.type)).font(.system(size: 18, weight: .bold))
                }
                .foregroundStyle(Color.navBannerOn)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(Color.navBanner.opacity(0.88), in: UnevenRoundedRectangle(bottomLeadingRadius: 14, bottomTrailingRadius: 14))
                .padding(.leading, 18)
            }
        }
        .padding(.horizontal, 10)
        .padding(.top, 4)
        .shadow(color: .black.opacity(0.25), radius: 6, y: 2)
    }
}

struct BottomBar: View {
    @Environment(AppModel.self) private var model
    let nav: NavigationSession
    @Binding var expanded: Bool
    @Binding var showAlternatives: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button { model.screen = .search(.addStop) } label: {
                    GimanoIcon(icon: .search, size: 28)
                        .frame(width: 56, height: 56)
                        .background(Color.brandMist, in: Circle())
                }
                .accessibilityLabel(Text("Add a stop"))
                Spacer()
                Button { withAnimation(.snappy) { expanded.toggle() } } label: {
                    VStack(spacing: 0) {
                        Text(ETAFormatter.arrivalTime(remainingS: nav.remainingS))
                            .font(Tokens.Font.etaClock)
                            .monospacedDigit()
                            .accessibilityIdentifier("etaClock")
                        Text(ETAFormatter.tripSummary(remainingS: nav.remainingS, remainingM: nav.remainingM))
                            .font(Tokens.Font.caption)
                            .foregroundStyle(Color.textMuted)
                    }
                }
                .buttonStyle(.plain)
                Spacer()
                Button { showAlternatives = true } label: {
                    Image(systemName: "arrow.triangle.branch")
                        .font(.system(size: 22, weight: .bold))
                        .foregroundStyle(Color.brandInk)
                        .frame(width: 56, height: 56)
                        .background(Color.brandMist, in: Circle())
                }
                .accessibilityLabel(Text("Alternative routes"))
            }
            .foregroundStyle(Color.textPrimary)
            .padding(.horizontal, Tokens.Space.gutter)
            .padding(.top, 10)
            .padding(.bottom, expanded ? 8 : 4)

            if expanded {
                VStack(alignment: .leading, spacing: 12) {
                    Divider()
                    VStack(alignment: .leading, spacing: 2) {
                        Text(nav.destination.name).font(Tokens.Font.bodyBold)
                        Text(nav.route.summary).font(Tokens.Font.caption).foregroundStyle(Color.textMuted).lineLimit(1)
                        let remainingStops = Array(nav.stops.dropFirst(nav.stopTracker.nextStopIndex))
                        let etas = nav.etaOffsets
                        ForEach(Array(remainingStops.enumerated()), id: \.element.id) { i, s in
                            HStack {
                                Text("\(i + 1)").font(Tokens.Font.nunito(13, .black)).foregroundStyle(Color.brandOn)
                                    .frame(width: 22, height: 22).background(Color.brand, in: Circle())
                                Text(s.name).font(Tokens.Font.label).lineLimit(1)
                                Spacer()
                                if i < etas.count { Text(ETAFormatter.arrivalTime(remainingS: etas[i])).font(Tokens.Font.label).foregroundStyle(Color.textMuted) }
                            }
                        }
                    }
                    HStack(spacing: 10) {
                        Button { expanded = false; model.screen = .search(.addStop) } label: {
                            Label("Add a stop", systemImage: "plus.circle.fill")
                        }
                        .buttonStyle(SecondaryButtonStyle())
                        Button {
                            expanded = false
                            model.startSharing()
                        } label: {
                            Label(model.driveShare == nil ? "Share drive" : "Sharing…", systemImage: "location.fill.viewfinder")
                        }
                        .buttonStyle(SecondaryButtonStyle())
                        .accessibilityIdentifier("shareDrive")
                    }
                    Button {
                        expanded = false
                        model.openFeedback(from: .navigation)
                    } label: {
                        Label("Add feedback", systemImage: "bubble.left.and.text.bubble.right")
                    }
                    .buttonStyle(SecondaryButtonStyle())
                    .accessibilityIdentifier("navFeedback")
                    HStack(spacing: 10) {
                        Button { expanded = false } label: { Text("Continue") }
                            .buttonStyle(SecondaryButtonStyle())
                        Button { expanded = false; model.stopNavigation() } label: { Text("Stop") }
                            .buttonStyle(PrimaryButtonStyle(color: .speeding, foreground: .white))
                            .accessibilityIdentifier("stopNavigation")
                    }
                }
                .padding(.horizontal, Tokens.Space.gutter)
                .padding(.bottom, 8)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .background(
            UnevenRoundedRectangle(topLeadingRadius: Tokens.Radius.sheetTop, topTrailingRadius: Tokens.Radius.sheetTop)
                .fill(Color.surface)
                .shadow(color: .black.opacity(0.15), radius: 10, y: -2)
                .ignoresSafeArea(edges: .bottom)
        )
    }

    private var shareText: String {
        let eta = ETAFormatter.arrivalTime(remainingS: nav.remainingS)
        return String(localized: "I'm driving to \(nav.destination.name) with Gimano. ETA \(eta).")
    }
}

/// "Still there? / Not there" card for an alert ahead or one tapped on the map.
struct AlertCard: View {
    let report: Report
    var distanceM: Double?
    let onStillThere: () -> Void
    let onNotThere: () -> Void
    var onClose: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                GimanoIcon(icon: report.type.gIcon, size: 34, stroke: report.type.strokeColor, fill: report.type.fillColor)
                    .frame(width: 56, height: 56)
                    .background(report.type.tileColor, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 4) {
                        Text(report.type.title).font(Tokens.Font.bodyBold)
                        if let sub = report.type.subtypeTitle(report.subtype) {
                            Text("· \(String(localized: sub))").font(Tokens.Font.body)
                        }
                    }
                    HStack(spacing: 4) {
                        if let distanceM { Text("\(ManeuverFormatter.distance(distanceM)) ahead"); Text("·") }
                        if let street = report.street { Text(street).lineLimit(1) }
                    }
                    .font(Tokens.Font.caption)
                    .foregroundStyle(Color.textMuted)
                    Text("\(report.reportedBy?.displayName ?? String(localized: "A driver")) · \(report.createdAt.formatted(.relative(presentation: .named)))")
                        .font(Tokens.Font.nunito(12, .semibold))
                        .foregroundStyle(Color.textMuted)
                }
                Spacer()
                if let onClose {
                    Button(action: onClose) {
                        Image(systemName: "xmark").font(.system(size: 14, weight: .bold)).foregroundStyle(Color.textMuted)
                    }
                    .accessibilityLabel(Text("Close"))
                }
            }
            Text("Still there?").font(Tokens.Font.label).foregroundStyle(Color.textMuted)
            HStack(spacing: 10) {
                Button(action: onStillThere) { Label("Still there", systemImage: "hand.thumbsup.fill") }
                    .buttonStyle(PrimaryButtonStyle())
                Button(action: onNotThere) { Label("Not there", systemImage: "hand.thumbsdown.fill") }
                    .buttonStyle(SecondaryButtonStyle())
            }
        }
        .foregroundStyle(Color.textPrimary)
        .padding(Tokens.Space.gutter)
        .background(Color.surface, in: RoundedRectangle(cornerRadius: Tokens.Radius.lg, style: .continuous))
        .fabShadow()
        .accessibilityIdentifier("alertCard")
    }
}

struct AlertDetailSheet: View {
    @Environment(AppModel.self) private var model
    let report: Report

    var body: some View {
        VStack(spacing: 12) {
            AlertCard(report: report, distanceM: Geo.distance(model.position, report.location),
                      onStillThere: { model.vote(report, stillThere: true) },
                      onNotThere: { model.vote(report, stillThere: false) })
            HStack {
                Label("\(report.confirmations)", systemImage: "checkmark.seal.fill")
                Spacer()
                Button { model.thank(report) } label: { Label("Thanks \(report.thanks)", systemImage: "heart.fill") }
            }
            .font(Tokens.Font.label)
            .foregroundStyle(Color.textMuted)
            .padding(.horizontal, 8)
        }
        .padding(Tokens.Space.gutter)
    }
}

struct ArrivedCard: View {
    let destination: Destination
    let onDone: () -> Void
    /// Arrived at a point chosen on the map: offer once to name (save) it on this phone.
    var onName: (() -> Void)? = nil

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "flag.checkered.circle.fill").font(.system(size: 54)).foregroundStyle(Color.brand)
            Text("You've arrived").font(Tokens.Font.title)
            Text(destination.name).font(Tokens.Font.body).foregroundStyle(Color.textMuted)
            if let onName {
                Button(action: onName) { Label("Name this place?", systemImage: "star") }
                    .buttonStyle(SecondaryButtonStyle())
                    .accessibilityIdentifier("namePinPlace")
            }
            Button("Done", action: onDone).buttonStyle(PrimaryButtonStyle())
        }
        .padding(24)
        .frame(maxWidth: .infinity)
        .background(
            UnevenRoundedRectangle(topLeadingRadius: Tokens.Radius.sheetTop, topTrailingRadius: Tokens.Radius.sheetTop)
                .fill(Color.surface)
                .ignoresSafeArea(edges: .bottom)
        )
    }
}

/// Alternate routes while driving.
struct DriveAlternativesSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let nav: NavigationSession
    @State private var routes: [Route] = []
    @State private var loading = true
    private var remainingStops: [TripStop] { Array(nav.stops.dropFirst(nav.stopTracker.nextStopIndex)) }

    var body: some View {
        NavigationStack {
            List {
                if loading { ProgressView() }
                ForEach(routes) { r in
                    Button {
                        nav.setRoute(r, stops: remainingStops)
                        dismiss()
                    } label: {
                        HStack {
                            VStack(alignment: .leading) {
                                Text(r.summary).font(Tokens.Font.bodyBold).lineLimit(1)
                                Text(LocalizedStringKey(r.trafficDescription ?? "")).font(Tokens.Font.caption).foregroundStyle(Color.textMuted)
                            }
                            Spacer()
                            VStack(alignment: .trailing) {
                                Text(ETAFormatter.duration(r.effectiveDurationS)).font(Tokens.Font.bodyBold)
                                Text(ManeuverFormatter.distance(r.distanceM)).font(Tokens.Font.caption).foregroundStyle(Color.textMuted)
                            }
                        }
                        .foregroundStyle(Color.textPrimary)
                    }
                }
            }
            .navigationTitle("Alternative routes")
            .navigationBarTitleDisplayMode(.inline)
        }
        .task {
            let req = RouteRequest(origin: RouteEndpoint(lat: model.position.lat, lng: model.position.lng),
                                   destination: RouteEndpoint(lat: nav.destination.location.lat, lng: nav.destination.location.lng, placeId: nav.destination.placeId),
                                   waypoints: remainingStops.map(\.endpoint), vehicle: nav.vehicle, avoid: nav.avoid, alternatives: 2)
            routes = (try? await model.repo.routes(req)) ?? []
            loading = false
        }
    }
}

/// Share my drive: link (key only in the fragment), BM/EN message, Stop sharing.
struct ShareDriveSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let session: DriveShareSession
    let nav: NavigationSession
    @State private var copied = false
    @Environment(\.openURL) private var openURL

    private var message: String {
        ShareCrypto.message(destination: nav.destination.name, eta: ETAFormatter.arrivalTime(remainingS: nav.remainingS), link: session.link)
    }

    private func tileLabel(_ title: LocalizedStringKey, system: String, tint: Color) -> some View {
        VStack(spacing: 6) {
            Image(systemName: system).font(.system(size: 26, weight: .bold)).foregroundStyle(.white)
                .frame(width: 52, height: 52)
                .background(tint, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            Text(title).font(Tokens.Font.small).foregroundStyle(Color.textPrimary).lineLimit(1).minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, minHeight: 78)
    }

    /// Opens a messaging app with the message pre-filled (falls back to the share sheet if it isn't installed).
    private func appTile(_ title: LocalizedStringKey, system: String, tint: Color, url: String, id: String) -> some View {
        Button {
            let encoded = message.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ""
            if let u = URL(string: url + encoded) {
                openURL(u) { ok in if !ok { UIPasteboard.general.string = message; model.showToast(String(localized: "Link copied")) } }
            }
        } label: { tileLabel(title, system: system, tint: tint) }
            .buttonStyle(.plain)
            .accessibilityIdentifier(id)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                GimanoIcon(icon: .logo, size: 36)
                    .frame(width: 60, height: 60)
                    .background(Color.brandMist, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text("Share my drive").font(Tokens.Font.title)
                    Text("Until you arrive · ends \(session.created.expiresAt.formatted(date: .omitted, time: .shortened)) at the latest")
                        .font(Tokens.Font.caption).foregroundStyle(Color.textMuted)
                }
            }
            Text(verbatim: message)
                .font(Tokens.Font.caption)
                .foregroundStyle(Color.textPrimary)
                .lineLimit(4)
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.surfaceAlt, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            HStack(spacing: 10) {
                appTile("WhatsApp", system: "message.fill", tint: Color(uiColor: UIColor(hex: 0x25D366)),
                        url: "whatsapp://send?text=", id: "shareWhatsApp")
                appTile("Telegram", system: "paperplane.fill", tint: Color(uiColor: UIColor(hex: 0x229ED9)),
                        url: "tg://msg?text=", id: "shareTelegram")
                appTile("SMS", system: "bubble.left.fill", tint: .brand, url: "sms:&body=", id: "shareSMS")
                Button {
                    UIPasteboard.general.string = message
                    copied = true
                    model.showToast(String(localized: "Link copied"))
                } label: { tileLabel("Copy", system: copied ? "checkmark" : "doc.on.doc.fill", tint: .brandInk) }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("shareCopy")
            }
            ShareLink(item: message) {
                Label("More apps…", systemImage: "square.and.arrow.up")
            }
            .buttonStyle(SecondaryButtonStyle())
            .accessibilityIdentifier("sendShareLink")
            Label("End-to-end encrypted: only people with the link can see your position. Gimano's server can't read it.",
                  systemImage: "lock.fill")
                .font(Tokens.Font.caption)
                .foregroundStyle(Color.textMuted)
            Text(verbatim: session.link.absoluteString)
                .font(.system(size: 1)).opacity(0.01)
                .accessibilityIdentifier("shareLink")
            if let e = session.lastError { Text(e).font(Tokens.Font.caption).foregroundStyle(Color.speeding) }
            Button(role: .destructive) {
                model.stopSharing()
                dismiss()
            } label: { Text("Stop sharing") }
                .buttonStyle(SecondaryButtonStyle())
                .accessibilityIdentifier("stopSharing")
        }
        .padding(Tokens.Space.gutter)
    }
}
