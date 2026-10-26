# Manotu architecture

Manotu is an open-source, community-driven navigation app for Malaysia. It
works the way Waze users expect (see [research/ux-study.md](research/ux-study.md))
and is built entirely on open data from OpenStreetMap.

```
 ┌──────────────┐   ┌──────────────┐
 │ Android app  │   │   iOS app    │   Kotlin/Compose + MapLibre   |   Swift/SwiftUI + MapLibre
 └──────┬───────┘   └──────┬───────┘
        │ HTTPS JSON + SignalR (WebSocket)
 ┌──────▼──────────────────▼───────┐
 │          Gimano.Api             │  ASP.NET Core (.NET 10) minimal APIs, SignalR hub
 └──┬──────────┬─────────┬─────────┘
    │          │         │ publish
    │          │   ┌─────▼──────┐     ┌────────────────┐
    │          │   │  RabbitMQ  ├────►│ Gimano.Worker  │  traffic aggregation, alert lifecycle,
    │          │   └────────────┘     └──┬──────────┬──┘  search indexing
    │          │                         │          │
 ┌──▼──────────▼─┐  ┌──────────────┐  ┌──▼───────┐  │
 │ PostgreSQL 17 │  │  OpenSearch  │◄─┤          │◄─┘
 │  + PostGIS    │  │  (POI search)│  └──────────┘
 └───────────────┘  └──────────────┘
    ▲                       ▲
    │   ┌───────────────────┴──┐       ┌──────────────┐
    └───┤   Gimano.Importer    │◄──────┤ Geofabrik OSM│  malaysia-singapore-brunei-latest.osm.pbf
        └──────────────────────┘       └──────────────┘
 ┌──────────────┐
 │   Valhalla   │  routing engine (car + motorcycle costing, avoid tolls/highways/ferries,
 └──────────────┘  alternates, turn-by-turn), built from the same OSM extract
```

## Components

| Component | Tech | Responsibility |
|---|---|---|
| `backend/src/Gimano.Api` | ASP.NET Core 10, EF Core + Npgsql/NetTopologySuite, OpenSearch.Client, RabbitMQ.Client, SignalR | Public REST API, auth, live push |
| `backend/src/Gimano.Worker` | .NET 10 worker service | Consumes queues: location pings → road-segment speeds → jams; report votes → alert TTL; POI changes → OpenSearch |
| `backend/src/Gimano.Importer` | .NET 10 console, OsmSharp | Reads OSM PBF, extracts POIs into Postgres and OpenSearch |
| `backend/src/Gimano.Core` | class library | Domain model, contracts shared by Api/Worker/Importer |
| PostgreSQL + PostGIS | 17 / 3.5 | Users, places, reports, votes, jams, traffic segments |
| OpenSearch | 2.x | `places` index: search-as-you-type + geo-distance decay |
| RabbitMQ | 4.x | `gimano.events` topic exchange |
| Valhalla | 3.x | Routing; the API proxies it and decorates routes with alerts and traffic |
| Map tiles | OpenFreeMap vector tiles (dev) / self-hosted PMTiles (prod) | Basemap rendered by MapLibre on device |

## Messaging (RabbitMQ)

Exchange `gimano.events` (topic, durable).

| Routing key | Producer | Consumer | Payload |
|---|---|---|---|
| `location.ping` | Api (`POST /api/v1/locations`) | Worker `LocationStreamConsumer` | **transient exchange `gimano.locations`** (see below): `[{s: sessionId, m: mood, p: [[lat,lng,speed,heading,tsMs],…]},…]` |
| `drivers.snapshot` | Worker (every 5 s) | Api (`/live` drivers) | **transient `gimano.locations`**: `{at, drivers: Driver[]}` (≥ 3-driver cells, rounded) |
| `report.created` | Api | Worker `AlertLifecycle`, Api SignalR fan-out | `Report` |
| `report.voted` | Api | Worker `AlertLifecycle` | `{reportId, stillThere, userId}` |
| `report.updated` | Api (merge / vote / thanks) | Api SignalR fan-out (`AlertUpdated`) | `Report` |
| `report.expired` | Worker | Api SignalR fan-out | `{reportId}` |
| `jam.updated` | Worker | Api SignalR fan-out | `Jam` |
| `jam.cleared` | Worker | Api SignalR fan-out (`JamUpdated` with `level: 0`) | `Jam` |
| `place.changed` | Importer / Api | Worker `SearchIndexer` | `{placeId}` |

