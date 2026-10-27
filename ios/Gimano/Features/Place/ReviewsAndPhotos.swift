import SwiftUI

// MARK: - Photos

struct PhotoViewerItem: Identifiable {
    let id = UUID()
    let urls: [URL]
    let index: Int
    /// The server photos behind `urls` (same order) when they are public photos: enables Report photo / Block this user.
    var photos: [Photo]? = nil
}

/// Image from a remote or file URL (WebP decodes natively on iOS 14+).
struct RemoteImage: View {
    let url: URL
    var contentMode: ContentMode = .fill

    var body: some View {
        AsyncImage(url: url) { phase in
            switch phase {
            case .success(let img): img.resizable().aspectRatio(contentMode: contentMode)
            case .failure: Image(systemName: "photo").font(.system(size: 24)).foregroundStyle(Color.textMuted)
            default: ProgressView()
            }
        }
    }
}

/// Horizontal gallery strip.
struct PhotoStrip: View {
    let thumbs: [URL]
    let onTap: (Int) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(Array(thumbs.enumerated()), id: \.offset) { i, u in
                    Button { onTap(i) } label: {
                        RemoteImage(url: u)
                            .frame(width: 112, height: 84)
                            .background(Color.surfaceAlt)
                            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("placePhoto")
                    .accessibilityValue(Text(verbatim: u.absoluteString))
                }
            }
        }
    }
}

/// Full-screen swipeable photo viewer.
struct PhotoViewer: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppModel.self) private var model
    let urls: [URL]
    @State var index: Int
    var photos: [Photo]? = nil
    @State private var confirmBlock: Photo?

    private var current: Photo? { photos.flatMap { index < $0.count ? $0[index] : nil } }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.black.ignoresSafeArea()
            TabView(selection: $index) {
                ForEach(Array(urls.enumerated()), id: \.offset) { i, u in
                    RemoteImage(url: u, contentMode: .fit).tag(i)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: urls.count > 1 ? .always : .never))
            .accessibilityIdentifier("photoViewer")
            Button { dismiss() } label: {
                GimanoIcon(icon: .close, size: 22, stroke: .white, fill: .clear)
                    .frame(width: 48, height: 48)
                    .background(.ultraThinMaterial, in: Circle())
            }
            .padding()
            .accessibilityLabel(Text("Close"))
            .accessibilityIdentifier("closeViewer")
        }
        .overlay(alignment: .topLeading) {
            if let photo = current {
                Menu {
                    Menu {
                        FlagReasonButtons { r in
                            Task {
                                try? await model.repo.flagPhoto(id: photo.id, reason: r)
                                model.showToast(String(localized: "Thanks, we'll take a look"))
                            }
                        }
                    } label: { Label("Report photo", systemImage: "flag") }
                        .accessibilityIdentifier("reportPhoto")
                    if photo.blockRef != nil {
                        Button(role: .destructive) { confirmBlock = photo } label: { Label("Block this user", systemImage: "person.crop.circle.badge.xmark") }
                            .accessibilityIdentifier("blockPhotoAuthor")
                    }
                } label: {
                    Image(systemName: "ellipsis").font(.system(size: 20, weight: .bold)).foregroundStyle(.white)
                        .frame(width: 48, height: 48)
                        .background(.ultraThinMaterial, in: Circle())
                }
                .padding()
                .accessibilityLabel(Text("More"))
                .accessibilityIdentifier("photoMore")
            }
        }
        .confirmationDialog("Block this user?", isPresented: Binding(get: { confirmBlock != nil }, set: { if !$0 { confirmBlock = nil } }), titleVisibility: .visible) {
            Button("Block", role: .destructive) {
                if let p = confirmBlock, let ref = p.blockRef {
                    model.blockAuthor(ref: ref, name: p.uploadedBy?.displayName ?? String(localized: "A contributor"))
                    dismiss()
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Their reviews and photos will be hidden on this phone. You can unblock them in Settings.")
        }
    }
}

// MARK: - Stars

struct StarsView: View {
    let rating: Double
    var size: CGFloat = 14

