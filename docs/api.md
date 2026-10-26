# Manotu API v1 (contract)

Base URL: `https://{host}/api/v1`. JSON, camelCase, UTF-8. Coordinates are WGS84
decimal degrees. Polylines use **Google encoded polyline, precision 6**
(same as Valhalla). Times are ISO-8601 UTC. Distances in metres, durations in
seconds, speeds in km/h.

Auth: `Authorization: Bearer <jwt>`. Anonymous use is allowed: the app calls
`POST /auth/device` on first launch and stores the token.

Errors: RFC 7807 `application/problem+json`. A write that raced another request on the same thing (two votes on one
report at the same instant, a double-tapped vote) is **409** ("changed at the same time; please try again"), never 500.

Language: server-written text (problem `title`, inbox `title`/`body`, area kinds in `address` such as "Bandar raya" /
"City", reverse-geocode labels, search suggestions) follows `Accept-Language`: **English by default, Malay when the header
prefers `ms`** (`ms`, `ms-MY`, `zsm`). Tier names (baharu/perak/emas) are always Malay.

## Auth & profile

```
POST /auth/register          {publicKey: base64 Ed25519, platform:"android"|"ios", locale}
  → 200 {token, userId, displayName}          (new; see identity-and-reputation.md)
POST /auth/token             {userId, ts, sig}   sig = Ed25519 over "GIMANO-AUTH\n"+userId+"\n"+ts
                          or {publicKey, ts, sig}   sig over "GIMANO1-LOGIN\n"+publicKey+"\n"+ts (recovery-code restore)
  → {token, userId, displayName}   (401 auth-failed · 429 > 10 key sign-ins/min per IP)
POST /me/keys                {publicKey, sigByOldKey?}  attach/rotate the signing key (legacy accounts: JWT only)
POST /auth/device            {deviceId, platform:"android"|"ios", locale}   (legacy, kept for old app versions)
  → 200 {token, userId, displayName}

GET  /me                     → User
PATCH /me                    {displayName?, mood?, vehicle?:"car"|"motorcycle"|"bicycle"|"walk", locale?}
```

`User = {id, displayName, mood, vehicle, points, level, joinedAt}`

`displayName` (2–40 chars) goes through the same word filter as reviews and places, and may not contain links (400).
A moderator-banned account gets **403** on every public contribution (reports, votes, issues, places, reviews, photos).

## Saved places, recents, private places: ON DEVICE ONLY

Personal data never lives on the server; see [privacy-and-backup.md](privacy-and-backup.md).
Favourites (Home, Work, "Kampung", "Rumah Mertua"…), recents, "Just for me" places and
planned drives are stored in the app's local SQLite DB and backed up to the user's own Google
Drive / iCloud / file.

The earlier `/me/places` and `/me/recents` endpoints are **deprecated** and kept only for a one-time
migration:

```
GET    /me/data/export    → {savedPlaces: SavedPlace[], recents: Recent[]}   (legacy server copy, if any)
DELETE /me/data           → 204   (permanently deletes the legacy server copy; the app calls it after importing)
DELETE /me                → 204   (deletes the account; the user's reports are anonymised, not deleted; event short links deleted)
```

`/me/places*` and `/me/recents` answer `410 Gone` once the apps have shipped the local store.
Legacy shapes (migration only): `SavedPlace = {id, kind, name, icon, lat, lng, address, placeId?, sortOrder}`,
`Recent = {id, name, address, lat, lng, placeId?, lastUsedAt}`. Favourite labels/icons:
`home, work, kampung, mertua, star, heart, school, surau, food, gym, shop, hospital`.

**Contributor identity, signed requests, trust tiers and vetting rules:** see
[identity-and-reputation.md](identity-and-reputation.md). `User` gains
`tier: "baharu"|"perak"|"emas", accuracy: number|null, placesAccepted, verifierVotes, nextTier: {name, missing: string[]}`.

## Search & places

```
GET /search?q=petronas&lat=3.1&lng=101.6&limit=10&category=fuel&near=3.15,101.70&sort=relevance&exact=false
  → {results: PlaceSummary[], correctedQuery?, suggestions?: Suggestion[], noMatch: bool, interpretation?}

GET /search/nearby?lat=&lng=&category=fuel&radius=5000
  → {results: PlaceSummary[]}

GET /places/{id}?lat=&lng=   → Place      (lat/lng optional: fills distanceM)
GET /geocode/reverse?lat=&lng=
  → {name, address, lat, lng, label?, houseNumber?, street?, area?, city?, postcode?, nearby?: PlaceSummary[]}
```

`PlaceSummary = {id, name, category, address, lat, lng, distanceM, brand?,
                source: "osm"|"community", status?: "pending"|"published",
                rating?: number, reviewCount: int, thumbnailUrl?,
                confirmationsWeighted?: number, required?: number,
                chainGroup?: {key, name, countNearby}, openNow?: bool, anchorDistanceM?: number}`

`openNow` is set only when the place has OSM `opening_hours` we can evaluate (Malaysia time); otherwise null.

### Finding places (`GET /search`)

Parameters: `q` (≤ 100 chars), `lat`/`lng` = the user (distances are measured from here), `near=lat,lng` = the map
centre (ranking origin when given), `limit` (≤ 50), `category`, `country` (MY/SG/BN), `sort=relevance` (default) or
`nearest`, `exact=true` (no spelling correction).

`viewport=lon,lat;lon,lat;lon,lat;lon,lat` is an optional captured visible-ground polygon (3–8
vertices; the server closes the ring). Invalid/self-intersecting polygons return 400. When supplied,
**every retrieval path is clipped to that polygon**, including coordinates, postcodes, streets, categories
and the Postgres fallback. The polygon centre is the ranking origin; `lat/lng` still supplies displayed
user distances. There is no radius expansion, out-of-area suggestion or chain count. Empty means no
matching places in this area. The apps capture the map above the bottom sheet and account for rotation;
on-device recents/favourites/private places are clipped locally too. The footprint is transient, never
saved to preferences or server logs. Search responses use `Cache-Control: no-store`.

Public community places that pass screening are included while unverified; held/checking places do
not become public merely because somebody submitted them. Verified community results and accepted
corrections receive a relevance boost. Confirmed permanent closures are excluded during retrieval,
including after their original report expiry; an accepted reopening or refutation restores eligibility.

Steps, in order:
1. **Normalise**: case, accents, apostrophes, punctuation/hyphens/slashes → space, `&` = "dan". Names are also compared
   without spaces: "Family Mart" = "FamilyMart", "7 eleven" = "7-Eleven" = "7eleven".
