import Foundation
import GRDB
import Sodium
import ZIPFoundation

/// `.gimano` backup, format v1 (docs/privacy-and-backup.md).
///
/// Unencrypted:  zip { manifest.json, data.sqlite, photos/*.webp }
/// Encrypted:    zip { manifest.json, payload.enc }, where payload.enc =
///               crypto_secretstream_xchacha20poly1305( zip { data.sqlite, photos/*.webp } )
///               - key: crypto_pwhash Argon2id13 (32 bytes), salt/opslimit/memlimit in manifest.kdf
///               - stream: 24-byte header, then chunks of 65 536 plaintext bytes (+17 bytes each),
///                 every chunk tagged MESSAGE except the last, tagged FINAL.
struct BackupManifest: Codable, Equatable, Sendable {
    struct KDF: Codable, Equatable, Sendable {
        var alg: String = "argon2id13"
        var opslimit: Int
        var memlimit: Int
        /// Base64 salt (crypto_pwhash_SALTBYTES = 16).
        var salt: String
        var chunkSize: Int = BackupCrypto.chunkSize
    }

    var format: Int = 1
    var schemaVersion: Int
    var appVersion: String
    var platform: String
    var createdAt: String
    var counts: [String: Int]
    var encryption: String
    var kdf: KDF?

    static let encryptionNone = "none"
    static let encryptionPassphrase = "passphrase-argon2id-xchacha20poly1305"
}

enum BackupError: LocalizedError, Equatable {
    case notABackup
    case unsupportedFormat(Int)
    case newerSchema(Int)
    case passphraseRequired
    case wrongPassphrase
    case corrupt

    var errorDescription: String? {
        switch self {
        case .notABackup: String(localized: "This file isn't a Gimano backup.")
        case .unsupportedFormat(let v): String(localized: "Unsupported backup format \(v).")
        case .newerSchema: String(localized: "This backup was made by a newer version of Gimano. Update the app first.")
        case .passphraseRequired: String(localized: "This backup is protected with a passphrase.")
        case .wrongPassphrase: String(localized: "Wrong passphrase.")
        case .corrupt: String(localized: "The backup file is damaged.")
        }
    }
}

enum RestoreMode: String, CaseIterable, Sendable {
    /// Wipe local personal data, then import.
    case replace
    /// Upsert by id keeping the newer `updated_at`; Home/Work come from the backup.
    case merge
}

/// libsodium encryption shared with Android (lazysodium): Argon2id + secretstream xchacha20poly1305.
enum BackupCrypto {
    static let chunkSize = 65_536

    struct Limits: Sendable {
        var opslimit: Int
        var memlimit: Int
        /// The doc's "moderate" limits (crypto_pwhash_OPSLIMIT_MODERATE / MEMLIMIT_MODERATE).
        static var moderate: Limits {
            let s = Sodium()
            return Limits(opslimit: s.pwHash.OpsLimitModerate, memlimit: s.pwHash.MemLimitModerate)
        }
        /// Fast limits for unit tests only.
        static var interactive: Limits {
            let s = Sodium()
            return Limits(opslimit: s.pwHash.OpsLimitInteractive, memlimit: s.pwHash.MemLimitInteractive)
        }
    }

    static func deriveKey(passphrase: String, salt: Bytes, opslimit: Int, memlimit: Int) throws -> Bytes {
        let s = Sodium()
        guard let key = s.pwHash.hash(outputLength: s.secretStream.xchacha20poly1305.KeyBytes, passwd: Array(passphrase.utf8),
                                      salt: salt, opsLimit: opslimit, memLimit: memlimit, alg: .Argon2ID13) else { throw BackupError.corrupt }
        return key
    }

    /// Encrypts `input` file to `output`; returns the KDF parameters to put in the manifest.
    static func encrypt(_ input: URL, to output: URL, passphrase: String, limits: Limits) throws -> BackupManifest.KDF {
        let s = Sodium()
        let salt = s.randomBytes.buf(length: s.pwHash.SaltBytes)!
        let key = try deriveKey(passphrase: passphrase, salt: salt, opslimit: limits.opslimit, memlimit: limits.memlimit)
        guard let stream = s.secretStream.xchacha20poly1305.initPush(secretKey: key) else { throw BackupError.corrupt }
        let data = try Data(contentsOf: input)
        var out = Data(stream.header())
        var offset = 0
        repeat {
            let end = min(offset + chunkSize, data.count)
            let isLast = end == data.count
            guard let c = stream.push(message: Bytes(data[offset..<end]), tag: isLast ? .FINAL : .MESSAGE) else { throw BackupError.corrupt }
            out.append(contentsOf: c)
            offset = end
        } while offset < data.count
        try out.write(to: output)
        return BackupManifest.KDF(opslimit: limits.opslimit, memlimit: limits.memlimit, salt: Data(salt).base64EncodedString())
    }

