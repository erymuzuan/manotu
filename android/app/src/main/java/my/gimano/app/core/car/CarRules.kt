package my.gimano.app.core.car

import my.gimano.app.core.format.Lang
import my.gimano.app.core.trip.TollBadge
import my.gimano.app.data.model.Route

/** docs/driving.md §5: rules of the car screens that don't need Android. */
object CarRules {
    /** Rows on a list while driving ("Ke mana?": Rumah, Kerja, favourites, recents). */
    const val MAX_ROWS_DRIVING = 6
    const val MAX_ROUTES = 3
    /** "Masih ada?" alert: 8 s, at most one per 2 km driven. */
    const val STILL_THERE_MS = 8_000L
    const val STILL_THERE_EVERY_M = 2_000.0
    const val STILL_THERE_WITHIN_M = 800.0
    const val TOLL_ALERT_MS = 8_000L

    /**
     * Short "via" for a car row: the road refs of the summary ("Via E11, E6"), else its first part, at most 28 chars.
     * The full summary wraps over four lines on a car screen and pushes the other routes out of view.
     */
    fun shortVia(summary: String, lang: Lang): String? {
        val refs = Regex("""\b[A-Z]{1,3}\d{1,4}\b""").findAll(summary).map { it.value }.distinct().take(3).toList()
        val via = if (lang == Lang.MS) "Melalui " else "Via "
        if (refs.isNotEmpty()) return via + refs.joinToString(", ")
        val first = summary.removePrefix("Via ").removePrefix("Melalui ").substringBefore(",").trim()
        if (first.isEmpty()) return null
        return via + if (first.length > 28) first.take(27).trimEnd() + "…" else first
    }

    /** Route choice row: "Tanpa tol" / "Tol RM 2.10" / "Tol dari RM 1.60" / "Tol". */
    fun tollLabel(route: Route, lang: Lang): String {
        val ms = lang == Lang.MS
        return when (val b = TollBadge.of(route)) {
            TollBadge.None -> if (ms) "Tanpa tol" else "No tolls"
            is TollBadge.Exact -> (if (ms) "Tol " else "Toll ") + TollBadge.rm(b.myr)
            is TollBadge.From -> (if (ms) "Tol dari " else "Toll from ") + TollBadge.rm(b.myr)
            TollBadge.Unknown -> if (ms) "Tol" else "Toll"
        }
    }
}

/**
 * "Masih ada?" in the car (an Alert with Ya / Tiada): once per report, and at most one per 2 km driven, so the driver
 * is never asked in a row. [odometerM] = metres driven this trip (keeps counting across reroutes).
 */
class StillThereGate {
    private val asked = HashSet<String>()
    private var lastAskedAtM: Double? = null

    fun shouldAsk(alertId: String, aheadM: Double, odometerM: Double): Boolean {
        if (alertId in asked || aheadM !in 0.0..CarRules.STILL_THERE_WITHIN_M) return false
        val last = lastAskedAtM
        if (last != null && odometerM - last < CarRules.STILL_THERE_EVERY_M) return false
        asked += alertId
        lastAskedAtM = odometerM
        return true
    }

    fun reset() { asked.clear(); lastAskedAtM = null }
}

/** Metres driven this trip from along-route distances, which restart at 0 on every reroute. */
class Odometer {
    private var lastAlong: Double? = null
    var metres = 0.0
        private set

    fun update(alongM: Double, routeId: String?): Double {
        val prev = lastAlong
        if (routeId != lastRoute) { lastRoute = routeId; lastAlong = alongM; return metres }
        if (prev != null && alongM > prev) metres += alongM - prev
        lastAlong = alongM
        return metres
    }
    private var lastRoute: String? = null

    fun reset() { lastAlong = null; metres = 0.0; lastRoute = null }
}

/** Shows each car alert (toll plaza, Tinjau problem) once per drive. */
class OncePerKey {
    private val seen = HashSet<String>()
    fun first(key: String): Boolean = seen.add(key)
    fun reset() = seen.clear()
}