    var body: some View {
        HStack(spacing: 1) {
            ForEach(1...5, id: \.self) { i in
                Image(systemName: Double(i) <= rating + 0.25 ? "star.fill" : (Double(i) - 0.5 <= rating ? "star.leadinghalf.filled" : "star"))
                    .font(.system(size: size))
                    .foregroundStyle(Color(uiColor: Tokens.Palette.traffic2))
            }
        }
        .accessibilityElement()
        .accessibilityLabel(Text("\(Int(rating.rounded())) stars"))
    }
}

// MARK: - Reviews

struct ReviewRow: View {
    @Environment(AppModel.self) private var model
    let review: Review
    let onChange: () async -> Void
    @State private var viewer: PhotoViewerItem?
    @State private var helpfulOn = false
    @State private var confirmBlock = false
    @State private var appealing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(review.author.displayName).font(Tokens.Font.bodyBold)
                if let lvl = review.author.level { Text("Lv \(lvl)").font(Tokens.Font.small).foregroundStyle(Color.textMuted) }
                Spacer()
                Menu {
                    Menu {
                        FlagReasonButtons { r in
                            Task { try? await model.repo.flagReview(id: review.id, reason: r); model.showToast(String(localized: "Thanks, we'll take a look")) }
                        }
                    } label: { Label("Report review", systemImage: "flag") }
                    if review.blockRef != nil {
                        Button(role: .destructive) { confirmBlock = true } label: { Label("Block this user", systemImage: "person.crop.circle.badge.xmark") }
                            .accessibilityIdentifier("blockReviewAuthor")
                    }
                } label: {
                    Image(systemName: "flag").font(.system(size: 14)).foregroundStyle(Color.textMuted).frame(width: 32, height: 32)
                }
                .accessibilityLabel(Text("Report review"))
                .accessibilityIdentifier("flagReview")
            }
            HStack(spacing: 6) {
                StarsView(rating: Double(review.rating), size: 13)
                Text(review.createdAt.formatted(.relative(presentation: .named))).font(Tokens.Font.small).foregroundStyle(Color.textMuted)
                if review.editedAt != nil { Text("edited").font(Tokens.Font.small).foregroundStyle(Color.textMuted) }
            }
            if let t = review.text, !t.isEmpty { Text(t).font(Tokens.Font.body) }
            if let m = review.moderation, m.state != .passed, m.state != .skipped {
                ModerationChip(moderation: m, onAppeal: { appealing = true })
            }
            if let photos = review.photos, !photos.isEmpty, ReviewPhotoDisplay.usesBadgeGrid(photos) {
                // The author's own review: the same tick / clock / cross badge grid as other photos.
                ModeratedPhotoGrid(photos: photos, onChange: onChange)
            } else if let photos = review.photos, !photos.isEmpty {
                let ready = photos.filter { $0.url != nil }
                let urls = ready.compactMap { MediaURL.resolve($0.url) }
                PhotoStrip(thumbs: ready.compactMap { MediaURL.resolve($0.thumbUrl ?? $0.url) }) { i in
                    viewer = PhotoViewerItem(urls: urls, index: i, photos: ready.map { var p = $0; if p.blockRef == nil { p.authorRef = review.blockRef }; if p.uploadedBy == nil { p.uploadedBy = review.author }; return p })
                }
                ForEach(photos.filter { $0.status == .processing || $0.url == nil }) { _ in
                    Label("Photo processing…", systemImage: "hourglass").font(Tokens.Font.small).foregroundStyle(Color.textMuted)
                        .accessibilityIdentifier("photoProcessing")
                }
            }
            Button {
                Task {
                    guard await model.ensureRulesAccepted() else { return }
                    helpfulOn.toggle()
                    try? await model.repo.toggleHelpful(reviewId: review.id)
                    await onChange()
                }
            } label: {
                Label("Helpful (\(review.helpfulCount))", systemImage: helpfulOn ? "hand.thumbsup.fill" : "hand.thumbsup")
                    .font(Tokens.Font.label)
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.brand)
            .accessibilityIdentifier("helpfulReview")
        }
        .padding(12)
        .background(Color.surfaceAlt, in: RoundedRectangle(cornerRadius: Tokens.Radius.md, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("reviewRow")
        .confirmationDialog("Block this user?", isPresented: $confirmBlock, titleVisibility: .visible) {
            Button("Block", role: .destructive) {
                if let ref = review.blockRef { model.blockAuthor(ref: ref, name: review.author.displayName) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Their reviews and photos will be hidden on this phone. You can unblock them in Settings.")
        }
        .fullScreenCover(item: $viewer) { v in PhotoViewer(urls: v.urls, index: v.index, photos: v.photos) }
        .sheet(isPresented: $appealing) { ContentAppealSheet(subject: .review(id: review.id)) { Task { await onChange() } } }
    }
}

extension FlagReason {
    var title: LocalizedStringKey {
        switch self {
        case .spam: "Spam"
        case .offensive: "Offensive"
        case .offTopic: "Off topic"
        case .conflictOfInterest: "Conflict of interest"
        case .sensitiveLocation: "Sensitive or security location"
        case .other: "Other"
        }
    }
}

struct AllReviewsSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let placeId: String
    @State private var sort: ReviewSort = .recent
    @State private var reviews: [Review] = []
    @State private var next: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(spacing: 10) {
                    Picker("Sort", selection: $sort) {
                        Text("Recent").tag(ReviewSort.recent)
                        Text("Helpful").tag(ReviewSort.helpful)
                    }
                    .pickerStyle(.segmented)
                    ForEach(BlockList.visible(reviews, blocked: model.blockedRefs)) { r in ReviewRow(review: r) { await load(reset: true) } }
                    if next != nil {
                        ProgressView().task { await load(reset: false) }
                    }
                }
                .padding(Tokens.Space.gutter)
            }
            .navigationTitle("Reviews")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } } }
            .task(id: sort) { await load(reset: true) }
        }
    }

    private func load(reset: Bool) async {
        guard let page = try? await model.repo.reviews(placeId: placeId, sort: sort, cursor: reset ? nil : next) else { return }
        reviews = reset ? page.reviews : reviews + page.reviews
        next = page.next
    }
}

