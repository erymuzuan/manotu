# Map data

Manotu combines **OpenStreetMap** map data with deliberately public community contributions.

| What | Source | Used by |
|---|---|---|
| `osm/malaysia-singapore-brunei-latest.osm.pbf` (~250 MB, not committed) | [Geofabrik](https://download.geofabrik.de/asia/malaysia-singapore-brunei.html) | `Gimano.Importer` (POIs, road segments), Valhalla (routing tiles) |

```bash
data/download-osm.sh        # fetch / refresh the extract into data/osm/
data/import.sh              # import with the local .NET SDK (Postgres + OpenSearch must be reachable)
data/import.sh --docker     # or as a container inside the compose stack
```

The importer is idempotent: places are upserted (and ones that disappeared from OSM are deleted),
road segments and the OpenSearch `places` index are rebuilt. Accepted place corrections are replayed
before locality enrichment and indexing. Street-name overlays retain captured OSM way identities.

## Public destination coverage

Scope is the Malaysia/Singapore/Brunei extract. `OsmCategoryMapper` maps unfamiliar named public
features to `Other`; presentation categories are not an import allowlist. Named developments such as
Ken Damansara 2 are eligible. Personal dwellings, unit addresses, military/intelligence sites and
sensitive identities are excluded; restricted polygons also remove nearby POIs and addresses before
indexing. Public-business addresses pass the same gate. Named multipolygon POIs use an interior point.
This is rule-based screening, not a claim that OSM tags identify every sensitive site; curated restricted
areas remain necessary. Approximate country polygons remain the fallback when no country tag exists.

Administrative names come from containing PostGIS boundaries. Nearby locality names use bounded,
same-country lookup and carry `manotu:locality_method=nearest_place` provenance. These inferred names
help search; they do not rewrite the source station name or assert an official branch name.

Rollout requires both migrations (`AcceptedPlaceCorrections`, `StreetSearchCorrections`), the updated
API/worker, and a full importer run with index recreation (do not use `--keep-index` for the first rollout).
A partial OpenSearch bulk failure blocks alias promotion. Previous physical indices are retained.
Imports hold a database advisory lock; accepted edits and worker index consumers wait, then read
current facts and write to the promoted alias. Rollback must replay current overlays/closures into the
rollback index before switching: never blindly point at a stale retained index. Retention cleanup is
explicit maintenance, not automatic deletion.

## Licence and attribution (ODbL)

OpenStreetMap data is © OpenStreetMap contributors and licensed under the
[Open Database License (ODbL) 1.0](https://opendatacommons.org/licenses/odbl/1-0/).
Manotu's own code is MIT; the **data** keeps its ODbL licence.

What this means for Manotu:

- **Attribution.** Every map view in the Android and iOS apps shows
  “© OpenStreetMap contributors” linking to <https://www.openstreetmap.org/copyright>.
  Any other place we display OSM-derived data (e.g. a web live map, screenshots in docs) must do the same.
- **Derived databases are share-alike.** Our Postgres `places` / `road_segments` tables, the OpenSearch
  `places` index and the Valhalla tiles are *derivative databases*. If we publicly distribute them
  (e.g. ship a data dump), they must be offered under the ODbL. Serving results through the API
  (a "Produced Work") only requires attribution.
- **Community reports are not OSM data.** User-generated reports, jams and speeds are Manotu's own data
  with separate contribution provenance. Accepted corrections are materialized into effective OSM-derived place records and the search index.
- Do not import data from sources whose licence is incompatible with the ODbL (e.g. Google Maps).
