package my.gimano.app.core.nav

import my.gimano.app.core.format.Formatters
import my.gimano.app.core.format.Lang
import my.gimano.app.core.geo.GeoPoint
import my.gimano.app.core.trip.TollBadge
import my.gimano.app.data.model.Route
import my.gimano.app.data.model.TollPlaza

/** A toll plaza placed on the route: metres from the route start. */
data class TollOnRoute(val plaza: TollPlaza, val alongM: Double) {
    val point get() = GeoPoint(plaza.lat, plaza.lng)
}

/** What the "toll ahead" banner says (docs/driving.md §1). */
enum class TollKind { FARE, CLOSED_ENTRY, UNKNOWN }

data class TollBanner(val toll: TollOnRoute, val kind: TollKind, val distanceM: Double, val passed: Boolean) {
    val fareMyr: Double? get() = toll.plaza.fareMyr
}

object TollAlong {
    /** How far from the route a plaza may be and still be projected onto it (fallback for servers without distances). */
    private const val MAX_OFF_ROUTE_M = 150.0

    /**
     * Along-route distance of each plaza: the server's `distanceAlongRouteM`, else the plaza projected onto the route,
     * searching forward from the previous plaza so plazas stay in route order. Plazas that cannot be placed are dropped.
     */
    fun place(tolls: List<TollPlaza>, geometry: RouteGeometry): List<TollOnRoute> {
        val out = ArrayList<TollOnRoute>()
        var fromSegment = 0
        for (t in tolls) {
            val given = t.distanceAlongRouteM
            if (given != null && given >= 0) {
                out += TollOnRoute(t, given.coerceAtMost(geometry.lengthM))
                fromSegment = geometry.segmentAt(given)
                continue
            }
            val forward = geometry.snap(GeoPoint(t.lat, t.lng), fromSegment)
            val snap = forward?.takeIf { it.distanceFromRouteM <= MAX_OFF_ROUTE_M } ?: geometry.snap(GeoPoint(t.lat, t.lng))
            if (snap == null || snap.distanceFromRouteM > MAX_OFF_ROUTE_M) continue
            out += TollOnRoute(t, snap.distanceAlongM)
            fromSegment = snap.segmentIndex
        }
        return out.sortedBy { it.alongM }
    }

    fun kind(p: TollPlaza): TollKind = when {
        p.system == "closed_entry" -> TollKind.CLOSED_ENTRY
        p.fareMyr != null -> TollKind.FARE
        else -> TollKind.UNKNOWN
    }
}

/**
 * Per-drive toll state: when to raise the banner, when to speak (once per plaza), and the running total.
 * Pure: feed it the along-route distance, speed and time of each fix.
 */
class TollTracker(val plazas: List<TollOnRoute>) {
    constructor(route: Route, geometry: RouteGeometry) : this(TollAlong.place(route.tolls, geometry))

    data class Update(val banner: TollBanner?, val speak: TollOnRoute?, val paidMyr: Double, val passed: Int)

    private val triggered = HashSet<Int>()
    private val passedAt = HashMap<Int, Long>()
    private var paid = 0.0
    private var first = true

    val paidMyr: Double get() = paid

    fun update(alongM: Double, speedKmh: Double, nowMs: Long): Update {
        var speak: TollOnRoute? = null
        if (first) {
            first = false
            // Plazas already behind at the first fix were not driven through on this route: not paid, not announced.
            plazas.forEachIndexed { i, t -> if (t.alongM < alongM - BEHIND_AT_START_M) { passedAt[i] = Long.MIN_VALUE / 2; triggered += i } }
        }
        plazas.forEachIndexed { i, t ->
            val ahead = t.alongM - alongM
            if (ahead <= 0 && i !in passedAt) {
                passedAt[i] = nowMs
                paid += t.plaza.fareMyr ?: 0.0
            }
            if (i !in triggered && i !in passedAt && ahead <= triggerM(speedKmh)) {
                triggered += i
                speak = speak ?: t
            }
        }
        // The banner: the nearest triggered plaza still ahead, else one passed less than 10 s ago.
        val ahead = plazas.indices.firstOrNull { it in triggered && it !in passedAt }
        val recent = plazas.indices.lastOrNull { i -> passedAt[i]?.let { nowMs - it < HIDE_AFTER_PASS_MS } == true && i in triggered }
        val idx = ahead ?: recent
        val banner = idx?.let { i ->
            val t = plazas[i]
            TollBanner(t, TollAlong.kind(t.plaza), (t.alongM - alongM).coerceAtLeast(0.0), passed = i in passedAt)
        }
        return Update(banner, speak, paid, passedAt.size)
    }

