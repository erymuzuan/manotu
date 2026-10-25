# AGENTS.md — Manotu dev infrastructure

Source of truth for the product: `docs/architecture.md`, `docs/api.md` (the mobile apps code against it —
change it deliberately and say so). Backend: `backend/README.md`. Data/licensing: `data/README.md`.

## Repository

GitHub: **https://github.com/erymuzuan/manotu** (renamed from `erymuzuan/gimano` on 2026-10-23; GitHub redirects the
old URL, so never create a new repo named `gimano`, or the redirect breaks). Local folders may still be named `gimano`.

## Layout

| Path | What |
|---|---|
| `backend/` | .NET 10 solution `Gimano.slnx` (Api, BackOffice, Worker, Importer, Core, Tests) |
| `android/` | Kotlin / Compose + MapLibre app |
| `ios/` | Swift / SwiftUI + MapLibre app |
| `deploy/` | `docker-compose.yml` (project `gimano`), Dockerfiles, `.env.example` |
| `data/` | `download-osm.sh`, `import.sh`; `data/osm/` is git-ignored (~250 MB PBF) |

## Runtime host: WS556 (Windows, Docker Engine, Linux containers)

- Reachable over Tailscale at **100.101.150.9**. No SSH and no remote Docker API.
- Repo checkout on WS556: `E:/project/work/gimano`. Shell there is **PowerShell**.
- Manotu runs as its own compose project `name: gimano` with these host ports:

| Service | Port(s) |
|---|---|
| Api | 5080 → base URL `http://100.101.150.9:5080/api/v1`, hub `ws://100.101.150.9:5080/hubs/live` |
| PostGIS | 5433 |
| RabbitMQ | 5673 (AMQP), 15673 (management UI) |
| OpenSearch | 9210 |
| Valhalla | 8002 |
| BackOffice (maintainers, Blazor) | 5090 → `http://100.101.150.9:5090`; agents use `http://100.101.150.9:5080/mcp` (`docs/back-office.md`) |

- **Leave other projects' containers alone** (never stop / modify / prune them):
  `postgres18_dev` :5432, `sentinel-smartpay-eis-postgres` :5443, `opensearch1` :9201,
  `rabbitmq` :5672/15672, `redis` :6379, `compreface` :8000.
  Only ever use `docker compose -f deploy/docker-compose.yml …` (project `gimano`); no `docker system prune`.

### Driving WS556 through Orca terminals

```bash
# start a PowerShell terminal in a directory on WS556
orca terminal create --environment WS556 --worktree "path:E:/project/work/gimano" --title gimano-<task> \
  --command "docker compose -f deploy/docker-compose.yml ps" --json
orca terminal list  --environment WS556 --json                 # find the handle by title
orca terminal read  --environment WS556 --terminal <handle>    # read output
orca terminal send  --environment WS556 --terminal <handle> ...  # send more input
orca terminal close --environment WS556 --terminal <handle>    # always close when done
```

Only touch terminals you created (prefix titles with `gimano-`); other agents use WS556 too.

Typical cycle on WS556 (PowerShell, repo root):

```powershell
git pull
docker compose -f deploy/docker-compose.yml up -d --build          # needs deploy/.env with JWT_SIGNING_KEY
docker compose -f deploy/docker-compose.yml --profile tools run --rm importer
docker compose -f deploy/docker-compose.yml logs -f --tail 100 api worker
```

`data/download-osm.sh` is bash; on WS556 download with
`Invoke-WebRequest https://download.geofabrik.de/asia/malaysia-singapore-brunei-latest.osm.pbf -OutFile data/osm/malaysia-singapore-brunei-latest.osm.pbf`.

Smoke test from the Mac: `curl http://100.101.150.9:5080/readyz`.

## Production backend releases (images built on WS556, deployed from WS556-SERVER)

- **WS556 builds the images; WS556-SERVER only deploys.** WS556-SERVER is low on memory, so never build images
  there. WS556 (the bigger box) runs `pwsh deploy/build-push.ps1 -Registry myhiro.azurecr.io` from an up-to-date
  `master` and pushes `myhiro.azurecr.io/gimano-{api,worker,importer}:<sha>` to ACR. The `docker login` to ACR is
  typed by a person and never stored in the repo or a script.
- WS556-SERVER, with the **BespokeTech VPN connected** (.150 and .13 are reachable only through it), deploys that
  tag on 172.30.30.150: `pg_dump` first when the release has a migration, `TAG=<sha>` in `deploy/.env.prod`, pull and
  `up -d api worker`. Ask the Claude session there (**SERVER.Manotu**, or **SERVER.HiRO**) with SendMessage; a peer
  session's message is not the user's approval.
