import SwiftUI

// Screens of "public content safety" (canvas "Manotu AI Content Safety"): icon-led, very little text. Every reason shown
// here comes from a fixed code (ContentReason), never from the model's words.

// MARK: - 1. Place warning banner

/// Amber banner on the place page: one icon per warning, one short line, `?` explains, flag = "Not right? Tell us".
struct WarningBanner: View {
    let warnings: [PlaceWarning]
    /// nil hides the flag (the add-place preview).
    var onFlag: (() -> Void)?
    @State private var explain = false

    var body: some View {
        HStack(spacing: 10) {
            HStack(spacing: -6) {
                ForEach(warnings, id: \.self) { w in
                    Image(systemName: w.symbol)
                        .font(.system(size: 17, weight: .bold))
                        .foregroundStyle(Color.amberInk)
                        .frame(width: 36, height: 36)
                        .background(Color.amberMist, in: Circle())
                        .overlay(Circle().strokeBorder(Color.amberEdge, lineWidth: 2))
                }
            }
            .accessibilityHidden(true)
            Text(String(localized: WarningCopy.line(warnings)))
                .font(Tokens.Font.nunito(15, .extrabold, relativeTo: .subheadline))
                .foregroundStyle(Color.amberInk)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button { explain = true } label: {
                Image(systemName: "questionmark.circle.fill").font(.system(size: 24)).foregroundStyle(Color.amberInk)
                    .frame(width: 44, height: 44).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("What does this mean?"))
            .accessibilityIdentifier("warningExplain")
            if let onFlag {
                Button(action: onFlag) {
                    Image(systemName: "flag.fill").font(.system(size: 18)).foregroundStyle(Color.amberInk)
                        .frame(width: 44, height: 44).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("Not right? Tell us"))
                .accessibilityIdentifier("warningFlag")
            }
        }
        .padding(.leading, 10).padding(.trailing, 2).padding(.vertical, 4)
        .background(Color.amberMist, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Color.amberEdge, lineWidth: 1.5))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("warningBanner")
        .alert(Text("About this warning"), isPresented: $explain) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(String(localized: WarningCopy.explain))
        }
    }
}

// MARK: - 2. Reviews

/// Five 48pt stars; tapping one starts a review with that rating.
struct StarRatingRow: View {
    let onPick: (Int) -> Void

    var body: some View {
        HStack(spacing: 4) {
            ForEach(1...5, id: \.self) { n in
                Button { onPick(n) } label: {
                    Image(systemName: "star").font(.system(size: 30))
                        .foregroundStyle(Color(uiColor: Tokens.Palette.traffic2))
                        .frame(width: 48, height: 48).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("\(n) stars"))
                .accessibilityIdentifier("quickStar.\(n)")
            }
        }
        .frame(maxWidth: .infinity)
    }
}

/// A tile with a symbol; `crossed` draws the diagonal slash, `lit` is the offending state.
struct CrossedTile: View {
    let symbol: String
    var label: String?
    var crossed = true
    var lit = true
    var size: CGFloat = 60

    var body: some View {
        VStack(spacing: 4) {
            ZStack {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(lit ? Color.coralMist : Color.surfaceAlt)
                Image(systemName: symbol).font(.system(size: size * 0.42, weight: .bold))
                    .foregroundStyle(lit ? Color.report : Color.textMuted.opacity(0.55))
                if crossed {
                    Capsule().fill(lit ? Color.report : Color.textMuted.opacity(0.4))
                        .frame(width: size * 0.9, height: 4).rotationEffect(.degrees(-45))
                }
            }
            .frame(width: size, height: size)
            if let label {
                Text(verbatim: label).font(Tokens.Font.small).foregroundStyle(Color.textMuted).lineLimit(2)
                    .multilineTextAlignment(.center).frame(width: size + 16)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: label ?? symbol))
    }
}

/// Under the review box: the three advert tiles light up as the text looks like one.
struct AdHintTiles: View {
    let hints: Set<AdHint>

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                ForEach(AdHint.allCases, id: \.self) { h in
                    CrossedTile(symbol: h.tile.symbol, label: String(localized: h.tile.label), lit: hints.contains(h), size: 52)
                }
                Spacer(minLength: 0)
            }
            Text("A vape shop is next door is fine. Offers, numbers and links are not.")
                .font(Tokens.Font.small).foregroundStyle(Color.textMuted).fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityIdentifier("adHintTiles")
    }
}

