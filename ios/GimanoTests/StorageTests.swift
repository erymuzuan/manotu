import Foundation
import GRDB
import Testing
@testable import Gimano

private func makeStore() throws -> LocalStore {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("store-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return try LocalStore(path: dir.appendingPathComponent("db.sqlite").path, photosDirectory: dir.appendingPathComponent("photos"))
}

/// The DDL block from docs/privacy-and-backup.md, when the repo is reachable (simulator runs on the Mac).
private var docSchema: String? {
    let doc = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("docs/privacy-and-backup.md")
    guard let md = try? String(contentsOf: doc, encoding: .utf8),
          let start = md.range(of: "```sql\n"), let end = md.range(of: "```", range: start.upperBound..<md.endIndex) else { return nil }
    return String(md[start.upperBound..<end.lowerBound])
}

private func describe(_ db: DatabaseQueue) throws -> [String] {
    try db.read { db in
        var out: [String] = []
        for t in try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%' ORDER BY name") {
            for c in try Row.fetchAll(db, sql: "PRAGMA table_info(\(t))") {
                out.append("\(t).\(c["name"] as String) \(c["type"] as String) notnull=\(c["notnull"] as Int) pk=\(c["pk"] as Int) default=\((c["dflt_value"] as String?) ?? "-")")
            }
            for fk in try Row.fetchAll(db, sql: "PRAGMA foreign_key_list(\(t))") {
                out.append("\(t) fk \(fk["from"] as String)->\(fk["table"] as String).\(fk["to"] as String) \(fk["on_delete"] as String)")
            }
        }
        for i in try Row.fetchAll(db, sql: "SELECT name, tbl_name, sql FROM sqlite_master WHERE type = 'index' AND sql IS NOT NULL ORDER BY name") {
            out.append("index \(i["name"] as String) on \(i["tbl_name"] as String)")
        }
        return out
    }
}

@Suite("Local store (on-device personal data)")
struct LocalStoreTests {
    @Test("Schema is identical to docs/privacy-and-backup.md", .enabled(if: docSchema != nil))
    func schemaMatchesDoc() throws {
        let fromDoc = try DatabaseQueue()
        try fromDoc.write { try $0.execute(sql: docSchema!) }
        let ours = try makeStore()
        #expect(try describe(fromDoc) == describe(ours.dbQueue))
        #expect(try ours.dbQueue.read { try Int.fetchOne($0, sql: "PRAGMA user_version") } == LocalStore.schemaVersion)
    }

