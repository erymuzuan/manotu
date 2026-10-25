package my.gimano.app.core.safety

import my.gimano.app.core.geo.GeoMath
import my.gimano.app.core.geo.GeoPoint
import kotlin.math.PI
import kotlin.math.cos

/** Where a point is relative to the restricted areas (docs/safety.md §4). */
enum class RestrictedZone {
    /** Inside a shape, or within `blockM` of its edge: no public contributions at all. */
    BLOCKED,
    /** Within `reviewM`: public places are held for a moderator, photos are refused. */
    NEAR,
    CLEAR,
}

/**
 * The phone's copy of GET /restricted-areas: outer rings only, `[lng, lat]` pairs. The check runs offline and sends
 * nothing. A bounding box per ring (padded by `reviewM`) keeps the lookup cheap over a few thousand shapes.
 */
class RestrictedAreas(
    val version: String,
    val blockM: Double,
    val reviewM: Double,
    val terms: List<String>,
    rings: List<List<GeoPoint>>,
) {
    class Ring(val points: List<GeoPoint>) {
        val minLat = points.minOf { it.lat }
        val maxLat = points.maxOf { it.lat }
        val minLng = points.minOf { it.lng }
        val maxLng = points.maxOf { it.lng }
    }

    val rings: List<Ring> = rings.filter { it.size >= 3 }.map(::Ring)
    val isEmpty: Boolean get() = rings.isEmpty()

    fun zone(p: GeoPoint): RestrictedZone {
        var near = false
        val padLat = reviewM / M_PER_DEG
        val padLng = reviewM / (M_PER_DEG * cos(p.lat * PI / 180.0).coerceAtLeast(0.01))
        for (r in rings) {
            if (p.lat < r.minLat - padLat || p.lat > r.maxLat + padLat || p.lng < r.minLng - padLng || p.lng > r.maxLng + padLng) continue
            if (inside(p, r.points)) return RestrictedZone.BLOCKED
            val d = edgeDistanceM(p, r.points)
            if (d <= blockM) return RestrictedZone.BLOCKED
            if (d <= reviewM) near = true
        }
        return if (near) RestrictedZone.NEAR else RestrictedZone.CLEAR
    }

    /** True when [p] is inside a shape (not merely near it): the map's "Kawasan larangan" sheet. */
    fun contains(p: GeoPoint): Boolean = rings.any { r ->
        p.lat in r.minLat..r.maxLat && p.lng in r.minLng..r.maxLng && inside(p, r.points)
    }

    companion object {
        private const val M_PER_DEG = GeoMath.EARTH_RADIUS_M * PI / 180.0

        /** Ray casting (even–odd); a closed or open ring both work. */
        fun inside(p: GeoPoint, ring: List<GeoPoint>): Boolean {
            var inside = false
            var j = ring.lastIndex
            for (i in ring.indices) {
                val a = ring[i]; val b = ring[j]
                if ((a.lat > p.lat) != (b.lat > p.lat) &&
                    p.lng < (b.lng - a.lng) * (p.lat - a.lat) / (b.lat - a.lat) + a.lng) inside = !inside
                j = i
            }
            return inside
        }

        /** Distance (m) from [p] to the nearest edge of [ring]. */
        fun edgeDistanceM(p: GeoPoint, ring: List<GeoPoint>): Double {
            var best = Double.MAX_VALUE
            for (i in ring.indices) {
                val a = ring[i]
                val b = ring[(i + 1) % ring.size]
                if (a == b) continue
                val d = GeoMath.projectOnSegment(p, a, b).second
                if (d < best) best = d
            }
            return best
        }
    }
}