/// "Can't post this": nothing was stored. Offers the safe part, Edit and Appeal.
struct CantPostSheet: View {
    let reasons: [ContentReason]
    let safeText: String?
    let onPostSafe: () -> Void
    let onEdit: () -> Void
    let onAppeal: () -> Void

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                Image(systemName: "xmark.shield.fill").font(.system(size: 44, weight: .bold)).foregroundStyle(.white)
                    .frame(width: 88, height: 88).background(Color.report, in: Circle())
                    .accessibilityHidden(true)
                Text("Can't post this").font(Tokens.Font.title).accessibilityAddTraits(.isHeader)
                HStack(spacing: 12) {
                    ForEach(ContentFailure.tiles(for: reasons), id: \.self) { t in
                        CrossedTile(symbol: t.symbol, label: String(localized: t.label))
                    }
                }
                VStack(spacing: 4) {
                    ForEach(reasons.prefix(3), id: \.self) { r in
                        Text(String(localized: r.copy)).font(Tokens.Font.caption).foregroundStyle(Color.textMuted)
                    }
                }
                .accessibilityIdentifier("cantPostReasons")
                if let safeText {
                    VStack(alignment: .leading, spacing: 10) {
                        Label("This part is fine", systemImage: "checkmark.circle.fill")
                            .font(Tokens.Font.label).foregroundStyle(Color.tealInk)
                        Text(verbatim: safeText).font(Tokens.Font.body).frame(maxWidth: .infinity, alignment: .leading)
                            .accessibilityIdentifier("safeText")
                        Button("Post this part", action: onPostSafe)
                            .buttonStyle(PrimaryButtonStyle())
                            .accessibilityIdentifier("postSafePart")
                    }
                    .padding(14)
                    .background(Color.tealMist, in: RoundedRectangle(cornerRadius: Tokens.Radius.md, style: .continuous))
                }
                Button("Edit", action: onEdit)
                    .buttonStyle(SecondaryButtonStyle())
                    .accessibilityIdentifier("cantPostEdit")
                Button(action: onAppeal) {
                    Label("Appeal", systemImage: "person.fill.questionmark")
                        .font(Tokens.Font.bodyBold).frame(maxWidth: .infinity, minHeight: 44)
                }
                .accessibilityIdentifier("cantPostAppeal")
            }
            .padding(Tokens.Space.xl)
        }
        .accessibilityIdentifier("cantPostSheet")
    }
}

/// Posting is paused for a while (403 `posting_paused`).
struct PausedCard: View {
    let until: Date

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "pause.circle.fill").font(.system(size: 30)).foregroundStyle(Color.amberInk).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("Paused").font(Tokens.Font.bodyBold).foregroundStyle(Color.amberInk)
                Text("Back in \(PostingPause.hoursLeft(until: until)) h").font(Tokens.Font.caption).foregroundStyle(Color.amberInk)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .background(Color.amberMist, in: RoundedRectangle(cornerRadius: Tokens.Radius.md, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Tokens.Radius.md, style: .continuous).strokeBorder(Color.amberEdge, lineWidth: 1.5))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("pausedCard")
    }
}

/// The author's own review, while it isn't simply published.
struct ModerationChip: View {
    let moderation: ContentModeration
    var onAppeal: (() -> Void)?

    var body: some View {
        switch moderation.state {
        case .checking, .held:
            chip(moderation.state == .held ? "person.fill" : "clock.fill",
                 moderation.state == .held ? String(localized: "A person will check this") : String(localized: "Checking"))
        case .rejected:
            VStack(alignment: .leading, spacing: 2) {
                chip("xmark.circle.fill", String(localized: "Not accepted"))
                if moderation.canAppeal, let onAppeal {
                    Button("Ask a person", action: onAppeal).font(Tokens.Font.label).frame(minHeight: 44)
                        .accessibilityIdentifier("reviewAppeal")
                }
            }
        case .passed, .skipped:
            EmptyView()
        }
    }

    private func chip(_ symbol: String, _ text: String) -> some View {
        Label(text, systemImage: symbol).font(Tokens.Font.label).foregroundStyle(Color.amberInk)
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(Color.amberMist, in: Capsule())
            .accessibilityIdentifier("moderationChip")
    }
}

