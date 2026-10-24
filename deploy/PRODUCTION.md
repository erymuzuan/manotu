# Manotu API: production runbook

`https://gimano-api.bukitbunga.com` takes this path:

```
phone / browser ──TLS──▶ Cloudflare ──▶ 103.28.91.40 → IIS 172.30.30.13 (ARR, Let's Encrypt cert)
                                              │  global rules "Proxy-gimano-api.bukitbunga.com" → web farm gimano-api-docker
                                              ▼
                               172.30.30.150:5080  (Docker, compose project "gimano")
                               api ─┬─ postgis   (internal network only)
                                    └─ valhalla  (internal)
                               worker, importer (on demand)
                                    │
                                    ▼  shared services on 172.30.30.149
                               RabbitMQ (vhost "gimano", port 5673) · OpenSearch 3.0 (TLS, user "gimano", indices "gimano-*")
```

Privacy rule (AGENTS.md): the server only holds public contributions plus transient, anonymous
pings. Request bodies are never logged, and logs have no precise coordinates. Keep it that way in any
change to logging or proxies.

## Hosts

| Host | Role | Notes |
|---|---|---|
| **172.30.30.150** (web50) | Docker host | Ubuntu 26.04, 6 vCPU, ~13 GiB free RAM, ~20 GB free on `/`. Shared with about 25 other prod containers: every service has a memory limit. Docker needs `sudo`. |
| **172.30.30.149** | shared RabbitMQ + OpenSearch 3.0 | Provisioned per app: RabbitMQ vhost `gimano` + user; OpenSearch user `gimano` whose role only grants `gimano-*` (+ `indices:data/write/bulk`). |
| **172.30.30.13** | IIS + ARR 3 + URL Rewrite + WebSockets | TLS termination (Let's Encrypt). `deploy/iis/gimano-api.ps1` configures it. |
| WS556 | image build | `deploy/build-push.ps1` (PowerShell). Build here, not on WS556-SERVER (low on memory). |
| WS556-SERVER | deploy | BespokeTech VPN to .150/.13. Deploys the tag built on WS556; doesn't build images. |
| `myhiro.azurecr.io` | registry | Images `gimano-api`, `gimano-worker`, `gimano-importer`. |

## 1. Build and push images

On WS556, from an up-to-date checkout of `master` (the whole release is the skill `.claude/skills/release-backend/`):

```powershell
docker login myhiro.azurecr.io          # or: az acr login --name myhiro   (done by a person; never stored in scripts)
pwsh deploy/build-push.ps1 -Registry myhiro.azurecr.io            # tags :<git short sha> and :latest, prints digests
pwsh deploy/build-push.ps1 -Registry myhiro.azurecr.io -WhatIf    # dry run
```

```bash
deploy/build-push.sh myhiro.azurecr.io            # Linux (e.g. on .150: sudo -E deploy/build-push.sh …)
DRY_RUN=1 deploy/build-push.sh myhiro.azurecr.io
```

CI (`.github/workflows/ci.yml`) only runs `dotnet test`. It doesn't publish images.

### How .150 authenticates to ACR (pull only)

Prefer a **repository-scoped, pull-only token** over admin credentials or a personal `az` login:

```bash
# once, by an ACR admin (Azure CLI):
az acr scope-map create -r myhiro -n gimano-pull \
  --repository gimano-api content/read --repository gimano-worker content/read --repository gimano-importer content/read
az acr token create -r myhiro -n gimano-web50 --scope-map gimano-pull     # prints the password once
# on .150 (as the user that runs docker):
sudo docker login myhiro.azurecr.io -u gimano-web50       # paste the token password; stored in /root/.docker/config.json
```

Rotate it with `az acr token credential generate`. Today .150 is already logged in to ACR, which works, but
moving to the scoped token means a leak of that host's credentials can't push or read other repositories.

## 2. First deploy on .150

```bash
sudo mkdir -p /opt/gimano && sudo chown $USER /opt/gimano && cd /opt/gimano
git clone https://github.com/erymuzuan/manotu.git . # compose file, toll table, moderation lists (no secrets in the repo)
cp deploy/.env.prod.example deploy/.env.prod && chmod 600 deploy/.env.prod
# Fill in every CHANGE_ME (generation commands are in the file). Set TAG to the sha printed by build-push.
C="sudo docker compose -f deploy/docker-compose.prod.yml --env-file deploy/.env.prod"
$C pull
$C up -d postgis valhalla                          # Valhalla downloads the extract and builds tiles (20–40 min, 2 threads)
# RabbitMQ/OpenSearch are the shared .149 instances (RABBITMQ_*/OPENSEARCH_* in .env.prod). Self-hosting: add --profile local-infra.
$C up -d api worker                                # the API applies EF migrations on start
```

Import places, roads, water and tolls (about 5 minutes; needs the PBF for the duration only):

```bash
mkdir -p data/osm && curl -fL -o data/osm/malaysia-singapore-brunei-latest.osm.pbf \
  https://download.geofabrik.de/asia/malaysia-singapore-brunei-latest.osm.pbf
$C --profile tools run --rm importer
rm data/osm/malaysia-singapore-brunei-latest.osm.pbf          # 250 MB back
```

Once Valhalla reports healthy (`$C ps`), remove its copy of the extract. The tiles don't need it
(`use_tiles_ignore_pbf`):

```bash
$C exec valhalla sh -c 'ls -la /custom_files; rm -f /custom_files/*.osm.pbf'
```

Disk budget on .150 (target < 10 GB): Valhalla tiles for MY/SG/BN take about 1.5–2 GB and Postgres about 3 GB. Media grows
with photos. The OpenSearch index (about 0.3 GB) lives on .149. Check with `sudo docker system df -v | grep gimano`.

Smoke test from the LAN: `curl http://172.30.30.150:5080/readyz` should report all 4 checks healthy.

## 3. IIS on .13 (ARR) and the certificate

```powershell
# elevated PowerShell on 172.30.30.13, from a checkout or a copy of deploy/iis/gimano-api.ps1
.\gimano-api.ps1 -WhatIf                          # shows every change; touches nothing
.\gimano-api.ps1 -CertThumbprint <LE thumbprint>  # idempotent; re-run after each renewal if the ACME client doesn't rebind
```

It follows the server's existing pattern: web farm `gimano-api-docker` (→ 172.30.30.150:5080, health check `/healthz`),
the server-level rules `Redirect-HTTP-to-HTTPS-gimano-api.bukitbunga.com` and `Proxy-gimano-api.bukitbunga.com`
(`/.well-known/acme-challenge/` excluded, so HTTP-01 validation keeps working), and a plain site with :80/:443 SNI
bindings. It changes no global settings, except turning on the ARR proxy if it was off (it says so when it does).

- **WebSockets / SignalR**: `/hubs/live` needs the IIS WebSocket Protocol feature (installed) and `webSocket enabled` on the
  site (the script's `web.config`). ARR passes `Upgrade` through automatically. In Cloudflare, keep **WebSockets on**
  (Network tab). If WebSockets fail, the SignalR clients fall back to SSE or long polling.
- **Let's Encrypt**: issue `gimano-api.bukitbunga.com` with the ACME client already used on .13 (HTTP-01 via the excluded
  `/.well-known/acme-challenge/` path, or DNS-01). Renewal: if the client rebinds IIS itself, nothing else is needed;
  otherwise re-run the script with the new thumbprint (`-CertThumbprint`). Cloudflare SSL mode: **Full (strict)**.
- The proxy rule sets `X-Forwarded-Proto: https`. ARR adds `X-Forwarded-For`, and Cloudflare adds `CF-Connecting-IP`. The API
  trusts these only from `TRUSTED_PROXIES` (172.30.30.13), and its per-IP rate limit uses `CF-Connecting-IP`.

Public smoke test: `curl https://gimano-api.bukitbunga.com/readyz`, then sign in with `POST /api/v1/auth/device`.

## 4. Updates

```bash
cd /opt/gimano && sudo git fetch origin && sudo git checkout --detach <sha>   # root-owned checkout pinned to the release
# release with a migration: pg_dump first, into /opt/gimano/backups (the daily cron in §6 is not installed yet)
# after build-push printed a new sha:
sed -i 's/^TAG=.*/TAG=<sha>/' deploy/.env.prod
$C pull api worker importer && $C up -d api worker # migrations run on API start; ~5 s of downtime
```

- Toll table changed (`data/tolls/my-toll-rates.csv`): `$C --profile tools run --rm importer --tolls-only`.
- New OSM data (monthly): download the PBF, run the importer, delete the PBF. Rebuild Valhalla with
  `force_rebuild=True` once, or remove the `gimano_valhalla` volume and restart Valhalla.

## 5. Rollback

Images are immutable per sha. Set `TAG` back to the previous sha and run `$C up -d api worker`. EF migrations only move
forward. If a release added a migration that the old image can't handle, restore the pre-release dump (below) as
well. Every release that contains a migration should be preceded by a manual `pg_dump`.

## 6. Backups (Postgres)

Only public data lives in Postgres: OSM-derived tables (re-creatable), reports, community places, reviews, photo
metadata, feedback, and the anonymous device accounts. Back up daily and keep 14 days:

```bash
# /etc/cron.d/gimano-backup  (root)
15 3 * * * root cd /opt/gimano && docker compose -f deploy/docker-compose.prod.yml --env-file deploy/.env.prod exec -T postgis \
  pg_dump -U gimano -d gimano -Fc --exclude-table-data=road_segments --exclude-table-data=water_areas --exclude-table-data=places --exclude-table-data=drops \
  > /var/backups/gimano/gimano-$(date +\%F).dump && find /var/backups/gimano -name '*.dump' -mtime +14 -delete
```

`drops` (event short links: encrypted blobs the server can't read) is left out on purpose, so an ended or deleted
link never lingers in a backup; after a restore, organizers simply share again. The other excluded tables are rebuilt by the importer (they're only a few GB, but they're OSM data). Media (photos) live
in the `gimano_media` volume. Back them up with `docker run --rm -v gimano_media:/m -v /var/backups/gimano:/b alpine tar czf /b/media-$(date +%F).tgz -C /m .`,
or switch to S3-compatible storage (`Media__Provider=s3`, `Media__S3__*`). Restore: `pg_restore -c -d gimano`
inside the postgis container, then run the importer for the OSM tables.

## 7. Operations notes

- Logs: `$C logs -f --tail 200 api worker`. Docker keeps 5 × 20 MB per container.
- Health: `/healthz` (process) and `/readyz` (Postgres; OpenSearch, RabbitMQ and Valhalla degrade gracefully).
- API docs (Scalar/OpenAPI) are off in Production (`Features__ApiDocs=false`).
- Rate limit: `RATE_LIMIT_PER_MINUTE` per client IP (default 600) → 429 with `Retry-After`.
- Request bodies are capped at 4 MB; photo uploads at 15 MB on `/api/v1/photos` only.
- OpenSearch is the shared 3.0 cluster on .149. Everything Manotu creates goes through `OPENSEARCH_INDEX_PREFIX`
  (`gimano-`). The importer fills a new physical index `gimano-places-<timestamp>` and swaps the alias `gimano-places`
  atomically, so search stays up during re-imports. `/readyz` uses `HEAD gimano-places` (no `cluster:monitor` needed).
  `OPENSEARCH_ALLOW_INVALID_CERT=true` skips certificate validation for that connection only (demo cert). Set it to
  false once .149 has a trusted certificate.
- RabbitMQ is the shared broker on .149, vhost `gimano`: the durable `gimano.events` exchange plus queues `gimano.worker.*`,
  and the transient `gimano.locations` exchange (exclusive auto-delete queue, 30 s TTL, drop-head).
- Share links (`/api/v1/shares`) live in API memory: a single API instance is assumed. If the API ever scales out,
  move them to a shared store (Redis), still in memory and never persisted.
- Event short links (`/api/v1/drops`) are in Postgres (table `drops`, ciphertext only, no key). The worker purges expired and
  deleted links hourly, so keep the worker running. `DROPS_OWNER_KEY` in `.env.prod` (optional, see the example file).
