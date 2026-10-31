# App Store review evidence

Applies to Manotu `my.manotu.app`, App Store Connect `6826478029`, STAFY `98KY9PMPX3`.
Read with `ios/RELEASE.md` and the `release-stores` skill. Never use an old handoff as proof of current production behavior.

## Why this is a release gate

On 31 October 2026 Apple rejected 0.4.2 (14), submission
`18806c97-4bcf-48d0-98c8-214033f6d5d9`, under **2.1 — Information Needed — New App Submission**.
Apple requested six items below in both the review reply and App Review Information Notes.
The message did not identify a specific crash. A replacement upload alone does not answer it.

## Evidence checklist

- [ ] Read the complete current reviewer message and record date, submission, version and build.
- [ ] Select one committed release SHA; coordinate concurrent work. Do not sweep unrelated working changes into an archive.
- [ ] Test the actual submitted Release build on supported physical devices, against production.
      Record device model, OS version, build, tests, results and any limitations.
- [ ] Capture a physical-device recording on the latest public OS supported by that device, beginning at launch.
      Verify OS currency rather than inferring it from the device model. No simulator footage passed off as physical footage.
- [ ] Explain purpose, audience, problem solved and user value.
- [ ] Provide setup and exact main-feature steps; supply test credentials/sample files only if needed.
- [ ] List core external data providers, hosted services, authentication, payment and AI services actually used by this build.
- [ ] Explain geographic data coverage and regional feature differences. Do not claim global navigation coverage.
- [ ] Supply relevant permissions/licences for third-party data/material; explain regulated services if applicable.
- [ ] Place the complete answer in **both** the review reply and App Review Notes. Verify saved text and attachments.
- [ ] Verify any video link is accessible without a developer login, and does not reveal private phone data or credentials.
- [ ] Verify the intended build is selected before resubmitting. Save console evidence of submission status.

## Physical recording plan

Use the exact submitted build, with its version visible, not a newer debug app. Enable notification suppression
with the device owner's permission if needed; keep private favourites, history, contacts and other apps off camera.
Record real UI, not a staged marketing mockup. Never uninstall/reset the owner's installation to get a clean launch.

1. Begin at app launch. Show any onboarding/permissions and explain that normal navigation needs no email/password login.
2. Search for a known public destination in the supported region; open its details, select a route and show navigation/voice controls.
   Do this while stationary; do not publish fake hazard reports or start driving for the recording.
3. Show local favourites and file backup UI using non-private sample data, if part of the typical flow.
   Confirm Drive/iCloud availability against the submitted artifact rather than current source flags.
4. Show public reviews/photos and their **Report** and **Block this user** controls, plus blocked-user management.
   Use legitimate test content and identify test submissions; do not make false abuse complaints about real contributors.
5. Show the pseudonymous identity/account explanation and deletion UI. Complete destructive deletion only on a dedicated
   test identity with the required authorization; never delete the owner's existing identity or local data just to record.
   If only the confirmation UI was demonstrated, state that limitation rather than claiming completed deletion.
6. Show paid features if any; otherwise explicitly state there are no paid features, subscriptions or purchases after verifying.

## Build decision

Information-only rejection: retain the selected build when physical QA passes and all requested information can be supplied.
If QA exposes a defect, fix it on a coordinated committed SHA, run relevant tests, allocate an unused increasing build number,
archive/export with STAFY, inspect the artifact and repeat the physical recording. Do not upload the shared dirty checkout.
Use a new marketing version for a new release; a corrective replacement for an unreleased version can retain that version.

## Evidence record template

Keep per-submission evidence in ignored `artifacts/app-review-<date>/`:

```
Version/build, committed SHA, IPA hash:
Selected App Store submission:
Physical device / OS / latest-OS check:
Production revision and prerequisite checks:
QA cases and results:
Video file, hash, upload/link and independent access check:
Reviewer requests 1–6: answer and supporting evidence for each:
App Review Notes save verified:
Review reply/attachment verified:
Resubmission result:
Outstanding blockers:
```

Do not mark an item passed from source inspection alone. Keep missing evidence explicitly pending.
Beta approval, production approval and public App Store availability are separate states.
