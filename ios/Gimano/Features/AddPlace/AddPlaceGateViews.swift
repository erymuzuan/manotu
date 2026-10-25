import SwiftUI

// Screens of "Add a place with an AI gate" (boards A1–C3), in the app's Cobalt components.

/// Round status glyph at the top of a result screen.
private struct ResultGlyph: View {
    let system: String
    let fill: Color
    var ink: Color = .white

    var body: some View {
        Image(systemName: system)
            .font(.system(size: 26, weight: .bold))
            .foregroundStyle(ink)
            .frame(width: 56, height: 56)
            .background(fill, in: Circle())
            .accessibilityHidden(true)
    }
}

/// Name + one line under it, in a pale card (the place as others would see it).
private struct PlaceLine: View {
    let name: String
    let category: PlaceCategory
    let detail: String?

    var body: some View {
        HStack(spacing: 12) {
            CategoryIcon(category: category)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: name).font(Tokens.Font.bodyBold).foregroundStyle(Color.textPrimary).lineLimit(2)
                if let detail, !detail.isEmpty {
                    Text(verbatim: detail).font(Tokens.Font.caption).foregroundStyle(Color.textMuted).lineLimit(2)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(Color.surfaceAlt, in: RoundedRectangle(cornerRadius: Tokens.Radius.md, style: .continuous))
    }
}

private struct NoteBox: View {
    let text: String
    var icon = "lightbulb.fill"
    var tint: Color = .brandMist
    var ink: Color = .brandInk