/// Stars, text and up to 5 photos; one review per place (editable).
struct WriteReviewSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let placeId: String
    let placeName: String
    /// The place's position, for the restricted-area check (docs/safety.md part 4).
    var location: LatLng? = nil
    let existing: Review?
    /// A star tapped on the place card starts the review with that rating.
    var initialRating = 0
    let onDone: () async -> Void
    @State private var rating = 0
    @State private var text = ""
    @State private var rejection: ContentRejectionItem?
    @State private var appealing: RefusedContent?
    @State private var photoRefusals: [RefusedContent] = []
    @State private var photos: [PickedPhoto] = []
    @State private var progress: Double?
    @State private var error: String?
    @State private var sending = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if let until = model.postingPausedUntil, PostingPause.isActive(until: until) { PausedCard(until: until) }
                    HStack(spacing: 4) {
                        ForEach(1...5, id: \.self) { n in
                            Button { rating = n } label: {
                                Image(systemName: n <= rating ? "star.fill" : "star")
                                    .font(.system(size: 38))
                                    .foregroundStyle(Color(uiColor: Tokens.Palette.traffic2))
                            }
                            .buttonStyle(.plain)
                            .frame(width: 48, height: 48)
                            .contentShape(Rectangle())
                            .accessibilityLabel(Text("\(n) stars"))
                            .accessibilityIdentifier("reviewStar.\(n)")
                        }
                    }
                    .frame(maxWidth: .infinity)
                    Text(StarWord.word(rating))
                        .font(Tokens.Font.bodyBold).foregroundStyle(Color.brandInk)
                        .frame(maxWidth: .infinity)
                        .accessibilityIdentifier("ratingWord")
                    if proximity == .blocked { RestrictedBlockedNote() }
                    TextField(String(localized: "Tell us about your visit"), text: $text, axis: .vertical)
                        .lineLimit(4...8)
                        .padding(14)
                        .background(Color.surfaceAlt, in: RoundedRectangle(cornerRadius: Tokens.Radius.md, style: .continuous))
                        .accessibilityIdentifier("reviewText")
                        .onChange(of: text) { if text.count > textLimit { text = String(text.prefix(textLimit)) } }
                    HStack {
                        Spacer()
                        Text(verbatim: "\(text.count) / \(ReviewPrefilter.maxChars)").font(Tokens.Font.small).foregroundStyle(Color.textMuted)
                            .accessibilityIdentifier("reviewCounter")
                    }
                    if looksLikeAdvert { AdHintTiles(hints: hints) }
                    if sensitive {
                        SensitiveTermsWarning { text = model.restricted.terms.removingMatchingSentences(text) }
                    }
                    if let mine = existing?.photos, ReviewPhotoDisplay.usesBadgeGrid(mine) {
                        ModeratedPhotoGrid(photos: mine, onChange: onDone)
                    }
                    if proximity == .clear {
                        PhotoPickerRow(photos: $photos)
                    } else if let reviewM = model.restricted.set?.reviewM {
                        PhotosOffCaption(reviewM: reviewM)
                    }
                    if !photoRefusals.isEmpty {
                        PhotosNotAcceptedNote(count: photoRefusals.count)
                    }
                    if let progress {
                        ProgressView(value: progress) { Text("Uploading photos…").font(Tokens.Font.caption) }
                            .accessibilityIdentifier("reviewUploadProgress")
                    }
                    if let error { Text(error).foregroundStyle(Color.speeding).font(Tokens.Font.caption).accessibilityIdentifier("reviewError") }
                    Button(sensitive ? "Send for review" : (existing == nil ? "Post review" : "Save changes")) { Task { await send() } }
                        .buttonStyle(PrimaryButtonStyle())
                        .disabled(rating == 0 || sending || proximity == .blocked || looksLikeAdvert || paused)
                        .accessibilityIdentifier("postReview")
                    if let existing {
                        Button("Delete review", role: .destructive) {
                            Task {
                                try? await model.repo.deleteReview(id: existing.id)
                                try? model.store.setSetting("review.\(placeId)", nil)
                                await onDone()
                                dismiss()
                            }
                        }
                        .frame(maxWidth: .infinity)
                    }
                }
                .padding(Tokens.Space.gutter)
            }
            .navigationTitle(placeName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarLeading) { Button("Cancel") { dismiss() } } }
            .onAppear {
                if let existing { rating = existing.rating; text = existing.text ?? "" } else if initialRating > 0 { rating = initialRating }
            }
            .sheet(item: $rejection) { r in
                CantPostSheet(reasons: r.reasons, safeText: r.safeText, onPostSafe: {
                    let safe = r.safeText ?? text
                    rejection = nil
                    text = safe
                    Task { await send() }
                }, onEdit: { rejection = nil }, onAppeal: {
                    rejection = nil
                    if let saved = r.refusal { appealing = saved } else { dismiss(); model.openFeedback(from: .place, placeId: placeId) }
                })
                .presentationDetents([.large])
            }
            .sheet(item: $appealing) { saved in
                AppealScreen(source: .refused(saved)) { dismiss() }
            }
        }
    }

    private var hints: Set<AdHint> { ReviewPrefilter.hints(text) }
    private var looksLikeAdvert: Bool { !hints.isEmpty }
    private var paused: Bool { PostingPause.isActive(until: model.postingPausedUntil) }
    /// New text stops at 500; an older, longer review being edited keeps its length.
    private var textLimit: Int { max(ReviewPrefilter.maxChars, existing?.text?.count ?? 0) }

    struct ContentRejectionItem: Identifiable {
        let id = UUID()
        let reasons: [ContentReason]
        let safeText: String?
        /// The refused review as saved on this phone (device-local), so it can be appealed.
        var refusal: RefusedContent? = nil
    }

    private var proximity: RestrictedProximity { location.map { model.restricted.proximity(of: $0) } ?? .clear }
    private var sensitive: Bool { model.restricted.terms.matches(text) }

    private func send() async {
        guard await model.ensureRulesAccepted() else { return }
        sending = true
        defer { sending = false }
        error = nil
        do {
            var photoIds = existing?.photos?.map(\.id) ?? []
            if !photos.isEmpty, proximity == .clear {
                progress = 0
                for (i, p) in photos.enumerated() {
                    let base = Double(i) / Double(photos.count), share = 1 / Double(photos.count)
                    do {
                        let uploaded = try await model.repo.uploadPhoto(p.jpeg, placeId: placeId, caption: nil) { f in
                            Task { @MainActor in progress = base + f * share }
                        }
                        photoIds.append(uploaded.id)
                    } catch let e as APIError where e.isRestrictedArea {
                        continue   // photos refused near a restricted area: the review goes without them
                    } catch where ContentFailure.isContentError(error) {
                        // This photo was refused (422): kept on the phone to appeal; the review goes without it.
                        guard case .rejected(let reasons, _) = ContentFailure.classify(error) else { throw error }
                        if let saved = model.recordRefusal(kind: .photo, placeId: placeId, placeName: placeName, reasons: reasons, photos: [p.jpeg]) {
                            photoRefusals.append(saved)
                        }
                    }
                }
            }
            let body = NewReview(rating: rating, text: text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : text,
                                 photoIds: photoIds.isEmpty ? nil : Array(photoIds.prefix(5)))
            let saved = existing == nil ? try await model.repo.createReview(placeId: placeId, body) : try await model.repo.updateReview(id: existing!.id, body)
            try? model.store.setSetting("review.\(placeId)", saved.id)
            await onDone()
            switch ReviewOutcome.of(saved) {
            case .held:
                model.showToast(String(localized: "Checked within 24 hours. You'll get a note in your Inbox."), seconds: 4)
            case .checking:
                model.showToast(String(localized: "Sent. We're still checking. The answer comes to your Inbox."), seconds: 4)
            case .published:
                if sensitive {
                    model.showToast(String(localized: "Checked within 24 hours. You'll get a note in your Inbox."), seconds: 4)
                } else {
                    model.showToast(String(localized: "Thanks for your review!"))
                }
            }
            if !photoRefusals.isEmpty {
                model.showToast(String(localized: "A photo wasn't accepted. See Inbox, Not accepted."), seconds: 4)
            }
            dismiss()
        } catch where ContentFailure.isContentError(error) {
            switch ContentFailure.classify(error, original: text) {
            case .rejected(let reasons, let safe):
                let saved = model.recordRefusal(kind: .review, placeId: placeId, placeName: placeName,
                                                text: text.trimmingCharacters(in: .whitespacesAndNewlines), reasons: reasons, rating: rating)
                rejection = ContentRejectionItem(reasons: reasons, safeText: safe, refusal: saved)
            case .paused(let until): model.pausePosting(until: until)
            default: break
            }
        } catch let e as APIError where e.isServerSideGap {
            error = String(localized: "Reviews aren't available on the server yet.")
        } catch APIError.http(status: 403, _) where existing != nil {
            // Not ours any more (e.g. a different device identity): forget it so the next save writes a new review.
            try? model.store.setSetting("review.\(placeId)", nil)
            await onDone()
            error = String(localized: "Only the author can change this review.")
        } catch {
            self.error = error.localizedDescription
        }
        progress = nil
    }
}

