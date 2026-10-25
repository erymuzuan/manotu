package my.gimano.app.core.nav

import my.gimano.app.core.geo.GeoPoint

/**
 * The travelled part of the route (docs/driving.md §6.3): everything behind the animated arrow is redrawn light grey
 * on a white casing; the road ahead stays blue (and keeps the traffic colours, drawn underneath).
 *
 * Fed the arrow's distance along the route on every display frame. To keep that cheap on long routes it hands back
 * two lines: a [Update.stable] part (route start → a vertex behind the arrow), only when it has to be re-sent, and a
 * short [Update.tail] (that vertex → the arrow) every frame. The stable part moves up after [rebaseVertices] vertices
 * or [rebaseTailM] metres. A new route (reroute) gets a new trail, so only the new route shows.
 */
class TravelledTrail(
    private val geometry: RouteGeometry,
    private val rebaseVertices: Int = 24,
    private val rebaseTailM: Double = 250.0,
) {
    /** [stable] is null when the last one sent is still right. Lines of fewer than 2 points draw nothing. */
    data class Update(val stable: List<GeoPoint>?, val tail: List<GeoPoint>)

    private var stableEnd = 0
    private var sent = false

    fun update(alongM: Double): Update {
        val g = geometry
        if (g.points.size < 2) return Update(emptyList(), emptyList())
        val a = alongM.coerceIn(0.0, g.lengthM)
        val i = splitIndex(g.cumulative, a)
        var changed = !sent
        if (i < stableEnd) { stableEnd = i; changed = true }   // re-snapped behind the stable part: rebuild it
        if (i - stableEnd > rebaseVertices || a - g.cumulative[stableEnd] > rebaseTailM) { stableEnd = i; changed = true }
        sent = true
        val stable = if (changed) g.points.subList(0, stableEnd + 1).toList() else null
        val tail = ArrayList<GeoPoint>(i - stableEnd + 2)
        for (k in stableEnd..i) tail += g.points[k]
        val here = g.pointAt(a).first
        if (tail.last() != here) tail += here
        return Update(stable, tail)
    }

    companion object {
        /** Index of the last vertex at or before [alongM] (the split between travelled and ahead). */
        fun splitIndex(cumulative: DoubleArray, alongM: Double): Int {
            if (cumulative.isEmpty()) return 0
            if (alongM <= cumulative[0]) return 0
            var lo = 0
            var hi = cumulative.size - 1
            if (alongM >= cumulative[hi]) return hi
            while (hi - lo > 1) {
                val mid = (lo + hi) ushr 1
                if (cumulative[mid] <= alongM) lo = mid else hi = mid
            }
            return lo
        }
    }
}