    companion object {
        const val TRIGGER_M = 1_000.0
        const val TRIGGER_SLOW_M = 500.0
        const val SLOW_KMH = 60.0
        const val HIDE_AFTER_PASS_MS = 10_000L
        const val BEHIND_AT_START_M = 50.0

        fun triggerM(speedKmh: Double) = if (speedKmh < SLOW_KMH) TRIGGER_SLOW_M else TRIGGER_M
    }
}

/** Toll wording for the banner, voice, trip bar and car screen (BM / EN), from docs/driving.md §1. */
object TollText {
    private val prefixes = listOf("plaza tol ", "plaza tol", "toll plaza ", "tol ", "toll ")
    private val suffixes = listOf(" toll plaza", " toll", " plaza tol")

    /** "Plaza Tol Sungai Besi" → "Sungai Besi". */
    fun shortName(name: String): String {
        var n = name.trim()
        prefixes.firstOrNull { n.lowercase().startsWith(it) }?.let { n = n.substring(it.length).trim() }
        suffixes.firstOrNull { n.lowercase().endsWith(it) }?.let { n = n.substring(0, n.length - it.length).trim() }
        return n
    }

    /** "Tol Sungai Besi" / "Sungai Besi toll". */
    fun title(p: TollPlaza, lang: Lang): String {
        val n = shortName(p.name)
        return when {
            n.isEmpty() -> if (lang == Lang.MS) "Tol" else "Toll"
            lang == Lang.MS -> "Tol $n"
            else -> "$n toll"
        }
    }

    /** Banner second line: "900 m di hadapan · RM 2.10", "Tol masuk · bayar di tol keluar", "Tol di hadapan · harga tidak diketahui". */
    fun detail(b: TollBanner, lang: Lang): String {
        val ms = lang == Lang.MS
        val dist = if (b.passed) null else Formatters.navDistance(b.distanceM) + if (ms) " di hadapan" else " ahead"
        return when (b.kind) {
            TollKind.FARE -> listOfNotNull(dist, TollBadge.rm(b.fareMyr ?: 0.0)).joinToString(" · ")
            TollKind.CLOSED_ENTRY -> listOfNotNull(if (ms) "Tol masuk" else "Toll entry", dist, if (ms) "bayar di tol keluar" else "pay at the exit").joinToString(" · ")
            TollKind.UNKNOWN -> listOfNotNull(if (ms) "Tol di hadapan" else "Toll ahead", dist?.takeIf { b.distanceM > 0 }, if (ms) "harga tidak diketahui" else "fare unknown")
                .distinct().joinToString(" · ")
        }
    }

    /** Car alert subtitle: "900 m · RM 2.10". */
    fun carDetail(b: TollBanner, lang: Lang): String {
        val ms = lang == Lang.MS
        val dist = Formatters.navDistance(b.distanceM)
        return when (b.kind) {
            TollKind.FARE -> "$dist · ${TollBadge.rm(b.fareMyr ?: 0.0)}"
            TollKind.CLOSED_ENTRY -> "$dist · " + if (ms) "bayar di tol keluar" else "pay at the exit"
            TollKind.UNKNOWN -> "$dist · " + if (ms) "harga tidak diketahui" else "fare unknown"
        }
    }

