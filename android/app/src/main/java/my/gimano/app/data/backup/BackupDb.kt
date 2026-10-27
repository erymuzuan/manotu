package my.gimano.app.data.backup

import my.gimano.app.data.local.GimanoSchema
import java.io.File

/** Minimal SQL access so snapshot/restore run on Room (app) and plain JDBC SQLite (tests). */
interface SqlPort {
    fun exec(sql: String, vararg args: Any?)
    fun queryLong(sql: String, vararg args: Any?): Long
    fun queryStrings(sql: String, vararg args: Any?): List<String>
    /** Runs [block] in a transaction (rolled back if it throws). */
    fun <T> transaction(block: () -> T): T
}

enum class RestoreMode { REPLACE, MERGE }

class BackupTooNewException(val version: Int) : Exception("This backup was made by a newer version of Manotu (schema $version)")

/** Snapshot and restore of the on-device DB, using the shared schema's table names only. */
object BackupDb {

    /**
     * Writes a consistent, compact copy of the DB to [target] with `VACUUM INTO` (SQLite ≥ 3.27),
     * then [cleanSnapshot] removes device-local tables.
     */
    fun snapshot(db: SqlPort, target: File) {
        target.delete()
        db.exec("VACUUM INTO ?", target.absolutePath)
    }

    /** Drops what must not be in a backup: the outbox and Room's/Android's bookkeeping tables. */
    fun cleanSnapshot(snapshot: SqlPort) {
        GimanoSchema.LOCAL_ONLY_TABLES.forEach { snapshot.exec("DROP TABLE IF EXISTS $it") }
        snapshot.exec("DROP TABLE IF EXISTS room_master_table")
        snapshot.exec("DROP TABLE IF EXISTS android_metadata")
        // The live DB carries Room's version; a backup carries the shared schema version (docs/privacy-and-backup.md).
        snapshot.exec("PRAGMA user_version = ${GimanoSchema.VERSION}")
        snapshot.exec("VACUUM")
    }

    fun counts(db: SqlPort, schema: String = "main") = BackupCounts(
        saved_places = db.queryLong("SELECT COUNT(*) FROM $schema.saved_places").toInt(),
        recents = db.queryLong("SELECT COUNT(*) FROM $schema.recents").toInt(),
        private_places = db.queryLong("SELECT COUNT(*) FROM $schema.private_places").toInt(),
        photos = db.queryLong("SELECT COUNT(*) FROM $schema.private_place_photos").toInt(),
        planned_drives = db.queryLong("SELECT COUNT(*) FROM $schema.planned_drives").toInt(),
        personal_routes = db.queryLong("SELECT COUNT(*) FROM $schema.personal_routes").toInt(),
    )

    /**
     * Copies rows from the backup file into the live DB. REPLACE wipes first; MERGE upserts by id,
     * keeping the newer `updated_at` (`last_used_at` for recents), and the backup's Home/Work.
     * @return file names of photos referenced by the restored rows.
     */
    fun restore(db: SqlPort, backupFile: File, mode: RestoreMode): List<String> {
        db.exec("ATTACH DATABASE ? AS bk", backupFile.absolutePath)
        try {
            val version = db.queryLong("PRAGMA bk.user_version").toInt()
            if (version > GimanoSchema.VERSION) throw BackupTooNewException(version)
            // Older schemas: the normal migrations run on the backup copy (a temp file extracted for this restore),
            // so schema 1 gains an empty `identity` and schema 2 an empty `personal_routes`.
            if (version < GimanoSchema.VERSION) GimanoSchema.migrateAttached("bk") { db.exec(it) }
            val tables = db.queryStrings("SELECT name FROM bk.sqlite_master WHERE type = 'table'").toSet()
            val missing = GimanoSchema.REQUIRED_TABLES - tables
            if (missing.isNotEmpty()) throw BackupFormatException("Backup is missing tables: $missing")

            db.exec("PRAGMA foreign_keys = OFF")
            try {
                db.transaction {
                    when (mode) {
                        RestoreMode.REPLACE -> {
                            GimanoSchema.REQUIRED_TABLES.reversed().forEach { db.exec("DELETE FROM main.$it") }
                            GimanoSchema.REQUIRED_TABLES.forEach { db.exec("INSERT INTO main.$it SELECT * FROM bk.$it") }
                        }
                        RestoreMode.MERGE -> merge(db)
                    }
                    // The contributor identity: a backup that carries one is adopted (Replace and Merge alike),
                    // so restoring on a new phone brings back the pseudonym and its reputation. A backup without
                    // one (schema 1, or never registered) leaves this phone's identity alone.
                    if ("identity" in tables && db.queryLong("SELECT COUNT(*) FROM bk.identity") > 0) {
                        db.exec("DELETE FROM main.identity")
                        db.exec("INSERT INTO main.identity SELECT * FROM bk.identity")
                    }
                }
            } finally {
                db.exec("PRAGMA foreign_keys = ON")
            }
            return db.queryStrings("SELECT file_name FROM bk.private_place_photos")
        } finally {
            db.exec("DETACH DATABASE bk")
        }
    }

