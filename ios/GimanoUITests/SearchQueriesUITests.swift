import XCTest

/// The new search API on a live server, query by query, with a screenshot and the top results of each.
/// Language from GIMANO_LANG (en | ms); server from the Debug default (WS556) unless GIMANO_API is set.
final class SearchQueriesUITests: XCTestCase {
    var app: XCUIApplication!
    var lang: String { ProcessInfo.processInfo.environment["GIMANO_LANG"] ?? "en" }

    static let queries: [(String, String)] = [
        ("familymart", "Family Mart"), ("famlymart", "famly mart"), ("kfcss2", "kfc ss2"), ("7eleven", "7 eleven"),
        ("tesco", "tesco"), ("minyak", "minyak"), ("tandas", "tandas"), ("surau", "surau"), ("atm", "atm"),
        ("street", "Jalan SS2/24"), ("address", "12 Jalan SS2/24"), ("postcode", "47300"),
        ("coords", "3.1478, 101.6153"), ("pluscode", "6PH57VP3+PR"), ("putrajaya", "Putrajaya"), ("klcc", "KLCC"),
        ("nomatch", "kedai runcit pak alix"), ("nomatch2", "qwxzzy plorft"),
    ]

    override func setUp() {
        continueAfterFailure = true
        app = XCUIApplication()
        var args = ["-GimanoDataMode", "live", "-GimanoFreshDevice", "YES", "-GimanoSkipOnboarding", "YES",
                    "-GimanoFakeLocation", "3.1178,101.6213", "-AppleLanguages", "(\(lang))",
                    "-AppleLocale", lang == "ms" ? "ms_MY" : "en_MY"]
        if let api = ProcessInfo.processInfo.environment["GIMANO_API"] { args += ["-GimanoAPIBaseURL", api] }
        app.launchArguments = args
        app.launch()
        XCTAssertTrue(app.buttons["whereTo"].waitForExistence(timeout: 30))
    }

    func attach(_ name: String, _ text: String? = nil) {
        let a = text.map { XCTAttachment(string: $0) } ?? XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        a.name = "\(lang)-\(name)"
        a.lifetime = .keepAlways
        add(a)
    }

    func test_Queries() {
        app.buttons["whereTo"].tap()
        let field = app.textFields["searchField"]
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        var report: [String] = []
        for (tag, q) in Self.queries {
            field.tap()
            if let v = field.value as? String, !v.isEmpty, v != field.placeholderValue {
                app.buttons["searchClear"].firstMatch.tap()
                field.tap()
            }
            field.typeText(q)
            let anyResult = app.buttons.matching(identifier: "searchResult").firstMatch
            let chain = app.buttons["chainGroup"].firstMatch
            let none = app.staticTexts["noResultsTitle"]
            let deadline = Date().addingTimeInterval(20)
            while Date() < deadline, !(anyResult.exists || chain.exists || none.exists) { usleep(300_000) }
            sleep(1)
            var line = "\(q) → "
            if let header = app.descendants(matching: .any).matching(identifier: "correctedHeader").allElementsBoundByIndex.first, header.exists {
                line += "[corrected: \(header.label)] "
            }
            if chain.exists { line += "[chain: \(chain.label)] " }
            if none.exists {
                let sugs = app.buttons.matching(identifier: "searchSuggestion").allElementsBoundByIndex.map { $0.label }
                line += "NO RESULTS; suggestions: \(sugs.joined(separator: " | "))"
            } else {
                let rows = app.buttons.matching(identifier: "searchResult").allElementsBoundByIndex.prefix(3).map { $0.label }
                line += rows.joined(separator: " | ")
            }
            report.append(line)
            attach("q-\(tag)")
            app.buttons["searchClear"].firstMatch.tap()
        }
        attach("report", report.joined(separator: "\n"))
    }

    func test_ChooseOnMapLabelAndNearby() {
        app.buttons["whereTo"].tap()
        let field = app.textFields["searchField"]
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        field.tap()
        field.typeText("kedai runcit pak alix")
        XCTAssertTrue(app.buttons["chooseOnMap"].waitForExistence(timeout: 25))
        app.buttons["chooseOnMap"].tap()
        let addr = app.staticTexts["selectAddress"]
        XCTAssertTrue(addr.waitForExistence(timeout: 20))
        let deadline = Date().addingTimeInterval(15)
        while Date() < deadline, addr.label.contains("…") { usleep(500_000) }
        let chip = app.buttons["selectIsThis"]
        _ = chip.waitForExistence(timeout: 5)
        attach("map-label", "label=\(addr.label) chip=\(chip.exists ? chip.label : "-")")
        attach("map-select")
        app.buttons["selectChoose"].tap()
        XCTAssertTrue(app.buttons["pinNavigate"].waitForExistence(timeout: 10))
        sleep(1)
        attach("map-pin-actions")
    }

    /// Pending pill: one pseudonym adds a public place here; a second (fresh) pseudonym is asked about it.
    func test_PendingPill() {
        // 1. Add a public place as this (fresh) pseudonym.
        app.buttons["whereTo"].tap()
        let field = app.textFields["searchField"]
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        field.tap()
        field.typeText("zzq tiada langsung")
        XCTAssertTrue(app.buttons["addPlaceFromSearch"].waitForExistence(timeout: 25))
        app.buttons["addPlaceFromSearch"].tap()
        XCTAssertTrue(app.buttons["pinNext"].waitForExistence(timeout: 15))
        app.buttons["pinNext"].tap()
        let name = "Gerai Uji " + String(UUID().uuidString.prefix(6))
        let n = app.textFields["placeName"]
        XCTAssertTrue(n.waitForExistence(timeout: 10))
        n.tap(); n.typeText(name)
        app.buttons["category.restaurant"].tap()
        for _ in 0..<6 where !app.buttons["detailsNext"].isHittable { app.swipeUp() }
        app.buttons["detailsNext"].tap()
        XCTAssertTrue(app.buttons["visibilityPublic"].waitForExistence(timeout: 10))
        app.buttons["visibilityPublic"].tap()
        // A4 "It's on the map" (the AI check passed): Done opens the place card.
        if app.buttons["resultDone"].waitForExistence(timeout: 15) { app.buttons["resultDone"].tap() }
        XCTAssertTrue(app.descendants(matching: .any)["badgeCommunity"].waitForExistence(timeout: 30), "place created")
        attach("pending-created", name)
        // 2. Another pseudonym, parked nearby, is asked about it.
        app.terminate()
        var args = app.launchArguments
        args += ["-GimanoVetNow", "YES"]
        app.launchArguments = args
        app.launch()
        let pill = app.staticTexts["badgeUnverifiedCount"]
        XCTAssertTrue(pill.waitForExistence(timeout: 40), "nearby verify prompt with the pending pill")
        attach("pending-pill", "\(app.staticTexts["vettingPlaceName"].label) — \(pill.label)")
        attach("pending-prompt")
    }
}
