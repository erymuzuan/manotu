# Gimano for iOS

Native iOS client for Gimano, the community navigation app for Malaysia. Gimano's own code is MIT-licensed; Apple platform frameworks it uses are listed in Settings → About → Platform components.
Swift 6, SwiftUI (iOS 17+), Observation, async/await, MapLibre Native.

- Behaviour spec: [`docs/research/ux-study.md`](../docs/research/ux-study.md)
- Visual system "Cobalt": [`docs/design-tokens.md`](../docs/design-tokens.md), icons in [`docs/icons/gimano-icons.json`](../docs/icons/gimano-icons.json)
- Backend contract: [`docs/api.md`](../docs/api.md)

## Open / build

The generated `Gimano.xcodeproj` is committed, so you can open it in Xcode directly.
If you change `project.yml`, regenerate it:

```sh
brew install xcodegen      # once
cd ios && xcodegen generate
```

Command line (Xcode lives at /Applications/Xcode.app, so override `xcode-select`):

```sh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
xcodebuild test  -project Gimano.xcodeproj -scheme Gimano -destination 'platform=iOS Simulator,name=Gimano iPhone 17'
xcodebuild build -project Gimano.xcodeproj -scheme Gimano -destination 'generic/platform=iOS' -allowProvisioningUpdates
xcrun devicectl device install app --device <UDID> <DerivedData>/Build/Products/Debug-iphoneos/Gimano.app
```

Bundle id `my.gimano.app`, automatic signing. Your Apple Developer Team ID is kept out of git:

```bash
cp Config/Local.xcconfig.example Config/Local.xcconfig   # git-ignored
# then set DEVELOPMENT_TEAM = <your team id>  (security find-identity -v -p codesigning)
```

`Config/Signing.xcconfig` (committed) includes it via `#include? "Local.xcconfig"`.

## Configuration

| Setting | Where | Default |
|---|---|---|
| API base URL | `GIMANO_API_BASE_URL` build setting → `GimanoAPIBaseURL` Info.plist key | Debug: `http://100.101.150.9:5080/api/v1/` (WS556 over Tailscale). Release: `http://localhost:5080/api/v1/` (placeholder until a production host exists) |
| Map style | `GIMANO_MAP_STYLE_URL` → `GimanoMapStyleURL` | `https://tiles.openfreemap.org/styles/liberty` |
| Overrides | In-app **Menu → Developer settings** (persisted in UserDefaults) | API URL, data mode, style URL, drive simulation |
| Universal Links | `MANOTU_APPLINKS` (`Config/Signing.xcconfig`) → adds `applinks:manotu.app` (Associated Domains) to the entitlements | `NO`: needs the Associated Domains capability on the App ID first. Without it, `/j/` and `/a/` links open the web page, whose "Buka di Manotu" opens the app via `manotu://` |

Debug uses `Resources/Info-Debug.plist`, which adds an ATS exception for the cleartext dev host
(`100.101.150.9`) plus `NSAllowsLocalNetworking`. Release uses `Resources/Info.plist` and is ATS-strict.
The two plists are maintained by hand, so keep them in sync.

### Data modes

- **Auto** (default): calls the backend and falls back to demo data when it can't be reached
  (transport errors back off for 30 s) or when an endpoint is missing (404/5xx). A "Demo mode" badge shows on the map.
- **Live**: backend only, and errors are surfaced.
- **Demo**: fully offline. Kuala Lumpur places, live alerts/jams/drivers, and **real-road routes**.

Demo routes come from `Resources/DemoRoutes.json`: 8 destinations from a fixed KL origin, 2–3
alternatives each, in the exact `Route` contract shape (precision-6 polylines, maneuvers with shape
indexes). They were captured once from OpenStreetMap data through the public OSRM demo server
(© OpenStreetMap contributors, ODbL). **Demo mode never fabricates geometry.** A trip outside the captured set gets
the captured routes to the nearest captured destination, labelled "Demo route: …" in the preview.
Demo jams are 300–800 m slices of those routes; demo alerts and nearby-driver dots sit on their vertices.
A unit test asserts every one of them lies within 15 m of a captured polyline.

## Architecture

