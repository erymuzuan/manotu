import AVFoundation
import PhotosUI
import SwiftUI

/// Categories offered when adding a place (big icon grid).
@MainActor
enum AddPlaceCategories {
    static let all: [(PlaceCategory, LocalizedStringKey)] = [
        (.restaurant, "Food"), (.cafe, "Cafe"), (.fuel, "Fuel"), (.surau, "Surau"), (.mosque, "Mosque"), (.parking, "Parking"),
        (.evCharging, "EV"), (.convenience, "Shop"), (.carRepair, "Workshop"), (.clinic, "Clinic"), (.school, "School"), (.other, "Other"),
    ]

    /// Plain-word category name for sentences ("Convenience store nearby · 6").
    static func title(_ c: PlaceCategory) -> String.LocalizationValue {
        switch c {
        case .convenience: "Convenience store"
        case .fuel: "Petrol station"
        case .restaurant, .fastFood: "Food"
        case .cafe: "Cafe"
        case .surau: "Surau"
        case .mosque: "Mosque"
        case .clinic: "Clinic"
        case .hospital: "Hospital"
        case .parking: "Parking"
        case .carRepair: "Workshop"
        case .school: "School"
        case .tollBooth: "Toll plaza"
        case .restArea: "R&R"
        case .evCharging: "EV charging"
        default: "Place"
        }
    }
}

extension PlaceCategory {
    /// Duotone icon (shared set), with sensible stand-ins for categories without their own glyph.
    var tileIcon: GIcon {
        if let g = gIcon { return g }
        switch self {
        case .convenience, .supermarket, .mall: return .shop
        case .clinic, .hospital, .pharmacy: return .hospital
        case .school, .university: return .school
        case .carRepair, .carWash: return .car
        default: return .map
        }
    }
}

/// One photo picked for a new place or review (kept as upload-ready JPEG + a preview).
struct PickedPhoto: Identifiable, Equatable {
    let id = UUID()
    let jpeg: Data
    let preview: UIImage
}

enum PhotoPicking {
    static let maxPhotos = 5

    /// Loads picker items as ≤ 2048 px JPEG (HEIC/PNG converted, metadata stripped).
    static func load(_ items: [PhotosPickerItem]) async -> [PickedPhoto] {
        var out: [PickedPhoto] = []
        for item in items {
            guard let data = try? await item.loadTransferable(type: Data.self),
                  let jpeg = ImageProcessing.uploadJPEG(data), let img = UIImage(data: jpeg) else { continue }
            out.append(PickedPhoto(jpeg: jpeg, preview: img))
        }
        return out
    }

    static func picked(_ image: UIImage) -> PickedPhoto? {
        guard let jpeg = ImageProcessing.uploadJPEG(image), let img = UIImage(data: jpeg) else { return nil }
        return PickedPhoto(jpeg: jpeg, preview: img)
    }

    #if DEBUG
    /// Generated photo for UI tests (`-GimanoTestPhotos YES`), so tests don't depend on the photo library.
    static func testPhoto() -> PickedPhoto? {
        let img = UIGraphicsImageRenderer(size: CGSize(width: 1200, height: 900)).image { ctx in
            UIColor(hex: 0x0047AB).setFill(); ctx.fill(CGRect(x: 0, y: 0, width: 1200, height: 900))
            UIColor(hex: 0xFF6B4A).setFill(); ctx.fill(CGRect(x: 300, y: 250, width: 600, height: 400))
            ("Gimano test photo" as NSString).draw(at: CGPoint(x: 340, y: 420), withAttributes: [.font: UIFont.boldSystemFont(ofSize: 60), .foregroundColor: UIColor.white])
        }
        return picked(img)
    }
    #endif
}

