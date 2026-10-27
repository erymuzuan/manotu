import Foundation
import Observation

enum DataMode: String, CaseIterable, Identifiable, Sendable {
    /// Use the backend; fall back to demo data when it is unreachable.
    case auto
    /// Backend only — errors are surfaced.
    case live
    /// Fully offline demo data.
    case demo
    var id: String { rawValue }

    var title: LocalizedStringResource {
        switch self {
        case .auto: "Auto (fallback to demo)"
        case .live: "Live backend only"
        case .demo: "Demo data"
        }
    }
}

/// Runtime configuration. Defaults come from Info.plist (`GimanoAPIBaseURL`, `GimanoMapStyleURL`, set from
/// build settings), overridable in the in-app Debug settings screen (persisted in UserDefaults).
@MainActor
@Observable
final class AppConfig {
    static let fallbackAPIBaseURL = "http://localhost:5080/api/v1/"
    nonisolated static let productionAPIBaseURL = "https://gimano-api.bukitbunga.com/api/v1/"
    nonisolated static let productionHosts: Set<String> = ["gimano-api.bukitbunga.com", "api.manotu.app"]
    nonisolated static func isProductionHost(_ url: String) -> Bool {
        guard let u = URL(string: url), u.scheme == "https", let h = u.host else { return false }
        return productionHosts.contains(h)
    }
    static let fallbackStyleURL = "https://tiles.openfreemap.org/styles/liberty"
    /// "Belum ada Manotu? Muat turun: …" in event invitation messages. On iOS this becomes the App Store URL once
    /// Manotu is published there.
    nonisolated static let downloadURL = "https://manotu.app/download/"

    private let defaults: UserDefaults

    let bundleAPIBaseURL: String
    let bundleStyleURL: String

    var apiBaseURLOverride: String { didSet { defaults.set(apiBaseURLOverride, forKey: Keys.api) } }
    var styleURLOverride: String { didSet { defaults.set(styleURLOverride, forKey: Keys.style) } }
    var dataMode: DataMode { didSet { defaults.set(dataMode.rawValue, forKey: Keys.mode) } }
    /// Drive along the route with a simulated GPS instead of real location.
    var simulateDrive: Bool { didSet { defaults.set(simulateDrive, forKey: Keys.simulate) } }
    var simulationSpeedup: Double { didSet { defaults.set(simulationSpeedup, forKey: Keys.speedup) } }

    init(defaults: UserDefaults = .standard, bundle: Bundle = .main) {
        self.defaults = defaults
        let plistAPI = (bundle.object(forInfoDictionaryKey: "GimanoAPIBaseURL") as? String)?.trimmingCharacters(in: .whitespaces)
        let plistStyle = (bundle.object(forInfoDictionaryKey: "GimanoMapStyleURL") as? String)?.trimmingCharacters(in: .whitespaces)
        let configuredAPI = (plistAPI?.isEmpty == false && !(plistAPI!.contains("$("))) ? plistAPI! : Self.fallbackAPIBaseURL
        #if DEBUG
        bundleAPIBaseURL = configuredAPI
        #else
        // A store/TestFlight build never talks to a dev or Tailscale host, whatever the build setting says.
        bundleAPIBaseURL = Self.isProductionHost(configuredAPI) ? configuredAPI : Self.productionAPIBaseURL
        #endif
        bundleStyleURL = (plistStyle?.isEmpty == false && !(plistStyle!.contains("$("))) ? plistStyle! : Self.fallbackStyleURL
        #if DEBUG
        apiBaseURLOverride = defaults.string(forKey: Keys.api) ?? ""
        styleURLOverride = defaults.string(forKey: Keys.style) ?? ""
        dataMode = DataMode(rawValue: defaults.string(forKey: Keys.mode) ?? "") ?? .auto
        simulateDrive = defaults.object(forKey: Keys.simulate) as? Bool ?? false
        simulationSpeedup = defaults.object(forKey: Keys.speedup) as? Double ?? 3
        applyLaunchArguments()
        #else
        // Release: no developer overrides; production server, demo data only when it's unreachable / 5xx, or when the
        // user turned on Demo mode (Settings, the public "try anywhere" mode).
        apiBaseURLOverride = ""
        styleURLOverride = ""
        dataMode = defaults.bool(forKey: Keys.publicDemo) ? .demo : .auto
        simulateDrive = false
        simulationSpeedup = 1
        #endif
    }

    /// Demo mode as the user sees it (Settings → Demo mode; the Demo badge turns it off): sample data on the phone,
    /// simulated drives, nothing sent. The same switch for everyone; there is no reviewer-only behaviour.
    var isDemoMode: Bool { dataMode == .demo }

