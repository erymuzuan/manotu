package my.gimano.app.core.nav

import my.gimano.app.core.geo.GeoMath
import my.gimano.app.core.geo.GeoPoint
import my.gimano.app.core.geo.Polyline
import my.gimano.app.data.model.Maneuver
import my.gimano.app.data.model.Route

/** Progress snapshot for the UI and voice guidance. */
data class NavProgress(
    val snapped: GeoPoint,
    val bearing: Double,
    val distanceAlongM: Double,
    val distanceFromRouteM: Double,
    val remainingM: Double,
    val remainingS: Double,
    val nextManeuverIndex: Int,
    val nextManeuver: Maneuver?,
    /** Leg the driver is on (0 = to the first stop). */
    val legIndex: Int = 0,
    val distanceToNextM: Double,
    val thenManeuver: Maneuver?,
    val arrived: Boolean,
)

/** Pure tracker: feed it fixes, it tells you where you are on the route. */
class NavigationTracker(val route: Route, private val pin: GeoPoint? = null) {
    val geometry = RouteGeometry(Polyline.decode(route.polyline))
    private val legManeuvers = my.gimano.app.core.trip.RouteLegs.maneuvers(route)
    val maneuvers: List<Maneuver> = legManeuvers.map { it.maneuver }
    val legCount: Int = route.legs.size.coerceAtLeast(1)

    /** Along-route distance of each intermediate stop (end of every leg but the last). */
    val stopAlongM: List<Double> = legManeuvers.groupBy { it.leg }.toSortedMap().values
        .map { geometry.distanceAtIndex(it.last().maneuver.beginShapeIndex) }
        .dropLast(1)
    private val reportedStops = HashSet<Int>()

    /** Returns the index of an intermediate stop the driver just reached (within 25 m), once each. */
    fun stopReached(p: NavProgress): Int? =
        stopAlongM.indices.firstOrNull { k -> p.distanceAlongM >= stopAlongM[k] - 25 && k !in reportedStops }?.also { reportedStops += it }
    private var lastSegment = 0
    private val speedFactor: Double =
        if (geometry.lengthM > 0) route.effectiveDurationS / geometry.lengthM else 0.0 // s per metre

    fun update(p: GeoPoint): NavProgress? {
        val snap = geometry.snap(p, lastSegment, window = 60) ?: return null
        // If the windowed snap is poor (e.g. after a GPS gap), retry on the whole route.
        val s = if (snap.distanceFromRouteM > 80) geometry.snap(p)?.takeIf { it.distanceFromRouteM < snap.distanceFromRouteM } ?: snap else snap
        lastSegment = s.segmentIndex
        val along = s.distanceAlongM
        val remainingM = (geometry.lengthM - along).coerceAtLeast(0.0)

        // Next maneuver = first one whose begin point is ahead of us.
        var idx = maneuvers.indexOfFirst { geometry.distanceAtIndex(it.beginShapeIndex) > along + 5 }
        if (idx == -1 && maneuvers.isNotEmpty()) idx = maneuvers.lastIndex
        val next = maneuvers.getOrNull(idx)
        val distToNext = if (next != null) (geometry.distanceAtIndex(next.beginShapeIndex) - along).coerceAtLeast(0.0) else remainingM
        val then = maneuvers.getOrNull(idx + 1)
        val leg = legManeuvers.getOrNull(idx)?.leg ?: 0
        // docs/driving.md §4: ≤ 30 m left along the route (on it), or ≤ 40 m in a straight line from the pin.
        val arrived = ArrivalRule.arrived(remainingM, s.distanceFromRouteM, pin?.let { GeoMath.distanceM(p, it) }, leg >= legCount - 1)
        return NavProgress(
            snapped = s.point,
            bearing = s.segmentBearing,
            distanceAlongM = along,
            distanceFromRouteM = s.distanceFromRouteM,
            remainingM = remainingM,
            remainingS = remainingM * speedFactor,
            nextManeuverIndex = idx,
            nextManeuver = next,
            legIndex = leg,
            distanceToNextM = distToNext,
            thenManeuver = then,
            arrived = arrived,
        )
    }

    companion object {
        /** Show the "then" strip only when the following maneuver comes quickly after the next one. */
        fun showThen(next: Maneuver?, then: Maneuver?): Boolean =
            next != null && then != null && next.type != "arrive" && next.distanceM < 400
    }
}

/**
 * Decides which voice prompts to speak. Each maneuver gets at most one "far" prompt
 * (distance depends on speed) and one "now" prompt.
 */
class VoicePromptPlanner(private val mode: String = "car") {
    private val spokenFar = HashSet<Int>()
    private val spokenNear = HashSet<Int>()
    private val spokenNow = HashSet<Int>()

    enum class Stage { FAR, NEAR, NOW }

    fun farDistanceFor(speedKmh: Double): Double = when {
        mode == "walk" -> 150.0
        mode == "bicycle" -> 300.0
        speedKmh > 80 -> 2000.0
        speedKmh > 50 -> 1000.0
        else -> 500.0
    }

    fun check(maneuverIndex: Int, distanceM: Double, speedKmh: Double): Stage? {
        if (maneuverIndex < 0) return null
        val far = farDistanceFor(speedKmh)
        val nowDist = when { mode == "walk" -> 15.0; mode == "bicycle" -> 30.0; speedKmh > 60 -> 120.0; else -> 60.0 }
        val nearMax = if (mode == "walk" || mode == "bicycle") far else minOf(far, 400.0)
        return when {
            distanceM <= nowDist && spokenNow.add(maneuverIndex) -> Stage.NOW
            distanceM in (nowDist + 20)..nearMax && maneuverIndex !in spokenNow && spokenNear.add(maneuverIndex) -> Stage.NEAR
            distanceM in 401.0..far && spokenFar.add(maneuverIndex) -> Stage.FAR
            else -> null
        }
    }

    fun reset() {
        spokenFar.clear(); spokenNear.clear(); spokenNow.clear()
    }
}

/** Heading difference helper exposed for the controller. */
fun headingDiff(a: Double?, b: Double): Double? = a?.let { GeoMath.angleDiff(it, b) }
