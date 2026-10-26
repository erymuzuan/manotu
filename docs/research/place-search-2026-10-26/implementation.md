# Place-search implementation — 26 October 2026

Implemented in the API, importer, worker, Android and iOS. This is development validation, not a production rollout.

## Behavior delivered

- Named public destinations no longer depend on the category allowlist. Unknown categories use `Other`. Named apartment developments remain eligible; personal dwellings/units, military and other sensitive features are excluded. Multipolygon POIs are included. Scope remains the MY/SG/BN extract.
- PostGIS supplies containing administrative names and bounded nearby locality context. Source names remain intact. Multilingual/alternative/historical names are indexed.
- Category filters coexist with locality parsing. `Petronas di Bukit Bunga`, `Petronas Bukit Bnga`, and `Petronas Bukit Bunga Kelantan` resolve from Kuala Lumpur. Corrected locality spellings are disclosed. Exact brand queries retrieve nearest branches before the result limit and retain relevant community candidates.
- Both clients capture a visible-ground polygon for **Search this area**. All server retrieval paths are clipped; category expansion and out-of-area suggestions are disabled. A named locality is intersected with the viewport. Recents, favourites and private places are clipped locally, without uploading them.
- Screened public unverified contributions remain searchable. Accepted edits modify the existing OSM identity rather than producing a competing result, retain historical names, and replay after OSM refresh. Maintainer acceptance is explicit and retryable.
- Confirmed permanent closures survive ordinary expiry/import maintenance and are excluded from indexed retrieval. Accepted reopening resolves confirmed closure reports. Owner closure suggestions no longer silently report success without changing the place.
- Street results open a detail card with a name-edit form. Accepted street search renames retain captured OSM way IDs, a stable result ID and historical-name aliases across index rebuilds, including an upstream rename.
- Bulk item failures and refresh failures block promotion. Previous physical indices are retained. A shared database advisory lock coordinates imports, acceptance and worker index updates. Legacy concrete indices fail safely rather than being deleted during promotion.
- The search path no longer records search-miss queries or location cells.

## Validation

| Check | Result |
|---|---|
| Local backend suite | 785 total; 746 passed, 39 infrastructure-dependent tests skipped; no failures |
| Focused PostGIS/OpenSearch suite on WS556 | 85 passed, no skips/failures; disposable databases and uniquely prefixed indices |
| Android debug build and unit tests | Build passed; 525 tests passed |
| iOS simulator build | Passed |
| iOS search unit tests | 7 passed |
| iOS live-API UI test | Passed: Bukit Bunga locality result; no result when the selected map area is Kuala Lumpur |
| Full MY/SG/BN PBF dry run | Completed: 270,437 candidate places before spatial exclusion filtering (MY 216,679; SG 46,471; BN 7,287) |
| Live development API probes | All four Petronas locality forms return `w1106132383`; Bukit Bunga viewport returns it; Kuala Lumpur viewport excludes it |
| S24 USB | Updated Manotu Dev installed; live locality search returned the remote station, map-scoped search excluded it, and the scoped Fuel chip returned a nearby station. In-area recents were retained locally; a street result opened its name-only suggestion form (cancelled without submitting) |
| Physical iPhone USB | Passed on attached iPhone 16: remote locality result and strict map-area exclusion. Signed with verified STAFY team `98KY9PMPX3`; personal-data reset disabled |

An initial broad container run also exposed three failures outside this change: two source-file inspection tests could not find the checkout beside the copied runner, and the existing Drop lifecycle test hit an EF duplicate-tracking error. The local complete suite and the focused real-service suite above pass. This does not claim the broad container suite passed.

## Development runtime and rollout

A separate `gimano-search-test-api` service runs on WS556 port **5082** using staged binaries at
`E:/project/work/manotu-search-test/api`. The normal API on 5080 was left running. It shares the development
PostGIS/OpenSearch services and applied the two additive migrations. The installed S24 **Manotu Dev** build
uses `http://100.101.150.9:5082/api/v1/`; the release app was not replaced.

Temporary compose override: `E:/project/work/manotu-search-test/search-test.yml`. To stop only this test service:

```powershell
docker compose -f deploy/docker-compose.yml -f E:/project/work/manotu-search-test/search-test.yml stop search-test-api
```

Production needs the normal release process, database backup, migrations `AcceptedPlaceCorrections` and
`StreetSearchCorrections`, updated API **and worker**, then a full importer run with index recreation.
The broader POI coverage is not activated by merely installing the mobile apps. A full production reimport,
production latency/capacity validation and production release have not been performed.

## Practical limits

- Import exclusions depend on tags, name heuristics and curated restricted polygons; they cannot prove that every sensitive site was tagged correctly. Country fallback polygons are approximate near borders.
- Nearby locality context is inferred and labelled as such. No new ambiguous-locality chooser was added.
- Street corrections update search/card naming. Vector-map labels and routing instructions still follow their own OSM/tile rebuilds. If all captured source ways disappear, the correction remains in the audit record but needs rematching.
- Bare alias rollback is unsafe: replay current edits and closure state before promoting a retained index. Index-retention cleanup is an explicit operation.
- Private app data stays on-device. The development UI-test location was synthetic; physical-device screenshots and local history were not added to the repository.

The API contract changes are documented in `docs/api.md`; import/reindex behavior is documented in `data/README.md`.

## iPhone follow-up

Owner reconfirmed STAFY COMPANY LIMITED (`98KY9PMPX3`) for all Manotu Apple signing and distribution,
including USB tests, on 26 October 2026. Updated AGENTS.md and persistent agent memory.
The signed app (`my.manotu.app`) was installed and the live-API UI test passed on the physical iPhone 16
(1 test, 0 failures). The test preserves existing on-device personal data; the simulator-only reset flag
is not passed on physical devices. The app was relaunched against the test API without the synthetic
location argument after testing. No TestFlight/App Store upload was performed.
