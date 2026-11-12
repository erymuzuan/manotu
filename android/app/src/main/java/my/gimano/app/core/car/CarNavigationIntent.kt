package my.gimano.app.core.car

import java.net.URI
import java.net.URLDecoder

/** Untrusted Assistant/POI input. Never log destination URIs. */
data class CarNavigationTarget(val query: String? = null, val lat: Double? = null, val lng: Double? = null)

object CarNavigationIntent {
    const val ACTION = "androidx.car.app.action.NAVIGATE"
    fun parse(action: String?, raw: String?): CarNavigationTarget? = runCatching {
        if (action != ACTION || raw == null || raw.length > 4096) return null
        val uri = URI(raw)
        if (uri.scheme != "geo" || uri.rawFragment != null) return null
        val body = uri.rawSchemeSpecificPart
        val params = body.substringAfter('?', "").split('&').filter { it.isNotEmpty() }
            .map { it.substringBefore('=') to URLDecoder.decode(it.substringAfter('=', ""), "UTF-8") }
        if (params.count { it.first == "q" } > 1) return null
        val queryParameter = params.firstOrNull { it.first == "q" }
        val query = queryParameter?.second?.trim()?.takeIf { it.isNotEmpty() }
        if (queryParameter != null && query == null) return null
        if (query != null) {
            if (query.length > 512 || query.any { it.isISOControl() }) return null
            val coordinateQuery = Regex("^(-?[0-9]+(?:\\.[0-9]+)?),\\s*(-?[0-9]+(?:\\.[0-9]+)?)(?:\\s*\\([^)]*\\))?$").matchEntire(query)
            if (coordinateQuery != null) {
                return coordinates(coordinateQuery.groupValues[1], coordinateQuery.groupValues[2])
            }
            return CarNavigationTarget(query = query)
        }
        val parts = body.substringBefore('?').split(',')
        if (parts.size != 2) return null
        coordinates(parts[0], parts[1])
    }.getOrNull()

    private fun coordinates(latitude: String, longitude: String): CarNavigationTarget? {
        val lat = latitude.toDoubleOrNull() ?: return null
        val lng = longitude.toDoubleOrNull() ?: return null
        if (!lat.isFinite() || !lng.isFinite() || lat !in -90.0..90.0 || lng !in -180.0..180.0) return null
        return CarNavigationTarget(lat = lat, lng = lng)
    }
}
