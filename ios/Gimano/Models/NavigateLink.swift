import Foundation

/// A request from another app (e.g. a delivery app) to route to one point. It is untrusted: it never starts
/// navigation by itself, the user confirms first. Nothing here is stored, logged or uploaded.
struct NavigateRequest: Equatable, Identifiable, Sendable {
    let lat: Double
    let lng: Double
    let label: String?
    let id = UUID()

    static func == (a: NavigateRequest, b: NavigateRequest) -> Bool {
        a.lat == b.lat && a.lng == b.lng && a.label == b.label
    }
}

enum NavigateLink {
    static let maxLabel = 60

    /// Strict: exact scheme/host/path, only lat, lng, label (each at most once), no credentials/port/fragment.
    static func parse(_ url: URL) -> NavigateRequest? {
        guard url.absoluteString.count <= 512,
              let c = URLComponents(url: url, resolvingAgainstBaseURL: false),
              c.user == nil, c.password == nil, c.port == nil, c.fragment == nil else { return nil }
        let https = c.scheme?.lowercased() == "https" && c.host?.lowercased() == "manotu.app"
            && ["/nav", "/nav/"].contains(c.percentEncodedPath)
        let custom = c.scheme?.lowercased() == "manotu" && c.host?.lowercased() == "navigate"
            && ["", "/"].contains(c.percentEncodedPath)
        guard https || custom, let query = c.percentEncodedQuery, !query.isEmpty else { return nil }

        var values: [String: String] = [:]
        for pair in query.split(separator: "&", omittingEmptySubsequences: false) {
            let kv = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard kv.count == 2 else { return nil }
            let key = String(kv[0])
            guard ["lat", "lng", "label"].contains(key), values[key] == nil else { return nil }
            values[key] = String(kv[1])
        }
        guard let latText = values["lat"], let lngText = values["lng"],
              let lat = coordinate(latText, limit: 90), let lng = coordinate(lngText, limit: 180) else { return nil }

        var label: String?
        if let raw = values["label"] {
            guard !raw.contains("+"), let decoded = raw.removingPercentEncoding, let clean = cleanLabel(decoded) else { return nil }
            label = clean
        }
        return NavigateRequest(lat: lat, lng: lng, label: label)
    }

    /// Plain decimal: optional '-', no '+', no exponent, no leading zeros, at most 6 decimals.
    private static func coordinate(_ s: String, limit: Double) -> Double? {
        guard s.range(of: "\\A-?(?:0|[1-9][0-9]{0,2})(?:\\.[0-9]{1,6})?\\z", options: .regularExpression) != nil,
              let v = Double(s), v.isFinite, abs(v) <= limit else { return nil }
        return v == 0 ? 0 : v
    }

    private static let allowedPunctuation = Set(" .,-#/()'&@:")

    /// Same grammar as site/manotu/nav/link.mjs: 1 to 60 chars, letters/marks/numbers (any script) and ` .,-#/()'&@:`,
    /// not blank, no "://" or "www.". Returned as decoded (not trimmed). nil = rejected.
    private static func cleanLabel(_ s: String) -> String? {
        guard !s.isEmpty, s.count <= maxLabel, !s.allSatisfy({ $0 == " " }) else { return nil }
        for scalar in s.unicodeScalars {
            switch scalar.properties.generalCategory {
            case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter,
                 .nonspacingMark, .spacingMark, .enclosingMark,
                 .decimalNumber, .letterNumber, .otherNumber: continue
            default:
                if !allowedPunctuation.contains(Character(scalar)) { return nil }
            }
        }
        let lower = s.lowercased()
        if lower.contains("://") || lower.contains("www.") { return nil }
        return s
    }
}

/// The one pending request. Newer links replace older ones; during a drive nothing is held.
struct NavigateLinkState: Equatable {
    enum Outcome: Equatable { case pending, finishDriveFirst }
    private(set) var pending: NavigateRequest?

    mutating func offer(_ r: NavigateRequest, driving: Bool) -> Outcome {
        guard !driving else { pending = nil; return .finishDriveFirst }
        pending = r
        return .pending
    }

    /// The request to route to, or nil when none is pending or a drive started meanwhile (it is then dropped).
    mutating func confirm(driving: Bool) -> NavigateRequest? {
        defer { pending = nil }
        return driving ? nil : pending
    }

    mutating func cancel() { pending = nil }
}