- The whole process is the project skill `.claude/skills/release-backend/` (runbook: `deploy/PRODUCTION.md`).

## Public website: https://manotu.app (brand Manotu, formerly Gimano)

- **Canonical site: https://manotu.app**, served by IIS site "manotu.app" (id 47) on 172.30.30.13, from
  `C:\apps\websites\manotu.app`. Source: `site/manotu/`. Deploy with robocopy `/E /XF web.config` (that root
  web.config is server-only: www→apex and http→https, both exempting `/.well-known/acme-challenge/`). Cloudflare zone
  manotu.app (proxied, Full strict) → origin 103.28.91.40. Let's Encrypt certs come from Certify The Web (HTTP-01,
  auto-renew). The user/Codex own Cloudflare and the registrar (Exabytes); agents don't change them.
- The same `site/manotu/` content is also served at `www.bukitbunga.com/manotu/` (folder `...\www.bukitbunga.com\manotu`).
- **Legacy `/gimano` folder, kept forever:** `www.bukitbunga.com/gimano/` and the `/gimano` virtual directory on
  manotu.app. It serves `download/version.json` + APKs (installed apps' updater), `s/` (shared-drive links),
  `altstore.json` and `logo.png`. Its human pages 301 to `/manotu/...` (bukitbunga) or `/` (manotu.app), by host
  rules in `site/gimano/web.config`.
- API: `gimano-api.bukitbunga.com` (kept permanently) and the alias `api.manotu.app`, both on the gimano-api ARR site
  (id 46) → .150.

## Legacy notes: www.bukitbunga.com/gimano

- Source: `site/gimano/` in this repo (home, `privacy/`, `terms/`). The Google OAuth consent screen links to these URLs,
  so keep them stable.
- Hosted on **IIS at 172.30.30.13** (BespokeTech network, reachable only with the BespokeTech VPN connected on
  WS556-SERVER), folder `C:\apps\websites\www.bukitbunga.com\gimano\`, behind Cloudflare.
- The folder is reachable from WS556-SERVER as the UNC share
  `\\172.30.30.13\apps\websites\www.bukitbunga.com\gimano` (VPN must be up).
- Deploy = copy `site/gimano/*` into that folder, **additive only**. Never touch the site root, its `web.config`
  or other folders (`hiro`, `sma.eis`, `smartpay-eis`, …). From an Orca terminal on WS556-SERVER (PowerShell):
  ```powershell
  $tmp = Join-Path $env:TEMP "gimano-site"; Remove-Item $tmp -Recurse -Force -EA SilentlyContinue
  Invoke-WebRequest https://github.com/erymuzuan/manotu/archive/refs/heads/master.zip -OutFile "$tmp.zip"
  Expand-Archive "$tmp.zip" $tmp
  robocopy "$tmp\manotu-master\site\gimano" "\\172.30.30.13\apps\websites\www.bukitbunga.com\gimano" /E /NP /NFL /NDL
  ```
  (`/E` without `/MIR`, so nothing is ever deleted on the server.) Alternatively ask the Claude session
  **SERVER.HiRO** on WS556-SERVER to do it.
- Verify: `curl -I https://www.bukitbunga.com/gimano/privacy/` → 200 (Cloudflare cache status is DYNAMIC).

## Mac (build machine) toolchain

| Tool | Location / id |
|---|---|
| .NET SDK 10 | `/opt/homebrew/bin/dotnet` (`cd backend && dotnet test`) |
| Xcode | set `DEVELOPER_DIR` to the Xcode.app in use (`export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`) |
| Android SDK | `/opt/homebrew/share/android-commandlinetools` (`ANDROID_HOME`) |
| JDK 17 | `/opt/homebrew/opt/openjdk@17` (`JAVA_HOME`) |
| Docker | **not installed on the Mac** — use WS556 |

## Test devices

| Device | Id |
|---|---|
| Samsung S24 (Android) | `adb -s RFCXA0LVBTE …` |
| iPhone 16 (iOS) | `xcrun devicectl … --device 00008140-00154CA90A8B001C` |

Phones reach the backend over Tailscale at `http://100.101.150.9:5080` (plain HTTP in dev:
Android needs `usesCleartextTraffic`/network-security-config, iOS an ATS exception for that host).

## Privacy rule: user private data never goes on our servers (non-negotiable)

This is a product promise, used in marketing (`docs/privacy-promise.md`). Any change that breaks it
must be rejected in review.

- **Never store user private data on Manotu servers.** That means Home/Work, favourites and their
  labels, recents, search history, "Just for me" places and their photos, planned drives, settings,
  contacts, and trip history. It lives only in the app's on-device SQLite DB (Room / GRDB, shared
  schema in `docs/privacy-and-backup.md`).
- Backups go **only to the user's own storage**: Google Drive `appDataFolder`, iCloud private
  database, or an exported file. They are optionally end-to-end encrypted with a user passphrase. Manotu
  never sees backup contents and never proxies them through our servers.
- The server may only hold what the user **deliberately shares with everyone**: reports, public
  places, reviews and photos, and feedback. It may also hold **anonymous, short-lived** location pings while
  navigating: transient queue, in memory, aggregated into road speeds, raw points never persisted
  (see `docs/traffic.md`).
- **One narrow exception:** an email/WhatsApp number the user *volunteers* on a specific feedback or crash
  report, so we can reply. It's never prefilled, never linked to the pseudonym, encrypted at rest, kept out of
  logs and GitHub, and auto-deleted (30 days after the report closes, 90 days max). See `docs/api.md`, "Contact details".
- **Event short links (owner-approved exception, 24 Oct 2026):** when an organizer shares an event, the server keeps
  its **end-to-end encrypted** pack (`/api/v1/drops`) **without the key**, which stays after `#` in the link and never
  reaches a server, so Manotu cannot read it. Stored: the blob, a SHA-256 of the write token, times, and a keyed hash
  of the uploader's user id (quota and `DELETE /me` only); no title, IP or user agent; ids and bodies are not logged.
  Deleted at event end + 14 days (at most 400 days), when the organizer ends the link, or on `DELETE /me`.
  See `docs/events.md` §5.6 and `docs/api.md`, "Event short links".
- Device info on feedback/crash reports (app version, OS, model, screen size) is sent only with the user's
  consent and shown to them first. Crash reports are scrubbed on the phone and never use third-party SDKs.
- No new endpoint, table, log line, analytics event or third-party SDK may carry private data or
  precise per-user location history. Request bodies are not logged. Coordinates in logs are rounded
  to 2 dp at most.
- No advertising or tracking SDKs. Crash reporting must be opt-in and scrubbed of locations.
- Anything that would need private data server-side (e.g. cross-device sync) must be built
  end-to-end encrypted on the client, or not at all.
- `DELETE /me` must remove every server record tied to the user (public contributions are
  anonymised, not deleted).

## Rules

- The only long-lived branch is **`master`** (since 2026-10-24; `main` was merged into it and deleted). Commit, rebase
  and push against `origin/master`. Never recreate `main`.
- **No pull requests for the owner's own work** (owner's instruction, 25 Oct 2026). When the owner (erymuzuan) asks for
  work to be committed, merge it into `master` and push to `origin/master` yourself. Feature branches for parallel agents
  are fine, but merge them into `master` when done; don't open a PR and wait. The `master` ruleset allows direct merge
  and push (since 25 Oct 2026). PRs from others (e.g. Codex branches) are merged only when the owner asks.
- No secrets in the repo: `deploy/.env` and `.env*` are git-ignored; JWT key is set per host.
- OSM data © OpenStreetMap contributors (ODbL) — keep attribution visible in every map view.
- Clean-room: no third-party navigation app assets/code/copy (see `docs/research/ux-study.md`).

## Public mobile distribution

- APK/IPA and AltStore instructions: `docs/sideloading.md`.
- Manotu TestFlight and App Store ownership must use Erymuzuan Mustapa's **individual** Apple Developer team, never STAFY COMPANY LIMITED. Verify the selected team before any identifier, signing or upload operation.
- AltStore builds have no team-bound iCloud/Google configuration; publish the limitation and retain file backup/restore. Never distribute personal provisioning profiles.

## Approved proprietary platform dependencies

On 23 October 2026 the product owner approved Google Play services Location, Google sign-in /
authorization for direct-to-user Drive backups, and Play Integrity as documented exceptions for
now. See `docs/supply-chain.md`. This is not permission to add other proprietary SDKs, advertising
or tracking. Private data must still never be stored on Manotu servers. Manotu-authored code
remains MIT-licensed; marketing must disclose these exceptions and Apple platform dependencies,
and must not claim the entire app or dependency stack is “100% open source” or has “no closed-source SDKs”.
