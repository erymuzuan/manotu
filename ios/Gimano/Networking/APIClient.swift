import Foundation

struct ProblemDetails: Codable, Sendable {
    var type: String?
    var title: String?
    var status: Int?
    var detail: String?
    /// Machine-readable reason, e.g. `restricted_area` (docs/api.md "Restricted areas") or `adding_paused`.
    var code: String?
    /// 429: seconds until the limit lifts (body `retryAfterSeconds`, else the `Retry-After` header).
    var retryAfterSeconds: Int?
    /// 403 `adding_paused`: when adding places is allowed again (ISO-8601; kept as text so a bad date never hides the problem).
    var pausedUntil: String?
    /// 422 `content_rejected` (docs/content-safety.md): fixed reason codes, and the review without the offending part.
    var reasons: [String]?
    var safeText: String?

    init(type: String? = nil, title: String? = nil, status: Int? = nil, detail: String? = nil, code: String? = nil,
         retryAfterSeconds: Int? = nil, pausedUntil: String? = nil, reasons: [String]? = nil, safeText: String? = nil) {
        self.type = type; self.title = title; self.status = status; self.detail = detail; self.code = code
        self.retryAfterSeconds = retryAfterSeconds; self.pausedUntil = pausedUntil
        self.reasons = reasons; self.safeText = safeText
    }

    /// Reads `Retry-After` as delta-seconds (the API never sends an HTTP date).
    static func retryAfter(header: String?) -> Int? {
        guard let h = header?.trimmingCharacters(in: .whitespaces), let s = Int(h), s >= 0 else { return nil }
        return s
    }
}

enum APIError: Error, LocalizedError, Sendable {
    case transport(URLError)
    case http(status: Int, problem: ProblemDetails?)
    /// 409 with a JSON body (e.g. the existing place for a duplicate "Add a place").
    case conflict(Data)
    case decoding(String)
    case notAvailable

    var errorDescription: String? {
        switch self {
        case .transport(let e): e.localizedDescription
        case .http(403, let p) where p?.code == "adding_paused":
            String(localized: "Adding places is paused for now. It lifts by itself.")
        // 403 on a contribution: a moderator suspended this account (docs/api.md "Reporting and moderation").
        case .http(403, let p) where p?.code == "posting_paused":
            String(localized: "Posting is paused for now. It lifts by itself.")
        case .http(403, _): String(localized: "Your account can't post right now: it was suspended for breaking the community rules.")
        case .http(let status, let p): p?.detail ?? p?.title ?? String(localized: "Something went wrong on the server (\(status)).")
        case .conflict: String(localized: "This place may already exist.")
        case .decoding: String(localized: "The server sent something unexpected. Try again later.")
        case .notAvailable: String(localized: "Not available")
        }
    }

    /// The backend can't be reached at all (vs. it answered with an error).
    var isUnreachable: Bool {
        guard case .transport(let e) = self else { return false }
        switch e.code {
        case .cannotConnectToHost, .cannotFindHost, .timedOut, .networkConnectionLost, .notConnectedToInternet,
             .dnsLookupFailed, .secureConnectionFailed, .appTransportSecurityRequiresSecureConnection,
             .resourceUnavailable, .badServerResponse, .cannotLoadFromNetwork, .internationalRoamingOff, .dataNotAllowed:
            return true
        default:
            return false
        }
    }

    /// Endpoint missing or server-side failure: worth serving demo data for this call in auto mode.
    var isServerSideGap: Bool {
        if case .http(let status, _) = self { return status == 404 || status == 405 || status == 501 || status >= 502 }
        return false
    }
}

enum JSON {
    static func makeDecoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .custom { decoder in
            let c = try decoder.singleValueContainer()
            let s = try c.decode(String.self)
            if let date = parseDate(s) { return date }
            throw DecodingError.dataCorruptedError(in: c, debugDescription: "Bad date \(s)")
        }
        return d
    }

    /// ISO-8601 UTC text, as the API sends dates.
    static func makeISO(_ d: Date) -> String { d.formatted(Date.ISO8601FormatStyle()) }

    static func makeEncoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }

    /// ISO-8601 with or without fractional seconds (any number of digits, .NET emits 7), with or without zone.
    static func parseDate(_ raw: String) -> Date? {
        var s = raw
        if let dot = s.firstIndex(of: ".") {
            // Normalise fractional seconds to 3 digits.
            var end = s.index(after: dot)
            while end < s.endIndex, s[end].isNumber { end = s.index(after: end) }
            let digits = s[s.index(after: dot)..<end]
            let ms = String((digits + "000").prefix(3))
            s = String(s[..<dot]) + "." + ms + String(s[end...])
        }
        let hasZone = s.hasSuffix("Z") || s.range(of: #"[+-]\d{2}:?\d{2}$"#, options: .regularExpression) != nil
        if !hasZone { s += "Z" }
        if let d = try? Date(s, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true)) { return d }
        if let d = try? Date(s, strategy: Date.ISO8601FormatStyle()) { return d }
        return nil
    }
}

