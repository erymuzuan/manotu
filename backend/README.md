# Manotu backend

.NET 10 backend for Manotu: REST + SignalR API, background worker, and OSM importer.
Contract: [`docs/api.md`](../docs/api.md) · design: [`docs/architecture.md`](../docs/architecture.md).

```
backend/
  Gimano.slnx
  Directory.Build.props / Directory.Packages.props   (central package management)
  global.json                                         (.NET 10 SDK, Microsoft.Testing.Platform)
  src/Gimano.Core       domain, contracts (DTOs), EF Core DbContext + migrations, rules
                        (alerts, jams, OSM mapping, search query, Valhalla mapping), RabbitMQ/OpenSearch plumbing
  src/Gimano.Api        minimal APIs (/api/v1), JWT device auth, SignalR /hubs/live, Valhalla proxy, health, OpenAPI,
                        agent API /admin/v1 + MCP server /mcp (docs/back-office.md)
  src/Gimano.BackOffice Blazor back office for maintainers: feedback, crash groups, agent runs/tokens (Identity + passkeys)
  src/Gimano.Worker     RabbitMQ consumers: TrafficAggregator, AlertLifecycle, SearchIndexer (+ jam publisher, expiry sweeper, drop purge)
  src/Gimano.Importer   OSM PBF → Postgres (places, road_segments) + OpenSearch `places` index
  tests/Gimano.Tests    xUnit v3 unit tests
```

## Run everything with Docker (recommended)

From the repo root:

```bash
cp deploy/.env.example deploy/.env        # replace every CHANGE_ME (openssl rand -base64 32)
docker compose -f deploy/docker-compose.yml up -d --build
data/download-osm.sh                       # ~250 MB Geofabrik extract → data/osm/
docker compose -f deploy/docker-compose.yml --profile tools run --rm importer   # ~2–5 min
curl http://localhost:5080/readyz
```

| Service | Host port (default) | Notes |
|---|---|---|
| api | 5080 | `/api/v1`, `/hubs/live`, `/healthz`, `/readyz`, `/openapi/v1.json`, `/scalar/v1` |
| postgis | 127.0.0.1:5433 | PostgreSQL 17 + PostGIS 3.5, db/user `gimano`, password from `deploy/.env` |
| opensearch | 127.0.0.1:9210 | 2.x single node, security plugin disabled (dev only, never published) |
| rabbitmq | 127.0.0.1:5673 / 15673 | AMQP / management UI, user `gimano`, password from `deploy/.env` |
| valhalla | 127.0.0.1:8002 | builds routing tiles from the Geofabrik extract on first start (10–30 min) |
| backoffice | 5090 | maintainer back office; Tailscale only (set `BACKOFFICE_MAINTAINER`, `FEEDBACK_CONTACT_KEY`) |
| worker | – | consumes `gimano.events` |

All ports are overridable in `deploy/.env`. Until Valhalla has finished building tiles,
`POST /api/v1/routes` returns **503** with a problem+json body and `/readyz` reports `valhalla: degraded`.

## Run the .NET apps locally against the stack

No credentials are committed. `appsettings.json` has connection strings **without** passwords, pointing at the
compose host ports on `localhost` (Postgres 5433, OpenSearch 9210, RabbitMQ 5673, Valhalla 8002). The infrastructure
ports are bound to 127.0.0.1, so run the apps on the Docker host, or tunnel to it. Supply secrets with
`dotnet user-secrets` (stored outside the repo) or with environment variables, using the same values as `deploy/.env`:

```bash
cd backend
for p in src/Gimano.Api src/Gimano.Worker src/Gimano.Importer src/Gimano.BackOffice; do
  dotnet user-secrets --project $p set "Postgres:Password" "<POSTGRES_PASSWORD from deploy/.env>"
  dotnet user-secrets --project $p set "RabbitMq:Password" "<RABBITMQ_PASSWORD from deploy/.env>"
done
dotnet user-secrets --project src/Gimano.Api set "Jwt:SigningKey" "$(openssl rand -base64 48)"   # optional in Development

dotnet run --project src/Gimano.Api          # http://0.0.0.0:5080
dotnet run --project src/Gimano.Worker
dotnet run --project src/Gimano.BackOffice   # http://localhost:5090
dotnet run --project src/Gimano.BackOffice -- invite me@example.com   # one-time registration link (no self-registration)
dotnet run --project src/Gimano.Importer -- --dry-run   # parse the extract only, no DB needed (~30 s)
```

Or use environment variables: `Postgres__Password`, `RabbitMq__Password`, `Jwt__SigningKey`, or a full
`ConnectionStrings__Postgres`. In Development, if no JWT key is set, the API generates an ephemeral one
(tokens stop working after a restart). In any other environment it refuses to start without one.

`dotnet ef` reads the design-time connection string from `GIMANO_PG`:
`export GIMANO_PG="Host=localhost;Port=5433;Database=gimano;Username=gimano;Password=$POSTGRES_PASSWORD"`.

The API applies EF Core migrations on start (`Database:MigrateOnStartup`, default `true`); the importer does too.

## Build & test

```bash
cd backend
dotnet build
dotnet test            # Microsoft.Testing.Platform (configured in global.json)
```

## Configuration

