import XCTest

/// Route start rules (simulator): no fresh fix → "unknown", no route; a chosen start → preview only.
/// Run with location permission revoked for the app.
final class RouteStartUITests: XCTestCase {
    func test_UnknownThenChosenStart() {
        let app = XCUIApplication()
        app.launchArguments = ["-GimanoDataMode", "demo", "-GimanoFreshDevice", "YES", "-GimanoSkipOnboarding", "YES",
                               "-GimanoNoAutoStart", "YES", "-AppleLanguages", "(en)"]
        app.launch()
        XCTAssertTrue(app.buttons["whereTo"].waitForExistence(timeout: 30))
        app.buttons["whereTo"].tap()
        let f = app.textFields["searchField"]
        XCTAssertTrue(f.waitForExistence(timeout: 10)); f.tap(); f.typeText("KLCC")
        let r = app.buttons.matching(identifier: "searchResult").firstMatch
        XCTAssertTrue(r.waitForExistence(timeout: 20)); r.tap()
        XCTAssertTrue(app.buttons["routesButton"].waitForExistence(timeout: 10)); app.buttons["routesButton"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["startUnknown"].waitForExistence(timeout: 15), "no fresh fix → unknown")
        XCTAssertFalse(app.buttons["goNow"].exists, "no route, no Go")
        let a = XCTAttachment(screenshot: app.screenshot()); a.name = "start-unknown"; a.lifetime = .keepAlways; add(a)
        app.buttons["startChooseOnMap"].tap()
        XCTAssertTrue(app.buttons["selectChoose"].waitForExistence(timeout: 10))
        app.otherElements.matching(identifier: "map").allElementsBoundByIndex.last?.swipeLeft()
        sleep(2)
        app.buttons["selectChoose"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["chosenStartNote"].waitForExistence(timeout: 30), "chosen start → amber note")
        XCTAssertTrue(app.buttons["driveToStartFirst"].exists && app.buttons["saveTrip"].exists)
        XCTAssertFalse(app.buttons["goNow"].exists, "never navigate from a chosen start")
        let b = XCTAttachment(screenshot: app.screenshot()); b.name = "start-chosen"; b.lifetime = .keepAlways; add(b)
    }

    /// Route options before a drive (live dev server): a long trip opens the route list, a tap compares with the fastest.
    /// On a phone the real GPS fix is used; on the simulator the fake location is PJ Section 17.
    func test_RouteOptionsList() {
        let app = XCUIApplication()
        var args = ["-GimanoDataMode", "live", "-GimanoSkipOnboarding", "YES", "-GimanoNoAutoStart", "YES", "-AppleLanguages", "(en)"]
        #if targetEnvironment(simulator)
        args += ["-GimanoFakeLocation", "3.1170,101.6290"]
        #endif
        app.launchArguments = args
        app.launch()
        func shot(_ name: String) { let a = XCTAttachment(screenshot: app.screenshot()); a.name = name; a.lifetime = .keepAlways; add(a) }
        XCTAssertTrue(app.buttons["whereTo"].waitForExistence(timeout: 40))
        app.buttons["whereTo"].tap()
        let f = app.textFields["searchField"]
        XCTAssertTrue(f.waitForExistence(timeout: 10)); f.tap(); f.typeText("Suria KLCC")
        let r = app.buttons.matching(identifier: "searchResult").firstMatch
        XCTAssertTrue(r.waitForExistence(timeout: 20)); r.tap()
        XCTAssertTrue(app.buttons["routesButton"].waitForExistence(timeout: 10)); app.buttons["routesButton"].tap()
        let cards = app.buttons.matching(identifier: "routeCard")
        XCTAssertTrue(cards.firstMatch.waitForExistence(timeout: 60), "a long trip opens the route list")
        sleep(2)
        shot("route-options-list")
        XCTAssertTrue(app.buttons["goNow"].label.hasPrefix("Start"), "Start · <time> via <road>: \(app.buttons["goNow"].label)")
        if cards.count >= 2 {
            cards.element(boundBy: 1).tap()
            sleep(2)
            shot("route-options-compare")
            XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label ==[c] 'Compared with the fastest'")).firstMatch.exists)
        }
    }
}
