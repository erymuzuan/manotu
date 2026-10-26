package my.gimano.app

import my.gimano.app.core.geo.SearchArea
import org.junit.Assert.*
import org.junit.Test

class SearchAreaTest {
    @Test fun rotatedFootprintExcludesBoundingBoxCornersAndIncludesEdges() {
        val area = "101,3;102,4;101,5;100,4"
        assertTrue(SearchArea.contains(area, 4.0, 101.0))
        assertTrue(SearchArea.contains(area, 3.5, 101.5))
        assertFalse(SearchArea.contains(area, 3.1, 101.9))
        assertFalse(SearchArea.contains(area, 6.0, 101.0))
        assertFalse(SearchArea.contains("bad", 4.0, 101.0))
    }
}
