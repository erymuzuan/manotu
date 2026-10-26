# Getting real app screenshots

## iOS simulator (preferred)

Use a simulator you create yourself, so you never disturb other sessions' simulators:

```bash
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
RT=$(xcrun simctl list runtimes | grep -o "com.apple.CoreSimulator.SimRuntime.iOS-[0-9-]*" | tail -1)
SIM=$(xcrun simctl create "FbPost iPhone 17" com.apple.CoreSimulator.SimDeviceType.iPhone-17 "$RT")
```

Drive the app with a **temporary** XCUITest. The simplest way that needs no project-file change is to append a
new `XCTestCase` class to an existing file in `ios/GimanoUITests/` (e.g. `RouteStartUITests.swift`), run it, then
`git checkout` that file. Pattern:

```swift
final class TmpFbShotsUITests: XCTestCase {
    func shot(_ app: XCUIApplication, _ name: String) {
        let a = XCTAttachment(screenshot: app.screenshot()); a.name = name; a.lifetime = .keepAlways; add(a)
    }
    func test_Shots() {
        let app = XCUIApplication()
        app.launchArguments = ["-GimanoDataMode", "demo",        // or "live" for the WS556 dev server
                               "-GimanoSkipOnboarding", "YES", "-GimanoNoAutoStart", "YES",
                               "-GimanoFakeLocation", "3.0787,101.5207",   // a public place, never someone's home
                               "-AppleLanguages", "(ms)"]
        app.launch()
        // navigate by accessibility identifiers (grep the SwiftUI sources for .accessibilityIdentifier)
        shot(app, "01-...")
    }
}
```

Useful identifiers: `whereTo`, `searchField`, `searchResult`, `routesButton`, `routeCard`, `goNow`, `menuButton`,
`menuEvents`, `eventNew`, `eventTemplate.<kind>`, `eventWizardNext`, `eventAddPlace`, `eventPickOnMap`,
`selectChoose`, `eventAddStop.parking`, `eventStopLabel`, `eventStopDone`, `eventDescriptionField`,
`eventAddInfo.<kind>`, `eventShareInvitation`. Existing UI tests (`EventHostUITests`, `RouteStartUITests`) show
working flows.

Driving shots: launch with `-GimanoDriveTo "Name|lat,lng|"`, `-GimanoSimSpeed route`, `-GimanoSimTick 1`
(optionally `-debug.simulationSpeedup 2`) and the app drives the route by itself. Wait for the element you want
(e.g. `tollBanner`, which appears 1 km before a plaza, 500 m below 60 km/h) by polling every 1–2 s, and take two
shots ~2 s apart (banners animate in). Some ids match more than one element: `etaClock` needs `app.buttons["etaClock"]`.
`xcrun simctl status_bar <sim> override --time 9:41` tidies the status bar, but then the app's ETA clock won't
match it; leave the override off if the ETA is visible.

To keep the repo change short: append the test class, run `build-for-testing`, `git checkout` the file at once,
then `test-without-building`.

Run and export:

```bash
xcodebuild test -project ios/Gimano.xcodeproj -scheme Gimano -destination "platform=iOS Simulator,id=$SIM" \
  -derivedDataPath "$SCRATCH/dd" -resultBundlePath "$SCRATCH/shots.xcresult" \
  -only-testing:GimanoUITests/TmpFbShotsUITests/test_Shots
.claude/skills/facebook-post/scripts/export_shots.sh "$SCRATCH/shots.xcresult" "$SCRATCH/shots"
```

`xcodebuild test` can hang waiting for the app to go idle (seen after tapping "Copy link"). Run it in the
background; if it stops making progress, `pkill -INT -f TmpFbShots` and export what was captured: attachments
up to that point are still in the bundle.

## iPhone 16 (`00008140-00154CA90A8B001C`)
Often lent to another session (e.g. the "Facebook" Orca tab). Ask the owner first. Signing uses the individual
team automatically with `-allowProvisioningUpdates`. A fresh install has no location permission: either fake
the location or let the test accept the system prompt. Give it back when done (relaunch whatever app it had in front).

## Samsung S24
`adb exec-out screencap -p > file.png`. The app there runs on real GPS, so the map and "Your location" show the
owner's area: don't post those unless the owner says it is fine. Fine for checking UI, not for marketing images.

## Before using any image
Look at it. Reject it if it shows a real home, a personal chat, a notification from a person, a phone number,
or a status bar with something private. Crop or retake rather than blur.