    static func decrypt(_ input: URL, to output: URL, passphrase: String, kdf: BackupManifest.KDF) throws {
        let s = Sodium()
        guard let salt = Data(base64Encoded: kdf.salt) else { throw BackupError.corrupt }
        let key = try deriveKey(passphrase: passphrase, salt: Bytes(salt), opslimit: kdf.opslimit, memlimit: kdf.memlimit)
        let data = try Data(contentsOf: input)
        let headerBytes = SecretStream.XChaCha20Poly1305.HeaderBytes
        guard data.count >= headerBytes,
              let stream = s.secretStream.xchacha20poly1305.initPull(secretKey: key, header: Bytes(data.prefix(headerBytes))) else {
            throw BackupError.corrupt
        }
        let cipherChunk = kdf.chunkSize + SecretStream.XChaCha20Poly1305.ABytes
        var out = Data()
        var offset = headerBytes
        var finished = false
        while offset < data.count {
            let end = min(offset + cipherChunk, data.count)
            // A wrong key fails authentication on the very first chunk.
            guard let (plain, tag) = stream.pull(cipherText: Bytes(data[offset..<end])) else {
                throw offset == headerBytes ? BackupError.wrongPassphrase : BackupError.corrupt
            }
            out.append(contentsOf: plain)
            offset = end
            if tag == .FINAL { finished = true; break }
        }
        guard finished, offset == data.count else { throw BackupError.corrupt }
        try out.write(to: output)
    }
}

/// Creates and restores `.gimano` files for a `LocalStore`.
struct BackupService: Sendable {
    let store: LocalStore
    var kdfLimits: BackupCrypto.Limits = .moderate

    static var appVersion: String {
        let i = Bundle.main.infoDictionary
        return "\(i?["CFBundleShortVersionString"] as? String ?? "0") (\(i?["CFBundleVersion"] as? String ?? "0"))"
    }

