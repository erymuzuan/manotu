# Handoff: publishing Manotu to Google Play and the App Store (for CodexApp)

Prompt written 27 Oct 2026 by the Claude session Mac.Manatu.master for the owner (erymuzuan). Paste the block below to Codex.
Repo: `https://github.com/erymuzuan/manotu` (local folder `gimano`), branch `master` only. Read `AGENTS.md` first.

---

## Prompt

You are taking over **publishing new Manotu builds to Google Play and the Apple App Store / TestFlight**. Manotu is a
Malaysia/Singapore/Brunei navigation app: Android (Kotlin/Compose, `android/`), iOS (SwiftUI, `ios/`), .NET 10 backend
(`backend/`). Bundle/package id on both stores: `my.manotu.app`. Releases are on a **daily cadence**, so keep the process
repeatable and boring.

### 1. Rules you must keep (from AGENTS.md; do not weaken them)

- **Apple team: STAFY COMPANY LIMITED, `98KY9PMPX3`**, App Store Connect app `6826478029`. The owner reconfirmed this on
  26 Oct 2026 ("use STAFY, not individual Apple account"). Verify the team before any signing or upload. Never create a
  duplicate app, transfer ownership, or change bundle ids. (`docs/sideloading.md` still has an old "individual
  membership, not STAFY" paragraph: it is stale; AGENTS.md wins. Fix that paragraph.)
- Google Play is published under the existing **STAFY CO LTD** Play account, Malaysia first.
- **Portal actions belong to the owner:** App Store Connect / Play Console registration, agreements, listings, review
  submission and any first upload. Do an upload or submission only when the owner authorises it for that task. Never ask
  for, paste or store credentials. The App Store Connect API key lives in git-ignored `ios/Config/asc.env`; the Android
  keystore password comes from the macOS Keychain or `GIMANO_KEYSTORE_PASSWORD`. Never print `.env`/key lines.
- **Release builds point only at production:** `https://gimano-api.bukitbunga.com/api/v1/` (alias `api.manotu.app`).
  The Gradle script and `AppConfig.swift` refuse any other host. Never ship a build that mentions `100.101.150.9`
  (Tailscale dev server). Check the built artifact, not only the source.
- Privacy promise is non-negotiable (AGENTS.md): no new SDKs, no analytics or ads, no private data on servers.
- Only `master`; commit and push straight to `origin/master` when the owner asks (no PRs for the owner's own work).
  Commit trailers: `Co-Authored-By:` your own model line, plus the session line your harness gives you.
- Play build must not self-update (`bundleManotuPlay`, manifest guard in `app/build.gradle.kts`); Google Drive backup is
  off in the Play build and iCloud/Drive are off in the TestFlight build (see `ios/RELEASE.md`).

### 2. Current state (27 Oct 2026, `master`)

- Android: `manotuDebug`/`manotu` flavour versionCode 13 in `app/build.gradle.kts`; website APK live is 0.3.4 (code 10).
  Check `version.json` at `https://manotu.app/download/version.json`.
- iOS: `MARKETING_VERSION 0.4.1`, `CURRENT_PROJECT_VERSION 13` in `ios/project.yml` (every upload needs a new build number).
- New since the last store builds (all on `master`, all untested on production):
  public content safety (Haiku 5.5 checks for reviews, photos, notes; place alcohol/gambling/tobacco warnings; saved
  refusals and an Appeal flow with a required reason); OSM place flag; DEV-badged debug icons; the store **update nudge**
  (`GET /api/v1/app/versions`, soft then forced cards; `docs/app-updates.md`).
- Debug builds are DEV-badged (red "DEV" icon, "Manotu DEV") and point at the dev stack on WS556. They share the real
  bundle id, so never upload a Debug build.

### 2a. Production backend (owner's statement, 27 Oct 2026)

The owner states that these features are all implemented in the **production** backend (172.30.30.150): public content
safety (reviews, photos, notes, place warnings, brand watchlist), appeals and the OSM place flag, feedback spam flag,
`GET /api/v1/app/versions` and the Apple poller. **Verify it before you ship, do not assume it.** When this prompt was
written, the Claude session that wrote it had only deployed these to the dev stack on WS556 and had no confirmation from
SERVER.Manotu about production. Check against production: `GET https://gimano-api.bukitbunga.com/api/v1/app/versions`
returns 200 (not 404), `/readyz` is healthy, the migrations `ContentSafety`, `AppealsOsmFlagsFeedbackSpam` and `AppVersions` are
applied, and a search result carries `warnings` after the reindex. If anything is missing, finish step 1 below before the
apps reach users.

A new store version is expected **today (27 Oct 2026)**; the owner has you working on it, so the Facebook announcement
(driving reports and place warnings, worded "coming soon") must not say "out now" until the store rollout is live.

### 3. Order of operations for every release (backend first)

The new apps call endpoints that **production does not have yet** (`/appeals`, `/app/versions`, new reason codes,
warnings). Release the backend before the apps reach users.

1. **Backend to production** (172.30.30.150): project skill `.claude/skills/release-backend/` and `deploy/PRODUCTION.md`.
   Images are built on WS556 (never on WS556-SERVER), deployed by the Claude session **SERVER.Manotu** on WS556-SERVER
   with the BespokeTech VPN, `pg_dump` first when there is a migration. This release has migrations
   (`ContentSafety`, `AppealsOsmFlagsFeedbackSpam`, `AppVersions`). After deploy: reindex search (importer with
   `--skip-places --skip-roads --skip-tolls`, run in the `tools` profile) so results carry `warnings`, and set the
   production `CLAUDE_API_KEY` in `deploy/.env.prod` (a separate production key, typed by the owner; never copy or print
   the dev key). Without a key the AI check is off and the plain filters apply.
2. **Android website APK** (existing channel): skill `.claude/skills/release-apk/` (bump, tag, build, release notes,
   GitHub Release, deploy via SERVER.HiRO, switch `version.json` last).
3. **Android Play:** `./gradlew :app:bundleManotuPlay` (set `JAVA_HOME=/opt/homebrew/opt/openjdk@17`,
   `ANDROID_HOME=/opt/homebrew/share/android-commandlinetools`). The AAB is signed per `android/keystore.properties.example`.
   Verify: Play manifest guard passes, no `REQUEST_INSTALL_PACKAGES`, production API URL only. The owner uploads to the Play
   Console (or authorises you to) and starts the rollout.
4. **iOS TestFlight / App Store:** `ios/RELEASE.md` and `ios/scripts/testflight.sh` (archive Release, export, upload with
   `altool`; bump `CURRENT_PROJECT_VERSION` each time; `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`;
   XcodeGen: `cd ios && xcodegen`). Export compliance and the checklist at the end of `ios/RELEASE.md` apply.
5. **When a store rollout is actually live to users**, mark it so installed apps nudge:
   - iOS is detected automatically: the backend worker polls Apple's lookup hourly.
   - **Google Play must be marked by you:** `PUT /api/v1/admin/app-versions/android-play` with `{"version":"<versionName>"}`
     using the admin key (or the back-office "App versions" page). Without this step Play users are never told. The same
     endpoint takes `minVersion` to force an update. The rules are in `docs/app-updates.md` (soft prompt when older than
     latest, forced when older than the version 3 releases back).
   - Add this step to `.claude/skills/release-apk/SKILL.md` (or a new `release-stores` skill) so it is not forgotten.
6. Verify publicly: production `GET /readyz`, `GET /api/v1/app/versions`, and the installed store build shows the
   production server in About.

### 4. Things worth doing as part of the handoff

- Write a short `release-stores` project skill covering steps 3 to 5 so each daily release is one checklist.
- Confirm the Play data-safety form, the App Store privacy answers and the age/content ratings still match the new
  public-content features (user reviews and photos, AI moderation by a third-party model, no ads, no tracking). The AI
  check sees only public text or the photo after EXIF is stripped; say so in the listings. Do not change store listings
  without the owner.
- Known open items (not store blockers): production backend release (above); a production Claude key; no moderation page in
  the back office (appeals and OSM flags go through the admin API); report notes and add-place refusals are not saved
  on the phone yet; a pending request from the KhaiRider session for a `manotu://navigate?lat&lng` deep link, which the
  owner has not yet approved.
- Test devices: Samsung S24 `adb -s RFCXA0LVBTE`, iPhone 16 `xcrun devicectl ... --device 00008140-00154CA90A8B001C`.
  Release builds need a Release configuration check on a device, not only a simulator.

### 5. Report back with

The version and build numbers shipped, the commit sha, what was uploaded where and by whom, the production checks you ran
and their results, and anything you skipped or could not verify.
