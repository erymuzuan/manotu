# Personal data: on-device only, with backup and restore

**Principle:** a user's personal data never lives on Manotu's servers. Favourites, Home/Work,
recents, private places, planned drives and settings stay **on the device**, and are backed up only to
**the user's own cloud** (Google Drive or iCloud) or to a file they control.

The server only receives what the user deliberately shares with everyone: reports, public places,
reviews and photos, feedback, and anonymous location pings while navigating (see `traffic.md`).

## Storage: SQLite, same schema on both platforms

| Platform | Library | Notes |
|---|---|---|
| Android | **Room** (androidx.room, SQLite) | DAOs, Flow queries, `AutoMigration` |
| iOS | **GRDB.swift** (MIT, SQLite) | `DatabaseMigrator`, `ValueObservation` |

The schema is identical on both platforms (`PRAGMA user_version` = schema version), so a backup made
on one platform restores on the other.

```sql
CREATE TABLE saved_places (            -- home, work, labelled favourites
  id TEXT PRIMARY KEY,                 -- UUID
  kind TEXT NOT NULL CHECK (kind IN ('home','work','favorite')),
  name TEXT NOT NULL,                  -- "Kampung", "Rumah Mertua" (≤ 40)
  icon TEXT NOT NULL DEFAULT 'star',   -- shared icon set
  lat REAL NOT NULL, lng REAL NOT NULL,
  address TEXT, place_id TEXT,         -- place_id = OSM/community id when saved from a place card
  sort_order INTEGER NOT NULL DEFAULT 0,
  created_at TEXT NOT NULL, updated_at TEXT NOT NULL);
CREATE UNIQUE INDEX ux_saved_home_work ON saved_places(kind) WHERE kind IN ('home','work');

CREATE TABLE recents (
  id TEXT PRIMARY KEY, name TEXT NOT NULL, address TEXT,
  lat REAL NOT NULL, lng REAL NOT NULL, place_id TEXT,
  last_used_at TEXT NOT NULL, use_count INTEGER NOT NULL DEFAULT 1);   -- keep the last 50

CREATE TABLE private_places (          -- "Just for me" places: never sent to the server
  id TEXT PRIMARY KEY, name TEXT NOT NULL, category TEXT NOT NULL,
  lat REAL NOT NULL, lng REAL NOT NULL, address TEXT, description TEXT,
  phone TEXT, website TEXT, opening_hours TEXT, amenities_json TEXT,
  created_at TEXT NOT NULL, updated_at TEXT NOT NULL);

CREATE TABLE private_place_photos (
  id TEXT PRIMARY KEY, place_id TEXT NOT NULL REFERENCES private_places(id) ON DELETE CASCADE,
  file_name TEXT NOT NULL,             -- WebP in the app's files dir: photos/<id>.webp
  created_at TEXT NOT NULL);

CREATE TABLE planned_drives (
  id TEXT PRIMARY KEY, name TEXT, origin_json TEXT, destination_json TEXT NOT NULL,
  waypoints_json TEXT, vehicle TEXT NOT NULL, depart_at TEXT, created_at TEXT NOT NULL);

CREATE TABLE personal_routes (         -- "Laluan saya": routes from the route builder (schema 3)
  id TEXT PRIMARY KEY,                 -- unique id (UUID or random b64u)
  name TEXT NOT NULL,                  -- ≤ 80
  mode TEXT NOT NULL CHECK (mode IN ('car','motorcycle','bicycle','walk')),
  route_json TEXT NOT NULL,            -- see "personal_routes.route_json" below
  distance_m INTEGER, duration_s INTEGER,   -- NULL = unknown (legs not calculated yet)
  created_at TEXT NOT NULL, updated_at TEXT NOT NULL);

CREATE TABLE settings (key TEXT PRIMARY KEY, value TEXT NOT NULL);

CREATE TABLE identity (                -- the contributor pseudonym's signing key (single row)
  user_id TEXT PRIMARY KEY, display_name TEXT,
  seed_b64 TEXT NOT NULL,              -- 32-byte Ed25519 seed; at rest wrapped with Keystore/Keychain key,
                                       -- in a backup protected only by the backup's own passphrase encryption
  created_at TEXT NOT NULL);  -- units, voice, avoid prefs, vehicle…

-- Not backed up (device-local queues):
CREATE TABLE outbox (id TEXT PRIMARY KEY, kind TEXT NOT NULL, payload_json TEXT NOT NULL,
  attempts INTEGER NOT NULL DEFAULT 0, next_attempt_at TEXT NOT NULL);   -- feedback, reports, uploads
```