// MARK: - My contributions

struct MyContributionsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var places: [PlaceSummary] = []
    @State private var loading = true
    @State private var error: String?
    /// C1 from a not-accepted row.
    @State private var appealFor: PlaceSummary?
    /// A not-accepted row: what wasn't accepted and why, with its actions.
    @State private var notAccepted: PlaceSummary?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack(spacing: 14) {
                        TierRing(tier: model.user?.tier ?? .baharu, progress: model.tierProgress)
                        VStack(alignment: .leading, spacing: 4) {
                            TierBadge(tier: model.user?.tier ?? .baharu)
                            if model.isNewContributor {
                                // C3: "2 of 3 accepted places to leave "new"".
                                Text("\(model.user?.placesAccepted ?? 0) of 3 accepted places to leave \"new\"")
                                    .font(Tokens.Font.caption).foregroundStyle(Color.textMuted)
                                    .accessibilityIdentifier("contributionsNewProgress")
                            }
                            if let next = model.user?.nextTier {
                                Text("Next: \(Text(next.name.title))").font(Tokens.Font.bodyBold)
                                if let first = next.missing.first {
                                    Text(NextTierText.describe(first)).font(Tokens.Font.caption).foregroundStyle(Color.textMuted)
                                }
                            }
                        }
                    }
                    .accessibilityIdentifier("contributionsTier")
                }
                Section("Shared with everyone") {
                    if loading { ProgressView() }
                    if let error { Text(error).foregroundStyle(Color.textMuted).font(Tokens.Font.caption) }
                    if !loading && places.isEmpty && error == nil { Text("Nothing shared yet").foregroundStyle(Color.textMuted) }
                    ForEach(places) { p in
                        let status = MyPlaceStatus.of(p)
                        Button {
                            if status.opensOutcome { notAccepted = p } else { dismiss(); model.openPlace(p) }
                        } label: { row(p.name, p.category, status: status) }
                            .accessibilityIdentifier("contribution.\(p.name)")
                    }
                }
                if !model.placeOutbox.items.isEmpty {
                    Section {
                        ForEach(model.placeOutbox.items) { d in
                            Button {
                                model.openAddPlace(AddPlaceSeed(place: d.place, editingId: nil, draftId: d.id))
                            } label: { row(d.place.name, d.place.category, status: d.status) }
                                .accessibilityIdentifier("draft.\(d.place.name)")
                                .swipeActions {
                                    Button("Delete", role: .destructive) { model.placeOutbox.remove(d.id); model.reloadLocal() }
                                }
                        }
                    } header: {
                        Text("On this phone, not shared yet")
                    } footer: {
                        Text("Drafts stay on this phone until you share them. Queued places are sent when you're back online.")
                    }
                }
                Section {
                    if model.privatePlaces.isEmpty { Text("No private places").foregroundStyle(Color.textMuted) }
                    ForEach(model.privatePlaces) { p in
                        Button { dismiss(); model.openPlace(p.summary) } label: { row(p.name, p.category, status: .justForMe) }
                            .accessibilityIdentifier("privatePlace.\(p.name)")
                    }
                } header: {
                    Text("Just for me")
                } footer: {
                    Text("Stored only on this phone and in your own backups.")
                }
            }
            .navigationTitle("My contributions")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } } }
            .task { await load() }
            .refreshable { await model.flushPlaces(); await load() }
            .confirmationDialog(notAccepted.map { String(localized: ScreeningCopy.notAcceptedTitle(ScreeningReason.primary($0.screening?.reasons ?? []))) } ?? "",
                                isPresented: Binding(get: { notAccepted != nil }, set: { if !$0 { notAccepted = nil } }),
                                titleVisibility: .visible, presenting: notAccepted) { p in
                if p.screening?.canAppeal == true {
                    Button("Ask for a review") { appealFor = p }
                }
                Button("Edit and try again") { Task { await edit(p) } }
                Button("Discard", role: .destructive) { Task { await discard(p) } }
                Button("Cancel", role: .cancel) {}
            } message: { p in
                Text(String(localized: ScreeningCopy.notAcceptedBody(ScreeningReason.primary(p.screening?.reasons ?? []))))
            }
            .sheet(item: $appealFor) { p in
                AppealSheet(placeId: p.id, name: p.name, reason: ScreeningReason.primary(p.screening?.reasons ?? [])) { updated in
                    if let updated, let i = places.firstIndex(where: { $0.id == updated.id }) { places[i] = updated.summary }
                }
            }
        }
    }

    private func load() async {
        do { places = try await model.repo.myContributions() } catch {
            self.error = (error as? APIError)?.isServerSideGap == true
                ? String(localized: "Contributions aren't available on the server yet.") : error.localizedDescription
        }
        loading = false
    }

    /// "Edit and try again": the owner's PATCH (the edit is checked again).
    private func edit(_ p: PlaceSummary) async {
        let full = (try? await model.repo.place(id: p.id, near: nil))
        let seed = NewPlace(name: full?.name ?? p.name, category: full?.category ?? p.category, lat: full?.lat ?? p.lat, lng: full?.lng ?? p.lng,
                            address: full?.address ?? p.address, description: full?.description, phone: full?.phone, website: full?.website,
                            openingHours: full?.openingHours, amenities: full?.amenities)
        model.openAddPlace(AddPlaceSeed(place: seed, editingId: p.id, draftId: nil))
    }

    private func discard(_ p: PlaceSummary) async {
        do {
            try await model.repo.deleteCommunityPlace(id: p.id)
            places.removeAll { $0.id == p.id }
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func row(_ name: String, _ cat: PlaceCategory, status: MyPlaceStatus) -> some View {
        HStack(spacing: 12) {
            CategoryIcon(category: cat)
            Text(verbatim: name).font(Tokens.Font.bodyBold).foregroundStyle(Color.textPrimary)
            Spacer()
            if status == .beingCheckedByPerson {
                // Held for a moderator (restricted area nearby, sensitive words, or the AI check): docs/safety.md part 4.
                BeingCheckedBadge()
            } else {
                MyPlaceStatusBadge(status: status)
            }
        }
    }
}

/// The word under the stars (board "Tulis ulasan").
enum StarWord {
    static func word(_ rating: Int) -> LocalizedStringKey {
        switch rating {
        case 1: "Awful"
        case 2: "Poor"
        case 3: "Okay"
        case 4: "Good"
        case 5: "Excellent!"
        default: "Tap a star"
        }
    }
}

extension PlaceStatus {
    /// Localized badge text (a `String` would bypass the catalog).
    var badgeTitle: LocalizedStringKey {
        switch self {
        case .pending: "Unverified"
        case .published: "Published"
        case .closed: "Closed"
        case .hidden: "Hidden"
        case .rejected: "Not accepted"
        case .expired: "Expired"
        }
    }
}

/// Place card → "Add photo": camera or library, metadata stripped on the phone, then uploaded. Each uploaded photo
/// shows a round status badge (tick, clock, cross) that follows `GET /photos/{id}` until the content check is final.
struct AddPlacePhotosSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let placeId: String
    let placeName: String
    var location: LatLng? = nil
    @State private var photos: [PickedPhoto] = []
    @State private var uploaded: [UploadedPhoto] = []
    @State private var progress: Double?
    @State private var error: String?
    @State private var rejected: UploadedPhoto?
    @State private var appealing: Photo?
    /// Photos the check refused at upload (422): kept on the phone, appealable.
    @State private var refusedPhotos: [RefusedContent] = []
    @State private var refusedOpen: RefusedContent?
    @State private var refusedAppeal: RefusedContent?

    /// Photos are refused within reviewM of a restricted area (docs/safety.md B).
    private var proximity: RestrictedProximity { location.map { model.restricted.proximity(of: $0) } ?? .clear }
    private var paused: Bool { PostingPause.isActive(until: model.postingPausedUntil) }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let until = model.postingPausedUntil, paused { PausedCard(until: until) }
                    if !uploaded.isEmpty {
                        UploadedPhotosGrid(items: $uploaded) { rejected = $0 }
                    }
                    if !refusedPhotos.isEmpty {
                        LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
                            ForEach(refusedPhotos) { r in RefusedPhotoTile(item: r) { refusedOpen = r } }
                        }
                        .accessibilityIdentifier("refusedPhotosGrid")
                    }
                    if proximity == .blocked { RestrictedBlockedNote() }
                    if proximity == .clear {
                        PhotoPickerRow(photos: $photos)
                    } else if let reviewM = model.restricted.set?.reviewM {
                        PhotosOffCaption(reviewM: reviewM)
                    }
                    Label("Location and camera details are removed before upload.", systemImage: "location.slash.fill")
                        .font(Tokens.Font.small).foregroundStyle(Color.textMuted)
                    if let progress { ProgressView(value: progress) }
                    if let error { Text(error).font(Tokens.Font.caption).foregroundStyle(Color.speeding) }
                    Button("Upload") { Task { await upload() } }
                        .buttonStyle(PrimaryButtonStyle())
                        .disabled(photos.isEmpty || progress != nil || paused)
                        .accessibilityIdentifier("uploadPhotos")
                }
                .padding(Tokens.Space.gutter)
            }
            .navigationTitle(placeName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button(uploaded.isEmpty ? "Cancel" : "Done") { dismiss() } }
            }
            .sheet(item: $rejected) { item in
                let m = item.photo.moderation
                RejectedPhotoSheet(reasons: m?.reasons ?? [], canAppeal: m?.canAppeal ?? false, onAnother: {
                    uploaded.removeAll { $0.id == item.id }
                    rejected = nil
                }, onAppeal: {
                    rejected = nil
                    appealing = item.photo
                })
                .presentationDetents([.medium, .large])
            }
            .onChange(of: uploaded.map { PhotoBadge.of($0.photo) }) {
                // A photo the check rejects later (GET /photos/{id}): kept in "Not accepted", refusalId = the photo id.
                for u in uploaded where PhotoBadge.of(u.photo) == .rejected && !model.refusedItems.contains(where: { $0.id == u.photo.id }) {
                    model.recordRefusal(kind: .photo, placeId: placeId, placeName: placeName, reasons: ContentReason.parse(u.photo.moderation?.reasons ?? []),
                                        id: u.photo.id)
                }
            }
            .sheet(item: $refusedOpen) { r in
                RejectedPhotoSheet(reasons: r.reasons, canAppeal: r.appealState == .none, onAnother: {
                    refusedOpen = nil
                    model.deleteRefused(id: r.id)
                    refusedPhotos.removeAll { $0.id == r.id }
                }, onAppeal: {
                    refusedOpen = nil
                    refusedAppeal = r
                })
                .presentationDetents([.medium, .large])
            }
            .sheet(item: $refusedAppeal) { r in
                AppealScreen(source: .refused(r)) {
                    if let i = refusedPhotos.firstIndex(where: { $0.id == r.id }) { refusedPhotos[i].appealState = .sent }
                }
            }
            .sheet(item: $appealing) { p in
                ContentAppealSheet(subject: .photo(id: p.id)) {
                    // Back to "being checked": the tile polls again.
                    if let i = uploaded.firstIndex(where: { $0.photo.id == p.id }) {
                        var q = uploaded[i].photo
                        q.status = .processing
                        q.moderation = ContentModeration(state: .held, reasons: q.moderation?.reasons ?? [])
                        let item = UploadedPhoto(preview: uploaded[i].preview, photo: q)
                        uploaded[i] = item
                    }
                }
            }
        }
    }

    private func upload() async {
        guard await model.ensureRulesAccepted() else { return }
        progress = 0
        error = nil
        defer { progress = nil }
        let batch = photos
        var done: [UploadedPhoto] = []
        var handled = 0
        var refusedNow = 0
        do {
            for (i, p) in batch.enumerated() {
                let base = Double(i) / Double(batch.count), share = 1 / Double(batch.count)
                do {
                    let photo = try await model.repo.uploadPhoto(p.jpeg, placeId: placeId, caption: nil) { f in
                        Task { @MainActor in progress = base + f * share }
                    }
                    done.append(UploadedPhoto(preview: p.preview, photo: photo))
                } catch where ContentFailure.isContentError(error) {
                    // 422: this photo is refused. Keep it on the phone (appealable) and go on with the next one.
                    guard case .rejected(let reasons, _) = ContentFailure.classify(error) else { throw error }
                    if let saved = model.recordRefusal(kind: .photo, placeId: placeId, placeName: placeName, reasons: reasons, photos: [p.jpeg]) {
                        refusedPhotos.append(saved)
                        refusedNow += 1
                    }
                }
                handled += 1
            }
            if !done.isEmpty { model.showToast(String(localized: "Thanks! We're checking your photos.")) }
        } catch where ContentFailure.isContentError(error) {
            if case .paused(let until) = ContentFailure.classify(error) { model.pausePosting(until: until) }
        } catch {
            self.error = error.localizedDescription
        }
        uploaded += done
        // Photos that went up (or were refused) leave the picker; the rest stay for another try.
        photos = Array(batch.dropFirst(handled))
        if refusedNow == 1, let r = refusedPhotos.last { refusedOpen = r }
    }
}

