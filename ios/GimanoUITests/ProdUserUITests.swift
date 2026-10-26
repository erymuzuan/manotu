import XCTest

/// Real-user matrix against the PRODUCTION server, on a Release build (launch arguments are ignored in Release,
/// so this is exactly what a user gets: real GPS, real server, no demo data).
/// Run: uninstall the app first, then
///   xcodebuild test -configuration Release -only-testing:GimanoUITests/ProdUserUITests -destination id=<iPhone>
/// Tests run in name order (01…09); 01 must be the first launch after a fresh install.
final class ProdUserUITests: XCTestCase {
    var app: XCUIApplication!
    var springboard: XCUIApplication { XCUIApplication(bundleIdentifier: "com.apple.springboard") }

    override func setUp() {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_MY"]
        app.launch()
    }

    func shot(_ name: String) {
        let a = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        a.name = name
        a.lifetime = .keepAlways
        add(a)
    }

    func note(_ name: String, _ text: String) {
        let a = XCTAttachment(string: text)
        a.name = name
        a.lifetime = .keepAlways
        add(a)
    }

    @discardableResult
    func wait(_ e: XCUIElement, _ t: TimeInterval = 30, _ msg: String = "") -> XCUIElement {
        XCTAssertTrue(e.waitForExistence(timeout: t), "Timed out waiting for \(e) \(msg)")
        return e
    }

    func allowSystemAlerts(_ timeout: TimeInterval = 3) {
        for label in ["Allow While Using App", "Allow", "OK", "Keep Only While Using"] {
            let b = springboard.buttons[label]
            if b.waitForExistence(timeout: timeout) { b.tap() }
        }
    }

    /// Safety agreement (docs/safety.md §1): shown once, before the location prompt.
    func agreeToSafety(_ timeout: TimeInterval = 3) {
        if app.buttons["safetyAgree"].waitForExistence(timeout: timeout) { app.buttons["safetyAgree"].tap(); sleep(1) }
    }

    func home() {
        agreeToSafety()
        if app.buttons["Continue"].waitForExistence(timeout: 3) { app.buttons["Continue"].tap(); allowSystemAlerts(5) }
        // A previous run may have left navigation running.
        let clock = app.buttons["etaClock"].exists ? app.buttons["etaClock"] : app.staticTexts["etaClock"]
        if clock.waitForExistence(timeout: 3) {
            clock.tap()
            if app.buttons["stopNavigation"].waitForExistence(timeout: 5) { app.buttons["stopNavigation"].tap() }
        }
        wait(app.buttons["whereTo"], 40)
    }

    /// Times one step so slowness is visible in the report.
    func timed<T>(_ label: String, _ body: () -> T) -> T {
        let t0 = Date()
        let r = body()
        note("timing-\(label)", String(format: "%@: %.1f s", label, Date().timeIntervalSince(t0)))
        return r
    }

    func search(_ q: String) -> XCUIElement {
        wait(app.buttons["whereTo"]).tap()
        let f = wait(app.textFields["searchField"])
        f.tap()
        f.typeText(q)
        return timed("search-\(q)") { wait(app.buttons.matching(identifier: "searchResult").firstMatch, 30, "results for \(q)") }
    }

    func backHome() {
        for _ in 0..<5 where !(app.buttons["whereTo"].exists && app.buttons["whereTo"].isHittable) {
            let back = app.buttons["Back"].firstMatch
            if back.exists && back.isHittable { back.tap() } else if app.buttons["Done"].exists { app.buttons["Done"].firstMatch.tap() } else { break }
            sleep(1)
        }
    }

    // MARK: matrix

