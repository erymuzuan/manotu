import SwiftUI

/// "Route to this spot?": shown for every navigate link because any app can send one.
struct NavigateLinkSheet: View {
    let request: NavigateRequest
    let onConfirm: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "mappin.circle.fill")
                .font(.system(size: 72))
                .foregroundStyle(Color.brand)
                .accessibilityHidden(true)
            Text("Route to this spot?").font(Tokens.Font.nunito(22, .black))
            if let label = request.label {
                Text(label).font(Tokens.Font.nunito(18, .bold)).multilineTextAlignment(.center)
                    .accessibilityIdentifier("navigateLinkLabel")
            }
            Text(String(format: "%.5f, %.5f", request.lat, request.lng))
                .font(Tokens.Font.caption).foregroundStyle(Color.textMuted)
                .accessibilityIdentifier("navigateLinkCoords")
            Button(action: onConfirm) { Label("Confirm", systemImage: "checkmark") }
                .buttonStyle(PrimaryButtonStyle())
                .accessibilityIdentifier("navigateLinkConfirm")
            Button("Cancel", action: onCancel)
                .font(Tokens.Font.label).foregroundStyle(Color.textMuted)
                .accessibilityIdentifier("navigateLinkCancel")
        }
        .padding(Tokens.Space.gutter)
    }
}
