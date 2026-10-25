import SwiftUI

// Sensitive places UI (docs/safety.md part 4): A blocked pin, B near, C sensitive words, D map sheet.

/// D · Tapped inside a restricted area on the map.
struct RestrictedAreaInfoSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                RestrictedAreaGlyph()
                Text("Restricted area").font(Tokens.Font.title).accessibilityAddTraits(.isHeader)
            }
            line("eye.slash.fill", "No reviews, photos or added places for this area.")
            line("camera.metering.none", "Don't photograph or sketch this area (Act 298).")
            line("arrow.triangle.branch", "Manotu routes don't go through this area.")
            Spacer(minLength: 0)
            Button("Close") { dismiss() }
                .buttonStyle(SecondaryButtonStyle())
                .accessibilityIdentifier("restrictedInfoClose")
        }
        .padding(Tokens.Space.xl)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("restrictedInfo")
    }

    private func line(_ icon: String, _ text: LocalizedStringKey) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon).frame(width: 24).foregroundStyle(Color.textMuted).accessibilityHidden(true)
            Text(text).font(Tokens.Font.body).fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Grey hatched square, as the area looks on the map.
struct RestrictedAreaGlyph: View {
    var size: CGFloat = 48

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size / 3.2, style: .continuous).fill(Color(light: 0xE6E9EF, dark: 0x262D3A))
            Canvas { ctx, sz in
                var p = Path()
                var x: CGFloat = -sz.height
                while x < sz.width {
                    p.move(to: CGPoint(x: x, y: sz.height)); p.addLine(to: CGPoint(x: x + sz.height, y: 0))
                    x += 7
                }
                ctx.stroke(p, with: .color(Color(light: 0x5B6475, dark: 0x8A93A6).opacity(0.55)), lineWidth: 1.5)
            }
            .clipShape(RoundedRectangle(cornerRadius: size / 3.2, style: .continuous))
            RoundedRectangle(cornerRadius: size / 3.2, style: .continuous)
                .strokeBorder(Color(light: 0x5B6475, dark: 0x8A93A6), style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// A · The pin is in a restricted area (public place, or moving a pin): this sheet instead of the form.
struct RestrictedBlockedSheet: View {
    let onMove: () -> Void
    let onSavePrivate: () -> Void
    let onCancel: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 12) {
                    RestrictedAreaGlyph()
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Can't be shared here").font(Tokens.Font.title).accessibilityAddTraits(.isHeader)
                        Text("The pin is in a restricted area").font(Tokens.Font.caption).foregroundStyle(Color.textMuted)
                    }
                }
                Text("Manotu doesn't accept places, photos, reviews or details in military, security and strategic areas. Photographing or sketching a restricted area is also an offence under Act 298.")
                    .font(Tokens.Font.body)
                    .fixedSize(horizontal: false, vertical: true)
                Label {
                    Text("A shop or stall outside the fence? Move the pin to where it really is, outside the shaded area.")
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "lightbulb.fill")
                }
                .font(Tokens.Font.caption)
                .foregroundStyle(Color.brandInk)
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.brandMist, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                Button("Move the pin", action: onMove)
                    .buttonStyle(PrimaryButtonStyle())
                    .accessibilityIdentifier("restrictedMovePin")
                Button("Save just for me", action: onSavePrivate)
                    .buttonStyle(SecondaryButtonStyle())
                    .accessibilityIdentifier("restrictedSavePrivate")
                Button("Cancel", action: onCancel)
                    .font(Tokens.Font.bodyBold)
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .accessibilityIdentifier("restrictedCancel")
            }
            .padding(Tokens.Space.xl)
        }
        .interactiveDismissDisabled()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("restrictedBlocked")
    }
}

/// A short "can't be shared here" note inside a form (reviews / photos of a place in a restricted area).
struct RestrictedBlockedNote: View {
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            RestrictedAreaGlyph(size: 36)
            VStack(alignment: .leading, spacing: 4) {
                Text("Can't be shared here").font(Tokens.Font.bodyBold)
                Text("Manotu doesn't accept places, photos, reviews or details in military, security and strategic areas. Photographing or sketching a restricted area is also an offence under Act 298.")
                    .font(Tokens.Font.caption)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.surfaceAlt, in: RoundedRectangle(cornerRadius: Tokens.Radius.md, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("restrictedBlockedNote")
    }
}

/// B · Near a restricted area (≤ reviewM), public: a note at the top of the form.
struct RestrictedNearNote: View {
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Color.amberInk).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text("Near a restricted area").font(Tokens.Font.bodyBold)
                Text("Photos aren't allowed here. A moderator will check this place before others can see it.")
                    .font(Tokens.Font.caption)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .foregroundStyle(Color.amberInk)
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.amberMist, in: RoundedRectangle(cornerRadius: Tokens.Radius.md, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("restrictedNearNote")
    }
}

/// Under the disabled photo button (B).
struct PhotosOffCaption: View {
    let reviewM: Double

    var body: some View {
        Label("Photos are off within \(Int(reviewM)) m of a restricted area.", systemImage: "camera.fill")
            .font(Tokens.Font.small)
            .foregroundStyle(Color.textMuted)
            .accessibilityIdentifier("photosOffCaption")
    }
}

/// C · Sensitive words in a public name, description or review: inline warning below the field.
struct SensitiveTermsWarning: View {
    let onRemove: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Security details aren't allowed").font(Tokens.Font.bodyBold)
                    Text("Don't write about entrances, guards, CCTV, fences or patrol times, anywhere. Remove this sentence, or a moderator will check this place first.")
                        .font(Tokens.Font.caption)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } icon: {
                Image(systemName: "exclamationmark.shield.fill")
            }
            Button("Remove this sentence", action: onRemove)
                .font(Tokens.Font.label)
                .buttonStyle(.borderless)
                .accessibilityIdentifier("removeSensitiveSentence")
        }
        .foregroundStyle(Color.amberInk)
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.amberMist, in: RoundedRectangle(cornerRadius: Tokens.Radius.md, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("sensitiveTermsWarning")
    }
}

/// "Being checked" badge for held items in My contributions.
struct BeingCheckedBadge: View {
    var body: some View {
        Text("Being checked")
            .font(Tokens.Font.small)
            .foregroundStyle(Color.amberInk)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(Color.amberMist, in: Capsule())
            .accessibilityIdentifier("beingChecked")
    }
}

extension FlagReason {
    /// The explainer under "Sensitive or security location" in report menus (E).
    var explainer: LocalizedStringKey? {
        self == .sensitiveLocation
            ? "A military or strategic site, a shelter, a private home, or details such as guards and CCTV. Hidden at once while it's checked."
            : nil
    }
}

/// The report-reason buttons for a menu (place, review, photo), with the explainer as the subtitle for E.
struct FlagReasonButtons: View {
    let action: (FlagReason) -> Void

    var body: some View {
        ForEach(FlagReason.allCases) { r in
            Button { action(r) } label: {
                Text(r.title)
                if let e = r.explainer { Text(e) }
            }
            .accessibilityIdentifier("flagReason.\(r.rawValue)")
        }
    }
}