    var body: some View {
        Label {
            Text(verbatim: text).fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: icon)
        }
        .font(Tokens.Font.caption)
        .foregroundStyle(ink)
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

private struct Footnote: View {
    let text: LocalizedStringKey
    var body: some View {
        Text(text).font(Tokens.Font.small).foregroundStyle(Color.textMuted).fixedSize(horizontal: false, vertical: true)
    }
}

private struct TextButton: View {
    let title: LocalizedStringKey
    let id: String
    let action: () -> Void
    var body: some View {
        Button(title, action: action)
            .font(Tokens.Font.bodyBold)
            .frame(maxWidth: .infinity, minHeight: 44)
            .accessibilityIdentifier(id)
    }
}

extension PlaceCategory {
    /// Plain category word for one-line summaries.
    @MainActor var plainTitle: String { String(localized: AddPlaceCategories.title(self)) }
}

// MARK: - A1 First time

struct AddPlaceIntroSheet: View {
    let onDone: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("Your first shared place").textCase(.uppercase)
                    .font(Tokens.Font.nunito(12, .black)).tracking(0.8).foregroundStyle(Color.brand)
                Text("How adding a place works").font(Tokens.Font.title).accessibilityAddTraits(.isHeader)
                step("globe.asia.australia.fill", .brandMist, .brandInk, "Everyone can see it",
                     "Shared places appear on the map for all drivers, under your pseudonym.")
                step("checkmark.shield.fill", .coralMist, Color(light: 0xB8573A, dark: 0xFFB59E), "A quick automatic check",
                     "Takes about 2 seconds. It looks only at what you write, never at who you are.")
                step("person.2.fill", .tealMist, .tealInk, "People nearby confirm it",
                     "Until then it shows \"Not verified yet\". Accurate places raise your level.")
                Text("Shops, stalls, surau, workshops, parking and places to stop. No homes, adverts or job offers. Want it only for yourself? Choose \"Just for me\": it never leaves your phone.")
                    .font(Tokens.Font.caption).foregroundStyle(Color.textMuted).fixedSize(horizontal: false, vertical: true)
                Button("Got it", action: onDone)
                    .buttonStyle(PrimaryButtonStyle())
                    .accessibilityIdentifier("addPlaceIntroDone")
            }
            .padding(Tokens.Space.xl)
        }
        .interactiveDismissDisabled()
        .accessibilityIdentifier("addPlaceIntro")
    }

    private func step(_ icon: String, _ bg: Color, _ ink: Color, _ title: LocalizedStringKey, _ body: LocalizedStringKey) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: icon).font(.system(size: 20, weight: .bold)).foregroundStyle(ink)
                .frame(width: 44, height: 44).background(bg, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(Tokens.Font.bodyBold)
                Text(body).font(Tokens.Font.caption).foregroundStyle(Color.textMuted).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

// MARK: - A3 Checking

struct AddPlaceCheckingView: View {
    let name: String
    @State private var dots = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(verbatim: name).font(Tokens.Font.title)
            Text("Checking before it goes on the map…").font(Tokens.Font.bodyBold).foregroundStyle(Color.textMuted)
            VStack(spacing: 8) {
                row(.done, "Location is fine", "Inside Malaysia, not in a restricted area")
                row(.done, "Not on the map yet", "No similar place within 100 m")
                row(.active, "Content check", "Is this a real place drivers can visit?")
                row(.waiting, "Goes live", "Then people nearby confirm it")
            }
            HStack(spacing: 10) {
                ProgressView().tint(Color.brandOn)
                Text("Checking").font(Tokens.Font.button)
            }
            .foregroundStyle(Color.brandOn)
            .frame(maxWidth: .infinity, minHeight: 56)
            .background(Color.brand.opacity(0.75), in: RoundedRectangle(cornerRadius: Tokens.Radius.md, style: .continuous))
            .accessibilityElement(children: .combine)
            Footnote(text: "Usually about 2 seconds. You can close this: the result also arrives in your Inbox.")
            Spacer(minLength: 0)
        }
        .padding(Tokens.Space.gutter)
        .accessibilityIdentifier("addPlaceChecking")
    }

    private enum Phase { case done, active, waiting }

    private func row(_ phase: Phase, _ title: LocalizedStringKey, _ sub: LocalizedStringKey) -> some View {
        HStack(spacing: 12) {
            Group {
                switch phase {
                case .done: Image(systemName: "checkmark").foregroundStyle(.white)
                case .active: ProgressView().controlSize(.mini).tint(.white)
                case .waiting: Image(systemName: "ellipsis").foregroundStyle(.white)
                }
            }
            .font(.system(size: 13, weight: .black))
            .frame(width: 28, height: 28)
            .background(phase == .done ? Color(light: 0x0E8A5F, dark: 0x3FC79A) : phase == .active ? Color.brand : Color.outline, in: Circle())
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(Tokens.Font.bodyBold)
                Text(sub).font(Tokens.Font.small).foregroundStyle(Color.textMuted)
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(phase == .active ? Color.brandMist : Color.surfaceAlt, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

// MARK: - A4 · A5 · B2 · B3 · B4 · B6 results

struct AddPlaceResultActions {
    var done: () -> Void
    var edit: () -> Void
    var appeal: () -> Void
    var discard: () -> Void
    var keepPrivate: () -> Void
}

struct AddPlaceResultView: View {
    let place: Place
    let outcome: AddPlaceOutcome
    let actions: AddPlaceResultActions
    /// New contributors see B2 more often (footnote).
    var isNewContributor = false

    private var detail: String {
        [place.category.plainTitle, place.address].filter { !$0.isEmpty }.joined(separator: " · ")
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                content
            }
            .padding(Tokens.Space.gutter)
        }
        .accessibilityIdentifier("addPlaceResult")
    }

    @ViewBuilder private var content: some View {
        switch outcome {
        case .live, .unscreened(held: false): live
        case .published: published
        case .held(let r): held(r)
        case .unscreened(held: true): held(.unclear)
        case .notAccepted(let r): notAccepted(r)
        case .aboutPeople(let r): aboutPeople(r)
        case .checking: checking
        }
    }

    private var confirmationText: Text? {
        guard let req = place.required.map({ Int($0.rounded(.up)) }), req > 0 else { return nil }
        let c = Int((place.confirmationsWeighted ?? 0).rounded(.down))
        return Text("Not verified yet · \(c) of \(req)")
    }

    // A4
    @ViewBuilder private var live: some View {
        ResultGlyph(system: "checkmark", fill: Color(light: 0x0E8A5F, dark: 0x2FA77C))
        Text("It's on the map").font(Tokens.Font.title).accessibilityIdentifier("resultLive")
        PlaceLine(name: place.name, category: place.category, detail: detail)
        (confirmationText ?? Text("Not verified yet"))
            .font(Tokens.Font.nunito(12, .black)).foregroundStyle(Color.amberInk)
            .padding(.horizontal, 10).padding(.vertical, 4)
            .background(Color.amberMist, in: Capsule())
        Text("Drivers can find it in search now. The next person who stops nearby will be asked \"Is this place here?\". When they say yes, it becomes Community verified and you get +20 points.")
            .font(Tokens.Font.body).fixedSize(horizontal: false, vertical: true)
        ShareLink(item: shareText) { Label("Share place", systemImage: "square.and.arrow.up") }
            .buttonStyle(SecondaryButtonStyle())
            .accessibilityIdentifier("resultShare")
        Button("Done", action: actions.done).buttonStyle(PrimaryButtonStyle()).accessibilityIdentifier("resultDone")
        Footnote(text: "You can edit it while it's not verified yet. An edit is checked again.")
    }

    // A5
    @ViewBuilder private var published: some View {
        ResultGlyph(system: "star.fill", fill: Color(light: 0xE0A800, dark: 0xC99A1E))
        Text("Live and verified").font(Tokens.Font.title).accessibilityIdentifier("resultPublished")
        PlaceLine(name: place.name, category: place.category, detail: [detail, place.phone ?? ""].filter { !$0.isEmpty }.joined(separator: " · "))
        TierBadge(tier: .emas)
        Text("Added by an Emas contributor").font(Tokens.Font.bodyBold)
        Text("Your Emas level means it skips the wait. It still passed the same automatic check. Now and then we ask a driver nearby to confirm an Emas place, to keep everyone's level fair.")
            .font(Tokens.Font.body).fixedSize(horizontal: false, vertical: true)
        Button("Done", action: actions.done).buttonStyle(PrimaryButtonStyle()).accessibilityIdentifier("resultDone")
        Footnote(text: "If the automatic check is unsure about an Emas place, a person decides. It is never refused automatically.")
    }

    // B2
    @ViewBuilder private func held(_ r: ScreeningReason) -> some View {
        ResultGlyph(system: "clock", fill: Color.brand)
        Text("A person will check this one").font(Tokens.Font.title).accessibilityIdentifier("resultHeld")
        PlaceLine(name: place.name, category: place.category, detail: String(localized: "Being checked · usually within 24 h"))
        NoteBox(text: String(localized: "Why: \(String(localized: ScreeningCopy.heldWhy(r)))"), icon: "info.circle.fill")
        Text("Until then only you can see it. You'll get the answer in your Inbox.")
            .font(Tokens.Font.body).fixedSize(horizontal: false, vertical: true)
        if r == .security {
            Button("Edit description", action: actions.edit).buttonStyle(SecondaryButtonStyle()).accessibilityIdentifier("resultEdit")
        }
        Button("OK", action: actions.done).buttonStyle(PrimaryButtonStyle()).accessibilityIdentifier("resultDone")
        if isNewContributor {
            Footnote(text: "New contributors see this more often: until you have 3 accepted places, anything the check isn't sure about goes to a person.")
        }
    }

    // B3
    @ViewBuilder private func notAccepted(_ r: ScreeningReason) -> some View {
        ResultGlyph(system: "nosign", fill: Color(light: 0xFFE2E2, dark: 0x4A1418), ink: Color(light: 0xC1121F, dark: 0xFF8A8F))
        Text(String(localized: ScreeningCopy.notAcceptedTitle(r))).font(Tokens.Font.title).accessibilityIdentifier("resultNotAccepted")
        PlaceLine(name: place.name, category: place.category, detail: place.description.map { "\"\($0)\"" })
        Text(String(localized: ScreeningCopy.notAcceptedBody(r))).font(Tokens.Font.body).fixedSize(horizontal: false, vertical: true)
        NoteBox(text: String(localized: ScreeningCopy.notAcceptedTip(r)))
        Button("Edit and try again", action: actions.edit).buttonStyle(PrimaryButtonStyle()).accessibilityIdentifier("resultEdit")
        if place.screening?.canAppeal == true {
            Button("I think this is wrong: ask for a review", action: actions.appeal)
                .buttonStyle(SecondaryButtonStyle()).accessibilityIdentifier("resultAppeal")
        }
        TextButton(title: "Discard", id: "resultDiscard", action: actions.discard)
        Footnote(text: "The same reasons, in plain words, for scams, illegal goods and adult services. We never show the automatic check's own wording.")
    }

    // B4
    @ViewBuilder private func aboutPeople(_ r: ScreeningReason) -> some View {
        ResultGlyph(system: "house.fill", fill: Color.brandMist, ink: Color.brand)
        Text(String(localized: ScreeningCopy.notAcceptedTitle(r))).font(Tokens.Font.title).accessibilityIdentifier("resultAboutPeople")
        PlaceLine(name: place.name, category: place.category, detail: detail)
        Text(String(localized: ScreeningCopy.notAcceptedBody(r))).font(Tokens.Font.body).fixedSize(horizontal: false, vertical: true)
        Button("Keep it just for me", action: actions.keepPrivate).buttonStyle(PrimaryButtonStyle()).accessibilityIdentifier("resultKeepPrivate")
        if place.screening?.canAppeal == true {
            Button("It's a business: ask for a review", action: actions.appeal)
                .buttonStyle(SecondaryButtonStyle()).accessibilityIdentifier("resultAppeal")
        }
        TextButton(title: "Discard", id: "resultDiscard", action: actions.discard)
        Text(String(localized: ScreeningCopy.notAcceptedTip(r))).font(Tokens.Font.small).foregroundStyle(Color.textMuted)
            .fixedSize(horizontal: false, vertical: true)
    }

    // B6 (slow)
    @ViewBuilder private var checking: some View {
        Text("Check took longer than 4 s").textCase(.uppercase)
            .font(Tokens.Font.nunito(12, .black)).tracking(0.8).foregroundStyle(Color.textMuted)
        ResultGlyph(system: "paperplane.fill", fill: Color.brand)
        Text("Sent. We're still checking").font(Tokens.Font.title).accessibilityIdentifier("resultChecking")
        Text("\(place.name) is safely with us. It will go on the map as soon as the check finishes, usually within a few minutes. You'll get a message in your Inbox.")
            .font(Tokens.Font.body).fixedSize(horizontal: false, vertical: true)
        Button("OK", action: actions.done).buttonStyle(PrimaryButtonStyle()).accessibilityIdentifier("resultDone")
        Footnote(text: "If the check service is down for more than an hour, a person reviews the place instead. Nothing is lost.")
    }

    private var shareText: String {
        "\(place.name)\n\(place.address)\nhttps://www.openstreetmap.org/?mlat=\(place.lat)&mlon=\(place.lng)#map=17/\(place.lat)/\(place.lng)"
    }
}

// MARK: - B6 offline

struct AddPlaceOfflineView: View {
    let onDone: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("No connection").textCase(.uppercase)
                .font(Tokens.Font.nunito(12, .black)).tracking(0.8).foregroundStyle(Color.textMuted)
            ResultGlyph(system: "wifi.slash", fill: Color.surfaceAlt, ink: Color.textMuted)
            Text("Saved on this phone").font(Tokens.Font.title).accessibilityIdentifier("resultOffline")
            Text("It will be sent and checked when you're back online. It stays on your map meanwhile, shown only to you.")
                .font(Tokens.Font.body).fixedSize(horizontal: false, vertical: true)
            Button("OK", action: onDone).buttonStyle(PrimaryButtonStyle()).accessibilityIdentifier("resultDone")
            Footnote(text: "Photos aren't kept with a saved place: add them on the place card once it's shared.")
            Spacer(minLength: 0)
        }
        .padding(Tokens.Space.gutter)
    }
}

