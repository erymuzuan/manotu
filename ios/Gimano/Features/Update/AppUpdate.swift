import SwiftUI
import UIKit
import Observation

// App update nudge (docs/app-updates.md): soft prompt when behind `latest`, blocking cover when behind `forceBelow`.
// One plain GET of public data; no identifiers, nothing private leaves the phone.

/// A marketing version ("0.4.10"), compared numerically per segment. Missing segments count as 0; a pre-release or
/// build suffix ("0.5.0-beta") is ignored. Anything without a leading number does not parse.
struct AppVersion: Comparable, Equatable, Sendable {
    let parts: [Int]

    init?(_ text: String?) {
        guard let text else { return nil }
        let core = text.trimmingCharacters(in: .whitespaces).split(whereSeparator: { $0 == "-" || $0 == "+" }).first.map(String.init) ?? ""
        let segs = core.split(separator: ".", omittingEmptySubsequences: false).map { Int($0) }
        guard !segs.isEmpty, !segs.contains(where: { $0 == nil }) else { return nil }
        var p = segs.compactMap { $0 }
        while p.count > 1, p.last == 0 { p.removeLast() }
        parts = p
    }

    static func < (a: AppVersion, b: AppVersion) -> Bool {
        let n = max(a.parts.count, b.parts.count)
        for i in 0..<n {
            let x = i < a.parts.count ? a.parts[i] : 0
            let y = i < b.parts.count ? b.parts[i] : 0
            if x != y { return x < y }
        }
        return false
    }
}

/// `GET /app/versions` body: `{"platforms":{"ios":{...}}}`.
struct AppVersionsResponse: Codable, Sendable, Equatable {
    struct Platform: Codable, Sendable, Equatable {
        var latest: String?
        var forceBelow: String?
        var storeUrl: String?
        var releasedAt: String?
    }
    var platforms: [String: Platform]
    var ios: Platform? { platforms["ios"] }
}

enum UpdateDecision: Equatable, Sendable { case none, soft, forced }

enum UpdatePolicy {
    static let checkInterval: TimeInterval = 30 * 60

    /// forced when current < forceBelow, soft when current < latest, else none. Unparseable values never nag.
    static func decide(current: String, latest: String?, forceBelow: String?) -> UpdateDecision {
        guard let cur = AppVersion(current) else { return .none }
        if let f = AppVersion(forceBelow), cur < f { return .forced }
        if let l = AppVersion(latest), cur < l { return .soft }
        return .none
    }

    /// At most one request per `checkInterval`; a clock that went backwards allows a check.
    static func shouldCheck(lastChecked: Date?, now: Date, interval: TimeInterval = checkInterval) -> Bool {
        guard let last = lastChecked else { return true }
        let dt = now.timeIntervalSince(last)
        return dt < 0 || dt >= interval
    }

    /// `https://apps.apple.com/app/id…` -> `itms-apps://apps.apple.com/app/id…` (opens the App Store directly).
    static func storeOpenURL(_ storeUrl: String?) -> URL? {
        guard let s = storeUrl, var c = URLComponents(string: s), c.host != nil else { return nil }
        if c.scheme == "https" || c.scheme == "http" { c.scheme = "itms-apps" }
        return c.url
    }
}

/// TestFlight and debug builds have no App Store version to compare with: skip the check (docs/app-updates.md).
enum UpdateEnvironment {
    static var isTestFlightOrDebug: Bool {
        #if DEBUG
        return true
        #else
        return Bundle.main.appStoreReceiptURL?.lastPathComponent == "sandboxReceipt"
        #endif
    }

    /// DEBUG only: `-GimanoForceUpdateCard soft|forced` shows the card without a server.
    static var debugForced: UpdateDecision? {
        #if DEBUG
        switch UserDefaults.standard.string(forKey: "GimanoForceUpdateCard") {
        case "soft": return .soft
        case "forced": return .forced
        default: return nil
        }
        #else
        return nil
        #endif
    }
}

@MainActor
@Observable
final class UpdateCenter {
    private(set) var info: AppVersionsResponse.Platform?
    private var laterTapped = false
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let currentVersion: String
    @ObservationIgnored private let skipChecks: Bool
    @ObservationIgnored private let fetch: @Sendable (URL) async -> Data?
    @ObservationIgnored private var inFlight = false
    @ObservationIgnored private let now: () -> Date

    private enum Keys { static let at = "update.lastCheck", body = "update.lastBody" }

    init(defaults: UserDefaults = .standard, currentVersion: String = AppInfo.version,
         skipChecks: Bool = UpdateEnvironment.isTestFlightOrDebug,
         now: @escaping () -> Date = { .now },
         fetch: @escaping @Sendable (URL) async -> Data? = UpdateCenter.networkFetch) {
        self.defaults = defaults; self.currentVersion = currentVersion; self.skipChecks = skipChecks
        self.now = now; self.fetch = fetch
        if !skipChecks, let d = defaults.data(forKey: Keys.body),
           let r = try? JSONDecoder().decode(AppVersionsResponse.self, from: d) { info = r.ios }
    }

