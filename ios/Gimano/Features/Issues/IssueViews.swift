import SwiftUI

// MARK: - Labels

extension IssueKind {
    var title: LocalizedStringKey {
        switch self {
        case .roadClosedTemp: "Road closed"
        case .roadNotExist: "No road here"
        case .onewayWrongClosedDir, .onewayWrongOpenDir: "One way"
        case .turnNotAllowed: "Can't turn"
        case .oddRoute: "Odd route"
        case .newRoad: "New road"
        case .placeClosedPerm: "Permanently closed"
        case .placeClosedTemp: "Temporarily closed"
        case .placeHoursWrong: "Opening hours wrong"
        case .placeEntranceWrong: "Entrance or parking wrong"
        case .placeInfoWrong: "Name, type, phone"
        case .placeDuplicate: "Duplicate"
        case .unknown: "Road problem"
        }
    }

    var systemImage: String {
        switch self {
        case .roadClosedTemp: "xmark.octagon.fill"
        case .roadNotExist: "road.lanes"
        case .onewayWrongClosedDir, .onewayWrongOpenDir: "arrow.right.circle.fill"
        case .turnNotAllowed: "arrow.uturn.left.circle.fill"
        case .oddRoute: "point.topleft.down.to.point.bottomright.curvepath"
        case .newRoad: "plus.circle.fill"
        default: "exclamationmark.triangle.fill"
        }
    }
}

extension ClosureDuration {
    var title: LocalizedStringKey {
        switch self {
        case .unknown: "Don't know"
        case .today: "Today"
        case .days: "A few days"
        case .longWorks: "Long roadworks"
        }
    }
}

extension DeviationReason {
    var title: LocalizedStringKey {
        switch self {
        case .closed: "Road closed"
        case .noRoad: "No road here"
        case .oneWay: "One way"
        case .noTurn: "Can't turn"
        case .jam: "Bad jam"
        case .myChoice: "My own choice"
        }
    }
}

enum IssueText {
    static func subtype(_ s: String?) -> String? {
        switch s {
        case "accident": String(localized: "accident")
        case "flood": String(localized: "flood")
        case "event": String(localized: "event")
        case "roadworks": String(localized: "roadworks")
        default: nil
        }
    }

    /// "Avoiding Jalan X: closed (flood) · confirmed by 3 drivers · 2 h ago"
    static func avoidLine(_ i: RouteIssue) -> String {
        var parts: [String] = []
        let road = i.roadName ?? i.summary ?? String(localized: "a road")
        let what = IssueText.subtype(i.subtype).map { String(localized: "closed (\($0))") } ?? String(localized: "closed")
        parts.append(String(localized: "Avoiding \(road): \(what)"))
        if let n = i.confirmations, n >= 1 { parts.append(String(localized: "confirmed by \(Int(n)) drivers")) }
        if let t = i.createdAt { parts.append(t.formatted(.relative(presentation: .named))) }
        return parts.joined(separator: " · ")
    }
}

// MARK: - Report sheet: "Road problem" group