// MARK: - Appeal (review or photo)

enum AppealSubject: Equatable, Sendable {
    case review(id: String)
    case photo(id: String)
}

/// "Ask a person" on the user's own held / rejected review or photo: the shared appeal screen (note required).
struct ContentAppealSheet: View {
    let subject: AppealSubject
    var onSent: () -> Void = {}

    var body: some View {
        switch subject {
        case .review(let id): AppealScreen(source: .review(id: id), onSent: onSent)
        case .photo(let id): AppealScreen(source: .photo(id: id), onSent: onSent)
        }
    }
}

// MARK: - 3. Photos

struct UploadedPhoto: Identifiable {
    let id = UUID()
    let preview: UIImage
    var photo: Photo
}

extension PhotoBadge {
    var tint: Color {
        switch self {
        case .published: .tealInk
        case .checking: .amberInk
        case .rejected: .report
        }
    }

    var spoken: String {
        switch self {
        case .published: String(localized: "Photo published")
        case .checking: String(localized: "Photo being checked")
        case .rejected: String(localized: "Photo not accepted")
        }
    }
}

/// One square photo tile with a round status badge (tick, clock, cross). Polls `GET /photos/{id}` until it is final.
struct PhotoStatusTile: View {
    @Environment(AppModel.self) private var model
    let item: UploadedPhoto
    let onUpdate: (Photo) -> Void
    let onTapRejected: (Photo) -> Void

    var body: some View {
        let badge = PhotoBadge.of(item.photo)
        Button { if badge == .rejected { onTapRejected(item.photo) } } label: {
            ZStack(alignment: .bottomTrailing) {
                if badge == .rejected {
                    Color.surfaceAlt.overlay(Image(systemName: "eye.slash.fill").font(.system(size: 34)).foregroundStyle(Color.textMuted))
                } else {
                    Image(uiImage: item.preview).resizable().scaledToFill()
                }
                Image(systemName: badge.symbol).font(.system(size: 14, weight: .black)).foregroundStyle(.white)
                    .frame(width: 30, height: 30).background(badge.tint, in: Circle())
                    .overlay(Circle().strokeBorder(.white, lineWidth: 2))
                    .padding(8)
            }
            .aspectRatio(1, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(badge.spoken))
        .accessibilityHint(badge == .rejected ? Text("Opens the reasons") : Text(""))
        .accessibilityIdentifier("photoTile")
        .accessibilityValue(Text(verbatim: "\(badge)"))
        .task(id: item.id) {
            let watched = await PhotoWatcher.watch(item.photo) { try await model.repo.photo(id: $0) }
            if watched != item.photo { onUpdate(watched) }
        }
    }
}

/// 2-column grid of the photos just uploaded.
struct UploadedPhotosGrid: View {
    @Binding var items: [UploadedPhoto]
    let onRejected: (UploadedPhoto) -> Void

    var body: some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
            ForEach(items) { item in
                PhotoStatusTile(item: item, onUpdate: { p in
                    if let i = items.firstIndex(where: { $0.id == item.id }) { items[i].photo = p }
                }, onTapRejected: { _ in onRejected(item) })
            }
        }
        .accessibilityIdentifier("uploadedPhotosGrid")
    }
}

/// A photo that wasn't accepted: the hidden tile, the four reasons we look at, and what to do next.
struct RejectedPhotoSheet: View {
    let reasons: [String]
    let canAppeal: Bool
    let onAnother: () -> Void
    let onAppeal: () -> Void

