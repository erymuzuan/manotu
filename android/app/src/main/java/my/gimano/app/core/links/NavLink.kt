package my.gimano.app.core.links

import java.net.URI

/**
 * A request from another app (e.g. a delivery app) to route to a point: `manotu://navigate?lat=&lng=&label=` or the
 * verified App Link `https://manotu.app/nav/?lat=&lng=&label=`. Any app can send it, so it never starts anything by
 * itself: the user confirms first ([NavLinkPending]). No start point (the phone position is used) and no vehicle
 * (the user's selected profile is used). The label is plain display text kept on this phone only.
 */
data class NavLink(val lat: Double, val lng: Double, val label: String?)

object NavLinkParser {
    const val MAX_LABEL = 60
    private const val MAX_RAW = 512
    private val decimal = Regex("-?(?:0|[1-9][0-9]{0,2})(?:\\.[0-9]{1,6})?")
    private const val SYMBOLS = ".,-#/()'&@: "

    /** True when the URI is addressed to the navigate route (valid or not), so a rejected one is dropped, never passed on. */
    fun isNavTarget(raw: String): Boolean = runCatching {
        val uri = URI(raw)
        when (uri.scheme?.lowercase()) {
            "https" -> uri.host?.lowercase() == "manotu.app" && uri.rawPath in PATHS
            "manotu" -> uri.host?.lowercase() == "navigate"
            else -> false
        }
    }.getOrDefault(false)

    private val PATHS = listOf("/nav", "/nav/")

    fun parse(raw: String): NavLink? = runCatching {
        if (raw.length > MAX_RAW || raw.any { it.isWhitespace() } || '#' in raw) return null
        val uri = URI(raw)
        if (uri.rawUserInfo != null || uri.port != -1 || uri.rawFragment != null) return null
        val ok = when (uri.scheme?.lowercase()) {
            "https" -> uri.host?.lowercase() == "manotu.app" && uri.rawPath in PATHS
            "manotu" -> uri.host?.lowercase() == "navigate" && uri.rawPath in listOf("", "/")
            else -> false
        }
        if (!ok) return null
        val query = uri.rawQuery ?: return null
        val params = HashMap<String, String>()
        for (pair in query.split('&')) {
            val eq = pair.indexOf('=')
            if (eq <= 0) return null
            val key = pair.substring(0, eq)
            if (key != "lat" && key != "lng" && key != "label") return null
            if (params.put(key, pair.substring(eq + 1)) != null) return null
        }
        val lat = coordinate(params["lat"], 90.0) ?: return null
        val lng = coordinate(params["lng"], 180.0) ?: return null
        val label = params["label"]?.let { label(it) ?: return null }
        NavLink(lat, lng, label)
    }.getOrNull()

    private fun coordinate(s: String?, limit: Double): Double? {
        if (s == null || !decimal.matches(s)) return null
        val v = s.toDouble()
        return v.takeIf { it.isFinite() && it >= -limit && it <= limit }
    }

    /** Null = rejected (an empty or blank label is invalid, as in site/manotu/nav/link.mjs). */
    private fun label(rawValue: String): String? {
        val text = percentDecode(rawValue) ?: return null
        if (text.isEmpty() || text.length > MAX_LABEL || text.isBlank()) return null  // UTF-16 units, as link.mjs
        var i = 0
        while (i < text.length) {
            val cp = text.codePointAt(i)
            i += Character.charCount(cp)
            val type = Character.getType(cp)
            val mark = type == Character.NON_SPACING_MARK.toInt() || type == Character.COMBINING_SPACING_MARK.toInt() || type == Character.ENCLOSING_MARK.toInt()
            val number = type == Character.DECIMAL_DIGIT_NUMBER.toInt() || type == Character.LETTER_NUMBER.toInt() || type == Character.OTHER_NUMBER.toInt()
            val ok = Character.isLetter(cp) || number || mark || (cp < 128 && SYMBOLS.indexOf(cp.toChar()) >= 0)
            if (!ok) return null
        }
        val lower = text.lowercase()
        if ("://" in lower || "www." in lower) return null
        return text
    }

    /** Strict UTF-8 percent-decoding; '+' stays a plus (and is then rejected as a label character). */
    private fun percentDecode(s: String): String? {
        val out = java.io.ByteArrayOutputStream()
        var i = 0
        while (i < s.length) {
            val c = s[i]
            if (c == '%') {
                if (i + 3 > s.length) return null
                val h1 = Character.digit(s[i + 1], 16); val h2 = Character.digit(s[i + 2], 16)
                if (h1 < 0 || h2 < 0 || s[i + 1].code > 127 || s[i + 2].code > 127) return null
                val b = h1 * 16 + h2
                out.write(b)
                i += 3
            } else {
                if (c.code >= 128) { out.write(c.toString().toByteArray(Charsets.UTF_8)) } else out.write(c.code)
                i++
            }
        }
        val dec = Charsets.UTF_8.newDecoder()
            .onMalformedInput(java.nio.charset.CodingErrorAction.REPORT)
            .onUnmappableCharacter(java.nio.charset.CodingErrorAction.REPORT)
        return runCatching { dec.decode(java.nio.ByteBuffer.wrap(out.toByteArray())).toString() }.getOrNull()
    }
}

/** The one link waiting for the user's Confirm. A newer link replaces it; Cancel or Confirm clears it. */
object NavLinkPending {
    fun offer(@Suppress("UNUSED_PARAMETER") pending: NavLink?, incoming: NavLink): NavLink = incoming
    fun cancel(@Suppress("UNUSED_PARAMETER") pending: NavLink?): NavLink? = null
    /** The link to route to, and the new pending state (always none). Null when nothing is waiting or a drive is in progress. */
    fun confirm(pending: NavLink?, driveActive: Boolean): Pair<NavLink?, NavLink?> =
        if (driveActive) null to null else pending to null
}
