package my.gimano.app.core.links

import java.net.URI

/** Public place IDs only. Never interpret links as private pins, API hosts or navigation commands. */
object PlaceLink {
    private val idPattern = Regex("(?:[nwr][1-9][0-9]{0,19}|c[0-9a-f]{32})")

    fun parse(raw: String): String? = runCatching {
        if (raw.length > 256) return null
        val uri = URI(raw)
        if (uri.rawUserInfo != null || uri.port != -1 || uri.rawFragment != null) return null
        val supported = when (uri.scheme?.lowercase()) {
            "https" -> uri.host?.lowercase() == "manotu.app" && uri.rawPath in listOf("/p", "/p/")
            "manotu" -> uri.host?.lowercase() == "place" && uri.rawPath in listOf("", "/")
            else -> false
        }
        if (!supported) return null
        val query = uri.rawQuery ?: return null
        if (!query.startsWith("id=")) return null
        query.removePrefix("id=").takeIf { idPattern.matches(it) }
    }.getOrNull()
}