// MARK: - B5 limit / paused

struct AddPlaceLimitView: View {
    let failure: AddPlaceFailure
    let onSaveDraft: () -> Void
    let onKeepPrivate: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                ResultGlyph(system: "hourglass", fill: Color.amberMist, ink: Color.amberInk)
                title.font(Tokens.Font.title).accessibilityIdentifier("resultLimit")
                bodyText.font(Tokens.Font.body).fixedSize(horizontal: false, vertical: true)
                NoteBox(text: String(localized: "Your place is saved as a draft on this phone. Share it from My contributions when adding opens again."),
                        icon: "tray.and.arrow.down.fill", tint: .amberMist, ink: .amberInk)
                Button("Save draft", action: onSaveDraft).buttonStyle(PrimaryButtonStyle()).accessibilityIdentifier("resultSaveDraft")
                Button("Keep it just for me instead", action: onKeepPrivate)
                    .buttonStyle(SecondaryButtonStyle()).accessibilityIdentifier("resultKeepPrivate")
            }
            .padding(Tokens.Space.gutter)
        }
    }

    private var title: Text {
        switch failure {
        case .limit(let m?) where m == 1: Text("You can add more in 1 minute")
        case .limit(let m?): Text("You can add more in \(m) minutes")
        case .paused(let until?):
            Text("Adding is paused until \(until.formatted(.dateTime.weekday(.wide).hour().minute()))")
        case .paused(nil): Text("Adding is paused for now")
        default: Text("You can add more later")
        }
    }

    private var bodyText: Text {
        if case .paused = failure {
            return Text("Three of your places were not accepted in the last 24 hours. It lifts by itself.")
        }
        return Text("New contributors can share a few places an hour and a day. The limit grows as your places get confirmed.")
    }
}