    private fun merge(db: SqlPort) {
        // Home/Work: the backup's wins.
        db.exec("DELETE FROM main.saved_places WHERE kind IN ('home','work') AND kind IN (SELECT kind FROM bk.saved_places WHERE kind IN ('home','work'))")
        db.exec("INSERT OR REPLACE INTO main.saved_places SELECT * FROM bk.saved_places WHERE kind IN ('home','work')")
        // Favourites, recents, private places: newer wins; missing ones are added.
        db.exec(
            "INSERT OR REPLACE INTO main.saved_places SELECT b.* FROM bk.saved_places b LEFT JOIN main.saved_places m ON m.id = b.id " +
                "WHERE b.kind = 'favorite' AND (m.id IS NULL OR b.updated_at > m.updated_at)",
        )
        db.exec(
            "INSERT OR REPLACE INTO main.recents SELECT b.* FROM bk.recents b LEFT JOIN main.recents m ON m.id = b.id " +
                "WHERE m.id IS NULL OR b.last_used_at > m.last_used_at",
        )
        db.exec("DELETE FROM main.recents WHERE id NOT IN (SELECT id FROM main.recents ORDER BY last_used_at DESC LIMIT 50)")
        db.exec(
            "INSERT OR REPLACE INTO main.private_places SELECT b.* FROM bk.private_places b LEFT JOIN main.private_places m ON m.id = b.id " +
                "WHERE m.id IS NULL OR b.updated_at > m.updated_at",
        )
        db.exec("INSERT OR IGNORE INTO main.private_place_photos SELECT b.* FROM bk.private_place_photos b WHERE b.place_id IN (SELECT id FROM main.private_places)")
        db.exec("INSERT OR IGNORE INTO main.planned_drives SELECT * FROM bk.planned_drives")
        // Personal routes ("Laluan saya"): newer `updated_at` wins; missing ones are added.
        db.exec(
            "INSERT OR REPLACE INTO main.personal_routes SELECT b.* FROM bk.personal_routes b LEFT JOIN main.personal_routes m ON m.id = b.id " +
                "WHERE m.id IS NULL OR b.updated_at > m.updated_at",
        )
        // Shared keys that merge rather than "device wins" (docs/privacy-and-backup.md), read before the generic copy:
        // the block list is the union by ref; rules acceptance keeps the later version.
        fun setting(schema: String, key: String) =
            db.queryStrings("SELECT value FROM $schema.settings WHERE `key` = ?", key).firstOrNull()
        val blocked = my.gimano.app.data.ugc.Blocking.union(
            setting("main", my.gimano.app.data.ugc.Blocking.SETTINGS_KEY), setting("bk", my.gimano.app.data.ugc.Blocking.SETTINGS_KEY))
        val rules = my.gimano.app.data.ugc.UgcTerms.newer(
            setting("main", my.gimano.app.data.ugc.UgcTerms.VERSION_KEY) to setting("main", my.gimano.app.data.ugc.UgcTerms.ACCEPTED_AT_KEY),
            setting("bk", my.gimano.app.data.ugc.UgcTerms.VERSION_KEY) to setting("bk", my.gimano.app.data.ugc.UgcTerms.ACCEPTED_AT_KEY))
        // Settings: the device's own choices win in a merge.
        db.exec("INSERT OR IGNORE INTO main.settings SELECT * FROM bk.settings")
        fun put(key: String, value: String?) {
            if (value == null) db.exec("DELETE FROM main.settings WHERE `key` = ?", key)
            else db.exec("INSERT OR REPLACE INTO main.settings (`key`, value) VALUES (?, ?)", key, value)
        }
        put(my.gimano.app.data.ugc.Blocking.SETTINGS_KEY, blocked)
        if (rules.first != null) {
            put(my.gimano.app.data.ugc.UgcTerms.VERSION_KEY, rules.first)
            put(my.gimano.app.data.ugc.UgcTerms.ACCEPTED_AT_KEY, rules.second)
        }
    }

    private const val SEP = "\u001f"

    /**
     * Rewrites every identity row's `seed_b64` with [transform]: unwrap (Keystore → plain) when writing a backup,
     * wrap (plain → Keystore) after a restore. At rest on the phone the seed is always wrapped.
     */
    fun transformIdentitySeeds(db: SqlPort, transform: (String) -> String) {
        if (db.queryLong("SELECT COUNT(*) FROM sqlite_master WHERE type = 'table' AND name = 'identity'") == 0L) return
        db.queryStrings("SELECT user_id || '$SEP' || seed_b64 FROM identity").forEach { row ->
            val (id, seed) = row.split(SEP, limit = 2)
            val out = transform(seed)
            if (out != seed) db.exec("UPDATE identity SET seed_b64 = ? WHERE user_id = ?", out, id)
        }
    }

    /** A fingerprint of the backed-up data, to skip automatic backups when nothing changed. */
    fun fingerprint(db: SqlPort): String = listOf(
        "SELECT COUNT(*) || ':' || COALESCE(MAX(updated_at), '') FROM saved_places",
        "SELECT COUNT(*) || ':' || COALESCE(MAX(last_used_at), '') FROM recents",
        "SELECT COUNT(*) || ':' || COALESCE(MAX(updated_at), '') FROM private_places",
        "SELECT COUNT(*) || '' FROM private_place_photos",
        "SELECT COUNT(*) || ':' || COALESCE(MAX(created_at), '') FROM planned_drives",
        "SELECT COUNT(*) || ':' || COALESCE(MAX(updated_at), '') FROM personal_routes",
        "SELECT COUNT(*) || ':' || COALESCE(group_concat(key || '=' || value), '') FROM settings",
        "SELECT COUNT(*) || ':' || COALESCE(MAX(user_id), '') FROM identity",
    ).joinToString("|") { db.queryStrings(it).firstOrNull().orEmpty() }
}
