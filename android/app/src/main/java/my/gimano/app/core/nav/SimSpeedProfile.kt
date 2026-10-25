package my.gimano.app.core.nav

import my.gimano.app.data.model.Route

/**
 * Debug drive replay only: a plausible speed along the route so the camera modes get exercised. Slow round turns,
 * crawling in jams (traffic level ≥ 3), the cruise speed elsewhere.
 */
class SimSpeedProfile(route: Route, tracker: NavigationTracker) {
    private val turns: List<Double> = tracker.maneuvers
        .filter { it.type !in setOf("depart", "straight", "arrive", "merge", "keep_left", "keep_right") }
        .map { tracker.geometry.distanceAtIndex(it.beginShapeIndex) }
    private val jams: List<ClosedFloatingPointRange<Double>> = route.trafficSegments.filter { it.level >= 3 }
        .map { tracker.geometry.distanceAtIndex(it.fromIndex)..tracker.geometry.distanceAtIndex(it.toIndex) }

    fun speedAt(alongM: Double, cruiseKmh: Double): Double = when {
        jams.any { alongM in it } -> 12.0
        turns.any { alongM in (it - 150)..(it + 40) } -> minOf(cruiseKmh, 25.0)
        turns.any { alongM in (it - 400)..(it + 120) } -> minOf(cruiseKmh, 50.0)
        else -> cruiseKmh
    }
}
