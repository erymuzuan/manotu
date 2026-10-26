# Driving: toll alerts, camera modes, steady arrow, arriving at the entrance, car screens

Design: canvas "Manotu App Design", page **Driving** (row "Tester drive 25 Oct", boards "Camera modes", "Steady arrow")
and page **Android Auto & CarPlay** (all rows; the newest row "Since the first car design"). Decided by the owner on
25 Oct 2026 after a tester's drive. Server contract: `docs/api.md` (`Route.tolls[].distanceAlongRouteM`,
`Route.arrival`, `Place.navigationPoint`, "Arriving at the entrance").

Everything here is computed on the phone from the route it already has. Nothing new about the user is sent or stored
(privacy rule, AGENTS.md).

## 1. Toll ahead

- Source: `route.tolls`, each with `distanceAlongRouteM` (fall back to projecting `lat/lng` on the route when absent).
- **Banner** when the plaza is 1 km ahead (500 m below 60 km/h): plaza name, fare and distance. Hidden 10 s after
  passing the plaza.

| Case | BM | EN |
|---|---|---|
| Fare known | **Tol Sungai Besi** · 900 m di hadapan · **RM 2.10** | **Sungai Besi toll** · 900 m ahead · **RM 2.10** |
| Closed-system entry | Tol masuk · bayar di tol keluar | Toll entry · pay at the exit |
| Fare unknown | Tol di hadapan · harga tidak diketahui | Toll ahead · fare unknown |

- **Voice**, once per plaza, in sound modes **Full and Alerts only** (never Mute):
  "Tol Sungai Besi di hadapan, dua ringgit sepuluh sen." / "Sungai Besi toll ahead, two ringgit ten." Closed entry:
  "Tol masuk Sungai Besi di hadapan." / "Sungai Besi toll entry ahead."
- **Trip bar / sheet**: "Tol setakat ini RM x · anggaran RM y" / "Tolls so far RM x · estimate RM y" (sum of plazas
  already passed; estimate = `tollEstimateMyr`, "from RM y" when not complete).
- Plaza icon on the map along the route.

## 2. Camera modes (navigation)

One camera controller, five modes. Priority: **Simpang > Tinjau > speed modes**.

| Mode | When | Zoom | Tilt | ≈ road ahead |
|---|---|---|---|---|
| Simpang | next maneuver ≤ 300 m or ≤ 15 s away; ends 50 m after it | 17.2 | 55° | 250 m |
| Perlahan | speed 0–30 km/h | 16.5 | 50° | 500 m |
| Bandar | 30–80 km/h | 16.0 | 50° | 800 m |
| Lebuh raya | ≥ 80 km/h | 15.2 | 50° | 1.5 km |
| Tinjau | a jam (traffic level ≥ 3 on `trafficSegments`), closure, accident or hazard alert starts ≤ 5 km ahead | fit arrow + start of the problem (never below zoom 12.5) | 30° | up to 5 km |

- Zoom values are MapLibre zoom levels at the phone's density; iOS converts to camera altitude/distance equivalently.
- Speed modes switch after the speed stays past the threshold for 5 s, with ±5 km/h hysteresis (Bandar → Lebuh raya at
  85, back at 75; Perlahan → Bandar at 35, back at 25). Changes ease over 2 s.
- **Tinjau**: once per jam/alert; zoom out over 1.2 s, hold 6 s, ease back 2 s. While it shows, a banner:
  "Sesak 4.8 km di hadapan · 1.2 km panjang · +6 min" / "Traffic 4.8 km ahead · 1.2 km long · +6 min" (length from the
  traffic segments; delay = traffic duration difference when known, else omitted). Skipped while Simpang is active or
  when a maneuver comes within 20 s. Not repeated for the same jam (the usual 1 km alert still plays).
- The arrow sits lower on screen at higher zoom-outs (more road ahead).
- A pinch or pan pauses all modes until the existing 10 s auto-recentre.

## 3. Steady arrow

- One **animated puck position**: each new fix starts an interpolation from the current animated position to the new
  (snapped) position, lasting the measured fix interval (clamped 0.3–1.2 s), along the route line when snapped.
- If no fix arrives, keep moving along the route at the last speed for up to 1 s, then hold. Never extrapolate past a
  maneuver point.
- The **camera follows the animated position every frame** (no separate eased camera commands per fix). Zoom/tilt
  changes from §2 are eased by the same per-frame loop.
- **Heading**: the route direction 20 m ahead of the snapped point, low-pass filtered, turn rate ≤ 90°/s. GPS course is
  used only when off-route and above 10 km/h.
