import SwiftUI
import PhotosUI

// "Not accepted" list (reached from the Inbox) and the one appeal screen (docs/content-safety.md "Appeals").
// Icon-led, little text. Everything shown here lives on this phone; it is sent only when the user taps Send.

// MARK: - Inbox row

/// First row of the Inbox when something was refused: a big icon, a count badge, opens the list.
struct NotAcceptedInboxRow: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        NavigationLink {
            NotAcceptedView()
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "xmark.shield.fill").font(.system(size: 28, weight: .bold)).foregroundStyle(Color.report)
                    .frame(width: 56, height: 56)
                    .background(Color(light: 0xFFE2E2, dark: 0x4A1418), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .accessibilityHidden(true)
                Text("Not accepted").font(Tokens.Font.bodyBold)
                Spacer()
                if model.refusedBadge > 0 {
                    Text(verbatim: "\(model.refusedBadge)").font(Tokens.Font.label).foregroundStyle(.white)
                        .frame(minWidth: 26, minHeight: 26).padding(.horizontal, 4)
                        .background(Color.report, in: Capsule())
                        .accessibilityIdentifier("notAcceptedBadge")
                }
            }
        }
        .accessibilityIdentifier("notAcceptedRow")
    }
}

// MARK: - The list

struct NotAcceptedView: View {
    @Environment(AppModel.self) private var model
    @State private var appeal: RefusedContent?

    var body: some View {
        List {
            if model.refusedItems.isEmpty {
                ContentUnavailableView("Nothing here", systemImage: "checkmark.shield")
                    .accessibilityIdentifier("notAcceptedEmpty")
                    .listRowBackground(Color.clear)
            }
            ForEach(model.refusedItems) { item in
                RefusedCard(item: item, onAppeal: { appeal = item }, onDelete: { model.deleteRefused(id: item.id) })
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
            }
            Label("Kept only on this phone for \(RefusedRules.keepDays) days. Sent only if you appeal.", systemImage: "lock.fill")
                .font(Tokens.Font.small).foregroundStyle(Color.textMuted)
                .listRowBackground(Color.clear)
                .accessibilityIdentifier("notAcceptedPrivacy")
        }
        .listStyle(.plain)
        .navigationTitle("Not accepted")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { model.reloadRefused() }
        .sheet(item: $appeal) { item in
            AppealScreen(source: .refused(item))
        }
    }
}

