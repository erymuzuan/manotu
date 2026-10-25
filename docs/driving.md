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