```
Gimano/
  App/            GimanoApp + RootView, AppModel (central @Observable store), AppConfig, LiveMapStore
  DesignSystem/   Cobalt tokens (colours, sizes, Nunito type), components, duotone icon renderer
                  (SVG path parser → SwiftUI Shape / CGContext), IconData.swift (generated)
  Models/         Codable DTOs matching docs/api.md, report catalogue
  Networking/     APIClient (actor, URLSession), GimanoRepository protocol,
                  LiveRepository (REST + device auth + 401 retry), DemoRepository (actor),
                  FallbackRepository (auto mode), LiveHubClient (SignalR JSON protocol over
                  URLSessionWebSocketTask: handshake, Subscribe(bbox), pings, reconnect), Keychain
  Navigation/     Polyline (precision 6), Geo, RouteTracker (snap/progress), OffRouteDetector,
                  LocationPingBatcher (5 s / 12 per POST), formatters, VoiceGuide (AVSpeechSynthesizer
                  en/ms), LocationService (CoreLocation, background while navigating), DriveSimulator,
                  NavigationSession
  Map/            MapLibre MLNMapView in UIViewRepresentable. Layers: jams, routes + traffic, alerts,
                  drivers, destination, puck. Camera modes. Duration-bubble projection.
  Features/       Home, Search, Place, Route (preview), Drive (navigation), Report, Menu, Settings
  Resources/      Info plists, Assets (Wau app icon + dark variant), Localizable.xcstrings (en + ms),
                  Fonts/Nunito.ttf (+ OFL licence), DemoRoutes.json
GimanoTests/      Swift Testing suites
```

Navigation flow: a `LocationFix` comes from CoreLocation or `DriveSimulator` and goes to `NavigationSession.handle`.
`RouteTracker` snaps it to the route and updates progress, upcoming maneuver and the "then" strip.
`VoiceAnnouncer` speaks early and near prompts. `OffRouteDetector` needs 3 consecutive fixes beyond
max(40 m, 1.2 × accuracy), with a 10 s cooldown, before calling `POST /routes/{id}/reroute` (falling back to `POST /routes`).
Alerts on the route within 600 m raise the "Still there? / Not there" card. Pings are batched to `POST /locations`.
Toll plazas ahead (`TollTracker`), camera modes (`CameraModeController`: Simpang > Tinjau > Perlahan / Bandar /
Lebuh raya) and the steady arrow (`PuckAnimator`, `HeadingFilter`, `SnapHysteresis`) follow docs/driving.md §1–3.
`DriveMotion` turns fixes into per-frame arrow positions and camera values; the map's `CADisplayLink` draws the arrow
and moves the camera every frame (only the puck source changes per frame). Arrival (§4): ≤ 30 m along the route or
≤ 40 m from the pin, dotted last metres to the entrance (`Route.arrival`), side of the entrance on the arrival card.

### CarPlay (docs/driving.md §5)

`CarPlay/`: a `CPTemplateApplicationScene` (Info.plist scene manifest) whose `CarPlayController` drives the templates
from the same `AppModel` and `NavigationSession` as the phone (one voice), and draws our own map in the car window
(`CarMapViewController`, same layers and `DriveMotion`). The CarPlay navigation entitlement
(`com.apple.developer.carplay-maps`) is not granted yet, so only **simulator** builds carry it
(`Resources/CarPlaySim/*.entitlements`, selected by `[sdk=iphonesimulator*]` in `Config/Signing.xcconfig`); device,
TestFlight and AltStore builds keep today's entitlements and profiles. Note: Xcode 27's Device Hub has no CarPlay
external display, so the templates need Apple's CarPlay Simulator app or a car; `-GimanoCarPreview YES` shows the car
map surface (800 × 480) on the phone for screenshots.

## Personal data: on device only (docs/privacy-and-backup.md)

Home/Work, labelled favourites (Kampung, Rumah Mertua…), recents, "Just for me" places, planned drives
and settings live in `Storage/LocalStore.swift` (GRDB, SQLite), using **exactly** the shared schema from
the doc (`PRAGMA user_version` versioning, no GRDB migration table, so snapshots contain only shared
tables). They are never sent to the server. On first launch the app imports any legacy server copy
(`GET /me/data/export`, then `DELETE /me/data`; 404/410 is ignored).

### Backup & restore (Settings, or Menu → Backup & restore)