    func setDemoMode(_ on: Bool) {
        defaults.set(on, forKey: Keys.publicDemo)
        dataMode = on ? .demo : .auto
    }

    /// Launch-argument server (tests); not persisted.
    private var launchAPIBaseURL: String?

    var apiBaseURL: URL {
        let raw = launchAPIBaseURL ?? (apiBaseURLOverride.trimmingCharacters(in: .whitespaces).isEmpty ? bundleAPIBaseURL : apiBaseURLOverride)
        var s = raw.trimmingCharacters(in: .whitespaces)
        if !s.hasSuffix("/") { s += "/" }
        return URL(string: s) ?? URL(string: Self.fallbackAPIBaseURL)!
    }

    var styleURL: URL {
        let raw = styleURLOverride.trimmingCharacters(in: .whitespaces).isEmpty ? bundleStyleURL : styleURLOverride
        return URL(string: raw) ?? URL(string: Self.fallbackStyleURL)!
    }

    /// Dark basemap (OpenFreeMap "dark"); a custom style override applies to both themes.
    var darkStyleURL: URL {
        if !styleURLOverride.trimmingCharacters(in: .whitespaces).isEmpty { return styleURL }
        return URL(string: "https://tiles.openfreemap.org/styles/dark")!
    }

    /// What About / Settings show as "Server": the public server is just "Manotu" (its host name is infrastructure);
    /// any other server (dev, a developer override) shows its host. Same rule as Android's `ServerLabel`.
    var serverLabel: String {
        #if DEBUG
        ServerLabel.text(current: apiBaseURL.absoluteString, builtIn: bundleAPIBaseURL, debug: true)
        #else
        ServerLabel.text(current: apiBaseURL.absoluteString, builtIn: bundleAPIBaseURL, debug: false)
        #endif
    }

    /// `ws(s)://host/hubs/live`, derived from the API base URL (`…/api/v1/` stripped).
    var liveHubURL: URL {
        Self.hubURL(fromAPIBase: apiBaseURL)
    }

    nonisolated static func hubURL(fromAPIBase base: URL) -> URL {
        var c = URLComponents(url: base, resolvingAgainstBaseURL: false) ?? URLComponents()
        c.scheme = (c.scheme == "https") ? "wss" : "ws"
        var path = c.path
        if let r = path.range(of: "/api/v1") { path = String(path[..<r.lowerBound]) }
        if path.hasSuffix("/") { path.removeLast() }
        c.path = path + "/hubs/live"
        c.query = nil
        return c.url ?? URL(string: "ws://localhost:5080/hubs/live")!
    }

    /// UI test / screenshot hooks: `-GimanoDataMode demo`, `-GimanoSimulateDrive YES`.
    private func applyLaunchArguments() {
        if let m = defaults.string(forKey: "GimanoDataMode"), let mode = DataMode(rawValue: m) { dataMode = mode }
        if defaults.object(forKey: "GimanoSimulateDrive") != nil { simulateDrive = defaults.bool(forKey: "GimanoSimulateDrive") }
        // `-GimanoAPIBaseURL https://…/api/v1/` (UI tests against another server, e.g. production): this run only,
        // never saved. `-GimanoFreshDevice YES` also forgets a saved developer override.
        if defaults.bool(forKey: "GimanoFreshDevice") {
            defaults.removeObject(forKey: Keys.api)
            apiBaseURLOverride = ""
        }
        if let u = defaults.string(forKey: "GimanoAPIBaseURL"), !u.isEmpty { launchAPIBaseURL = u }
    }

    private enum Keys {
        static let api = "debug.apiBaseURL"
        static let style = "debug.styleURL"
        static let mode = "debug.dataMode"
        static let publicDemo = "settings.demoMode"
        static let simulate = "debug.simulateDrive"
        static let speedup = "debug.simulationSpeedup"
    }
}

/// Release builds talking to their built-in server show the app's name instead of a host name.
enum ServerLabel {
    static func isPublic(current: String, builtIn: String, debug: Bool) -> Bool {
        func trimmed(_ s: String) -> String { s.trimmingCharacters(in: CharacterSet(charactersIn: "/ ")) }
        return !debug && trimmed(current) == trimmed(builtIn)
    }

    static func text(current: String, builtIn: String, debug: Bool) -> String {
        if isPublic(current: current, builtIn: builtIn, debug: debug) { return AppInfo.name }
        return URL(string: current)?.host() ?? current
    }
}
