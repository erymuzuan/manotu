package my.gimano.app.core.nav

import my.gimano.app.core.geo.GeoMath
import my.gimano.app.core.geo.GeoPoint
import my.gimano.app.data.model.AlertOnRoute
import my.gimano.app.data.model.Report

/**
 * Alerts reported after the route was calculated (docs/driving.md §6.1): the phone already listens to the live feed
 * for its map area, so it matches those reports to its own road ahead. The server never learns the route.
 */
object LiveAlertsOnRoute {
    /** A report counts as "on the road" within this distance of the route line. */
    const val LATERAL_M = 40.0
    /** Voice once + chip from this far ahead. */
    const val ANNOUNCE_M = 1_000.0
    /** "Still there?" window: from [ASK_BEFORE_M] before the spot to [ASK_AFTER_M] after it. */
    const val ASK_BEFORE_M = 150.0
    const val ASK_AFTER_M = 100.0
    /** Alerts stay in the chip/card logic a little after the spot, never for longer. */
    const val PASSED_M = 100.0

    /** Reports that sit on [geometry] in the driver's direction, as alerts with their along-route distance. */
    fun match(geometry: RouteGeometry, reports: List<Report>): List<AlertOnRoute> = reports.mapNotNull { r ->
        if (r.subtype == "other_side") return@mapNotNull null
        val s = geometry.snap(GeoPoint(r.lat, r.lng)) ?: return@mapNotNull null
        if (s.distanceFromRouteM > LATERAL_M) return@mapNotNull null
        // A report facing the other way is for the other carriageway.
        val h = r.heading
        if (h != null && GeoMath.angleDiff(h, s.segmentBearing) > 100.0) return@mapNotNull null
        AlertOnRoute(r.id, r.type, r.subtype, r.lat, r.lng, r.heading, r.street, r.reportedBy, r.createdAt, r.expiresAt,
            r.confirmations, r.thanks, s.distanceAlongM)
    }

    /** Ask "still there?" only when the spot is within the window: [deltaM] = alert along-distance minus ours. */
    fun asks(deltaM: Double): Boolean = deltaM in -ASK_AFTER_M..ASK_BEFORE_M
}
