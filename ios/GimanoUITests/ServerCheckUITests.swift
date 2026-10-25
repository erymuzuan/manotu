import XCTest

/// A plain launch (no test arguments): which server does the installed Debug app use?
final class ServerCheckUITests: XCTestCase {
    func test_ServerAfterTests() {
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(en)", "-GimanoSkipSafety", "YES"]
        app.launch()
        if app.buttons["Continue"].waitForExistence(timeout: 5) { app.buttons["Continue"].tap() }
        XCTAssertTrue(app.buttons["menuButton"].waitForExistence(timeout: 30))
        app.buttons["menuButton"].tap()
        XCTAssertTrue(app.buttons["Settings"].waitForExistence(timeout: 10))
        app.buttons["Settings"].tap()
        let server = app.descendants(matching: .any)["serverHost"]
        for _ in 0..<8 where !server.exists { app.swipeUp() }
        XCTAssertTrue(server.waitForExistence(timeout: 10))
        let a = XCTAttachment(string: server.label)
        a.name = "server"; a.lifetime = .keepAlways; add(a)
        XCTAssertTrue(server.label.contains("100.101.150.9"), "Debug app points at WS556 again: \(server.label)")
    }
}