    @Test("Our embedded DDL covers every documented table (works on device too)")
    func tables() throws {
        let s = try makeStore()
        let names = try s.dbQueue.read { try String.fetchAll($0, sql: "SELECT name FROM sqlite_master WHERE type='table' ORDER BY name") }
        #expect(names == ["device_state", "identity", "outbox", "personal_routes", "planned_drives", "private_place_photos", "private_places",
                          "recents", "refused_content", "saved_places", "settings"])
    }

    @Test("Home/Work are unique; favourites keep label, icon and order")
    func savedPlaces() throws {
        let s = try makeStore()
        try s.setHomeWork(.home, name: "Home", lat: 3.1, lng: 101.6, address: "TTDI", placeId: nil)
        try s.setHomeWork(.home, name: "Home", lat: 3.2, lng: 101.7, address: "Bangsar", placeId: nil)
        try s.setHomeWork(.work, name: "Work", lat: 3.0, lng: 101.5, address: "KL Sentral", placeId: "n1")
        let k = try s.addFavorite(name: "Kampung", icon: .kampung, lat: 3.5, lng: 101.0, address: "Kuala Kubu", placeId: nil)
        let m = try s.addFavorite(name: "Rumah Mertua", icon: .mertua, lat: 3.4, lng: 101.1, address: "Rawang", placeId: nil)
        var all = try s.savedPlaces()
        #expect(all.map(\.name) == ["Home", "Work", "Kampung", "Rumah Mertua"])
        #expect(all[0].address == "Bangsar")
        #expect(all.first { $0.id == m.id }?.favoriteIcon == .mertua)
        try s.reorderFavorites([m.id, k.id])
        try s.updateFavorite(id: k.id, name: "Kampung Abah", icon: .heart)
        all = try s.savedPlaces()
        #expect(all.map(\.name) == ["Home", "Work", "Rumah Mertua", "Kampung Abah"])
        #expect(all.last?.favoriteIcon == .heart)
        try s.deleteSavedPlace(id: m.id)
        #expect(try s.savedPlaces().count == 3)
    }

    @Test("Recents: dedupe by place id or same name within 50 m, newest first, capped at 50")
    func recents() throws {
        let s = try makeStore()
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        try s.recordRecent(name: "KLCC", address: nil, lat: 3.1579, lng: 101.7123, placeId: "w1", at: t0)
        try s.recordRecent(name: "KLCC", address: nil, lat: 3.1580, lng: 101.7124, placeId: nil, at: t0 + 10)
        try s.recordRecent(name: "Pavilion", address: nil, lat: 3.149, lng: 101.713, placeId: nil, at: t0 + 20)
        var r = try s.recents()
        #expect(r.map(\.name) == ["Pavilion", "KLCC"])
        let useCount = try s.dbQueue.read { try Int.fetchOne($0, sql: "SELECT use_count FROM recents WHERE name='KLCC'") }
        #expect(useCount == 2)
        for i in 0..<60 { try s.recordRecent(name: "P\(i)", address: nil, lat: 2 + Double(i) * 0.01, lng: 101, placeId: nil, at: t0 + 100 + Double(i)) }
        r = try s.recents(limit: 100)
        #expect(r.count == 50)
        #expect(r.first?.name == "P59")
    }

    @Test("Legacy server data is imported once without duplicates")
    func legacy() throws {
        let s = try makeStore()
        let export = LegacyDataMigration.Export(
            savedPlaces: [SavedPlace(id: "1", kind: .home, name: "Home", icon: "home", lat: 3.1, lng: 101.6, address: "TTDI"),
                          SavedPlace(id: "2", kind: .favorite, name: "Kampung", icon: "kampung", lat: 3.5, lng: 101, address: "KKB", sortOrder: 0)],
            recents: [Recent(id: "r", name: "Mid Valley", address: "", lat: 3.11, lng: 101.67, placeId: nil, lastUsedAt: .now)])
        #expect(try LegacyDataMigration.importExport(export, into: s) == 3)
        #expect(try LegacyDataMigration.importExport(export, into: s) == 1) // only the recent is bumped again
        let places = try s.savedPlaces()
        #expect(places.count == 2)
        #expect(places.first { $0.kind == .favorite }?.favoriteIcon == .kampung)
    }
}

@Suite("Backup & restore (.gimano v1)")
struct BackupTests {
    private func seeded() throws -> LocalStore {
        let s = try makeStore()
        try s.setHomeWork(.home, name: "Home", lat: 3.1466, lng: 101.6297, address: "TTDI", placeId: nil)
        try s.addFavorite(name: "Rumah Mertua", icon: .mertua, lat: 3.07, lng: 101.52, address: "Shah Alam", placeId: nil)
        try s.recordRecent(name: "Mid Valley", address: "KL", lat: 3.118, lng: 101.677, placeId: "w1")
        try s.setSetting("voice", "on")
        try s.dbQueue.write { db in
            try db.execute(sql: """
                INSERT INTO private_places (id, name, category, lat, lng, created_at, updated_at) VALUES ('pp1', 'Gerai Pak Abu', 'food', 3.1, 101.6, ?, ?)
                """, arguments: [LocalStore.timestamp(), LocalStore.timestamp()])
            try db.execute(sql: "INSERT INTO private_place_photos (id, place_id, file_name, created_at) VALUES ('ph1', 'pp1', 'photos/ph1.webp', ?)",
                           arguments: [LocalStore.timestamp()])
        }
        try Data("RIFFfakewebp".utf8).write(to: s.photosDirectory.appendingPathComponent("ph1.webp"))
        try s.replaceOutbox(kind: "feedback", items: [("o1", "{}", 0, .now)])
        return s
    }

