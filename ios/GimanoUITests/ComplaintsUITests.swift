import XCTest

/// Complaints v1 on the simulator (demo data): "Road problem" report, the after-trip deviation question,
/// place-card "Suggest an edit" menu. Language from GIMANO_LANG.
final class ComplaintsUITests: XCTestCase {
    var lang: String { ProcessInfo.processInfo.environment["GIMANO_LANG"] ?? "en" }

    func launch(_ extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-GimanoDataMode", "demo", "-GimanoFreshDevice", "YES", "-GimanoSkipOnboarding", "YES",
                               "-GimanoFakeLocation", "3.152613,101.703718", "-AppleLanguages", "(\(lang))"] + extra
        app.launch()
        return app
    }

    func shot(_ app: XCUIApplication, _ name: String) {
        let a = XCTAttachment(screenshot: app.screenshot()); a.name = "\(lang)-\(name)"; a.lifetime = .keepAlways; add(a)
    }

    func test_1_RoadProblemReport() {
        let app = launch()
        XCTAssertTrue(app.buttons["reportButton"].waitForExistence(timeout: 30))
        app.buttons["reportButton"].tap()
        XCTAssertTrue(app.buttons["reportType.map_issue"].waitForExistence(timeout: 10))
        shot(app, "report-grid")
        app.buttons["reportType.map_issue"].tap()
        app.buttons["roadProblem.road_closed_temp"].tap()
        XCTAssertTrue(app.buttons["closureDuration.days"].waitForExistence(timeout: 5))
        app.buttons["closureDuration.days"].tap()
        shot(app, "road-problem")
        app.buttons["sendRoadProblem"].tap()
        XCTAssertTrue(app.buttons["whereTo"].waitForExistence(timeout: 10), "sheet closes after sending")
    }

    func test_2_DeviationQuestion() {
        let app = launch(["-GimanoFakeDeviation", "YES"])
        XCTAssertTrue(app.buttons["deviation.closed"].waitForExistence(timeout: 30))
        shot(app, "deviation")
        app.buttons["deviation.closed"].tap()
        XCTAssertTrue(app.buttons["whereTo"].waitForExistence(timeout: 10))
    }

    func test_3_PlaceSuggestEditMenu() {
        let app = launch()
        XCTAssertTrue(app.buttons["whereTo"].waitForExistence(timeout: 30))
        app.buttons["whereTo"].tap()
        let f = app.textFields["searchField"]; XCTAssertTrue(f.waitForExistence(timeout: 10)); f.tap(); f.typeText("KLCC")
        let r = app.buttons.matching(identifier: "searchResult").firstMatch; XCTAssertTrue(r.waitForExistence(timeout: 20)); r.tap()
        XCTAssertTrue(app.buttons["placeMore"].waitForExistence(timeout: 10)); app.buttons["placeMore"].tap()
        XCTAssertTrue(app.buttons["suggestEditMenu"].waitForExistence(timeout: 5)); app.buttons["suggestEditMenu"].tap()
        sleep(1)
        shot(app, "suggest-edit-menu")
        app.buttons.matching(NSPredicate(format: "label IN {'Temporarily closed', 'Tutup sementara'}")).firstMatch.tap()
        XCTAssertTrue(app.buttons["sendPlaceIssue"].waitForExistence(timeout: 5))
        shot(app, "closed-temporarily")
        app.buttons["sendPlaceIssue"].tap()
    }
}
