import SwiftUI

/// Sound button (boards NavBunyi / NavBunyiKeadaan). Tap opens the "Sound" panel anchored to it (Full sound · Alerts only
/// · Mute, the current one checked, and the voice volume); picking a mode or tapping outside closes it. Long-press mutes
/// at once, or goes back to the mode before. Each mode has its own icon (Mute: crossed speaker on an orange ring); a change
/// shows a 2 s toast and is announced by VoiceOver. The choice is remembered across drives (on the device).
struct SoundFab: View {
    @Environment(AppModel.self) private var model
    @State private var showPanel = false

    var body: some View {
        let mode = model.soundMode
        FlatIconView(icon: mode.flatIcon, size: Tokens.Size.fabIcon)
            .frame(width: Tokens.Size.fab, height: Tokens.Size.fab)
            .background(mode == .off ? Color.muteMist : Color.surface, in: Circle())
            .overlay(Circle().strokeBorder(mode == .off ? Color.muteInk : .clear, lineWidth: 3))
            .fabShadow()
            .contentShape(Circle())
            .onTapGesture { showPanel = true }
            .onLongPressGesture(minimumDuration: 0.5) {
                let r = SoundMode.quickMute(current: model.soundMode, last: model.lastSoundMode)
                model.lastSoundMode = r.last
                apply(r.mode)
            }
            .accessibilityElement()
            .accessibilityAddTraits(.isButton)
            .accessibilityLabel(Text("Sound"))
            .accessibilityValue(Text(mode.rowTitle))
            .accessibilityHint(Text("Opens the sound choices. Touch and hold to mute."))
            .accessibilityAction { showPanel = true }
            .accessibilityIdentifier("soundButton")
            .popover(isPresented: $showPanel, attachmentAnchor: .rect(.bounds), arrowEdge: .top) {
                SoundPanel(selected: mode, volume: Binding(get: { model.voiceVolume }, set: { model.voiceVolume = $0 })) { m in
                    let r = SoundMode.pick(m, current: model.soundMode, last: model.lastSoundMode)
                    model.lastSoundMode = r.last
                    showPanel = false
                    apply(r.mode)
                }
                .presentationCompactAdaptation(.popover)
            }
    }

    private func apply(_ m: SoundMode) {
        let changed = m != model.soundMode
        model.soundMode = m
        guard changed else { return }
        let message = String(localized: m.changedMessage)
        model.showToast(message, seconds: 2)
        AccessibilityNotification.Announcement(message).post()
    }
}

/// "SOUND" panel: three radio rows and the app's voice volume.
struct SoundPanel: View {
    let selected: SoundMode
    @Binding var volume: Double
    let onSelect: (SoundMode) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Sound")
                .textCase(.uppercase)
                .font(Tokens.Font.nunito(12, .black, relativeTo: .caption))
                .tracking(0.6)
                .foregroundStyle(Color.sectionLabel)
                .padding(.horizontal, 6)
                .accessibilityAddTraits(.isHeader)
            ForEach(SoundMode.allCases, id: \.self) { m in
                Button { onSelect(m) } label: { row(m) }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(m == selected ? .isSelected : [])
                    .accessibilityIdentifier("soundMode.\(m.storageValue)")
            }
            HStack(spacing: 10) {
                Text("Volume").font(Tokens.Font.nunito(13, .black, relativeTo: .footnote)).foregroundStyle(Color.textPrimary)
                Slider(value: $volume, in: 0...1, step: 0.05)
                    .tint(Color.brand)
                    .accessibilityLabel(Text("Voice volume"))
                    .accessibilityIdentifier("voiceVolume")
                Text(verbatim: "\(Int((volume * 100).rounded())) %")
                    .font(Tokens.Font.nunito(13, .black, relativeTo: .footnote)).foregroundStyle(Color.textPrimary)
                    .frame(minWidth: 44, alignment: .trailing)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 6)
            .padding(.top, 4)
        }
        .padding(14)
        .frame(width: 320)
        .background(Color.surface)
        // A popover gets its own Dynamic Type: capped like the map controls so the three rows and the slider always fit.
        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
    }

    private func row(_ m: SoundMode) -> some View {
        let on = m == selected
        return HStack(spacing: 12) {
            FlatIconView(icon: m.flatIcon, size: 26)
                .frame(width: 44, height: 44)
                .background(on ? Color.surface : Color.surfaceAlt, in: Circle())
            VStack(alignment: .leading, spacing: 1) {
                Text(m.rowTitle).font(Tokens.Font.nunito(17, .black, relativeTo: .headline)).foregroundStyle(Color.textPrimary)
                Text(m.rowSubtitle).font(Tokens.Font.nunito(13, .bold, relativeTo: .footnote)).foregroundStyle(Color.tileLabel)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            ZStack {
                Circle().strokeBorder(on ? Color.brand : Color.outline, lineWidth: 2)
                if on { Circle().fill(Color.brand).padding(5) }
            }
            .frame(width: 22, height: 22)
            .accessibilityHidden(true)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 10)
        .background(on ? Color.brandMist : Color.clear, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(on ? Color.brand : .clear, lineWidth: 2))
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

extension SoundMode {
    /// A row picked in the panel. Picking Mute remembers the mode before it, so a long-press can go back to it.
    static func pick(_ m: SoundMode, current: SoundMode, last: SoundMode) -> (mode: SoundMode, last: SoundMode) {
        (m, m == .off && current != .off ? current : last)
    }
}