    private var fast: BackupService.Type { BackupService.self }

    @Test("Round trip without passphrase (Replace), outbox excluded, photos restored")
    func roundTrip() throws {
        let src = try seeded()
        let file = try BackupService(store: src, kdfLimits: .interactive).makeBackup()
        let m = try BackupService.readManifest(file)
        #expect(m.format == 1 && m.encryption == "none" && m.platform == "ios")
        #expect(m.counts["saved_places"] == 2 && m.counts["photos"] == 1)

        let dst = try makeStore()
        try dst.addFavorite(name: "Will be wiped", icon: .star, lat: 0, lng: 0, address: nil, placeId: nil)
        try BackupService(store: dst).restore(file, mode: .replace)
        #expect(try dst.savedPlaces().map(\.name) == ["Home", "Rumah Mertua"])
        #expect(try dst.recents().map(\.name) == ["Mid Valley"])
        #expect(try dst.setting("voice") == "on")
        #expect(try dst.outboxItems(kind: "feedback").isEmpty)
        #expect(FileManager.default.fileExists(atPath: dst.photosDirectory.appendingPathComponent("ph1.webp").path))
    }

    @Test("Encrypted round trip; wrong or missing passphrase is rejected")
    func encrypted() throws {
        let src = try seeded()
        let file = try BackupService(store: src, kdfLimits: .interactive).makeBackup(passphrase: "kampung-2026!")
        let m = try BackupService.readManifest(file)
        #expect(m.encryption == BackupManifest.encryptionPassphrase)
        #expect(m.kdf?.alg == "argon2id13" && m.kdf?.chunkSize == 65_536)
        #expect(Data(base64Encoded: m.kdf?.salt ?? "")?.count == 16)

        let dst = try makeStore()
        #expect(throws: BackupError.passphraseRequired) { try BackupService(store: dst).restore(file, mode: .replace) }
        #expect(throws: BackupError.wrongPassphrase) { try BackupService(store: dst).restore(file, mode: .replace, passphrase: "wrong") }
        try BackupService(store: dst).restore(file, mode: .replace, passphrase: "kampung-2026!")
        #expect(try dst.savedPlaces().count == 2)
    }

    @Test("Large payloads span several secretstream chunks")
    func multiChunk() throws {
        let src = try seeded()
        try Data((0..<300_000).map { UInt8($0 % 251) }).write(to: src.photosDirectory.appendingPathComponent("ph1.webp"))
        let file = try BackupService(store: src, kdfLimits: .interactive).makeBackup(passphrase: "pw")
        let dst = try makeStore()
        try BackupService(store: dst).restore(file, mode: .replace, passphrase: "pw")
        let restored = try Data(contentsOf: dst.photosDirectory.appendingPathComponent("ph1.webp"))
        #expect(restored.count == 300_000)
    }

    @Test("Merge keeps the newer updated_at, takes Home/Work from the backup and keeps local extras")
    func merge() throws {
        let src = try seeded()
        let file = try BackupService(store: src, kdfLimits: .interactive).makeBackup()

        let dst = try makeStore()
        try dst.setHomeWork(.home, name: "Home", lat: 9, lng: 9, address: "Old home", placeId: nil)
        try dst.addFavorite(name: "Gym", icon: .gym, lat: 3.15, lng: 101.71, address: "KLCC", placeId: nil)
        // Same favourite id as in the backup but edited later on this device: local wins.
        let mertuaId = try src.savedPlaces().first { $0.name == "Rumah Mertua" }!.id
        try dst.dbQueue.write { db in
            try db.execute(sql: """
                INSERT INTO saved_places (id, kind, name, icon, lat, lng, address, sort_order, created_at, updated_at)
                VALUES (?, 'favorite', 'Mertua (baru)', 'mertua', 3.07, 101.52, 'Shah Alam', 1, '2020-01-01T00:00:00Z', '2999-01-01T00:00:00.000Z')
                """, arguments: [mertuaId])
            try db.execute(sql: "INSERT INTO settings (key, value) VALUES ('voice', 'off')")
        }
        try BackupService(store: dst).restore(file, mode: .merge)
        let places = try dst.savedPlaces()
        #expect(places.first { $0.kind == .home }?.address == "TTDI")
        #expect(places.contains { $0.name == "Gym" })
        #expect(places.first { $0.id == mertuaId }?.name == "Mertua (baru)")
        #expect(try dst.setting("voice") == "off") // local settings kept
        #expect(try dst.recents().count == 1)
    }

