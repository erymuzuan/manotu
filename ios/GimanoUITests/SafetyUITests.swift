import XCTest

/// docs/safety.md: agreement before the location prompt, the not-agreed sheet at "Go now", the reminder card with
/// "Don't show again", Settings › Safety, and a (DEBUG fixture) restricted area: map sheet D and Add a place A.
/// Demo data + a fresh device, so it runs anywhere (simulator or a test phone). Screenshots are attached.
final class SafetyUITests: XCTestCase {
    var app: XCUIApplication!
    let start = "3.152613,101.703718"
    var lang: String { ProcessInfo.processInfo.environment["GIMANO_LANG"] ?? "en" }

    override func setUp() { continueAfterFailure = false }

    func launch(_ extra: [String] = [], safety: Bool = true) {
        app = XCUIApplication()
        app.launchArguments = ["-GimanoDataMode", "demo", "-GimanoFreshDevice", "YES", "-GimanoResetSafety", safety ? "YES" : "NO", safety ? "-GimanoSafetyTest" : "-GimanoSkipSafety", "YES",
                               "-GimanoFakeLocation", start, "-GimanoNoAutoStart", "YES", "-onboarding.done", "YES",
                               "-AppleLanguages", "(\(lang))"] + extra
        app.launch()
    }

    func shot(_ name: String) {
        let a = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); a.name = "\(lang)-\(name)"; a.lifetime = .keepAlways; add(a)
    }

    @discardableResult
    func wait(_ e: XCUIElement, _ t: TimeInterval = 20) -> XCUIElement {
        XCTAssertTrue(e.waitForExistence(timeout: t), "Timed out waiting for \(e)")
        return e
    }

    func routeToMidValley() {
        wait(app.buttons["whereTo"], 30).tap()
        let f = wait(app.textFields["searchField"])
        f.tap()
        f.typeText("Mid Valley")
        wait(app.buttons.matching(identifier: "searchResult").firstMatch, 30).tap()
        wait(app.buttons["routesButton"]).tap()
    }

    func test_01_AgreementThenReminder() {
        launch()
        // Fresh device: the agreement comes first.
        wait(app.descendants(matching: .any)["safetyAgreement"], 30)
        XCTAssertTrue(app.buttons["safetyAgree"].exists && app.buttons["safetyNotNow"].exists)
        shot("01-agreement")
        app.buttons["safetyNotNow"].tap()

        // Not agreed: route preview works, Go now opens the sheet.
        routeToMidValley()
        wait(app.buttons["goNow"], 40).tap()
        wait(app.buttons["safetyReadAndAgree"])
        shot("02-not-agreed-sheet")
        app.buttons["safetyReadAndAgree"].tap()
        wait(app.buttons["safetyAgree"]).tap()

        // Agreed → the reminder card over the route preview.
        wait(app.buttons["safetyStart"], 20)
        XCTAssertTrue(app.descendants(matching: .any)["safetyCardSubtitle"].exists)
        shot("03-reminder-card")
        app.buttons["safetyDontShowAgain"].tap()
        app.buttons["safetyStart"].tap()
        wait(app.staticTexts.matching(identifier: "maneuverDistance").firstMatch, 30)
        shot("04-navigating-after-dont-show-again")
        let clock = app.buttons["etaClock"].exists ? app.buttons["etaClock"] : app.staticTexts["etaClock"]
        wait(clock).tap()
        wait(app.buttons["stopNavigation"]).tap()

        // Next drive: no card.
        routeToMidValley()
        wait(app.buttons["goNow"], 40).tap()
        wait(app.staticTexts.matching(identifier: "maneuverDistance").firstMatch, 30)
        XCTAssertFalse(app.buttons["safetyStart"].exists, "no card after Don't show again")
        let clock2 = app.buttons["etaClock"].exists ? app.buttons["etaClock"] : app.staticTexts["etaClock"]
        wait(clock2).tap()
        wait(app.buttons["stopNavigation"]).tap()

        // Settings › Safety: switch it back on.
        wait(app.buttons["menuButton"]).tap()
        wait(app.buttons["menu.settings"]).tap()
        wait(app.buttons["settingsSafety"]).tap()
        wait(app.descendants(matching: .any)["safetyAgreedOn"])
        XCTAssertTrue(app.descendants(matching: .any)["safetyReminderOffDate"].exists)
        shot("05-settings-safety-off")
        let toggle = app.switches["safetyReminderToggle"]
        wait(toggle)
        toggle.switches.firstMatch.exists ? toggle.switches.firstMatch.tap() : toggle.tap()
        sleep(1)
        shot("06-settings-safety-on")
        wait(app.buttons["safetyShowNow"]).tap()
        wait(app.buttons["safetyStart"])
        shot("07-show-now")
    }

    func test_02_RestrictedAreaFixture() {
        // A 400 m test area centred on the start (DEBUG fixture, memory only).
        launch(["-GimanoRestrictedFixture", start], safety: false)
        wait(app.buttons["whereTo"], 30)
        sleep(3)
        shot("10-map-restricted-area")
        // Tap inside the area → sheet D.
        app.otherElements["map"].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.35)).tap()
        if app.buttons["restrictedInfoClose"].waitForExistence(timeout: 5) {
            shot("11-restricted-info")
            app.buttons["restrictedInfoClose"].tap()
        }
        // Long-press inside → Add a place → A.
        app.otherElements["map"].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.35)).press(forDuration: 1.2)
        wait(app.buttons["pinAddPlace"]).tap()
        wait(app.buttons["restrictedMovePin"], 15)
        shot("12-blocked-sheet")
        app.buttons["restrictedSavePrivate"].tap()
        wait(app.textFields["placeName"])
        shot("13-private-only-form")
    }
}