### Location stream (transient, lossy by design)

GPS pings don't use the durable `gimano.events` exchange. They go through a separate **non-durable** topic exchange,
`gimano.locations`:

- **Api**: `POST /locations` does no database I/O. It validates the request and maps the user to a **rotating
  pseudonymous session id**, an HMAC with a per-hour random key that exists only in memory, so the pipeline never sees
  user ids. It then drops the batch into a bounded in-memory channel (drop-oldest) and returns `202`. One background
  task coalesces up to 500 batches into one **transient** message: no publisher confirms, `mandatory=false`. If the
  broker is down, pings are dropped.
- **Queue** `gimano.locations.traffic`: non-durable, `x-message-ttl` 30 s, `x-max-length` 200k, `x-overflow: drop-head`.
  Stale pings are worthless.
- **Worker**: auto-ack, prefetch 2000. Each ping is snapped against an **in-memory road index**: float32
  struct-of-arrays plus a 0.002° grid, loaded from `road_segments` at startup and reloaded when the importer replaces
  them. The ping then goes into the in-memory 5-minute speed window. Driver dots are kept **only in memory**, keyed by
  session id, and published every 5 s as an anonymised snapshot (≥ 3 drivers per 0.01° cell, 3 dp, heading in
  15° steps). **No ping, position or session id is ever written to the database.** Only aggregated
  `segment_speeds` and `jams` are.

## Traffic model

1. Clients send a location ping every 5 s while navigating (batched, max 12 per request).
2. Worker snaps each ping to the nearest `road_segment` (PostGIS KNN, ≤ 25 m,
   heading-compatible) and keeps a 5-minute rolling mean speed per segment.
3. A segment is a **jam** when `mean_speed < 0.5 × free_flow_speed` with ≥ 3
   distinct users; level 1–4 by ratio. Adjacent jam segments are merged into a
   `Jam` polyline and published.
4. Route responses from Valhalla are re-scored: per-edge time is scaled by the
   live speed factor where available, then alternatives are re-ranked (the best
   one is labelled `best`).

## Alert lifecycle

- New report: TTL depends on type (police 30 min, accident 60 min, hazard 60 min,
  traffic 20 min, closure 24 h, weather 120 min).
- "Still there" extends TTL by 50% of base (max 3× base); "Not there" ×2 from
  distinct users expires it. Reporter reputation weights votes.
- Duplicate suppression: same type within 150 m along the same heading merges
  into the existing report (`confirmations++`).

## Malaysia-first data

- Extract: `https://download.geofabrik.de/asia/malaysia-singapore-brunei-latest.osm.pbf`
- Places carry `country` (MY/SG/BN): an explicit supported country tag wins; simplified
  country polygons are the current fallback. Search can explicitly filter one country.
- Named public destinations are eligible even without a known presentation category (`Other`).
  Sensitive sites and personal residential records are excluded before search indexing.
- PostGIS enriches containing administrative names and bounded nearby locality context;
  OpenSearch handles text/aliases and geographic retrieval. A captured viewport is a hard boundary.
- Applied place suggestions are durable correction records replayed over refreshed OSM facts.
  Street search renames retain captured source-way IDs and historical-name aliases. Confirmed
  permanent closures remain effective until refuted or explicitly reopened.
- Import/rebuild and live index writers coordinate through a Postgres advisory lock. Failed bulk
  items block alias promotion; previous physical indices are retained for deliberate rollback.
  See [import rollout](../data/README.md#public-destination-coverage).
- POI categories in [api.md](api.md#place-categories).
- Licence: OSM data © OpenStreetMap contributors, ODbL. Attribution is shown in
  the map view of both apps.
