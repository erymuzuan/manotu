package my.gimano.app.links

import my.gimano.app.core.links.PlaceLink
import org.junit.Assert.*
import org.junit.Test

class PlaceLinkTest {
    @Test fun opensOnlyPublicPlacesOnTrustedHosts() {
        for (prefix in listOf("https://manotu.app/p/?id=", "https://manotu.app/p?id=", "manotu://place?id=")) {
            for (id in listOf("w1106132383", "n123", "r42", "c01a166b7f9c67924976aff1beb56c2cd"))
                assertEquals(id, PlaceLink.parse(prefix + id))
            for (id in listOf("private:123", "pin:1,2", "../me", "%2fme", "", "w0", "w123&id=n456", "w123#key", "w123&url=https://evil.test"))
                assertNull(prefix + id, PlaceLink.parse(prefix + id))
        }
        for (link in listOf("https://evil.test/p/?id=w123", "https://manotu.app.evil.test/p/?id=w123", "https://evil@manotu.app/p/?id=w123", "http://manotu.app/p/?id=w123", "https://manotu.app:443/p/?id=w123", "https://manotu.app/j/?id=w123", "manotu://event?id=w123", "https://manotu.app/p/?id=w123\n"))
            assertNull(link, PlaceLink.parse(link))
    }
}
