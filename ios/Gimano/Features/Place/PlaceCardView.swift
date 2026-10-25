import SwiftUI

/// Place card from search (boards TempatFlow / TempatIntai / TempatBaru / TempatPenuh).
///
/// - **Peek** (default, ≤ 40 % of the screen): name with one rating line ("★ 4.3 · 12 reviews · 450 m", or grey stars +
///   "New"), category · address · open now, the "Routes" button (plain: nothing is routed, and no position leaves the
///   phone, until it is tapped), then Save · Call · Share · Website.
/// - **Full** (swipe up): Reviews (average, 5→1 bars, latest review, Write a review), Photos (Add photo at the end),
///   hours and amenities, Suggest an edit.
///
/// The map keeps the pin centred in the part it leaves visible (`MapState.placeBottomInset`), and Recenter returns to it.
struct PlaceCardView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openURL) private var openURL
    @Environment(\.dynamicTypeSize) private var typeSize
    let summary: PlaceSummary
    @State private var place: Place?
    @State private var privatePlace: PrivatePlace?
    @State private var showSuggest = false
    @State private var placeIssue: IssueKind?
    @State private var verifyDone = false
    @State private var verifyResult: VerifyResult?
    @State private var viewer: PhotoViewerItem?
    @State private var confirmDelete = false
    @State private var confirmBlockAuthor = false
    @State private var detent: PlaceDetent = .peek
    @State private var reviews: [Review] = []
    @State private var reviewsLoaded = false
    @State private var writing = false
    @State private var showAllReviews = false
    @State private var showAddPhotos = false
    /// Natural heights of the peek's scrolling top (name, rating, address) and its fixed bottom (Routes, actions).
    @State private var peekTop: CGFloat = 120
    @State private var peekFixed: CGFloat = 170
    @GestureState private var drag: CGFloat = 0

    private var isPrivate: Bool { summary.isPrivate }
    private var isPin: Bool { summary.id.hasPrefix("pin:") || summary.id.hasPrefix("local:") }
    private var isCommunity: Bool { (place?.source ?? summary.source) == .community }
    private var status: PlaceStatus? { place?.status ?? summary.status }
    private var canReview: Bool { !isPrivate && !isPin }
    private var canSuggest: Bool { !isPrivate && !isPin }

    private var stats: RatingSummary {
        RatingSummary.make(reviews: reviews, serverAverage: place?.rating ?? summary.rating, serverCount: place?.reviewCount ?? summary.reviewCount)
    }

    private var ratingLine: PlaceRatingLine {
        PlaceRatingLine.make(serverAverage: place?.rating ?? summary.rating, serverCount: place?.reviewCount ?? summary.reviewCount,
                             loaded: reviewsLoaded ? stats : nil)
    }

    var body: some View {
        GeometryReader { geo in
            let bottom = geo.safeAreaInsets.bottom
            let screen = geo.size.height + geo.safeAreaInsets.top + bottom
            let peekH = PlaceCardMetrics.peekHeight(natural: PlaceCardMetrics.handleBlock + peekTop + peekFixed, bottomInset: bottom, screenHeight: screen)
            let fullH = PlaceCardMetrics.fullHeight(available: geo.size.height, bottomInset: bottom)
            let target = detent == .peek ? peekH : fullH
            let h = min(fullH, max(peekH - 40, target - drag))
            ZStack(alignment: .bottom) {
                topControls
                if detent == .peek {
                    HStack(alignment: .bottom) {
                        OSMAttribution()
                        Spacer()
                        RoundFab(icon: .logo, accessibilityLabel: "Recenter", stroke: .brand, fill: .brand) { model.recenter() }
                            .accessibilityIdentifier("placeRecenter")
                    }
                    .padding(.horizontal, Tokens.Space.gutter)
                    .padding(.bottom, h + 10)
                    .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
                    .transition(.opacity)
                }
                sheet(height: h, peekHeight: peekH, bottom: bottom)
            }
            .ignoresSafeArea(edges: .bottom)
            .onAppear { model.map.placeBottomInset = Double(target) }
            .onChange(of: target) { _, t in model.map.placeBottomInset = Double(t) }
            .onDisappear { model.map.placeBottomInset = 0 }
        }
        .animation(.snappy(duration: 0.28), value: detent)
        .sheet(item: $placeIssue) { k in
            PlaceIssueSheet(kind: k, placeId: summary.id, location: summary.location)
        }
        .sheet(isPresented: $showSuggest) {
            SuggestEditSheet(placeId: summary.id, current: place, fallback: summary)
        }
        .sheet(isPresented: $writing) {
            WriteReviewSheet(placeId: summary.id, placeName: summary.name, location: summary.location, existing: myReview) { await reloadReviews() }
        }
        .sheet(isPresented: $showAddPhotos) {
            AddPlacePhotosSheet(placeId: summary.id, placeName: summary.name, location: summary.location)
        }
        .sheet(isPresented: $showAllReviews) { AllReviewsSheet(placeId: summary.id) }
        .fullScreenCover(item: $viewer) { v in PhotoViewer(urls: v.urls, index: v.index, photos: v.photos) }
        .confirmationDialog("Block this user?", isPresented: $confirmBlockAuthor, titleVisibility: .visible) {
            Button("Block", role: .destructive) {
                if let by = place?.addedBy, let ref = by.authorRef { model.blockAuthor(ref: ref, name: by.displayName) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Their reviews and photos will be hidden on this phone. You can unblock them in Settings.")
        }
        .confirmationDialog("Delete this place from your phone?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                if let id = privatePlace?.id {
                    try? model.store.deletePrivatePlace(id: id)
                    model.reloadLocal()
                }
                model.go(.home)
            }
        }
        .task(id: summary.id) { await load() }
        .task(id: summary.id) { if canReview { await reloadReviews() } }
    }

    // MARK: layout

    private var topControls: some View {
        VStack {
            HStack {
                Button { model.go(.home) } label: {
                    Image(systemName: "arrow.left")
                        .font(.system(size: 20, weight: .bold))
                        .foregroundStyle(Color.textPrimary)
                        .frame(width: 48, height: 48)
                        .background(Color.surface, in: Circle())
                        .fabShadow()
                }
                .accessibilityLabel(Text("Back"))
                .accessibilityIdentifier("placeBack")
                Spacer()
                if detent == .peek { SoundFab() }
            }
            .padding(.horizontal, Tokens.Space.gutter)
            .padding(.top, 8)
            .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
            Spacer()
        }
    }

    private func sheet(height h: CGFloat, peekHeight: CGFloat, bottom: CGFloat) -> some View {
        VStack(spacing: 0) {
            handle
            if detent == .peek {
                peekBody(available: peekHeight - bottom - PlaceCardMetrics.handleBlock)
            } else {
                fullBody(bottom: bottom)
            }
        }
        .frame(maxWidth: .infinity)
        // The largest text sizes are capped (like the home panel) so the peek still shows name, rating, Routes and actions.
        .dynamicTypeSize(...DynamicTypeSize.accessibility2)
        .frame(height: h, alignment: .top)
        .clipped()
        .background(
            UnevenRoundedRectangle(topLeadingRadius: 26, topTrailingRadius: 26)
                .fill(Color.surface)
                .shadow(color: Color(red: 11 / 255, green: 27 / 255, blue: 58 / 255).opacity(0.14), radius: 9, y: -4)
        )
        .contentShape(Rectangle())
        .simultaneousGesture(detent == .peek ? sheetDrag : nil)
    }

    private var sheetDrag: some Gesture {
        DragGesture(minimumDistance: 10, coordinateSpace: .global)
            .updating($drag) { v, s, _ in s = v.translation.height }
            .onEnded { v in detent = PlaceCardMetrics.snap(from: detent, predictedTranslation: v.predictedEndTranslation.height) }
    }

    /// Grab handle: tap toggles Peek ↔ Full; VoiceOver swipes up/down.
    private var handle: some View {
        // Not a Button: a button swallows the drag on a real device, so the handle is a plain view that taps and drags.
        GrabHandle()
            .frame(maxWidth: .infinity)
            .frame(height: PlaceCardMetrics.handleBlock)
            .contentShape(Rectangle())
            .onTapGesture { detent = detent.toggled }
            .gesture(sheetDrag)
            .accessibilityElement()
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { detent = detent.toggled }
            .accessibilityLabel(Text(detent == .peek ? "Place details, collapsed. Swipe up for reviews and photos." : "Place details, expanded. Swipe down to show the map."))
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment: detent = .full
                case .decrement: detent = .peek
                @unknown default: break
                }
            }
            .accessibilityValue(Text(verbatim: detent == .peek ? "peek" : "full"))
            .accessibilityIdentifier("placeCardHandle")
    }

    /// Peek: the top (name, rating, address, issue badges) scrolls only when it can't fit (largest text sizes);
    /// Routes and the four actions always stay visible.
    private func peekBody(available: CGFloat) -> some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    header
                    metaLine
                    peekBadges
                }
                .padding(.horizontal, Tokens.Space.gutter)
                .padding(.bottom, 12)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { peekTop = $0 }
            }
            .scrollBounceBehavior(.basedOnSize)
            .frame(height: max(0, min(peekTop, available - peekFixed)))
            VStack(spacing: 12) {
                routesButton
                actions
            }
            .padding(.horizontal, Tokens.Space.gutter)
            .padding(.bottom, 10)
            .dynamicTypeSize(...DynamicTypeSize.accessibility1)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { peekFixed = $0 }
        }
    }

    private func fullBody(bottom: CGFloat) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                // Pulling down past the top folds the card back to Peek.
                Color.clear.frame(height: 0)
                    .onGeometryChange(for: CGFloat.self) { $0.frame(in: .named("placeScroll")).minY } action: { y in
                        if y > 70, detent == .full { detent = .peek }
                    }
                header
                metaLine
                peekBadges
                routesButton
                actions.dynamicTypeSize(...DynamicTypeSize.accessibility1)
                badgesAndVerify
                if canReview { reviewsSection }
                photosSection
                infoRows
                if canSuggest { suggestRow }
                Text(isPrivate ? "Just for me: stored only on this phone" : isCommunity ? "Added by a Gimano user" : "Place data © OpenStreetMap contributors")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.textMuted)
                    .frame(maxWidth: .infinity)
            }
            .padding(.horizontal, Tokens.Space.gutter)
            .padding(.bottom, bottom + 16)
        }
        .coordinateSpace(.named("placeScroll"))
    }

    // MARK: data

    private func load() async {
        if isPrivate {
            let id = String(summary.id.dropFirst(PrivatePlace.idPrefix.count))
            privatePlace = try? model.store.privatePlace(id: id)
            return
        }
        guard !isPin else { return }
        // No position goes with it: the distance is measured on the phone (see PlaceCardLoader).
        place = await PlaceCardLoader.detail(id: summary.id, source: model.repo)
    }

    private var myReviewId: String? { try? model.store.setting("review.\(summary.id)") }
    private var myReview: Review? { reviews.first { $0.id == myReviewId } }

    private func reloadReviews() async {
        reviews = await PlaceCardLoader.reviews(placeId: summary.id, source: model.repo) ?? []
        reviewsLoaded = true
        // Photos are re-encoded to WebP on the server: poll briefly until they're published.
        for _ in 0..<6 where reviews.contains(where: { r in (r.photos ?? []).contains { $0.url == nil || $0.status == .processing } }) {
            try? await Task.sleep(for: .seconds(2))
            if Task.isCancelled { return }
            reviews = await PlaceCardLoader.reviews(placeId: summary.id, source: model.repo) ?? reviews
        }
    }

    // MARK: peek sections

    private var header: some View {
        HStack(alignment: typeSize.isAccessibilitySize ? .top : .center, spacing: 12) {
            CategoryTile(category: summary.category)
            VStack(alignment: .leading, spacing: 2) {
                Text(summary.name)
                    .font(Tokens.Font.nunito(21, .black, relativeTo: .title2))
                    .foregroundStyle(Color.textPrimary)
                    .lineLimit(3)
                    .accessibilityIdentifier("placeTitle")
                ratingRow
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            moreMenu
            Button { model.go(.home) } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 18, weight: .heavy))
                    .foregroundStyle(Color.tileLabel)
                    .frame(width: 36, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("Close"))
            .accessibilityIdentifier("placeClose")
        }
    }

    /// One line: stars, average, "· N reviews · distance"; no reviews → grey stars, "New · distance".
    private var ratingRow: some View {
        let line = ratingLine
        let distance = distanceText
        // At accessibility sizes the stars sit on their own line so the text wraps under the whole width.
        let layout = typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 2))
            : AnyLayout(HStackLayout(alignment: .firstTextBaseline, spacing: 4))
        return layout {
            RatingStars(rating: line.isNew ? 0 : line.average, size: 15, grey: line.isNew)
                .alignmentGuide(.firstTextBaseline) { d in d[.bottom] - 3 }
                .accessibilityHidden(true)
            Group {
                if line.isNew {
                    Text("New").fontWeight(.black).foregroundStyle(Color.textPrimary)
                        + Text(distance.map { " · \($0)" } ?? "")
                } else {
                    Text(String(format: "%.1f", line.average)).fontWeight(.black).foregroundStyle(Color.textPrimary)
                        + Text(" · ") + Text(line.count == 1 ? String(localized: "1 review") : String(localized: "\(line.count) reviews"))
                        + Text(distance.map { " · \($0)" } ?? "")
                }
            }
            .font(Tokens.Font.nunito(13, .bold, relativeTo: .footnote))
            .foregroundStyle(Color.tileLabel)
            .lineLimit(typeSize.isAccessibilitySize ? 3 : 1)
            .minimumScaleFactor(0.8)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("placeRatingLine")
    }

    private var distanceText: String? {
        guard case .fresh(let me) = model.currentGPS() else { return nil }
        return ManeuverFormatter.distance(Geo.distance(me, summary.location))
    }

    /// "Mosque · Jalan SS 9/16, Petaling Jaya · Open now".
    private var metaLine: some View {
        let word = String(localized: AddPlaceCategories.title(summary.category))
        let category: String? = word == String(localized: "Place") ? nil : word
        let address = privatePlace?.address ?? summary.address
        let parts = [category, address.isEmpty ? nil : address].compactMap { $0 }
        var t = Text(parts.joined(separator: " · "))
        if let open = place?.openNow ?? summary.openNow {
            t = t + Text(parts.isEmpty ? "" : " · ")
                + Text(open ? "Open now" : "Closed").foregroundStyle(open ? Color.brand : Color(uiColor: Tokens.Palette.speeding))
        }
        return t
            .font(Tokens.Font.nunito(13, .bold, relativeTo: .footnote))
            .foregroundStyle(Color.textMuted)
            .lineLimit(3)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityIdentifier("placeMeta")
    }

    @ViewBuilder private var peekBadges: some View {
        if let ref = place?.addedBy?.authorRef, model.blockedRefs.contains(ref) {
            HStack {
                Label("You blocked the person who added this place", systemImage: "person.crop.circle.badge.xmark")
                    .font(Tokens.Font.caption).foregroundStyle(Color.textMuted)
                Spacer()
                Button("Unblock") { model.unblockAuthor(ref) }.font(Tokens.Font.label)
            }
            .accessibilityIdentifier("placeAuthorBlocked")
        }
        if !isPrivate && !isPin && !summary.isSearchOnly {
            PlaceIssueBadges(placeId: summary.id, location: summary.location)
        }
    }

    private var moreMenu: some View {
        Menu {
            Button { model.openFeedback(from: .place, placeId: summary.id) } label: {
                Label("Add feedback", systemImage: "bubble.left.and.text.bubble.right")
            }
            if canSuggest {
                Menu { suggestOptions } label: { Label("Suggest an edit", systemImage: "pencil") }
                    .accessibilityIdentifier("suggestEditMenu")
            }
            if isCommunity, !isPrivate {
                Menu {
                    FlagReasonButtons { r in
                        Task {
                            do {
                                try await model.repo.flagPlace(id: summary.id, reason: r)
                                model.showToast(String(localized: "Thanks, we'll take a look"))
                            } catch { model.showToast(error.localizedDescription) }
                        }
                    }
                } label: { Label("Report place", systemImage: "flag") }
                    .accessibilityIdentifier("reportPlace")
                if place?.addedBy?.authorRef != nil {
                    Button(role: .destructive) { confirmBlockAuthor = true } label: {
                        Label("Block this user", systemImage: "person.crop.circle.badge.xmark")
                    }
                    .accessibilityIdentifier("blockPlaceAuthor")
                }
            }
            if isPrivate {
                Button(role: .destructive) { confirmDelete = true } label: { Label("Delete", systemImage: "trash") }
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 18, weight: .heavy))
                .rotationEffect(.degrees(90))
                .foregroundStyle(Color.tileLabel)
                .frame(width: 32, height: 44)
        }
        .accessibilityLabel(Text("More"))
        .accessibilityIdentifier("placeMore")
    }

    /// The six "Suggest an edit" choices (complaints v1), shared by the ⋮ menu and the row in Full.
    @ViewBuilder private var suggestOptions: some View {
        Button { placeIssue = .placeClosedPerm } label: { Label("Permanently closed", systemImage: "xmark.octagon") }
        Button { placeIssue = .placeClosedTemp } label: { Label("Temporarily closed", systemImage: "clock.badge.xmark") }
        Button { placeIssue = .placeHoursWrong } label: { Label("Opening hours wrong", systemImage: "clock") }
        Button {
            model.entrancePlace = (summary.id, summary.location)
            model.startPinPick(.placeEntrance, start: summary.location)
        } label: { Label("Entrance or parking wrong", systemImage: "door.left.hand.open") }
        Button { showSuggest = true } label: { Label("Name, type, phone", systemImage: "pencil") }
        Button { placeIssue = .placeDuplicate } label: { Label("Duplicate", systemImage: "square.on.square") }
    }

    private var routesButton: some View {
        Button {
            model.planRoute(to: Destination(name: summary.name, address: summary.address, location: summary.location,
                                            placeId: isPin || isPrivate ? nil : summary.id,
                                            category: summary.category))
        } label: {
            HStack(spacing: 10) {
                RouteGlyph().frame(width: 26, height: 26)
                // Plain "Routes": no route (and no position) is requested until it's tapped.
                Text("Routes")
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            .font(Tokens.Font.nunito(18, .black, relativeTo: .headline))
            .foregroundStyle(Color.brandOn)
            .frame(maxWidth: .infinity, minHeight: 56)
            .background(Color.brand, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("routesButton")
    }

    private var actions: some View {
        let phone = place?.phone ?? privatePlace?.phone
        let site = place?.website ?? privatePlace?.website
        let siteURL = site.flatMap { URL(string: $0.hasPrefix("http") ? $0 : "https://\($0)") }
        return HStack(alignment: .top, spacing: 0) {
            if !isPrivate {
                action("Save", icon: .save, id: "savePlace") { model.savingPlace = summary }
            }
            action("Call", icon: .call, id: "callPlace", enabled: phone != nil) {
                if let p = phone?.filter({ $0.isNumber || $0 == "+" }), let url = URL(string: "tel:\(p)") { openURL(url) }
            }
            ShareLink(item: shareText) { actionLabel("Share", icon: .share) }
                .buttonStyle(.plain)
                .accessibilityIdentifier("sharePlace")
            action("Website", icon: .website, id: "websitePlace", enabled: siteURL != nil) {
                if let siteURL { openURL(siteURL) }
            }
        }
    }

    private func action(_ title: LocalizedStringKey, icon: FlatIcon, id: String, enabled: Bool = true, perform: @escaping () -> Void) -> some View {
        Button(action: perform) { actionLabel(title, icon: icon) }
            .buttonStyle(.plain)
            .disabled(!enabled)
            .opacity(enabled ? 1 : 0.45)
            .accessibilityIdentifier(id)
    }

    private func actionLabel(_ title: LocalizedStringKey, icon: FlatIcon) -> some View {
        VStack(spacing: 4) {
            FlatIconView(icon: icon, size: 26)
                .frame(width: 48, height: 48)
                .background(Color.brandMist, in: Circle())
            Text(title)
                .font(Tokens.Font.nunito(11, .bold, relativeTo: .caption))
                .foregroundStyle(Color.tileLabel)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
    }

    private var shareText: String {
        "\(summary.name)\n\(summary.address)\nhttps://www.openstreetmap.org/?mlat=\(summary.lat)&mlon=\(summary.lng)#map=17/\(summary.lat)/\(summary.lng)"
    }

    // MARK: full sections

    private func sectionLabel(_ title: LocalizedStringKey) -> some View {
        Text(title)
            .textCase(.uppercase)
            .font(Tokens.Font.nunito(12, .black, relativeTo: .caption))
            .tracking(0.6)
            .foregroundStyle(Color.sectionLabel)
            .padding(.top, 4)
    }

    private var reviewsSection: some View {
        let s = stats
        let line = ratingLine
        return VStack(alignment: .leading, spacing: 12) {
            sectionLabel("Reviews")
            if !line.isNew {
                HStack(alignment: .center, spacing: 14) {
                    VStack(spacing: 2) {
                        Text(String(format: "%.1f", line.average))
                            .font(Tokens.Font.nunito(34, .black, relativeTo: .largeTitle))
                            .foregroundStyle(Color.textPrimary)
                            .accessibilityIdentifier("ratingAverage")
                        RatingStars(rating: line.average, size: 15)
                        Text(line.count == 1 ? String(localized: "1 review") : String(localized: "\(line.count) reviews"))
                            .font(Tokens.Font.nunito(11, .bold, relativeTo: .caption))
                            .foregroundStyle(Color.tileLabel)
                    }
                    .frame(minWidth: 86)
                    VStack(spacing: 3) {
                        let maxCount = max(1, s.distribution.max() ?? 1)
                        ForEach((1...5).reversed(), id: \.self) { star in
                            HStack(spacing: 6) {
                                Text("\(star)").font(Tokens.Font.nunito(11, .bold, relativeTo: .caption)).foregroundStyle(Color.tileLabel)
                                    .frame(width: 10)
                                GeometryReader { g in
                                    ZStack(alignment: .leading) {
                                        Capsule().fill(Color.surfaceAlt)
                                        Capsule().fill(Color.starFill)
                                            .frame(width: g.size.width * CGFloat(s.distribution[star - 1]) / CGFloat(maxCount))
                                    }
                                }
                                .frame(height: 6)
                            }
                        }
                    }
                    .accessibilityIdentifier("ratingDistribution")
                }
            } else {
                HStack(spacing: 8) {
                    RatingStars(rating: 0, size: 18, grey: true)
                    Text("New").font(Tokens.Font.nunito(15, .black)).foregroundStyle(Color.textPrimary)
                        .accessibilityIdentifier("ratingNew")
                    Text("No reviews yet. Be the first!").font(Tokens.Font.caption).foregroundStyle(Color.textMuted)
                }
            }
            let shown = BlockList.visible(reviews, blocked: model.blockedRefs)
            if let latest = shown.first {
                ReviewRow(review: latest) { await reloadReviews() }
            }
            if shown.count > 1 {
                Button("All reviews (\(shown.count))") { showAllReviews = true }
                    .font(Tokens.Font.bodyBold)
                    .accessibilityIdentifier("allReviews")
            }
            Button { writing = true } label: {
                HStack(spacing: 8) {
                    FlatIconView(icon: .review, size: 22)
                    Text(myReview == nil ? "Write a review" : "Edit your review")
                }
                .font(Tokens.Font.nunito(15, .black))
                .foregroundStyle(Color.brandInk)
                .frame(maxWidth: .infinity, minHeight: 46)
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.outline, lineWidth: 2))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("writeReview")
        }
    }

    /// Photos: the strip, then "Add photo" (camera or library; metadata stripped on the phone) at the end.
    @ViewBuilder private var photosSection: some View {
        // Public photos with a URL, minus those from blocked contributors (same order for thumbs, viewer and menu).
        let publicPhotos = BlockList.visible((place?.photos ?? []).filter { $0.url != nil }, blocked: model.blockedRefs)
        let urls: [URL] = privatePlace.map { p in p.photoFiles.map { model.store.photoURL($0) } }
            ?? publicPhotos.compactMap { MediaURL.resolve($0.url) }
        let thumbs: [URL] = privatePlace.map { _ in urls }
            ?? publicPhotos.compactMap { MediaURL.resolve($0.thumbUrl ?? $0.url) }
        if !thumbs.isEmpty || canReview {
            VStack(alignment: .leading, spacing: 10) {
                sectionLabel("Photos")
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(Array(thumbs.enumerated()), id: \.offset) { i, u in
                            Button { viewer = PhotoViewerItem(urls: urls, index: i, photos: privatePlace == nil ? publicPhotos : nil) } label: {
                                RemoteImage(url: u)
                                    .frame(width: 96, height: 96)
                                    .background(Color.surfaceAlt)
                                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("placePhoto")
                            .accessibilityValue(Text(verbatim: u.absoluteString))
                        }
                        // Near or in a restricted area: photos are off (docs/safety.md B).
                        if canReview && model.restricted.proximity(of: summary.location) != .clear {
                            VStack(spacing: 4) {
                                Image(systemName: "camera.fill").font(.system(size: 22)).foregroundStyle(Color.textMuted)
                                PhotosOffCaption(reviewM: model.restricted.set?.reviewM ?? 300)
                                    .labelStyle(.titleOnly)
                                    .multilineTextAlignment(.center)
                                    .minimumScaleFactor(0.7)
                            }
                            .padding(6)
                            .frame(width: 140, height: 96)
                            .background(Color.surfaceAlt, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        } else if canReview {
                            Button { showAddPhotos = true } label: {
                                VStack(spacing: 4) {
                                    FlatIconView(icon: .camera, size: 30)
                                    Text("Add photo")
                                        .font(Tokens.Font.nunito(11, .extrabold, relativeTo: .caption))
                                        .foregroundStyle(Color.brandInk)
                                        .multilineTextAlignment(.center)
                                        .minimumScaleFactor(0.7)
                                }
                                .padding(4)
                                .frame(width: 96, height: 96)
                                .background(Color.brandMist, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("placeAddPhoto")
                        }
                    }
                }
            }
        }
    }

    private var suggestRow: some View {
        Menu { suggestOptions } label: {
            HStack(spacing: 10) {
                FlatIconView(icon: .edit, size: 22)
                Text("Suggest an edit").font(Tokens.Font.nunito(14, .extrabold)).foregroundStyle(Color.brandInk)
                Spacer()
            }
            .padding(.vertical, 10)
            .padding(.horizontal, 2)
            .contentShape(Rectangle())
        }
        .accessibilityIdentifier("suggestEditRow")
    }

    @ViewBuilder private var badgesAndVerify: some View {
        if isPrivate || isCommunity {
            HStack(spacing: 8) {
                if isPrivate { badge("Just for me", icon: .heart, id: "badgePrivate") }
                if isCommunity { badge("Community", icon: .map, id: "badgeCommunity") }
                if isCommunity && status == .pending {
                    badge("Unverified", icon: .hazard, id: "badgeUnverified")
                    VettingBadge(confirmed: verifyResult.map { Int($0.confirmationsWeighted) } ?? place?.confirmationsWeighted.map { Int($0) } ?? place?.verifiedCount ?? 0,
                                 required: verifyResult.map { Int($0.required) } ?? place?.required.map { Int($0) } ?? 3)
                }
                if let n = place?.verifiedCount, n > 0 {
                    Text("Confirmed by \(n)").font(Tokens.Font.small).foregroundStyle(Color.textMuted)
                }
            }
        }
        if isCommunity && status == .pending && model.ownPlaceIds.contains(summary.id) {
            Label("Waiting for other drivers to confirm (\(place?.verifiedCount ?? 0)/3)", systemImage: "hourglass")
                .font(Tokens.Font.caption)
                .foregroundStyle(Color.textMuted)
                .accessibilityIdentifier("awaitingVerification")
        } else if isCommunity && status == .pending {
            VStack(alignment: .leading, spacing: 10) {
                Text("Is this place here?").font(Tokens.Font.bodyBold)
                if verifyDone {
                    Label("Thanks for checking!", systemImage: "checkmark.seal.fill").foregroundStyle(Color.brand)
                        .accessibilityIdentifier("verifyThanks")
                } else if Proximity.claim(me: model.position, place: summary.location, rural: place?.tags?["rural"] == "yes") == nil {
                    Label("Get within 1 km of the place to confirm it.", systemImage: "location.circle")
                        .font(Tokens.Font.caption).foregroundStyle(Color.textMuted)
                        .accessibilityIdentifier("verifyTooFar")
                } else {
                    HStack(spacing: 8) {
                        Button { verify(.yes, location: true) } label: { Label("Yes", systemImage: "hand.thumbsup.fill") }
                            .buttonStyle(PrimaryButtonStyle())
                            .accessibilityIdentifier("verifyYes")
                        Button { verify(.no, location: nil) } label: { Label("No", systemImage: "hand.thumbsdown.fill") }
                            .buttonStyle(SecondaryButtonStyle())
                            .accessibilityIdentifier("verifyNo")
                    }
                    HStack {
                        Button("It's here, but the pin is in the wrong spot") { verify(.yes, location: false) }
                        Spacer()
                        Button("Not sure") { verify(.unsure, location: nil) }
                    }
                    .font(Tokens.Font.caption)
                }
            }
            .padding(12)
            .background(Color.brandMist, in: RoundedRectangle(cornerRadius: Tokens.Radius.md, style: .continuous))
        }
    }

    private func verify(_ answer: VoteAnswer, location: Bool?) {
        Task {
            do {
                let target = place ?? Place(summary: summary)
                verifyResult = try await model.vote(on: target, answer: answer, nameCorrect: answer == .yes ? true : nil, locationCorrect: location)
                verifyDone = true
            } catch is CancellationError {
                // The community rules were declined: nothing sent.
            } catch {
                model.showToast(error.localizedDescription)
            }
        }
    }

    @ViewBuilder private var infoRows: some View {
        if let hours = place?.openingHours ?? privatePlace?.openingHours {
            Label(hours, systemImage: "clock").font(Tokens.Font.caption).foregroundStyle(Color.textPrimary)
        }
        if let d = place?.description ?? privatePlace?.description {
            Text(d).font(Tokens.Font.body).foregroundStyle(Color.textPrimary)
        }
        if let amenities = place?.amenities ?? privatePlace?.amenities, !amenities.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(amenities, id: \.self) { a in
                        AddPlaceFlow.amenityLabel(a)
                            .font(.system(size: 12, weight: .medium))
                            .padding(.horizontal, 10).padding(.vertical, 5)
                            .background(Color.surfaceAlt, in: Capsule())
                    }
                }
            }
        }
    }

    private func badge(_ title: LocalizedStringKey, icon: GIcon, id: String) -> some View {
        HStack(spacing: 4) {
            GimanoIcon(icon: icon, size: 16)
            Text(title).font(Tokens.Font.small)
        }
        .foregroundStyle(Color.brandInk)
        .padding(.horizontal, 10).padding(.vertical, 5)
        .background(Color.brandMist, in: Capsule())
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(id)
    }
}

/// 52 pt pale-cobalt tile with the place's category icon (flat two-tone where the set has one).
struct CategoryTile: View {
    let category: PlaceCategory
    var body: some View {
        Group {
            if let f = category.flatIcon {
                FlatIconView(icon: f, size: 32)
            } else {
                GimanoIcon(icon: category.tileIcon, size: 30, stroke: .brand, fill: .brandTint)
            }
        }
        .frame(width: 52, height: 52)
        .background(Color.brandMist, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .accessibilityHidden(true)
    }
}

extension PlaceCategory {
    /// Flat two-tone icon (home panel set) for the categories it covers.
    var flatIcon: FlatIcon? {
        switch self {
        case .fuel: .fuel
        case .evCharging: .ev
        case .restaurant, .cafe, .fastFood, .restArea: .food
        case .mosque, .surau: .surau
        case .parking: .parking
        case .convenience, .supermarket, .mall: .shop
        default: nil
        }
    }
}

/// Five stars: gold (#F5B301), a paler gold for a half star, grey (#D5DCE8) when there are no reviews.
struct RatingStars: View {
    let rating: Double
    var size: CGFloat = 15
    var grey = false

    var body: some View {
        HStack(spacing: 1) {
            ForEach(1...5, id: \.self) { i in
                let f = grey ? 0 : PlaceRatingLine.starFill(i, rating: rating)
                StarShape()
                    .fill(f == 1 ? Color.starFill : f > 0 ? Color.starHalf : Color.starEmpty)
                    .frame(width: size, height: size)
            }
        }
        .accessibilityElement()
        .accessibilityLabel(Text(grey ? "No reviews yet" : "\(String(format: "%.1f", rating)) stars"))
    }
}

private struct StarShape: Shape {
    func path(in rect: CGRect) -> Path {
        let p = SVGPath.parse("m12 2 3 6.3 6.9.9-5 4.8 1.2 6.8L12 17.6l-6.1 3.2L7.1 14l-5-4.8 6.9-.9z").fill
        let s = min(rect.width, rect.height) / 24
        var t = CGAffineTransform(translationX: rect.midX - 12 * s, y: rect.midY - 12 * s).scaledBy(x: s, y: s)
        return Path(p.copy(using: &t) ?? p)
    }
}

/// The white route diamond on the primary "Routes" button.
private struct RouteGlyph: View {
    var body: some View {
        ZStack {
            PathShape(d: "M12 2 22 12 12 22 2 12z").fill(Color.brandOn.opacity(0.25))
            PathShape(d: "M9 15v-3a2 2 0 0 1 2-2h4V8l3 3-3 3v-2h-4v3z").fill(Color.brandOn)
        }
        .accessibilityHidden(true)
    }
}

private struct PathShape: Shape {
    let d: String
    func path(in rect: CGRect) -> Path {
        let p = SVGPath.parse(d).fill
        let s = min(rect.width, rect.height) / 24
        var t = CGAffineTransform(translationX: rect.midX - 12 * s, y: rect.midY - 12 * s).scaledBy(x: s, y: s)
        return Path(p.copy(using: &t) ?? p)
    }
}

extension Color {
    /// Rating star gold (#F5B301), half-star (#F9D77A) and the grey of an unrated place (#D5DCE8).
    static let starFill = Color(light: 0xF5B301, dark: 0xF5B301)
    static let starHalf = Color(light: 0xF9D77A, dark: 0xB89A4A)
    static let starEmpty = Color(light: 0xD5DCE8, dark: 0x34425F)
}

/// "Suggest an edit" (any place, including OSM): hours, phone, website, category, name, comment.
struct SuggestEditSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let placeId: String
    let current: Place?
    let fallback: PlaceSummary
    /// Called after the suggestion was sent (e.g. B1 "Yes, that's it" closes the add-place flow).
    var onSent: (() -> Void)? = nil
    @State private var name = ""
    @State private var category: PlaceCategory = .other
    @State private var phone = ""
    @State private var website = ""
    @State private var hours = OpeningHours.uniform([OpeningHours.Range(open: 8 * 60, close: 22 * 60)])
    @State private var editHours = false
    @State private var comment = ""
    @State private var sending = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("Name") { TextField("Name", text: $name).accessibilityIdentifier("suggestName") }
                Section("Category") {
                    Picker("Category", selection: $category) {
                        ForEach(AddPlaceCategories.all, id: \.0) { c, t in Text(t).tag(c) }
                    }
                }
                Section("Contact") {
                    TextField("Phone", text: $phone).keyboardType(.phonePad)
                    TextField("Website", text: $website).keyboardType(.URL).textInputAutocapitalization(.never)
                }
                Section {
                    Toggle("Change opening hours", isOn: $editHours)
                    if editHours { OpeningHoursEditor(hours: $hours) }
                }
                Section("Anything else?") {
                    TextField("e.g. moved to the next shoplot", text: $comment, axis: .vertical).lineLimit(2...4)
                        .accessibilityIdentifier("suggestComment")
                }
                Section {
                    Button("Send suggestion") { Task { await send() } }
                        .disabled(sending)
                        .accessibilityIdentifier("sendSuggestion")
                    if let error { Text(error).foregroundStyle(Color.speeding).font(Tokens.Font.caption) }
                }
            }
            .navigationTitle("Suggest an edit")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarLeading) { Button("Cancel") { dismiss() } } }
            .onAppear {
                name = current?.name ?? fallback.name
                category = current?.category ?? fallback.category
                phone = current?.phone ?? ""
                website = current?.website ?? ""
                if let h = current?.openingHours, let parsed = OpeningHours.parse(h) { hours = parsed }
            }
        }
    }

    private func send() async {
        guard await model.ensureRulesAccepted() else { return }
        sending = true
        defer { sending = false }
        func changed(_ new: String, _ old: String?) -> String? {
            let t = new.trimmingCharacters(in: .whitespaces)
            return t.isEmpty || t == (old ?? "") ? nil : t
        }
        let s = PlaceEditSuggestion(
            name: changed(name, current?.name ?? fallback.name),
            category: category == (current?.category ?? fallback.category) ? nil : category,
            phone: changed(phone, current?.phone), website: changed(website, current?.website),
            openingHours: editHours ? hours.osm : nil,
            comment: comment.trimmingCharacters(in: .whitespaces).isEmpty ? nil : comment)
        do {
            _ = try await model.repo.suggestEdit(placeId: placeId, s)
            model.showToast(String(localized: "Thanks! Your suggestion was sent."))
            dismiss()
            onSent?()
        } catch let e as APIError where e.isServerSideGap {
            error = String(localized: "Edit suggestions aren't available on the server yet.")
        } catch {
            self.error = error.localizedDescription
        }
    }
}
