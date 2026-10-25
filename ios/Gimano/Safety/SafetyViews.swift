import SwiftUI

/// Why the full-screen agreement is open.
enum SafetyAgreementPurpose: String, Identifiable {
    /// First launch (or a new agreement version), before the location prompt.
    case launch
    /// "Read and agree" from the not-agreed sheet: on agree, navigation starts.
    case startDriving
    /// Settings › Safety › Read again.
    case reread
    var id: String { rawValue }
}

/// The reminder card for one start of navigation.
struct SafetyCardRequest: Identifiable, Equatable {
    let id = UUID()
    var destination: String?
    var durationS: Double?
    var isLongDrive: Bool { SafetyPolicy.isLongDrive(durationS: durationS) }
}

// MARK: - 1. User agreement

/// Full screen, not dismissible by swipe; "Not now" is the only way out without agreeing (docs/safety.md §1).
struct SafetyAgreementView: View {
    let onAnswer: (Bool) -> Void

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Image(systemName: "checkmark.shield.fill")
                        .font(.system(size: 40))
                        .foregroundStyle(Color.brand)
                        .frame(width: 72, height: 72)
                        .background(Color.brandMist, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                        .accessibilityHidden(true)
                    Text("Before we start")
                        .font(Tokens.Font.nunito(30, .extrabold, relativeTo: .largeTitle))
                        .accessibilityAddTraits(.isHeader)
                    Text("Just a moment. This is about your safety and everyone else's on the road.")
                        .font(Tokens.Font.body)
                        .foregroundStyle(Color.textMuted)
                    VStack(alignment: .leading, spacing: 14) {
                        item(1, "steeringwheel", "**Manotu is only an aid.** Maps, routes and reports can be wrong or out of date. You drive and you decide.")
                        item(2, "signpost.right.fill", "**Obey the traffic laws.** Road signs, traffic lights and the police always come before the app's directions.")
                        item(3, "bed.double.fill", "**Drive only when alert.** Don't drive when tired or sleepy, or under the influence of alcohol, drugs or medicine that makes you drowsy.")
                        item(4, "iphone.slash", "**Hands on the wheel, not the phone.** Set your destination before you move, or ask a passenger.")
                        item(5, "person.fill.checkmark", "**Your responsibility.** To the extent permitted by law, the developer of Manotu is not responsible for accidents, injury, damage or fines.")
                    }
                    HStack(spacing: 8) {
                        Link("Full terms", destination: SafetyPolicy.termsURL).accessibilityIdentifier("safetyTermsLink")
                        Text(verbatim: "·").foregroundStyle(Color.textMuted)
                        Link("Privacy", destination: SafetyPolicy.privacyURL).accessibilityIdentifier("safetyPrivacyLink")
                    }
                    .font(Tokens.Font.bodyBold)
                }
                .padding(.horizontal, Tokens.Space.xl)
                .padding(.top, Tokens.Space.xxl)
                .padding(.bottom, Tokens.Space.l)
            }
            VStack(spacing: 10) {
                Button("I understand and agree") { onAnswer(true) }
                    .buttonStyle(PrimaryButtonStyle())
                    .accessibilityIdentifier("safetyAgree")
                // "Belum setuju" in Malay (the plain "Not now" key is "Bukan sekarang").
                Button("Not now (safety agreement)") { onAnswer(false) }
                    .buttonStyle(SecondaryButtonStyle())
                    .accessibilityIdentifier("safetyNotNow")
                Text("Stored on this phone only · Version \(SafetyPolicy.agreementVersion)")
                    .font(Tokens.Font.small)
                    .foregroundStyle(Color.textMuted)
                    .accessibilityIdentifier("safetyFooter")
            }
            .padding(.horizontal, Tokens.Space.xl)
            .padding(.top, Tokens.Space.m)
            .padding(.bottom, Tokens.Space.l)
            .background(Color.surface)
        }
        .background(Color.surface.ignoresSafeArea())
        .interactiveDismissDisabled()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("safetyAgreement")
    }

    /// The bold lead-in (`**…**` in the catalog) in Nunito ExtraBold; SwiftUI's markdown bold doesn't apply to the custom font.
    private func styled(_ key: String.LocalizationValue) -> AttributedString {
        var a = AttributedString(localized: key)
        for run in a.runs where run.inlinePresentationIntent?.contains(.stronglyEmphasized) == true {
            a[run.range].font = Tokens.Font.bodyBold
        }
        return a
    }

    private func item(_ n: Int, _ icon: String, _ text: String.LocalizationValue) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(Color.brand)
                .frame(width: 44, height: 44)
                .background(Color.brandMist, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .accessibilityHidden(true)
            Text(styled(text))
                .font(Tokens.Font.body)
                .foregroundStyle(Color.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("safetyItem\(n)")
    }
}

