import XCTest

/// Round 3: add a place (private / public), reviews with photos.
/// Runs in demo mode until the backend deploys /places, /reviews and /photos (they 404 on WS556 today).
final class Round3UITests: XCTestCase {
    var app: XCUIApplication!

    func launch(fresh: Bool = true) {
        app = XCUIApplication()
        app.launchArguments = [
            "-GimanoDataMode", ProcessInfo.processInfo.environment["GIMANO_DATA_MODE"] ?? "demo",
            "-GimanoFreshDevice", fresh ? "YES" : "NO",
            "-GimanoSkipOnboarding", "YES",
            "-GimanoFakeLocation", "3.152613,101.703718",
            "-GimanoNoAutoStart", "YES",
            "-GimanoTestPhotos", "YES",
            "-AppleLanguages", "(en)",
        ]
        app.launch()
        XCTAssertTrue(app.buttons["whereTo"].waitForExistence(timeout: 30))
    }

    override func setUp() {
        continueAfterFailure = false
        launch()
    }

    func shot(_ name: String) {
        let a = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        a.name = name
        a.lifetime = .keepAlways
        add(a)
    }

    @discardableResult
    func wait(_ e: XCUIElement, _ t: TimeInterval = 20) -> XCUIElement {
        XCTAssertTrue(e.waitForExistence(timeout: t), "Timed out waiting for \(e)")
        return e
    }

    func search(_ q: String) {
        wait(app.buttons["whereTo"]).tap()
        let f = wait(app.textFields["searchField"])
        f.tap()
        f.typeText(q)
    }

    func goHome() {
        for _ in 0..<4 where !app.buttons["whereTo"].isHittable {
            let back = app.buttons["Back"].firstMatch
            if back.exists { back.tap() } else { break }
        }
    }

    func addPlace(name: String, category: String, visibility: String) {
        search("qwxzzy nothing here")
        wait(app.buttons["addPlaceFromSearch"]).tap()
        _ = app.staticTexts.matching(identifier: "pinAddress").firstMatch.waitForExistence(timeout: 10)
        sleep(2)
        shot("add-1-pin-\(visibility)")
        wait(app.buttons["pinNext"]).tap()
        let n = wait(app.textFields["placeName"])
        n.tap()
        n.typeText(name)
        app.buttons["category.\(category)"].tap()
        if app.buttons["addTestPhoto"].exists { app.buttons["addTestPhoto"].tap() }
        let hours = app.switches["hoursToggle"]
        if hours.exists { hours.switches.firstMatch.exists ? hours.switches.firstMatch.tap() : hours.tap() }
        sleep(1)
        shot("add-2-details-\(visibility)")
        for _ in 0..<6 where !app.buttons["detailsNext"].isHittable { app.swipeUp() }
        app.buttons["detailsNext"].tap()
        wait(app.buttons[visibility])
        shot("add-3-visibility")
        app.buttons[visibility].tap()
    }

    func test_l_PrivatePlaceVisibleOnlyToOwner() {
        addPlace(name: "Gerai Pak Abu UITest", category: "restaurant", visibility: "visibilityPrivate")
        wait(app.descendants(matching: .any)["badgePrivate"], 30)
        sleep(1)
        shot("l-private-place-card")
        goHome()
        search("Pak Abu UITest")
        wait(app.buttons["privateResult"])
        XCTAssertFalse(app.buttons["searchResult"].exists, "a private place must never come from the server")
        shot("l-private-in-search")
        // Another user (fresh device): the place doesn't exist anywhere.
        app.terminate()
        launch(fresh: true)
        search("Pak Abu UITest")
        wait(app.buttons["addPlaceFromSearch"])
        XCTAssertFalse(app.buttons["privateResult"].exists)
        shot("l-other-user-cannot-see")
    }

    func test_m_PublicPlace() {
        // Unique per run: the live server rejects a similar name within 100 m (409).
        // (trigram similarity >= 0.6 within 100 m), so use an unrelated random name.
        let name = "Warung " + String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(10))
        addPlace(name: name, category: "convenience", visibility: "visibilityPublic")
        // A4 "It's on the map" (the AI check passed): Done opens the place card.
        if app.buttons["resultDone"].waitForExistence(timeout: 15) {
            shot("m-result-live")
            app.buttons["resultDone"].tap()
        }
        wait(app.descendants(matching: .any)["badgeCommunity"], 30)
        XCTAssertTrue(app.descendants(matching: .any)["badgeUnverified"].exists)
        sleep(1)
        shot("m-public-place-card")
        // The owner can't verify their own place; other drivers do (3 confirmations).
        XCTAssertFalse(app.buttons["verifyYes"].exists, "owners must not see the verify buttons")
        wait(app.descendants(matching: .any)["awaitingVerification"])
        shot("m-awaiting-verification")
        goHome()
        wait(app.buttons["menuButton"]).tap()
        wait(app.buttons["menuContributions"]).tap()
        wait(app.buttons["contribution.\(name)"])
        shot("m-my-contributions")
    }

    func test_n_ReviewWithPhotoIsWebP() {
        search("Suria KLCC")
        wait(app.buttons.matching(identifier: "searchResult").firstMatch).tap()
        wait(app.buttons["routesButton"])
        let write = app.buttons["writeReview"]
        for _ in 0..<6 where !write.isHittable { app.swipeUp() }
        write.tap()
        wait(app.buttons["reviewStar.4"]).tap()
        let t = app.textFields["reviewText"].exists ? app.textFields["reviewText"] : app.textViews["reviewText"]
        t.tap()
        t.typeText("Sedap, parking senang. (UI test)")
        app.buttons["addTestPhoto"].tap()
        wait(app.descendants(matching: .any)["pickedPhoto"])
        shot("n-write-review")
        app.buttons["postReview"].tap()
        let row = wait(app.descendants(matching: .any)["reviewRow"].firstMatch, 30)
        for _ in 0..<4 where !row.isHittable { app.swipeUp() }
        sleep(2)
        shot("n-review-posted")
        wait(app.buttons.matching(identifier: "placePhoto").firstMatch)
        let all = app.buttons.matching(identifier: "placePhoto").allElementsBoundByIndex
        let photo = all.first { $0.isHittable } ?? all[0]
        let url = (photo.value as? String) ?? ""
        XCTAssertTrue(url.hasSuffix(".webp"), "photo URL should end in .webp: \(url)")
        photo.tap()
        wait(app.descendants(matching: .any)["photoViewer"])
        sleep(1)
        shot("n-photo-viewer")
        app.buttons["closeViewer"].tap()
    }
}
