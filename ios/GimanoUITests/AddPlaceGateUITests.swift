import XCTest

/// "Add a place with an AI gate" in demo mode (the demo check reacts to keywords; nothing reaches a server or a model):
/// A1 → A3 → A4, B1, B3 → C1, B4, B5, C3, C2. Screenshots are attached to the test result.
final class AddPlaceGateUITests: XCTestCase {
    var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = [
            "-GimanoDataMode", "demo",
            "-GimanoFreshDevice", "YES",
            "-GimanoSkipOnboarding", "YES",
            "-GimanoAddPlaceIntroSeen", "NO",   // show A1 (the argument domain wins over the skip above)
            "-GimanoFakeLocation", "3.152613,101.703718",
            "-GimanoNoAutoStart", "YES",
            "-AppleLanguages", ProcessInfo.processInfo.environment["GIMANO_LANG"] ?? "(en)",
        ]
        app.launch()
        XCTAssertTrue(app.buttons["whereTo"].waitForExistence(timeout: 30))
    }

    func shot(_ name: String) {
        let a = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        a.name = name
        a.lifetime = .keepAlways
        add(a)
        if let dir = ProcessInfo.processInfo.environment["GIMANO_SHOTS_DIR"] {
            try? XCUIScreen.main.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(name).png"))
        }
    }

    @discardableResult
    func wait(_ e: XCUIElement, _ t: TimeInterval = 20) -> XCUIElement {
        XCTAssertTrue(e.waitForExistence(timeout: t), "Timed out waiting for \(e)")
        return e
    }

    func goHome() {
        for _ in 0..<4 where !app.buttons["whereTo"].isHittable {
            let back = app.buttons["Back"].firstMatch
            if back.exists { back.tap() } else { break }
        }
    }

    func element(_ id: String) -> XCUIElement { app.descendants(matching: .any)[id].firstMatch }

    /// Search → "Add a place" → pin → name → visibility → Share with everyone.
    func share(_ name: String, description: String? = nil) {
        sleep(1)
        goHome()
        wait(app.buttons["whereTo"]).tap()
        let f = wait(app.textFields["searchField"])
        f.tap()
        f.typeText("qwxzzy nothing here")
        wait(app.buttons["addPlaceFromSearch"]).tap()
        wait(app.buttons["pinNext"]).tap()
        let n = wait(app.textFields["placeName"])
        n.tap()
        n.typeText(name)
        if let description {
            let d = app.textViews["placeDescription"].exists ? app.textViews["placeDescription"] : app.textFields["placeDescription"]
            d.tap(); d.typeText(description)
        }
        for _ in 0..<6 where !app.buttons["detailsNext"].isHittable { app.swipeUp() }
        app.buttons["detailsNext"].tap()
        wait(app.buttons["visibilityPublic"]).tap()
        if app.buttons["communityAgree"].waitForExistence(timeout: 3) { app.buttons["communityAgree"].tap() }
    }

    func test_AddPlaceGate() {
        // A2 → A1 (first shared place) → A3 → A4.
        share("Gerai Nasi Kerabu Mek Na")
        wait(app.buttons["addPlaceIntroDone"])
        shot("A1-intro")
        app.buttons["addPlaceIntroDone"].tap()
        if app.buttons["communityAgree"].waitForExistence(timeout: 3) { app.buttons["communityAgree"].tap() }
        if element("addPlaceChecking").waitForExistence(timeout: 3) { shot("A3-checking") }
        wait(element("resultLive"))
        shot("A4-live")
        app.buttons["resultDone"].tap()
        sleep(2)
        goHome()

        // B1: the same name at the same pin → 409.
        share("Gerai Nasi Kerabu Mek Na")
        wait(element("duplicateSheet"))
        shot("B1-duplicate")
        app.buttons["duplicateSuggestEdit"].tap()
        wait(app.buttons["sendSuggestion"])
        app.buttons["Cancel"].firstMatch.tap()
        app.buttons["addPlaceBack"].tap(); app.buttons["addPlaceBack"].tap(); app.buttons["addPlaceBack"].tap()

        // B3 → C1.
        share("BEST FOREX SIGNAL 100% UNTUNG")
        wait(element("resultNotAccepted"))
        shot("B3-not-accepted-advert")
        app.buttons["resultAppeal"].tap()
        let note = wait(app.textFields["appealNote"].exists ? app.textFields["appealNote"] : app.textViews["appealNote"])
        note.tap(); note.typeText("A real office with a signboard")
        shot("C1-appeal")
        app.buttons["appealSend"].tap()
        sleep(1)

        // B4.
        share("Rumah Mak Teh")
        wait(element("resultAboutPeople"))
        shot("B4-someones-home")
        app.buttons["resultDiscard"].tap()
        sleep(1)

        // B5.
        share("Surau Al-Ikhlas #limit")
        wait(element("resultLimit"))
        shot("B5-limit")
        app.buttons["resultSaveDraft"].tap()
        sleep(1)

        // C3 · C2.
        goHome()
        wait(app.buttons["menuButton"]).tap()
        wait(app.buttons["menuContributions"]).tap()
        wait(app.buttons["contribution.Gerai Nasi Kerabu Mek Na"])
        sleep(1)
        shot("C3-my-places")
        app.buttons["Done"].firstMatch.tap()
        wait(app.buttons["menuButton"]).tap()
        wait(app.buttons["menuInbox"]).tap()
        wait(app.buttons.matching(identifier: "inboxItem").firstMatch)
        shot("C2-inbox")
    }
}