/// One saved item: kind icon, place, the text, the reason tiles, and Appeal / Pending / Answered.
struct RefusedCard: View {
    @Environment(AppModel.self) private var model
    let item: RefusedContent
    let onAppeal: () -> Void
    let onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: item.kind.symbol).font(.system(size: 20, weight: .bold)).foregroundStyle(Color.report)
                    .frame(width: 40, height: 40).background(Color.coralMist, in: Circle())
                    .accessibilityLabel(Text(String(localized: item.kind.label)))
                Text(verbatim: item.placeName ?? String(localized: item.kind.label)).font(Tokens.Font.bodyBold).lineLimit(1)
                Spacer(minLength: 0)
                Button(role: .destructive, action: onDelete) {
                    Image(systemName: "trash").font(.system(size: 17)).frame(width: 44, height: 44).contentShape(Rectangle())
                }
                .buttonStyle(.plain).foregroundStyle(Color.textMuted)
                .accessibilityLabel(Text("Delete"))
                .accessibilityIdentifier("refusedDelete")
            }
            if !item.text.isEmpty {
                Text(verbatim: item.text).font(Tokens.Font.body).foregroundStyle(Color.textPrimary).lineLimit(4)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if !item.photoFiles.isEmpty { RefusedPhotoThumbs(item: item) }
            HStack(spacing: 8) {
                ForEach(ContentFailure.tiles(for: item.explained), id: \.self) { t in
                    CrossedTile(symbol: t.symbol, label: nil, size: 40)
                }
                if let first = item.explained.first {
                    Text(String(localized: first.copy)).font(Tokens.Font.caption).foregroundStyle(Color.textMuted)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("refusedReasons")
            HStack {
                state
                Spacer()
                Text("\(RefusedRules.daysLeft(item.createdAt)) d").font(Tokens.Font.small).foregroundStyle(Color.textMuted)
                    .accessibilityLabel(Text("\(RefusedRules.daysLeft(item.createdAt)) days left"))
            }
        }
        .padding(14)
        .background(Color.surface, in: RoundedRectangle(cornerRadius: Tokens.Radius.md, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("refusedCard")
    }

    @ViewBuilder private var state: some View {
        switch item.appealState {
        case .none:
            Button(action: onAppeal) {
                Label("Appeal", systemImage: AppealState.none.symbol).font(Tokens.Font.bodyBold).frame(minHeight: 44)
            }
            .buttonStyle(.borderless)
            .accessibilityIdentifier("refusedAppeal")
        case .sent:
            Label("Pending", systemImage: AppealState.sent.symbol).font(Tokens.Font.label).foregroundStyle(Color.amberInk)
                .padding(.horizontal, 10).padding(.vertical, 6).background(Color.amberMist, in: Capsule())
                .accessibilityIdentifier("refusedPending")
        case .answered:
            Label("Answered", systemImage: AppealState.answered.symbol).font(Tokens.Font.label).foregroundStyle(Color.tealInk)
                .padding(.horizontal, 10).padding(.vertical, 6).background(Color.tealMist, in: Capsule())
                .accessibilityIdentifier("refusedAnswered")
        }
    }
}

/// The refused photo(s): an eye-slash tile on the list, the real picture only on the appeal screen (`reveal`).
struct RefusedPhotoThumbs: View {
    @Environment(AppModel.self) private var model
    let item: RefusedContent
    var reveal = false

    var body: some View {
        HStack(spacing: 8) {
            ForEach(item.photoFiles, id: \.self) { name in
                ZStack(alignment: .bottomTrailing) {
                    if reveal, let img = UIImage(contentsOfFile: model.store.refusedFileURL(id: item.id, name).path) {
                        Image(uiImage: img).resizable().scaledToFill()
                    } else {
                        Color.surfaceAlt.overlay(Image(systemName: "eye.slash.fill").font(.system(size: 24)).foregroundStyle(Color.textMuted))
                    }
                    Image(systemName: "xmark").font(.system(size: 11, weight: .black)).foregroundStyle(.white)
                        .frame(width: 22, height: 22).background(Color.report, in: Circle()).padding(4)
                }
                .frame(width: 64, height: 64)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
        }
    }
}

// MARK: - The appeal screen

enum AppealSource: Identifiable {
    case refused(RefusedContent)
    case review(id: String)
    case photo(id: String)

    var id: String {
        switch self { case .refused(let r): "f\(r.id)"; case .review(let i): "r\(i)"; case .photo(let i): "p\(i)" }
    }
}

/// One screen for every appeal: the saved text (when there is one), a REQUIRED note (≤ 200, counter), up to 3 evidence
/// photos from the system photo picker (no permission prompt), Send. Used for refused content (`POST /appeals`) and for
/// the user's own held / rejected review or photo (`POST /reviews|photos/{id}/appeal`).
struct AppealScreen: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let source: AppealSource
    var onSent: () -> Void = {}
    @State private var note = ""
    @State private var extras: [PickedPhoto] = []
    @State private var pickerItems: [PhotosPickerItem] = []
    @State private var sending = false
    @State private var failure: AppealFailure?

    private var refused: RefusedContent? { if case .refused(let r) = source { r } else { nil } }
    private var slots: Int { AppealRules.evidenceSlots(refusedPhotos: refused?.photoFiles.count ?? 0) }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Image(systemName: "person.fill.questionmark").font(.system(size: 40)).foregroundStyle(Color.brand)
                        .frame(maxWidth: .infinity).accessibilityHidden(true)
                    if let until = model.postingPausedUntil, PostingPause.isActive(until: until) { PausedCard(until: until) }
                    if let refused { saved(refused) }
                    noteField
                    photosRow
                    if let failure {
                        Label(failure.message, systemImage: failure.symbol).font(Tokens.Font.caption).foregroundStyle(Color.speeding)
                            .accessibilityIdentifier("appealError")
                    }
                    Button { Task { await send() } } label: {
                        if sending { ProgressView().tint(Color.brandOn) } else { Label("Send", systemImage: "paperplane.fill") }
                    }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(!AppealRules.canSend(note: note, sending: sending))
                    .accessibilityIdentifier("appealSend")
                }
                .padding(Tokens.Space.gutter)
            }
            .navigationTitle("Appeal")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarLeading) { Button("Cancel") { dismiss() } } }
        }
        .accessibilityIdentifier("appealScreen")
    }

    private func saved(_ r: RefusedContent) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: r.kind.symbol).foregroundStyle(Color.report)
                Text(verbatim: r.placeName ?? String(localized: r.kind.label)).font(Tokens.Font.bodyBold).lineLimit(1)
            }
            if !r.text.isEmpty {
                Text(verbatim: r.text).font(Tokens.Font.body).frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("appealSavedText")
            }
            if !r.photoFiles.isEmpty { RefusedPhotoThumbs(item: r, reveal: true) }
            HStack(spacing: 8) {
                ForEach(ContentFailure.tiles(for: r.explained), id: \.self) { CrossedTile(symbol: $0.symbol, label: nil, size: 36) }
            }
        }
        .padding(14).frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.surfaceAlt, in: RoundedRectangle(cornerRadius: Tokens.Radius.md, style: .continuous))
    }

    private var noteField: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Why should it be accepted?", systemImage: "square.and.pencil").font(Tokens.Font.label)
            TextField(String(localized: "Tell us (required)"), text: $note, axis: .vertical)
                .lineLimit(3...5).padding(14)
                .background(Color.surfaceAlt, in: RoundedRectangle(cornerRadius: Tokens.Radius.md, style: .continuous))
                .onChange(of: note) { _, v in
                    if v.count > AppealRules.maxNote { note = AppealRules.clamped(v) }
                    if failure == .noteRequired { failure = nil }
                }
                .accessibilityIdentifier("appealNote")
            Text(verbatim: "\(note.count) / \(AppealRules.maxNote)")
                .font(Tokens.Font.small).foregroundStyle(Color.textMuted).frame(maxWidth: .infinity, alignment: .trailing)
                .accessibilityIdentifier("appealCounter")
        }
    }

    private var photosRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(extras) { p in
                    Image(uiImage: p.preview).resizable().scaledToFill().frame(width: 76, height: 76)
                        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                        .overlay(alignment: .topTrailing) {
                            Button { extras.removeAll { $0.id == p.id } } label: {
                                Image(systemName: "xmark.circle.fill").font(.system(size: 22)).foregroundStyle(.white, .black.opacity(0.6))
                            }
                            .padding(4).accessibilityLabel(Text("Remove photo"))
                        }
                }
                if extras.count < slots {
                    PhotosPicker(selection: $pickerItems, maxSelectionCount: max(1, slots - extras.count), matching: .images) {
                        VStack(spacing: 4) {
                            Image(systemName: "photo.badge.plus").font(.system(size: 26, weight: .bold))
                            Text("Add photo").font(Tokens.Font.small)
                        }
                        .foregroundStyle(Color.brandInk).frame(width: 76, height: 76)
                        .background(Color.surfaceAlt, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    }
                    .accessibilityIdentifier("appealAddPhoto")
                }
            }
        }
        .onChange(of: pickerItems) {
            let items = pickerItems
            pickerItems = []
            Task { extras += await PhotoPicking.load(items).prefix(slots - extras.count) }
        }
    }

    private func send() async {
        guard AppealRules.isValidNote(note) else { failure = .noteRequired; return }
        sending = true
        failure = nil
        defer { sending = false }
        let text = AppealRules.trimmed(note)
        let photos = extras.map(\.jpeg)
        do {
            switch source {
            case .refused(let r):
                let req = AppealRequest(refusalId: r.id, kind: r.kind, placeId: r.placeId, text: r.text, reasons: r.reasons, note: text,
                                        photos: model.store.refusedPhotoData(r) + photos, rating: r.rating)
                _ = try await model.repo.appeal(req)
                model.markRefused(id: r.id, .sent)
            case .review(let id): try await model.repo.appealReview(id: id, note: text, photos: photos)
            case .photo(let id): try await model.repo.appealPhoto(id: id, note: text, photos: photos)
            }
            model.showToast(String(localized: "Sent. A person will look within 24 hours."))
            onSent()
            dismiss()
        } catch {
            let f = AppealFailure.classify(error)
            if case .paused(let until) = f { model.pausePosting(until: until) }
            if f.countsAsSent, case .refused(let r) = source { model.markRefused(id: r.id, .sent) }
            failure = f
        }
    }
}