    /** "Tol Sungai Besi di hadapan, dua ringgit sepuluh sen." / "Sungai Besi toll ahead, two ringgit ten." */
    fun spoken(t: TollOnRoute, lang: Lang): String {
        val p = t.plaza
        val ms = lang == Lang.MS
        val n = shortName(p.name)
        return when (TollAlong.kind(p)) {
            TollKind.CLOSED_ENTRY -> when {
                ms && n.isEmpty() -> "Tol masuk di hadapan."
                ms -> "Tol masuk $n di hadapan."
                n.isEmpty() -> "Toll entry ahead."
                else -> "$n toll entry ahead."
            }
            TollKind.FARE -> "${title(p, lang)} ${if (ms) "di hadapan" else "ahead"}, ${MoneyWords.say(p.fareMyr ?: 0.0, lang)}."
            TollKind.UNKNOWN -> "${title(p, lang)} ${if (ms) "di hadapan" else "ahead"}."
        }
    }

    /** Trip bar: "Tol setakat ini RM 2.10 · anggaran RM 9.35" / "Tolls so far RM 2.10 · estimate from RM 4.10". */
    fun tripLine(paidMyr: Double, route: Route, carriedEstimateMyr: Double = 0.0, lang: Lang): String? {
        if (route.tolls.isEmpty() && !route.hasTolls && paidMyr == 0.0) return null
        val ms = lang == Lang.MS
        val so = (if (ms) "Tol setakat ini " else "Tolls so far ") + TollBadge.rm(paidMyr)
        val est = route.tollEstimateMyr?.let { it + carriedEstimateMyr }
        val tail = when {
            est == null -> null
            route.tollFareComplete -> (if (ms) "anggaran " else "estimate ") + TollBadge.rm(est)
            else -> (if (ms) "anggaran dari " else "estimate from ") + TollBadge.rm(est)
        }
        return listOfNotNull(so, tail).joinToString(" · ")
    }
}

/** Ringgit and sen in words, for the voice ("dua ringgit sepuluh sen" / "two ringgit ten"). */
object MoneyWords {
    fun say(myr: Double, lang: Lang): String {
        val totalSen = Math.round(myr * 100)
        val rm = (totalSen / 100).toInt()
        val sen = (totalSen % 100).toInt()
        return if (lang == Lang.MS) {
            when {
                rm == 0 && sen == 0 -> "percuma"
                rm == 0 -> "${ms(sen)} sen"
                sen == 0 -> "${ms(rm)} ringgit"
                else -> "${ms(rm)} ringgit ${ms(sen)} sen"
            }
        } else {
            when {
                rm == 0 && sen == 0 -> "free"
                rm == 0 -> "${en(sen)} sen"
                sen == 0 -> "${en(rm)} ringgit"
                else -> "${en(rm)} ringgit ${en(sen)}"
            }
        }
    }

    private val msOnes = listOf("kosong", "satu", "dua", "tiga", "empat", "lima", "enam", "tujuh", "lapan", "sembilan")

    fun ms(n: Int): String = when {
        n < 10 -> msOnes[n]
        n == 10 -> "sepuluh"
        n == 11 -> "sebelas"
        n < 20 -> "${msOnes[n - 10]} belas"
        n < 100 -> (if (n / 10 == 1) "sepuluh" else "${msOnes[n / 10]} puluh") + if (n % 10 > 0) " ${msOnes[n % 10]}" else ""
        n < 1000 -> (if (n / 100 == 1) "seratus" else "${msOnes[n / 100]} ratus") + if (n % 100 > 0) " ${ms(n % 100)}" else ""
        else -> n.toString()
    }

    private val enSmall = listOf("zero", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten",
        "eleven", "twelve", "thirteen", "fourteen", "fifteen", "sixteen", "seventeen", "eighteen", "nineteen")
    private val enTens = listOf("", "", "twenty", "thirty", "forty", "fifty", "sixty", "seventy", "eighty", "ninety")

    fun en(n: Int): String = when {
        n < 20 -> enSmall[n]
        n < 100 -> enTens[n / 10] + if (n % 10 > 0) "-${enSmall[n % 10]}" else ""
        n < 1000 -> "${enSmall[n / 100]} hundred" + if (n % 100 > 0) " ${en(n % 100)}" else ""
        else -> n.toString()
    }
}