- **iCloud**: CloudKit private DB, container `iCloud.my.gimano.app`, one `GimanoBackup` record per backup (file as a
  `CKAsset`) plus a fixed `GimanoBackupIndex` record. Keeps the last 5. Requires an Apple ID in Xcode
  → Settings → Accounts so automatic signing can register the container. Until then, build with
  `GIMANO_ICLOUD=NO` (on the command line or in `Config/Local.xcconfig`); the app then shows "iCloud isn't enabled in this build".
- **Google Drive** `appDataFolder` (scope `drive.appdata`) via GoogleSignIn-iOS + Drive REST. Copy
  `Config/Google.xcconfig.example` to `Config/Google.xcconfig` (git-ignored) with the iOS OAuth client id;
  without it the screen says "not configured".
  **Store/TestFlight build: no Drive** (owner decision 2026-10-24). Build setting `GIMANO_DRIVE` (default `YES` in
  `Config/Signing.xcconfig`, Info.plist key `GimanoDriveEnabled`, read by `GoogleDriveBackupDestination.isEnabled`).
  With `GIMANO_DRIVE=NO` there is no Drive destination, no Google sign-in, no Drive auto-backup or restore, and
  Info.plist carries an empty `GIDClientID` and a placeholder URL scheme. The backup screen says "Google Drive backup
  isn't available in this version. Backup to a file works." The GoogleSignIn package stays linked but is unreachable.
  `scripts/testflight.sh` defaults to `GIMANO_ICLOUD=NO GIMANO_DRIVE=NO`.
- **File**: export a `.gimano` file (ShareLink) / restore with the file importer, or open one from Files/WhatsApp
  (UTType `my.gimano.backup`).
- Optional daily auto-backup (`BGProcessingTask` `my.gimano.app.backup`, charging + network, only if data changed).
  Auto-backups are unencrypted, because the passphrase is never stored.
- Restore modes: **Replace** or **Merge** (upsert by id, newer `updated_at` wins; Home/Work from the backup;
  recents keep the newer `last_used_at` and the larger `use_count`; local settings are kept).

### `.gimano` v1 byte layout (for cross-platform interop; please mirror on Android)

```
zip (plain):      manifest.json, data.sqlite, photos/<id>.webp
zip (encrypted):  manifest.json, payload.enc
payload.enc     = libsodium crypto_secretstream_xchacha20poly1305 over an inner zip { data.sqlite, photos/* }
                  [24-byte header][chunk]…  chunk = 65 536 plaintext bytes + 17 (ABYTES); last chunk tag FINAL,
                  all others MESSAGE (no additional data)
key             = crypto_pwhash(32 bytes, passphrase UTF-8, salt, opslimit, memlimit, ALG_ARGON2ID13)
manifest.kdf    = {"alg":"argon2id13","opslimit":…,"memlimit":…,"salt":"<base64 16 bytes>","chunkSize":65536}
                  (iOS writes crypto_pwhash_OPSLIMIT_MODERATE / MEMLIMIT_MODERATE; readers must use the manifest values)
data.sqlite     = `VACUUM INTO` snapshot, `outbox` table dropped, user_version = schema version
timestamps      = ISO-8601 UTC text (`2026-10-23T01:02:03.123Z`); merge compares with julianday()
```

## Community places, reviews & photos

- **Add a place**: from search ("Can't find it? Add a place"), the side menu, or a long-press on the map.
  A centre pin over a movable map (reverse-geocoded address), then name, a category icon grid, photos (PhotosPicker
  or camera; downscaled on the device to ≤ 2048 px JPEG, HEIC converted, metadata incl. GPS stripped), an
  opening-hours editor (day chips + 24 h ranges + Closed → OSM `opening_hours`, see `Navigation/OpeningHours.swift`),
  then "Just for me" (local `private_places`, photos as WebP via libwebp, never sent) or "Share with everyone"
  (`POST /places` + `POST /photos` with upload progress; a 409 duplicate offers "Is it this one?").
- **Place card**: Community / Unverified / Just for me badges, "Is this place here?" (`/verify`), "Suggest an edit"
  (any place, incl. OSM), photo strip + full-screen viewer, rating summary with distribution ("New" under 3 reviews),
  reviews (helpful, flag), write/edit one review per place with up to 5 photos.