// MARK: - B1 duplicate

struct DuplicatePlaceSheet: View {
    let existing: PlaceSummary
    let typedName: String
    let distanceM: Double?
    let onSuggestEdit: () -> Void
    let onDifferent: () -> Void

    private var detail: String {
        var parts = [existing.category.plainTitle]
        if let d = distanceM { parts.append(String(localized: "\(Int(d.rounded())) m away")) }
        switch existing.status {
        case .published: parts.append(String(localized: "Community verified"))
        case .pending: parts.append(String(localized: "Not verified yet"))
        default: break
        }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                ResultGlyph(system: "mappin.and.ellipse", fill: Color.amberMist, ink: Color.amberInk)
                Text("Is it already on the map?").font(Tokens.Font.title).accessibilityIdentifier("duplicateSheet")
                if let d = distanceM {
                    Text("We found a similar place \(Int(d.rounded())) m from your pin. You wrote \"\(typedName)\".")
                        .font(Tokens.Font.body).fixedSize(horizontal: false, vertical: true)
                } else {
                    Text("We found a similar place near your pin. You wrote \"\(typedName)\".")
                        .font(Tokens.Font.body).fixedSize(horizontal: false, vertical: true)
                }
                PlaceLine(name: existing.name, category: existing.category, detail: detail)
                Button("Yes, that's it: suggest an edit", action: onSuggestEdit)
                    .buttonStyle(PrimaryButtonStyle()).accessibilityIdentifier("duplicateSuggestEdit")
                Button("No, mine is a different place", action: onDifferent)
                    .buttonStyle(SecondaryButtonStyle()).accessibilityIdentifier("duplicateDifferent")
                Footnote(text: "\"Different place\" sends it on with that answer. If the check still thinks it's the same, a person decides. Nothing is lost either way.")
            }
            .padding(Tokens.Space.xl)
        }
    }
}

