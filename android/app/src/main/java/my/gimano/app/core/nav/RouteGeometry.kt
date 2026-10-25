package my.gimano.app.core.nav

import my.gimano.app.core.geo.GeoMath
import my.gimano.app.core.geo.GeoPoint

/** Decoded route shape with cumulative distances, for snapping and distance-along-route queries. */
class RouteGeometry(val points: List<GeoPoint>) {
    /** cumulative[i] = metres from start to points[i]. */
    val cumulative: DoubleArray = DoubleArray(points.size).also { arr ->
        for (i in 1 until points.size) arr[i] = arr[i - 1] + GeoMath.distanceM(points[i - 1], points[i])
    }
    val lengthM: Double get() = if (cumulative.isEmpty()) 0.0 else cumulative.last()

    data class Snap(
        val segmentIndex: Int,      // index of segment start point
        val fraction: Double,       // 0..1 along the segment
        val distanceFromRouteM: Double,
        val distanceAlongM: Double,
        val point: GeoPoint,
        val segmentBearing: Double,
    )

    /**
     * Snaps [p] to the closest segment. When [fromSegment] is given, only a forward window
     * (plus a small look-back) is searched so a looping route doesn't make us jump ahead.
     */
    fun snap(p: GeoPoint, fromSegment: Int = 0, window: Int = Int.MAX_VALUE): Snap? {
        if (points.size < 2) return null
        val start = (fromSegment - 2).coerceAtLeast(0)
        val end = if (window == Int.MAX_VALUE) points.size - 2 else (fromSegment + window).coerceAtMost(points.size - 2)
        var best: Snap? = null
        for (i in start..end) {
            val a = points[i]
            val b = points[i + 1]
            val (t, d) = GeoMath.projectOnSegment(p, a, b)
            if (best == null || d < best.distanceFromRouteM) {
                val segLen = cumulative[i + 1] - cumulative[i]
                best = Snap(i, t, d, cumulative[i] + segLen * t, GeoMath.lerp(a, b, t), GeoMath.bearingDeg(a, b))
            }
        }
        return best
    }

    /** Point at [distanceM] along the route. */
    fun pointAt(distanceM: Double): Pair<GeoPoint, Double> {
        if (points.isEmpty()) return GeoPoint(0.0, 0.0) to 0.0
        if (points.size == 1 || distanceM <= 0) return points.first() to (if (points.size > 1) GeoMath.bearingDeg(points[0], points[1]) else 0.0)
        if (distanceM >= lengthM) return points.last() to GeoMath.bearingDeg(points[points.size - 2], points.last())
        var lo = 0
        var hi = cumulative.size - 1
        while (hi - lo > 1) {
            val mid = (lo + hi) / 2
            if (cumulative[mid] <= distanceM) lo = mid else hi = mid
        }
        val segLen = cumulative[hi] - cumulative[lo]
        val t = if (segLen == 0.0) 0.0 else (distanceM - cumulative[lo]) / segLen
        return GeoMath.lerp(points[lo], points[hi], t) to GeoMath.bearingDeg(points[lo], points[hi])
    }

    /** The part of the line between two along-distances: exact endpoints plus every vertex in between. */
    fun slice(fromM: Double, toM: Double): List<GeoPoint> {
        val a = fromM.coerceIn(0.0, lengthM)
        val b = toM.coerceIn(a, lengthM)
        val out = ArrayList<GeoPoint>()
        out += pointAt(a).first
        for (i in points.indices) if (cumulative[i] > a && cumulative[i] < b) out += points[i]
        out += pointAt(b).first
        return out
    }

    /** Index of the segment containing [distanceM]. */
    fun segmentAt(distanceM: Double): Int {
        val i = cumulative.indexOfFirst { it > distanceM }
        return if (i <= 0) 0 else i - 1
    }

    /** Direction of the route from [alongM] to [aheadM] metres further on (smooth through vertices). */
    fun bearingAhead(alongM: Double, aheadM: Double): Double {
        val a = pointAt(alongM)
        if (alongM + 1 >= lengthM) return a.second
        val b = pointAt(minOf(alongM + aheadM, lengthM)).first
        return if (GeoMath.distanceM(a.first, b) < 0.5) a.second else GeoMath.bearingDeg(a.first, b)
    }

    fun distanceAtIndex(i: Int): Double = cumulative[i.coerceIn(0, cumulative.size - 1)]
}
