# Android Auto review — replacement for rejected 0.4.2 (14)

Google rejected build 14 on 12 November 2026 for navigation intents (NF-6), missing
simulated test drive, and phone interaction while driving. The owner authorized fixes,
QA and replacement submission on 13 November. Candidate: 0.4.3 (15).

The current production release in Play Console is 0.3.5 (11), full Malaysia rollout.
Build 14 is rejected and must not be resubmitted. Latest bundles checked: 11–14;
no testing releases were shown in the release overview. Recheck before upload.

## Implementation

- Activity declares the car NAVIGATE geo intent; session handles cold and warm intents.
  Named destinations seed car search; coordinates open route choice. Invalid input is ignored.
- Host `NavigationManagerCallback.onAutoDriveEnabled` enables release simulation for
  subsequent drives. It is session scoped, and disconnect stops a host test drive.
- Existing navigation engine excludes simulated traffic probes. Car reports and votes are
  disabled during simulation, including callbacks from an already displayed report screen.
- Phone content is replaced during Android Auto projection. Disconnect restores normal UI;
  initial setup requires parking and disconnecting before using the phone.

## Required exact-artifact QA (record results for each candidate)

Run on the signed Play variant with a physical phone and DHU/real head unit.
Do not uninstall or clear the owner's app data. Record device/OS, SHA, artifact hash and video.

1. Cold launch by Assistant navigation: named destination, percent-encoded name, coordinates.
2. Warm request from home, route preview and active navigation; latest destination remains visible.
3. Choose result, route and Start; verify navigation/voice and End. Verify empty/invalid queries.
4. Enable test drive using the host command below, then choose a destination. Verify position
   advances without moving the phone, maneuvers/voice/arrival and End. Verify no traffic uploads,
   reports or votes. Disconnect: simulated drive stops; real navigation should remain running.
5. Phone connected before app launch and connected with app open; foreground/background and
   recreation. Phone controls must stay inaccessible. Disconnect restores the phone interface.
6. Test first-run setup before connection. Confirm the car prompts to park/disconnect when setup
   or permissions are missing. No permission/agreement flow should be forced while driving.
7. Run Play unit tests, merged-manifest and no-Drive AAB checks. Inspect signed artifact identity,
   production API, signature, version 0.4.3/code15; never upload debug or an unsigned AAB.

Host simulation command (physical device connected to Android Auto/DHU):

```sh
adb shell dumpsys activity service my.manotu.app/my.gimano.app.car.ManotuCarAppService AUTO_DRIVE
```

Replace the rejected production bundle only after QA passes; preserve Malaysia/full rollout.
Inspect all tracks for rejected bundles. Keep monitoring marked rejected/remediation until the
replacement submission is confirmed. Do not set backend latest version until public rollout.

References: [Navigation apps](https://developer.android.com/training/cars/apps/navigation),
[navigation intents](https://developer.android.com/develop/devices/assistant/intents-assistant-nav-app),
[connection API](https://developer.android.com/training/cars/apps/library/connection-api).

## 13 November replacement validation

The final signed candidate is built from master `ebdcaa9` (0.4.3/code15). Release tests:
605 passed, zero failures; Play manifest and no-Drive AAB guards passed. Exact APK/AAB
signatures and production identity were verified. Physical S22 (Android16) DHU checks
covered cold/warm navigation intents, encoded queries, coordinates, invalid/no-result input,
active-drive replacement, repeated route choice, simulation progress/arrival/End,
phone lockout through recreation and restoration/stopping simulation on disconnect.

Physical QA found two additional host integration defects: deprecated route-preview rendering
could lose rows on reopening, and speech did not request navigation audio focus. Current hosts
use MapWithContentTemplate for route choice with visible navigation actions. VoiceGuide now
uses navigation/speech audio attributes, transient-may-duck focus and releases focus after
completion/error/stop. The owner explicitly confirmed audible directions and arrival on the
final candidate; earlier silent candidates are superseded.

Local exact-artifact hashes, timestamped2fps physical-device video (without an audio track),
phone screenshots and QA results are in ignored
`artifacts/android-auto-review-20261113/revision-ebdcaa9/`. Audio confirmation is the owner's
listening result, not an audio recording. No owner data was cleared. Test server/forward
were stopped, developer mode restored off and the temporary test helper removed.
Store submission status must be verified in Play Console; passing QA is not public availability.