**`personal_routes.route_json`** (identical on both platforms, so routes restore across them):

```jsonc
{ "v": 1,
  "points": [{ "lat": 3.5701, "lng": 101.6583 }, …],        // ≥ 2 once saved; WGS84, ≤ 6 decimals
  "legs": [{                                                 // legs.length == points.length - 1, leg i = point i → i+1
    "source": "routed",                                      // routed | matched | sketch | pending
    "polyline": "…",                                         // precision 6 (same as the routing API); "" when pending
    "distanceM": 12400, "durationS": 2880 }] }               // optional; absent = unknown, never 0
```

`matched` = a drawn line snapped to roads (`/routes/match`); the original finger stroke is not kept. `pending` = a
leg that still needs routing (offline); the app recalculates it when the route is opened. Unknown fields are ignored.
Writer rules: a matched leg with unmatched parts is stored as `sketch`; a failed leg (offline, no route) as `pending`.
Reader rules: "Ikut jalan" opens off only when every leg is `sketch`; a `route_json` with `v` > 1 is kept but not
shown; legs that don't fit the points become `pending`. Point ids and event-stop links are not stored.

Schema 3 adds only `personal_routes`; a schema-2 backup restores into it with no routes. Apps that kept personal
routes in the events database (`manotu-events.db` / events store, never backed up) move them here once on upgrade.
### Shared `settings` keys

Rows both apps read and write, so a backup made on one platform restores on the other. Values are text; dates are
ISO-8601 UTC. A **Merge** restore keeps this phone's value for a key that exists on both sides, except where noted.

