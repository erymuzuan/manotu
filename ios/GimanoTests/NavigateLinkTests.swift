import Foundation
import Testing
@testable import Gimano

struct NavigateLinkTests {
    private func parse(_ s: String) -> NavigateRequest? { URL(string: s).flatMap(NavigateLink.parse) }
    private let bases = ["manotu://navigate?", "https://manotu.app/nav/?", "https://manotu.app/nav?"]

    @Test func validLinks() {
        for b in bases {
            let r = parse(b + "lat=3.1301&lng=101.6712&label=Aisyah%2C%20Block%20B")
            #expect(r?.lat == 3.1301); #expect(r?.lng == 101.6712); #expect(r?.label == "Aisyah, Block B")
            #expect(parse(b + "lat=3.1&lng=101.6")?.label == nil)
            #expect(parse(b + "lng=101.6&label=A&lat=3.1")?.label == "A")
            #expect(parse(b + "lat=3.1&lng=101.6&label=") == nil)        // empty label is invalid, as on the web
            #expect(parse(b + "lat=3.1&lng=101.6&label=Caf%C3%A9%20%23%2012%2FA%20(L2)%20O%27Neil%20%26%20Co%20%40%20x%3A")?.label == "Café # 12/A (L2) O'Neil & Co @ x:")
            #expect(parse(b + "lat=3.1&lng=101.6&label=%E0%AE%A4%E0%AE%AE%E0%AE%BF%E0%AE%B4%E0%AF%8D")?.label == "தமிழ்")   // Tamil, combining marks
            #expect(parse(b + "lat=3.1&lng=101.6&label=%E0%B8%81%E0%B8%B4%E0%B8%99")?.label == "กิน")                // Thai
            #expect(parse(b + "lat=3.1&lng=101.6&label=%E5%8C%97%E4%BA%AC")?.label == "北京")
        }
    }

    @Test func boundaries() {
        let b = "manotu://navigate?"
        #expect(parse(b + "lat=90&lng=180") != nil)
        #expect(parse(b + "lat=-90&lng=-180") != nil)
        #expect(parse(b + "lat=0&lng=0") != nil)
        #expect(parse(b + "lat=-0.000001&lng=1.123456") != nil)
        #expect(parse(b + "lat=90.000001&lng=0") == nil)
        #expect(parse(b + "lat=91&lng=0") == nil)
        #expect(parse(b + "lat=0&lng=180.1") == nil)
        #expect(parse(b + "lat=0&lng=-181") == nil)
        #expect(parse(b + "lat=3.1234567&lng=101.1") == nil)          // 7 decimals
        #expect(parse(b + "lat=1e1&lng=101.1") == nil)
        #expect(parse(b + "lat=1E1&lng=101.1") == nil)
        #expect(parse(b + "lat=%2B3.1&lng=101.1") == nil)
        #expect(parse(b + "lat=+3.1&lng=101.1") == nil)
        #expect(parse(b + "lat=nan&lng=101.1") == nil)
        #expect(parse(b + "lat=inf&lng=101.1") == nil)
        #expect(parse(b + "lat=3.&lng=101.1") == nil)
        #expect(parse(b + "lat=.5&lng=101.1") == nil)
        #expect(parse(b + "lat=&lng=101.1") == nil)
        #expect(parse(b + "lat=03.1&lng=101.1") == nil)
        #expect(parse(b + "lat=0x10&lng=101.1") == nil)
        #expect(parse(b + "lat=3.1") == nil)
        #expect(parse(b + "lng=3.1") == nil)
        #expect(parse(b) == nil)
        #expect(parse("manotu://navigate") == nil)
    }

    @Test func duplicatesAndExtras() {
        for b in bases {
            #expect(parse(b + "lat=3.1&lat=3.2&lng=101.6") == nil)
            #expect(parse(b + "lat=3.1&lng=101.6&lng=101.7") == nil)
            #expect(parse(b + "lat=3.1&lng=101.6&label=a&label=b") == nil)
            #expect(parse(b + "lat=3.1&lng=101.6&from=3.2,101.7") == nil)
            #expect(parse(b + "lat=3.1&lng=101.6&vehicle=car") == nil)
            #expect(parse(b + "lat=3.1&lng=101.6&url=https://evil.test") == nil)
            #expect(parse(b + "lat=3.1&lng=101.6&") == nil)
            #expect(parse(b + "lat=3.1&&lng=101.6") == nil)
            #expect(parse(b + "lat=3.1&lng=101.6&label") == nil)
            #expect(parse(b + "LAT=3.1&lng=101.6") == nil)
            #expect(parse(b + "lat=3.1&lng=101.6#frag") == nil)
        }
    }