// MARK: - Badge grid for photos already on the server (own review photos)

/// The same tick / clock / cross badge as a fresh upload, on server photos (the author's own review). A rejected tile
/// opens the reasons with Appeal; a checking tile follows `GET /photos/{id}` until the answer is final.
struct ModeratedPhotoGrid: View {
    @Environment(AppModel.self) private var model
    @State var photos: [Photo]
    var onChange: () async -> Void = {}
    @State private var rejected: Photo?
    @State private var appealing: Photo?

    var body: some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
            ForEach(photos) { photo in
                ModeratedPhotoTile(photo: photo, onUpdate: { p in
                    if let i = photos.firstIndex(where: { $0.id == p.id }) { photos[i] = p }
                }, onTapRejected: { rejected = $0 })
            }
        }
        .accessibilityIdentifier("reviewPhotosGrid")
        .sheet(item: $rejected) { p in
            let m = p.moderation
            RejectedPhotoSheet(reasons: m?.reasons ?? [], canAppeal: m?.canAppeal ?? false, onAnother: { rejected = nil }, onAppeal: {
                rejected = nil
                appealing = p
            })
            .presentationDetents([.medium, .large])
        }
        .sheet(item: $appealing) { p in
            AppealScreen(source: .photo(id: p.id)) { Task { await onChange() } }
        }
    }
}