| Key | Value | Merge restore |
|---|---|---|
| `sound_mode` | full / alerts only / mute | this phone wins |
| `voice_lang`, `vehicle`, `use_24h`, `show_traffic`, `show_alerts`, `show_drivers`, `theme` | Android's other choices (copied in just before a backup; iOS ignores them today) | this phone wins |
| `planned_drive:<id>` | the drive's schedule (JSON) | this phone wins |
| `blocked_authors` | **one JSON array** `[{"ref": "<authorRef>", "name": "<display name>", "blockedAt": "2026-10-24T03:00:00Z"}]`: contributors the user chose to hide (docs/api.md `authorRef`). On the device only, never sent. No row when nobody is blocked. Readers skip entries without a `ref` (never the whole list). | **union by `ref`** (this phone's entry wins for a ref on both sides) |
| `community_rules_version` | the community rules version the user accepted (an ISO date, e.g. `2026-10-24`); asked again when the app's version differs | the **later** version wins, together with its date |
| `community_rules_accepted_at` | when it was accepted (ISO-8601, fractional seconds allowed) | goes with `community_rules_version` |
| `safety.agreedVersion` | the safety agreement version the user agreed to (integer; docs/safety.md part 1); asked again when the app's version is higher | the **higher** version wins, together with its date |
| `safety.agreedAt` | when it was agreed (ISO-8601) | goes with `safety.agreedVersion` |
| `safety.reminderEnabled` | `true` / `false`: the safety card at the start of every drive (docs/safety.md part 2) | this phone wins |
| `safety.reminderDisabledAt` | when "Jangan tunjuk lagi" or the switch turned it off (ISO-8601) | goes with `safety.reminderEnabled` |

"Delete my Manotu account" with "also clear data on this phone" removes these rows with the rest of the local data.

Search merges server results with local `saved_places` and `private_places` matches
**on the device** (local hits first, marked with their icon). Private places are drawn on the map from the local DB only.

## Backup file format (`.gimano` / v1)

A ZIP container:

```
manifest.json   {format:1, schemaVersion, appVersion, platform, createdAt,
                 counts:{saved_places, recents, private_places, photos, planned_drives, personal_routes},
                 encryption: "none" | "passphrase-argon2id-xchacha20poly1305", kdf:{opslimit, memlimit, salt}}
data.sqlite     snapshot via `VACUUM INTO` (consistent, compact; outbox table dropped)
photos/*.webp   private-place photos
```

With a passphrase set, everything except `manifest.json` is encrypted with **libsodium**:
Argon2id (`crypto_pwhash`, moderate limits) derives the key, and `crypto_secretstream_xchacha20poly1305`
encrypts. Both platforms use the same libsodium (lazysodium-android / swift-sodium), so encrypted backups
restore across platforms. The passphrase is never stored or uploaded; if it's lost, the backup is
unrecoverable (the app says this clearly).

Restore modes: **Replace** (wipe, then import) or **Merge** (upsert by id, keep the newer
`updated_at`; home/work: keep the backup's). Imports older schemas by running the normal migrations on
a temp copy, then copying rows over.

## Destinations

| Destination | Android | iOS | Notes |
|---|---|---|---|
| **Google Drive, app-private folder** (`appDataFolder`, scope `drive.appdata`) | ✅ website APK (not in the Google Play build) | ✅ | Hidden folder in the user's own Drive that only Manotu can see. Cross-platform. Keeps the last 5 backups. |
| **iCloud** (CloudKit private database, record holding the backup file as a `CKAsset`) | — | ✅ | No sign-in needed; in the user's own iCloud quota. |
| **Android Auto Backup** (`dataExtractionRules`, the DB + photos only) | ✅ automatic | — | Free, zero-config, end-to-end encrypted by Android using the screen lock. Baseline safety net. |
| **Export / Import file** (share sheet / file picker) | ✅ | ✅ | Works with WhatsApp, email, USB, any cloud app. |

**Automatic backup:** optional daily backup to the chosen cloud, on Wi-Fi and while charging
(WorkManager / BGProcessingTask), only when data changed since the last backup.

**Google Play build (Android):** no Google Drive backup (owner decision 2026-10-24, `BuildConfig.DRIVE_BACKUP=false`):
no Drive destination, Google sign-in, Drive auto-backup or Drive restore. Backup and restore go through a file (and
demo storage in demo mode). The app says so on the Backup screen. The website APK keeps Drive.

**Settings → Backup & restore** screen: destination, last backup time and size, "Back up now",
"Restore…", auto-backup toggle, passphrase on/off.

## Server changes

- `/me/places` and `/me/recents` are **removed** from the API. On first launch of the new app version,
  any server-side favourites/recents for that device are downloaded once into the local DB, then
  deleted on the server (`DELETE /me/data`, which also deletes them for good).
- "Just for me" places are **never** sent to the server; only "Share with everyone" creates a
  community place via `POST /places`.
- `DELETE /me` deletes the account and every server-side record linked to it (reports are
  anonymised, not deleted, so the map stays accurate).

## Setup the owner must do (one-time)

- **Google Cloud project** with the Drive API enabled; OAuth consent screen (scope `drive.appdata`);
  OAuth client IDs for Android (package + SHA-1 of the debug/release keys) and iOS (bundle id).
  Client IDs go in git-ignored local config, like the iOS Team ID.
- **iCloud**: enable the iCloud/CloudKit capability with container `iCloud.my.gimano.app` in the Apple
  Developer account (Xcode can do this with automatic signing).
