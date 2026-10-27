package my.gimano.app.core.update

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.contentOrNull

/**
 * Google Play build only: `GET {apiBase}/app/versions` (docs/app-updates.md) lists the newest published marketing
 * version per platform; the app only points the person at the store, it never downloads anything itself.
 */
data class StoreVersion(
    val latest: String,
    val forceBelow: String? = null,
    val storeUrl: String? = null,
    val releasedAt: String? = null,
) {
    companion object {
        const val PLATFORM = "android-play"
        const val FALLBACK_STORE_URL = "https://play.google.com/store/apps/details?id=my.manotu.app"
        private val json = Json { ignoreUnknownKeys = true; isLenient = true }

        /** null when the body is unusable (not JSON, no platform entry, or a latest that isn't a version). */
        fun parse(text: String, platform: String = PLATFORM): StoreVersion? {
            val root = runCatching { json.parseToJsonElement(text) as? JsonObject }.getOrNull() ?: return null
            val p = (root["platforms"] as? JsonObject)?.get(platform) as? JsonObject ?: return null
            fun str(k: String) = (p[k] as? JsonPrimitive)?.takeIf { it !is JsonNull }?.contentOrNull?.trim()?.takeIf { it.isNotEmpty() }
            val latest = str("latest")?.takeIf { SemVer.parse(it) != null } ?: return null
            return StoreVersion(
                latest = latest,
                forceBelow = str("forceBelow")?.takeIf { SemVer.parse(it) != null },
                storeUrl = str("storeUrl")?.takeIf { it.startsWith("https://") },
                releasedAt = str("releasedAt"),
            )
        }
    }
}

/** Marketing version "0.4.10": numeric per segment (0.4.10 > 0.4.9), a "-suffix" is ignored, missing segments are 0. */
object SemVer {
    fun parse(v: String): List<Int>? {
        val core = v.trim().removePrefix("v").substringBefore('-').substringBefore('+')
        if (core.isEmpty()) return null
        val parts = core.split('.').map { it.toIntOrNull() ?: return null }
        return parts.takeIf { it.all { n -> n >= 0 } }
    }

    /** Negative / 0 / positive like compareTo; unparseable input compares as equal (never nags on garbage). */
    fun compare(a: String, b: String): Int {
        val x = parse(a) ?: return 0
        val y = parse(b) ?: return 0
        for (i in 0 until maxOf(x.size, y.size)) {
            val c = x.getOrElse(i) { 0 }.compareTo(y.getOrElse(i) { 0 })
            if (c != 0) return c
        }
        return 0
    }
}

sealed interface StoreUpdateDecision {
    data object None : StoreUpdateDecision
    /** A newer version: a dismissable card, once per cold start. */
    data class Soft(val current: String, val latest: String) : StoreUpdateDecision
    /** current < forceBelow: a blocking card, Update only. */
    data class Forced(val current: String, val latest: String) : StoreUpdateDecision
}

object StoreUpdatePolicy {
    const val CHECK_EVERY_MS = 30 * 60_000L
    const val MARKET_URI = "market://details?id=my.manotu.app"

    /** The Play build always; a debug build only behind its debug toggle. Everything else (website APK) never. */
    fun enabled(distribution: String, debug: Boolean, debugToggle: Boolean) = distribution == "play" || (debug && debugToggle)

    fun decide(current: String, v: StoreVersion?): StoreUpdateDecision = when {
        v == null -> StoreUpdateDecision.None
        v.forceBelow != null && SemVer.compare(current, v.forceBelow) < 0 -> StoreUpdateDecision.Forced(current, v.latest)
        SemVer.compare(current, v.latest) < 0 -> StoreUpdateDecision.Soft(current, v.latest)
        else -> StoreUpdateDecision.None
    }

    /** True when a request is due: never checked, 30 min elapsed, or the clock went backwards. */
    fun shouldCheck(lastCheckMs: Long, nowMs: Long) = lastCheckMs <= 0 || nowMs < lastCheckMs || nowMs - lastCheckMs >= CHECK_EVERY_MS

    /** The card may show now: not while navigating, and a soft one not after "Later" this process. */
    fun visible(d: StoreUpdateDecision, navigating: Boolean, laterThisLaunch: Boolean) = when (d) {
        StoreUpdateDecision.None -> false
        is StoreUpdateDecision.Forced -> !navigating
        is StoreUpdateDecision.Soft -> !navigating && !laterThisLaunch
    }

    fun storeUrl(v: StoreVersion?) = v?.storeUrl ?: StoreVersion.FALLBACK_STORE_URL
}