    /// Plain GET: no cookies, no credentials, no identifiers; any failure is silent.
    nonisolated static let networkFetch: @Sendable (URL) async -> Data? = { url in
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 10
        cfg.httpCookieStorage = nil
        cfg.urlCache = nil
        var req = URLRequest(url: url)
        req.httpShouldHandleCookies = false
        guard let (data, resp) = try? await URLSession(configuration: cfg).data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return data
    }

    var decision: UpdateDecision {
        if let f = UpdateEnvironment.debugForced { return f }
        guard !skipChecks, let info else { return .none }
        return UpdatePolicy.decide(current: currentVersion, latest: info.latest, forceBelow: info.forceBelow)
    }

    var latestVersion: String { info?.latest ?? currentVersion }
    /// A newer version exists (shown as a row in Settings / About; never gated on Later).
    var updateAvailable: Bool { decision != .none }

    /// What the full-screen card should show now: forced always, soft until Later. `busy` (navigating) defers both.
    func presentation(busy: Bool) -> UpdateDecision {
        if busy { return .none }
        switch decision {
        case .forced: return .forced
        case .soft: return laterTapped ? .none : .soft
        case .none: return .none
        }
    }

    func later() { laterTapped = true }

    func open() {
        let url = UpdatePolicy.storeOpenURL(info?.storeUrl) ?? UpdatePolicy.storeOpenURL(AppInfo.fallbackStoreUrl)
        if let url { UIApplication.shared.open(url) }
    }

    /// Launch and every activation; throttled to once per 30 minutes (the last answer is cached on the device).
    func checkIfDue(apiBase: URL, demo: Bool) async {
        guard !skipChecks, !demo, !inFlight else { return }
        let last = defaults.object(forKey: Keys.at) as? Date
        guard UpdatePolicy.shouldCheck(lastChecked: last, now: now()) else { return }
        inFlight = true
        defer { inFlight = false }
        guard let url = URL(string: "app/versions", relativeTo: apiBase)?.absoluteURL,
              let data = await fetch(url),
              let r = try? JSONDecoder().decode(AppVersionsResponse.self, from: data) else { return }
        defaults.set(now(), forKey: Keys.at)
        defaults.set(data, forKey: Keys.body)
        info = r.ios
    }
}

extension AppInfo {
    static let fallbackStoreUrl = "https://apps.apple.com/app/id6826478029"
}

/// Full-screen "New version" card. `forced` has no Later and cannot be dismissed.
struct UpdateCardView: View {
    let forced: Bool
    let current: String
    let latest: String
    let onUpdate: () -> Void
    let onLater: () -> Void

    private var badgeColor: Color { forced ? Color.report : Color.brand }
    private var badgeSymbol: String { forced ? "exclamationmark.circle.fill" : "arrow.down.circle.fill" }

    private var icon: some View {
        ZStack(alignment: .bottomTrailing) {
            GimanoIcon(icon: .logo, size: 88)
                .frame(width: 140, height: 140)
                .background(Color.brandMist, in: RoundedRectangle(cornerRadius: 32, style: .continuous))
            Image(systemName: badgeSymbol)
                .font(.system(size: 40))
                .foregroundStyle(badgeColor)
                .background(Circle().fill(Color.appBackground).padding(2))
                .offset(x: 10, y: 10)
        }
    }

    private var heading: some View {
        VStack(spacing: 10) {
            Text(forced ? "Update needed" : "New version")
                .font(Tokens.Font.title)
                .foregroundStyle(Color.textPrimary)
                .accessibilityIdentifier("updateTitle")
            HStack(spacing: 10) {
                Text(verbatim: current).foregroundStyle(Color.textMuted)
                Image(systemName: "arrow.right").foregroundStyle(Color.brand)
                Text(verbatim: latest).foregroundStyle(Color.brandInk)
            }
            .font(Tokens.Font.nunito(20, .bold))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(verbatim: "\(current) to \(latest)"))
        }
    }

    private var actions: some View {
        VStack(spacing: 10) {
            Button(action: onUpdate) {
                Label("Update", systemImage: "arrow.down.circle.fill")
            }
            .buttonStyle(PrimaryButtonStyle())
            .accessibilityIdentifier("updateNow")
            if forced {
                Color.clear.frame(height: 36)
            } else {
                Button("Later", action: onLater)
                    .font(Tokens.Font.caption)
                    .foregroundStyle(Color.textMuted)
                    .padding(.vertical, 8)
                    .accessibilityIdentifier("updateLater")
            }
        }
    }

    var body: some View {
        VStack(spacing: 28) {
            Spacer()
            icon
            heading
            Spacer()
            actions
        }
        .padding(Tokens.Space.gutter)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.appBackground.ignoresSafeArea())
    }
}

/// Settings / About row.
struct UpdateAvailableRow: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if model.updates.updateAvailable {
            Button { model.updates.open() } label: {
                HStack {
                    Label("Update available", systemImage: "arrow.down.circle.fill")
                    Spacer()
                    Text(verbatim: model.updates.latestVersion).foregroundStyle(Color.textMuted)
                }
            }
            .accessibilityIdentifier("updateAvailableRow")
        }
    }
}
