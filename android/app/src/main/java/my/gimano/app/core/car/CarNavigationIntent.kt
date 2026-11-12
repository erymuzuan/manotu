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
        val query = params.firstOrNull { it.first == "q" }?.second?.trim()?.takeIf { it.isNotEmpty() }
        if (query != null) {
            if (query.length > 512 || query.any { it.isISOControl() }) return null
            return CarNavigationTarget(query = query)
        }
        val coordinates = body.substringBefore('?').split(',')
        if (coordinates.size != 2) return null
        val lat = coordinates[0].toDoubleOrNull() ?: return null
        val lng = coordinates[1].toDoubleOrNull() ?: return null
        if (!lat.isFinite() || !lng.isFinite() || lat !in -90.0..90.0 || lng !in -180.0..180.0) return null
        CarNavigationTarget(lat = lat, lng = lng)
    }.getOrNull()
}