// MARK: - C1 Ask for a review

struct AppealSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let placeId: String
    let name: String
    let reason: ScreeningReason
    let onSent: (Place?) -> Void
    @State private var note = ""
    @State private var sending = false
    @State private var error: String?

    private var trimmed: String { note.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(verbatim: name).font(Tokens.Font.bodyBold)
                        Text("Not accepted: \(String(localized: ScreeningCopy.notAcceptedTitle(reason)))")
                            .font(Tokens.Font.caption).foregroundStyle(Color.textMuted)
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.surfaceAlt, in: RoundedRectangle(cornerRadius: Tokens.Radius.md, style: .continuous))
                    Text("What should the reviewer know?").font(Tokens.Font.label).foregroundStyle(Color.textMuted)
                    TextField(String(localized: "e.g. she sells kuih from her house every morning, with a signboard outside"),
                              text: $note, axis: .vertical)
                        .lineLimit(4...6)
                        .padding(14)
                        .background(Color.surfaceAlt, in: RoundedRectangle(cornerRadius: Tokens.Radius.md, style: .continuous))
                        .onChange(of: note) { _, v in if v.count > AppealPlaceRequest.maxNote { note = String(v.prefix(AppealPlaceRequest.maxNote)) } }
                        .accessibilityIdentifier("appealNote")
                    Text(verbatim: "\(note.count) / \(AppealPlaceRequest.maxNote)")
                        .font(Tokens.Font.small).foregroundStyle(Color.textMuted)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                    Text("A Manotu maintainer, a person, answers within 24 hours. One review per place. Don't include phone numbers or names of people here.")
                        .font(Tokens.Font.caption).foregroundStyle(Color.textMuted).fixedSize(horizontal: false, vertical: true)
                    if reason.isAboutPeople {
                        NoteBox(text: String(localized: "Tip: naming the business instead of the person, and adding opening hours, often passes the check straight away."))
                    }
                    if let error { Text(error).font(Tokens.Font.caption).foregroundStyle(Color.speeding).accessibilityIdentifier("appealError") }
                    Button {
                        Task { await send() }
                    } label: {
                        if sending { ProgressView().tint(Color.brandOn) } else { Text("Send for review") }
                    }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(sending)
                    .accessibilityIdentifier("appealSend")
                }
                .padding(Tokens.Space.gutter)
            }
            .navigationTitle("Ask for a review")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarLeading) { Button("Cancel") { dismiss() } } }
        }
    }

    private func send() async {
        sending = true
        defer { sending = false }
        do {
            let p = try await model.repo.appealPlace(id: placeId, note: trimmed.isEmpty ? nil : String(trimmed.prefix(AppealPlaceRequest.maxNote)))
            model.showToast(String(localized: "Sent for review. A person answers within 24 hours."), seconds: 4)
            dismiss()
            onSent(p)
        } catch APIError.conflict {
            error = String(localized: "A review was already asked for this place.")
        } catch let e as APIError where e.isServerSideGap {
            error = String(localized: "Reviews of not-accepted places aren't available on the server yet.")
        } catch {
            self.error = error.localizedDescription
        }
    }
}

