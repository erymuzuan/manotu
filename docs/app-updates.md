# App updates (store versions)

We ship daily, so an installed store app asks the API whether a newer store version is live: a soft nudge when behind,
a forced update when too far behind. No user data is involved: the request is anonymous and identical for everyone.

## Endpoint

```
GET /api/v1/app/versions        (no auth, no body, no query)
200 Cache-Control: public, max-age=300
{
  "platforms": {
    "ios":          { "latest": "0.4.2", "forceBelow": "0.4.0", "storeUrl": "https://apps.apple.com/app/id6826478029", "releasedAt": "2026-10-26T03:04:05+00:00" },
    "android-play": { "latest": "0.4.2", "forceBelow": null,    "storeUrl": "https://play.google.com/store/apps/details?id=my.manotu.app", "releasedAt": "2026-10-26T09:00:00+00:00" }
  }
}
```

- Keys: `ios`, `android-play` (the sideloaded APK/AltStore builds have their own updater; ignore this endpoint there).
- A platform is **absent** until a release is known. Treat a missing platform, a network error or a non-200 as "no update info": do nothing.
- `latest`: highest marketing version known (`major.minor.patch`, compared numerically: `0.4.10` > `0.4.9`).
- `forceBelow`: `null` or a version. An app whose version is **strictly below** it must update.
- `storeUrl`: open it for the update. `releasedAt`: when it went live (ISO 8601; informational).
- Rate-limited like other public endpoints (429 + `Retry-After`).

## Client rules

1. Compare the app's marketing version (not the build number) with the response, numerically per part.
2. `appVersion < forceBelow` -> blocking "Update required" screen with a button to `storeUrl`.
3. else `appVersion < latest` -> soft, dismissible nudge (suggest: show again after 24 h or when `latest` changes).
4. Check at launch and at most once per foreground resume per hour; honour the 5-minute cache. Never block on the call.

## How versions are decided

- iOS: the worker polls Apple's public lookup hourly (`AppUpdates:PollAppStore`, default true) and records the live version.
- Google Play has no public lookup: a maintainer marks a release live once it is rolled out (back office "App versions", or
  `PUT /api/v1/admin/app-versions/android-play {"version":"0.4.2"}`; see [`back-office.md`](back-office.md)).
- `forceBelow` = the higher of the maintainer's `minVersion` and the version `maxBehind` (default 3) releases older than
  `latest`, counted over the distinct versions we have recorded; `null` if fewer exist and no min is set.

Tables: `app_releases (platform, version, first_seen_at, released_at)`, `app_version_config (platform, min_version, max_behind, store_url, updated_at)`.
Only public store facts are stored.