struct RoadProblemPanel: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var kind: IssueKind?
    @State private var duration: ClosureDuration = .unknown
    @State private var sending = false

    static let kinds: [IssueKind] = [.roadClosedTemp, .roadNotExist, .onewayWrongClosedDir, .turnNotAllowed, .oddRoute, .newRoad]
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 10), count: 3)

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            LazyVGrid(columns: columns, spacing: 10) {
                ForEach(Self.kinds, id: \.self) { k in
                    Button { kind = k } label: {
                        VStack(spacing: 6) {
                            Image(systemName: k.systemImage).font(.system(size: 28, weight: .bold)).foregroundStyle(Color.report)
                            Text(k.title).font(Tokens.Font.nunito(13, .black)).multilineTextAlignment(.center).foregroundStyle(Color.brandInk)
                        }
                        .frame(maxWidth: .infinity, minHeight: 88)
                        .selectableTile(kind == k, radius: 18)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("roadProblem.\(k.rawValue)")
                }
            }
            if kind == .roadClosedTemp {
                Text("For how long?").font(Tokens.Font.label).foregroundStyle(Color.textMuted)
                FlowLayout(spacing: 8) {
                    ForEach(ClosureDuration.allCases, id: \.self) { d in
                        Button { duration = d } label: {
                            Text(d.title).font(Tokens.Font.nunito(13, .black))
                                .padding(.horizontal, 12).frame(height: 36)
                                .foregroundStyle(duration == d ? Color.brandOn : Color.brandInk)
                                .background(duration == d ? Color.brand : Color.brandMist, in: Capsule())
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("closureDuration.\(d.rawValue)")
                    }
                }
            }
            Text("One report never closes a road: drivers nearby are asked to confirm.")
                .font(Tokens.Font.small).foregroundStyle(Color.textMuted)
            Button {
                guard let kind else { return }
                sending = true
                Task {
                    let ok = await model.reportIssue(kind, subtype: kind == .roadClosedTemp && duration == .longWorks ? "roadworks" : nil,
                                                     duration: kind == .roadClosedTemp ? duration : nil)
                    sending = false
                    if ok { model.showReport = false; dismiss() }
                }
            } label: { Label("Send", systemImage: "paperplane.fill") }
                .buttonStyle(PrimaryButtonStyle(color: .report, foreground: .reportOn))
                .disabled(kind == nil || sending)
                .accessibilityIdentifier("sendRoadProblem")
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 24)
    }
}

// MARK: - "Why didn't you follow the route?"

struct DeviationPromptSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let event: DeviationEvent
    @State private var neverAgain = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Why didn't you follow the route?").font(Tokens.Font.title)
            if let road = event.roadName {
                Text("We suggested \(road).").font(Tokens.Font.caption).foregroundStyle(Color.textMuted)
            }
            FlowLayout(spacing: 8) {
                ForEach(DeviationReason.allCases, id: \.self) { r in
                    Button {
                        model.answerDeviation(event, r, neverAskAgain: neverAgain)
                        dismiss()
                    } label: {
                        Text(r.title).font(Tokens.Font.nunito(14, .black)).foregroundStyle(Color.brandInk)
                            .padding(.horizontal, 14).frame(height: 40)
                            .background(Color.brandMist, in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("deviation.\(r.rawValue)")
                }
            }
            Toggle("Don't ask again", isOn: $neverAgain).font(Tokens.Font.body).accessibilityIdentifier("deviationNeverAgain")
            Text("Only your answer and that spot are sent, never your trip.").font(Tokens.Font.small).foregroundStyle(Color.textMuted)
            Button("Skip") {
                model.answerDeviation(event, nil, neverAskAgain: neverAgain)
                dismiss()
            }
            .buttonStyle(SecondaryButtonStyle())
            .accessibilityIdentifier("deviationSkip")
        }
        .padding(Tokens.Space.gutter)
    }
}

// MARK: - "Still closed?" while driving

struct StillClosedCard: View {
    @Environment(AppModel.self) private var model
    let issue: Issue

    var body: some View {
        ConfirmCard(
            title: Text("Still closed?"),
            subtitle: IssueText.confirmSubtitle(issue),
            choices: [
                .init(id: "issueVote.still", title: "Still closed", style: .primary, glyph: .cross) { model.voteIssue(issue, .still) },
                .init(id: "issueVote.cleared", title: "It's open", style: .pale, glyph: .check) { model.voteIssue(issue, .cleared) },
                .init(id: "issueVote.unsure", title: "Not sure", style: .outlined, glyph: .question) { model.voteIssue(issue, .unsure) },
            ],
            onTimeout: { model.stillClosedPrompt = nil })
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("stillClosedCard")
    }
}

/// Confirm prompt while driving (board NavSahkan): 22 pt title, "kind · street · age", equal 84 pt answer buttons with the
/// icon above the full label (wrapping with Dynamic Type, never clipped), and a 10 s ring that dismisses the card with
/// no answer.
struct ConfirmCard: View {
    struct Choice: Identifiable {
        enum Style { case primary, pale, outlined }
        enum Glyph { case cross, check, question }
        let id: String
        let title: LocalizedStringKey
        let style: Style
        let glyph: Glyph
        let action: () -> Void
    }