// MARK: - C3 status badge

struct MyPlaceStatusBadge: View {
    let status: MyPlaceStatus

    var body: some View {
        VStack(alignment: .trailing, spacing: 2) {
            label
                .font(Tokens.Font.small).foregroundStyle(ink)
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(tint, in: Capsule())
            if let next { next.font(Tokens.Font.small).foregroundStyle(Color.textMuted) }
        }
        .multilineTextAlignment(.trailing)
        .accessibilityElement(children: .combine)
    }

    private var label: Text {
        switch status {
        case .communityVerified: Text("Community verified")
        case .live: Text("Live · not verified yet")
        case .waiting: Text("Waiting for verification")
        case .beingChecked: Text("Being checked")
        case .beingCheckedByPerson: Text("Being checked by a person")
        case .notAccepted: Text("Not accepted")
        case .hidden: Text("Hidden: reported \"not here\"")
        case .closed: Text("Closed")
        case .expired: Text("Expired")
        case .draft: Text("Draft on this phone")
        case .queued: Text("Queued")
        case .justForMe: Text("On this phone only")
        }
    }

    private var next: Text? {
        switch status {
        case .live(let c, let r?), .waiting(let c, let r?): Text("\(c) of \(r)")
        case .beingChecked: Text("A few minutes")
        case .beingCheckedByPerson: Text("< 24 h")
        case .notAccepted(let canAppeal, let appealed):
            canAppeal ? Text("Ask for a review") : appealed ? Text("Review closed") : nil
        case .hidden: Text("Moderator")
        case .draft(let after?) where after > .now:
            Text("Share in \(max(1, Int((after.timeIntervalSinceNow / 60).rounded(.up)))) min")
        case .draft: Text("Share now")
        case .queued: Text("When online")
        case .justForMe: Text("Private")
        default: nil
        }
    }

    private var tint: Color {
        switch status {
        case .communityVerified: .tealMist
        case .live, .waiting: .amberMist
        case .beingChecked, .beingCheckedByPerson: .brandMist
        case .notAccepted, .hidden: Color(light: 0xFFE2E2, dark: 0x4A1418)
        default: Color(light: 0xF2F4F7, dark: 0x262D3A)
        }
    }

    private var ink: Color {
        switch status {
        case .communityVerified: .tealInk
        case .live, .waiting: .amberInk
        case .beingChecked, .beingCheckedByPerson: .brandInk
        case .notAccepted, .hidden: Color(light: 0x5C0A10, dark: 0xFFB3B8)
        default: Color(light: 0x3A4A66, dark: 0xC9D3E3)
        }
    }
}