struct ModeratedPhotoTile: View {
    @Environment(AppModel.self) private var model
    let photo: Photo
    let onUpdate: (Photo) -> Void
    let onTapRejected: (Photo) -> Void

    var body: some View {
        let badge = PhotoBadge.of(photo)
        Button { if badge == .rejected { onTapRejected(photo) } } label: {
            ZStack(alignment: .bottomTrailing) {
                if badge == .rejected || (MediaURL.resolve(photo.thumbUrl ?? photo.url) == nil) {
                    Color.surfaceAlt.overlay(Image(systemName: badge == .rejected ? "eye.slash.fill" : "hourglass")
                        .font(.system(size: 34)).foregroundStyle(Color.textMuted))
                } else if let u = MediaURL.resolve(photo.thumbUrl ?? photo.url) {
                    RemoteImage(url: u)
                }
                Image(systemName: badge.symbol).font(.system(size: 14, weight: .black)).foregroundStyle(.white)
                    .frame(width: 30, height: 30).background(badge.tint, in: Circle())
                    .overlay(Circle().strokeBorder(.white, lineWidth: 2)).padding(8)
            }
            .aspectRatio(1, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(badge.spoken))
        .accessibilityIdentifier("photoTile")
        .accessibilityValue(Text(verbatim: "\(badge)"))
        .task(id: photo.id) {
            let watched = await PhotoWatcher.watch(photo) { try await model.repo.photo(id: $0) }
            if watched != photo { onUpdate(watched) }
        }
    }
}

/// Whether a review's photos show as the badge grid (the author's own review: the server sent a `moderation` block).
enum ReviewPhotoDisplay {
    static func usesBadgeGrid(_ photos: [Photo]?) -> Bool { photos?.contains { $0.moderation != nil } == true }
}
