# Query-time locality and nearby spelling repair

Production baseline: API/worker/backoffice 6591322, Core migrations 22, BackOffice 2.
Search alias `gimano-places-20261026235132753`, 266945 OSM places.

This release branch applies the targeted repair developed against master 9ddbae1
to live 6591322. It excludes the unrelated AppVersions migration and worker changes.
Only the API image is needed. No mapping, indexed-document, importer, or migration
change; no reindex or PBF import is required. Do not restart worker/backoffice or
send account/digest emails as part of this release.

## Behavior

- Locality fuzzy matching cannot change digits or their letter suffixes.
- Exact imported names/aliases win. A missing section shorthand can use a matching
  section within 5 km of the supplied origin: SS plus the complete section code,
  or initials of its nearest imported city/town plus that code. Native SS17 remains
  SS17, not Seksyen 17; inference without nearby context is deliberately disabled.
- A second bounded search retrieves nearby one-edit whole-name alternatives within
  3 km for multiword queries. It keeps the best literal result first and offers at
  most two alternatives only when at least twice as close as the nearest literal
  match. No name aliases or POI IDs are embedded in production code.
- Exact mode omits nonliteral hits. Country, visibility, closure and strict viewport
  constraints apply to the supplementary query too. No query logging was added.

## WS556 gates (never run Docker/builds on WS556-SERVER)

Use an isolated worktree at the exact release commit and an isolated test OpenSearch
instance. Existing `GIMANO_OS_URL`, `GIMANO_OS_USER`, `GIMANO_OS_PASSWORD`, and
`GIMANO_OS_INSECURE` test settings must never point to production or be printed.
The tests create/delete only unique `gimano-loc*` test indices.

1. Run `dotnet test backend/Gimano.slnx --filter FullyQualifiedName~LocalitySearchRegressionTests`.
   Require all 8 cases to run, including real OpenSearch (zero skips/failures).
2. Run the full suite with real OpenSearch so existing Petronas/locality/viewport,
   ranking, closure and community visibility cases run. Report failures/skips and TRX.
   Infrastructure skips unrelated to search must be identified, not hidden.
3. Build only API from the clean exact release commit:
   `docker build -f deploy/Dockerfile.api -t myhiro.azurecr.io/gimano-api:<short-sha> .`
4. Push that immutable tag using stored registry login; return exact SHA, digest,
   build warnings and test totals. Do not deploy from WS556.

Public read-only baseline assertions reproduced four failures before implementation:
Masjid Ar-Rahmah SS17A, SS 17A, PJ17A and bare Masjid Ar-Rahman near 3.1292,101.6316
all omitted r17086858. Automated C#/OpenSearch validation is pending WS556.

## Deployment after gates pass

Coordinate exclusive execution, verify current production baseline, take/verify a
fresh current pg_dump (exclude ephemeral drops per runbook), preserve all previous
backups, alias and live contributions. Use an API-only compose image override pinned
to the approved digest with project gimano and existing production env. Keep global
TAG/worker/backoffice/importer unchanged. No migration or index mutation is needed.

Verify each shorthand and Rahman query near PJ, exact genuine Rahman results and
exact mode, correct Rahmah first, explicit Seksyen 17A, native SS17/Subang distinction,
Petronas fuel/typo/di/Kelantan and both strict viewport directions. Check both API
domains health/ready and the unchanged alias. Rollback image is the API 6591322 digest
`sha256:339cf2ae2230e832a59138db7d951ef92f1bc20fec585832a05dc2230a2a4d50`;
do not restore the DB or switch aliases for this code-only release.