- **Snap hysteresis**: snap when within 25 m (and heading within 60° above 10 km/h); release only beyond 40 m for 3 s.
- Update only changed map layers per frame (the route line, traffic and alerts only when they change).

## 4. Arriving at the entrance

- Routes to a place end at `route.arrival` when present (the server already routes there).
- **Arrived** when the remaining distance along the route is ≤ 30 m **or** the straight-line distance to the pin is
  ≤ 40 m, whichever comes first (and the driver is on route for the first rule).
- Draw the **last metres** dashed: route end → entrance (blue dots) and entrance → pin (grey dots) when the pin is more
  than 15 m from the route end.
- Arrival card: title "Anda sudah tiba" / "You've arrived", the place name, and a line saying which side the entrance
  is on (left/right of the direction of travel at the route end) and how far from the road:
  "Pintu masuk utama di sebelah kiri · 25 m dari jalan" / "Main entrance on your left · 25 m from the road"
  (`kind: main` → "Pintu masuk utama"/"Main entrance"; other kinds → "Pintu masuk"/"Entrance"; `outline` → "Tempat ini
  di sebelah kiri"/"The place is on your left"). Buttons: "Selesai"/"Done" and "Pintu masuk salah?"/"Wrong entrance?"
  which opens the existing `place_entrance_wrong` report.

## 5. Android Auto and Apple CarPlay

The car screen is a second view of the drive the phone runs: one navigation session, same route, same on-device data.
Templates (canvas page "Android Auto & CarPlay", first board):

| Screen | Android Auto (Car App Library, navigation category) | CarPlay (CarPlay framework, navigation) |
|---|---|---|
| Ke mana? | MapWithContentTemplate / PlaceListNavigationTemplate: Rumah, Kerja, favourites, recents (≤ 6 rows driving) | CPMapTemplate + CPListTemplate |
| Search | SearchTemplate (keyboard when parked only) | CPSearchTemplate |
| Route choice | RoutePreviewNavigationTemplate, max 3 routes, "Tanpa tol"/"Tol RM 2.10" | CPMapTemplate.showTripPreviews |
| Navigating | NavigationTemplate (RoutingInfo, TravelEstimate); we draw map, route, traffic, speed limit, © OSM line on the surface | CPNavigationSession + CPManeuver; same surface drawing |
| Lapor | GridTemplate, 6 types, one tap | CPGridTemplate (≤ 8) |
| Masih ada? | Alert (API 5): Ya / Tiada, 8 s, ≤ 1 per 2 km | CPNavigationAlert |

Changes since the first car design (canvas row "Since the first car design"):

- **Agreement**: never shown in the car. Not agreed → AA MessageTemplate / CarPlay CPInformationTemplate
  "Buka Manotu di telefon untuk bermula" + "Faham".
- **Drive reminder**: no card; if the reminder is on, AA CarToast / CarPlay 5 s CPNavigationAlert "Pandu dengan selamat.
  Patuhi undang-undang jalan raya." at start.
- **Restricted areas**: drawn and labelled on the surface (no tap sheet). Report inside → "Laporan tidak diterima di
  kawasan larangan." (AA CarToast / CarPlay 3 s alert); nothing sent.
- **Toll ahead**: AA Alert / CPNavigationAlert "Tol Sungai Besi" · "900 m · RM 2.10", 8 s, no buttons; voice through
  car audio once (phone and car never both speak).
- **Camera modes and steady arrow**: same controller and renderer on the surface; Tinjau text in the alert.
- **Arrival**: final step "Pintu masuk utama di sebelah kiri"; dashed last metres on the surface; "Pintu masuk salah?"
  stays on the phone.

Platform gates: CarPlay needs the CarPlay navigation entitlement under Erymuzuan Mustapa's individual Apple team (never
STAFY); until Apple grants it, CarPlay is built and tested in the CarPlay Simulator only and is excluded from device and
AltStore builds. Android Auto needs the navigation category and Google's quality review; test with the Desktop Head
Unit (DHU) and Android Auto developer mode / unknown sources on the test phone.

## 6. Confirm card, sound selector, travelled route, hold-to-report

Design: canvas page **Driving**, first row (boards "Issues from the S24 drive + rules" to "Sent at once"). Found on the
S24 drive: the "Still closed?" buttons were cut off, and the sound button toggled blindly on each tap.

### 6.1 Confirm card ("Still closed?" / "Still there?")

- Three equal buttons, **84 dp/pt tall**, icon above a **full label** (max 2 lines, never truncated; shrink the font
  before cutting): primary "Still closed" / "Masih ditutup" (blue), "It's open" / "Sudah dibuka" (light blue),
  "Not sure" / "Tak pasti" (outlined). The same layout for road alerts: "Still there" / "Gone" / "Not sure".