    func test_01_FirstLaunchAndRegistration() {
        XCTAssertTrue(app.buttons["safetyAgree"].waitForExistence(timeout: 20), "first launch shows the safety agreement first")
        shot("01-safety-agreement")
        app.buttons["safetyAgree"].tap()
        let welcome = app.staticTexts.matching(NSPredicate(format: "label IN {'Welcome to Manotu', 'Welcome to Gimano'}")).firstMatch
        XCTAssertTrue(welcome.waitForExistence(timeout: 20), "first launch shows onboarding")
        shot("01-onboarding")
        app.buttons["Continue"].tap()
        allowSystemAlerts(8)
        wait(app.buttons["whereTo"], 40)
        sleep(4)
        shot("01-home-first-launch")
        wait(app.buttons["menuButton"]).tap()
        wait(app.buttons["Settings"]).tap()
        sleep(2)
        shot("01-settings")
        let server = app.descendants(matching: .any)["serverHost"]
        for _ in 0..<6 where !server.exists { app.swipeUp() }
        wait(server, 10)
        for _ in 0..<4 where !server.isHittable { app.swipeUp() }
        XCTAssertTrue(server.label.contains("gimano-api.bukitbunga.com"), "Release talks to production: \(server.label)")
        let pseudonym = app.descendants(matching: .any)["pseudonym"]
        XCTAssertTrue(pseudonym.waitForExistence(timeout: 20), "registered with the server (pseudonym shown)")
        note("01-registration", "server=\(server.label) pseudonym=\(pseudonym.label)")
        shot("01-settings-prod-server")
        app.buttons["Done"].firstMatch.tap()
    }

    func test_02_SearchPetronas() {
        home()
        let first = search("petronas")
        let count = app.buttons.matching(identifier: "searchResult").count
        note("02-petronas", "results=\(count) first=\(first.label)")
        XCTAssertGreaterThan(count, 0)
        shot("02-search-petronas")
        first.tap()
        wait(app.buttons["routesButton"])
        sleep(2)
        shot("02-petronas-place-card")
        backHome()
    }

