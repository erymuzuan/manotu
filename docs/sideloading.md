# Direct downloads and AltStore Classic

Public downloads: https://manotu.app/download/
Legacy Gimano channel: https://www.bukitbunga.com/gimano/download/
AltStore source: https://www.bukitbunga.com/gimano/altstore.json
GitHub releases: https://github.com/erymuzuan/manotu/releases

## Android

Publish a **release-key-signed** APK, never a debug APK. Keep the signing key unchanged so upgrades preserve
local data. The v0.1.0 APK already published remains unchanged. SHA-256 certificate fingerprint:
`b9baddcd63b3d74b8a374cb93df3278579ba4faeae121c35827d377e210bbec9`.
Users need Android 8+. Allow installation for the browser/Files app when requested; it can be disabled after installing.
Export a backup before removing a differently signed development build.

## iPhone

The IPA is an arm64 Release build, iOS 17+, for re-signing with AltStore Classic or Sideloadly.
It is **not** an App Store, TestFlight, enterprise, or pre-provisioned Ad Hoc installer.
AltStore Classic works worldwide; the user signs with their own Apple account. Free signing requires
refreshing within seven days and allows three active apps (AltStore counts as one).
Initial AltStore setup requires a Mac or Windows computer running AltServer.

Build with `ios/scripts/sideload.sh` from the repository root. Xcode must be installed.
The build explicitly disables iCloud and Google OAuth configuration. File backups remain available.
Do not bundle personal provisioning profiles, Apple credentials, or a company signing identity.
Use a separate TestFlight/App Store build for capabilities bound to the developer team.

The source feed lists the exact version/build, minimum OS, byte length and privacy usage strings from the IPA.
Regenerate it after changing any binary; upload immutable versioned assets before updating the feed.
Free accounts cannot use every Apple entitlement: keep the sideload build free of iCloud, push and app-group requirements.

## Release integrity and provenance

Publish checksums alongside binaries. When a release is built from an uncommitted source snapshot, attach
that exact source snapshot and explicitly identify it in the release notes; never imply the release tag
alone reproduces it. Exclude all ignored configuration, signing files, build products and credentials.
The initial iOS sideload snapshot also updates the feedback contract test from `context` to `location`.

## Website deployment

Use the dedicated Manotu and legacy Gimano folders and additive deployment described in AGENTS.md. Serve `altstore.json` as JSON.
Keep the source URL stable; preserve older version entries when adding new releases.
The download page must disclose signing renewal, backup limitations and whether a TestFlight link exists.
Do not present a successful compiler run as a successful AltStore installation on a phone.

## TestFlight ownership

Manotu uses **STAFY COMPANY LIMITED (98KY9PMPX3)** for device signing, TestFlight and App Store distribution,
as reconfirmed by the owner on 26 October 2026. Use the existing `my.manotu.app` identifier and App Store Connect
app `6826478029`; do not create a duplicate app. Verify the team before signing or uploading.

## Coordination with Mac.Gimano

The homepage entry is `/gimano/#muat-turun`. APK, IPA and AltStore each have separate controls.
Mac.Gimano owns APK publication and `/gimano/download/version.json`; never write that manifest from
website work. `downloads.mjs` reads it without caching and updates Android links/labels/checksum only
when the version, checksum and exact first-party APK URL validate. Missing/invalid metadata keeps the
verified static fallback. Publish and verify the APK **before** the manifest. Update static fallback
links in a subsequent website release for users without JavaScript.

Android and iOS versions are independent. Do not advertise an Android test build (e.g. updater-test
0.2.1) as public, or label the iOS IPA 0.2.x because Android has that version. Add an AltStore version
only after the matching IPA is published. As of this handoff Android 0.2.0 is pending publication;
0.2.1 is a private updater test; iOS is 0.1.0.
