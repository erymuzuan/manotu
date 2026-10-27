import Foundation
import GRDB

/// On-device personal data (docs/privacy-and-backup.md): Home/Work/favourites, recents, "Just for me" places,
/// planned drives, personal routes ("Laluan saya"), settings and the device-local outbox. Same SQLite schema as
/// Android (Room), so backups restore across platforms.
///
/// Versioning uses `PRAGMA user_version` (not GRDB's migrator table) so a snapshot contains only the shared tables.
final class LocalStore: Sendable {
    static let schemaVersion = 3

    /// Schema v1, verbatim from docs/privacy-and-backup.md.
    static let schemaV1 = """
    CREATE TABLE saved_places (
      id TEXT PRIMARY KEY,
      kind TEXT NOT NULL CHECK (kind IN ('home','work','favorite')),
      name TEXT NOT NULL,
      icon TEXT NOT NULL DEFAULT 'star',
      lat REAL NOT NULL, lng REAL NOT NULL,
      address TEXT, place_id TEXT,
      sort_order INTEGER NOT NULL DEFAULT 0,
      created_at TEXT NOT NULL, updated_at TEXT NOT NULL);
    CREATE UNIQUE INDEX ux_saved_home_work ON saved_places(kind) WHERE kind IN ('home','work');

    CREATE TABLE recents (
      id TEXT PRIMARY KEY, name TEXT NOT NULL, address TEXT,
      lat REAL NOT NULL, lng REAL NOT NULL, place_id TEXT,
      last_used_at TEXT NOT NULL, use_count INTEGER NOT NULL DEFAULT 1);

    CREATE TABLE private_places (
      id TEXT PRIMARY KEY, name TEXT NOT NULL, category TEXT NOT NULL,
      lat REAL NOT NULL, lng REAL NOT NULL, address TEXT, description TEXT,
      phone TEXT, website TEXT, opening_hours TEXT, amenities_json TEXT,
      created_at TEXT NOT NULL, updated_at TEXT NOT NULL);

    CREATE TABLE private_place_photos (
      id TEXT PRIMARY KEY, place_id TEXT NOT NULL REFERENCES private_places(id) ON DELETE CASCADE,
      file_name TEXT NOT NULL,
      created_at TEXT NOT NULL);

    CREATE TABLE planned_drives (
      id TEXT PRIMARY KEY, name TEXT, origin_json TEXT, destination_json TEXT NOT NULL,
      waypoints_json TEXT, vehicle TEXT NOT NULL, depart_at TEXT, created_at TEXT NOT NULL);

    CREATE TABLE settings (key TEXT PRIMARY KEY, value TEXT NOT NULL);

    CREATE TABLE outbox (id TEXT PRIMARY KEY, kind TEXT NOT NULL, payload_json TEXT NOT NULL,
      attempts INTEGER NOT NULL DEFAULT 0, next_attempt_at TEXT NOT NULL);
    """

    /// Schema v2: the contributor pseudonym's signing key (docs/privacy-and-backup.md, identity-and-reputation.md).
    /// `seed_b64` is wrapped with a device-only Keychain key here (`kc1:` prefix); backups carry the raw base64 seed.
    static let schemaV2 = """
    CREATE TABLE identity (
      user_id TEXT PRIMARY KEY, display_name TEXT,
      seed_b64 TEXT NOT NULL,
      created_at TEXT NOT NULL);
    """

    /// Schema v3: "Laluan saya", routes from the route builder (docs/privacy-and-backup.md; `route_json` v1 is
    /// `PersonalRouteJSON`).
    static let schemaV3 = """
    CREATE TABLE personal_routes (
      id TEXT PRIMARY KEY,
      name TEXT NOT NULL,
      mode TEXT NOT NULL CHECK (mode IN ('car','motorcycle','bicycle','walk')),
      route_json TEXT NOT NULL,
      distance_m INTEGER, duration_s INTEGER,
      created_at TEXT NOT NULL, updated_at TEXT NOT NULL);
    """

