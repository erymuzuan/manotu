import XCTest

final class TmpFacebookPostUITests: XCTestCase {
    func snap(_ name: String, _ app: XCUIApplication) {
        let s = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); s.lifetime = .keepAlways; s.name = name; add(s)
        let t = XCTAttachment(string: app.debugDescription); t.lifetime = .keepAlways; t.name = name + "-tree"; add(t)
    }

    func testLook() throws {
        let fb = XCUIApplication(bundleIdentifier: "com.facebook.Facebook")
        fb.activate(); _ = fb.wait(for: .runningForeground, timeout: 30); sleep(3)
        snap("z-look", fb)
    }

    func testPageName() throws {
        continueAfterFailure = false
        let fb = XCUIApplication(bundleIdentifier: "com.facebook.Facebook")
        fb.activate(); _ = fb.wait(for: .runningForeground, timeout: 30); sleep(2)
        fb.coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 0)).withOffset(CGVector(dx: 100, dy: 261)).tap(); sleep(2)
        XCTAssertTrue(fb.keyboards.firstMatch.waitForExistence(timeout: 5))
        for k in ["M","a","n","o","t","u"] { fb.keyboards.keys[k].tap() }
        sleep(1)
        snap("n1-name", fb)
        fb.buttons["Next"].firstMatch.tap(); sleep(4)
        snap("n2-after-next", fb)
    }

    func testNext() throws {
        continueAfterFailure = false
        let fb = XCUIApplication(bundleIdentifier: "com.facebook.Facebook")
        fb.activate(); _ = fb.wait(for: .runningForeground, timeout: 30); sleep(2)
        let done = fb.buttons["Done"]
        if done.exists { done.tap(); sleep(1) }
        fb.buttons["Next"].firstMatch.tap(); sleep(4)
        snap("o-next", fb)
    }

    func testFixName() throws {
        continueAfterFailure = false
        let fb = XCUIApplication(bundleIdentifier: "com.facebook.Facebook")
        fb.activate(); _ = fb.wait(for: .runningForeground, timeout: 30); sleep(2)
        fb.buttons["back-button"].tap(); sleep(2)
        fb.coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 0)).withOffset(CGVector(dx: 100, dy: 261)).tap(); sleep(2)
        XCTAssertTrue(fb.keyboards.firstMatch.waitForExistence(timeout: 5))
        let del = fb.keyboards.keys["delete"]
        for _ in 0..<14 { del.tap() }
        let isUpper = fb.keyboards.keys["M"].exists
        for k in (isUpper ? ["M"] : ["shift", "M"]) { if fb.keyboards.keys[k].exists { fb.keyboards.keys[k].tap() } }
        for k in ["a","n","o","t","u"] { fb.keyboards.keys[k].tap() }
        sleep(1)
        snap("q1-typed", fb)
        let literal = fb.descendants(matching: .any).matching(NSPredicate(format: "label == '\u{201C}Manotu\u{201D}'")).firstMatch
        if literal.exists { literal.tap(); sleep(1) }
        snap("q2-literal", fb)
    }

    func testNext2() throws {
        continueAfterFailure = false
        let fb = XCUIApplication(bundleIdentifier: "com.facebook.Facebook")
        fb.activate(); _ = fb.wait(for: .runningForeground, timeout: 30); sleep(2)
        let done = fb.buttons["Done"]
        if done.exists { done.tap(); sleep(1) }
        fb.buttons["Next"].firstMatch.tap(); sleep(4)
        snap("r-next", fb)
    }

    func testCategory() throws {
        continueAfterFailure = false
        let fb = XCUIApplication(bundleIdentifier: "com.facebook.Facebook")
        fb.activate(); _ = fb.wait(for: .runningForeground, timeout: 30); sleep(2)
        let tf = fb.textFields.firstMatch
        tf.tap(); tf.typeText("software"); sleep(3)
        snap("s1-search-software", fb)
        tf.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 8)); tf.typeText("app")
        sleep(3)
        snap("s2-search-app", fb)
    }

    func testPickAppPage() throws {
        continueAfterFailure = false
        let fb = XCUIApplication(bundleIdentifier: "com.facebook.Facebook")
        fb.activate(); _ = fb.wait(for: .runningForeground, timeout: 30); sleep(2)
        let opt = fb.descendants(matching: .any).matching(NSPredicate(format: "label == 'App Page'")).firstMatch
        if !opt.exists { fb.coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 0)).withOffset(CGVector(dx: 64, dy: 371)).tap() } else { opt.tap() }
        sleep(2)
        snap("t-picked", fb)
    }

    func testCreate() throws {
        continueAfterFailure = false
        let fb = XCUIApplication(bundleIdentifier: "com.facebook.Facebook")
        fb.activate(); _ = fb.wait(for: .runningForeground, timeout: 30); sleep(2)
        let done = fb.buttons["Done"]
        if done.exists { done.tap(); sleep(1) }
        snap("u0-before-create", fb)
        let create = fb.buttons["Create"].firstMatch
        XCTAssertTrue(create.waitForExistence(timeout: 5)); XCTAssertTrue(create.isEnabled)
        create.tap(); sleep(8)
        snap("u1-after-create", fb)
    }

    func testTapNext() throws {
        continueAfterFailure = false
        let fb = XCUIApplication(bundleIdentifier: "com.facebook.Facebook")
        fb.activate(); _ = fb.wait(for: .runningForeground, timeout: 30); sleep(2)
        let next = fb.buttons["Next"].firstMatch
        XCTAssertTrue(next.waitForExistence(timeout: 5)); next.tap(); sleep(6)
        snap("v-next", fb)
    }

    func pasteInto(_ fb: XCUIApplication, text: String, at pt: CGVector, tag: String) {
        UIPasteboard.general.string = text
        fb.coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 0)).withOffset(pt).tap(); sleep(2)
        let paste = fb.menuItems["Paste"].firstMatch
        if paste.waitForExistence(timeout: 3) { paste.tap() }
        else {
            let alt = fb.descendants(matching: .any).matching(NSPredicate(format: "label == 'Paste'")).firstMatch
            if alt.waitForExistence(timeout: 3) { alt.tap() }
        }
        sleep(1)
        let sb = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let allow = sb.buttons["Allow Paste"]
        if allow.waitForExistence(timeout: 2) { allow.tap() }
        sleep(2)
        snap(tag, fb)
    }

    func testBio() throws {
        continueAfterFailure = false
        let fb = XCUIApplication(bundleIdentifier: "com.facebook.Facebook")
        fb.activate(); _ = fb.wait(for: .runningForeground, timeout: 30); sleep(2)
        pasteInto(fb, text: "Navigasi komuniti Malaysia. Percuma, tanpa iklan. Tempat peribadi kekal dalam telefon anda. Akses awal.", at: CGVector(dx: 196, dy: 296), tag: "w-bio")
    }

    func testBio2() throws {
        continueAfterFailure = false
        let fb = XCUIApplication(bundleIdentifier: "com.facebook.Facebook")
        fb.activate(); _ = fb.wait(for: .runningForeground, timeout: 30); sleep(2)
        UIPasteboard.general.string = "Navigasi komuniti Malaysia. Percuma, tanpa iklan. Tempat peribadi kekal dalam telefon anda. Akses awal."
        let origin = fb.coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 0))
        origin.withOffset(CGVector(dx: 196, dy: 296)).tap(); sleep(2)
        snap("x1-first", fb)
        origin.withOffset(CGVector(dx: 100, dy: 306)).tap(); sleep(2)
        snap("x2-second", fb)
    }

    func testBio3() throws {
        continueAfterFailure = false
        let fb = XCUIApplication(bundleIdentifier: "com.facebook.Facebook")
        fb.activate(); _ = fb.wait(for: .runningForeground, timeout: 30); sleep(2)
        let origin = fb.coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 0))
        origin.withOffset(CGVector(dx: 196, dy: 330)).tap(); sleep(1)   // blur then refocus
        origin.withOffset(CGVector(dx: 196, dy: 296)).tap(); sleep(3)
        snap("y1-focus", fb)
        let paste = fb.descendants(matching: .any).matching(NSPredicate(format: "label == 'Paste'")).firstMatch
        if paste.waitForExistence(timeout: 4) { paste.tap(); sleep(1) }
        let sb = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let allow = sb.buttons["Allow Paste"]
        if allow.waitForExistence(timeout: 3) { allow.tap() }
        sleep(2)
        snap("y2-pasted", fb)
    }

    func testBio4() throws {
        continueAfterFailure = false
        let fb = XCUIApplication(bundleIdentifier: "com.facebook.Facebook")
        fb.activate(); _ = fb.wait(for: .runningForeground, timeout: 30); sleep(2)
        XCTAssertTrue(fb.keyboards.firstMatch.waitForExistence(timeout: 5))
        fb.keyboards.firstMatch.typeText("Navigasi komuniti Malaysia. Percuma, tanpa iklan. Tempat peribadi kekal dalam telefon anda. Akses awal.")
        sleep(2)
        snap("z1-bio-typed", fb)
    }

    func testSkipDetails() throws {
        continueAfterFailure = false
        let fb = XCUIApplication(bundleIdentifier: "com.facebook.Facebook")
        fb.activate(); _ = fb.wait(for: .runningForeground, timeout: 30); sleep(2)
        // dismiss keyboard by tapping the heading area
        fb.coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 0)).withOffset(CGVector(dx: 196, dy: 160)).tap(); sleep(1)
        let next = fb.buttons["Next"].firstMatch
        XCTAssertTrue(next.waitForExistence(timeout: 5)); next.tap(); sleep(6)
        snap("a1-after-details", fb)
    }

    func testSkipDetails2() throws {
        continueAfterFailure = false
        let fb = XCUIApplication(bundleIdentifier: "com.facebook.Facebook")
        fb.activate(); _ = fb.wait(for: .runningForeground, timeout: 30); sleep(2)
        let o = fb.coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 0))
        o.withOffset(CGVector(dx: 196, dy: 250)).press(forDuration: 0.1, thenDragTo: o.withOffset(CGVector(dx: 196, dy: 560))); sleep(2)
        snap("b0-after-swipe", fb)
        if fb.keyboards.firstMatch.exists { fb.swipeDown(); sleep(2) }
        let next = fb.buttons["Next"].firstMatch
        XCTAssertTrue(next.isHittable, "Next still covered")
        next.tap(); sleep(6)
        snap("b1-after-details", fb)
    }

    func testOpenMenu() throws {
        continueAfterFailure = false
        let fb = XCUIApplication(bundleIdentifier: "com.facebook.Facebook")
        fb.activate(); _ = fb.wait(for: .runningForeground, timeout: 30); sleep(2)
        let m = fb.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'menu'")).firstMatch
        if m.waitForExistence(timeout: 5) { m.tap() } else { fb.coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 0)).withOffset(CGVector(dx: 21, dy: 85)).tap() }
        sleep(3)
        snap("m0-menu", fb)
    }

    func testSeeMore() throws {
        continueAfterFailure = false
        let fb = XCUIApplication(bundleIdentifier: "com.facebook.Facebook")
        fb.activate(); _ = fb.wait(for: .runningForeground, timeout: 30); sleep(2)
        let b = fb.buttons["See more"].firstMatch
        XCTAssertTrue(b.waitForExistence(timeout: 5)); b.tap(); sleep(2)
        snap("s0-seemore", fb)
        fb.swipeUp(); sleep(1)
        snap("s1-seemore-scrolled", fb)
    }

    func testOpenPages() throws {
        continueAfterFailure = false
        let fb = XCUIApplication(bundleIdentifier: "com.facebook.Facebook")
        fb.activate(); _ = fb.wait(for: .runningForeground, timeout: 30); sleep(2)
        let pages = fb.buttons.matching(NSPredicate(format: "label ==[c] 'Pages'")).firstMatch
        var n = 0
        while !(pages.exists && pages.isHittable) && n < 8 { fb.swipeUp(); n += 1; usleep(600000) }
        XCTAssertTrue(pages.exists, "no Pages entry")
        pages.tap(); sleep(4)
        snap("p0-pages", fb)
    }

    func testOpenManotu() throws {
        continueAfterFailure = false
        let fb = XCUIApplication(bundleIdentifier: "com.facebook.Facebook")
        fb.activate(); _ = fb.wait(for: .runningForeground, timeout: 30); sleep(2)
        snap("q-before", fb)
        fb.coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 0)).withOffset(CGVector(dx: 110, dy: 246)).tap(); sleep(5)
        snap("q0-page", fb)
    }

    func testSwitch() throws {
        continueAfterFailure = false
        let fb = XCUIApplication(bundleIdentifier: "com.facebook.Facebook")
        fb.activate(); _ = fb.wait(for: .runningForeground, timeout: 30); sleep(2)
        snap("w-before", fb)
        fb.coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 0)).withOffset(CGVector(dx: 345, dy: 730)).tap(); sleep(6)
        snap("w0-switched", fb)
    }

    func testTapXY() throws {
        continueAfterFailure = false
        let fb = XCUIApplication(bundleIdentifier: "com.facebook.Facebook")
        fb.activate(); _ = fb.wait(for: .runningForeground, timeout: 30); sleep(2)
        let env = ProcessInfo.processInfo.environment
        _ = env; let x = 362.0 /*X*/, y = 85.0 /*Y*/
        fb.coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 0)).withOffset(CGVector(dx: x, dy: y)).tap(); sleep(4)
        snap("t0-after", fb)
    }

    func testPageTab() throws {
        continueAfterFailure = false
        let fb = XCUIApplication(bundleIdentifier: "com.facebook.Facebook")
        fb.activate(); _ = fb.wait(for: .runningForeground, timeout: 30); sleep(2)
        let t = fb.buttons["tab-bar-item-190055527696468"]
        XCTAssertTrue(t.waitForExistence(timeout: 8)); t.tap(); sleep(4)
        snap("u0-pagetab", fb)
    }

    /// Types `text` into the field at (x, y): typeText first, on-screen key taps when the field ignores it.
    func testTypeAt() throws {
        continueAfterFailure = false
        let fb = XCUIApplication(bundleIdentifier: "com.facebook.Facebook")
        fb.activate(); _ = fb.wait(for: .runningForeground, timeout: 30); sleep(2)
        let text = "manotu.app"
        let o = fb.coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 0))
        o.withOffset(CGVector(dx: 196, dy: 265 /*TY*/)).tap(); sleep(2)
        let tf = fb.textFields.firstMatch
        if tf.exists && tf.value(forKey: "hasKeyboardFocus") as? Bool == true { tf.typeText(text) }
        else {
            for ch in text {
                let k = String(ch)
                let key = fb.keyboards.keys[k].exists ? fb.keyboards.keys[k] : fb.keyboards.keys[k.uppercased()]
                if key.exists { key.tap() }
                else if k == "@" || k == "." || k == ":" || k == "/" {
                    if fb.keyboards.keys["more"].exists { fb.keyboards.keys["more"].tap() }
                    if fb.keyboards.keys[k].exists { fb.keyboards.keys[k].tap() }
                    if fb.keyboards.keys["letters"].exists { fb.keyboards.keys["letters"].tap() }
                } else { XCTFail("no key \(k)") }
            }
        }
        sleep(1)
        snap("v0-typed", fb)
    }

    func testScrollTop() throws {
        continueAfterFailure = false
        let fb = XCUIApplication(bundleIdentifier: "com.facebook.Facebook")
        fb.activate(); _ = fb.wait(for: .runningForeground, timeout: 30); sleep(2)
        for _ in 0..<6 { fb.swipeDown(velocity: .fast); usleep(500000) }
        snap("x0-top", fb)
    }

    func testReplaceText() throws {
        continueAfterFailure = false
        let fb = XCUIApplication(bundleIdentifier: "com.facebook.Facebook")
        fb.activate(); _ = fb.wait(for: .runningForeground, timeout: 30); sleep(2)
        let text = "Navigasi komuniti Malaysia. Percuma, tanpa iklan. Tempat peribadi kekal dalam telefon anda. Akses awal."
        let o = fb.coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 0))
        o.withOffset(CGVector(dx: 300, dy: 300)).tap(); sleep(2)
        let tv = fb.textViews.firstMatch
        XCTAssertTrue(tv.exists, "no text view")
        tv.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 300))
        tv.typeText(text); sleep(1)
        snap("y0-replaced", fb)
    }

    func testScrollDown() throws {
        continueAfterFailure = false
        let fb = XCUIApplication(bundleIdentifier: "com.facebook.Facebook")
        fb.activate(); _ = fb.wait(for: .runningForeground, timeout: 30); sleep(2)
        fb.swipeUp(); sleep(1); fb.swipeUp(); sleep(1)
        snap("z-down", fb)
    }

    func testBackToDetails() throws {
        continueAfterFailure = false
        let fb = XCUIApplication(bundleIdentifier: "com.facebook.Facebook")
        fb.activate(); _ = fb.wait(for: .runningForeground, timeout: 30); sleep(2)
        let o = fb.coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 0))
        o.withOffset(CGVector(dx: 196, dy: 300)).press(forDuration: 0.1, thenDragTo: o.withOffset(CGVector(dx: 196, dy: 800))); sleep(2)
        o.withOffset(CGVector(dx: 24, dy: 85)).tap(); sleep(2)
        fb.swipeDown(); sleep(1); fb.swipeDown(); sleep(1)
        snap("d0-details", fb)
    }

    func testScrollOne() throws {
        continueAfterFailure = false
        let fb = XCUIApplication(bundleIdentifier: "com.facebook.Facebook")
        fb.activate(); _ = fb.wait(for: .runningForeground, timeout: 30); sleep(2)
        fb.swipeUp(); sleep(1)
        snap("z-one", fb)
    }

    func testClearByKeys() throws {
        continueAfterFailure = false
        let fb = XCUIApplication(bundleIdentifier: "com.facebook.Facebook")
        fb.activate(); _ = fb.wait(for: .runningForeground, timeout: 30); sleep(2)
        let del = fb.keyboards.keys["delete"]
        XCTAssertTrue(del.waitForExistence(timeout: 5))
        for _ in 0..<40 { del.tap() }
        snap("c0-cleared", fb)
    }
}