/// Photo row: thumbnails, remove, PhotosPicker and camera.
struct PhotoPickerRow: View {
    @Binding var photos: [PickedPhoto]
    @State private var items: [PhotosPickerItem] = []
    @State private var showCamera = false
    @State private var showLibrary = false
    @State private var cameraDenied = false

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(photos) { p in
                    Image(uiImage: p.preview)
                        .resizable().scaledToFill()
                        .frame(width: 76, height: 76)
                        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                        .overlay(alignment: .topTrailing) {
                            Button { photos.removeAll { $0.id == p.id } } label: {
                                Image(systemName: "xmark.circle.fill").font(.system(size: 22)).foregroundStyle(.white, .black.opacity(0.6))
                            }
                            .padding(4)
                            .accessibilityLabel(Text("Remove photo"))
                        }
                        .accessibilityIdentifier("pickedPhoto")
                }
                if photos.count < PhotoPicking.maxPhotos {
                    // One "Add photo" tile: Take photo / Choose from library (no full photo-library permission).
                    Menu {
                        if UIImagePickerController.isSourceTypeAvailable(.camera) {
                            Button { openCamera() } label: { Label("Take photo", systemImage: "camera") }
                                .accessibilityIdentifier("takePhoto")
                        }
                        Button { showLibrary = true } label: { Label("Choose from library", systemImage: "photo.on.rectangle") }
                            .accessibilityIdentifier("pickPhotos")
                    } label: {
                        tile(system: "camera.fill", title: "Add photo")
                    }
                    .accessibilityIdentifier("addPhotoMenu")
                    #if DEBUG
                    if UserDefaults.standard.bool(forKey: "GimanoTestPhotos") {
                        Button { if let p = PhotoPicking.testPhoto() { photos.append(p) } } label: { tile(system: "testtube.2", title: "Test") }
                            .accessibilityIdentifier("addTestPhoto")
                    }
                    #endif
                }
            }
        }
        .photosPicker(isPresented: $showLibrary, selection: $items, maxSelectionCount: max(1, PhotoPicking.maxPhotos - photos.count),
                      matching: .images, photoLibrary: .shared())
        .onChange(of: items) {
            let picked = items
            items = []
            Task { photos += await PhotoPicking.load(picked).prefix(PhotoPicking.maxPhotos - photos.count) }
        }
        .fullScreenCover(isPresented: $showCamera) {
            CameraPicker { image in
                if let image, let p = PhotoPicking.picked(image), photos.count < PhotoPicking.maxPhotos { photos.append(p) }
                showCamera = false
            }
            .ignoresSafeArea()
        }
        .alert("Camera access is off", isPresented: $cameraDenied) {
            Button("Open Settings") { if let u = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(u) } }
            Button("Choose from library") { showLibrary = true }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Allow camera access for Manotu in Settings, or choose a photo from your library.")
        }
    }

    /// Asks for the camera the first time; explains how to turn it on when it was refused.
    private func openCamera() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: showCamera = true
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { ok in
                Task { @MainActor in if ok { showCamera = true } else { cameraDenied = true } }
            }
        default: cameraDenied = true
        }
    }

    private func tile(system: String, title: LocalizedStringKey) -> some View {
        VStack(spacing: 4) {
            Image(systemName: system).font(.system(size: 24, weight: .semibold))
            Text(title).font(Tokens.Font.small)
        }
        .foregroundStyle(Color.brandInk)
        .frame(width: 76, height: 76)
        .background(Color.brandMist, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

/// UIImagePickerController camera wrapper.
struct CameraPicker: UIViewControllerRepresentable {
    let onDone: (UIImage?) -> Void

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let c = UIImagePickerController()
        c.sourceType = .camera
        c.delegate = context.coordinator
        return c
    }

    func updateUIViewController(_ c: UIImagePickerController, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(onDone) }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let onDone: (UIImage?) -> Void
        init(_ onDone: @escaping (UIImage?) -> Void) { self.onDone = onDone }
        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            onDone(info[.originalImage] as? UIImage)
        }
        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) { onDone(nil) }
    }
}

/// Opens the flow pre-filled: an edit of the user's own place ("Edit and try again") or a draft saved on the phone.
struct AddPlaceSeed: Hashable, Sendable {
    var place: NewPlace
    /// The user's community place to PATCH instead of creating a new one.
    var editingId: String?
    /// The phone draft this came from (removed once shared).
    var draftId: UUID?
}