    /// Device-local tables (never in a backup, never on a server, no schema bump so cross-platform restore keeps working):
    /// `refused_content` = public content the check refused, kept 30 days so the user can appeal it;
    /// `device_state` = small device-only flags (e.g. `postingPausedUntil`).
    static let deviceLocalSchema = """
    CREATE TABLE IF NOT EXISTS refused_content (
      id TEXT PRIMARY KEY,
      kind TEXT NOT NULL CHECK (kind IN ('review','photo','place')),
      place_id TEXT, place_name TEXT,
      text TEXT NOT NULL DEFAULT '',
      reasons_json TEXT NOT NULL DEFAULT '[]',
      photos_json TEXT NOT NULL DEFAULT '[]',
      created_at TEXT NOT NULL,
      appeal_state TEXT NOT NULL DEFAULT 'none' CHECK (appeal_state IN ('none','sent','answered')),
      rating INTEGER CHECK (rating BETWEEN 1 AND 5));
    CREATE TABLE IF NOT EXISTS device_state (key TEXT PRIMARY KEY, value TEXT NOT NULL);
    """

    /// Tables included in backups (everything except the device-local outbox).
    static let backedUpTables = ["saved_places", "recents", "private_places", "private_place_photos", "planned_drives", "personal_routes",
                                 "settings", "identity"]
    static let maxRecents = 50

    let dbQueue: DatabaseQueue
    /// The in-memory fallback (corrupt DB) or a test store: nothing written to it outlives the session.
    let isInMemory: Bool
    /// Directory holding private-place photos (`photos/<id>.webp`).
    let photosDirectory: URL

    init(path: String?, photosDirectory: URL) throws {
        var config = Configuration()
        config.foreignKeysEnabled = true
        dbQueue = try path.map { try DatabaseQueue(path: $0, configuration: config) } ?? DatabaseQueue(configuration: config)
        isInMemory = path == nil
        self.photosDirectory = photosDirectory
        try FileManager.default.createDirectory(at: photosDirectory, withIntermediateDirectories: true)
        try Self.migrate(dbQueue)
    }

    /// The app-wide store.
    static let shared = LocalStore.makeDefault()