- Title row: icon tile, question ("Still closed?"), subtitle (kind · street · age, e.g. "No turn · Jalan SS 2/3 ·
  5 h ago"), and a **10 s countdown ring**; when it runs out the card closes with no answer.
- Language follows the phone (BM/EN). The card sits above the trip bar and never covers the maneuver banner.

### 6.2 Sound selector

- Tapping the sound button opens a small panel (not a toggle): **Full sound** ("Directions + alerts"), **Alerts only**
  ("Police, closures, hazards"), **Mute** ("No sound"), with the current choice marked, plus a **voice volume** slider
  (app's own voice volume, 0–100 %).
- Choosing an option, or tapping outside, closes the panel. A **2 s toast** confirms the change ("Alerts only: voice
  directions off").
- **Button states**: a distinct icon per mode; Mute has an orange ring. **Long-press = quick mute** (toggle Mute / back to
  the previous mode).
- The choice is remembered across trips (on the phone only). Accessibility: the button announces the current mode;
  TalkBack/VoiceOver announce the new choice.

### 6.3 Travelled route

- The part of the route behind the arrow is redrawn **light grey (#C3CAD6) on a white casing** as you pass it; the road
  ahead stays blue. It follows the animated arrow position (§3), so it moves smoothly.
- After a reroute, only the new route shows (the old one, travelled or not, is removed).
- Traffic colours apply only to the part ahead.

### 6.4 Reporting while driving: tap drawer, hold arc, one detail sheet

Redesigned 26 Oct 2026 (owner-approved; canvas page **Driving**, row "Reporting while driving, redesigned 26 Oct",
boards RpFlow, RpDrawer, RpDetail, RpHold, RpSent, RpAhead1, RpAhead2). It replaces the 8-bubble fan that sent at once.
Two ways in, one ending, so a tap and a hold no longer behave differently.

- **Tap** the report button: the **drawer** "What do you see?", 9 tiles: Traffic, Police, Crash, Hazard, Closed, Lane,
  Map issue, Weather, Animal. Pick one: the **detail sheet**.
- **Hold** (~300 ms): **5 bubbles on one arc** up and left of the button: Hazard, Police, Crash, Traffic, Closed.
  **Slide** onto one: it grows, haptic tick, banner shows its name ("Let go to continue · slide to ✕ to cancel").
  **Let go** on it: the detail sheet. Let go anywhere else, or on ✕: cancel. Weather, Animal, Lane and Map issue are
  in the drawer only.
- **Detail sheet** (both doors end here): the type's subtypes with the **default already picked** (Traffic: heavy;
  others: the first; Closed has none), **Cancel** and **Report**. It **sends itself after 3 s** (the Report button fills
  as the timer runs, "Sends in 3 s · tap an option to choose first"); touching an option or typing stops the timer.
  **Map issue** has its own sheet (road problems) and never auto-sends.
- After sending: the card "Crash reported · Jalan SS 2/55 · just now" with **Undo** for **5 s** (Undo deletes the
  report on the server, or cancels it if not yet sent). There is no Details button any more: the choice was made
  before sending.
- The existing rules still apply: restricted areas refuse reports (docs/safety.md), rate limits, signed requests.
- Accessibility: TalkBack/VoiceOver users get the drawer on a plain activation (no gesture needed).
- Android Auto / CarPlay: no hold; the report grid sends the chosen type at once with its default subtype.

#### Getting a report to the next driver ("is it still there?")

- Server (unchanged): a report is stored, merged with the same type within 150 m and 45° of heading, broadcast on the
  live feed (AlertCreated / AlertUpdated / AlertExpired) and expires by type (Crash/Hazard 60 min, Police/Animal
  30 min, Traffic 20 min, Weather 120 min, Closure 24 h, Blocked lane 60 min); "still there" extends it, two "not
  there" votes remove it.
- Phone (new): `route.alerts` is only a snapshot from when the route was calculated, so a crash reported after the
  driver set off was never announced. The phone already listens to the live feed for its map area; it now **matches
  those alerts to its own road ahead on the device** (within 40 m of the route line, not facing the other way, never
  `other_side`) and adds them to the trip. Reports this phone sent are never asked about. **The server never learns
  the route.**
- Driver: voice once and a chip "Crash · 1 km ahead" from **1 km**; the **"Still there?" card from 150 m before to
  100 m after** the spot (10 s ring; no answer = no vote); Still there / Gone / Not sure extend or expire the alert as
  in §6.1. The car uses the same trigger (150 m, at most one per 2 km).