/// A refused photo in the grid: eye-slash tile with the cross badge; tap for the reasons and Appeal.
struct RefusedPhotoTile: View {
    let item: RefusedContent
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            ZStack(alignment: .bottomTrailing) {
                Color.surfaceAlt.overlay(Image(systemName: "eye.slash.fill").font(.system(size: 34)).foregroundStyle(Color.textMuted))
                Image(systemName: item.appealState == .none ? PhotoBadge.rejected.symbol : AppealState.sent.symbol)
                    .font(.system(size: 14, weight: .black)).foregroundStyle(.white)
                    .frame(width: 30, height: 30).background(item.appealState == .none ? Color.report : Color.amberInk, in: Circle())
                    .overlay(Circle().strokeBorder(.white, lineWidth: 2)).padding(8)
            }
            .aspectRatio(1, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("Photo not accepted"))
        .accessibilityHint(Text("Opens the reasons"))
        .accessibilityIdentifier("refusedPhotoTile")
    }
}

/// One line under the review box when photos were refused on send.
struct PhotosNotAcceptedNote: View {
    let count: Int
    var body: some View {
        Label("\(count) photo not accepted", systemImage: "eye.slash.fill")
            .font(Tokens.Font.label).foregroundStyle(Color.report)
            .accessibilityIdentifier("photosNotAccepted")
    }
}
