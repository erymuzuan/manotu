package my.gimano.app.core.trip

import my.gimano.app.data.model.Route

/**
 * Route options before a drive (design "Route options before driving", docs/api.md "Route options"). The server decides
 * which routes are worth offering (`hidden`) and why (`reasons`); this decides how the preview shows them.
 */
object RouteChoices {
    /** Trips at least this long by road open with the route list and no countdown. */
    const val LONG_TRIP_M = 10_000.0

    fun shown(routes: List<Route>): List<Route> = routes.filter { it.hidden == null }
    fun hidden(routes: List<Route>): List<Route> = routes.filter { it.hidden != null }

    /** The list opens by itself: a long car/motorcycle trip without stops and with a real choice. */
    fun listFirst(routes: List<Route>, mode: TravelMode, hasStops: Boolean): Boolean {
        val shown = shown(routes)
        return mode.isMotorised && !hasStops && shown.size >= 2 && shown.first().distanceM >= LONG_TRIP_M
    }

    /** What choosing [r] instead of [fastest] costs and saves. Null fields mean "no difference worth saying". */
    data class Compare(val extraS: Double, val tollSavedMyr: Double?, val shorterM: Double?, val longerM: Double?, val avoids: List<String>,
                       val tollExtraMyr: Double? = null)

    fun compare(r: Route, fastest: Route, shown: List<Route>): Compare {
        val tollDiff = knownToll(fastest)?.let { f -> knownToll(r)?.let { f - it } }
        val saved = tollDiff?.takeIf { it >= 0.5 }
        val diff = fastest.distanceM - r.distanceM
        val avoids = shown.filter { it.id != r.id }.flatMap { it.viaRoads.orEmpty() }.distinct()
        return Compare(
            extraS = (r.effectiveDurationS - fastest.effectiveDurationS).coerceAtLeast(0.0),
            tollSavedMyr = saved,
            shorterM = diff.takeIf { it >= 500 },
            longerM = (-diff).takeIf { it >= 500 },
            avoids = avoids,
            tollExtraMyr = tollDiff?.let { -it }?.takeIf { it >= 0.5 },
        )
    }

    /** Known total toll in RM: 0 without tolls, null when a fare is unknown. */
    fun knownToll(r: Route): Double? = when {
        !r.hasTolls -> 0.0
        r.tollFareComplete -> r.tollEstimateMyr
        else -> null
    }
}