/// "Agree first to start driving" (Mula / Go now before agreeing).
struct SafetyNotAgreedSheet: View {
    let onAgree: () -> Void
    let onLater: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Image(systemName: "checkmark.shield.fill")
                .font(.system(size: 28))
                .foregroundStyle(Color.brand)
                .frame(width: 56, height: 56)
                .background(Color.brandMist, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                .accessibilityHidden(true)
            Text("Agree first to start driving").font(Tokens.Font.title).fixedSize(horizontal: false, vertical: true)
            Text("You can still look at the map, find places and compare routes. Turn-by-turn directions start only after you agree to the safety agreement.")
                .font(Tokens.Font.body)
                .foregroundStyle(Color.textMuted)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button("Read and agree", action: onAgree)
                .buttonStyle(PrimaryButtonStyle())
                .accessibilityIdentifier("safetyReadAndAgree")
            Button("Not now", action: onLater)
                .buttonStyle(SecondaryButtonStyle())
                .accessibilityIdentifier("safetyLater")
        }
        .padding(Tokens.Space.xl)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("safetyNotAgreed")
    }
}

// MARK: - 2. Reminder at the start of every drive

struct SafetyReminderCard: View {
    let request: SafetyCardRequest?
    let onStart: (_ dontShowAgain: Bool) -> Void
    @State private var dontShowAgain = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(systemName: "checkmark.shield.fill")
                    .font(.system(size: 24))
                    .foregroundStyle(Color.brand)
                    .frame(width: 48, height: 48)
                    .background(Color.brandMist, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Drive safely").font(Tokens.Font.title).accessibilityAddTraits(.isHeader)
                    if let r = request, let dest = r.destination {
                        Group {
                            if let s = r.durationS {
                                Text("To \(dest) · \(ETAFormatter.duration(s))")
                            } else {
                                Text("To \(dest)")
                            }
                        }
                        .font(Tokens.Font.caption)
                        .foregroundStyle(Color.textMuted)
                        .lineLimit(1)
                        .accessibilityIdentifier("safetyCardSubtitle")
                    }
                }
            }
            VStack(alignment: .leading, spacing: 10) {
                line("signpost.right.fill", "Obey the law, road signs and the police.")
                line("nosign", "Never drive drunk, high or on drowsy medicine.")
                line("iphone.slash", "Hands on the wheel. Don't hold the phone.")
                line("arrow.triangle.turn.up.right.diamond.fill", "Direction looks wrong? Follow the road.")
                if request?.isLongDrive == true {
                    line("cup.and.saucer.fill", "Long drive: rest every 2 hours. Tired or sleepy? Stop.")
                        .padding(10)
                        .background(Color.amberMist, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .foregroundStyle(Color.amberInk)
                        .accessibilityIdentifier("safetyLongDrive")
                } else {
                    line("cup.and.saucer.fill", "Tired or sleepy? Stop and rest.")
                }
            }
            Button {
                dontShowAgain.toggle()
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: dontShowAgain ? "checkmark.square.fill" : "square")
                        .font(.system(size: 24))
                        .foregroundStyle(dontShowAgain ? Color.brand : Color.textMuted)
                    Text("Don't show again").font(Tokens.Font.body).foregroundStyle(Color.textPrimary)
                    Spacer()
                }
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(dontShowAgain ? .isSelected : [])
            .accessibilityIdentifier("safetyDontShowAgain")
            Button { onStart(dontShowAgain) } label: {
                Text("Got it, start driving").frame(maxWidth: .infinity, minHeight: 64)
            }
            .buttonStyle(PrimaryButtonStyle())
            .accessibilityIdentifier("safetyStart")
        }
        .padding(Tokens.Space.gutter)
        .background(Color.surface, in: RoundedRectangle(cornerRadius: Tokens.Radius.lg, style: .continuous))
        .fabShadow()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("safetyCard")
    }

    private func line(_ icon: String, _ text: LocalizedStringKey) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 17, weight: .semibold))
                .frame(width: 24)
                .foregroundStyle(Color.brand)
                .accessibilityHidden(true)
            Text(text).font(Tokens.Font.body).fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// One line, 5 s, nothing to tap: navigation started while already moving.