/// "Can't find it? Add a place": pin → details → visibility → save → the AI check's answer (boards A1–B6).
struct AddPlaceFlow: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let start: LatLng

    enum Step { case pin, details, warnings, visibility }
    /// After "Share with everyone": the check is running, or what it answered.
    enum Phase {
        case checking
        case result(Place, AddPlaceOutcome)
        case offline
        case limit(AddPlaceFailure)
    }
    @State private var step: Step = .pin
    @State private var phase: Phase?
    @State private var pinMap: MapState?
    @State private var center: LatLng
    @State private var address = ""
    @State private var name = ""
    @State private var category: PlaceCategory = .restaurant
    @State private var phone = ""
    @State private var website = ""
    @State private var details = ""
    @State private var amenities: Set<String> = []
    /// "Anything people should know?": sent as `warnings[]` on POST /places.
    @State private var warnings: Set<PlaceWarning> = []
    @State private var hours = OpeningHours.uniform([OpeningHours.Range(open: 8 * 60, close: 22 * 60)])
    @State private var hoursEnabled = false
    @State private var photos: [PickedPhoto] = []
    @State private var saving = false
    @State private var uploadProgress: Double?
    /// B1: the 409's similar place.
    @State private var duplicate: PlaceSummary?
    /// B1 "Yes, that's it": the existing place's suggest-edit.
    @State private var suggestFor: PlaceSummary?
    /// B1 "No, mine is a different place": sent with the next POST.
    @State private var notDuplicateOf: String?
    /// The user's own place this flow edits (seeded, or created here and then "Edit and try again").
    @State private var editingId: String?
    @State private var draftId: UUID?
    /// The form is editing an existing place (seeded edit, or "Edit and try again"): titled "Edit place".
    @State private var isEditing = false
    /// C1 from B3/B4.
    @State private var appealFor: Place?
    /// A1 before the first shared place.
    @State private var showIntro = false
    @State private var error: String?
    /// A · the pin is in a restricted area: the sheet instead of the form.
    @State private var showBlocked = false
    /// "Save just for me" from A: only the private choice is offered (it never leaves the phone).
    @State private var privateOnly = false

    init(start: LatLng, seed: AddPlaceSeed? = nil) {
        self.start = start
        _center = State(initialValue: start)
        if let seed {
            let p = seed.place
            _center = State(initialValue: LatLng(lat: p.lat, lng: p.lng))
            _name = State(initialValue: p.name)
            _category = State(initialValue: p.category)
            _address = State(initialValue: p.address ?? "")
            _details = State(initialValue: p.description ?? "")
            _phone = State(initialValue: p.phone ?? "")
            _website = State(initialValue: p.website ?? "")
            _amenities = State(initialValue: Set(p.amenities ?? []))
            _warnings = State(initialValue: Set(PlaceWarning.parse(p.warnings)))
            if let h = p.openingHours, let parsed = OpeningHours.parse(h) {
                _hours = State(initialValue: parsed)
                _hoursEnabled = State(initialValue: true)
            }
            _notDuplicateOf = State(initialValue: p.notDuplicateOf)
            _editingId = State(initialValue: seed.editingId)
            _isEditing = State(initialValue: seed.editingId != nil)
            _draftId = State(initialValue: seed.draftId)
            // A draft goes straight to "share"; an edit opens the form.
            _step = State(initialValue: seed.draftId != nil ? .visibility : .details)
        }
        #if DEBUG
        // `-GimanoAddPlaceStep details` (device screenshots): open at the form.
        if UserDefaults.standard.string(forKey: "GimanoAddPlaceStep") == "details" { _step = State(initialValue: .details) }
        #endif
    }

    static let amenityOptions: [(String, LocalizedStringKey)] = [
        ("toilets", "Toilets"), ("surau", "Surau"), ("parking", "Parking"), ("wheelchair", "Wheelchair"),
        ("wifi", "Wi-Fi"), ("ev_charging", "EV charging"), ("cards", "Cards"), ("touch_n_go", "Touch 'n Go"),
    ]

    /// Localized amenity name for any key (place card and the editor share it).
    static func amenityLabel(_ key: String) -> Text {
        let extra: [String: LocalizedStringKey] = [
            "air_conditioning": "Air conditioning", "card_payment": "Cards", "ewallet": "E-wallet",
            "compressed_air": "Air pump", "outdoor_seating": "Outdoor seating", "takeaway": "Takeaway", "delivery": "Delivery",
        ]
        if let k = amenityOptions.first(where: { $0.0 == key })?.1 ?? extra[key] { return Text(k) }
        return Text(verbatim: key.replacingOccurrences(of: "_", with: " ").capitalized)
    }

    var body: some View {
        NavigationStack {
            Group {
                if let phase {
                    phaseView(phase)
                } else {
                    switch step {
                    case .pin: pinStep
                    case .details: detailsStep
                    case .warnings: WarningsStepView(selection: $warnings) { step = .visibility }
                    case .visibility: visibilityStep
                    }
                }
            }
            .navigationTitle(isEditing && phase == nil ? "Edit place" : "Add a place")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if phase == nil {
                        Button(step == .pin ? "Cancel" : "Back") {
                            switch step {
                            case .pin: dismiss()
                            case .details: step = .pin
                            case .warnings: step = .details
                            case .visibility: step = privateOnly ? .details : .warnings
                            }
                        }
                        .accessibilityIdentifier("addPlaceBack")
                    } else if case .checking? = phase {
                        // The answer also arrives in the Inbox (A3).
                        Button("Close") { dismiss() }.accessibilityIdentifier("addPlaceClose")
                    }
                }
            }
        }
        .sheet(item: $duplicate) { d in
            DuplicatePlaceSheet(existing: d, typedName: trimmedName, distanceM: d.distanceM ?? Geo.distance(d.location, center),
                                onSuggestEdit: {
                                    duplicate = nil
                                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { suggestFor = d }
                                }, onDifferent: {
                                    duplicate = nil
                                    notDuplicateOf = d.id
                                    Task { await savePublic() }
                                })
                .presentationDetents([.medium, .large])
                .presentationCornerRadius(Tokens.Radius.sheetTop)
        }
        .sheet(item: $suggestFor) { d in
            SuggestEditSheet(placeId: d.id, current: nil, fallback: d) {
                // The suggestion went to the place that's already there: nothing new to add.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { dismiss() }
            }
        }
        .sheet(item: $appealFor) { p in
            AppealSheet(placeId: p.id, name: p.name, reason: ScreeningReason.primary(p.screening?.reasons ?? [])) { _ in
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { dismiss() }
            }
        }
        .sheet(isPresented: $showIntro) {
            AddPlaceIntroSheet {
                UserDefaults.standard.set(true, forKey: AddPlaceIntro.seenKey)
                showIntro = false
                Task { await savePublic() }
            }
            .presentationDetents([.large])
            .presentationCornerRadius(Tokens.Radius.sheetTop)
        }
        .sheet(isPresented: $showBlocked) {
            RestrictedBlockedSheet(onMove: {
                showBlocked = false
                phase = nil
                step = .pin
            }, onSavePrivate: {
                showBlocked = false
                phase = nil
                privateOnly = true
                step = .details
            }, onCancel: {
                showBlocked = false
                dismiss()
            })
            .presentationDetents([.large])
            .presentationCornerRadius(Tokens.Radius.sheetTop)
        }
    }

    // MARK: restricted areas (docs/safety.md part 4)

    private var proximity: RestrictedProximity { model.restricted.proximity(of: center) }
    /// B: public and within reviewM: photos off, held for a moderator.
    private var isNear: Bool { !privateOnly && proximity == .near }
    private func sensitive(_ text: String) -> Bool { !privateOnly && model.restricted.terms.matches(text) }
    /// Held for review before others see it (near, or sensitive words).
    private var willBeReviewed: Bool { isNear || sensitive(name) || sensitive(details) }

    // MARK: 1. pin

    private var pinStep: some View {
        ZStack {
            if let pinMap {
                GimanoMapView(state: pinMap).ignoresSafeArea(edges: .bottom)
            }
            // Fixed centre pin: move the map under it.
            VStack(spacing: 0) {
                GimanoIcon(icon: .addStop, size: 54, stroke: .brand, fill: .brandTint)
                    .shadow(color: .black.opacity(0.2), radius: 4, y: 2)
                Color.clear.frame(height: 54)
            }
            .allowsHitTesting(false)
            .accessibilityIdentifier("centerPin")
            VStack {
                Spacer()
                VStack(alignment: .leading, spacing: 10) {
                    Text("Move the map to put the pin on the place").font(Tokens.Font.label).foregroundStyle(Color.textMuted)
                    Label(address.isEmpty ? String(localized: "Finding the address…") : address, systemImage: "mappin.and.ellipse")
                        .font(Tokens.Font.bodyBold)
                        .lineLimit(2)
                        .accessibilityIdentifier("pinAddress")
                    Button("Next") {
                        if proximity == .blocked && !privateOnly { showBlocked = true } else { step = .details }
                    }
                    .buttonStyle(PrimaryButtonStyle())
                    .accessibilityIdentifier("pinNext")
                }
                .padding(Tokens.Space.gutter)
                .background(Color.surface, in: RoundedRectangle(cornerRadius: Tokens.Radius.lg, style: .continuous))
                .padding(Tokens.Space.gutter)
            }
        }
        .onAppear {
            if pinMap == nil {
                let m = MapState(styleURL: model.config.styleURL)
                m.puck = model.position
                m.camera = .center(center, zoom: 17)
                m.cameraRevision = 1
                m.restrictedAreas = model.restricted.rings
                pinMap = m
                // Long-press "Add a place" inside an area goes straight to A.
                if model.restricted.proximity(of: center) == .blocked { showBlocked = true }
            }
        }
        .task(id: pinMap?.visibleBBox) {
            guard let b = pinMap?.visibleBBox else { return }
            center = LatLng(lat: (b.minLat + b.maxLat) / 2, lng: (b.minLng + b.maxLng) / 2)
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            if let rg = try? await model.repo.reverseGeocode(center) { address = rg.address ?? rg.name ?? "" }
        }
    }

    // MARK: 2. details

    private var detailsStep: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if isNear { RestrictedNearNote() }
                TextField(String(localized: "Name (required)"), text: $name)
                    .font(Tokens.Font.nunito(20, .bold))
                    .padding(.horizontal, 16)
                    .frame(height: 60)
                    .background(Color.surfaceAlt, in: RoundedRectangle(cornerRadius: Tokens.Radius.searchField, style: .continuous))
                    .accessibilityIdentifier("placeName")
                if sensitive(name) {
                    SensitiveTermsWarning { name = model.restricted.terms.removingMatchingSentences(name) }
                }

                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 4), spacing: 10) {
                    ForEach(AddPlaceCategories.all, id: \.0) { cat, title in
                        Button { category = cat } label: {
                            VStack(spacing: 4) {
                                GimanoIcon(icon: cat.tileIcon, size: 34)
                                Text(title).font(Tokens.Font.small).lineLimit(1)
                            }
                            .foregroundStyle(Color.brandInk)
                            .frame(maxWidth: .infinity, minHeight: 72)
                            .selectableTile(category == cat, radius: 18)
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("category.\(cat.rawValue)")
                    }
                }

                if isNear {
                    VStack(alignment: .leading, spacing: 6) {
                        PhotoPickerRow(photos: .constant([])).disabled(true).opacity(0.45)
                        PhotosOffCaption(reviewM: model.restricted.set?.reviewM ?? 300)
                    }
                    .onAppear { photos = [] }
                } else {
                    PhotoPickerRow(photos: $photos)
                }

                Toggle("Opening hours", isOn: $hoursEnabled.animation()).font(Tokens.Font.bodyBold).accessibilityIdentifier("hoursToggle")
                if hoursEnabled { OpeningHoursEditor(hours: $hours) }

                Group {
                    TextField("Phone (optional)", text: $phone).keyboardType(.phonePad)
                    TextField("Website (optional)", text: $website).keyboardType(.URL).textInputAutocapitalization(.never)
                    TextField("What should drivers know? (optional)", text: $details, axis: .vertical).lineLimit(2...5)
                        .accessibilityIdentifier("placeDescription")
                }
                .padding(14)
                .background(Color.surfaceAlt, in: RoundedRectangle(cornerRadius: Tokens.Radius.md, style: .continuous))
                if sensitive(details) {
                    SensitiveTermsWarning { details = model.restricted.terms.removingMatchingSentences(details) }
                }

                Text("Amenities").font(Tokens.Font.label).foregroundStyle(Color.textMuted)
                FlowChips(options: Self.amenityOptions, selection: $amenities)

                Button("Next") { step = privateOnly ? .visibility : .warnings }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                    .accessibilityIdentifier("detailsNext")
            }
            .padding(Tokens.Space.gutter)
        }
        .scrollDismissesKeyboard(.interactively)
    }

    // MARK: 3. visibility

    private var visibilityStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Make this place discoverable by other Gimano users?").font(Tokens.Font.title)
            visibilityCard(icon: .heart, title: "Just for me", subtitle: "Saved only on this phone (and in your own backups). Never sent to Gimano.",
                           id: "visibilityPrivate") { Task { await savePrivate() } }
            if !privateOnly {
                if willBeReviewed {
                    visibilityCard(icon: .map, title: "Send for review", subtitle: "A moderator will check this place before others can see it.",
                                   id: "visibilityPublic") { sharePublic() }
                } else {
                    visibilityCard(icon: .map, title: "Share with everyone", subtitle: "Other drivers will help verify it.",
                                   id: "visibilityPublic") { sharePublic() }
                    // A2 hint line.
                    Text("Shared places get a quick automatic check, then people nearby confirm them.")
                        .font(Tokens.Font.caption).foregroundStyle(Color.textMuted)
                        .accessibilityIdentifier("addPlaceCheckHint")
                }
            }
            if saving, let uploadProgress {
                ProgressView(value: uploadProgress) { Text("Uploading photos…").font(Tokens.Font.caption) }
                    .accessibilityIdentifier("uploadProgress")
            }
            if let error { Text(error).foregroundStyle(Color.speeding).font(Tokens.Font.caption).accessibilityIdentifier("addPlaceError") }
            Spacer()
        }
        .padding(Tokens.Space.gutter)
        .disabled(saving)
    }

    private func visibilityCard(icon: GIcon, title: LocalizedStringKey, subtitle: LocalizedStringKey, id: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 14) {
                GimanoIcon(icon: icon, size: 40)
                    .frame(width: 64, height: 64)
                    .background(Color.brandMist, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(Tokens.Font.nunito(19, .extrabold))
                    Text(subtitle).font(Tokens.Font.caption).foregroundStyle(Color.textMuted).multilineTextAlignment(.leading)
                }
                Spacer(minLength: 0)
            }
            .foregroundStyle(Color.textPrimary)
            .padding(14)
            .background(Color.surface, in: RoundedRectangle(cornerRadius: Tokens.Radius.lg, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Tokens.Radius.lg, style: .continuous).stroke(Color.outline, lineWidth: 1.5))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(id)
    }

    // MARK: 4. after "Share with everyone"

    @ViewBuilder private func phaseView(_ phase: Phase) -> some View {
        switch phase {
        case .checking:
            AddPlaceCheckingView(name: trimmedName)
        case .result(let place, let outcome):
            AddPlaceResultView(place: place, outcome: outcome, actions: resultActions(place, outcome),
                               isNewContributor: model.isNewContributor)
        case .offline:
            AddPlaceOfflineView { dismiss() }
        case .limit(let failure):
            AddPlaceLimitView(failure: failure, onSaveDraft: {
                model.placeOutbox.save(newPlace(), state: .draft, shareAfter: failure.shareAfter(), replacing: draftId)
                model.reloadLocal()
                dismiss()
                model.showToast(String(localized: "Saved as a draft on this phone"))
            }, onKeepPrivate: { Task { await savePrivate() } })
        }
    }

    private func resultActions(_ place: Place, _ outcome: AddPlaceOutcome) -> AddPlaceResultActions {
        AddPlaceResultActions(
            done: {
                dismiss()
                switch outcome {
                case .live, .published: model.openPlace(place.summary)
                default: break
                }
            },
            edit: {
                editingId = place.id
                isEditing = true
                notDuplicateOf = nil
                phase = nil
                step = .details
            },
            appeal: { appealFor = place },
            discard: {
                let repo = model.repo
                Task { try? await repo.deleteCommunityPlace(id: place.id) }
                dismiss()
                model.showToast(String(localized: "Discarded"))
            },
            keepPrivate: { Task { await savePrivate() } })
    }

    // MARK: save

    private var trimmedName: String { name.trimmingCharacters(in: .whitespaces) }
    private func opt(_ s: String) -> String? { s.trimmingCharacters(in: .whitespaces).isEmpty ? nil : s.trimmingCharacters(in: .whitespaces) }

    private func newPlace(notDuplicateOf: String? = nil) -> NewPlace {
        NewPlace(name: trimmedName, category: category, lat: center.lat, lng: center.lng, address: opt(address),
                 description: opt(details), phone: opt(phone), website: opt(website),
                 openingHours: hoursEnabled ? opt(hours.osm) : nil, amenities: amenities.sorted(), notDuplicateOf: notDuplicateOf,
                 warnings: PlaceWarning.wire(warnings))
    }

    private func savePrivate() async {
        saving = true
        defer { saving = false }
        let webps = photos.compactMap { ImageProcessing.webp($0.jpeg) }
        let p = PrivatePlace(id: "", name: trimmedName, category: category, lat: center.lat, lng: center.lng, address: opt(address),
                             description: opt(details), phone: opt(phone), website: opt(website),
                             openingHours: hoursEnabled ? opt(hours.osm) : nil, amenities: amenities.sorted())
        do {
            let saved = try model.store.addPrivatePlace(p, webpPhotos: webps)
            // B4 "Keep it just for me": the not-accepted copy on the server (owner-only) is removed; a draft is done.
            if let editingId {
                let repo = model.repo
                Task { try? await repo.deleteCommunityPlace(id: editingId) }
            }
            if let draftId { model.placeOutbox.remove(draftId) }
            model.reloadLocal()
            dismiss()
            model.showToast(String(localized: "Saved on this phone only"))
            model.openPlace(saved.summary)
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// "Share with everyone": A1 once, then the check.
    private func sharePublic() {
        if editingId == nil,
           AddPlaceIntro.shouldShow(seen: UserDefaults.standard.bool(forKey: AddPlaceIntro.seenKey),
                                    sharedBefore: !model.ownPlaceIds.isEmpty, privateOnly: privateOnly) {
            showIntro = true
        } else {
            Task { await savePublic() }
        }
    }

    private func savePublic() async {
        // The pin may have moved since: check again before anything is sent.
        if proximity == .blocked { showBlocked = true; return }
        guard await model.ensureRulesAccepted() else { return }
        guard !saving else { return }
        saving = true
        error = nil
        defer { saving = false }
        let held = willBeReviewed
        let editing = editingId
        let new = newPlace(notDuplicateOf: editing == nil ? notDuplicateOf : nil)
        phase = .checking
        let started = Date()
        do {
            let place: Place
            if let editing { place = try await model.repo.updateCommunityPlace(id: editing, new) } else { place = try await model.repo.createPlace(new) }
            model.rememberOwnPlace(place.id)
            if let draftId { model.placeOutbox.remove(draftId); self.draftId = nil; model.reloadLocal() }
            editingId = place.id
            notDuplicateOf = nil
            let outcome = AddPlaceOutcome.of(place)
            if !outcome.isNotAccepted { await uploadPhotos(to: place) }
            // A3 stays up long enough to read (the answer usually takes about 2 s).
            let shown = Date().timeIntervalSince(started)
            if shown < 0.8 { try? await Task.sleep(for: .seconds(0.8 - shown)) }
            if case .unscreened(let wasHeld) = outcome {
                // The check didn't run (off, over budget, older server): as before.
                dismiss()
                if wasHeld || held {
                    model.showToast(String(localized: "Checked within 24 hours. You'll get a note in your Inbox."), seconds: 4)
                } else {
                    model.showToast(String(localized: "Thanks! Other drivers will help verify it."))
                    model.openPlace(place.summary)
                }
                return
            }
            phase = .result(place, outcome)
        } catch {
            phase = nil
            handle(AddPlaceFailure.classify(error), new: new)
        }
    }

    private func handle(_ failure: AddPlaceFailure, new: NewPlace) {
        switch failure {
        case .duplicate(let existing):
            duplicate = existing
        case .conflict:
            error = String(localized: "This place may already exist.")
        case .limit, .paused:
            phase = .limit(failure)
        case .offline:
            if editingId != nil {
                error = String(localized: "You're offline. Try again when you're back online.")
            } else {
                // B6: queued on the phone (device-local outbox), sent and checked when back online.
                model.placeOutbox.save(new, state: .queued, replacing: draftId)
                model.reloadLocal()
                phase = .offline
            }
        case .suspended:
            error = APIError.http(status: 403, problem: nil).localizedDescription
        case .restricted:
            showBlocked = true
        case .unavailable:
            error = String(localized: "Sharing places isn't available on the server yet. Save it just for you for now.")
        case .other(let message):
            error = message
        }
    }

    /// Photos never block the place: one that's refused (restricted area nearby, network) is skipped.
    private func uploadPhotos(to place: Place) async {
        guard !photos.isEmpty, !isNear else { return }
        uploadProgress = 0
        defer { uploadProgress = nil }
        for (i, p) in photos.enumerated() {
            let base = Double(i) / Double(photos.count), share = 1 / Double(photos.count)
            _ = try? await model.repo.uploadPhoto(p.jpeg, placeId: place.id, caption: nil) { frac in
                Task { @MainActor in uploadProgress = base + frac * share }
            }
        }
        photos = []
    }
}

/// Wrapping multi-select chips.
struct FlowChips: View {
    let options: [(String, LocalizedStringKey)]
    @Binding var selection: Set<String>

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 104), spacing: 8)], alignment: .leading, spacing: 8) {
            ForEach(options, id: \.0) { key, title in
                let on = selection.contains(key)
                Button {
                    if on { selection.remove(key) } else { selection.insert(key) }
                } label: {
                    Text(title)
                        .font(Tokens.Font.label)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .foregroundStyle(on ? Color.brandOn : Color.brandInk)
                        .background(on ? Color.brand : Color.brandMist, in: Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("amenity.\(key)")
            }
        }
    }
}