/// Thin async JSON client for the Gimano REST API.
actor APIClient {
    let baseURL: URL
    private(set) var token: String?
    private let session: URLSession
    private let decoder = JSON.makeDecoder()
    private let encoder = JSON.makeEncoder()

    init(baseURL: URL, token: String?, timeout: TimeInterval = 8) {
        self.baseURL = baseURL
        self.token = token
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = timeout
        cfg.timeoutIntervalForResource = timeout * 2
        cfg.waitsForConnectivity = false
        self.session = URLSession(configuration: cfg)
    }

    func setToken(_ token: String?) { self.token = token }

    /// Signs contribution requests (X-Gimano-Ts / X-Gimano-Sig) once the pseudonym has a key.
    private(set) var signer: IdentityKeys?
    func setSigner(_ keys: IdentityKeys?) { signer = keys }

    /// Adds the signature headers when `path` is a signed endpoint (docs/identity-and-reputation.md §2).
    private func sign(_ req: inout URLRequest, method: String, path: String, body: Data?, now: Date = .now) {
        guard let signer, let url = req.url, SignedEndpoints.requiresSignature(method: method, path: path) else { return }
        let ts = SigningClock.fixedTs ?? Int64(now.timeIntervalSince1970)
        let canonical = Canonical.request(method: method, pathAndQuery: Canonical.pathAndQuery(of: url), ts: ts, body: body ?? Data())
        req.setValue(String(ts), forHTTPHeaderField: "X-Gimano-Ts")
        req.setValue(signer.sign(canonical), forHTTPHeaderField: "X-Gimano-Sig")
    }

    /// The request exactly as `perform` would send it (tests check the signature on it).
    func preparedRequest(method: String, path: String, query: [URLQueryItem] = [], body: Data?) -> URLRequest {
        var req = URLRequest(url: url(path, query: query))
        req.httpMethod = method
        req.httpBody = body
        sign(&req, method: method, path: path, body: body)
        return req
    }

    func url(_ path: String, query: [URLQueryItem] = []) -> URL {
        let relative = path.hasPrefix("/") ? String(path.dropFirst()) : path
        var c = URLComponents(url: baseURL.appendingPathComponent(relative), resolvingAgainstBaseURL: false)!
        if !query.isEmpty {
            c.queryItems = query
            // Foundation leaves "+" as-is, which servers read as a space ("6PH57VP3+PR" → "6PH57VP3 PR").
            c.percentEncodedQuery = c.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        }
        return c.url!
    }

    func get<T: Decodable & Sendable>(_ path: String, query: [URLQueryItem] = [], as: T.Type = T.self) async throws -> T {
        let data = try await perform(method: "GET", path: path, query: query, body: Optional<Data>.none)
        return try decode(data)
    }

    func send<T: Decodable & Sendable>(_ method: String, _ path: String, body: (some Encodable & Sendable)?, as: T.Type = T.self) async throws -> T {
        let payload = try body.map { try encoder.encode($0) }
        let data = try await perform(method: method, path: path, query: [], body: payload)
        return try decode(data)
    }

    func sendNoContent(_ method: String, _ path: String, body: (some Encodable & Sendable)?, authorization: String? = nil,
                       headers: [String: String] = [:]) async throws {
        let payload = try body.map { try encoder.encode($0) }
        _ = try await perform(method: method, path: path, query: [], body: payload, authorization: authorization, headers: headers)
    }

    /// A raw byte body and/or response (`application/octet-stream`, e.g. event short links). `authorization` overrides the
    /// bearer token (e.g. `Drop <writeToken>`); `anonymous` sends none (public reads).
    func raw(_ method: String, _ path: String, body: Data?, authorization: String? = nil, anonymous: Bool = false,
             headers: [String: String] = [:], accept: String = "application/json") async throws -> Data {
        try await perform(method: method, path: path, query: [], body: body, authorization: authorization, headers: headers,
                          contentType: "application/octet-stream", accept: accept, anonymous: anonymous)
    }

    func ping(_ path: String) async -> Bool {
        (try? await perform(method: "GET", path: path, query: [], body: nil)) != nil
    }

    /// `multipart/form-data` upload with byte progress (0…1).
    func upload<T: Decodable & Sendable>(_ path: String, fields: [String: String], file: Data, fileName: String, mimeType: String,
                                        progress: @escaping @Sendable (Double) -> Void) async throws -> T {
        let boundary = "gimano-\(UUID().uuidString)"
        var body = Data()
        for (k, v) in fields {
            body.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(k)\"\r\n\r\n\(v)\r\n".data(using: .utf8)!)
        }
        body.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"\(fileName)\"\r\nContent-Type: \(mimeType)\r\n\r\n".data(using: .utf8)!)
        body.append(file)
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)
        var req = URLRequest(url: url(path))
        req.httpMethod = "POST"
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue(AppLanguage.acceptLanguage, forHTTPHeaderField: "Accept-Language")
        if let token { req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        sign(&req, method: "POST", path: path, body: body)
        req.timeoutInterval = 120
        let delegate = UploadProgressDelegate(progress)
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.upload(for: req, from: body, delegate: delegate)
        } catch let e as URLError {
            throw APIError.transport(e)
        }
        guard let http = response as? HTTPURLResponse else { throw APIError.transport(URLError(.badServerResponse)) }
        guard (200..<300).contains(http.statusCode) else {
            throw APIError.http(status: http.statusCode, problem: try? decoder.decode(ProblemDetails.self, from: data))
        }
        progress(1)
        return try decode(data)
    }

    /// `multipart/form-data` with repeated fields and several files (appeals). The signature covers the whole body.
    func sendForm(_ method: String = "POST", _ path: String, fields: [(name: String, value: String)],
                  files: [MultipartForm.File]) async throws -> Data {
        let boundary = "gimano-\(UUID().uuidString)"
        let body = MultipartForm.body(boundary: boundary, fields: fields, files: files)
        var req = URLRequest(url: url(path))
        req.httpMethod = method
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue(AppLanguage.acceptLanguage, forHTTPHeaderField: "Accept-Language")
        if let token { req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        sign(&req, method: method, path: path, body: body)
        req.timeoutInterval = 120
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.upload(for: req, from: body)
        } catch let e as URLError {
            throw APIError.transport(e)
        }
        guard let http = response as? HTTPURLResponse else { throw APIError.transport(URLError(.badServerResponse)) }
        guard (200..<300).contains(http.statusCode) else {
            if http.statusCode == 409, !data.isEmpty { throw APIError.conflict(data) }
            throw APIError.http(status: http.statusCode, problem: try? decoder.decode(ProblemDetails.self, from: data))
        }
        return data
    }

    private func decode<T: Decodable>(_ data: Data) throws -> T {
        do {
            return try decoder.decode(T.self, from: data)
        } catch {
            throw APIError.decoding(String(describing: error))
        }
    }

    /// `authorization` overrides the bearer token (e.g. `Share <writeToken>`).
    private func perform(method: String, path: String, query: [URLQueryItem], body: Data?, authorization: String? = nil,
                         headers: [String: String] = [:], contentType: String = "application/json",
                         accept: String = "application/json", anonymous: Bool = false) async throws -> Data {
        var req = URLRequest(url: url(path, query: query))
        req.httpMethod = method
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        req.setValue(accept, forHTTPHeaderField: "Accept")
        if let body {
            req.httpBody = body
            req.setValue(contentType, forHTTPHeaderField: "Content-Type")
        }
        if let authorization { req.setValue(authorization, forHTTPHeaderField: "Authorization") }
        else if let token, !anonymous { req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        req.setValue(AppLanguage.acceptLanguage, forHTTPHeaderField: "Accept-Language")
        sign(&req, method: method, path: path, body: body)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: req)
        } catch let e as URLError {
            throw APIError.transport(e)
        }
        guard let http = response as? HTTPURLResponse else { throw APIError.transport(URLError(.badServerResponse)) }
        guard (200..<300).contains(http.statusCode) else {
            if http.statusCode == 409, !data.isEmpty { throw APIError.conflict(data) }
            var problem = try? decoder.decode(ProblemDetails.self, from: data)
            if http.statusCode == 429, problem?.retryAfterSeconds == nil,
               let s = ProblemDetails.retryAfter(header: http.value(forHTTPHeaderField: "Retry-After")) {
                if problem == nil { problem = ProblemDetails(status: 429) }
                problem?.retryAfterSeconds = s
            }
            throw APIError.http(status: http.statusCode, problem: problem)
        }
        return data
    }
}

/// Empty body / response helper.
struct Empty: Codable, Sendable {}

final class UploadProgressDelegate: NSObject, URLSessionTaskDelegate, Sendable {
    private let onProgress: @Sendable (Double) -> Void
    init(_ onProgress: @escaping @Sendable (Double) -> Void) { self.onProgress = onProgress }
    func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64, totalBytesSent: Int64,
                    totalBytesExpectedToSend: Int64) {
        guard totalBytesExpectedToSend > 0 else { return }
        onProgress(Double(totalBytesSent) / Double(totalBytesExpectedToSend))
    }
}