struct SafetyMovingBanner: View {
    var body: some View {
        Label("Drive safely. Obey the traffic laws.", systemImage: "checkmark.shield.fill")
            .font(Tokens.Font.label)
            .foregroundStyle(Color.brandOn)
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .padding(.horizontal, 14)
            .frame(maxWidth: .infinity, minHeight: 40, alignment: .leading)
            .background(Color.brand, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .allowsHitTesting(false)
            .accessibilityIdentifier("safetyBanner")
    }
}

// MARK: - 3. Settings › Safety

struct SafetySettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var showPreview = false
    @State private var rereading = false

    var body: some View {
        Form {
            Section {
                Toggle(isOn: Binding(get: { model.safety.reminderEnabled }, set: { model.setReminderEnabled($0) })) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Safety advice every time you start driving").font(Tokens.Font.body)
                        if !model.safety.reminderEnabled, let at = model.safety.reminderDisabledAt {
                            Text("Turned off on \(at.formatted(date: .abbreviated, time: .omitted))")
                                .font(Tokens.Font.caption).foregroundStyle(Color.textMuted)
                                .accessibilityIdentifier("safetyReminderOffDate")
                        }
                    }
                }
                .accessibilityIdentifier("safetyReminderToggle")
                Button { showPreview = true } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Show it now").font(Tokens.Font.body).foregroundStyle(Color.textPrimary)
                        Text("See the advice card without starting a drive").font(Tokens.Font.caption).foregroundStyle(Color.textMuted)
                    }
                }
                .accessibilityIdentifier("safetyShowNow")
            }
            Section {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("User agreement").font(Tokens.Font.body)
                        if model.safety.hasAgreed, let at = model.safety.agreedAt {
                            Text("Agreed on \(at.formatted(date: .abbreviated, time: .omitted)) · Version \(model.safety.agreedVersion)")
                                .font(Tokens.Font.caption).foregroundStyle(Color.textMuted)
                                .accessibilityIdentifier("safetyAgreedOn")
                        } else {
                            Text("Not agreed yet · Version \(SafetyPolicy.agreementVersion)").font(Tokens.Font.caption).foregroundStyle(Color.textMuted)
                                .accessibilityIdentifier("safetyAgreedOn")
                        }
                    }
                    Spacer()
                    Button("Read again") { rereading = true }
                        .buttonStyle(.borderless)
                        .font(Tokens.Font.label)
                        .accessibilityIdentifier("safetyReadAgain")
                }
                Link("Full terms at manotu.app", destination: SafetyPolicy.termsURL)
                    .accessibilityIdentifier("safetySettingsTerms")
            } footer: {
                Text("These settings and the date you agreed are stored only on your phone and go into your own backup. Manotu never receives them.")
            }
        }
        .navigationTitle("Safety")
        .sheet(isPresented: $showPreview) {
            ScrollView {
                SafetyReminderCard(request: nil) { dontShow in
                    showPreview = false
                    if dontShow {
                        model.setReminderEnabled(false)
                        model.showToast(String(localized: "Turned off. Turn it back on in Settings › Safety."), seconds: 4)
                    }
                }
                .padding(Tokens.Space.gutter)
            }
            .presentationDetents([.large])
            .presentationBackground(Color.appBackground)
        }
        .fullScreenCover(isPresented: $rereading) {
            SafetyAgreementView { agreed in
                rereading = false
                // Reading again never withdraws the agreement; agreeing again refreshes the date.
                if agreed { model.answerSafetyAgreement(true) }
            }
        }
    }
}