    var body: some View {
        let lit = PhotoWatcher.litTiles(reasons)
        ScrollView {
            VStack(spacing: 18) {
                Image(systemName: "eye.slash.fill").font(.system(size: 40)).foregroundStyle(Color.textMuted)
                    .frame(width: 120, height: 120).background(Color.surfaceAlt, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
                    .accessibilityHidden(true)
                Text("Photo hidden").font(Tokens.Font.title).accessibilityAddTraits(.isHeader)
                HStack(spacing: 10) {
                    ForEach(PhotoWatcher.photoTiles, id: \.self) { t in
                        CrossedTile(symbol: t.symbol, label: String(localized: t.label), crossed: false, lit: lit.contains(t), size: 64)
                    }
                }
                .accessibilityIdentifier("rejectedPhotoTiles")
                Button("Another photo", action: onAnother)
                    .buttonStyle(PrimaryButtonStyle())
                    .accessibilityIdentifier("anotherPhoto")
                if canAppeal {
                    Button(action: onAppeal) {
                        Label("Appeal", systemImage: "person.fill.questionmark")
                            .font(Tokens.Font.bodyBold).frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .accessibilityIdentifier("photoAppeal")
                }
            }
            .padding(Tokens.Space.xl)
        }
        .accessibilityIdentifier("rejectedPhotoSheet")
    }
}

// MARK: - 4. Add-place step "Anything people should know?"

struct WarningsStepView: View {
    @Binding var selection: Set<PlaceWarning>
    let onNext: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Anything people should know?").font(Tokens.Font.title).accessibilityAddTraits(.isHeader)
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
                    ForEach(PlaceWarning.allCases, id: \.self) { w in
                        tile(symbol: w.symbol, title: String(localized: w.spoken), on: selection.contains(w), id: "warning.\(w.rawValue)") {
                            selection = WarningSelection.toggled(w, in: selection)
                        }
                    }
                    tile(symbol: "checkmark.circle.fill", title: String(localized: "None"), on: selection.isEmpty, id: "warning.none") {
                        selection = WarningSelection.none(selection)
                    }
                }
                if !selection.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Drivers will see").font(Tokens.Font.label).foregroundStyle(Color.textMuted)
                        WarningBanner(warnings: PlaceWarning.allCases.filter(selection.contains), onFlag: nil)
                    }
                    .accessibilityIdentifier("warningPreview")
                }
                Button("Next", action: onNext)
                    .buttonStyle(PrimaryButtonStyle())
                    .accessibilityIdentifier("warningsNext")
            }
            .padding(Tokens.Space.gutter)
        }
    }

    private func tile(symbol: String, title: String, on: Bool, id: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 8) {
                Image(systemName: symbol).font(.system(size: 34, weight: .bold)).foregroundStyle(Color.brandInk)
                Text(verbatim: title).font(Tokens.Font.label).foregroundStyle(Color.brandInk).multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity, minHeight: 110)
            .selectableTile(on, radius: 22)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(verbatim: title))
        .accessibilityIdentifier(id)
    }
}

// MARK: - 6. Inbox rows for the content check

struct ContentInboxActions: View {
    @Environment(AppModel.self) private var model
    let item: InboxItem
    let status: ContentInboxStatus
    let onEdit: () -> Void
    @State private var appeal: AppealSubject?

    var body: some View {
        HStack(spacing: 8) {
            if status.canEdit {
                Button(action: onEdit) { Label("Edit", systemImage: "pencil").frame(minHeight: 44) }
                    .accessibilityIdentifier("contentEdit")
            }
            if status.canAppeal, let subject = subject {
                Button { appeal = subject } label: { Label("Ask a person", systemImage: "person.fill.questionmark").frame(minHeight: 44) }
                    .accessibilityIdentifier("contentAppeal")
            }
        }
        .font(Tokens.Font.label)
        .buttonStyle(.borderless)
        .sheet(item: Binding(get: { appeal.map(IdentifiedSubject.init) }, set: { appeal = $0?.subject })) { s in
            ContentAppealSheet(subject: s.subject)
        }
    }

    private var subject: AppealSubject? {
        guard let id = item.subjectId ?? item.refId else { return nil }
        switch item.subjectKind {
        case "review": return .review(id: id)
        case "photo": return .photo(id: id)
        default: return nil   // places are appealed from My contributions
        }
    }

    private struct IdentifiedSubject: Identifiable {
        let subject: AppealSubject
        var id: String { switch subject { case .review(let i): "r\(i)"; case .photo(let i): "p\(i)" } }
    }
}

extension ContentInboxStatus {
    var tint: Color {
        switch self {
        case .published: .tealMist
        case .heldForPerson, .checking: .amberMist
        case .rejected: Color(light: 0xFFE2E2, dark: 0x4A1418)
        }
    }
    var ink: Color {
        switch self {
        case .published: .tealInk
        case .heldForPerson, .checking: .amberInk
        case .rejected: .report
        }
    }
    var spoken: String {
        switch self {
        case .published: String(localized: "Published")
        case .heldForPerson: String(localized: "A person will check this")
        case .checking: String(localized: "Checking")
        case .rejected: String(localized: "Not accepted")
        }
    }
}