| Key | Default | |
|---|---|---|
| `ConnectionStrings:Postgres` | `Host=localhost;Port=5433;…` (no password) | password via `Postgres:Password` or the full string from env |
| `OpenSearch:Url` | `http://localhost:9210` | optional `OpenSearch:User` / `Password` |
| `RabbitMq:Host/Port/User/Password` | `localhost` / `5673` / `gimano` / *(none — secret)* | |
| `Valhalla:Url` | `http://localhost:8002` | |
| `Jwt:SigningKey` | *(none; ephemeral random key in Development)* | ≥ 32 chars, **required outside Development** |
| `Jwt:Issuer` / `Jwt:Audience` / `Jwt:LifetimeDays` | `gimano` / `gimano-app` / `365` | |
| `Urls` | `http://0.0.0.0:5080` | bound on all interfaces so phones on the LAN/Tailscale can connect |
| `Feedback:ContactKey` | *(none)* | api + backoffice: base64 of 32 bytes; unset = volunteered contacts are dropped (api) / can't be revealed (backoffice) |
| `Drops:OwnerKey` | *(none; derived from the JWT key)* | api: base64 of ≥ 32 bytes, keys the owner hash of event short links (quota, `DELETE /me`). Set it in production so a JWT key rotation doesn't detach drops from their owners |
| `Cors:DropViewerOrigins` | `https://manotu.app,https://www.bukitbunga.com` | api: origins allowed to `GET /drops/{id}` |
| `RateLimit:DropReadsPerMinute` | `30` | api: per-IP `GET /drops/{id}` limit (in memory) |
| `Admin:Enabled` / `AllowPublic` / `AllowedNetworks` | `true` / `false` / `[]` | api: guards the agent endpoints `/admin/v1` and `/mcp` |
| `BackOffice:Maintainers` | `[]` (`["*"]` in Development) | backoffice: emails allowed to register / sign in |
| `BackOffice:ApiBaseUrl` | `http://100.101.150.9:5080` | backoffice: shown in the MCP setup command |
| `BackOffice:PublicUrl` | `http://100.101.150.9:5090` | backoffice: base of the invite links printed by `invite <email>` |
| `DataProtection:KeysPath` | *(none)* | backoffice: persist cookie keys (set in compose) |

## Maintainer view (feedback & crash reports)

`/api/v1/admin/*` with header `X-Admin-Key: <ADMIN_KEY>` (disabled when `Admin:Key` is empty):
`GET feedback?status=`, `PATCH feedback/{id} {status}` (done/wont_fix starts the 30-day contact deletion),
`GET feedback/{id}/screenshot`, `GET crash-groups`, `GET crash-groups/{signature}/reports`,
`PATCH crash-groups/{signature} {status}`, and `POST contacts/{feedback|crash}/{id}/reveal`. Reveal is the only way to see a
volunteered contact. It's audit-logged (subject, id, key fingerprint, IP) without the values.
The Blazor back office (`src/Gimano.BackOffice`, port 5090) and the agent API (`/admin/v1`, `/mcp`) are the fuller
version of this: [`docs/back-office.md`](../docs/back-office.md).

## Migrations

```bash
cd backend
dotnet tool restore
dotnet ef migrations add <Name> -p src/Gimano.Core -s src/Gimano.Api -o Data/Migrations
# back-office maintainer accounts (schema "backoffice"; applied by the back office on start)
dotnet ef migrations add <Name> -p src/Gimano.BackOffice -s src/Gimano.BackOffice -o Data/Migrations -c ApplicationDbContext
```

## Behaviour notes

- **Search** uses OpenSearch (`search_as_you_type` + gauss geo decay + popularity, soft MY preference).
  If OpenSearch is down it falls back to a Postgres `ILIKE` search ordered by distance.
- **Routing** proxies Valhalla (`auto` / `motorcycle` costing, `use_tolls/highways/ferry` = 0 when avoided),
  maps maneuvers to the contract, attaches active reports within 40 m of the route (direction-aware),
  overlays live jams as `trafficSegments`, re-scores durations and re-ranks (`best` first).
- **Traffic**: pings are snapped (≤ 25 m, heading-compatible) to ~300 m `road_segments`; a 5-minute rolling
  mean per segment; jam when `< 0.5 × free-flow` with ≥ 3 distinct users; jams recomputed every 30 s.
- **Alerts**: TTLs, “still there” extension (+50 % of base, max 3×), “not there” expiry (reputation-weighted ×2),
  150 m same-heading de-duplication — see `Gimano.Core/Alerts/AlertRules.cs`.
- **Countries** (MY/SG/BN) are resolved with simplified border polygons (`CountryResolver`), not admin relations.

## Place-search coverage and corrections

The October 2026 search update adds strict `viewport` polygons, category-aware locality parsing, durable
accepted corrections and permanent-closure indexing. See [the API contract](../docs/api.md#finding-places-get-search),
[import/reindex rollout notes](../data/README.md#public-destination-coverage) and
[validation evidence](../docs/research/place-search-2026-10-26/implementation.md). Deploy the API and worker together,
apply `AcceptedPlaceCorrections` and `StreetSearchCorrections`, then recreate the search index through the importer.
Never promote a stale retained index without replaying current corrections and closures.
