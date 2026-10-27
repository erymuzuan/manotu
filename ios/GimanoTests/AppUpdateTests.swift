import XCTest
@testable import Gimano

final class AppUpdateTests: XCTestCase {
    func testVersionCompareIsNumericPerSegment() {
        XCTAssertTrue(AppVersion("0.4.9")! < AppVersion("0.4.10")!)
        XCTAssertTrue(AppVersion("0.4")! == AppVersion("0.4.0")!)
        XCTAssertTrue(AppVersion("1.0")! > AppVersion("0.99.99")!)
        XCTAssertTrue(AppVersion("0.5.0-beta")! == AppVersion("0.5.0")!)
        XCTAssertNil(AppVersion("abc"))
        XCTAssertNil(AppVersion(""))
        XCTAssertNil(AppVersion(nil))
    }

    func testDecision() {
        XCTAssertEqual(UpdatePolicy.decide(current: "0.4.2", latest: "0.4.2", forceBelow: nil), .none)
        XCTAssertEqual(UpdatePolicy.decide(current: "0.4.3", latest: "0.4.2", forceBelow: nil), .none)
        XCTAssertEqual(UpdatePolicy.decide(current: "0.4.1", latest: "0.4.2", forceBelow: "0.4.0"), .soft)
        XCTAssertEqual(UpdatePolicy.decide(current: "0.3.9", latest: "0.4.2", forceBelow: "0.4.0"), .forced)
        XCTAssertEqual(UpdatePolicy.decide(current: "0.4.0", latest: "0.4.2", forceBelow: "0.4.0"), .soft)
        XCTAssertEqual(UpdatePolicy.decide(current: "0.4.9", latest: "0.4.10", forceBelow: nil), .soft)
        XCTAssertEqual(UpdatePolicy.decide(current: "0.4.1", latest: "garbage", forceBelow: "x"), .none)
        XCTAssertEqual(UpdatePolicy.decide(current: "?", latest: "9.0", forceBelow: nil), .none)
    }

    func testThrottle() {
        let t = Date(timeIntervalSince1970: 1_000_000)
        XCTAssertTrue(UpdatePolicy.shouldCheck(lastChecked: nil, now: t))
        XCTAssertFalse(UpdatePolicy.shouldCheck(lastChecked: t, now: t.addingTimeInterval(29 * 60)))
        XCTAssertTrue(UpdatePolicy.shouldCheck(lastChecked: t, now: t.addingTimeInterval(30 * 60)))
        XCTAssertTrue(UpdatePolicy.shouldCheck(lastChecked: t, now: t.addingTimeInterval(-5)))
    }

    func testStoreUrl() {
        XCTAssertEqual(UpdatePolicy.storeOpenURL("https://apps.apple.com/app/id6826478029")?.absoluteString,
                       "itms-apps://apps.apple.com/app/id6826478029")
        XCTAssertNil(UpdatePolicy.storeOpenURL(nil))
        XCTAssertNil(UpdatePolicy.storeOpenURL("not a url"))
    }

    func testDecoding() throws {
        let json = #"{"platforms":{"ios":{"latest":"0.4.2","forceBelow":"0.4.0","storeUrl":"https://apps.apple.com/app/id6826478029","releasedAt":"2026-10-27T01:00:00Z"},"android":{"latest":"0.3.9","forceBelow":null}}}"#
        let r = try JSONDecoder().decode(AppVersionsResponse.self, from: Data(json.utf8))
        XCTAssertEqual(r.ios?.latest, "0.4.2")
        XCTAssertEqual(r.ios?.forceBelow, "0.4.0")
        XCTAssertNil(r.platforms["android"]?.forceBelow)
        let nulls = try JSONDecoder().decode(AppVersionsResponse.self, from: Data(#"{"platforms":{"ios":{"latest":"1.0","forceBelow":null}}}"#.utf8))
        XCTAssertNil(nulls.ios?.forceBelow)
        XCTAssertNil(try JSONDecoder().decode(AppVersionsResponse.self, from: Data(#"{"platforms":{}}"#.utf8)).ios)
    }

    @MainActor
    func testCenterThrottlesCachesAndDefers() async throws {
        let suite = "update-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        final class Counter: @unchecked Sendable { var n = 0 }
        let c = Counter()
        let body = Data(#"{"platforms":{"ios":{"latest":"0.4.2","forceBelow":"0.4.0","storeUrl":"https://apps.apple.com/app/id1"}}}"#.utf8)
        var clock = Date(timeIntervalSince1970: 2_000_000)
        let center = UpdateCenter(defaults: defaults, currentVersion: "0.4.1", skipChecks: false, now: { clock },
                                  fetch: { _ in c.n += 1; return body })
        let base = URL(string: "https://example.test/api/v1/")!
        await center.checkIfDue(apiBase: base, demo: false)
        await center.checkIfDue(apiBase: base, demo: false)
        XCTAssertEqual(c.n, 1)
        XCTAssertEqual(center.decision, .soft)
        XCTAssertEqual(center.presentation(busy: true), .none)
        XCTAssertEqual(center.presentation(busy: false), .soft)
        center.later()
        XCTAssertEqual(center.presentation(busy: false), .none)
        XCTAssertTrue(center.updateAvailable)
        clock = clock.addingTimeInterval(31 * 60)
        await center.checkIfDue(apiBase: base, demo: false)
        XCTAssertEqual(c.n, 2)
        // Cached answer survives a restart; failures leave it alone.
        let again = UpdateCenter(defaults: defaults, currentVersion: "0.3.0", skipChecks: false, now: { clock }, fetch: { _ in nil })
        XCTAssertEqual(again.decision, .forced)
        XCTAssertEqual(again.presentation(busy: false), .forced)
        again.later()
        XCTAssertEqual(again.presentation(busy: false), .forced)
    }

    @MainActor
    func testSkippedWhenTestFlightOrDemo() async {
        let suite = "update-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        final class Counter: @unchecked Sendable { var n = 0 }
        let c = Counter()
        let tf = UpdateCenter(defaults: defaults, currentVersion: "0.1", skipChecks: true, fetch: { _ in c.n += 1; return nil })
        await tf.checkIfDue(apiBase: URL(string: "https://x.test/api/v1/")!, demo: false)
        let demo = UpdateCenter(defaults: defaults, currentVersion: "0.1", skipChecks: false, fetch: { _ in c.n += 1; return nil })
        await demo.checkIfDue(apiBase: URL(string: "https://x.test/api/v1/")!, demo: true)
        XCTAssertEqual(c.n, 0)
        XCTAssertEqual(tf.decision, .none)
    }
}