    /// What the title tile shows: the amber no-entry sign (road issues) or the report's own duotone icon (road alerts).
    enum Tile { case noEntry, report(ReportType) }

    let title: Text
    let subtitle: Text
    let choices: [Choice]
    var tile: Tile = .noEntry
    var seconds: Int = ConfirmCountdown.seconds
    let onTimeout: () -> Void
    @State private var start = Date()

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 12) {
                Group {
                    switch tile {
                    case .noEntry:
                        NoEntryGlyph()
                            .frame(width: 32, height: 32)
                            .frame(width: 52, height: 52)
                            .background(Color.amberTile, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    case .report(let t):
                        GimanoIcon(icon: t.gIcon, size: 32, stroke: t.strokeColor, fill: t.fillColor)
                            .frame(width: 52, height: 52)
                            .background(t.tileColor, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    }
                }
                .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    title.font(Tokens.Font.nunito(22, .black, relativeTo: .title2)).foregroundStyle(Color.textPrimary)
                    subtitle.font(Tokens.Font.nunito(14, .bold, relativeTo: .subheadline)).foregroundStyle(Color.tileLabel)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityElement(children: .combine)
                CountdownRing(start: start, seconds: seconds, onDone: onTimeout)
            }
            // Three equal buttons side by side, always (docs/driving.md §6.1): a stacked card at accessibility sizes
            // would cover the maneuver banner, so the card's text stops growing at xxxLarge and long labels shrink.
            HStack(alignment: .top, spacing: 8) {
                ForEach(choices) { c in
                    Button(action: c.action) {
                        VStack(spacing: 6) {
                            ChoiceGlyph(glyph: c.glyph, onPrimary: c.style == .primary).frame(width: 30, height: 30)
                            // The full label on at most 2 lines: the font shrinks before anything is cut.
                            Text(c.title)
                                .font(Tokens.Font.nunito(15, .black, relativeTo: .body))
                                .multilineTextAlignment(.center)
                                .lineLimit(ConfirmCountdown.maxLabelLines)
                                .minimumScaleFactor(ConfirmCountdown.minLabelScale)
                                .allowsTightening(true)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(.horizontal, 6)
                        .padding(.vertical, 8)
                        .frame(maxWidth: .infinity, minHeight: ConfirmCountdown.buttonHeight, maxHeight: .infinity)
                        .foregroundStyle(c.style == .primary ? Color.brandOn : c.style == .pale ? Color.brandInk : Color.textMuted)
                        .background(
                            RoundedRectangle(cornerRadius: 18, style: .continuous)
                                .fill(c.style == .primary ? Color.brand : c.style == .pale ? Color.brandMist : Color.surface)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 18, style: .continuous)
                                .strokeBorder(c.style == .outlined ? Color.outline : .clear, lineWidth: 2)
                        )
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier(c.id)
                }
            }
            // Equal heights: every button takes the tallest label's height.
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .background(Color.surface, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .shadow(color: Color(red: 11 / 255, green: 27 / 255, blue: 58 / 255).opacity(0.22), radius: 11, y: 6)
        .dynamicTypeSize(...ConfirmCountdown.maxTypeSize)
        .onAppear { start = Date() }
    }
}

/// 10 s countdown on the confirm card; tapping the ring dismisses the card too.
enum ConfirmCountdown {
    static let seconds = 10
    /// Answer buttons are at least this tall (board NavSahkan: 84 pt).
    static let buttonHeight: CGFloat = 84
    /// Labels: at most 2 lines, shrinking down to this scale before anything would be cut (docs/driving.md §6.1).
    static let maxLabelLines = 2
    static let minLabelScale: CGFloat = 0.6
    /// The card's text grows with Dynamic Type up to here, so it stays one row of buttons below the maneuver banner.
    static let maxTypeSize = DynamicTypeSize.xxxLarge
    /// Whole seconds left (shown in the ring), never below 0.
    static func remaining(elapsed: TimeInterval, total: Int = seconds) -> Int { max(0, Int((Double(total) - elapsed).rounded(.up))) }
    /// Ring fill 1 → 0.
    static func progress(elapsed: TimeInterval, total: Int = seconds) -> Double { max(0, min(1, 1 - elapsed / Double(total))) }
}

private struct CountdownRing: View {
    let start: Date
    let seconds: Int
    let onDone: () -> Void

    var body: some View {
        TimelineView(.periodic(from: start, by: 0.25)) { ctx in
            let elapsed = ctx.date.timeIntervalSince(start)
            Button(action: onDone) {
                ZStack {
                    Circle().stroke(Color.brandMist, lineWidth: 4)
                    Circle().trim(from: 0, to: ConfirmCountdown.progress(elapsed: elapsed, total: seconds))
                        .stroke(Color.brand, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                    Text(verbatim: "\(ConfirmCountdown.remaining(elapsed: elapsed, total: seconds))")
                        .font(Tokens.Font.nunito(12, .black)).foregroundStyle(Color.brand)
                }
                .frame(width: 40, height: 40)
                .frame(width: 44, height: 44)
                .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("Close"))
            .accessibilityValue(Text(verbatim: "\(ConfirmCountdown.remaining(elapsed: elapsed, total: seconds)) s"))
            .accessibilityIdentifier("confirmCountdown")
        }
        .task(id: start) {
            try? await Task.sleep(for: .seconds(Double(seconds)))
            if !Task.isCancelled { onDone() }
        }
    }
}

private struct ChoiceGlyph: View {
    let glyph: ConfirmCard.Choice.Glyph
    /// On the blue primary button the glyph is white.
    var onPrimary = false

    var body: some View {
        Canvas { ctx, size in
            let s = min(size.width, size.height) / 24
            var t = CGAffineTransform(scaleX: s, y: s)
            func stroke(_ d: String) -> Path { let p = SVGPath.parse(d).stroke; return Path(p.copy(using: &t) ?? p) }
            func fill(_ d: String) -> Path { let p = SVGPath.parse(d).fill; return Path(p.copy(using: &t) ?? p) }
            let disc = fill("M12 2a10 10 0 1 1 0 20 10 10 0 0 1 0-20z")
            switch glyph {
            case .cross where onPrimary:
                ctx.fill(disc, with: .color(.white.opacity(0.25)))
                ctx.stroke(stroke("M8 8l8 8M16 8l-8 8"), with: .color(.white), style: StrokeStyle(lineWidth: 2.6 * s, lineCap: .round))
            case .cross:
                ctx.fill(disc, with: .color(Color.brandTint))
                ctx.stroke(stroke("M8 8l8 8M16 8l-8 8"), with: .color(Color.brand), style: StrokeStyle(lineWidth: 2.6 * s, lineCap: .round))
            case .check where onPrimary:
                ctx.fill(disc, with: .color(.white.opacity(0.25)))
                ctx.stroke(stroke("m7 12.5 3.2 3.2L17 9"), with: .color(.white),
                           style: StrokeStyle(lineWidth: 2.6 * s, lineCap: .round, lineJoin: .round))
            case .check:
                ctx.fill(disc, with: .color(Color.brandTint))
                ctx.stroke(stroke("m7 12.5 3.2 3.2L17 9"), with: .color(Color.brand),
                           style: StrokeStyle(lineWidth: 2.6 * s, lineCap: .round, lineJoin: .round))
            case .question:
                ctx.fill(disc, with: .color(Color.surfaceAlt))
                ctx.stroke(stroke("M9.5 9.2a2.6 2.6 0 1 1 3.7 2.4c-.8.4-1.2.9-1.2 1.8v.4M12 16.6v.2"), with: .color(Color.tileLabel),
                           style: StrokeStyle(lineWidth: 2.2 * s, lineCap: .round))
            }
        }
        .accessibilityHidden(true)
    }
}

/// The amber no-entry sign on the confirm card's tile.
private struct NoEntryGlyph: View {
    var body: some View {
        Canvas { ctx, size in
            let s = min(size.width, size.height) / 24
            var t = CGAffineTransform(scaleX: s, y: s)
            ctx.fill(Path(ellipseIn: CGRect(x: 3 * s, y: 3 * s, width: 18 * s, height: 18 * s)), with: .color(Color(light: 0xFFE2A8, dark: 0x6B4A12)))
            let d = "M12 4.5a7.5 7.5 0 1 1 0 15 7.5 7.5 0 0 1 0-15zm0 2a5.5 5.5 0 0 0-4.4 8.8l7.7-7.7A5.5 5.5 0 0 0 12 6.5zm4.4 2.2-7.7 7.7a5.5 5.5 0 0 0 7.7-7.7z"
            let p = SVGPath.parse(d).fill
            ctx.fill(Path(p.copy(using: &t) ?? p), with: .color(Color(light: 0x7A5200, dark: 0xFFD27A)), style: FillStyle(eoFill: true))
        }
        .accessibilityHidden(true)
    }
}

extension Color {
    /// Amber tile behind the confirm card's sign (#FFF1CC).
    static let amberTile = Color(light: 0xFFF1CC, dark: 0x3A2E12)
}

extension IssueText {
    /// "Can't turn · Jalan SS 2/3 · 5 hours ago".
    static func confirmSubtitle(_ i: Issue) -> Text {
        var parts: [Text] = [Text(i.kind.title)]
        if let street = i.streetName, !street.isEmpty { parts.append(Text(verbatim: street)) }
        if let at = i.lastEvidenceAt ?? i.createdAt {
            parts.append(Text(at.formatted(.relative(presentation: .named, unitsStyle: .wide))))
        }
        return parts.dropFirst().reduce(parts[0]) { $0 + Text(verbatim: " · ") + $1 }
    }
}

// MARK: - Route preview: "Avoiding …" / warnings

struct RouteIssuesBanner: View {
    @Environment(AppModel.self) private var model
    let route: Route
    @State private var details: RouteIssue?

    var body: some View {
        let issues = (route.issues ?? []).filter { $0.state.isOpen }
        VStack(alignment: .leading, spacing: 8) {
            ForEach(issues) { i in
                VStack(alignment: .leading, spacing: 6) {
                    if i.avoided == true {
                        Label(IssueText.avoidLine(i), systemImage: "arrow.triangle.branch").font(Tokens.Font.caption)
                        HStack(spacing: 12) {
                            Button("Details") { details = i }.font(Tokens.Font.label)
                            Button("Drive through anyway (I know this road)") { model.driveThroughAnyway(i) }
                                .font(Tokens.Font.label)
                                .accessibilityIdentifier("driveThroughAnyway")
                        }
                    } else {
                        Label(String(localized: "Reported on this route: \(i.roadName ?? i.summary ?? String(localized: "a road"))"),
                              systemImage: "exclamationmark.triangle.fill")
                            .font(Tokens.Font.caption)
                    }
                }
                .foregroundStyle(Color.amberInk)
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.amberMist, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .accessibilityIdentifier("routeIssueBanner")
            }
        }
        .sheet(item: $details) { i in
            VStack(alignment: .leading, spacing: 10) {
                Label { Text(i.kind.title) } icon: { Image(systemName: i.kind.systemImage) }.font(Tokens.Font.title)
                Text(IssueText.avoidLine(i)).font(Tokens.Font.body)
                Text(i.state == .confirmed ? "Confirmed by drivers nearby." : "Reported, waiting for confirmation.")
                    .font(Tokens.Font.caption).foregroundStyle(Color.textMuted)
                Text("Reports expire, and traffic driving through clears them.").font(Tokens.Font.small).foregroundStyle(Color.textMuted)
            }
            .padding(Tokens.Space.gutter)
            .presentationDetents([.height(240)])
        }
    }
}

// MARK: - Place card: "Suggest an edit" menu + badges

struct PlaceIssueBadges: View {
    @Environment(AppModel.self) private var model
    let placeId: String
    let location: LatLng
    @State private var issues: [Issue] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(issues) { i in
                switch i.kind {
                case .placeClosedPerm:
                    VStack(alignment: .leading, spacing: 8) {
                        Label("Reported closed · confirm?", systemImage: "exclamationmark.triangle.fill").font(Tokens.Font.bodyBold)
                        HStack(spacing: 8) {
                            Button("Closed") { vote(i, .still) }.buttonStyle(SecondaryButtonStyle())
                            Button("Still open") { vote(i, .cleared) }.buttonStyle(SecondaryButtonStyle())
                        }
                    }
                    .padding(12)
                    .background(Color.amberMist, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .accessibilityIdentifier("badgeReportedClosed")
                case .placeClosedTemp:
                    Label(i.closedUntil.map { String(localized: "Temporarily closed until \($0.formatted(date: .abbreviated, time: .omitted))") }
                          ?? String(localized: "Temporarily closed"), systemImage: "clock.badge.xmark")
                        .font(Tokens.Font.bodyBold).foregroundStyle(Color.amberInk)
                        .accessibilityIdentifier("badgeClosedTemp")
                case .placeHoursWrong:
                    Label("Hours may have changed", systemImage: "clock.arrow.circlepath").font(Tokens.Font.caption).foregroundStyle(Color.amberInk)
                default:
                    EmptyView()
                }
            }
        }
        .task(id: placeId) {
            let box = BBox(minLng: location.lng, minLat: location.lat, maxLng: location.lng, maxLat: location.lat).expanded(byM: 300)
            let kinds: [IssueKind] = [.placeClosedPerm, .placeClosedTemp, .placeHoursWrong]
            let blocked = model.blockedRefs
            issues = ((try? await model.repo.issuesNearby(bbox: box, kinds: kinds)) ?? []).filter {
                $0.placeId == placeId && $0.state.isOpen && !($0.reportedBy?.authorRef.map(blocked.contains) ?? false)
            }
        }
    }

    private func vote(_ i: Issue, _ a: IssueVoteAnswer) {
        issues.removeAll { $0.id == i.id }
        model.voteIssue(i, a)
    }
}

/// The non-field "Suggest an edit" choices (closures, hours, entrance, duplicate) are sent as place issues.
struct PlaceIssueSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let kind: IssueKind
    let placeId: String
    let location: LatLng
    @State private var until = Date().addingTimeInterval(7 * 86400)
    @State private var hours = OpeningHours()
    @State private var sending = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                switch kind {
                case .placeClosedTemp:
                    DatePicker("Closed until", selection: $until, in: Date()...Date().addingTimeInterval(60 * 86400), displayedComponents: .date)
                        .accessibilityIdentifier("closedUntil")
                case .placeHoursWrong:
                    OpeningHoursEditor(hours: $hours)
                default:
                    Text(kind == .placeClosedPerm ? "Drivers nearby will be asked to confirm before anything changes."
                                                  : "A maintainer will check it.")
                }
                Section {
                    Button("Send") {
                        sending = true
                        Task {
                            var payload: [String: String] = [:]
                            // The API takes a Malaysian calendar day (yyyy-MM-dd), not a timestamp (400 otherwise).
                            if kind == .placeClosedTemp { payload["until"] = PlaceIssuePayload.untilDay(until) }
                            if kind == .placeHoursWrong { payload["openingHours"] = hours.osm }
                            let ok = await model.reportIssue(kind, placeId: placeId, at: location, source: .placeEdit,
                                                             payload: payload.isEmpty ? nil : payload)
                            sending = false
                            // The toast sits behind this sheet: show a failure here too.
                            if ok { dismiss() } else { error = model.toast ?? String(localized: "Couldn't send. Try again.") }
                        }
                    }
                    .disabled(sending)
                    .accessibilityIdentifier("sendPlaceIssue")
                    if let error {
                        Text(error).font(Tokens.Font.caption).foregroundStyle(Color(uiColor: Tokens.Palette.speeding))
                            .accessibilityIdentifier("placeIssueError")
                    }
                }
            }
            .navigationTitle(Text(kind.title))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarLeading) { Button("Cancel") { dismiss() } } }
        }
    }
}

enum PlaceIssuePayload {
    /// "Closed until" as the API wants it: the chosen day in Malaysia (yyyy-MM-dd).
    static func untilDay(_ date: Date) -> String {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Asia/Kuala_Lumpur") ?? .current
        let c = cal.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }
}
