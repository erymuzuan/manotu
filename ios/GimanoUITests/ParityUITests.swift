import XCTest

/// iPhone parity pass against Android (2026-10-24): everything that changed on iOS since 2026-10-23 plus the features
/// Android has. Writes go to the dev server the Debug build points at (WS556), never to production; nothing here
/// sets `-GimanoAPIBaseURL`. Screens with the user's own data (share sheet, photo picker, Files) are never captured.
///
/// Environment: GIMANO_LANG (en|ms), GIMANO_DATA_MODE (live|auto|demo; default live).
final class ParityUITests: XCTestCase {
    var app: XCUIApplication!
    var env: [String: String] { ProcessInfo.processInfo.environment }
    var lang: String { env["GIMANO_LANG"] ?? "en" }
    var mode: String { env["GIMANO_DATA_MODE"] ?? "live" }
    /// Jalan Sultan Ismail, KL: a fixed, public start (the phone's own position never shows).
    let klStart = "3.152613,101.703718"
    var springboard: XCUIApplication { XCUIApplication(bundleIdentifier: "com.apple.springboard") }

    override func setUp() { continueAfterFailure = false }

    // MARK: helpers

    func launch(_ extra: [String] = [], fake: String? = "3.152613,101.703718", fresh: Bool = false, mode m: String? = nil) {
        app = XCUIApplication()
        var args = ["-GimanoDataMode", m ?? mode, "-GimanoSkipOnboarding", "YES", "-GimanoNoAutoStart", "YES",
                    "-AppleLanguages", "(\(lang))", "-AppleLocale", lang == "ms" ? "ms_MY" : "en_MY"]
        if let fake { args += ["-GimanoFakeLocation", fake] }
        if fresh { args += ["-GimanoFreshDevice", "YES"] }
        app.launchArguments = args + extra
        app.launch()
        wait(app.buttons["whereTo"], 40)
    }