- **My contributions** (menu): `GET /me/places/contributed` plus local private places.
- Demo mode implements all of it (WebP photos written locally) so the flows work offline.

## Planned drives, Share my drive, Theme

- **Planned drives** (menu, or route preview → Leave later → "Plan this drive"): on device in `planned_drives`;
  one-off or repeating weekdays; "Leave by" from `GET /routes/departure-times` (hourly slots, interpolated);
  local notifications 15 min before; tapping one opens route preview. The schedule lives in the shared `settings`
  table: `planned_drive:<id>` = `{"arriveBy":"HH:mm","days":["Mo",…]}` (repeating) or `{"arriveAt":"<ISO>"}`
  (one-off), and `depart_at` = the computed leave-by for one-off drives. *Proposed convention; please mirror on Android.*
- **Share my drive** (trip sheet → Share drive): a 256-bit key generated on the device; link
  `https://www.bukitbunga.com/gimano/s/#<shareId>.<base64url key>`; every 15 s an XChaCha20-Poly1305-IETF blob
  (AD = shareId) is PUT with `Authorization: Share <writeToken>`. Ends on arrival, Stop, "Stop sharing" or expiry.
  The key exists only in memory and in the link.
- **Theme**: Light (default, even when iOS is in Dark mode), Dark, Follow phone, Auto day/night (sunrise/sunset).
  Dark uses the OpenFreeMap `dark` basemap.

## Icons

`DesignSystem/IconData.swift` is generated from `docs/icons/gimano-icons.json`:

```sh
python3 - <<'EOF'
import json
d=json.load(open('docs/icons/gimano-icons.json'))
out=['// Generated from docs/icons/gimano-icons.json — do not edit by hand.','','enum GimanoIconData {',
     '    static let grid: Double = %d' % d['grid'],'    static let paths: [String: String] = [']
out+=['        "%s": "%s",' % kv for kv in d['icons'].items()]
out+=['    ]','}','','enum GIcon: String, CaseIterable, Sendable {']+['    case %s' % k for k in d['icons']]+['}','']
open('ios/Gimano/DesignSystem/IconData.swift','w').write('\n'.join(out))
EOF
```

## Localization

`Resources/Localizable.xcstrings` holds English (source) and Bahasa Melayu. Voice guidance uses the
app language: `ms-MY` voice, falling back to `id-ID` and then English if no Malay voice is installed.

## Debug launch arguments (screenshots / demos)

`-GimanoDataMode demo|auto|live`, `-GimanoSimulateDrive YES`,
`-GimanoDemoScene search|place|route|route-far|nav|report|menu|overview` (DEBUG builds only), `-GimanoDemoQuery <text>`,
`-GimanoFreshDevice YES` (new anonymous device, wipes local data), `-GimanoSkipOnboarding YES`,
`-GimanoFakeLocation lat,lng`, `-GimanoNoAutoStart YES` (no Go-now countdown).
Route replays: `-GimanoDriveTo "Name|lat,lng|placeId"` (plans and starts a drive from the fake location),
`-GimanoSimSpeed route` (maneuver speeds), `-GimanoSimTick 1` (one fix a second), `-debug.simulationSpeedup 1`,
`-GimanoFakeJam <metres>` (a memory-only jam on the replayed route), `-GimanoSkipSafety YES` (this launch only),
`-GimanoCarPreview YES`, `-GimanoCarScene places|search|report|agreement` (CarPlay).

## UI tests (real device)

`GimanoUITests` drives the main scenarios against the live backend and attaches screenshots:

```sh
xcodebuild test -project Gimano.xcodeproj -scheme Gimano -destination id=<device-udid> \
  -allowProvisioningUpdates GIMANO_ICLOUD=NO -only-testing:GimanoUITests -resultBundlePath out.xcresult
xcrun xcresulttool export attachments --path out.xcresult --output-path shots/
```

The phone must be unlocked, and it needs Tailscale on to reach WS556.

## Licences / attribution

Map data © OpenStreetMap contributors (ODbL), shown on the map. Tiles: OpenFreeMap. Renderer: MapLibre Native (BSD).
Nunito font: SIL Open Font License 1.1 (`Resources/Fonts/Nunito-OFL.txt`).