    /// The app's store in Application Support.
    static func makeDefault() -> LocalStore {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("gimano", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        do {
            return try LocalStore(path: dir.appendingPathComponent("gimano.sqlite").path, photosDirectory: dir.appendingPathComponent("photos", isDirectory: true))
        } catch {
            // A corrupt DB must not brick the app: fall back to an in-memory store for this session.
            return try! LocalStore(path: nil, photosDirectory: FileManager.default.temporaryDirectory.appendingPathComponent("gimano-photos"))
        }
    }

    static func migrate(_ db: DatabaseWriter) throws {
        try db.write { db in
            let version = try Int.fetchOne(db, sql: "PRAGMA user_version") ?? 0
            if version < 1 {
                try db.execute(sql: schemaV1)
            }
            if version < 2 {
                try db.execute(sql: schemaV2)
            }
            if version < 3 {
                try db.execute(sql: schemaV3)
            }
            try db.execute(sql: deviceLocalSchema)
            if version < schemaVersion {
                try db.execute(sql: "PRAGMA user_version = \(schemaVersion)")
            }
        }
    }

    // MARK: timestamps

    /// ISO-8601 UTC with milliseconds, e.g. 2026-10-23T01:02:03.123Z (sortable as text).
    static func timestamp(_ date: Date = .now) -> String {
        date.formatted(Date.ISO8601FormatStyle(includingFractionalSeconds: true))
    }

    static func date(_ s: String?) -> Date? { s.flatMap(JSON.parseDate) }

    // MARK: saved places

    func savedPlaces() throws -> [SavedPlace] {
        try dbQueue.read { db in
            try Row.fetchAll(db, sql: """
                SELECT * FROM saved_places
                ORDER BY CASE kind WHEN 'home' THEN 0 WHEN 'work' THEN 1 ELSE 2 END, sort_order, name
                """).map(Self.savedPlace)
        }
    }

    static func savedPlace(_ r: Row) -> SavedPlace {
        SavedPlace(id: r["id"], kind: SavedPlaceKind(rawValue: r["kind"]) ?? .favorite, name: r["name"], icon: r["icon"],
                   lat: r["lat"], lng: r["lng"], address: r["address"] ?? "", placeId: r["place_id"], sortOrder: r["sort_order"])
    }

    /// Sets Home or Work (one each).
    @discardableResult
    func setHomeWork(_ kind: SavedPlaceKind, name: String, lat: Double, lng: Double, address: String?, placeId: String?) throws -> SavedPlace {
        precondition(kind != .favorite)
        let now = Self.timestamp()
        return try dbQueue.write { db in
            let existing = try String.fetchOne(db, sql: "SELECT id FROM saved_places WHERE kind = ?", arguments: [kind.rawValue])
            let id = existing ?? UUID().uuidString.lowercased()
            if existing != nil {
                try db.execute(sql: """
                    UPDATE saved_places SET name = ?, icon = ?, lat = ?, lng = ?, address = ?, place_id = ?, updated_at = ? WHERE id = ?
                    """, arguments: [name, kind.rawValue, lat, lng, address, placeId, now, id])
            } else {
                try db.execute(sql: """
                    INSERT INTO saved_places (id, kind, name, icon, lat, lng, address, place_id, sort_order, created_at, updated_at)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, 0, ?, ?)
                    """, arguments: [id, kind.rawValue, name, kind.rawValue, lat, lng, address, placeId, now, now])
            }
            return try Self.savedPlace(Row.fetchOne(db, sql: "SELECT * FROM saved_places WHERE id = ?", arguments: [id])!)
        }
    }

    @discardableResult
    func addFavorite(name: String, icon: FavoriteIcon, lat: Double, lng: Double, address: String?, placeId: String?) throws -> SavedPlace {
        let now = Self.timestamp()
        let id = UUID().uuidString.lowercased()
        return try dbQueue.write { db in
            let next = (try Int.fetchOne(db, sql: "SELECT MAX(sort_order) FROM saved_places WHERE kind = 'favorite'") ?? -1) + 1
            try db.execute(sql: """
                INSERT INTO saved_places (id, kind, name, icon, lat, lng, address, place_id, sort_order, created_at, updated_at)
                VALUES (?, 'favorite', ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """, arguments: [id, String(name.prefix(40)), icon.rawValue, lat, lng, address, placeId, next, now, now])
            return try Self.savedPlace(Row.fetchOne(db, sql: "SELECT * FROM saved_places WHERE id = ?", arguments: [id])!)
        }
    }

    func updateFavorite(id: String, name: String? = nil, icon: FavoriteIcon? = nil) throws {
        try dbQueue.write { db in
            if let name { try db.execute(sql: "UPDATE saved_places SET name = ? WHERE id = ?", arguments: [String(name.prefix(40)), id]) }
            if let icon { try db.execute(sql: "UPDATE saved_places SET icon = ? WHERE id = ? AND kind = 'favorite'", arguments: [icon.rawValue, id]) }
            try db.execute(sql: "UPDATE saved_places SET updated_at = ? WHERE id = ?", arguments: [Self.timestamp(), id])
        }
    }

    /// Persists a new favourite order.
    func reorderFavorites(_ ids: [String]) throws {
        let now = Self.timestamp()
        try dbQueue.write { db in
            for (i, id) in ids.enumerated() {
                try db.execute(sql: "UPDATE saved_places SET sort_order = ?, updated_at = ? WHERE id = ? AND kind = 'favorite'", arguments: [i, now, id])
            }
        }
    }

    func deleteSavedPlace(id: String) throws {
        try dbQueue.write { db in try db.execute(sql: "DELETE FROM saved_places WHERE id = ?", arguments: [id]) }
    }

    // MARK: recents

    func recents(limit: Int = 20) throws -> [Recent] {
        try dbQueue.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM recents ORDER BY last_used_at DESC LIMIT ?", arguments: [limit]).map {
                Recent(id: $0["id"], name: $0["name"], address: $0["address"] ?? "", lat: $0["lat"], lng: $0["lng"],
                       placeId: $0["place_id"], lastUsedAt: Self.date($0["last_used_at"]))
            }
        }
    }

    /// Records a destination: same place (by place id, or same name within 50 m) bumps `use_count`; keeps the last 50.
    func recordRecent(name: String, address: String?, lat: Double, lng: Double, placeId: String?, at date: Date = .now) throws {
        let now = Self.timestamp(date)
        try dbQueue.write { db in
            var existingId: String?
            if let placeId {
                existingId = try String.fetchOne(db, sql: "SELECT id FROM recents WHERE place_id = ?", arguments: [placeId])
            }
            if existingId == nil {
                for r in try Row.fetchAll(db, sql: "SELECT id, lat, lng FROM recents WHERE name = ?", arguments: [name])
                where Geo.distance(LatLng(lat: r["lat"], lng: r["lng"]), LatLng(lat: lat, lng: lng)) < 50 {
                    existingId = r["id"]
                    break
                }
            }
            if let existingId {
                try db.execute(sql: """
                    UPDATE recents SET name = ?, address = ?, lat = ?, lng = ?, place_id = COALESCE(?, place_id),
                    last_used_at = ?, use_count = use_count + 1 WHERE id = ?
                    """, arguments: [name, address, lat, lng, placeId, now, existingId])
            } else {
                try db.execute(sql: """
                    INSERT INTO recents (id, name, address, lat, lng, place_id, last_used_at, use_count) VALUES (?, ?, ?, ?, ?, ?, ?, 1)
                    """, arguments: [UUID().uuidString.lowercased(), name, address, lat, lng, placeId, now])
            }
            try db.execute(sql: """
                DELETE FROM recents WHERE id NOT IN (SELECT id FROM recents ORDER BY last_used_at DESC LIMIT \(Self.maxRecents))
                """)
        }
    }

    // MARK: private places ("Just for me", never sent to the server)

    /// Saves a private place with its photos (already WebP-encoded) under `photos/<photoId>.webp`.
    @discardableResult
    func addPrivatePlace(_ p: PrivatePlace, webpPhotos: [Data]) throws -> PrivatePlace {
        let now = Self.timestamp()
        let id = p.id.isEmpty ? UUID().uuidString.lowercased() : p.id
        let amenities = String(decoding: try JSONEncoder().encode(p.amenities), as: UTF8.self)
        var files: [String] = []
        for data in webpPhotos {
            let photoId = UUID().uuidString.lowercased()
            let name = "\(photoId).webp"
            try data.write(to: photosDirectory.appendingPathComponent(name), options: .atomic)
            files.append(name)
        }
        try dbQueue.write { db in
            try db.execute(sql: """
                INSERT INTO private_places (id, name, category, lat, lng, address, description, phone, website, opening_hours,
                  amenities_json, created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """, arguments: [id, p.name, p.category.rawValue, p.lat, p.lng, p.address, p.description, p.phone, p.website,
                                 p.openingHours, amenities, now, now])
            for f in files {
                try db.execute(sql: "INSERT INTO private_place_photos (id, place_id, file_name, created_at) VALUES (?, ?, ?, ?)",
                               arguments: [String(f.dropLast(5)), id, "photos/\(f)", now])
            }
        }
        return try privatePlace(id: id)!
    }

    func privatePlaces() throws -> [PrivatePlace] {
        try dbQueue.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM private_places ORDER BY updated_at DESC").map { try Self.privatePlace($0, db: db) }
        }
    }

    func privatePlace(id: String) throws -> PrivatePlace? {
        try dbQueue.read { db in
            try Row.fetchOne(db, sql: "SELECT * FROM private_places WHERE id = ?", arguments: [id]).map { try Self.privatePlace($0, db: db) }
        }
    }

    private static func privatePlace(_ r: Row, db: Database) throws -> PrivatePlace {
        let id: String = r["id"]
        let amenities = (r["amenities_json"] as String?).flatMap { try? JSONDecoder().decode([String].self, from: Data($0.utf8)) } ?? []
        let files = try String.fetchAll(db, sql: "SELECT file_name FROM private_place_photos WHERE place_id = ? ORDER BY created_at", arguments: [id])
        return PrivatePlace(id: id, name: r["name"], category: PlaceCategory(rawValue: r["category"]) ?? .other, lat: r["lat"], lng: r["lng"],
                            address: r["address"], description: r["description"], phone: r["phone"], website: r["website"],
                            openingHours: r["opening_hours"], amenities: amenities, photoFiles: files,
                            createdAt: date(r["created_at"]), updatedAt: date(r["updated_at"]))
    }

    func deletePrivatePlace(id: String) throws {
        let files = try dbQueue.read { try String.fetchAll($0, sql: "SELECT file_name FROM private_place_photos WHERE place_id = ?", arguments: [id]) }
        try dbQueue.write { try $0.execute(sql: "DELETE FROM private_places WHERE id = ?", arguments: [id]) }
        for f in files { try? FileManager.default.removeItem(at: photoURL(f)) }
    }

    /// File URL for a `file_name` stored as "photos/<id>.webp".
    func photoURL(_ fileName: String) -> URL {
        photosDirectory.appendingPathComponent((fileName as NSString).lastPathComponent)
    }

    // MARK: identity (single row)

    func identity() throws -> StoredIdentity? {
        try dbQueue.read { db in
            guard let row = try Row.fetchOne(db, sql: "SELECT user_id, display_name, seed_b64, created_at FROM identity ORDER BY created_at DESC LIMIT 1"),
                  let seed = SeedVault.unwrap(row["seed_b64"]), let keys = IdentityKeys(seed: seed) else { return nil }
            return StoredIdentity(userId: row["user_id"], displayName: row["display_name"], keys: keys, createdAt: row["created_at"])
        }
    }

    func saveIdentity(_ id: StoredIdentity) throws {
        try dbQueue.write { db in
            try db.execute(sql: "DELETE FROM identity")
            try db.execute(sql: "INSERT INTO identity (user_id, display_name, seed_b64, created_at) VALUES (?, ?, ?, ?)",
                           arguments: [id.userId.lowercased(), id.displayName, SeedVault.wrap(id.keys.seed), id.createdAt])
        }
    }

    func setIdentityDisplayName(_ name: String?) throws {
        try dbQueue.write { db in try db.execute(sql: "UPDATE identity SET display_name = ?", arguments: [name]) }
    }

    func deleteIdentity() throws {
        try dbQueue.write { db in try db.execute(sql: "DELETE FROM identity") }
    }

    // MARK: settings

    func setting(_ key: String) throws -> String? {
        try dbQueue.read { db in try String.fetchOne(db, sql: "SELECT value FROM settings WHERE key = ?", arguments: [key]) }
    }

    /// Removes settings tied to the server identity (my review ids, my places, inbox read mark).
    func clearIdentitySettings() throws {
        try dbQueue.write { db in
            try db.execute(sql: "DELETE FROM settings WHERE key LIKE 'review.%' OR key IN ('ownPlaces', 'inbox.readUpTo')")
        }
    }

    func setSetting(_ key: String, _ value: String?) throws {
        try dbQueue.write { db in
            if let value {
                try db.execute(sql: "INSERT INTO settings (key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value",
                               arguments: [key, value])
            } else {
                try db.execute(sql: "DELETE FROM settings WHERE key = ?", arguments: [key])
            }
        }
    }

    // MARK: outbox (device-local, never backed up)

    func outboxItems(kind: String) throws -> [(id: String, payload: String)] {
        try dbQueue.read { db in
            try Row.fetchAll(db, sql: "SELECT id, payload_json FROM outbox WHERE kind = ? ORDER BY next_attempt_at", arguments: [kind])
                .map { ($0["id"], $0["payload_json"]) }
        }
    }

    func replaceOutbox(kind: String, items: [(id: String, payload: String, attempts: Int, nextAttemptAt: Date)]) throws {
        try dbQueue.write { db in
            try db.execute(sql: "DELETE FROM outbox WHERE kind = ?", arguments: [kind])
            for i in items {
                try db.execute(sql: "INSERT INTO outbox (id, kind, payload_json, attempts, next_attempt_at) VALUES (?, ?, ?, ?, ?)",
                               arguments: [i.id, kind, i.payload, i.attempts, Self.timestamp(i.nextAttemptAt)])
            }
        }
    }

    // MARK: bulk

    /// Counts per backed-up table (for the backup manifest).
    func counts() throws -> [String: Int] {
        try dbQueue.read { db in
            var out: [String: Int] = [:]
            for t in ["saved_places", "recents", "private_places", "planned_drives", "personal_routes"] {
                out[t] = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \(t)") ?? 0
            }
            out["photos"] = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM private_place_photos") ?? 0
            return out
        }
    }

    /// Latest change timestamp across personal data (auto-backup runs only when this moved).
    func lastChangeAt() throws -> String? {
        try dbQueue.read { db in
            try String.fetchOne(db, sql: """
                SELECT MAX(t) FROM (
                  SELECT MAX(updated_at) AS t FROM saved_places UNION ALL
                  SELECT MAX(last_used_at) FROM recents UNION ALL
                  SELECT MAX(updated_at) FROM private_places UNION ALL
                  SELECT MAX(created_at) FROM planned_drives UNION ALL
                  SELECT MAX(updated_at) FROM personal_routes)
                """)
        }
    }

    func wipePersonalData() throws {
        try dbQueue.write { db in
            for t in Self.backedUpTables.reversed() where t != "settings" { try db.execute(sql: "DELETE FROM \(t)") }
            try db.execute(sql: "DELETE FROM refused_content")
            try db.execute(sql: "DELETE FROM device_state")
        }
        try? FileManager.default.removeItem(at: refusedDirectory)
    }
}