    func test_03_RouteCarWithTollAndNavigate() {
        home()
        // "Putrajaya" ranks a KL building first on prod (reported); Genting is a reliable tolled route from KL.
        search("Genting Highlands").tap()
        wait(app.buttons["routesButton"]).tap()
        if app.buttons["mode.car"].waitForExistence(timeout: 10) { app.buttons["mode.car"].tap() }
        let go = timed("route-genting") { wait(app.buttons["goNow"], 60) }
        _ = app.buttons["routeBubble"].firstMatch.waitForExistence(timeout: 30)
        XCTAssertFalse(app.staticTexts["routeError"].exists, "route error: \(app.staticTexts["routeError"].label)")
        let toll = app.buttons["tollBadge"]
        XCTAssertTrue(toll.waitForExistence(timeout: 30), "a KL → Genting car route has a toll fare")
        note("03-toll", toll.exists ? toll.label : "no toll badge")
        shot("03-route-car-toll")
        toll.tap()
        _ = app.staticTexts["tollTotal"].waitForExistence(timeout: 10)
        shot("03-toll-breakdown")
        let grabber = app.buttons["Sheet Grabber"].firstMatch
        if grabber.exists {
            let start = grabber.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            start.press(forDuration: 0.1, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.98)))
        }
        sleep(2)
        wait(go).tap()
        allowSystemAlerts(4)
        // The safety reminder card at the start of the drive (docs/safety.md §2).
        if app.buttons["safetyStart"].waitForExistence(timeout: 5) { shot("03-safety-card"); app.buttons["safetyStart"].tap() }
        let maneuver = wait(app.staticTexts.matching(identifier: "maneuverDistance").firstMatch, 30)
        sleep(4)
        note("03-navigation", "first maneuver: \(maneuver.label)")
        shot("03-navigation-banner")
        // Exits / steps: the upcoming instruction text (e.g. "Exit 1104 ...") is in the banner.
        let banner = app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] 'exit' OR label CONTAINS[c] 'keluar'")).firstMatch
        note("03-exits", banner.exists ? banner.label : "no exit instruction on the first step (stationary phone)")
        allowSystemAlerts(3)
        let clock = app.buttons["etaClock"].exists ? app.buttons["etaClock"] : app.staticTexts["etaClock"]
        wait(clock).tap()
        sleep(1)
        shot("03-trip-sheet")
        wait(app.buttons["stopNavigation"]).tap()
        wait(app.buttons["whereTo"])
    }

    func test_04_ReportAndStillThere() {
        home()
        wait(app.buttons["reportButton"]).tap()
        wait(app.buttons["reportType.hazard"]).tap()
        sleep(1)
        shot("04-report-hazard")
        // The default subtype is picked: Report (or the 3 s auto-send) sends it.
        wait(app.buttons["sendReport"]).tap()
        sleep(4)
        shot("04-report-sent")
        // "Still there?": tap the report on the map (it sits at our position, the centre of the followed map).
        let map = app.otherElements["map"]
        map.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        let card = app.descendants(matching: .any)["alertCard"]
        if card.waitForExistence(timeout: 8) {
            shot("04-still-there-card")
            app.buttons["Still there"].firstMatch.tap()
            sleep(3)
            shot("04-still-there-voted")
            note("04-still-there", "card shown and voted")
        } else {
            shot("04-still-there-not-hit")
            note("04-still-there", "map tap did not hit the report symbol")
        }
    }

    func test_05_FeedbackWithScreenshot() {
        home()
        wait(app.buttons["menuButton"]).tap()
        wait(app.buttons["menuAddFeedback"]).tap()
        wait(app.buttons["feedbackCategory.idea"]).tap()
        let msg = app.textFields["feedbackMessage"].exists ? app.textFields["feedbackMessage"] : app.textViews["feedbackMessage"]
        msg.tap()
        msg.typeText("Real-user test on iPhone 16 (Release build).")
        let shotToggle = app.switches["includeScreenshot"]
        for _ in 0..<4 where !(shotToggle.exists && shotToggle.isHittable) { app.swipeUp() }
        if shotToggle.exists, (shotToggle.value as? String) != "1" { shotToggle.switches.firstMatch.exists ? shotToggle.switches.firstMatch.tap() : shotToggle.tap() }
        let previewButton = app.buttons["deviceInfoPreviewButton"]
        for _ in 0..<4 where !(previewButton.exists && previewButton.isHittable) { app.swipeUp() }
        previewButton.tap()
        let preview = wait(app.staticTexts["deviceInfoPreview"])
        XCTAssertTrue(preview.label.contains("\"locationPrecision\""), preview.label)
        XCTAssertFalse(preview.label.contains("\"lat\""), "no coordinates in the device block")
        note("05-device-block", preview.label)
        shot("05-feedback-device-preview")
        shot("05-feedback-form")
        for _ in 0..<4 where !(app.buttons["sendFeedback"].exists && app.buttons["sendFeedback"].isHittable) { app.swipeUp() }
        app.buttons["sendFeedback"].tap()
        sleep(4)
        wait(app.buttons["menuButton"]).tap()
        wait(app.buttons["menuMyFeedback"]).tap()
        let row = wait(app.descendants(matching: .any)["feedbackRow"].firstMatch, 30)
        note("05-feedback", row.label)
        XCTAssertFalse(row.label.lowercased().contains("waiting to send"), "feedback reached the server: \(row.label)")
        shot("05-my-feedback")
    }

    func test_06_Favourites() {
        home()
        search("KLCC").tap()
        wait(app.buttons["savePlace"]).tap()
        wait(app.buttons["setAsWork"]).tap()
        sleep(1)
        backHome()
        let tile = wait(app.buttons["shortcut.work"], 15)
        shot("06-home-favourites")
        tile.tap()
        timed("route-work") { _ = wait(app.buttons["goNow"], 60) }
        shot("06-route-to-work")
        backHome()
    }

    func test_07_Theme() {
        home()
        wait(app.buttons["menuButton"]).tap()
        wait(app.buttons["Settings"]).tap()
        wait(app.buttons["theme.dark"]).tap()
        sleep(2)
        shot("07-theme-dark-settings")
        app.buttons["Done"].firstMatch.tap()
        sleep(4)
        shot("07-theme-dark-map")
        wait(app.buttons["menuButton"]).tap()
        wait(app.buttons["Settings"]).tap()
        wait(app.buttons["theme.light"]).tap()
        app.buttons["Done"].firstMatch.tap()
    }

    /// Backup → restore through the user's own Google Drive (iCloud needs the CloudKit capability on the
    /// signing team; see README).
    func test_08_BackupRestoreDrive() {
        home()
        wait(app.buttons["menuButton"]).tap()
        wait(app.buttons["menuBackup"]).tap()
        wait(app.buttons["backupDestination.googleDrive"]).tap()
        sleep(1)
        shot("08-backup")
        if app.buttons["Sign in with Google"].exists {
            app.buttons["Sign in with Google"].tap()
            let cont = springboard.buttons["Continue"]
            if cont.waitForExistence(timeout: 10) { cont.tap() }
            let safari = XCUIApplication(bundleIdentifier: "com.apple.SafariViewService")
            for _ in 0..<10 {
                if app.buttons["Sign out"].exists { break }
                guard safari.state == .runningForeground else { sleep(2); continue }
                let web = safari.webViews.firstMatch
                guard web.waitForExistence(timeout: 5) else { break }
                let go = web.buttons.matching(NSPredicate(format: "label IN {'Continue', 'Allow', 'Teruskan', 'Benarkan'}")).firstMatch
                for box in web.checkBoxes.allElementsBoundByIndex where box.isHittable && (box.value as? String) != "1" { box.tap() }
                if go.exists && go.isHittable { go.tap() }
                else if web.staticTexts["Choose an account"].exists { web.links.matching(NSPredicate(format: "label CONTAINS[c] '@gmail.com'")).firstMatch.tap() }
                else { web.swipeUp() }
                sleep(3)
            }
        }
        wait(app.buttons["Sign out"], 40)
        let backUp = app.buttons["backUpNow"]
        for _ in 0..<6 where !(backUp.exists && backUp.isHittable) { app.swipeUp() }
        backUp.tap()
        let done = app.staticTexts.matching(NSPredicate(format: "label == 'Backed up' OR label BEGINSWITH 'Last backup'")).firstMatch
        timed("backup-drive") { _ = wait(done, 90) }
        for _ in 0..<4 where !app.descendants(matching: .any)["backupStatusCard"].isHittable { app.swipeDown() }
        note("08-backup", app.descendants(matching: .any)["backupStatusCard"].label)
        shot("08-backed-up")
        for _ in 0..<4 where !app.buttons.matching(identifier: "remoteBackup").firstMatch.exists { app.swipeUp() }
        wait(app.buttons.matching(identifier: "remoteBackup").firstMatch, 30).tap()
        wait(app.buttons["restoreButton"]).tap()
        timed("restore-drive") { _ = wait(app.staticTexts["backupMessage"], 60) }
        shot("08-restored")
    }

    func test_09_AboutShowsVersion() {
        home()
        wait(app.buttons["menuButton"]).tap()
        let v = wait(app.staticTexts["menuVersion"])
        note("09-menu-version", v.label)
        wait(app.buttons["Settings"]).tap()
        let about = app.buttons["settingsAbout"]
        for _ in 0..<8 where !(about.exists && about.isHittable) { app.swipeUp() }
        about.tap()
        let ver = wait(app.staticTexts["aboutVersion"])
        XCTAssertTrue(ver.label.hasPrefix("0."), ver.label)
        let server = app.descendants(matching: .any).matching(identifier: "aboutServer").firstMatch
        note("09-about", "version=\(ver.label) server=\(server.label)")
        shot("09-about")
        app.swipeUp()
        shot("09-about-platform-components")
    }
}
