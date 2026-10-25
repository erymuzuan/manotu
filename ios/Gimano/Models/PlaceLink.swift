import Foundation

/// Public place links contain an ID only, never a private pin or a caller-supplied API URL.
enum PlaceLink {
    static func parse(_ url: URL) -> String? {
        guard url.absoluteString.count <= 256,
              let c = URLComponents(url: url, resolvingAgainstBaseURL: false),
              c.user == nil, c.password == nil, c.port == nil, c.fragment == nil else { return nil }
        let supported = (c.scheme?.lowercased() == "https" && c.host?.lowercased() == "manotu.app" && ["/p", "/p/"].contains(c.percentEncodedPath))
            || (c.scheme?.lowercased() == "manotu" && c.host?.lowercased() == "place" && ["", "/"].contains(c.percentEncodedPath))
        guard supported, let query = c.percentEncodedQuery, query.hasPrefix("id=") else { return nil }
        let id = String(query.dropFirst(3))
        guard id.range(of: "\\A(?:[nwr][1-9][0-9]{0,19}|c[0-9a-f]{32})\\z", options: .regularExpression) != nil else { return nil }
        return id
    }
}