    private func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("gimano-backup-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Writes a backup file and returns its URL (in a temporary directory).
    func makeBackup(passphrase: String? = nil, now: Date = .now) throws -> URL {
        let fm = FileManager.default
        let work = try tempDir()
        let payloadDir = work.appendingPathComponent("payload", isDirectory: true)
        try fm.createDirectory(at: payloadDir, withIntermediateDirectories: true)

        // 1. Consistent compact snapshot without the device-local outbox.
        let snapshot = payloadDir.appendingPathComponent("data.sqlite")
        try store.dbQueue.writeWithoutTransaction { db in
            try db.execute(sql: "VACUUM INTO ?", arguments: [snapshot.path])
        }
        let rawIdentity = try store.identity()
        let snap = try DatabaseQueue(path: snapshot.path)
        try snap.writeWithoutTransaction { db in
            try db.execute(sql: "DROP TABLE IF EXISTS outbox")
            // Refused public content and device flags never leave the phone (not even in the user's own backup).
            try db.execute(sql: "DROP TABLE IF EXISTS refused_content")
            try db.execute(sql: "DROP TABLE IF EXISTS device_state")
            // The seed leaves this phone only inside the user's own backup, as a raw base64 seed (portable across
            // platforms); the backup's passphrase encryption is what protects it.
            if let rawIdentity {
                try db.execute(sql: "UPDATE identity SET seed_b64 = ? WHERE user_id = ?",
                               arguments: [Data(rawIdentity.keys.seed).base64EncodedString(), rawIdentity.userId])
            }
            try db.execute(sql: "PRAGMA user_version = \(LocalStore.schemaVersion)")
            try db.execute(sql: "VACUUM")
        }
        try snap.close()

        // 2. Photos referenced by private places.
        let photoNames = try store.dbQueue.read { db in try String.fetchAll(db, sql: "SELECT file_name FROM private_place_photos") }
        let photosOut = payloadDir.appendingPathComponent("photos", isDirectory: true)
        try fm.createDirectory(at: photosOut, withIntermediateDirectories: true)
        for name in photoNames {
            let src = store.photosDirectory.appendingPathComponent((name as NSString).lastPathComponent)
            if fm.fileExists(atPath: src.path) {
                try fm.copyItem(at: src, to: photosOut.appendingPathComponent(src.lastPathComponent))
            }
        }

        var manifest = BackupManifest(schemaVersion: LocalStore.schemaVersion, appVersion: Self.appVersion, platform: "ios",
                                      createdAt: LocalStore.timestamp(now), counts: try store.counts(),
                                      encryption: BackupManifest.encryptionNone, kdf: nil)

        let stamp = now.formatted(Date.ISO8601FormatStyle().year().month().day()) + "-" + String(Int(now.timeIntervalSince1970) % 100_000)
        // Manotu (formerly Gimano): new backups are .manotu; .gimano files still import (same format).
        let output = work.appendingPathComponent("manotu-backup-\(stamp).manotu")
        let archive = try Archive(url: output, accessMode: .create)

        if let passphrase, !passphrase.isEmpty {
            let inner = work.appendingPathComponent("inner.zip")
            let innerArchive = try Archive(url: inner, accessMode: .create)
            try Self.addDirectory(payloadDir, to: innerArchive)
            let enc = work.appendingPathComponent("payload.enc")
            manifest.kdf = try BackupCrypto.encrypt(inner, to: enc, passphrase: passphrase, limits: kdfLimits)
            manifest.encryption = BackupManifest.encryptionPassphrase
            try Self.addData(try Self.encode(manifest), path: "manifest.json", to: archive)
            try archive.addEntry(with: "payload.enc", fileURL: enc, compressionMethod: .none)
        } else {
            try Self.addData(try Self.encode(manifest), path: "manifest.json", to: archive)
            try Self.addDirectory(payloadDir, to: archive)
        }
        return output
    }

    /// Reads the manifest without decrypting.
    static func readManifest(_ url: URL) throws -> BackupManifest {
        guard let archive = try? Archive(url: url, accessMode: .read), let entry = archive["manifest.json"] else { throw BackupError.notABackup }
        var data = Data()
        _ = try archive.extract(entry) { data.append($0) }
        guard let m = try? JSONDecoder().decode(BackupManifest.self, from: data) else { throw BackupError.notABackup }
        return m
    }

    /// Restores a backup file into the store.
    @discardableResult
    func restore(_ url: URL, mode: RestoreMode, passphrase: String? = nil) throws -> BackupManifest {
        let fm = FileManager.default
        let manifest = try Self.readManifest(url)
        guard manifest.format == 1 else { throw BackupError.unsupportedFormat(manifest.format) }
        guard manifest.schemaVersion <= LocalStore.schemaVersion else { throw BackupError.newerSchema(manifest.schemaVersion) }

        let work = try tempDir()
        defer { try? fm.removeItem(at: work) }
        let unpacked = work.appendingPathComponent("unpacked", isDirectory: true)
        try fm.unzipItem(at: url, to: unpacked)
        var payload = unpacked
        if manifest.encryption == BackupManifest.encryptionPassphrase {
            guard let passphrase, !passphrase.isEmpty else { throw BackupError.passphraseRequired }
            guard let kdf = manifest.kdf else { throw BackupError.corrupt }
            let inner = work.appendingPathComponent("inner.zip")
            try BackupCrypto.decrypt(unpacked.appendingPathComponent("payload.enc"), to: inner, passphrase: passphrase, kdf: kdf)
            payload = work.appendingPathComponent("inner", isDirectory: true)
            try fm.unzipItem(at: inner, to: payload)
        }
        let snapshot = payload.appendingPathComponent("data.sqlite")
        guard fm.fileExists(atPath: snapshot.path) else { throw BackupError.corrupt }

        // Bring older snapshots up to the current schema on the temp copy.
        let snap = try DatabaseQueue(path: snapshot.path)
        try LocalStore.migrate(snap)
        try snap.close()

        try Self.importRows(from: snapshot, into: store, mode: mode)

        // Photos
        if mode == .replace {
            try? fm.removeItem(at: store.photosDirectory)
            try fm.createDirectory(at: store.photosDirectory, withIntermediateDirectories: true)
        }
        let photos = payload.appendingPathComponent("photos", isDirectory: true)
        if let names = try? fm.contentsOfDirectory(atPath: photos.path) {
            for n in names {
                let dst = store.photosDirectory.appendingPathComponent(n)
                if !fm.fileExists(atPath: dst.path) { try fm.copyItem(at: photos.appendingPathComponent(n), to: dst) }
            }
        }
        return manifest
    }

    /// Copies rows from a snapshot DB (same schema) into the store.
    static func importRows(from snapshot: URL, into store: LocalStore, mode: RestoreMode) throws {
        try store.dbQueue.writeWithoutTransaction { db in
            try db.execute(sql: "ATTACH DATABASE ? AS b", arguments: [snapshot.path])
            defer { try? db.execute(sql: "DETACH DATABASE b") }
            try db.inTransaction {
                func cols(_ t: String) throws -> String {
                    try Row.fetchAll(db, sql: "PRAGMA main.table_info(\(t))").map { $0["name"] as String }.joined(separator: ", ")
                }
                switch mode {
                case .replace:
                    for t in ["private_place_photos", "private_places", "saved_places", "recents", "planned_drives", "personal_routes", "settings"] {
                        try db.execute(sql: "DELETE FROM main.\(t)")
                    }
                    for t in ["saved_places", "recents", "private_places", "private_place_photos", "planned_drives", "personal_routes", "settings"] {
                        let c = try cols(t)
                        try db.execute(sql: "INSERT INTO main.\(t) (\(c)) SELECT \(c) FROM b.\(t)")
                    }
                case .merge:
                    let sp = try cols("saved_places")
                    // Home/Work: the backup's win.
                    try db.execute(sql: """
                        DELETE FROM main.saved_places WHERE kind IN (SELECT kind FROM b.saved_places WHERE kind IN ('home','work'))
                        """)
                    try db.execute(sql: """
                        INSERT INTO main.saved_places (\(sp)) SELECT \(sp) FROM b.saved_places WHERE kind IN ('home','work')
                        ON CONFLICT(id) DO NOTHING
                        """)
                    try db.execute(sql: """
                        INSERT INTO main.saved_places (\(sp)) SELECT \(sp) FROM b.saved_places WHERE kind = 'favorite' AND true
                        ON CONFLICT(id) DO UPDATE SET kind = excluded.kind, name = excluded.name, icon = excluded.icon, lat = excluded.lat,
                          lng = excluded.lng, address = excluded.address, place_id = excluded.place_id, sort_order = excluded.sort_order,
                          created_at = excluded.created_at, updated_at = excluded.updated_at
                        WHERE julianday(excluded.updated_at) > julianday(saved_places.updated_at)
                        """)
                    let rc = try cols("recents")
                    try db.execute(sql: """
                        INSERT INTO main.recents (\(rc)) SELECT \(rc) FROM b.recents WHERE true
                        ON CONFLICT(id) DO UPDATE SET name = excluded.name, address = excluded.address, lat = excluded.lat, lng = excluded.lng,
                          place_id = excluded.place_id, last_used_at = excluded.last_used_at,
                          use_count = MAX(recents.use_count, excluded.use_count)
                        WHERE julianday(excluded.last_used_at) > julianday(recents.last_used_at)
                        """)
                    let pc = try cols("private_places")
                    try db.execute(sql: """
                        INSERT INTO main.private_places (\(pc)) SELECT \(pc) FROM b.private_places WHERE true
                        ON CONFLICT(id) DO UPDATE SET name = excluded.name, category = excluded.category, lat = excluded.lat,
                          lng = excluded.lng, address = excluded.address, description = excluded.description, phone = excluded.phone,
                          website = excluded.website, opening_hours = excluded.opening_hours, amenities_json = excluded.amenities_json,
                          created_at = excluded.created_at, updated_at = excluded.updated_at
                        WHERE julianday(excluded.updated_at) > julianday(private_places.updated_at)
                        """)
                    let rt = try cols("personal_routes")
                    try db.execute(sql: """
                        INSERT INTO main.personal_routes (\(rt)) SELECT \(rt) FROM b.personal_routes WHERE true
                        ON CONFLICT(id) DO UPDATE SET name = excluded.name, mode = excluded.mode, route_json = excluded.route_json,
                          distance_m = excluded.distance_m, duration_s = excluded.duration_s,
                          created_at = excluded.created_at, updated_at = excluded.updated_at
                        WHERE julianday(excluded.updated_at) > julianday(personal_routes.updated_at)
                        """)
                    // Shared settings keys merge by their own rules (docs/privacy-and-backup.md "Shared settings keys");
                    // read both sides before the plain copy, which keeps this phone's value for every other key.
                    func setting(_ schema: String, _ key: String) throws -> String? {
                        try String.fetchOne(db, sql: "SELECT value FROM \(schema).settings WHERE key = ?", arguments: [key])
                    }
                    let blocked = BlockList.merged(local: try setting("main", BlockList.settingsKey), backup: try setting("b", BlockList.settingsKey))
                    let rules = CommunityRules.merged(
                        local: (try setting("main", CommunityRules.versionKey), try setting("main", CommunityRules.acceptedAtKey)),
                        backup: (try setting("b", CommunityRules.versionKey), try setting("b", CommunityRules.acceptedAtKey)))
                    let safety = SafetyPolicy.mergedAgreement(
                        local: (try setting("main", SafetyPolicy.agreedVersionKey), try setting("main", SafetyPolicy.agreedAtKey)),
                        backup: (try setting("b", SafetyPolicy.agreedVersionKey), try setting("b", SafetyPolicy.agreedAtKey)))
                    for t in ["private_place_photos", "planned_drives", "settings"] {
                        let c = try cols(t)
                        try db.execute(sql: "INSERT OR IGNORE INTO main.\(t) (\(c)) SELECT \(c) FROM b.\(t)")
                    }
                    func put(_ key: String, _ value: String?) throws {
                        if let value {
                            try db.execute(sql: "INSERT INTO main.settings (key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value",
                                           arguments: [key, value])
                        } else {
                            try db.execute(sql: "DELETE FROM main.settings WHERE key = ?", arguments: [key])
                        }
                    }
                    try put(BlockList.settingsKey, blocked)
                    try put(CommunityRules.versionKey, rules.version)
                    try put(CommunityRules.acceptedAtKey, rules.version == nil ? nil : rules.acceptedAt)
                    try put(SafetyPolicy.agreedVersionKey, safety.version)
                    try put(SafetyPolicy.agreedAtKey, safety.version == nil ? nil : safety.at)
                    // Keep the newest 50 recents.
                    try db.execute(sql: """
                        DELETE FROM main.recents WHERE id NOT IN (SELECT id FROM main.recents ORDER BY last_used_at DESC LIMIT \(LocalStore.maxRecents))
                        """)
                }
                // Identity: the backup's pseudonym is restored (both modes), re-wrapped for this device.
                if let row = try Row.fetchOne(db, sql: "SELECT user_id, display_name, seed_b64, created_at FROM b.identity ORDER BY created_at DESC LIMIT 1"),
                   let seed = SeedVault.unwrap(row["seed_b64"]), seed.count == 32 {
                    try db.execute(sql: "DELETE FROM main.identity")
                    try db.execute(sql: "INSERT INTO main.identity (user_id, display_name, seed_b64, created_at) VALUES (?, ?, ?, ?)",
                                   arguments: [(row["user_id"] as String).lowercased(), row["display_name"] as String?, SeedVault.wrap(seed), row["created_at"] as String])
                }
                return .commit
            }
        }
    }

    private static func encode(_ m: BackupManifest) throws -> Data {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try e.encode(m)
    }

    private static func addData(_ data: Data, path: String, to archive: Archive) throws {
        try archive.addEntry(with: path, type: .file, uncompressedSize: Int64(data.count), compressionMethod: .deflate) { pos, size in
            data.subdata(in: Int(pos)..<Int(pos) + size)
        }
    }

    private static func addDirectory(_ dir: URL, to archive: Archive) throws {
        let fm = FileManager.default
        guard let e = fm.enumerator(at: dir, includingPropertiesForKeys: [.isDirectoryKey]) else { return }
        for case let url as URL in e {
            let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            if isDir { continue }
            let rel = url.path.replacingOccurrences(of: dir.path + "/", with: "")
            try archive.addEntry(with: rel, fileURL: url, compressionMethod: rel.hasSuffix(".webp") ? .none : .deflate)
        }
    }
}

extension Archive {
    /// `addEntry(with:relativeTo:)` needs a base URL; this adds a file under an explicit path.
    func addEntry(with path: String, fileURL: URL, compressionMethod: CompressionMethod) throws {
        let data = try Data(contentsOf: fileURL)
        try addEntry(with: path, type: .file, uncompressedSize: Int64(data.count), compressionMethod: compressionMethod) { pos, size in
            data.subdata(in: Int(pos)..<Int(pos) + size)
        }
    }
}
