import SwiftUI
import UIKit

/// The fan's state while the finger is down (owned by DriveView, which draws the overlay over the whole screen).
struct QuickFanState: Equatable {
    var isOpen = false
    var selected: ReportType?
    /// The report button's centre in DriveView's "drive" coordinate space.
    var center: CGPoint = .zero
}

/// Report button while driving (docs/driving.md §6.4, board NavDilalui): tap = the full report sheet, as before;
/// hold ~300 ms = the fan of 8 quick actions; slide onto one and release to send it at once; release elsewhere cancels.
/// VoiceOver: the button's action opens the full sheet (the fan needs no gesture to be reachable).
struct HoldReportButton: View {
    @Binding var fan: QuickFanState
    let onTap: () -> Void
    let onSend: (ReportType) -> Void

    @State private var pressStart: Date?
    @State private var holdTask: Task<Void, Never>?
    @State private var lastTranslation: CGVector = .zero

    var body: some View {
        GimanoIcon(icon: .report, size: Tokens.Size.reportFabIcon, stroke: .reportOn, fill: .reportTint)
            .frame(width: Tokens.Size.reportFab, height: Tokens.Size.reportFab)
            .background(Color.report, in: RoundedRectangle(cornerRadius: Tokens.Radius.reportFab, style: .continuous))
            .reportShadow()
            .opacity(fan.isOpen ? 0 : 1)
            .contentShape(RoundedRectangle(cornerRadius: Tokens.Radius.reportFab, style: .continuous))
            .onGeometryChange(for: CGPoint.self) { g in
                let f = g.frame(in: .named(DriveView.space))
                return CGPoint(x: f.midX, y: f.midY)
            } action: { fan.center = $0 }
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .named(DriveView.space))
                    .onChanged { v in changed(v) }
                    .onEnded { v in ended(v) }
            )
            .accessibilityElement()
            .accessibilityAddTraits(.isButton)
            .accessibilityLabel(Text("Report"))
            .accessibilityHint(Text("Opens the report list. Touch and hold for quick reports."))
            .accessibilityAction { onTap() }
            .accessibilityIdentifier("reportButton")
    }

    private func changed(_ v: DragGesture.Value) {
        if pressStart == nil {
            pressStart = Date()
            holdTask?.cancel()
            holdTask = Task { @MainActor in
                try? await Task.sleep(for: .seconds(QuickReportFan.holdS))
                guard !Task.isCancelled, pressStart != nil else { return }
                open()
            }
        }
        let t = CGVector(dx: v.location.x - fan.center.x, dy: v.location.y - fan.center.y)
        lastTranslation = t
        guard fan.isOpen else { return }
        select(QuickReportFan.hit(t))
    }

    private func ended(_ v: DragGesture.Value) {
        holdTask?.cancel()
        holdTask = nil
        pressStart = nil
        if fan.isOpen {
            let t = CGVector(dx: v.location.x - fan.center.x, dy: v.location.y - fan.center.y)
            let chosen = QuickReportFan.hit(t)
            withAnimation(.snappy(duration: 0.2)) { fan.isOpen = false; fan.selected = nil }
            if let chosen {
                UIImpactFeedbackGenerator(style: .heavy).impactOccurred()
                onSend(chosen)
            }
        } else if hypot(v.translation.width, v.translation.height) < 20 {
            onTap()
        }
    }

    private func open() {
        UIImpactFeedbackGenerator(style: .rigid).impactOccurred()
        withAnimation(.spring(response: 0.28, dampingFraction: 0.75)) { fan.isOpen = true }
        select(QuickReportFan.hit(lastTranslation))
    }

    private func select(_ t: ReportType?) {
        guard t != fan.selected else { return }
        withAnimation(.snappy(duration: 0.15)) { fan.selected = t }
        if t != nil { UIImpactFeedbackGenerator(style: .medium).impactOccurred() }
    }
}

/// The open fan (boards NavLaporTahan / NavLaporPilih): dimmed map, the top banner, 8 coloured bubbles around the
/// button and a dark close button in its place. Drawn by DriveView over everything; it takes no touches itself (the
/// finger is still on the report button's gesture).
struct QuickFanOverlay: View {
    let fan: QuickFanState

