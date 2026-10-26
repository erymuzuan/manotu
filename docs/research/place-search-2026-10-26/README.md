# Place search investigation — 26 October 2026

Open `index.html` in a browser. It includes inline SVG diagrams, an interactive proposed-behavior illustration, responsive layout and print styling. No build or network connection is required to read it.

- `live-probes.json`: 11 public API request/response snapshots, with UTC timestamps. Locations are synthetic public-area origins, not device locations. All recorded probes returned HTTP 200.
- `design-notes.md`: frontend-design direction and review.

Findings: the exact Petronas Bukit Bunga query succeeds now, including from a distant origin. Four related forms return zero results: explicit fuel filter, a locality typo, `di`, and appended state. The report distinguishes those observations from code-level coverage/reliability risks and unverified device behavior.

Validation: rendered in headless Chromium at 1440px and 390px; inspected desktop/mobile screenshots, checked scenario switching, no browser JS errors, no horizontal page overflow at 390px, no duplicate IDs or broken local links. Application code and API contract were not changed; no deployment performed.

Owner-requested recommendation update: broad import coverage in Malaysia, Singapore and Brunei, excluding sensitive sites and individual residences while including named apartments/condominiums/residential developments (e.g. Ken Damansara 2). The report covers eligibility/category separation, the separate address-import path, removal of existing exclusions and country-specific acceptance fixtures. Recommendation only; no importer changes.

Viewport recommendation: when the map is open, Search this area uses captured visible bounds as a hard filter. No automatic widening or GPS-origin substitution; applies to corrections and fallback too. Added explicit API-contract requirements, scenario illustration and acceptance checks.

Community recommendation update: public contributed places participate in normal and viewport search; accepted corrections override imported fields through one canonical effective record. Verified community results receive priority among comparably relevant matches. Confirmed closures remain suppressed through imports/report expiry; street renames retain old public aliases. Includes SVG merge flow and regression criteria. The original Downloads PDF was inaccessible; the subsequently supplied repository-root `add-place.pdf` has now been reviewed (all 15 pages extracted, key screens visually inspected).

Design alignment: live unverified places are publicly searchable immediately after screening; My places also lists non-public states, which must not leak into public search. Duplicate suggestions link to existing entities; legitimate home businesses can be reviewed separately from personal residences. PDF page references are in the report. The PDF mentions Thailand, but the owner-requested MY/SG/BN scope is retained.

## Implementation

See [implementation.md](implementation.md) for delivered behavior, test results, the development test API, rollout steps and remaining device checks.