2. **Aliases** from [`data/search/aliases.csv`](../data/search/README.md) (brand short names, renames such as
   tesco → Lotus's, dialect/abbreviations such as jln → jalan); every rewrite is searched next to the original.
3. **Typos**: per word, 0 edits up to 3 letters, 1 for 4–6, 2 from 7 letters (OpenSearch `AUTO:4,7`); 1 edit on the
   spacing-free name ("famly mart" → FamilyMart, "myddin" → Mydin, but "pak ali" never becomes "Pak Abu").
   **Results that only matched through typo tolerance always carry `correctedQuery`** (the top result's brand or name): when
   none of the top 3 contains the query literally (after normalisation and aliases; every word starting a word of the name,
   brand or address). Aliases are not corrections ("tesco" → Lotus's has no `correctedQuery`). With `exact=true` such
   results are dropped instead.
4. **Coordinates** ("3.1478, 101.6153", "3.1478 101.6153") and **Plus Codes** (full "6PH57VP3+PR", or short
   "7VP3+PR" + optional locality, recovered near `near`/the user) → one result, `category: "point"`, `id: "pt-lat,lng"`,
   `address` = the reverse-geocode label.
5. **Postcodes** ("47300") → `category: "postcode"` (centroid of the addresses carrying it).
   **Street addresses**: "12 Jalan SS2/24" → a named public-business address (`category: "address"`) when mapped, then the street; individual dwelling/unit addresses are excluded;
   "Jalan SS2/24" → `category: "street"` (one result per street name per ~20–40 km, on the road), nearest first.
6. **Category words** (the whole query): minyak / stesen minyak / petrol → fuel; surau / masjid → surau+mosque;
   tandas / toilet → toilets; atm; parkir / parking; klinik; farmasi; kedai runcit; … (the `category` rows of aliases.csv).
   Nearest first within 5 km, widened to 15 then 50 km when there are fewer than 3. With two categories the first is
   primary: "surau" lists suraus first and a masjid only when it is ≥ 2 km nearer (and vice versa for "masjid").
7. **Brand + area**: a trailing or leading area name ("kfc ss2", "mydin shah alam", "minyak shah alam") → the rest of the
   query searched near that area's centre (within 10 km), unless some result's whole name already equals the query
   ("Hospital Putrajaya"). These results are ordered by distance from that area's centre: `distanceM` stays the
   distance from the user, `anchorDistanceM` is the distance from the area centre, and `interpretation.area/areaLat/areaLng`
   name the anchor, so the app can say "berhampiran SS2" (and sort/label by `anchorDistanceM`).
   The selected category does not disable locality parsing. Leading/trailing locality phrases, connectors
   (`di`, `in`, `near`, `at`), bounded locality typos and a trailing parent locality are supported:
   `Petronas di Bukit Bunga`, `Petronas Bukit Bnga`, `Petronas Bukit Bunga Kelantan`.
   Corrected locality spellings populate `correctedQuery`. In viewport mode, the captured polygon and
   its centre remain authoritative even when the query contains another locality.
8. **Ranking**: a whole-name or brand match and areas beat names that merely contain the word; distance (from `near`, else
   the user) and popularity add to that. **Chains are always nearest-first**: results with the same spacing-free name keep
   the positions ranking gave them but are re-ordered by distance, and get `chainGroup: {key, name, countNearby}`
   (outlets within 10 km), so the app can show "FamilyMart · 12 berdekatan". Same name within 50 m → one result.
9. **Suggestions outside viewport mode**: when nothing matches, `noMatch: true` and `suggestions` (a category word inside the query, e.g.
   "kedai runcit pak ali" → nearby convenience stores). A did-you-mean place is only offered for a close spelling (same rule
   as 3, word by word) **and** within 3 km of the origin, unless it is a chain (then its nearest outlet); a different single
   shop farther away is never a correction. Unless `exact=true` it is searched instead and returned with `correctedQuery`
   (then `noMatch: false`). Nothing is ever substituted silently. When nothing else applies, `suggestions` falls back to
   popular categories nearby (kedai makan, stesen minyak, kedai runcit, with counts), unless an explicit viewport is present.
   Category `count`s are places within 5 km with an OSM node and its building counted once.

`Suggestion = {label, query?, category?, placeId?, lat?, lng?, distanceM?, count?}`: a did-you-mean place
(`label`/`query` = its name, `placeId`, position, `distanceM` from the user) or a nearby category (`label` in the
request language, `query` = the category word, `category`, `count` = how many within 5 km).

`interpretation = {kind, normalized, categories?, area?, areaLat?, areaLng?}` with
`kind ∈ text, category, brand_area, category_area, street, address, postcode, coordinates, plus_code` (informational).

Result ids: `n…`/`w…`/`r…` OSM places and areas, `c_…` community places; `st-…` streets, `ad-…` addresses,
`pc-…` postcodes and `pt-…` points are search-only (no `GET /places/{id}`; use lat/lng).

### Reverse geocode ("Pilih pada peta")

`GET /geocode/reverse?lat=&lng=` is anonymous and never cached (`Cache-Control: no-store`); coordinates are not logged.
`name`/`address` are as before (a place within 40 m, else the street). Added: `label` ("Dekat 18, Jalan SS 2/24, SS2,
Petaling Jaya" / "Near …"), `houseNumber`, `street`, `area` (suburb/neighbourhood), `city`, `postcode`, and `nearby` =
places within 50 m, nearest first (max 5), for "Adakah ini FamilyMart?".
`city`/`area` come from the OSM administrative boundaries that contain the point (smallest first): `city` is the
nearest city/town inside the smallest containing boundary of admin_level ≤ 6 (else that boundary's name), `area` the
nearest suburb/neighbourhood inside the smallest containing boundary, so KLCC is "Kuala Lumpur", not a town across the
border. When there is no house address and no street within ~30 m, the label is built from the nearest named
place in `nearby` ("Dekat Suria KLCC, Kuala Lumpur").

### Search misses (anonymous zero-result counts)

When a search returns nothing, the server adds 1 to a counter keyed by **(normalised query text, ~11 km cell, ISO week)**
and nothing else: no user id or token, no IP, no exact location (the cell is lat/lng floored to 0.1°, or empty without a
location). Before counting, emails, phone numbers and digit-heavy tokens (house numbers, postcodes, codes) are removed; if
nothing is left, nothing is counted. Rows with a count below 5 are deleted once their week is over, and all rows after 26
weeks. Maintainers read them with `GET /admin/search-misses?week=2026-W43&minCount=5` (X-Admin-Key) to add aliases.

`confirmationsWeighted`/`required` are set only on places still being vetted (`/places/pending-nearby`, and
pending or audited items in `/me/places/contributed`), e.g. `1` of `3` → "1 daripada 3". Same values as the
`POST /places/{id}/verify` response.

`Place = PlaceSummary + {phone?, website?, openingHours?, openNow?:bool,
amenities: string[], tags: {k:v}, osmType?, osmId?,      // osm* null for community places
description?, addedBy?: {displayName, authorRef?}, verifiedCount: int, photos: Photo[] (first 10)}`

Search returns OSM places, published community places and the caller's own pending
places. The app merges in matches from its local favourites and private places **on the device**. When `results` is empty, the app offers **"Can't find it? Add a place"**.

## Community places (add a missing place)

Clean-room flow, modelled on how big map apps let people add missing places:

1. The user drops or drags a **pin** on the map (pre-filled with the reverse-geocoded address)
   and gives it a **name**. Optional: category, description, phone, website, opening
   hours, amenities, photos.
2. **Visibility** question: "Make this place discoverable by other Manotu users?"
   - **No** → private: stored **only on the device** (local DB, included in the user's backup) and never
     sent to the server.
   - **Yes** → the automated checks run (below), then the **AI check** (below), whose answer comes back in the same
     response. A place that passes is `pending` with `listed: true`: in search and on the map for everyone with a
     "Not verified yet" badge, and nearby users can confirm it ("Is this place here?"). After the required
     confirmations (**1 in launch mode**, otherwise 3, 2 for Perak), or a moderator approval, it becomes `published`.
     **3 "Doesn't exist / Wrong location" votes** hide it for moderator review.
3. Anyone can then **suggest an edit** (hours, phone, category, location); owner edits apply through screening (closure/reopening suggestions always require acceptance),
   other users' edits need 2 confirmations.

```
POST   /places                        → 201 Place   (owner view, with `screening`)
  { name, category, lat, lng, address?, description?, phone?, website?,
    openingHours?: "Mo-Fr 08:00-18:00; Sa 08:00-13:00",     // OSM opening_hours syntax
    amenities?: string[],                                    // always public; private places never reach the server
    warnings?: ("alcohol"|"gambling"|"tobacco")[],           // the owner's tags (max 3, unknown values ignored); see "Place warnings"
    notDuplicateOf?: string }                                // the `existing.id` of a 409 the user answered "No, mine is different"
PATCH  /places/{id}                   → Place        (owner only, community places only; a changed place is checked again; `warnings` is
                                                      replaced when sent and does not trigger a new check;
                                                      a `rejected` place may be edited: "Edit and try again")
POST   /places/{id}/appeal  (signed)  {note?: ≤ 200}  → Place   (owner only, `rejected` places, once per place → hidden,
                                                      held for a maintainer; 409 if not rejected or already appealed)
DELETE /places/{id}                   → 204          (owner only; published places become "closed", not deleted)
POST   /places/{id}/suggest-edit      → 202 {suggestionId}   (any user; any place incl. OSM → stored as a map-data suggestion)
POST   /places/{id}/verify  (signed)  {answer: yes|no|unsure, nameCorrect?, locationCorrect?,
                                      proximity:{cell, withinM}, attestation?:{platform, token}}
                                      → 200 {status, confirmationsWeighted, required}
                                      (the 0.1.0 body {exists, correctLocation} is accepted only from accounts with no
                                       signing key; keyed accounts get 400 without answer + proximity)
GET    /places/pending-nearby?cell=<geohash6>   → PlaceSummary[] (pending, excludes own)
GET    /me/places/contributed         → PlaceSummary[]
```

Maintainer acceptance: `GET /admin/place-suggestions` lists pending edits;
`POST /admin/place-suggestions/{id}/accept` applies an edit, guarded by `X-Admin-Key`.
Applied suggestions retain `AppliedAt` and are replayed over refreshed OSM facts before indexing.
Reaccepting is retry-safe. OSM updates cannot erase an accepted correction. Renames retain historical
names as aliases. `Closed: false` explicitly resolves confirmed permanent-closure reports.

`st-…` street results now have a place detail endpoint and support `suggest-edit` with **name and
comment only**. The server captures the specific OSM way IDs for review; acceptance changes the street
search document while retaining its stable ID and old-name aliases. Rebuilds use those way IDs even
if the upstream name changes. This changes search/place-card naming; routing-tile instructions and
base-map vector labels still follow their separately rebuilt OSM datasets.


**AI check (Claude Haiku 5.5; design: canvas page "Add a place with an AI gate").** It sees only the public fields
(name, category, description, opening hours, phone, website) and the names of public places within 150 m, never the
user id, pseudonym, device or anyone's location. It answers publish / hold / reject with a confidence and fixed reason
codes, and the server applies it by tier:

| Contributor | AI: publish | AI: hold | AI: reject |
|---|---|---|---|
| New (account < 7 days or < 3 accepted places) | `pending` + `listed` only on high confidence, else held | held | `rejected` |
| Baharu, Perak | `pending` + `listed` | held | `rejected` |
| Emas | `published` (10 % audited) | held | held (never rejected automatically) |

"Held" = `hidden` + `heldForReview: true`, decided by a maintainer within 24 h. An edit of a place others already
confirmed is never rejected automatically: a doubtful edit is held. **3 AI rejections in 24 h pause adding for 24 h**
(`403`, `code: "adding_paused"`, `pausedUntil`). The check spends at most **US$20 a week**; when it is off or the week's
budget is used up, places follow the plain rules (`screening.state: "skipped"`: `pending`, not listed, 3 confirmations).

The owner's `Place` (POST/PATCH/appeal responses, `GET /me/places/contributed`) carries
`screening: {state, reasons, canAppeal, appealed}` (absent for other viewers), and while it waits for confirmations
`confirmationsWeighted` and `required` ("Not verified yet · 0 of 1"):

| `state` | Meaning | App (design) |
|---|---|---|
| `passed` | live (`pending` + listed, or `published`) | A4 "It's on the map", A5 Emas |
| `held` | `hidden`, a maintainer decides (also after an appeal) | B2 "A person will check this one" |
| `rejected` | `status: rejected`, only the owner sees it | B3 advert/scam, B4 someone's home (`reasons` say which) |
| `checking` | no answer within 4 s; the worker finishes it, the result arrives in the Inbox. Hidden from others until then | B6 "Sent. We're still checking" |
| `skipped` / `none` | not checked (off, over budget, older places, restricted-area holds) | as before |

`reasons` ⊂ `spam, scam, gibberish, harassment, private_home, adult, illegal, duplicate, security, unclear,
wrong_category` (and `ok` on a pass), plus the public-content-safety codes (design: canvas "Manotu AI Content Safety"):

| Group | Codes |
|---|---|
| Harm | `violence`, `drugs`, `personal_data`, `3r` (race, religion, royalty) |
| Promotion (rejected) | `gambling_promo`, `alcohol_promo`, `tobacco_promo`, `brand_promo`, `external_contact` (phone, WhatsApp, Telegram, links) |
| Money and goods | `high_risk_investment`, `loan_shark`, `mlm`, `counterfeit`, `medical_claims` |
| Warning only | `sensitive_alcohol`, `sensitive_gambling`, `sensitive_tobacco`: the place stays listed and apps show a warning banner |

Mentioning that a place sells or hosts alcohol, gambling or tobacco is accepted; offers, codes, links and contacts for them
are rejected. The same check and codes screen reviews, report notes and photos (text and image, public content only, never
user id, device or location): see `docs/content-safety.md` and "Reviews & photos" below. Unknown codes from the model become
`unclear`. The apps show their own copy for each code, never model text.

**Place warnings.** `Place` and `PlaceSummary` carry `warnings?: ("alcohol"|"gambling"|"tobacco")[]`, omitted when empty, in a fixed
order. Sources: the owner's tags on `POST/PATCH /places`, the AI check's `sensitive_*` codes, the brand watchlist (a place whose
name, description or website matches a brand set to `warn`), and, for map (OSM) places, tags (`shop=alcohol`,
`amenity=bar|pub|biergarten|casino`, `leisure=adult_gaming_centre`, `shop=bookmaker|lottery`, `shop=tobacco|e-cigarette`). The place
stays listed and routable; the apps show a banner. A community place whose name matches a brand set to `hold` (online gambling,
loan shark, high-risk investment) is held for a maintainer unless the AI check rejects it. "Not right? Tell us" =
`POST /places/{id}/flag {reason:"other"}`. Search results come from the search index, so `warnings` appears on them after the
next reindex (it is always present on `GET /places/{id}`, nearby and `/me/places/contributed`).
Rate limits answer `429` with `Retry-After` and `retryAfterSeconds` (B5 "You can add more in 40 minutes").

**Automated checks before `pending` → visible:**
- duplicates: the same or a similar name (trigram ≥ 0.6) within 100 m of an OSM or community place is
  rejected (409, with the existing place returned so the app can say "Is it this one?"); sending the request again
  with `notDuplicateOf: existing.id` lets it through to the AI check, which is told the user said it is different;
- rate limit: 10 new places per user per day, 3 public ones per hour;
- text filter (profanity/spam/URLs in names), Malay and English;
- coordinates inside MY/SG/BN and not in water (OSM water polygons).

### Restricted areas: no military, national-security or at-risk sites

Manotu never accepts community content in or next to military and strategic sites (Malaysia's Protected Areas and
Protected Places Act 1959, Act 298, forbids photographing or sketching them), nor content that maps shelters, safe
houses, private homes or security details (guards, CCTV, back entrances, patrol times). Design: canvas page "Safety",
row 2.

```
GET /restricted-areas            (anonymous; ETag / If-None-Match → 304; Cache-Control: public, max-age=86400)
→ 200 {
    version: "3f9a1c2b7d4e5f60",          // changes when the shapes or terms change
    blockM: 100,                           // inside a shape or within blockM: no public contributions
    reviewM: 300,                          // within reviewM: places are held for a moderator, photos refused
    terms: ["kem", "pangkalan", …],        // lower case; matched as whole words/phrases, accent- and case-insensitive
    areas: [ [[lng, lat], …], … ]          // outer rings only, closed, simplified (~10 m); no names, no kinds
  }
```

- The whole set is downloaded (never a bounding box), so the request says nothing about where the user is. The apps
  cache it and re-check daily; the check on the phone works offline and sends nothing.
- `areas` come from the OSM import: `landuse=military`, `military=*` (except `bunker`, `trench`, `danger_area`),
  `power=plant`, `power=substation` at ≥ 132 kV, `man_made=water_works`, `amenity=prison`. Maintainer-curated sites
  that must not be revealed (shelters, safe houses) are **checked on the server only** and never sent to phones.
- Road segments inside an area are not imported for traffic, so no speeds are computed there from anonymous pings.

Server checks (authoritative; the phone check can be bypassed):

| Request | Inside a shape or ≤ `blockM` | ≤ `reviewM` | Matches a `terms` entry (name, description, text) |
|---|---|---|---|
| `POST /places`, `PATCH /places/{id}` (move) | 422 `restricted_area` | created `hidden`, `heldForReview: true` | created `hidden`, `heldForReview: true` |
| `POST /places/{id}/suggest-edit` (lat/lng) | 422 `restricted_area` | accepted (never auto-applied) | accepted (never auto-applied) |
| `POST /photos` (place within the distance) | 422 `restricted_area` | 422 `restricted_area` | — |
| `POST /places/{id}/reviews` | 422 `restricted_area` | published as usual | review `hidden`, `heldForReview: true` |
| `POST /issues`, `POST /reports` | 422 `restricted_area` | as usual | — |

`422` body: ProblemDetails with `code: "restricted_area"` and a localized `detail`. A refusal is counted in a metric,
never logged with the user or the coordinates. Held items wait in the moderation queue (`state=hidden`, `held: true`);
the owner sees them in "My contributions" as "Sedang disemak" and gets an Inbox note when a maintainer decides.
Trusted (emas) contributors are not exempt.

**Reports:** flag reason `sensitive_location` (places, reviews, photos) hides the item after **one** report (other
reasons need three); a maintainer acts within 24 h.

**Private places ("Untuk saya")** never leave the phone, so the apps allow them anywhere, restricted areas included.

## Reviews & photos

```
GET    /places/{id}/reviews?sort=recent|helpful&cursor=   → {reviews: Review[], next?}
POST   /places/{id}/reviews           {rating: 1–5, text?: ≤ 2000, photoIds?: string[]} → 201 Review (screened, see below)
                                      → 422 {code:"content_rejected", reasons, safeText?}   → 403 {code:"posting_paused", pausedUntil}
PATCH  /reviews/{id}  /  DELETE /reviews/{id}      (author only; one review per user per place; an edited text is screened the same way)
POST   /reviews/{id}/appeal           {note?: ≤ 200} → 202   (author only, once, only after a late rejection; held for a maintainer)
POST   /reviews/{id}/helpful          → 204   (toggle)
POST   /reviews/{id}/flag             {reason: spam|offensive|off_topic|conflict_of_interest|sensitive_location|other} → 202

POST   /photos   multipart/form-data: file (JPEG/PNG/HEIC/WebP, ≤ 15 MB), placeId, caption?
  → 201 Photo   (status "processing" → "published" | "rejected"; held photos stay "processing", see below)
GET    /places/{id}/photos?cursor=    → {photos: Photo[], next?}
DELETE /photos/{id}                   (uploader only)
POST   /photos/{id}/flag              {reason}
POST   /photos/{id}/appeal            {note?: ≤ 200} → 202   (uploader only, once, only after a rejection; held for a maintainer)
POST   /places/{id}/flag              {reason} → 202   (community places only; 3 reports from different users hide it)
GET    /media/{key}.webp              (public, immutable, Cache-Control: max-age=31536000)
GET    /photos/{id}                   → Photo   (poll after upload: status processing → published | rejected)
```

`Review = {id, placeId, rating, text?, photos: Photo[], author: {displayName, level, reviewCount, authorRef?},
helpfulCount, createdAt, editedAt?, status: "published"|"hidden", heldForReview, moderation?}`
`Photo = {id, url, thumbUrl, width, height, caption?, uploadedBy: {displayName, authorRef?}, createdAt, status, moderation?}`
`moderation = {state: "passed"|"held"|"checking"|"rejected"|"skipped", reasons: string[], canAppeal: bool}`: **the author's own view only**
(absent for everyone else, and for content that was never checked). Photos never use `skipped` (an unchecked photo has no
`moderation`). `url`/`thumbUrl` are set only while `status` is `published`.

**Public content safety (docs/content-safety.md).** Reviews (text, new or edited), photos (after EXIF/GPS stripping, as a
metadata-free JPEG) and the free-text note of a road report go through the Claude Haiku 5.5 check, with the same reason codes and
the same US$20/week budget as places. The model sees only the public text or image and the public place's name, never user id,
pseudonym, device, contact or location; content is never logged.

| Review verdict | Response |
|---|---|
| publish | `201 Review`, `status: "published"`, `moderation.state: "passed"` (`reasons: []`) |
| hold | `201 Review`, `status: "hidden"`, `heldForReview: true`, `moderation: {state:"held", reasons, canAppeal:false}`; a maintainer decides within 24 h; Inbox `content_held` |
| no answer in 4 s | `201 Review`, `status: "hidden"`, `moderation.state: "checking"`; the worker finishes it (an hour at most, then it is held) and the result arrives in the Inbox (`content_published`, `content_held` or `content_rejected`) |
| reject | `422 {title, status, detail, code: "content_rejected", reasons: string[], safeText?: string}`; nothing is stored (a rejected `PATCH` leaves the review as it was). `safeText` = the text without the offending part, only when a useful part remains |
| check off / budget used up | `201 Review` as before the check (profanity and link filters only), `moderation.state: "skipped"` |

A rating-only `PATCH` is not screened. The author also gets their own hidden review back in `GET /places/{id}/reviews` (first
page, when the request is signed in) with its `moderation`. A review rejected only after the app stopped waiting stays hidden with
`moderation: {state:"rejected", reasons, canAppeal:true}` until appealed; unappealed rejected reviews and photo files are deleted
after 7 days. An appeal (`POST …/appeal`, `202`) turns the item into `held` (`canAppeal:false`); `409` when not rejected or already
appealed; `400` for a note over 200 characters or with links. A maintainer's approval publishes it (Inbox `content_published`), a
refusal rejects it (`content_rejected`, `canAppeal:false` once appealed).

**Photos.** `POST /photos` still answers `201 Photo` with `status: "processing"`; the uploader's `Photo` carries
`moderation.state: "checking"` while the worker processes and checks it (poll `GET /photos/{id}`). Outcomes: `published`
(`passed`), `rejected` (`rejected`, `canAppeal: true`), or still `processing` while held (`held`) or `checking`. Other viewers see
only published photos (`GET /photos/{id}` of someone else's unpublished photo is `404`). A rejected photo never blocks the review
or place it belongs to.

**Pause.** Three AI rejections in 24 hours (reviews, review edits, photos, report notes and rejected places together) pause
posting for 24 hours: `403 {code: "posting_paused", pausedUntil}` on `POST/PATCH /reviews` and `POST /photos`
(`adding_paused` for places, same `pausedUntil`, same clock).

**`authorRef` (blocking, Apple 1.2):** an opaque, stable id for the contributor, the same on every review, photo,
community place (`addedBy`) and issue (`reportedBy`) of theirs: `base64url(HMAC-SHA256(server secret, internal user
id)[..12])`, 16 characters. It is not the user id or the pseudonym's key and can't be reversed. The apps keep a
**"hide this contributor" list of `authorRef`s on the device only** and filter content client-side; nothing about a
block is sent to the server. `authorRef` is absent when the author deleted their account. Server secret:
`Community:AuthorHandleKey` (falls back to a key derived from the JWT key).

**Reporting and moderation:** reviews, photos and community places can be reported (`/flag`); 3 reports from different
users hide the item until a maintainer reviews it (within 24 h, docs/back-office.md "Moderation"). Maintainers can hide,
restore, and ban an abusive contributor (their public content is hidden and new contributions are refused with 403).
(`url`/`thumbUrl` are null while `status` is `processing`; uploads of HEIC or other undecodable images get `415`.)

**Photo processing (server):** apply EXIF orientation → **strip all metadata (incl. GPS)** →
resize to max 1600 px on the long edge → encode **WebP** (quality 80) + a 400 px thumbnail (WebP
q 70); reject < 200 px or undecodable. Stored by content hash in object storage
(`IMediaStore`: local volume by default, S3-compatible optional). The app also downsizes before
upload (≤ 2048 px JPEG/WebP) to save mobile data.

**Review moderation (clean-room, policy-based):** reviews are published immediately when
they pass automated checks (profanity/spam filter, links stripped, ≤ 1 review/user/place,
rate limit 20/day, and no reviews on a place the reviewer added in the first 24 h).
3 flags from distinct users hide the review pending moderation. Ratings are shown as the
mean with the count; places with < 3 reviews show "New".

Contributors earn points (place added +5, published +20, review +3, photo +2, helpful vote
received +1); these feed `User.points`/`level`.

### Place categories

`fuel, ev_charging, rest_area, toll_booth, parking, restaurant, cafe, fast_food,
mall, supermarket, convenience, mosque, surau, temple, church, hospital, clinic,
pharmacy, police, school, university, hotel, atm, bank, car_repair, car_wash,
tourism, transit_station, airport, government, other, area, toilets`

Search-only result kinds: `street, address, postcode, point` (see "Finding places").

`area` (search results only) is a city, town, suburb, village, neighbourhood or state/district from OSM
(`id` `n…`/`w…`/`r…`, `address` like "Bandar raya, Wilayah Persekutuan"). It cannot be chosen for a community place.
Clients must treat unknown categories as `other`. Search collapses results with the same name within 50 m.

## Routing

```
POST /routes
{
  "origin":      {"lat":3.13,"lng":101.62},
  "destination": {"lat":3.12,"lng":101.61, "placeId":"..."},
  "waypoints":   [{"lat":3.14,"lng":101.69,"name":"Kedai Mak","placeId":null}],   // 0–5 intermediate stops, in order (0–25 with "store": false)
  "vehicle":     "car" | "motorcycle" | "bicycle" | "walk",
  "avoid":       {"tolls":false,"highways":false,"ferries":false},
  "departAt":    null,        // ISO time for "Leave later"
  "alternatives": 2,
  "store":       true         // optional, default true; false = stateless (Events, see below)
}
→ 200 {"routes": Route[]}
→ 422 problem+json  no route between the points (Valhalla error)
→ 503 problem+json  routing engine unavailable (Retry-After: 30)
```

Routes are cached server-side for 3 h so that `/routes/{id}/reroute` can reuse the
original destination/vehicle/avoid options (404 when the id is unknown or expired).

**Stateless routing (`"store": false`)** — added for Events ([events.md](events.md) §6); additive and backward
compatible (omitted = `true` = the behaviour above). Nothing is kept server-side, not even in the in-memory reroute
cache; route ids start with `x-` and `/routes/{id}/reroute` answers 404 for them (plan a new route instead). Up to
**25** waypoints are allowed (still 5 when stored); more than 20 locations are routed by Valhalla in consecutive
chunks and returned as one route with one leg per stop, without alternatives. Everything else (traffic, tolls,
alerts, issues) is unchanged. The request should carry coordinates and travel mode only (no stop names for events).

**Travel modes** map to Valhalla costings: `car`→`auto`, `motorcycle`→`motorcycle`,
`bicycle`→`bicycle`, `walk`→`pedestrian`. `avoid.*` applies to car/motorcycle only; bicycle and
walk never use expressways or tolls. Live-traffic re-scoring and `trafficSegments` apply to
car/motorcycle only (empty for bicycle/walk). Walking/cycling instructions use the same
`Maneuver` shape.

**Multi-stop:** each waypoint becomes a leg: `legs.length == waypoints.length + 1`. Reroute keeps the
**remaining** stops (the client sends `nextStopIndex`). `nextStopIndex` always indexes the waypoints of the
**original** `POST /routes` request (also after earlier reroutes); omitted = 0. Each leg's `to.name` echoes the
waypoint/destination `name` from the request.

**Tolls & fares:** OSM has toll plazas but no tariffs. `tolls` lists every toll plaza the route
passes, in order, with the class-appropriate fare from Manotu's curated tariff table
(`data/tolls/my-toll-rates.csv`, every row cites its public source and effective date).
`tollEstimateMyr` is the sum **only when every plaza has a known fare** (`tollFareComplete: true`);
otherwise it is the sum of the known fares and `tollFareComplete: false`, and the app shows "from RM x".
Closed-system expressways (PLUS E1/E2 etc.) charge entry→exit pairs and are priced only
where the pair is in the table. On a priced pair the entry plaza is listed with `system: "closed_entry"`, `fareMyr: 0`
and the pair fare is on the exit plaza (`closed_exit`). Plazas with no tariff row are listed with
`system: "open"` and no `fareMyr`. `tollEstimateMyr` is `null` when no fare on the route is known. Vehicle class: car = class 1, motorcycle = class 0. Most Malaysian
tolls are free for class 0, but fares are taken from the table, not assumed. Bicycle and walk routes always have `tolls: []`.

```
Route = {
  id, label: "best"|"alternative",
  durationS, distanceM, trafficDurationS,
  summary: "Via E11 LDP, Exit 1107 SS2 Petaling Jaya",
  trafficDescription: "Typical traffic" | "Heavier than usual" | "Light traffic",
  vehicle: "car"|"motorcycle"|"bicycle"|"walk",
  hasTolls: bool, tollEstimateMyr?: number, tollFareComplete: bool,
  tolls: [{plazaId, name, highway?, lat, lng, fareMyr?: number, system: "open"|"closed_entry"|"closed_exit", source?,
           distanceAlongRouteM?}],   // metres from the route start to the plaza: drives the "toll ahead" alert
  arrival?: NavigationPoint,       // a place destination routed to its entrance (see "Arriving at the entrance")
  reasons?: ("fastest"|"shortest"|"lower_toll"|"no_tolls"|"fewer_reports"|"other_main_road")[],  // see "Route options"
  viaRoads?: string[],             // main roads only this route uses, e.g. ["FT2"]
  hidden?: null|"same_road"|"slower"|"worse",   // not worth offering; listed after the shown routes
  polyline,                         // encoded, precision 6
  bbox: [minLng,minLat,maxLng,maxLat],
  legs: [{ durationS, distanceM, to: {lat, lng, name?}, maneuvers: Maneuver[] }],
  trafficSegments: [{fromIndex, toIndex, level:0..4}],   // indexes into decoded polyline
  alerts: AlertOnRoute[]
}
Maneuver = {type, instruction, streetName?, exitNumber?, roadRef?,
            distanceM, durationS, beginShapeIndex, endShapeIndex,
            verbalPre?, verbalPost?}
type ∈ depart, arrive, straight, slight_left, left, sharp_left, slight_right,
       right, sharp_right, uturn_left, uturn_right, roundabout_enter,
       roundabout_exit, merge, ramp_left, ramp_right, exit_left, exit_right,
       keep_left, keep_right, ferry
AlertOnRoute = Report + {distanceAlongRouteM}
```

```
POST /routes/{id}/reroute   {lat, lng, heading, nextStopIndex?}   → {routes: Route[]}   // 404 for "x-" (stateless) ids
GET  /routes/departure-times?originLat=&originLng=&destLat=&destLng=&date=&vehicle=
  → {slots:[{departAt, durationS}]}         // "Find the best time to leave"
  // date = yyyy-MM-dd (Malaysia time, default today); one slot per hour 06:00–22:00 MYT;
  // vehicle optional (car|motorcycle, default car)
```

**Snap a drawn line to roads** — added for Events ([events.md](events.md) §6); a new endpoint, so additive and
backward compatible. Valhalla map matching (`trace_attributes`, `shape_match: map_snap`, same costing per vehicle as
`POST /routes`). Stateless: never cached, stored or logged.

```
POST /routes/match
{ "points": [{"lat":3.1579,"lng":101.7120}, …],   // 2–5000, in drawing order; each a valid WGS84 point
  "vehicle": "bicycle" }                          // car|motorcycle|bicycle|walk (default car)
→ 200 { "polyline": "…",                          // matched road geometry, encoded, precision 6 (as Route.polyline)
        "distanceM": 1234, "durationS": 300,
        "unmatched": [{"fromIndex": 40, "toIndex": 55}] }   // inclusive input-point ranges that matched no road
→ 400 problem+json  validation (fewer than 2 / more than 5000 points, invalid point → errors["points[i]"])
→ 422 problem+json  nothing could be matched to a road (or the line is beyond Valhalla's trace limits)
→ 503 problem+json  routing engine unavailable (Retry-After: 30)
```

Unmatched stretches are skipped (the polyline joins the matched parts); the client shows them as drawn and lets the
user fix them. Duration is Valhalla's estimate for the vehicle, without live traffic.

## Issues (road and place complaints)

Spec: [complaints.md](complaints.md). One report never closes a road; corrections only make routing more cautious;
traffic that drives through refutes "closed"; everything expires. Reports are public contributions under the pseudonym.
No per-user location history: road reports are snapped to the road and stored at ≈ 5 m, odd-route ends at ≈ 1 km, and
passive evidence is anonymous per-segment hourly counts.

```
POST /issues                       (auth, signed)  CreateIssue → 201 Issue      (a duplicate is merged: same Issue, merged: true)
GET  /issues/nearby?bbox=minLng,minLat,maxLng,maxLat&kinds=road_closed_temp,place_closed_perm   → {issues: Issue[]}
GET  /issues/{id}                                    → Issue
POST /issues/{id}/votes            (auth, signed)  {answer: "still"|"cleared"|"unsure", proximity: {cell, withinM}}
                                                    → {state, confirmationsWeighted, refutationsWeighted, required}
```

`CreateIssue = {kind, subtype?, lat, lng, heading?, placeId?, vehicle?, durationHint?, source: "report"|"deviation"|"place_edit", payload?}`

| kind | needs | subtype / payload |
|---|---|---|
| `road_closed_temp` | lat, lng, heading | subtype `accident`·`flood`·`event`·`roadworks`; `durationHint` `unknown`·`today`·`few_days`·`long_roadworks` |
| `road_not_exist` | lat, lng, heading, `vehicle` | subtype `gate`·`private`·`track` |
| `oneway_wrong_closed_dir` | lat, lng, heading (the direction you can't drive) | |
| `oneway_wrong_open_dir` | lat, lng, heading (the direction the map forbids) | |
| `turn_not_allowed` | lat, lng, heading | payload `toLat`, `toLng` (where you wanted to go) |
| `odd_route` | lat, lng | payload `fromLat/fromLng/toLat/toLng` (stored at 2 dp), `chosen`, `taken`, `comment` |
| `new_road` | lat, lng | payload `trace: [[lat,lng],…]` (only that road; 200 m trimmed at each end server-side, must be > 400 m), `name` |
| `place_closed_perm` | placeId | |
| `place_closed_temp` | placeId | payload `until` (yyyy-MM-dd, ≤ 60 days) |
| `place_hours_wrong` | placeId | payload `openingHours` (OSM syntax) |
| `place_entrance_wrong` | placeId | payload `navLat`, `navLng` (+ `kind`: `entrance`·`parking`) |
| `place_info_wrong` | placeId | payload any of `name`, `category`, `phone`, `website`, `comment` |
| `place_duplicate` | placeId | payload `duplicateOf` (place id) |

Road reports snap to the nearest road segment within 50 m whose direction fits `heading` (400 Bad Request if none; 50 m because dual carriageways such as the E12 are mapped ~37 m apart). Coordinates in `payload` (`navLat`/`navLng`, `toLat`/`toLng`, odd-route ends, trace points) may be JSON numbers or numeric strings. A report of the
same kind on the same segment / place (or within 50 m; for the two one-way kinds only the same segment **and direction**)
while one is open is **merged**: it counts as a "still" vote and
the existing issue is returned with `merged: true`. Limits: 30 reports and 20 answers per pseudonym per day; answers
need `proximity` like place vetting (`cell` = geohash-6 around the issue, `withinM` ≤ 1000). One answer per pseudonym:
answering again replaces it.

`Issue = {id, kind, subtype?, state, source, lat, lng, direction: "both"|"forward"|"backward",
          segment?: {wayId, seq, name?, highway?, direction}, placeId?, vehicle?, summary,
          confirmationsWeighted, refutationsWeighted, required, stillVotes, clearedVotes, confidence,
          createdAt, lastEvidenceAt, expiresAt?, confirmedAt?, reportedBy?: {displayName}, mine, myVote?, payload, merged}`

`summary` is in the request language ("Jalan SS 2/24: ditutup (banjir)"). `payload` is public except for `odd_route` and
`new_road` (maintainers only). `direction` is relative to the OSM way's digitised direction.

**States**: `reported` (odd_route/new_road: feedback, never voted on) · `suspected` (on creation) → `confirmed`; or
`refuted`, `expired`, `resolved` (the imported map now matches: the way is gone, the one-way flag flipped, the place was
removed). Votes: still = it holds · cleared = cleared / never true / "masih buka" · unsure (weight 0). Weights:
baharu 1, perak 1.5, emas 2; accounts under 7 days 0; the reporter's report is the first "still".

| kind | confirmed when | refuted when | effect |
|---|---|---|---|
| `road_closed_temp` | still ≥ 2, or still ≥ 1 + no traffic for 30 min on a normally busy road (≥ 24/day), or one Emas. **Major roads** (motorway/trunk/primary incl. links; Malaysian toll expressways): still ≥ 3 **and** that passive evidence | cleared ≥ 2 (and ≥ still), or ≥ 5 vehicles through in full hours after the report | suspected: warn on routes; confirmed: avoided (all vehicles) |
| `road_not_exist` | still ≥ 2 and no traversals in 14 days | same | confirmed: avoided for the reported `vehicle` |
| `oneway_wrong_closed_dir` | still ≥ 2 and no traversals in that direction for 14 days | same | v1: warn only |
| `oneway_wrong_open_dir` | one Emas and ≥ 5 traversals in that direction in 14 days | cleared ≥ 2 | never changes routing; maintainer/OSM queue |
| `turn_not_allowed` | still ≥ 2 | cleared ≥ 2 | v1: warn on routes |
| `place_closed_perm` | still ≥ 3, or one Emas | cleared ≥ 2 ("masih buka"), also after confirmation | suspected: badge; confirmed: hidden from search/nearby |
| `place_closed_temp` | still ≥ 2 | cleared ≥ 2 | badge "Tutup sementara sehingga …" until the date |
| `place_hours_wrong` | still ≥ 2 | cleared ≥ 2 | suspected: badge; confirmed: `openingHours`/`openNow` use the new hours |
| `place_entrance_wrong` | still ≥ 2, or one Emas | cleared ≥ 2 | confirmed: `Place.navigationPoint`, used as the routing destination |
| `place_info_wrong` / `place_duplicate` | still ≥ 2, or one Emas | cleared ≥ 2 | maintainer queue |

Expiry: closures accident 2 h · flood 6 h · event 12 h · roadworks 7 d · unknown 6 h (`durationHint`: today = end of the
Malaysian day, few_days 3 d, long_roadworks 30 d); every "still" extends to now + the subtype's duration.
`place_closed_temp` expires at its date; odd_route/new_road after 90 days; everything else after 180 days unless resolved.
A worker job runs every 15 minutes (passive evidence, expiry, resolution). Each transition is kept in the issue's audit
trail. When an issue closes, its votes are unlinked like place votes (HMAC with a per-issue salt, deleted 30 days later).

**Reputation**: confirmed → the reporter's accepted count +1; refuted by votes before ever being confirmed → rejected +1
(traffic clearing a real closure doesn't count against anyone). Voters: a "still" agrees with confirmed, a "cleared"
with refuted; each vote is scored once.

**Inbox**: the reporter gets `issue_confirmed`, `issue_refuted`, `issue_resolved` (`refType: "issue"`, `refId` = issue id).

**Routing**: `POST /routes` accepts `ignoreIssues: [issueId]` ("Lalu juga": not avoided for this trip only; kept for
reroutes). Confirmed `road_closed_temp`/`road_not_exist` within the trip's area (≥ 30 km around it, nearest 60) become
Valhalla `exclude_polygons` (a 50 m × 10 m box across the middle of the segment, so the junctions stay usable).
`routes[].issues` = `[{id, kind, subtype?, state, avoided, summary, confirmations, lastEvidenceAt, segment?, lat, lng,
distanceAlongRouteM?}]`: `avoided: true` = a confirmed closure within 1.5 km of the route that it goes around
("Mengelak Jln X"); `avoided: false` = an open road issue on the route (≤ 25 m; suspected closures, one-way, turns, and
ignored ones), with `distanceAlongRouteM`.

**Places**: `PlaceSummary.badge?` / `Place.badge?` = `{issueId, kind, state, label, until?}` for open `place_closed_perm`,
`place_closed_temp`, `place_hours_wrong` (`label` in the request language: "Dilaporkan tutup · sahkan?", "Tutup sementara
sehingga 2026-11-01", "Waktu mungkin berubah"). While a `place_closed_temp` is open (until its date) or a
`place_closed_perm` is confirmed, `openNow` is `false` whatever the opening hours say. Confirmed `place_closed_perm` places are left out of `/search` and
`/search/nearby`. `Place.navigationPoint?` = `NavigationPoint` (see "Arriving at the entrance"; the display pin is
unchanged).

### Route options

Added 26 Oct 2026, additive (older apps ignore the new fields and keep showing every route as before). The server
decides which alternatives are worth offering before a drive and says why, so both apps show the same list.

- **Shown routes come first**, fastest (with live traffic) first, at most 3. The rest follow with `hidden` set:
  `same_road` (over 80% of it within 30 m of a shown route), `slower` (over 40% slower than the fastest and saves under
  RM 3 in tolls, or beyond the 3 shown), `worse` (at least 5 min slower, 2 km longer and RM 1 more toll than a shown
  route; unknown fares never count). Apps show hidden routes only behind "Show anyway".
- **`reasons`** (shown routes, empty when only one is shown): `fastest`; `shortest` (at least 1 km and 5% shorter
  than the next); `no_tolls` (the fastest has tolls); `lower_toll` (at least RM 1 less, known fares only);
  `fewer_reports` (fewer reports than the fastest); `other_main_road` when nothing else applies and `viaRoads` is set.
- **`viaRoads`**: up to 2 roads (display ref, else name) with at least 2 km on this route and under 500 m on every other
  shown route. Apps use the other routes' `viaRoads` for "avoids E5 and FT2".
- **More tries on long trips:** when a car/motorcycle trip of 10 km or more without stops has fewer than 2 shown routes,
  the server also asks Valhalla for an avoid-tolls route (if the fastest has tolls) and for a route with the fastest
  route's main road blocked in two places. Near-copies are then hidden as `same_road`.
- **Apps:** trips of 10 km or more with 2+ shown routes open the preview with the list expanded and no auto-start
  countdown; shorter trips keep the countdown, with a compact "N other routes" row. The chosen route is never sent.

### Arriving at the entrance

`NavigationPoint = {lat, lng, issueId?, source: "confirmed"|"osm_entrance"|"outline", kind?}` is where a route to a
place ends. `confirmed`: a confirmed `place_entrance_wrong` (`issueId` set). `osm_entrance`: an OSM `entrance=*` node on
the building outline (`kind` = its value, `main` first; exits and emergency doors are skipped). `outline`: the outline
point nearest the closest named drivable road within 150 m, used only when the pin is more than 25 m from that road.
Map places carry it in `Place.navigationPoint`; a route whose destination has a `placeId` is routed to it and returns it
as `Route.arrival`. The apps draw the last metres from the route end to the pin dashed, and say which side the entrance is
on (docs/driving.md).

**Maintainers** (X-Admin-Key): `GET /admin/osm-queue?includeExported=` lists odd routes, new roads, "actually two-way"
and issues confirmed for 7+ days that OSM should fix, with a suggested note text and links (export only; nothing is posted
to OSM in v1); `POST /admin/osm-queue/{id}/exported` marks one done.

## Live map (alerts, jams, drivers)

```
GET /live?bbox=minLng,minLat,maxLng,maxLat&types=alerts,jams,drivers
  → {alerts: Report[], jams: Jam[], drivers: Driver[], serverTime}
```

`Jam = {id, level:1..4, speedKmh, delayS, lengthM, polyline, street?, updatedAt}`
`Driver = {lat, lng, heading, mood}` (anonymised, rounded to 3 dp, ≥ 3 drivers per cell)

SignalR hub: `wss://{host}/hubs/live`

| Direction | Method | Args |
|---|---|---|
| client→server | `Subscribe` | `bbox: number[4]` (replaces the previous subscription) |
| server→client | `AlertCreated` | `Report` |
| server→client | `AlertUpdated` | `Report` |
| server→client | `AlertExpired` | `reportId` |
| server→client | `JamUpdated` | `Jam` (`level: 0` = jam cleared → remove it) |

## Reports

```
POST /reports
{ "type":"hazard", "subtype":"pothole", "lat":3.1, "lng":101.6,
  "heading":270, "comment":null }
→ 201 Report   (+ `note` or `comment`: optional free text ≤ 500; screened, see below)

POST /reports/{id}/votes     {"stillThere": true}   → Report
POST /reports/{id}/thanks                           → 204
DELETE /reports/{id}   (signed)                     → 204   Undo within 2 min (docs/driving.md §6.4): withdraws your own
                                                    report, or your confirmation when yours was merged into it; later 409
```

**Report notes.** The free-text `note` (alias `comment`) is checked (docs/content-safety.md "Report notes"). A rejected or held note
is dropped and the report is created anyway: the `201` body then also has `noteDropped: true` and `noteReasons: string[]`
(both absent otherwise). If the check gives no answer in time or is off, the note is kept. Notes are not shown to other drivers.

Privacy: about an hour after a report expires, it is **unlinked from its reporter** (`reportedBy` becomes "Pemandu
Manotu") and its votes are deleted, so no per-user history of reported locations is kept. Points already earned stay.

One vote per pseudonym per report: voting again changes the answer (a withdrawn "still there" no longer counts in
`confirmations`) but earns no more points. Thanking a report again is a no-op (still 204).

```
Report = { id, type, subtype?, lat, lng, heading?, street?,
           reportedBy:{displayName, mood}, createdAt, expiresAt,
           confirmations, thanks }
type ∈ traffic, police, accident, hazard, closure, blocked_lane,
       map_issue, weather, animal
subtypes:
  traffic: moderate | heavy | standstill
  police:  visible | hidden | roadblock
  accident: minor | major | other_side
  hazard:  object_on_road | pothole | stopped_vehicle | roadkill | construction | flood | oil_spill
  closure: (free text in comment, optional endLat/endLng)
  blocked_lane: left | center | right
  weather: heavy_rain | fog | flood | haze
  animal:  on_road | on_shoulder
```

## Share my drive (end-to-end encrypted live ETA)

The driver shares a link (WhatsApp etc.). The recipient opens it in any browser and sees the driver's position
and ETA until arrival. **Manotu's server only relays ciphertext it cannot read**, so this keeps the
privacy rule in AGENTS.md.

1. The app generates a random 256-bit key `K` **on the device** and calls `POST /shares`.
2. Share link: `https://www.bukitbunga.com/gimano/s/#<shareId>.<base64url(K)>`. The part after `#` is
   **never sent to any server** by browsers, so the key stays between the driver and the recipients.
3. Every 15 s while navigating, the app encrypts
   `{lat, lng, heading, speedKmh, etaIso, remainingM, destinationName, status: "driving"|"arrived"|"ended", ts}`
   with **XChaCha20-Poly1305** (libsodium `crypto_aead_xchacha20poly1305_ietf`, random 24-byte nonce,
   associated data = shareId) and PUTs it.
4. The viewer page (`site/gimano/s/index.html`, static, served from bukitbunga.com) reads the fragment, polls `GET`
   every 10 s, decrypts in the browser (libsodium.js, self-hosted next to the page) and shows the position on a
   MapLibre GL JS map with the ETA. It never sends the key anywhere.
5. The share ends on arrival, on Stop, when the driver taps "Stop sharing", or at `expiresAt` (max 12 h).

```
POST   /shares              {expiresInMinutes: 15..720}            → 201 {shareId, writeToken, expiresAt}
PUT    /shares/{shareId}    Authorization: Share <writeToken>
                            {nonce: base64, ciphertext: base64}     (≤ 1 KB)  → 204
GET    /shares/{shareId}    (public, no auth; CORS for the viewer origin) → 200 {nonce, ciphertext, updatedAt, expiresAt}
                                                                     → 404 unknown · 410 ended/expired
DELETE /shares/{shareId}    Authorization: Share <writeToken>       → 204
```

Server storage: **in memory only** (latest blob per share, with TTL; never Postgres, never logged), and a
rate limit of 3 active shares per user. `shareId` is 128-bit random and `writeToken` is 256-bit random.
After the share ends, `GET` returns 410 and the blob is dropped immediately.
Before the first `PUT`, `GET` returns 200 with `nonce`/`ciphertext` = null. Limits: `nonce` must be 24 bytes and
`ciphertext` ≤ 1024 bytes (413 above); `POST` above 3 active shares → 429; a wrong `writeToken` → 401. CORS on
`GET` allows only the viewer origin (`https://www.bukitbunga.com` in production, any origin in dev). The store is
per API process, so the API must run as a single instance (or move to a shared in-memory store if it scales out).

## Event short links (end-to-end encrypted event packs)

**Additive** (24 Oct 2026): new endpoints only; nothing existing changes. Full design: `docs/events.md` §5.6.
An organizer's app uploads an event pack it has already encrypted; guests open `https://manotu.app/j/#<dropId>.<secret>`.
The key is derived from `secret`, which sits after `#` and **never reaches any server**, so Manotu keeps a blob it cannot
read (owner-approved exception to the privacy rule, see AGENTS.md).

```
POST   /drops               (Bearer JWT) Content-Type: application/octet-stream, body = blob
                            X-Drop-Expires: <ISO-8601 date-time>        → 201 {dropId, writeToken, expiresAt}
PUT    /drops/{dropId}      Authorization: Drop <writeToken>, body = new blob
                            [X-Drop-Expires: <ISO-8601 date-time>]      → 204
GET    /drops/{dropId}      public, no auth; CORS for https://manotu.app and https://www.bukitbunga.com
                                                                         → 200 application/octet-stream (Cache-Control: no-store)
                                                                         → 404 unknown · 410 expired/deleted (until purged)
DELETE /drops/{dropId}      Authorization: Drop <writeToken>            → 204
```

- Blob = `nonce (24) ‖ XChaCha20-Poly1305 ciphertext` (§5.6). **40 bytes ≤ size ≤ 256 KiB** (262 144): smaller → 400,
  larger → 413. Another `Content-Type` → 415.
- `dropId`: 10 characters of base58 (`123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz`), CSPRNG.
  `writeToken`: 256-bit random, base64url (43 chars); the server keeps only its SHA-256. A wrong or missing token → 401.
- `X-Drop-Expires` is required on POST (missing or unparseable → 400) and optional on PUT. No offset = UTC. The server
  clamps it to **now + 1 day … now + 400 days** and returns the clamped value in `expiresAt`.
- **50 live drops per user**; one more → 429. Deleted and expired drops don't count.
- `GET` is rate-limited per client IP, in memory only (`RateLimit:DropReadsPerMinute`, default 30) → 429.
- Expired or deleted drops: `GET`/`PUT`/`DELETE` → 410 until the hourly purge (worker) removes the row, then 404. `DELETE`
  clears the blob at once.
- Stored per drop: id, blob, SHA-256 of the write token, created/updated/expires/deleted times, and
  `HMAC-SHA256(Drops:OwnerKey, userId)`, used only for the quota and `DELETE /me` (which deletes all of the user's drops).
  No title, IP, user agent or user id. Request bodies, drop ids and IPs are not logged on these routes.

## Planned drives (on device)

Planned drives are personal data, so they are stored only in the local `planned_drives` table and backed up
with the rest. The app computes "Leave by" times by calling
`GET /routes/departure-times` (origin/destination are sent for the calculation only and not stored) and
schedules local notifications ("Bertolak sebelum 7:40 pagi untuk sampai 8:30 di Kerja"). A drive can be
one-off or repeat on chosen weekdays. Opening the notification goes straight to route preview.

## Feedback

Every screen's menu has **Add feedback**. Anonymous users can send feedback too, with their device token.

```
POST /feedback
{ "category": "bug" | "idea" | "map_data" | "route" | "search" | "other",
  "message": "Jalan ini sudah ditutup sejak minggu lepas",   // 1–2000 chars, required
  "rating": 4,                       // optional 1–5
  "screen": "navigation",            // home|search|place|route_preview|navigation|report|settings|other
  "device": {                        // ONLY when the user ticked "Sertakan maklumat peranti" (opt-in, default OFF, shown in a preview)
    "appVersion": "0.2.0", "appBuild": 2, "platform": "android"|"ios",
    "osVersion": "16" | "iOS 26.1", "apiLevel": 36,            // apiLevel Android only
    "deviceModel": "SM-S921B", "manufacturer": "samsung",
    "screen": {"widthPx": 1080, "heightPx": 2340, "density": 2.625, "widthDp": 411, "heightDp": 891},
    "locale": "ms", "theme": "light"|"dark", "dataMode": "live"|"demo"
  },
  "location": {"lat": 3.12, "lng": 101.62},   // optional, separate tick "Sertakan lokasi kasar", rounded to 2 dp ON THE PHONE
  "contact": {                       // optional; only if the user wants to be contacted about THIS report
    "email": "ali@example.com",      // either or both; validated
    "whatsapp": "+60123456789",      // E.164
    "consent": true                  // required true when any contact field is present
  },
  "routeId": "...", "placeId": "...",
  "screenshot": "<base64 PNG/JPEG, optional and opt-in (default OFF), ≤ 1.5 MB decoded>" }
→ 201 {id, createdAt, contactToken?}
→ 400 problem+json (validation; contact without consent=true), 413 (screenshot too big), 429 (> 10 per hour per user)

GET  /me/feedback            → FeedbackSummary[]   ({id, category, message, status, createdAt, hasContact})
DELETE /feedback/{id}/contact → 204   (header X-Contact-Token: the contactToken; or, for older feedback, as its author)
```

**A report that carries a contact is not linked to the account** (privacy rule: the contact must not be joinable to
the pseudonym). It is stored without the user id, so it does **not** appear in `GET /me/feedback`, gets no inbox
status updates (we reply by the contact instead) and isn't touched by `DELETE /me` (the contact still expires as below).
The create response returns `contactToken` once; the app keeps it with its local copy of the report and sends it as
`X-Contact-Token` to withdraw the contact. Rate limits still apply (counted in memory only). Feedback is deleted
after **24 months**.

`status ∈ received, triaged, planned, done, wont_fix`. Feedback is stored in Postgres (screenshot as bytea,
max 1.5 MB) and `feedback.created` is published on RabbitMQ. The optional GitHub-issue sink **never** includes
contact details, device model or location.

## Crash reports

No third-party crash SDK. The app writes a crash record **locally** (Android: `UncaughtExceptionHandler` +
`ApplicationExitInfo` for ANR/native exits; iOS: MetricKit `MXCrashDiagnostic`, delivered on the next launch).
On the next launch it asks *"Manotu terhenti tadi. Hantar laporan?"* with **Lihat butiran** (the exact JSON)
and a remembered choice: **Tanya setiap kali** (default) · **Sentiasa hantar** · **Jangan hantar**.

```
POST /crash-reports
{ "occurredAt": "2026-10-23T03:41:00Z",
  "kind": "crash" | "anr" | "native" | "hang",
  "exception": "java.lang.IllegalStateException", "message": "<first 500 chars, scrubbed>",
  "stack": "<≤ 32 KB, scrubbed>",
  "threads": "<optional, ≤ 32 KB>",
  "screen": "navigation", "uptimeS": 312,
  "device": { …same shape as feedback.device; opt-in like feedback (default OFF), shown in the preview… },
  "contact": { "email"?, "whatsapp"?, "consent": true }      // optional, as for feedback
}
→ 201 {id, signature, contactToken?}      // signature = sha256 of exception + top 5 app frames, for grouping
→ 429 (> 20 per day per install)

DELETE /crash-reports/{id}/contact   (header X-Contact-Token) → 204 · 404 when the token doesn't match
```

As for feedback, a crash report that carries a contact is stored without the user id.

**Scrubbing on the phone before sending:** coordinates (anything that looks like a lat/lng pair), emails, phone
numbers, tokens/JWTs, URLs with query strings and file paths under the user's data dir are replaced with `[redacted]`.
Crash records never include favourites, routes, search text or screenshots. Server retention: 90 days.

## Contact details (feedback & crash reports): the narrow exception

Contact details are the ONE kind of personal data the server accepts, and only when the user volunteers them on a
specific report:
- never prefilled and never stored on the user's pseudonym or profile: they belong to that one report, and that report
  is stored **without the user id** (no join links a contact to a pseudonym; withdraw with the report's `contactToken`);
- encrypted at rest (AES-GCM with a key from server config, not in the database);
- visible only to maintainers triaging that report; never in the GitHub sink, logs or analytics;
- **deleted automatically 30 days after the report is closed (done/wont_fix), and in any case after 90 days**,
  or immediately via `DELETE /feedback/{id}/contact` / `DELETE /crash-reports/{id}/contact` (with `X-Contact-Token`).

## Inbox

Notifications about the user's own **public** contributions only. Nothing private is involved, so this fits the
privacy rule. Items are generated by the worker from contribution events, kept for **90 days**, and deleted by
`DELETE /me`.

```
GET  /me/inbox?cursor=       → {items: InboxItem[], next?, unread}
POST /me/inbox/read          {upTo: ISO time}   → 204   (everything created at or before upTo is read; never moves back)
```

`InboxItem = {id, kind, title, body, refType?, refId?, createdAt, read, count}`
`kind ∈ place_published, place_rejected, place_expired, report_thanked, review_helpful, edit_accepted, feedback_status, announcement,
place_held, place_not_accepted, place_live, content_published, content_held, content_rejected`

- `place_held` / `place_not_accepted`: the AI check held or didn't accept the user's place (also sent when the app
  already showed the result). `place_live`: a place went on the map after the app stopped waiting (`checking`), or a
  maintainer accepted a held or appealed place. All three: `refType: "place"`, `refId` = the community place id.

- `content_published` / `content_held` / `content_rejected` (docs/content-safety.md): the content check or a maintainer decided on
  the user's review or photo (held and rejected are also sent when the app already showed the result; published only when it
  came late or from a maintainer). Besides the usual fields they carry `subjectKind: "review"|"photo"`, `subjectId`, `placeId`,
  `reasons: string[]` (fixed codes) and `canAppeal: bool` (rejected and not yet appealed), and `refType`/`refId` = the same
  subject. The title names the place. Places keep `place_held` / `place_not_accepted` / `place_live` (no `subjectKind: "place"`).

- `report_thanked` and `review_helpful` are **aggregated per day** (Malaysia time) into one item, e.g. "24 drivers thanked
  you" (`count: 24`). Each new thank moves it to the top as unread.
- `place_published` / `place_rejected`: `refType: "place"`, `refId` = the community place id.
- `feedback_status`: `refType: "feedback"`. Created when a feedback item's status changes, or when a maintainer approves a
  reply (possibly drafted by an agent) in the back office; then `body` is the reply text.
- `announcement`: broadcast to everyone (a server-side table that operators fill), with `refType: "url"` and `refId` = a link when present.
- `title`/`body` follow the request's `Accept-Language` (English default, Malay when preferred). The app may also render
  its own text from `kind` + `count`.
- Newest first, keyset-paged with `cursor` (30 per page). `unread` counts everything newer than the read mark.

## Back office & AI agents (not for the apps)

`/admin/v1/*` and the MCP endpoint `POST /mcp` (server `gimano-backoffice`) are for maintainers' AI agents. They take
`Authorization: Bearer agt_…` tokens minted in the back office (scopes `read`, `triage:write`, `runs:write`,
`replies:draft`; 8 h max) and answer 404 to requests that came through the public edge. They never return contact
details, user ids or device tokens. Details and the tool list: [`back-office.md`](back-office.md).

## Location pings

```
POST /locations
{ "routeId": "...", "points": [{lat,lng,speedKmh,heading,accuracyM,ts}] }   // ≤ 12
→ 202
```

## Enum wire format

All enums are lower `snake_case` strings exactly as listed above (`ev_charging`,
`blocked_lane`, `slight_left`, …). Unknown values are rejected with 400.
Optional fields are always present and `null` when absent.

## Health

`GET /healthz` (liveness) · `GET /readyz` (Postgres, OpenSearch, RabbitMQ, Valhalla)

`/readyz` returns 503 only when Postgres is down; OpenSearch / RabbitMQ / Valhalla
outages report `degraded` (200) since the API keeps working without them
(search falls back to Postgres, routing returns 503, live push pauses).
OpenAPI: `GET /openapi/v1.json`, interactive docs at `/scalar/v1`.
