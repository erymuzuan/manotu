import XCTest

/// Arriving at the entrance (docs/driving.md §4) on a replayed drive to Mid Valley Megamall against the dev backend:
/// the arrival card says which side the main entrance is on, and "Wrong entrance?" opens the existing
/// place_entrance_wrong "choose on map" flow (backed out without sending). Simulator only.
///
/// Environment: GIMANO_DATA_MODE (default live), GIMANO_FAKE_LOCATION (start, default 1 km north of the mall).
final class DriveArrivalUITests: XCTestCase {
    var app: XCUIApplication!
    var env: [String: String] { ProcessInfo.processInfo.environment }

    override func setUp() { continueAfterFailure = false }

    func shot(_ name: String) {
        let a = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); a.name = name; a.lifetime = .keepAlways; add(a)
    }

    func testArrivalCardAndWrongEntrance() {
        app = XCUIApplication()
        app.launchArguments = ["-GimanoDataMode", env["GIMANO_DATA_MODE"] ?? "live", "-GimanoSkipOnboarding", "YES",
                               "-GimanoFakeLocation", env["GIMANO_FAKE_LOCATION"] ?? "3.1245,101.6790",
                               "-GimanoDriveTo", "Mid Valley Megamall|3.117928,101.676998|w922804567",
                               "-GimanoSimSpeed", "route", "-GimanoSimTick", "1", "-debug.simulationSpeedup", "4",
                               "-AppleLanguages", "(en)"]
        app.launch()
        let side = app.descendants(matching: .any)["arrivalSide"]
        XCTAssertTrue(side.waitForExistence(timeout: 240), "No arrival card")
        XCTAssertTrue(side.label.contains("entrance on your") || side.label.contains("place is on your"), side.label)
        shot("arrived")
        let wrong = app.buttons["wrongEntrance"]
        XCTAssertTrue(wrong.exists)
        wrong.tap()
        let choose = app.descendants(matching: .any)["selectChoose"]
        XCTAssertTrue(choose.waitForExistence(timeout: 10), "The entrance pin picker did not open")
        shot("wrong-entrance-picker")
        app.descendants(matching: .any)["selectBack"].tap()
    }
}