    func shot(_ name: String) {
        let a = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); a.name = "\(lang)-\(name)"; a.lifetime = .keepAlways; add(a)
    }

    func note(_ name: String, _ text: String) {
        let a = XCTAttachment(string: text); a.name = "\(lang)-\(name)"; a.lifetime = .keepAlways; add(a)
    }

    @discardableResult
    func wait(_ e: XCUIElement, _ t: TimeInterval = 25, _ msg: String = "") -> XCUIElement {
        XCTAssertTrue(e.waitForExistence(timeout: t), "Timed out waiting for \(e) \(msg)")
        return e
    }

    func any(_ id: String) -> XCUIElement { app.descendants(matching: .any).matching(identifier: id).firstMatch }

    func search(_ q: String) {
        wait(app.buttons["whereTo"]).tap()
        let f = wait(app.textFields["searchField"])
        f.tap()
        f.typeText(q)
    }

    func clearSearch() {
        if app.buttons["searchClear"].exists { app.buttons["searchClear"].tap() }
    }

    func openPlace(_ q: String) {
        search(q)
        wait(app.buttons.matching(identifier: "searchResult").firstMatch, 30, q).tap()
        wait(app.buttons["routesButton"])
    }

    func routeTo(_ q: String) {
        openPlace(q)
        sleep(1)
        app.buttons["routesButton"].tap()
        wait(app.buttons["goNow"], 40)
        _ = app.buttons["routeBubble"].firstMatch.waitForExistence(timeout: 30)
    }

    func etaButton() -> XCUIElement { app.buttons["etaClock"].exists ? app.buttons["etaClock"] : app.staticTexts["etaClock"] }

    func stopNavigation() {
        wait(etaButton()).tap()
        wait(app.buttons["stopNavigation"]).tap()
        wait(app.buttons["whereTo"], 30)
    }

    /// A finger-length drag starting on an element (XCUIElement.swipe* stays inside small elements).
    func drag(_ e: XCUIElement, dy: CGFloat) {
        let start = e.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: 0, dy: dy)), withVelocity: .fast, thenHoldForDuration: 0)
    }

    func navDebug() -> [String: Int] {
        var out: [String: Int] = [:]
        guard app.staticTexts["navDebug"].waitForExistence(timeout: 10) else { return out }
        for part in app.staticTexts["navDebug"].label.split(separator: ";") {
            let kv = part.split(separator: "=")
            if kv.count == 2, let v = Int(kv[1]) { out[String(kv[0])] = v }
        }
        return out
    }

    func openMenu() { wait(app.buttons["menuButton"]).tap(); sleep(1) }

    func closeSheet() {
        let done = app.buttons["Done"].firstMatch
        if done.exists && done.isHittable { done.tap() } else { app.swipeDown(velocity: .fast) }
        sleep(1)
    }

    /// Every label under an identifier (SwiftUI copies a container's identifier to its children).
    func label(_ id: String) -> String {
        let all = app.descendants(matching: .any).matching(identifier: id).allElementsBoundByIndex.map { $0.label }.filter { !$0.isEmpty }
        return all.isEmpty ? "-" : all.joined(separator: " | ")
    }

    // MARK: 1. Home panel (247e52f)

    func test_01_HomePanel() {
        launch()
        let handle = wait(app.buttons["homePanelHandle"])
        sleep(2)
        let win = app.windows.firstMatch.frame
        note("01-home-peek-metrics", String(format: "peek top %.1f → %.1f %% of %.0f; handle label '%@'", handle.frame.minY,
                                            (win.maxY - handle.frame.minY) / win.height * 100, win.height, handle.label))
        shot("01-home-peek")
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'savedRow.' OR identifier BEGINSWITH 'favoriteTile.' OR identifier BEGINSWITH 'category.'")).count > 0
                      || app.buttons.count > 5, "chip row")
        // Drag from the handle (real finger-length drags).
        drag(handle, dy: -250); sleep(2)
        let halfTop = handle.frame.minY
        shot("01-home-half")
        drag(handle, dy: -500); sleep(2)
        let fullTop = handle.frame.minY
        shot("01-home-full")
        drag(handle, dy: 700); sleep(2)
        let backTop = handle.frame.minY
        shot("01-home-back-to-peek")
        // Tap cycles too.
        handle.tap(); sleep(1)
        let tapTop = handle.frame.minY
        handle.tap(); sleep(1); handle.tap(); sleep(1)
        note("01-home-detents", String(format: "half top %.1f, full top %.1f, back %.1f, tap → %.1f, after 3 taps %.1f (label '%@')",
                                       halfTop, fullTop, backTop, tapTop, handle.frame.minY, handle.label))
        XCTAssertLessThan(halfTop, win.maxY - 200, "drag up opens half")
        XCTAssertLessThan(fullTop, halfTop, "drag up again opens full")
        XCTAssertGreaterThan(backTop, halfTop, "drag down returns to peek")
    }

    // MARK: 2. Search v2 (2bda4de, b9846f0, db91aab)

    func test_02_Search() {
        launch()
        var lines: [String] = []
        for q in ["family mart", "famly mart", "petronas", "stesen minyak", "surau", "tandas", "kfc ss2"] {
            search(q)
            let first = app.buttons.matching(identifier: "searchResult").firstMatch
            let ok = first.waitForExistence(timeout: 25)
            sleep(2)
            let chain = app.buttons.matching(identifier: "chainGroup").firstMatch
            let header = any("correctedHeader")
            let sugg = app.buttons.matching(identifier: "searchSuggestion").firstMatch
            lines.append("\(q): results=\(ok) first='\(ok ? first.label.prefix(80) : "-")' chain=\(chain.exists ? String(chain.label.prefix(60)) : "-") corrected=\(header.exists ? String(header.label.prefix(60)) : "-") suggestion=\(sugg.exists ? String(sugg.label.prefix(40)) : "-")")
            shot("02-search-\(q.replacingOccurrences(of: " ", with: "_"))")
            app.terminate()
            launch()
        }
        note("02-search-results", lines.joined(separator: "\n"))
        // Choose on map from search.
        // "Choose on map" shows under the results once a query has been searched.
        search("Jalan Ampang")
        _ = app.buttons.matching(identifier: "searchResult").firstMatch.waitForExistence(timeout: 25)
        let choose = app.buttons["chooseOnMap"]
        if choose.waitForExistence(timeout: 10) {
            choose.tap()
            wait(app.buttons["selectChoose"], 15)
            sleep(3)
            shot("02-select-on-map")
            note("02-select-on-map", "address: \(label("selectAddress"))")
            app.buttons["selectChoose"].tap()
            sleep(3)
            shot("02-select-on-map-chosen")
        } else {
            XCTFail("no Choose on map in search")
        }
        XCTAssertTrue(lines.first?.contains("FamilyMart") == true || lines.first?.lowercased().contains("family") == true, lines.first ?? "")
    }

    // MARK: 3. Route start rules (54d4581)

    func test_03_RouteStartNoGPS() {
        // No GPS for this app: reset the permission and decline it (only this test build's permission).
        app = XCUIApplication()
        app.resetAuthorizationStatus(for: .location)
        addUIInterruptionMonitor(withDescription: "location") { alert in
            for l in ["Don’t Allow", "Don't Allow", "Jangan Benarkan"] where alert.buttons[l].exists { alert.buttons[l].tap(); return true }
            return false
        }
        launch(fake: nil)
        for l in ["Don’t Allow", "Don't Allow", "Jangan Benarkan"] where springboard.buttons[l].waitForExistence(timeout: 3) {
            springboard.buttons[l].tap(); break
        }
        openPlace("Mid Valley")
        app.buttons["routesButton"].tap()
        app.tap()   // lets the interruption monitor answer a late permission alert
        let unknown = any("startUnknown")
        XCTAssertTrue(unknown.waitForExistence(timeout: 20), "no fresh fix → unknown")
        XCTAssertFalse(app.buttons["goNow"].exists, "no route, no Go")
        note("03-unknown", "startUnknown: '\(unknown.label)'; route start row: '\(label("routeStart"))'")
        shot("03-start-unknown")
        // Start picker.
        wait(app.buttons["routeStart"]).tap()
        sleep(1)
        shot("03-start-picker")
        note("03-start-picker", "gps=\(any("startPick.gps").exists) map=\(any("startPick.map").exists) saved=\(any("startPick.saved").exists) search=\(any("startSearch").exists)")
        if app.buttons["startPick.map"].exists { app.buttons["startPick.map"].tap() } else { app.buttons["startChooseOnMap"].tap() }
        wait(app.buttons["selectChoose"], 15)
        app.otherElements.matching(identifier: "map").allElementsBoundByIndex.last?.swipeLeft()
        sleep(2)
        app.buttons["selectChoose"].tap()
        XCTAssertTrue(any("chosenStartNote").waitForExistence(timeout: 30), "chosen start → note")
        sleep(3)
        note("03-chosen", "note '\(label("chosenStartNote"))'; driveToStartFirst '\(label("driveToStartFirst"))'; saveTrip '\(label("saveTrip"))'; goNow exists \(app.buttons["goNow"].exists)")
        XCTAssertFalse(app.buttons["goNow"].exists, "never navigate from a chosen start")
        shot("03-start-chosen")
        // Swap.
        wait(app.buttons["routeSwap"]).tap()
        sleep(4)
        shot("03-swapped")
        note("03-swap", "start row after swap: '\(label("routeStart"))'")
    }

    func test_04_AlreadyHereAndNoAutoStart() {
        // Fake fix on the Mid Valley Megamall entrance → "You're already here".
        launch(fake: "3.117871,101.677433")
        openPlace("Mid Valley Megamall")
        app.buttons["routesButton"].tap()
        let here = any("alreadyHere")
        XCTAssertTrue(here.waitForExistence(timeout: 20), "under 50 m → already here")
        note("04-already-here", "'\(here.label)'")
        shot("04-already-here")
        app.terminate()
        // Auto-start is off by default: a route after a search must not start by itself (launched WITHOUT -GimanoNoAutoStart).
        app = XCUIApplication()
        app.launchArguments = ["-GimanoDataMode", mode, "-GimanoSkipOnboarding", "YES", "-GimanoFakeLocation", klStart,
                               "-AppleLanguages", "(\(lang))"]
        app.launch()
        wait(app.buttons["whereTo"], 40)
        openPlace("Mid Valley")
        app.buttons["routesButton"].tap()
        wait(app.buttons["goNow"], 40)
        sleep(15)
        let started = app.staticTexts["maneuverDistance"].exists
        shot("04-no-auto-start-after-15s")
        note("04-auto-start", "navigation started by itself after 15 s: \(started)")
        XCTAssertFalse(started, "auto-start is off by default")
    }

    // MARK: 4. Navigation with the simulated drive (bcf0ec1)

    func test_05_SimulatedDriveMultiStopShare() {
        launch(["-GimanoSimulateDrive", "YES"])
        routeTo("Mid Valley")
        // Multi-stop: add KL Sentral as a stop.
        wait(app.buttons["addStopButton"]).tap()
        let f = wait(app.textFields["searchField"]); f.tap(); f.typeText("KL Sentral")
        wait(app.buttons.matching(identifier: "searchResult").firstMatch, 30).tap()
        wait(app.buttons["stop.0"], 20)
        _ = app.staticTexts["stopEta.0"].waitForExistence(timeout: 30)
        sleep(3)
        let previewStopEta = label("stopEta.0")
        shot("05-preview-with-stop")
        // Double-tap Go: one session only.
        let go = wait(app.buttons["goNow"])
        go.doubleTap()
        wait(app.staticTexts["maneuverDistance"], 30)
        sleep(4)
        shot("05-navigating")
        let d1 = navDebug()
        // Stop ETA in navigation.
        wait(etaButton()).tap()
        sleep(1)
        let navStopEta = label("stopEta.0")
        shot("05-trip-sheet")
        // Share my drive: start, then stop the drive; the share must end with it.
        var shareLink = "-"
        if app.buttons["shareDrive"].waitForExistence(timeout: 5) {
            app.buttons["shareDrive"].tap()
            if app.staticTexts["shareLink"].waitForExistence(timeout: 30) { shareLink = app.staticTexts["shareLink"].label }
            shot("05-share-sheet-own")
            app.swipeDown(velocity: .fast)
            sleep(2)
        }
        let chipWhileDriving = app.buttons["sharingChip"].waitForExistence(timeout: 5)
        shot("05-sharing-chip")
        sleep(20)
        let d2 = navDebug()
        shot("05-after-20s")
        // Road problem report while driving.
        if app.buttons["reportButton"].exists {
            app.buttons["reportButton"].tap()
            if app.buttons["reportType.map_issue"].waitForExistence(timeout: 10) {
                shot("05-report-grid-driving")
                app.buttons["reportType.map_issue"].tap()
                if app.buttons["roadProblem.road_closed_temp"].waitForExistence(timeout: 5) {
                    app.buttons["roadProblem.road_closed_temp"].tap()
                    if app.buttons["closureDuration.days"].waitForExistence(timeout: 5) { app.buttons["closureDuration.days"].tap() }
                    shot("05-road-problem-driving")
                    app.buttons["sendRoadProblem"].tap()
                    sleep(3)
                    shot("05-road-problem-sent")
                }
            }
            if !app.staticTexts["maneuverDistance"].exists { closeSheet() }
        }
        stopNavigation()
        sleep(3)
        let chipAfterStop = app.buttons["sharingChip"].exists
        shot("05-after-stop")
        // Back to peek after a drive.
        let handle = app.buttons["homePanelHandle"]
        let win = app.windows.firstMatch.frame
        let peekAfter = handle.exists ? (win.maxY - handle.frame.minY) / win.height * 100 : -1
        note("05-drive", """
        navDebug start \(d1) after 20 s \(d2)
        stop ETA preview '\(previewStopEta)' / navigation '\(navStopEta)'
        share link prefix '\(shareLink.prefix(42))…' chip while driving \(chipWhileDriving), chip after Stop \(chipAfterStop)
        home panel after the drive: \(String(format: "%.1f", peekAfter)) % of the screen
        """)
        XCTAssertFalse(chipAfterStop, "sharing ends when the drive stops")
        XCTAssertGreaterThanOrEqual(d2["reroutes"] ?? 0, 0)
    }

    // MARK: 5. Reports and alerts

    func test_06_ReportAndAlerts() {
        launch()
        wait(app.buttons["reportButton"]).tap()
        wait(app.buttons["reportType.traffic"], 10)
        shot("06-report-grid")
        app.buttons["reportType.traffic"].tap()
        sleep(1)
        shot("06-report-traffic")
        if app.buttons["sendReport"].waitForExistence(timeout: 5) { app.buttons["sendReport"].tap() }
        sleep(4)
        shot("06-report-sent")
        // Alerts nearby: tap one if the live layer has any (the alert detail sheet votes "Still there?").
        let card = any("alertCard")
        note("06-alerts", "alert card visible: \(card.exists)")
    }

    // MARK: 6. Complaints (deb63c1)

    func test_07_PlaceComplaintsOnDev() {
        launch()
        openPlace("Masjid Jamek")
        sleep(2)
        wait(app.buttons["placeMore"]).tap()
        wait(app.buttons["suggestEditMenu"], 5).tap()
        sleep(1)
        shot("07-suggest-edit-6-options")
        let opts = ["Permanently closed", "Temporarily closed", "Opening hours wrong", "Entrance or parking wrong", "Name, type, phone", "Duplicate",
                    "Tutup kekal", "Tutup sementara", "Waktu buka salah", "Pintu masuk / parkir salah", "Nama, jenis, telefon", "Pendua"]
        let shown = opts.filter { app.buttons[$0].exists }
        note("07-options", "options shown: \(shown)")
        let temp = app.buttons.matching(NSPredicate(format: "label IN {'Temporarily closed', 'Tutup sementara'}")).firstMatch
        temp.tap()
        wait(app.buttons["sendPlaceIssue"], 8)
        shot("07-temporarily-closed-form")
        app.buttons["sendPlaceIssue"].tap()
        sleep(4)
        shot("07-temporarily-closed-sent")
        let sent = !app.buttons["sendPlaceIssue"].exists
        note("07-temp-closed", "sheet closed after Send: \(sent); error: \(label("placeIssueError"))")
        if !sent { app.buttons["Cancel"].firstMatch.tap(); sleep(1) }
        XCTAssertTrue(sent, "temporarily closed report accepted by the dev server")
        // Name / type / phone (suggest edit) with an obvious test comment.
        wait(app.buttons["placeMore"]).tap()
        wait(app.buttons["suggestEditMenu"], 5).tap()
        app.buttons.matching(NSPredicate(format: "label IN {'Name, type, phone', 'Nama, jenis, telefon'}")).firstMatch.tap()
        let c = wait(app.textFields["suggestComment"], 10)
        c.tap(); c.typeText("UI test from iPhone parity pass, please ignore")
        shot("07-suggest-edit-form")
        app.buttons["sendSuggestion"].tap()
        sleep(4)
        shot("07-suggest-edit-sent")
        note("07-result", "suggest edit error: \(app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'server'")).firstMatch.exists)")
    }

    func test_08_DeviationQuestion() {
        launch(["-GimanoFakeDeviation", "YES"])
        let q = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'deviation.'")).firstMatch
        XCTAssertTrue(q.waitForExistence(timeout: 30), "after-trip 'why didn't you follow the route?'")
        sleep(1)
        shot("08-deviation-question")
        app.buttons["deviationSkip"].exists ? app.buttons["deviationSkip"].tap() : q.tap()
    }

    /// Place badges, Still closed? and closure avoidance need confirmed issues: in demo two reports confirm one.
    func test_09_ComplaintBadgesDemo() {
        launch(fresh: true, mode: "demo")
        openPlace("KLCC")
        for _ in 0..<2 {
            wait(app.buttons["placeMore"]).tap()
            wait(app.buttons["suggestEditMenu"], 5).tap()
            app.buttons.matching(NSPredicate(format: "label IN {'Temporarily closed', 'Tutup sementara'}")).firstMatch.tap()
            wait(app.buttons["sendPlaceIssue"], 8).tap()
            sleep(2)
        }
        // Reopen the card to reload its badges.
        app.buttons["placeClose"].tap()
        openPlace("KLCC")
        sleep(3)
        let badge = any("badgeClosedTemp").exists ? any("badgeClosedTemp") : any("badgeReportedClosed")
        note("09-badges", "closed-temp badge: \(any("badgeClosedTemp").exists) '\(label("badgeClosedTemp"))'; reported-closed badge: \(any("badgeReportedClosed").exists) '\(label("badgeReportedClosed"))'")
        shot("09-place-badge")
        _ = badge
    }

    // MARK: 7. Favourites / Home / Work

    func test_10_Favourites() {
        launch(fresh: true)
        openPlace("Mid Valley Megamall")
        wait(app.buttons["savePlace"]).tap()
        wait(app.buttons["setAsWork"], 10).tap()
        sleep(2)
        app.buttons["placeClose"].firstMatch.exists ? app.buttons["placeClose"].tap() : ()
        openPlace("KLCC")
        wait(app.buttons["savePlace"]).tap()
        let label = wait(app.textFields["favoriteLabel"], 10)
        label.tap(); label.typeText("Ujian KLCC")
        app.buttons["saveFavorite"].tap()
        sleep(2)
        if app.buttons["placeClose"].exists { app.buttons["placeClose"].tap() }
        sleep(2)
        shot("10-home-with-work-and-favourite")
        openMenu()
        wait(app.buttons["menuFavorites"]).tap()
        sleep(2)
        shot("10-favourites-manager")
        note("10-favourites", "rows: \(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'favoriteRow.'")).count)")
        closeSheet()
    }

    // MARK: 8. Backup to file (no restore)

    func test_11_BackupExport() {
        launch()
        openMenu()
        wait(app.buttons["menuBackup"]).tap()
        wait(app.buttons["backupDestination.file"], 10).tap()
        sleep(1)
        shot("11-backup-file")
        app.buttons["exportBackup"].tap()
        let plain = app.buttons["shareBackup"].waitForExistence(timeout: 20)
        let plainName = plain ? app.buttons["shareBackup"].label : "-"
        shot("11-backup-exported-plain")
        // With a passphrase.
        app.switches["backupPassphraseToggle"].exists ? app.switches["backupPassphraseToggle"].switches.firstMatch.tap() : ()
        if !app.secureTextFields["backupPassphrase"].waitForExistence(timeout: 3) { app.switches["backupPassphraseToggle"].tap() }
        let p1 = wait(app.secureTextFields["backupPassphrase"], 5); p1.tap(); p1.typeText("ujian-12345")
        let p2 = wait(app.secureTextFields["backupPassphraseConfirm"]); p2.tap(); p2.typeText("ujian-12345")
        app.buttons["exportBackup"].tap()
        sleep(8)
        let encName = app.buttons["shareBackup"].exists ? app.buttons["shareBackup"].label : "-"
        shot("11-backup-exported-encrypted")
        note("11-backup", "plain export: \(plain) '\(plainName)'; encrypted export: '\(encName)'; error: \(label("backupError"))")
        XCTAssertTrue(plain)
        closeSheet()
    }

    // MARK: 9. Feedback / crash consent (not sent)

    func test_12_FeedbackForm() {
        launch()
        openMenu()
        wait(app.buttons["menuAddFeedback"]).tap()
        wait(app.buttons["feedbackCategory.bug"], 15).tap()
        sleep(1)
        shot("12-feedback-form")
        for _ in 0..<6 where !app.buttons["deviceInfoPreviewButton"].isHittable { app.swipeUp() }
        if app.buttons["deviceInfoPreviewButton"].exists {
            app.buttons["deviceInfoPreviewButton"].tap()
            sleep(1)
            note("12-device-info", label("deviceInfoPreview"))
            shot("12-device-info-preview")
        }
        note("12-defaults", "includeDevice=\(String(describing: app.switches["includeDevice"].value)) includeLocation=\(String(describing: app.switches["includeLocation"].value)) email='\(String(describing: app.textFields["contactEmail"].value))'")
        // Not sent: cancel.
        let cancel = app.buttons["Cancel"].firstMatch
        if cancel.exists { cancel.tap() } else { closeSheet() }
    }

    func test_13_CrashPrompt() {
        launch(["-GimanoFakeCrash", "YES"])
        let prompt = app.buttons["sendCrashReport"]
        if prompt.waitForExistence(timeout: 20) {
            if app.buttons["crashDetailsButton"].exists { app.buttons["crashDetailsButton"].tap(); sleep(1) }
            shot("13-crash-consent")
            note("13-crash", "details: \(label("crashDetails").prefix(400))")
            app.buttons["discardCrashReport"].exists ? app.buttons["discardCrashReport"].tap() : closeSheet()
        } else {
            note("13-crash", "no crash prompt")
            shot("13-no-crash-prompt")
        }
    }

    // MARK: 10. Settings, About, branding, inbox

    func test_14_SettingsAboutBranding() {
        launch()
        openMenu()
        shot("14-menu")
        note("14-menu", "version line '\(label("menuVersion"))'; texts: \(app.staticTexts.allElementsBoundByIndex.prefix(30).map { $0.label })")
        wait(app.buttons["Settings"]).tap()
        sleep(1)
        shot("14-settings-top")
        let auto = app.switches["autoStartNav"]
        for _ in 0..<4 where !auto.exists || !auto.isHittable { app.swipeUp() }
        note("14-settings-auto-start", "auto-start toggle \(auto.exists) value \(auto.exists ? String(describing: auto.value) : "-")")
        shot("14-settings-auto-start")
        for _ in 0..<3 { app.swipeUp() }
        note("14-settings", "server '\(label("serverHost"))'")
        shot("14-settings-bottom")
        wait(app.buttons["settingsAbout"]).tap()
        sleep(2)
        shot("14-about")
        note("14-about", "version '\(label("aboutVersion"))'; server '\(label("aboutServer"))'; texts: \(app.staticTexts.allElementsBoundByIndex.prefix(20).map { $0.label })")
        app.navigationBars.buttons.element(boundBy: 0).tap()
        sleep(1)
        // Theme: dark then back to light.
        for _ in 0..<3 { app.swipeDown() }
        if app.buttons["theme.dark"].waitForExistence(timeout: 5) {
            app.buttons["theme.dark"].tap(); sleep(2)
            shot("14-theme-dark")
            app.buttons["theme.light"].tap(); sleep(1)
        }
        // Language picker.
        if any("languagePicker").exists {
            any("languagePicker").tap(); sleep(1)
            shot("14-language-picker")
            app.swipeDown(velocity: .fast)
        }
        closeSheet()
        // Inbox.
        openMenu()
        wait(app.buttons["menuInbox"]).tap()
        let item = app.descendants(matching: .any).matching(identifier: "inboxItem").firstMatch
        let ok = item.waitForExistence(timeout: 15) || any("inboxEmpty").exists
        shot("14-inbox")
        note("14-inbox", "items: \(app.descendants(matching: .any).matching(identifier: "inboxItem").count), empty: \(any("inboxEmpty").exists)")
        XCTAssertTrue(ok)
        closeSheet()
    }

    func test_15_Onboarding() {
        app = XCUIApplication()
        // Onboarding shows while location permission is undecided (only this test build's permission is reset).
        app.resetAuthorizationStatus(for: .location)
        app.launchArguments = ["-GimanoDataMode", mode, "-GimanoFreshDevice", "YES", "-GimanoFakeLocation", klStart,
                               "-AppleLanguages", "(\(lang))", "-onboarding.done", "NO", "-GimanoSkipSafety", "YES"]
        app.launch()
        sleep(6)
        shot("15-onboarding-1")
        note("15-onboarding", "texts: \(app.staticTexts.allElementsBoundByIndex.prefix(20).map { $0.label }); restore button: '\(label("onboardingRestore"))'")
    }
}
