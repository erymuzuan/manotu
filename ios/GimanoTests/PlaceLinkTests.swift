import Foundation
import Testing
@testable import Gimano

struct PlaceLinkTests {
    @Test func publicPlaceLinks() {
        for prefix in ["https://manotu.app/p/?id=", "https://manotu.app/p?id=", "manotu://place?id="] {
            for id in ["w1106132383", "n123", "r42", "c01a166b7f9c67924976aff1beb56c2cd"] {
                #expect(PlaceLink.parse(URL(string: prefix + id)!) == id)
            }
            for id in ["private:123", "pin:1,2", "../me", "%2fme", "", "w0", "w123&id=n456", "w123#key", "w123&url=https://evil.test"] {
                #expect(PlaceLink.parse(URL(string: prefix + id)!) == nil)
            }
        }
        for link in ["https://evil.test/p/?id=w123", "https://manotu.app.evil.test/p/?id=w123", "https://evil@manotu.app/p/?id=w123", "http://manotu.app/p/?id=w123", "https://manotu.app:443/p/?id=w123", "https://manotu.app/j/?id=w123", "manotu://event?id=w123"] {
            #expect(PlaceLink.parse(URL(string: link)!) == nil)
        }
    }
}
