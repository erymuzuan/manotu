package my.gimano.app.core.nav

import my.gimano.app.core.format.Lang
import my.gimano.app.core.geo.GeoMath
import my.gimano.app.core.geo.GeoPoint
import my.gimano.app.data.model.NavigationPoint
import kotlin.math.roundToInt

/** docs/driving.md §4: arriving at the entrance. */
object ArrivalRule {
    const val REMAINING_M = 30.0
    const val ON_ROUTE_M = 40.0
    const val PIN_M = 40.0

    /**
     * Arrived when the remaining distance along the route is ≤ 30 m (and the driver is on the route), or the
     * straight-line distance to the pin is ≤ 40 m, whichever comes first. Only on the last leg.
     */
    fun arrived(remainingM: Double, distanceFromRouteM: Double, distanceToPinM: Double?, lastLeg: Boolean): Boolean =
        lastLeg && ((remainingM <= REMAINING_M && distanceFromRouteM <= ON_ROUTE_M) || (distanceToPinM != null && distanceToPinM <= PIN_M))
}

/** The dashed last metres: route end → entrance (blue dots), entrance → pin (grey dots). */
object LastMetres {
    data class Line(val points: List<GeoPoint>, val kind: String)   // kind: "entrance" | "pin"

    const val PIN_FAR_M = 15.0

    fun lines(routeEnd: GeoPoint?, arrival: GeoPoint?, pin: GeoPoint?): List<Line> {
        if (routeEnd == null) return emptyList()
        val out = ArrayList<Line>()
        if (arrival != null && GeoMath.distanceM(routeEnd, arrival) > 2) out += Line(listOf(routeEnd, arrival), "entrance")
        if (pin != null && GeoMath.distanceM(routeEnd, pin) > PIN_FAR_M) {
            val from = arrival ?: routeEnd
            if (GeoMath.distanceM(from, pin) > 2) out += Line(listOf(from, pin), "pin")
        }
        return out
    }
}

enum class Side { LEFT, RIGHT }

/** "Pintu masuk utama di sebelah kiri · 25 m dari jalan" / "Main entrance on your left · 25 m from the road". */
object ArrivalText {
    /** Which side of the direction of travel [target] is, standing at the route end heading [travelBearing]. */
    fun side(routeEnd: GeoPoint, travelBearing: Double, target: GeoPoint): Side? {
        if (GeoMath.distanceM(routeEnd, target) < 3) return null
        val d = GeoMath.angleDiff(travelBearing, GeoMath.bearingDeg(routeEnd, target))
        return if (d < 0) Side.LEFT else Side.RIGHT
    }

    fun line(arrival: NavigationPoint?, routeEnd: GeoPoint?, travelBearing: Double?, pin: GeoPoint?, lang: Lang): String? {
        if (arrival == null || routeEnd == null || travelBearing == null) return null
        val ms = lang == Lang.MS
        val entrance = GeoPoint(arrival.lat, arrival.lng)
        val outline = arrival.source == "outline"
        // The outline point stands for the place itself; otherwise the entrance (or the pin when the route ends at it).
        val side = if (outline) side(routeEnd, travelBearing, pin ?: entrance) ?: side(routeEnd, travelBearing, entrance)
            else side(routeEnd, travelBearing, entrance) ?: pin?.let { side(routeEnd, travelBearing, it) }
        val what = when {
            outline -> if (ms) "Tempat ini" else "The place is"
            arrival.kind == "main" -> if (ms) "Pintu masuk utama" else "Main entrance"
            else -> if (ms) "Pintu masuk" else "Entrance"
        }
        val head = when (side) {
            null -> what.takeUnless { outline } ?: return null
            Side.LEFT -> if (ms) "$what di sebelah kiri" else "$what on your left"
            Side.RIGHT -> if (ms) "$what di sebelah kanan" else "$what on your right"
        }
        val m = ((GeoMath.distanceM(routeEnd, entrance) / 5).roundToInt() * 5)
        return if (m >= 5) "$head · $m m " + (if (ms) "dari jalan" else "from the road") else head
    }
}