    @Test("A backup with an older backup on the same ids: backup wins when newer")
    func mergeNewerBackup() throws {
        let src = try seeded()
        let dst = try makeStore()
        let id = try src.savedPlaces().first { $0.kind == .favorite }!.id
        try dst.dbQueue.write { db in
            try db.execute(sql: """
                INSERT INTO saved_places (id, kind, name, icon, lat, lng, sort_order, created_at, updated_at)
                VALUES (?, 'favorite', 'Old name', 'star', 0, 0, 0, '2020-01-01T00:00:00Z', '2020-01-01T00:00:00Z')
                """, arguments: [id])
        }
        let file = try BackupService(store: src, kdfLimits: .interactive).makeBackup()
        try BackupService(store: dst).restore(file, mode: .merge)
        #expect(try dst.savedPlaces().first { $0.id == id }?.name == "Rumah Mertua")
    }

    @Test("Non-backups and newer schemas are refused")
    func refuse() throws {
        let junk = FileManager.default.temporaryDirectory.appendingPathComponent("junk-\(UUID()).gimano")
        try Data("not a zip".utf8).write(to: junk)
        #expect(throws: BackupError.notABackup) { try BackupService.readManifest(junk) }
    }
}

@Suite("Manotu backups")
struct ManotuBackupTests {
    @Test("New backups are .manotu; a .gimano file from before the rename still restores")
    func extensions() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("m-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let src = try LocalStore(path: dir.appendingPathComponent("a.sqlite").path, photosDirectory: dir.appendingPathComponent("pa"))
        try src.setHomeWork(.home, name: "Home", lat: 3.1, lng: 101.6, address: "Rumah", placeId: nil)
        let file = try BackupService(store: src, kdfLimits: .interactive).makeBackup()
        #expect(file.pathExtension == "manotu" && file.lastPathComponent.hasPrefix("manotu-backup-"))
        let old = dir.appendingPathComponent("gimano-backup-old.gimano")
        try FileManager.default.copyItem(at: file, to: old)
        let dst = try LocalStore(path: dir.appendingPathComponent("b.sqlite").path, photosDirectory: dir.appendingPathComponent("pb"))
        try BackupService(store: dst).restore(old, mode: .replace)
        #expect(try dst.savedPlaces().first?.kind == .home)
    }
}

@Suite("Backup retention")
struct BackupRetentionTests {
    private func b(_ id: String, _ daysAgo: Double, _ install: String?) -> RemoteBackup {
        RemoteBackup(id: id, name: id, createdAt: Date(timeIntervalSinceNow: -daysAgo * 86400), size: 1, installId: install)
    }

    @Test("Only this installation's backups beyond the newest 5 are deleted; Android/other devices/untagged are never touched")
    func scoped() {
        let mine = (0..<8).map { b("m\($0)", Double($0), "me") }
        let others = [b("android1", 20, nil), b("android2", 0.5, nil), b("ipad", 30, "other-install"), b("old-gimano", 90, nil)]
        let drop = BackupRetention.toDelete(mine + others, installId: "me", keep: 5)
        #expect(Set(drop.map(\.id)) == ["m5", "m6", "m7"])
        #expect(BackupRetention.toDelete(others, installId: "me", keep: 0).isEmpty, "never deletes what it didn't create")
    }

    @Test("Install id is stable and random per installation")
    func installId() {
        let a = BackupRetention.installId
        #expect(a == BackupRetention.installId && a.count == 36)
    }
}
