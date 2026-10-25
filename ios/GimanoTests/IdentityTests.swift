import Foundation
import GRDB
import Testing
import ZIPFoundation
@testable import Gimano

private func hex(_ s: String) -> [UInt8] {
    stride(from: 0, to: s.count, by: 2).map { i in
        UInt8(s[s.index(s.startIndex, offsetBy: i)..<s.index(s.startIndex, offsetBy: i + 2)], radix: 16)!
    }
}

private func freshStore() throws -> LocalStore {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("id-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return try LocalStore(path: dir.appendingPathComponent("db.sqlite").path, photosDirectory: dir.appendingPathComponent("photos"))
}

/// docs/identity-and-reputation.md §8: the server's SignatureVectorTests check the same values.
@Suite("Identity: keys and signature vectors")
struct IdentityVectorTests {
    let keys = IdentityKeys(seed: hex("000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f"))!

    @Test("Seed → Ed25519 public key")
    func publicKey() {
        #expect(keys.publicKey == hex("03a107bff3ce10be1d70dd18e74bc09967e4d6309ba50d5f1ddc8664125531b8"))
        #expect(keys.publicKeyBase64 == "A6EHv/POEL4dcN0Y50vAmWfk1jCbpQ1fHdyGZBJVMbg=")
    }

    @Test("Request 1: POST verify")
    func request1() {
        let body = Data(#"{"answer":"yes","nameCorrect":true,"locationCorrect":true,"proximity":{"cell":"w283f8","withinM":420}}"#.utf8)
        #expect(Canonical.sha256Hex(body) == "6c091ee7b6a05d273cedfd0ada1a4a1c113a2ef99a1ed14c35f8d87f36019821")
        let c = Canonical.request(method: "POST", pathAndQuery: "/api/v1/places/c01a166b7f9c67924976aff1beb56c2cd/verify", ts: 1792713600, body: body)
        #expect(c == "GIMANO1\nPOST\n/api/v1/places/c01a166b7f9c67924976aff1beb56c2cd/verify\n1792713600\n6c091ee7b6a05d273cedfd0ada1a4a1c113a2ef99a1ed14c35f8d87f36019821")
        #expect(keys.sign(c) == "CPm5nQ7WU1z/tiBHSciXop7u2uc/M6Rt4/AgExSarydCkuW1iUQ99XT+gFyonROf7816WI+u2h901BueYupVAQ==")
    }

    @Test("Request 2: DELETE with an empty body")
    func request2() {
        #expect(Canonical.sha256Hex(Data()) == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        let c = Canonical.request(method: "delete", pathAndQuery: "/api/v1/reviews/01a16676-ce9e-78db-842e-55ffa03ef190", ts: 1792713600, body: Data())
        #expect(keys.sign(c) == "62H79zlWTyZDvgEzOFxiHLBA29cFklC0eto7hkBYoWdsgHaoXp54+ygVAvS7hyS/38WD2XYwOK+XQr6RE4B+Cw==")
    }

    @Test("Request 3: query string is part of the target")
    func request3() throws {
        let body = Data(#"{"type":"hazard","subtype":"pothole","lat":3.118,"lng":101.619,"heading":90}"#.utf8)
        #expect(Canonical.sha256Hex(body) == "e7880fafa70c2dcc331adee63b54a5c4362d39a02d0ec08341d7ac06b9713980")
        let url = try #require(URL(string: "https://gimano-api.bukitbunga.com/api/v1/reports?source=app"))
        #expect(Canonical.pathAndQuery(of: url) == "/api/v1/reports?source=app")
        let c = Canonical.request(method: "POST", pathAndQuery: Canonical.pathAndQuery(of: url), ts: 1792713601, body: body)
        #expect(keys.sign(c) == "CVlQVQXZSUEbSZDJ3pEkhmeAKHgPbZh2MyAkEwcTXo9C5d+drAlcNC2X7zdrBBXfSAJN9jq3VQo+ukoTiRLJDw==")
    }

    @Test("Signature login, key rotation and attestation client data")
    func authRotationAttest() {
        let auth = Canonical.auth(userId: "01A16676-0000-7000-8000-000000000001", ts: 1792713600)
        #expect(auth == "GIMANO-AUTH\n01a16676-0000-7000-8000-000000000001\n1792713600")
        #expect(keys.sign(auth) == "aApOheYmDSVKSLICJI8tuRW9Cp06hzkHJQKwdLab1N5sYCPAwvKFum8s+fnw6+6QsktcXji/+OLZzEQqijW+Cw==")
        let next = IdentityKeys(seed: hex("202122232425262728292a2b2c2d2e2f303132333435363738393a3b3c3d3e3f"))!
        #expect(next.publicKeyBase64 == "Kay64UG8yvCyLhqU000LxzYeUm0L/hLIl5S8kyKWbdc=")
        let rot = Canonical.keyRotation(userId: "01a16676-0000-7000-8000-000000000001", newPublicKeyBase64: next.publicKeyBase64)
        #expect(keys.sign(rot) == "y+8fzyom8LvtpxVQGE3Hebps7dovTSlGQYQhrgqO8hAekGT4pX0PXw282mqNZc8vMCOtLmmwfDbgVqlBKYsBDg==")
        let att = Canonical.attestClientData(placeId: "c01a166b7f9c67924976aff1beb56c2cd", ts: 1792713600)
        #expect(Canonical.sha256Hex(Data(att.utf8)) == "ff664bac6820f2ce7bb5823ae9a2b33b103e47bca5bb6aa4ec11af46a9aa78be")
    }

    @Test("Sign-in by public key (recovery-code restore)")
    func keyLogin() {
        let c = Canonical.keyLogin(publicKeyBase64: keys.publicKeyBase64, ts: 1792713600)
        #expect(c == "GIMANO1-LOGIN\nA6EHv/POEL4dcN0Y50vAmWfk1jCbpQ1fHdyGZBJVMbg=\n1792713600")
        #expect(keys.sign(c) == "61uR1jjsZqzZb7I0Oq3t0ZgVkyxeyutovBXfKWH9GvedLaFb2TzIXtKuotj9CgnRf6njJJDUBOwf6yy3ZkfFDQ==")
    }

    @Test("Signed endpoints match §2 exactly")
    func signedEndpoints() {
        let yes: [(String, String)] = [("POST", "places"), ("PATCH", "places/c1"), ("POST", "places/c1/verify"),
                                       ("POST", "places/c1/suggest-edit"), ("POST", "places/c1/reviews"), ("PATCH", "reviews/r1"),
                                       ("DELETE", "reviews/r1"), ("POST", "photos"), ("POST", "reports"), ("POST", "reports/r1/votes"), ("DELETE", "reports/r1"),
                                       ("POST", "reports?source=app")]
        let no: [(String, String)] = [("GET", "places/c1"), ("DELETE", "places/c1"), ("POST", "reviews/r1/helpful"),
                                      ("POST", "reviews/r1/flag"), ("POST", "feedback"), ("POST", "locations"), ("GET", "me"),
                                      ("POST", "reports/r1/thanks"), ("POST", "shares"), ("POST", "auth/register")]
        for (m, p) in yes { #expect(SignedEndpoints.requiresSignature(method: m, path: p), "\(m) \(p)") }
        for (m, p) in no { #expect(!SignedEndpoints.requiresSignature(method: m, path: p), "\(m) \(p)") }
    }
}

@Suite("Identity: recovery code (BIP-39)")
struct RecoveryCodeTests {
    @Test("Wordlist is the canonical BIP-39 English list")
    func wordlist() {
        #expect(RecoveryCode.words.count == 2048)
        #expect(RecoveryCode.words.first == "abandon" && RecoveryCode.words.last == "zoo")
    }

    @Test("Official BIP-39 vectors (256-bit entropy)")
    func vectors() throws {
        let zero = RecoveryCode.encode([UInt8](repeating: 0, count: 32))
        #expect(zero == Array(repeating: "abandon", count: 23) + ["art"])
        let sevenF = RecoveryCode.encode([UInt8](repeating: 0x7f, count: 32))
        #expect(sevenF.joined(separator: " ") == "legal winner thank year wave sausage worth useful legal winner thank year wave sausage worth useful legal winner thank year wave sausage worth title")
        let mixed = RecoveryCode.encode(hex("68a79eaca2324873eacc50cb9c6eca8cc68ea5d936f98787c60c7ebc74e6ce7c"))
        #expect(mixed.joined(separator: " ") == "hamster diagram private dutch cause delay private meat slide toddler razor book happy fancy gospel tennis maple dilemma loan word shrug inflict delay length")
    }

    @Test("Round trip, typos and checksum errors")
    func roundTrip() throws {
        let seed = IdentityKeys.generate().seed
        let words = RecoveryCode.encode(seed)
        #expect(try RecoveryCode.decode(words.joined(separator: "  ").uppercased()) == seed)
        #expect(throws: RecoveryCode.Failure.wordCount) { try RecoveryCode.decode("abandon abandon") }
        #expect(throws: RecoveryCode.Failure.unknownWord("abandonn")) { try RecoveryCode.decode((["abandonn"] + Array(words.dropFirst())).joined(separator: " ")) }
        var swapped = words
        swapped.swapAt(0, 1)
        if swapped != words { #expect(throws: RecoveryCode.Failure.checksum) { try RecoveryCode.decode(swapped.joined(separator: " ")) } }
    }
}

@Suite("Identity: storage and backup")
struct IdentityStorageTests {
    @Test("Seed is wrapped at rest (Keychain key), never stored raw")
    func wrappedAtRest() throws {
        let store = try freshStore()
        let keys = IdentityKeys.generate()
        try store.saveIdentity(StoredIdentity(userId: "01A16676-0000-7000-8000-000000000001", displayName: "Rusa 2368", keys: keys, createdAt: LocalStore.timestamp()))
        let raw = try store.dbQueue.read { db in try String.fetchOne(db, sql: "SELECT seed_b64 FROM identity") }
        #expect(raw?.hasPrefix(SeedVault.prefix) == true)
        #expect(raw?.contains(Data(keys.seed).base64EncodedString()) == false)
        let loaded = try #require(try store.identity())
        #expect(loaded.keys == keys && loaded.userId == "01a16676-0000-7000-8000-000000000001" && loaded.displayName == "Rusa 2368")
    }

    @Test("Backup carries the raw seed (portable); restore re-wraps it and restores the pseudonym")
    func backupRoundTrip() throws {
        let src = try freshStore()
        let keys = IdentityKeys.generate()
        try src.saveIdentity(StoredIdentity(userId: "u-1", displayName: "Rusa 2368", keys: keys, createdAt: "2026-10-23T00:00:00.000Z"))
        let file = try BackupService(store: src, kdfLimits: .interactive).makeBackup()

        // Inside the backup: raw base64 seed, the Android-compatible form.
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("unz-\(UUID().uuidString)")
        try FileManager.default.unzipItem(at: file, to: tmp)
        let snap = try DatabaseQueue(path: tmp.appendingPathComponent("data.sqlite").path)
        let inBackup = try snap.read { db in try String.fetchOne(db, sql: "SELECT seed_b64 FROM identity") }
        #expect(inBackup == Data(keys.seed).base64EncodedString())
        #expect(try snap.read { db in try Int.fetchOne(db, sql: "PRAGMA user_version") } == LocalStore.schemaVersion)

        // A new phone already registered a fresh pseudonym; restoring brings back the old one.
        let dst = try freshStore()
        try dst.saveIdentity(StoredIdentity(userId: "u-new", displayName: "Badak 1", keys: IdentityKeys.generate(), createdAt: LocalStore.timestamp()))
        try BackupService(store: dst).restore(file, mode: .merge)
        let restored = try #require(try dst.identity())
        #expect(restored.userId == "u-1" && restored.keys == keys && restored.displayName == "Rusa 2368")
        let atRest = try dst.dbQueue.read { db in try String.fetchOne(db, sql: "SELECT seed_b64 FROM identity") }
        #expect(atRest?.hasPrefix(SeedVault.prefix) == true)
    }

    @Test("An Android-made schema-v2 snapshot with a raw identity restores on iOS")
    func androidSnapshot() throws {
        // Build a snapshot the way Android does: the shared DDL, user_version 2, raw base64 seed, platform android.
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("android-\(UUID().uuidString)")
        let payload = dir.appendingPathComponent("payload")
        try FileManager.default.createDirectory(at: payload, withIntermediateDirectories: true)
        let db = try DatabaseQueue(path: payload.appendingPathComponent("data.sqlite").path)
        let seed = hex("000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f")
        try db.write { db in
            try db.execute(sql: LocalStore.schemaV1)
            try db.execute(sql: LocalStore.schemaV2)
            try db.execute(sql: "DROP TABLE outbox")
            try db.execute(sql: "INSERT INTO identity VALUES ('01a16676-0000-7000-8000-000000000001', 'Rusa 2368', ?, '2026-10-20T01:00:00.000Z')",
                           arguments: [Data(seed).base64EncodedString()])
            try db.execute(sql: "INSERT INTO saved_places (id, kind, name, icon, lat, lng, created_at, updated_at) VALUES ('h', 'home', 'Rumah', 'home', 3.1, 101.6, '2026-10-20T01:00:00.000Z', '2026-10-20T01:00:00.000Z')")
            try db.execute(sql: "PRAGMA user_version = 2")
        }
        try db.close()
        let manifest = #"{"format":1,"schemaVersion":2,"appVersion":"0.2.0","platform":"android","createdAt":"2026-10-20T01:00:00.000Z","counts":{"saved_places":1},"encryption":"none"}"#
        try Data(manifest.utf8).write(to: payload.appendingPathComponent("manifest.json"))
        let file = dir.appendingPathComponent("gimano-android.gimano")
        try FileManager.default.zipItem(at: payload, to: file, shouldKeepParent: false)

        let dst = try freshStore()
        try BackupService(store: dst).restore(file, mode: .replace)
        let id = try #require(try dst.identity())
        #expect(id.keys.publicKeyBase64 == "A6EHv/POEL4dcN0Y50vAmWfk1jCbpQ1fHdyGZBJVMbg=")
        #expect(id.userId == "01a16676-0000-7000-8000-000000000001")
        #expect(try dst.savedPlaces().count == 1)
    }

    @Test("A v1 backup (no identity table) still restores and keeps the current pseudonym")
    func v1Backup() throws {
        let src = try freshStore()
        let file = try BackupService(store: src, kdfLimits: .interactive).makeBackup()
        // Simulate an old v1 file: drop the identity table from the snapshot and set user_version 1.
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("v1-\(UUID().uuidString)")
        try FileManager.default.unzipItem(at: file, to: tmp)
        let snap = try DatabaseQueue(path: tmp.appendingPathComponent("data.sqlite").path)
        try snap.writeWithoutTransaction { db in
            try db.execute(sql: "DROP TABLE identity")
            try db.execute(sql: "DROP TABLE personal_routes")   // schema 3
            try db.execute(sql: "PRAGMA user_version = 1")
        }
        try snap.close()
        var m = try JSONSerialization.jsonObject(with: Data(contentsOf: tmp.appendingPathComponent("manifest.json"))) as! [String: Any]
        m["schemaVersion"] = 1
        try JSONSerialization.data(withJSONObject: m).write(to: tmp.appendingPathComponent("manifest.json"))
        let v1 = FileManager.default.temporaryDirectory.appendingPathComponent("v1-\(UUID().uuidString).gimano")
        try FileManager.default.zipItem(at: tmp, to: v1, shouldKeepParent: false)

        let dst = try freshStore()
        let mine = IdentityKeys.generate()
        try dst.saveIdentity(StoredIdentity(userId: "me", displayName: nil, keys: mine, createdAt: LocalStore.timestamp()))
        try BackupService(store: dst).restore(v1, mode: .replace)
        #expect(try dst.identity()?.keys == mine)
    }
}

@Suite("Identity: signing layer")
struct SigningLayerTests {
    @Test("APIClient signs only contribution endpoints, over the exact target and body")
    func signsRequests() async throws {
        let keys = IdentityKeys(seed: hex("000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f"))!
        let client = APIClient(baseURL: URL(string: "https://gimano-api.bukitbunga.com/api/v1/")!, token: "t")
        await client.setSigner(keys)
        let body = Data(#"{"answer":"yes","nameCorrect":true,"locationCorrect":true,"proximity":{"cell":"w283f8","withinM":420}}"#.utf8)
        let req = await client.preparedRequest(method: "POST", path: "places/c01a166b7f9c67924976aff1beb56c2cd/verify", body: body)
        let ts = try #require(req.value(forHTTPHeaderField: "X-Gimano-Ts").flatMap { Int64($0) })
        #expect(abs(Double(ts) - Date().timeIntervalSince1970) < 5)
        let expected = keys.sign(Canonical.request(method: "POST", pathAndQuery: "/api/v1/places/c01a166b7f9c67924976aff1beb56c2cd/verify", ts: ts, body: body))
        #expect(req.value(forHTTPHeaderField: "X-Gimano-Sig") == expected)
        let get = await client.preparedRequest(method: "GET", path: "places/c01", body: nil)
        #expect(get.value(forHTTPHeaderField: "X-Gimano-Sig") == nil)
        let feedback = await client.preparedRequest(method: "POST", path: "feedback", body: Data("{}".utf8))
        #expect(feedback.value(forHTTPHeaderField: "X-Gimano-Sig") == nil)
    }
}
