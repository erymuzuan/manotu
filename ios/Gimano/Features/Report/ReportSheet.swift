import SwiftUI

/// Report sheet (docs/driving.md §6.4): the drawer, "What do you see?", a 3×3 grid of tiles; then the detail sheet both
/// doors end on (tap drawer, hold arc). `initialType` opens it straight on that type's detail (the hold arc).
struct ReportSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var type: ReportType?
    private let initialType: ReportType?

    init(initialType: ReportType? = nil) {
        self.initialType = initialType
        _type = State(initialValue: initialType)
    }

    private let columns = Array(repeating: GridItem(.flexible(), spacing: Tokens.Space.gridGap), count: 3)

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                if type != nil {
                    Button { back() } label: {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 20, weight: .bold))
                            .foregroundStyle(Color.brandInk)
                            .frame(width: 48, height: 48)
                            .background(Color.brandMist, in: Circle())
                    }
                    .accessibilityLabel(Text("Back"))
                }
                Spacer()
                Button { dismiss() } label: {
                    GimanoIcon(icon: .close, size: 22)
                        .frame(width: 48, height: 48)
                        .background(Color.brandMist, in: Circle())
                }
                .accessibilityLabel(Text("Close"))
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)
            .padding(.bottom, 8)

            ScrollView {
                if let type {
                    ReportDetail(type: type, onCancel: { back() })
                        .id(type)
                } else {
                    LazyVGrid(columns: columns, spacing: Tokens.Space.gridGap + 4) {
                        ForEach(ReportType.allCases) { t in
                            Button { withAnimation(.snappy) { type = t } } label: {
                                ReportTile(icon: t.gIcon, title: t.shortTitle, type: t)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(Text(t.title))
                            .accessibilityIdentifier("reportType.\(t.rawValue)")
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.bottom, 24)
                }
            }
        }
        .background(Color.surface)
    }

    /// Back goes to the drawer; from a detail opened by the arc it closes the sheet.
    private func back() {
        if initialType != nil { dismiss() } else { withAnimation(.snappy) { type = nil } }
    }
}

/// The sheet both doors end on (board RpDetail): the default subtype is picked, and Report sends itself after
/// `ReportDefaults.autoSendS` (the button fills as it runs). Touching an option or the comment stops the timer;
/// Cancel closes without sending. Map issue never sends by timer: its road problems are behind it.
private struct ReportDetail: View {
    @Environment(AppModel.self) private var model
    let type: ReportType
    let onCancel: () -> Void
    @State private var picked: String?
    @State private var comment = ""
    @FocusState private var noteFocused: Bool
    @State private var timerOn = false
    @State private var fill: CGFloat = 0
    @State private var secondsLeft = Int(ReportDefaults.autoSendS)

    private let columns = Array(repeating: GridItem(.flexible(), spacing: Tokens.Space.gridGap), count: 3)

    var body: some View {
        VStack(spacing: 18) {
            if type == .mapIssue {
                RoadProblemPanel()
            } else {
                content
            }
        }
        .padding(.horizontal, type == .mapIssue ? 0 : 20)
        .padding(.bottom, 24)
        .onAppear {
            guard type != .mapIssue else { return }
            picked = ReportDefaults.defaultSubtype(type)
            timerOn = ReportDefaults.autoSends(type)
        }
        .task(id: timerOn) {
            guard timerOn else { fill = 0; return }
            withAnimation(.linear(duration: ReportDefaults.autoSendS)) { fill = 1 }
            for left in stride(from: Int(ReportDefaults.autoSendS), to: 0, by: -1) {
                secondsLeft = left
                try? await Task.sleep(for: .seconds(1))
                if Task.isCancelled { return }
            }
            send()
        }
    }