    var body: some View {
        ZStack(alignment: .top) {
            Color(red: 11 / 255, green: 27 / 255, blue: 58 / 255).opacity(0.5)
                .ignoresSafeArea()
            ForEach(QuickReportFan.items) { item in
                bubble(item)
                    .position(x: fan.center.x + item.offset.dx, y: fan.center.y + item.offset.dy)
            }
            Image(systemName: "xmark")
                .font(.system(size: 26, weight: .heavy))
                .foregroundStyle(.white)
                .frame(width: 68, height: 68)
                .background(Color(uiColor: UIColor(hex: 0x0B1F4A)), in: Circle())
                .shadow(color: Color(red: 11 / 255, green: 27 / 255, blue: 58 / 255).opacity(0.4), radius: 8, y: 4)
                .position(fan.center)
            banner
                .padding(.horizontal, 10)
                .padding(.top, 118)
        }
        .allowsHitTesting(false)
        .dynamicTypeSize(...DynamicTypeSize.xxLarge)
        .accessibilityHidden(true)
    }

    private var banner: some View {
        let sel = fan.selected
        let colors = sel.map(QuickReportFan.colors)
        return VStack(alignment: .leading, spacing: 2) {
            if let sel {
                Text(sel.fanTitle).font(Tokens.Font.nunito(22, .black))
                Text("Release to report at your position").font(Tokens.Font.nunito(14, .bold)).opacity(0.9)
            } else {
                Text("Slide to an option, release to report").font(Tokens.Font.nunito(22, .black))
                Text("Just tap = full list · release outside = cancel").font(Tokens.Font.nunito(14, .bold)).opacity(0.9)
            }
        }
        .foregroundStyle(colors.map { Color(uiColor: UIColor(hex: $0.ink)) } ?? .white)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 18).padding(.vertical, 14)
        .background(colors.map { Color(uiColor: UIColor(hex: $0.fill)) } ?? Color(uiColor: UIColor(hex: 0x0B1F4A)),
                    in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .shadow(color: .black.opacity(0.3), radius: 11, y: 6)
        .accessibilityIdentifier("quickFanBanner")
    }

    private func bubble(_ item: QuickReportFan.Item) -> some View {
        let on = fan.selected == item.type
        let dimmed = fan.selected != nil && !on
        let c = QuickReportFan.colors(item.type)
        let d = on ? QuickReportFan.selectedDiameter : item.diameter
        let ink = Color(uiColor: UIColor(hex: c.ink))
        return VStack(spacing: 4) {
            GimanoIcon(icon: item.type.gIcon, size: on ? 40 : 28, stroke: ink, fill: ink.opacity(0.35))
                .frame(width: d, height: d)
                .background(Color(uiColor: UIColor(hex: c.fill)), in: Circle())
                .overlay(Circle().strokeBorder(Color.white.opacity(on ? 1 : 0.9), lineWidth: on ? 4 : 3))
                .background(Circle().fill(Color(uiColor: UIColor(hex: c.fill)).opacity(on ? 0.45 : 0)).padding(-8))
                .shadow(color: .black.opacity(on ? 0.35 : 0.25), radius: on ? 9 : 6, y: on ? 6 : 4)
            Text(item.type.fanTitle)
                .font(Tokens.Font.nunito(on ? 15 : 13, .black))
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.6), radius: 1.5, y: 1)
                .fixedSize()
        }
        // The label hangs below the bubble: shift so the bubble's centre sits on the ring.
        .offset(y: 10)
        .opacity(dimmed ? 0.45 : 1)
        .accessibilityIdentifier("quickFan.\(item.type.rawValue)")
    }
}

/// "Hazard reported · Jalan SS 2/55 · just now" with Details and Undo (5 s ring), board NavLaporHantar.
struct QuickReportCard: View {
    @Environment(AppModel.self) private var model
    let q: QuickReportUndo

