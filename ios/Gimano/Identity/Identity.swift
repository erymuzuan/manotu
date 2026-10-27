import CryptoKit
import Foundation
import Security
import Sodium

/// Contributor identity (docs/identity-and-reputation.md): a random 32-byte seed → Ed25519 key pair.
/// The server only ever sees the public key, a random userId and an auto-generated pseudonym.
struct IdentityKeys: Sendable, Equatable {
    let seed: [UInt8]
    let publicKey: [UInt8]
    private let secretKey: [UInt8]

    init?(seed: [UInt8]) {
        guard seed.count == 32, let kp = Sodium().sign.keyPair(seed: seed) else { return nil }
        self.seed = seed
        self.publicKey = kp.publicKey
        self.secretKey = kp.secretKey
    }

    static func generate() -> IdentityKeys {
        IdentityKeys(seed: Sodium().randomBytes.buf(length: 32)!)!
    }

    var publicKeyBase64: String { Data(publicKey).base64EncodedString() }

    func sign(_ message: String) -> String {
        Data(Sodium().sign.signature(message: Bytes(message.utf8), secretKey: secretKey)!).base64EncodedString()
    }

    static func == (a: IdentityKeys, b: IdentityKeys) -> Bool { a.seed == b.seed }
}

/// The exact strings the server verifies (§7–8).
enum Canonical {
    static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// `GIMANO1\n<METHOD>\n<path?query as sent>\n<ts>\n<hex sha256(body)>`
    static func request(method: String, pathAndQuery: String, ts: Int64, body: Data) -> String {
        "GIMANO1\n\(method.uppercased())\n\(pathAndQuery)\n\(ts)\n\(sha256Hex(body))"
    }

    /// `POST /auth/token` (userId lower-case, "D" format).
    static func auth(userId: String, ts: Int64) -> String { "GIMANO-AUTH\n\(userId.lowercased())\n\(ts)" }

    /// `POST /auth/token {publicKey, ts, sig}`: sign-in by key (recovery-code restore).
    static func keyLogin(publicKeyBase64: String, ts: Int64) -> String { "GIMANO1-LOGIN\n\(publicKeyBase64)\n\(ts)" }

    /// `POST /me/keys` rotation, signed with the current key.
    static func keyRotation(userId: String, newPublicKeyBase64: String) -> String {
        "GIMANO-KEY\n\(userId.lowercased())\n\(newPublicKeyBase64)"
    }

    /// App Attest client data for a vote.
    static func attestClientData(placeId: String, ts: Int64) -> String { "GIMANO-ATTEST\n\(placeId)\n\(ts)" }

    /// The request target exactly as it goes on the request line.
    static func pathAndQuery(of url: URL) -> String {
        let c = URLComponents(url: url, resolvingAgainstBaseURL: true)
        let path = c?.percentEncodedPath.isEmpty == false ? c!.percentEncodedPath : "/"
        if let q = c?.percentEncodedQuery, !q.isEmpty { return "\(path)?\(q)" }
        return path
    }
}

/// Contribution endpoints that need `X-Gimano-Ts` / `X-Gimano-Sig` (§2). `path` is relative to the API base
/// (e.g. `places/abc/verify`), without the query.
enum SignedEndpoints {
    static func requiresSignature(method: String, path: String) -> Bool {
        let p = path.split(separator: "?").first.map(String.init) ?? path
        let s = p.split(separator: "/").map(String.init)
        switch (method.uppercased(), s.count) {
        case ("POST", 1): return s[0] == "places" || s[0] == "photos" || s[0] == "reports" || s[0] == "issues" || s[0] == "appeals"
        case ("PATCH", 2): return s[0] == "places" || s[0] == "reviews"
        case ("DELETE", 2): return s[0] == "reviews" || s[0] == "reports"
        case ("POST", 3):
            return (s[0] == "places" && ["verify", "suggest-edit", "reviews", "appeal"].contains(s[2])) || (s[0] == "reports" && s[2] == "votes")
                || (s[0] == "issues" && s[2] == "votes")
                // Content-safety appeals (docs/content-safety.md): signed like the place appeal.
                || ((s[0] == "reviews" || s[0] == "photos") && s[2] == "appeal")
        default: return false
        }
    }
}

/// BIP-39 (English) encoding of the 32-byte seed: 24 words, last word carries an 8-bit SHA-256 checksum.
enum RecoveryCode {
    static let words: [String] = {
        guard let url = Bundle.main.url(forResource: "bip39-english", withExtension: "txt")
                ?? Bundle(for: BundleToken.self).url(forResource: "bip39-english", withExtension: "txt"),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return text.split(whereSeparator: \.isNewline).map(String.init)
    }()
    private final class BundleToken {}

    enum Failure: Error, Equatable { case wordCount, unknownWord(String), checksum }

    static func encode(_ entropy: [UInt8]) -> [String] {
        precondition(entropy.count == 32 && words.count == 2048)
        let checksum = Array(SHA256.hash(data: Data(entropy)))[0]
        let bits = (entropy + [checksum]).flatMap { byte in (0..<8).reversed().map { (byte >> $0) & 1 } }
        return stride(from: 0, to: 264, by: 11).map { i in
            words[bits[i..<i + 11].reduce(0) { $0 << 1 | Int($1) }]
        }
    }

    static func decode(_ phrase: String) throws -> [UInt8] {
        let list = phrase.lowercased().split(whereSeparator: { $0.isWhitespace || $0 == "," }).map(String.init)
        guard list.count == 24 else { throw Failure.wordCount }
        var bits: [UInt8] = []
        for w in list {
            guard let i = words.firstIndex(of: w) else { throw Failure.unknownWord(w) }
            bits += (0..<11).reversed().map { UInt8((i >> $0) & 1) }
        }
        var bytes = stride(from: 0, to: 264, by: 8).map { i in bits[i..<i + 8].reduce(UInt8(0)) { $0 << 1 | $1 } }
        let checksum = bytes.removeLast()
        guard Array(SHA256.hash(data: Data(bytes)))[0] == checksum else { throw Failure.checksum }
        return bytes
    }
}

/// Wraps the seed at rest with a device-only Keychain key (never synced, never in backups).
enum SeedVault {
    static let prefix = "kc1:"
    private static let account = "identity.wrapKey"

    private static func wrapKey() -> [UInt8] {
        if let s = Keychain.get(account), let d = Data(base64Encoded: s), d.count == 32 { return Bytes(d) }
        let k = Sodium().secretBox.key()
        Keychain.set(Data(k).base64EncodedString(), for: account, accessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly)
        return k
    }

    static func wrap(_ seed: [UInt8]) -> String {
        let s = Sodium()
        let sealed: Bytes = s.secretBox.seal(message: seed, secretKey: wrapKey())!
        return prefix + Data(sealed).base64EncodedString()
    }

    /// Accepts a wrapped value or a raw base64 seed (as found in backups, from either platform).
    static func unwrap(_ stored: String) -> [UInt8]? {
        if stored.hasPrefix(prefix) {
            guard let d = Data(base64Encoded: String(stored.dropFirst(prefix.count))) else { return nil }
            let seed = Sodium().secretBox.open(nonceAndAuthenticatedCipherText: Bytes(d), secretKey: wrapKey())
            return seed?.count == 32 ? seed : nil
        }
        guard let d = Data(base64Encoded: stored), d.count == 32 else { return nil }
        return Bytes(d)
    }
}

/// The `identity` row (single row).
struct StoredIdentity: Sendable, Equatable {
    var userId: String
    var displayName: String?
    var keys: IdentityKeys
    var createdAt: String
}