    @Test func labelRules() {
        let b = "manotu://navigate?lat=3.1&lng=101.6&label="
        #expect(parse(b + String(repeating: "a", count: 60))?.label?.count == 60)
        #expect(parse(b + String(repeating: "a", count: 61)) == nil)
        #expect(parse(b + String(repeating: "%C3%A9", count: 60)) != nil)
        #expect(parse(b + String(repeating: "%C3%A9", count: 61)) == nil)
        for bad in ["%3Cb%3E", "a%3Eb", "a%0Ab", "a%0Db", "a%09b", "a%00b", "a%1Bb", "a%7Fb", "http%3A%2F%2Fevil.test", "www.evil.com",
                    "a%3Bb", "a%22b", "a%5Cb", "a%7Cb", "a%25b", "a%2Bb", "a+b", "+", "%20", "%20%20", "HTTPS%3A%2F%2Fx", "WWW.x", "a%3Fb", "a%3Db", "a%2Ab", "%E2%80%AEx", "a%C2%A0b", "%F0%9F%98%80", "%ZZ"] {
            #expect(parse(b + bad) == nil, "\(bad)")
        }
    }

    @Test func wrongSchemeHostPath() {
        let q = "?lat=3.1&lng=101.6"
        for link in ["http://manotu.app/nav/", "https://evil.test/nav/", "https://manotu.app.evil.test/nav/", "https://www.manotu.app/nav/",
                     "https://manotu.app/p/", "https://manotu.app/nav/x", "https://manotu.app/navigate/", "https://manotu.app/", "https://manotu.app/nav//",
                     "manotu://place", "manotu://nav", "manotu://navigate/x", "manotu://navigatex", "gimano://navigate", "evil://navigate",
                     "https://manotu.app:443/nav/", "https://manotu.app:8443/nav/", "manotu://navigate:80"] {
            #expect(parse(link + q) == nil, "\(link)")
        }
        #expect(parse("manotu://navigate/" + q) != nil)
    }

    @Test func credentials() {
        let q = "?lat=3.1&lng=101.6"
        #expect(parse("https://evil@manotu.app/nav/" + q) == nil)
        #expect(parse("https://u:p@manotu.app/nav/" + q) == nil)
        #expect(parse("manotu://user@navigate" + q) == nil)
        #expect(parse("manotu://user:pw@navigate" + q) == nil)
    }

    @Test func placeLinksUnaffected() {
        #expect(PlaceLink.parse(URL(string: "manotu://navigate?lat=3.1&lng=101.6")!) == nil)
        #expect(NavigateLink.parse(URL(string: "manotu://place?id=w123")!) == nil)
    }

    @Test func pendingAndSupersede() {
        let a = NavigateRequest(lat: 1, lng: 2, label: "A")
        let b = NavigateRequest(lat: 3, lng: 4, label: "B")
        var s = NavigateLinkState()
        #expect(s.pending == nil)
        #expect(s.offer(a, driving: false) == .pending)
        #expect(s.pending == a)
        #expect(s.offer(b, driving: false) == .pending)        // newer supersedes
        #expect(s.pending == b)
        #expect(s.confirm(driving: false) == b)
        #expect(s.pending == nil)
        #expect(s.confirm(driving: false) == nil)              // nothing twice
    }

    @Test func pendingDuringDrive() {
        let a = NavigateRequest(lat: 1, lng: 2, label: nil)
        var s = NavigateLinkState()
        #expect(s.offer(a, driving: true) == .finishDriveFirst)
        #expect(s.pending == nil)
        _ = s.offer(a, driving: false)
        #expect(s.offer(a, driving: true) == .finishDriveFirst)   // a pending one is dropped too
        #expect(s.pending == nil)
        _ = s.offer(a, driving: false)
        #expect(s.confirm(driving: true) == nil)                  // drive started while the sheet was open
        #expect(s.pending == nil)
        _ = s.offer(a, driving: false)
        s.cancel()
        #expect(s.pending == nil)
        #expect(s.confirm(driving: false) == nil)
    }
}