    var body: some View {
        TimelineView(.periodic(from: q.startedAt, by: 0.25)) { ctx in
            let c = QuickReportFan.colors(q.type)
            HStack(spacing: 12) {
                GimanoIcon(icon: q.type.gIcon, size: 28, stroke: Color(uiColor: UIColor(hex: c.ink)),
                           fill: Color(uiColor: UIColor(hex: c.ink)).opacity(0.35))
                    .frame(width: 48, height: 48)
                    .background(Color(uiColor: UIColor(hex: c.fill)), in: Circle())
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 1) {
                    Text("\(String(localized: q.type.fanTitle)) reported")
                        .font(Tokens.Font.nunito(18, .black, relativeTo: .headline))
                        .lineLimit(2).minimumScaleFactor(0.7)
                    Text(verbatim: [q.street, String(localized: "just now")].compactMap { $0 }.joined(separator: " · "))
                        .font(Tokens.Font.nunito(13, .bold, relativeTo: .footnote))
                        .foregroundStyle(Color.tileLabel)
                        .lineLimit(2)
                        .minimumScaleFactor(0.85)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityElement(children: .combine)
                Button { model.openQuickReportDetails() } label: {
                    Text("Details").font(Tokens.Font.nunito(15, .black))
                        .lineLimit(1).fixedSize()
                        .foregroundStyle(Color.brandInk)
                        .padding(.horizontal, 12).frame(minHeight: 48)
                        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.outline, lineWidth: 2))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(q.reportId == nil)
                .accessibilityIdentifier("quickReportDetails")
                Button { model.undoQuickReport() } label: {
                    HStack(spacing: 6) {
                        ZStack {
                            Circle().stroke(Color.white.opacity(0.35), lineWidth: 3)
                            Circle().trim(from: 0, to: q.progress(at: ctx.date))
                                .stroke(Color.white, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                                .rotationEffect(.degrees(-90))
                            Text(verbatim: "\(q.remaining(at: ctx.date))").font(Tokens.Font.nunito(10, .black))
                        }
                        .frame(width: 22, height: 22)
                        Text("Undo").font(Tokens.Font.nunito(15, .black))
                            .lineLimit(1).fixedSize()
                    }
                    .foregroundStyle(Color.brandOn)
                    .padding(.horizontal, 12).frame(minHeight: 48)
                    .background(Color.brand, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("Undo"))
                .accessibilityValue(Text(verbatim: "\(q.remaining(at: ctx.date)) s"))
                .accessibilityIdentifier("quickReportUndo")
            }
            .foregroundStyle(Color.textPrimary)
            .padding(12)
            .background(Color.surface, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .shadow(color: Color(red: 11 / 255, green: 27 / 255, blue: 58 / 255).opacity(0.25), radius: 11, y: 6)
        }
        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("quickReportCard")
        .onAppear {
            AccessibilityNotification.Announcement(String(localized: "\(String(localized: q.type.fanTitle)) reported")).post()
        }
    }
}

/// Details on the card: the subtypes of the report just sent (optional).
struct QuickReportDetailsSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let q: QuickReportUndo
    private let columns = Array(repeating: GridItem(.flexible(), spacing: Tokens.Space.gridGap), count: 3)

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(q.type.title).font(Tokens.Font.title)
            if q.type.subtypes.isEmpty {
                Text("Nothing more to add for this report.").font(Tokens.Font.body).foregroundStyle(Color.textMuted)
            }
            LazyVGrid(columns: columns, spacing: Tokens.Space.gridGap + 4) {
                ForEach(q.type.subtypes) { s in
                    Button { model.setQuickReportSubtype(s.id); dismiss() } label: {
                        ReportTile(icon: q.type.gIcon, title: s.title, type: q.type, badge: s.systemImage)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text("\(String(localized: q.type.title)): \(String(localized: s.title))"))
                    .accessibilityIdentifier("quickSubtype.\(s.id)")
                }
            }
            Spacer(minLength: 0)
        }
        .padding(20)
    }
}

extension ReportType {
    /// Label on the fan and the sent card: the inner ring's full names, the outer ring's short ones.
    var fanTitle: LocalizedStringResource {
        switch self {
        case .hazard, .police, .accident: title
        default: shortTitle
        }
    }
}
