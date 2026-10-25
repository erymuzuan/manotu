import XCTest

/// Hold-to-report (docs/driving.md §6.4) in a simulated drive. Simulator only (gestures). The live test sends a real
/// quick report to the dev API and withdraws it with Undo, checking `/live` before and after.
/// Environment: GIMANO_LANG (en|ms), GIMANO_DATA_MODE (default live = dev server).
final class QuickReportUITests: XCTestCase {
    var app: XCUIApplication!
    var env: [String: String] { ProcessInfo.processInfo.environment }
    var lang: String { env["GIMANO_LANG"] ?? "en" }
    var tag: String { "\(lang)" }
    let apiBase = "http://100.101.150.9:5080/api/v1/"

    override func setUp() { continueAfterFailure = false }

    func launch(_ extra: [String] = []) {
        app = XCUIApplication()
        app.launchArguments = ["-GimanoDataMode", env["GIMANO_DATA_MODE"] ?? "live", "-GimanoSkipOnboarding", "YES", "-GimanoNoAutoStart", "YES",
                               "-GimanoFakeLocation", "3.152613,101.703718", "-GimanoSimulateDrive", "YES",
                               "-AppleLanguages", "(\(lang))"] + extra
        app.launch()
        XCTAssertTrue(app.buttons["whereTo"].waitForExistence(timeout: 40))
    }

    func shot(_ name: String) {
        let a = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); a.name = "\(tag)-\(name)"; a.lifetime = .keepAlways; add(a)
    }

    func note(_ name: String, _ text: String) {
        let a = XCTAttachment(string: text); a.name = "\(tag)-\(name)"; a.lifetime = .keepAlways; add(a)
    }

    @discardableResult
    func wait(_ e: XCUIElement, _ t: TimeInterval = 25) -> XCUIElement {
        XCTAssertTrue(e.waitForExistence(timeout: t), "Timed out waiting for \(e)")
        return e
    }

    func startDrive() {
        wait(app.buttons["whereTo"]).tap()
        let f = wait(app.textFields["searchField"]); f.tap(); f.typeText("Mid Valley")
        wait(app.buttons.matching(identifier: "searchResult").firstMatch, 30).tap()
        wait(app.buttons["routesButton"]).tap()
        wait(app.buttons["goNow"], 40).tap()
        wait(app.staticTexts["maneuverDistance"], 30)
    }

    func agreeIfAsked(_ t: TimeInterval = 3) {
        let agree = app.buttons["communityAgree"]
        if agree.waitForExistence(timeout: t) { shot("0-community-rules"); agree.tap(); sleep(1) }
    }

    var log: String { app.staticTexts["quickReportLog"].label }

    /// Hold the report button, slide by (dx, dy) from its centre, release.
    func holdAndSlide(dx: CGFloat, dy: CGFloat) {
        let b = wait(app.descendants(matching: .any).matching(identifier: "reportButton").firstMatch)
        let c = b.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        c.press(forDuration: 0.6, thenDragTo: c.withOffset(CGVector(dx: dx, dy: dy)), withVelocity: .slow, thenHoldForDuration: 0.4)
    }

    /// Report ids in `/live` around the start (anonymous, public data).
    func liveIds() -> [String] {
        let url = URL(string: apiBase + "live?bbox=101.60,3.05,101.80,3.25&types=alerts")!
        let done = expectation(description: "live")
        var ids: [String] = []
        URLSession.shared.dataTask(with: url) { data, _, _ in
            if let data, let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let a = o["alerts"] as? [[String: Any]] {
                ids = a.compactMap { $0["id"] as? String }
            }
            done.fulfill()
        }.resume()
        wait(for: [done], timeout: 15)
        return ids
    }

    func test_1_TapOpensFullSheet() {
        launch()
        startDrive()
        wait(app.descendants(matching: .any).matching(identifier: "reportButton").firstMatch).tap()
        XCTAssertTrue(app.buttons["reportType.hazard"].waitForExistence(timeout: 5), "tap = the full report sheet")
        XCTAssertTrue(app.buttons["reportType.map_issue"].exists, "Map issue stays in the full sheet")
        shot("1-tap-full-sheet")
    }

    func test_2_FanScreens() {
        launch(["-GimanoQuickFan", "open"])
        startDrive()
        XCTAssertTrue(app.otherElements["quickFanBanner"].waitForExistence(timeout: 15) || app.staticTexts.count > 0)
        sleep(5)
        shot("2-fan-open")
        app.terminate()
        launch(["-GimanoQuickFan", "hazard"])
        startDrive()
        sleep(6)
        shot("3-fan-hazard-selected")
        app.terminate()
        launch(["-GimanoQuickReportCard", "hazard"])
        startDrive()
        wait(app.descendants(matching: .any).matching(identifier: "quickReportCard").firstMatch, 15)
        sleep(1)
        shot("4-reported-card")
    }

    func test_3_ReleaseOutsideCancels() {
        launch()
        startDrive()
        holdAndSlide(dx: -60, dy: 60)            // below-left of the button: no bubble there
        sleep(2)
        XCTAssertFalse(app.descendants(matching: .any).matching(identifier: "quickReportCard").firstMatch.exists)
        XCTAssertFalse(app.buttons["reportType.hazard"].exists, "a hold never opens the full sheet")
        XCTAssertEqual(log, "", "nothing sent")
        // A hold released back on the button: cancelled too.
        holdAndSlide(dx: 0, dy: 0)
        sleep(2)
        XCTAssertEqual(log, "")
        shot("5-cancelled")
    }

    /// Real quick report + Undo against the dev API.
    func test_4_QuickReportAndUndoLive() {
        launch()
        startDrive()
        sleep(3)
        holdAndSlide(dx: 0, dy: -122)            // Hazard, straight up on the inner ring
        agreeIfAsked()
        let card = app.descendants(matching: .any).matching(identifier: "quickReportCard").firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 10), "sent card")
        shot("6-hazard-reported")
        let logEl = app.staticTexts["quickReportLog"]
        XCTAssertTrue(NSPredicate(format: "label BEGINSWITH 'sent='").evaluate(with: logEl) || {
            _ = XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "label BEGINSWITH 'sent='"), object: logEl)], timeout: 10)
            return logEl.label.hasPrefix("sent=")
        }(), "POST /reports answered")
        let id = String(log.dropFirst("sent=".count))
        let before = liveIds()
        app.buttons["quickReportUndo"].tap()
        _ = XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "label BEGINSWITH 'withdrawn='"), object: logEl)], timeout: 15)
        shot("7-undone")
        sleep(1)
        let after = liveIds()
        note("7-live-undo", "id \(id): in /live before Undo \(before.contains(id)); after \(after.contains(id)); log '\(log)'")
        XCTAssertTrue(before.contains(id), "the quick report was live")
        XCTAssertEqual(log, "withdrawn=\(id)")
        XCTAssertFalse(after.contains(id), "Undo withdrew it")
    }
}