/// Day chips + 24 h time ranges + Closed → OSM opening_hours.
struct OpeningHoursEditor: View {
    @Binding var hours: OpeningHours
    @State private var selected: Set<OpeningHours.Day> = [.mo, .tu, .we, .th, .fr]

    private var firstSelected: OpeningHours.Day { selected.min() ?? .mo }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                ForEach(OpeningHours.Day.allCases) { d in
                    let on = selected.contains(d)
                    Button {
                        if on { if selected.count > 1 { selected.remove(d) } } else { selected.insert(d) }
                    } label: {
                        Text(verbatim: d.shortName)
                            .font(Tokens.Font.label)
                            .frame(maxWidth: .infinity, minHeight: 40)
                            .foregroundStyle(on ? Color.brandOn : Color.brandInk)
                            .background(on ? Color.brand : Color.brandMist, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("day.\(d.osm)")
                }
            }
            HStack(spacing: 8) {
                quick("24 h") { apply([OpeningHours.Range(open: 0, close: 1440)]) }
                quick("Closed") { apply([]) }
                quick("+ Time") { apply(hours.ranges(firstSelected) + [OpeningHours.Range(open: 14 * 60, close: 18 * 60)]) }
            }
            let ranges = hours.ranges(firstSelected)
            if ranges.isEmpty {
                Text("Closed").font(Tokens.Font.bodyBold).foregroundStyle(Color.textMuted)
            }
            ForEach(Array(ranges.enumerated()), id: \.offset) { i, r in
                HStack {
                    timePicker(r.open) { v in update(i) { $0.open = v } }
                    Text("–")
                    timePicker(min(r.close, 1439)) { v in update(i) { $0.close = v } }
                    Spacer()
                    Button { apply(ranges.enumerated().filter { $0.offset != i }.map(\.element)) } label: {
                        Image(systemName: "minus.circle.fill").font(.system(size: 22)).foregroundStyle(Color.speeding)
                    }
                    .accessibilityLabel(Text("Remove time"))
                }
            }
            Text(verbatim: hours.osm.isEmpty ? "—" : hours.osm)
                .font(.system(.footnote, design: .monospaced))
                .foregroundStyle(Color.textMuted)
                .accessibilityIdentifier("hoursPreview")
        }
        .padding(12)
        .background(Color.surfaceAlt, in: RoundedRectangle(cornerRadius: Tokens.Radius.md, style: .continuous))
    }

    private func quick(_ title: LocalizedStringKey, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(Tokens.Font.label).padding(.horizontal, 12).padding(.vertical, 8)
                .background(Color.surface, in: Capsule())
        }
        .buttonStyle(.plain)
    }

    private func apply(_ ranges: [OpeningHours.Range]) {
        for d in selected { hours.days[d] = ranges }
    }

    private func update(_ i: Int, _ change: (inout OpeningHours.Range) -> Void) {
        var ranges = hours.ranges(firstSelected)
        guard ranges.indices.contains(i) else { return }
        change(&ranges[i])
        apply(ranges)
    }

    /// 24-hour wheel picker bound to minutes since midnight.
    private func timePicker(_ minutes: Int, set: @escaping (Int) -> Void) -> some View {
        let cal = Calendar(identifier: .gregorian)
        let base = cal.startOfDay(for: Date(timeIntervalSince1970: 0))
        return DatePicker("", selection: Binding(
            get: { base.addingTimeInterval(TimeInterval(minutes * 60)) },
            set: { d in
                let c = cal.dateComponents([.hour, .minute], from: d)
                set((c.hour ?? 0) * 60 + (c.minute ?? 0))
            }), displayedComponents: .hourAndMinute)
            .labelsHidden()
            .environment(\.locale, Locale(identifier: "en_GB")) // 24 h
    }
}

/// 409 from `POST /places`: a problem+json with the similar place under `existing` ("Is it this one?").
enum DuplicatePlace {
    private struct Problem: Decodable { var existing: PlaceSummary? }

    static func existing(in body: Data) -> PlaceSummary? {
        let d = JSON.makeDecoder()
        if let p = try? d.decode(Problem.self, from: body), let e = p.existing { return e }
        return (try? d.decode(Place.self, from: body))?.summary
    }
}