    @ViewBuilder private var content: some View {
        if !type.subtypes.isEmpty {
            LazyVGrid(columns: columns, spacing: Tokens.Space.gridGap + 4) {
                ForEach(type.subtypes) { s in
                    Button { picked = s.id; timerOn = false } label: {
                        ReportTile(icon: type.gIcon, title: s.title, type: type, badge: s.systemImage)
                            .overlay(
                                RoundedRectangle(cornerRadius: Tokens.Radius.reportTile + 2, style: .continuous)
                                    .strokeBorder(type.strokeColor, lineWidth: picked == s.id ? 3 : 0)
                                    .padding(.bottom, 26))
                            .opacity(picked == nil || picked == s.id ? 1 : 0.6)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text("\(String(localized: type.title)): \(String(localized: s.title))"))
                    .accessibilityAddTraits(picked == s.id ? .isSelected : [])
                    .accessibilityIdentifier("reportSubtype.\(s.id)")
                }
            }
        } else {
            ReportTile(icon: type.gIcon, title: type.shortTitle, type: type)
                .frame(width: Tokens.Size.reportTile + 20)
        }
        if type.wantsComment {
            // Note: at most 140 characters; the server drops a note that fails the content check and still sends the report.
            VStack(alignment: .trailing, spacing: 2) {
                HStack(alignment: .top, spacing: 4) {
                    TextField(type == .closure ? String(localized: "Which road? (optional)") : String(localized: "What's wrong? (optional)"),
                              text: $comment, axis: .vertical)
                        .font(Tokens.Font.body)
                        .lineLimit(2...4)
                        .focused($noteFocused)
                        .accessibilityIdentifier("reportNote")
                    if noteFocused {
                        Button { noteFocused = false } label: {
                            Image(systemName: "checkmark.circle.fill").font(.system(size: 26)).foregroundStyle(Color.brand)
                                .frame(width: 44, height: 44).contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(Text("OK"))
                        .accessibilityIdentifier("reportNoteOK")
                    }
                }
                .padding(.leading, 14).padding(.trailing, noteFocused ? 4 : 14).padding(.vertical, noteFocused ? 4 : 14)
                .background(Color.surfaceAlt, in: RoundedRectangle(cornerRadius: Tokens.Radius.md))
                if !comment.isEmpty {
                    Text(verbatim: "\(comment.count) / \(ReportNote.maxChars)").font(Tokens.Font.small).foregroundStyle(Color.textMuted)
                }
            }
            .onChange(of: comment) { _, v in
                timerOn = false
                if v.count > ReportNote.maxChars { comment = ReportNote.clamped(v) }
            }
        }
        if timerOn {
            Text("Sends in \(secondsLeft) s · tap an option to choose first")
                .font(Tokens.Font.nunito(14, .bold))
                .foregroundStyle(Color.textMuted)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityIdentifier("reportSendsIn")
        }
        HStack(spacing: 10) {
            Button { onCancel() } label: {
                Text("Cancel").font(Tokens.Font.nunito(17, .bold))
                    .frame(maxWidth: .infinity, minHeight: 56)
                    .foregroundStyle(Color.brandInk)
                    .overlay(RoundedRectangle(cornerRadius: Tokens.Radius.md, style: .continuous).strokeBorder(Color.outline, lineWidth: 2))
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity)
            .accessibilityIdentifier("cancelReport")
            Button { send() } label: {
                Text("Report").font(Tokens.Font.nunito(17, .black))
                    .frame(maxWidth: .infinity, minHeight: 56)
                    .foregroundStyle(Color.reportOn)
                    .background(alignment: .leading) {
                        // The sweep shows the time left before it sends itself.
                        GeometryReader { g in Rectangle().fill(Color.black.opacity(0.22)).frame(width: g.size.width * fill) }
                    }
                    .background(Color.report)
                    .clipShape(RoundedRectangle(cornerRadius: Tokens.Radius.md, style: .continuous))
            }
            .buttonStyle(.plain)
            .layoutPriority(1)
            .frame(maxWidth: .infinity)
            .accessibilityIdentifier("sendReport")
        }
    }

    private func send() {
        timerOn = false
        model.submitReport(type: type, subtype: picked, comment: comment)
    }
}

struct ReportTile: View {
    let icon: GIcon
    let title: LocalizedStringResource
    let type: ReportType
    /// Small SF Symbol hint for subtypes (the main glyph stays the shared duotone icon).
    var badge: String?

    var body: some View {
        VStack(spacing: 8) {
            GimanoIcon(icon: icon, size: Tokens.Size.reportIcon, stroke: type.strokeColor, fill: type.fillColor)
                .frame(maxWidth: .infinity)
                .frame(height: Tokens.Size.reportTile)
                .background(type.tileColor, in: RoundedRectangle(cornerRadius: Tokens.Radius.reportTile, style: .continuous))
                .overlay(alignment: .topTrailing) {
                    if let badge {
                        Image(systemName: badge)
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(type.strokeColor)
                            .frame(width: 30, height: 30)
                            .background(Color.white.opacity(0.85), in: Circle())
                            .padding(8)
                    }
                }
            Text(title)
                .font(Tokens.Font.nunito(15, .extrabold))
                .foregroundStyle(Color.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .contentShape(Rectangle())
    }
}
