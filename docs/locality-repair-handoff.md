# Locality enrichment repair: WS556 handoff

## Scope and compatible source

Build **the supplied repair commit**, not today's master HEAD. The repair is based on deployed
`95ea6d9006eb880ae3506dbd8bceb2b59bdfbd5b`, then merged into master under the owner's policy.
Its only production changes are in the importer. Newer master includes unrelated ContentSafety
schema/model changes; using that newer importer would also apply an unrelated migration.
The repair commit has exactly the same migrations/Core/search implementation as `95ea6d9`.

No production deployment is part of this build handoff. Do not build on WS556-SERVER.

## What changes

The failed query joined all non-area places to complex geography polygons in one 1,800-second
command. Indexes and statistics were present; no lock blocker was found. A bounded 200-place
read-only plan took 1,778 ms for the exact geography predicate. Geometry took 124 ms, but is
not semantically interchangeable: the regression fixture at latitude 72 demonstrates that.

The repair retains `ST_Covers(geography, geography)` and the same spheroidal distance tests.
It pages at most 256 POIs using database ID ordering, stages both admin/locality tags in a
transaction, and publishes tags only after all batches complete. Commands are limited to
120 seconds (lower, not higher, than before). Nearby-locality candidates are materialized
once, with a temporary GiST index and country index, instead of searching all POIs for every
nearest area. The additional 20 km prefilter cannot remove any match under the existing
20 km town/city and 2.5 km village/suburb rules. Exact distance ties now use ID for stability.

This is bounded execution, **not a claim that geography becomes 14 times faster**. The full
recovery can still take tens of minutes. Each completed batch logs counts and elapsed time.
Cancellation or SQL failure rolls back staged enrichment and prevents reaching index rebuild.

`--enrich-only` recovers an already imported database: normal exclusive advisory lock,
migrations (unchanged on this repair commit), accepted-correction replay, enrichment, then
the existing full index rebuild including community data/closures, bulk-error gates, refresh
validation and atomic promotion. It does not parse PBF, rebuild roads/water/entrances, or load
tolls. Incompatible dry-run, skip-search, keep-index and tolls-only modes are rejected.

## WS556 test/build commands (PowerShell 7)

Use the exact repair SHA supplied with this handoff. Keep the dev checkout untouched:

```powershell
Set-Location E:/project/work/gimano
$repair = '<FULL_REPAIR_SHA>'
git fetch origin master
if ($LASTEXITCODE -ne 0) { throw 'fetch failed' }
git merge-base --is-ancestor $repair origin/master
if ($LASTEXITCODE -ne 0) { throw 'repair must be published in master history' }
$buildDir = "E:/project/work/manotu-locality-$($repair.Substring(0,7))"
git worktree add --detach $buildDir $repair
if ($LASTEXITCODE -ne 0) { throw 'worktree creation failed; inspect existing path, do not overwrite it' }
Set-Location $buildDir
git diff --exit-code 95ea6d9 HEAD -- backend/src/Gimano.Core deploy/Dockerfile.importer
if ($LASTEXITCODE -ne 0) { throw 'unexpected Core/schema/Dockerfile change' }

pwsh -NoProfile -File backend/tests/locality-it.ps1
if ($LASTEXITCODE -ne 0) { throw 'test gate failed; stop before build/push' }

$tag = git rev-parse --short=7 HEAD
$image = "myhiro.azurecr.io/gimano-importer:$tag"
docker build --pull -f deploy/Dockerfile.importer -t $image .
if ($LASTEXITCODE -ne 0) { throw 'image build failed' }
docker run --rm $image --help
if ($LASTEXITCODE -ne 0) { throw 'importer help smoke failed' }
docker run --rm $image --enrich-only --keep-index
if ($LASTEXITCODE -ne 2) { throw 'incompatible recovery options must exit 2 before database access' }
docker push $image
if ($LASTEXITCODE -ne 0) { throw 'push failed; use existing stored ACR login, never print credentials' }
docker image inspect $image --format '{{json .RepoDigests}}'
```

The test runner uses unique disposable `gimano-locality-it-*` containers/networks, no host
port bindings, and a random password held only in process environment. It never connects to
production. It checks native exit codes and requires all PostGIS cases to pass (no skipped
database tests). Return the full repair SHA, image tag and registry digest, test totals/TRX
(`artifacts/locality-tests/locality-repair.trx`), build warnings, and help/invalid-option exits.
Do not change/build/push api, worker or backoffice images. Do not deploy from WS556.

## Gates before production recovery (separate execution)

1. Coordinate exclusive execution with SERVER.Manotu again. Confirm .150 still uses 95ea6d9,
   no overlapping import, and matching source/schema state. Keep the verified backup
   `/opt/gimano/backups/place-rebuild-20261026/pre-import.dump` and retained index
   `gimano-places-20261023110424`.
2. Take and verify a **fresh current** pg_dump and contribution/visibility fingerprints.
   Preserve all contributions since the failed import; never restore the old database.
3. Recheck staged PBF SHA-256:
   `92e10b7d3d6b415758fa8e5720411fcb20e431e1f7d7f3e1420a2703289edd23`.
   Geofabrik `malaysia-singapore-brunei-261025.osm.pbf`, data through 2026-10-25 21:21:21 UTC.
4. Pull only the validated importer digest. Use a temporary **importer-only compose override**
   under project `gimano`; do not change global TAG, restart other services or check out newer
   master on .150. Run `importer --enrich-only` detached with captured logs and normal locking.
5. Require exit 0 and completed bulk/refresh/alias promotion logs. If a batch fails, retain
   diagnostics and old index; do not force promotion. The old index is stale relative to the
   database and cannot be blindly used as a rollback: replay current overlays/closures and
   community updates before any rollback decision.
6. Reconcile **every** DB place ID/country with active alias (missing/extra must both be zero),
   and community IDs/visibility without changing them. Verify r17086858 GET 200 and exact-name
   search near 3.1292,101.6316, separately test SS17A/PJ17A/locality and Rahman ambiguity, and
   repeat Petronas fuel/typo/di/Kelantan/strict-viewport and both public health/ready checks.

Baseline after failed import: 266,945 eligible places (MY 214,349; SG 45,363; BN 7,233).
The prefilter candidate count was 270,701; restricted-area filtering excluded 3,756 places
and 361 of 26,728 eligible addresses. These are not counts of every source OSM object.

## Validation status at authoring

No .NET/Docker build was run on WS556-SERVER. Read-only PostGIS diagnostics and the curved-edge
geography-versus-geometry fixture passed there. C# compilation, the new integration tests,
image build/push and full-scale recovery remain WS556/production gates; do not describe this
handoff as a verified production repair until those gates complete.
