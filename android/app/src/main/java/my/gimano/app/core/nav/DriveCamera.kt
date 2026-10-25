package my.gimano.app.core.nav

import my.gimano.app.core.format.Formatters
import my.gimano.app.core.format.Lang
import my.gimano.app.core.geo.GeoMath
import my.gimano.app.core.geo.GeoPoint
import my.gimano.app.data.model.Route
import kotlin.math.abs
import kotlin.math.cos
import kotlin.math.exp
import kotlin.math.ln
import kotlin.math.roundToInt

/**
 * docs/driving.md §2: one camera controller, five modes. Priority Simpang > Tinjau > speed modes.
 * [anchorY] = where the arrow sits, as a fraction of the map height from the top (lower when more road is shown).
 */
enum class CameraMode(val zoom: Double, val tilt: Double, val anchorY: Double) {
    SIMPANG(17.2, 55.0, 0.62),
    PERLAHAN(16.5, 50.0, 0.64),
    BANDAR(16.0, 50.0, 0.68),
    LEBUH_RAYA(15.2, 50.0, 0.72),
    TINJAU(12.5, 30.0, 0.76),
}

/** A problem ahead the Tinjau camera shows: a jam (traffic level ≥ 3) or a closure/accident/hazard alert. */
data class Problem(
    val key: String,
    /** "jam", "closure", "accident", "hazard". */
    val kind: String,
    val startAlongM: Double,
    val lengthM: Double?,
    val start: GeoPoint,
)

/** Shown while the Tinjau camera is out: "Sesak 4.8 km di hadapan · 1.2 km panjang · +6 min". */
data class TinjauInfo(val problem: Problem, val distanceM: Double, val delayS: Double?, val startedAtMs: Long)

/** What the per-frame renderer eases towards. [focus] (Tinjau): the point the zoom must keep in view. */
data class CameraTarget(val mode: CameraMode, val tinjau: TinjauInfo? = null) {
    val zoom get() = mode.zoom
    val tilt get() = mode.tilt
    val anchorY get() = mode.anchorY
}

/** Speed modes with 5 s dwell and ±5 km/h hysteresis (Perlahan ↔ Bandar at 35/25, Bandar ↔ Lebuh raya at 85/75). */
class SpeedModeSelector {
    var mode: CameraMode? = null
        private set
    private var pending: CameraMode? = null
    private var pendingSinceMs = 0L

    fun update(speedKmh: Double, nowMs: Long): CameraMode {
        val cur = mode ?: return initial(speedKmh).also { mode = it }
        val want = when (cur) {
            CameraMode.LEBUH_RAYA -> when { speedKmh <= 25 -> CameraMode.PERLAHAN; speedKmh <= 75 -> CameraMode.BANDAR; else -> cur }
            CameraMode.BANDAR -> when { speedKmh >= 85 -> CameraMode.LEBUH_RAYA; speedKmh <= 25 -> CameraMode.PERLAHAN; else -> cur }
            else -> when { speedKmh >= 85 -> CameraMode.LEBUH_RAYA; speedKmh >= 35 -> CameraMode.BANDAR; else -> CameraMode.PERLAHAN }
        }
        if (want == cur) { pending = null; return cur }
        if (pending != want) { pending = want; pendingSinceMs = nowMs }
        if (nowMs - pendingSinceMs >= DWELL_MS) { mode = want; pending = null }
        return mode!!
    }

    fun reset() { mode = null; pending = null }

    companion object {
        const val DWELL_MS = 5_000L
        fun initial(speedKmh: Double) = when { speedKmh >= 80 -> CameraMode.LEBUH_RAYA; speedKmh >= 30 -> CameraMode.BANDAR; else -> CameraMode.PERLAHAN }
    }
}

object SimpangRule {
    const val NEAR_M = 300.0
    const val NEAR_S = 15.0
    const val AFTER_M = 50.0
    private val notTurns = setOf("depart", "straight")

    fun isTurn(type: String?) = type != null && type !in notTurns

    fun secondsTo(distanceM: Double, speedKmh: Double): Double? = if (speedKmh > 3) distanceM / (speedKmh / 3.6) else null

    /** Next maneuver ≤ 300 m or ≤ 15 s away; until 50 m after it. */
    fun active(nextType: String?, distanceToNextM: Double?, prevType: String?, sincePrevM: Double?, speedKmh: Double): Boolean {
        if (isTurn(nextType) && distanceToNextM != null) {
            if (distanceToNextM <= NEAR_M) return true
            val s = secondsTo(distanceToNextM, speedKmh)
            if (s != null && s <= NEAR_S) return true
        }
        return isTurn(prevType) && prevType != "arrive" && sincePrevM != null && sincePrevM in 0.0..AFTER_M
    }
}

/** Finds jams and alerts on a route, and times the Tinjau zoom-out (once per problem). */
class TinjauPlanner {
    private val shown = HashSet<String>()
    var current: TinjauInfo? = null
        private set

    fun reset() { shown.clear(); current = null }

    /**
     * @param maneuverInS seconds to the next maneuver (Tinjau is skipped when one comes within 20 s).
     */
    fun update(problems: List<Problem>, alongM: Double, simpang: Boolean, maneuverInS: Double?, delayS: Double?, nowMs: Long): TinjauInfo? {
        current?.let { c ->
            // Simpang has priority: the zoom-out stops at once.
            if (simpang || nowMs - c.startedAtMs >= SHOW_MS) current = null
            else current = c.copy(distanceM = (c.problem.startAlongM - alongM).coerceAtLeast(0.0))
            return current
        }
        if (simpang || (maneuverInS != null && maneuverInS <= SKIP_MANEUVER_S)) return null
        val p = problems.firstOrNull { it.key !in shown && (it.startAlongM - alongM) in MIN_AHEAD_M..MAX_AHEAD_M } ?: return null
        shown += p.key
        current = TinjauInfo(p, p.startAlongM - alongM, if (p.kind == "jam") delayS else null, nowMs)
        return current
    }

    companion object {
        const val MAX_AHEAD_M = 5_000.0
        const val MIN_AHEAD_M = 150.0
        const val SKIP_MANEUVER_S = 20.0
        const val OUT_MS = 1_200L
        const val HOLD_MS = 6_000L
        const val BACK_MS = 2_000L
        /** Tinjau stays the mode for the zoom-out and the hold; the renderer eases back over [BACK_MS]. */
        const val SHOW_MS = OUT_MS + HOLD_MS

        private val alertKinds = setOf("closure", "accident", "hazard")

        /** Jams (contiguous traffic level ≥ 3) and closure / accident / hazard alerts, by distance along the route. */
        fun problems(route: Route, geometry: RouteGeometry): List<Problem> {
            val out = ArrayList<Problem>()
            val segs = route.trafficSegments.filter { it.level >= 3 }.sortedBy { it.fromIndex }
            var i = 0
            while (i < segs.size) {
                val from = segs[i].fromIndex
                var to = segs[i].toIndex
                while (i + 1 < segs.size && segs[i + 1].fromIndex <= to + 1) { i++; to = maxOf(to, segs[i].toIndex) }
                val a = geometry.distanceAtIndex(from)
                val b = geometry.distanceAtIndex(to)
                val start = geometry.points.getOrElse(from.coerceIn(0, geometry.points.lastIndex.coerceAtLeast(0))) { GeoPoint(0.0, 0.0) }
                // Keyed by place (~100 m), so the same jam is not shown again after a reroute.
                out += Problem("jam:${(start.lat * 1000).roundToInt()}:${(start.lng * 1000).roundToInt()}", "jam", a, b - a, start)
                i++
            }
            route.alerts.filter { it.type in alertKinds }.forEach { a ->
                out += Problem("alert:${a.id}", a.type, a.distanceAlongRouteM, null, GeoPoint(a.lat, a.lng))
            }
            return out.sortedBy { it.startAlongM }
        }

        /** Whole-route delay from traffic (trafficDurationS − durationS), when known and positive. */
        fun delayS(route: Route): Double? = route.trafficDurationS?.let { it - route.durationS }?.takeIf { it >= 60 }
    }
}

object TinjauText {
    fun title(kind: String, lang: Lang): String {
        val ms = lang == Lang.MS
        return when (kind) {
            "jam" -> if (ms) "Sesak" else "Traffic"
            "closure" -> if (ms) "Jalan ditutup" else "Road closed"
            "accident" -> if (ms) "Kemalangan" else "Accident"
            else -> if (ms) "Bahaya" else "Hazard"
        }
    }

    /** "Sesak 4.8 km di hadapan · 1.2 km panjang · +6 min" / "Traffic 4.8 km ahead · 1.2 km long · +6 min". */
    fun line(t: TinjauInfo, lang: Lang): String {
        val ms = lang == Lang.MS
        val parts = ArrayList<String>()
        parts += "${title(t.problem.kind, lang)} ${km(t.distanceM)} ${if (ms) "di hadapan" else "ahead"}"
        t.problem.lengthM?.takeIf { it >= 50 }?.let { parts += "${km(it)} ${if (ms) "panjang" else "long"}" }
        t.delayS?.let { parts += "+${(it / 60).roundToInt().coerceAtLeast(1)} min" }
        return parts.joinToString(" · ")
    }

    private fun km(m: Double): String = if (m < 950) Formatters.navDistance(m) else String.format(java.util.Locale.US, "%.1f km", m / 1000)
}

/**
 * The camera controller: picks the mode from what the drive is doing. Runs on each fix in the navigation session,
 * so the phone and the car screen show the same mode.
 */
class CameraModeController {
    private val speed = SpeedModeSelector()
    private val tinjau = TinjauPlanner()
    private var problems: List<Problem> = emptyList()
    private var delayS: Double? = null

    fun setRoute(route: Route, geometry: RouteGeometry) {
        problems = TinjauPlanner.problems(route, geometry)
        delayS = TinjauPlanner.delayS(route)
    }

    fun reset() { speed.reset(); tinjau.reset(); problems = emptyList() }

    fun update(
        speedKmh: Double, alongM: Double, nextType: String?, distanceToNextM: Double?, prevType: String?, sincePrevM: Double?, nowMs: Long,
    ): CameraTarget {
        val base = speed.update(speedKmh, nowMs)
        val simpang = SimpangRule.active(nextType, distanceToNextM, prevType, sincePrevM, speedKmh)
        val inS = distanceToNextM?.takeIf { SimpangRule.isTurn(nextType) }?.let { SimpangRule.secondsTo(it, speedKmh) }
        val t = tinjau.update(problems, alongM, simpang, inS, delayS, nowMs)
        return when {
            simpang -> CameraTarget(CameraMode.SIMPANG)
            t != null -> CameraTarget(CameraMode.TINJAU, t)
            else -> CameraTarget(base)
        }
    }
}

/** Zoom that keeps the arrow and the start of the problem in view (never below 12.5, never closer than [maxZoom]). */
object TinjauZoom {
    const val MIN_ZOOM = 12.5

    fun fit(distanceM: Double, lat: Double, mapHeightDp: Double, anchorY: Double, maxZoom: Double): Double {
        if (distanceM <= 0 || mapHeightDp <= 0) return maxZoom
        // Road visible above the arrow ≈ anchorY · height (dp), with a 15 % margin. MapLibre: 512 dp tiles.
        val availDp = anchorY * mapHeightDp * 0.85
        val metresPerDp = distanceM / availDp
        val z = ln(40_075_016.686 * cos(Math.toRadians(lat)) / (512.0 * metresPerDp)) / ln(2.0)
        return z.coerceIn(MIN_ZOOM, maxZoom)
    }
}

/** Snap hysteresis (§3): snap within 25 m (and heading within 60° above 10 km/h); release beyond 40 m for 3 s. */
class SnapHysteresis {
    var snapped = false
        private set
    private var farSinceMs: Long? = null

    fun update(distanceFromRouteM: Double, gpsBearing: Double?, routeBearing: Double, speedKmh: Double, nowMs: Long): Boolean {
        if (!snapped) {
            val headingOk = gpsBearing == null || speedKmh < 10 || abs(GeoMath.angleDiff(gpsBearing, routeBearing)) <= 60
            if (distanceFromRouteM <= SNAP_M && headingOk) { snapped = true; farSinceMs = null }
        } else if (distanceFromRouteM > RELEASE_M) {
            val since = farSinceMs ?: nowMs.also { farSinceMs = it }
            if (nowMs - since >= RELEASE_AFTER_MS) { snapped = false; farSinceMs = null }
        } else farSinceMs = null
        return snapped
    }

    fun reset() { snapped = false; farSinceMs = null }

    companion object {
        const val SNAP_M = 25.0
        const val RELEASE_M = 40.0
        const val RELEASE_AFTER_MS = 3_000L
    }
}

/** Heading low-pass (time constant ~0.4 s) with the turn rate capped at 90°/s. */
class HeadingFilter(private val maxRateDegPerS: Double = 90.0, private val tauS: Double = 0.4) {
    var value: Double? = null
        private set
    private var lastMs = 0L

    fun update(target: Double, nowMs: Long): Double {
        val v = value
        if (v == null) { value = norm(target); lastMs = nowMs; return value!! }
        val dt = ((nowMs - lastMs).coerceAtLeast(0)) / 1000.0
        lastMs = nowMs
        val diff = GeoMath.angleDiff(v, target)
        val alpha = 1 - exp(-dt / tauS)
        val maxStep = maxRateDegPerS * dt
        val step = (diff * alpha).coerceIn(-maxStep, maxStep)
        value = norm(v + step)
        return value!!
    }

    fun reset() { value = null }

    private fun norm(d: Double) = ((d % 360) + 360) % 360
}

/**
 * The one animated puck position (§3). Each fix starts an interpolation from where the puck is drawn now to the new
 * position, lasting the measured fix interval (0.3–1.2 s); along the route line when snapped. With no new fix it
 * keeps moving along the route at the last speed for up to 1 s, never past [maxAlongM] (the next maneuver), then holds.
 */
class PuckAnimator(private val geometry: RouteGeometry?) {
    data class Pose(val point: GeoPoint, val alongM: Double?)

    private var fromAlong: Double? = null
    private var toAlong: Double? = null
    private var fromPoint: GeoPoint? = null
    private var toPoint: GeoPoint? = null
    private var startMs = 0L
    private var durationMs = 1_000L
    private var lastFixMs: Long? = null
    private var speedMps = 0.0
    private var maxAlongM = Double.MAX_VALUE

    val hasPose get() = toPoint != null || toAlong != null

    fun onFix(point: GeoPoint, alongM: Double?, speedMps: Double, maxAlongM: Double?, nowMs: Long) {
        val cur = pose(nowMs)
        val interval = lastFixMs?.let { nowMs - it } ?: 1_000L
        lastFixMs = nowMs
        durationMs = interval.coerceIn(MIN_MS, MAX_MS)
        this.speedMps = speedMps.coerceAtLeast(0.0)
        this.maxAlongM = maxAlongM ?: Double.MAX_VALUE
        startMs = nowMs
        if (alongM != null && geometry != null && cur?.alongM != null) {
            val back = cur.alongM - alongM
            // Small backward GPS jitter: hold rather than drive backwards. A big jump (re-snap) moves at once.
            fromAlong = if (back > JUMP_M || -back > JUMP_M) alongM else cur.alongM
            toAlong = if (back in 0.0..JUMP_M) cur.alongM else alongM
            fromPoint = null; toPoint = null
        } else if (alongM != null && geometry != null) {
            fromAlong = alongM; toAlong = alongM; fromPoint = null; toPoint = null
        } else {
            val from = cur?.point ?: point
            fromPoint = if (GeoMath.distanceM(from, point) > JUMP_M) point else from
            toPoint = point
            fromAlong = null; toAlong = null
        }
    }

    fun pose(nowMs: Long): Pose? {
        val g = geometry
        val fa = fromAlong
        val ta = toAlong
        if (fa != null && ta != null && g != null) {
            val t = (nowMs - startMs).toDouble() / durationMs
            val along = if (t <= 1.0) fa + (ta - fa) * t.coerceAtLeast(0.0) else {
                // Dead reckoning for up to 1 s past the expected fix, never past the next maneuver.
                val extraS = ((nowMs - startMs - durationMs).coerceAtMost(EXTRAPOLATE_MS)) / 1000.0
                (ta + speedMps * extraS).coerceAtMost(maxOf(ta, maxAlongM))
            }
            return Pose(g.pointAt(along).first, along)
        }
        val fp = fromPoint ?: return null
        val tp = toPoint ?: return null
        val t = ((nowMs - startMs).toDouble() / durationMs).coerceIn(0.0, 1.0)
        return Pose(GeoMath.lerp(fp, tp, t), null)
    }

    companion object {
        const val MIN_MS = 300L
        const val MAX_MS = 1_200L
        const val EXTRAPOLATE_MS = 1_000L
        const val JUMP_M = 150.0
    }
}

/** Eases a value from where it is to a new target over a duration (smoothstep). */
class Easer(initial: Double) {
    private var from = initial
    private var to = initial
    private var startMs = 0L
    private var durationMs = 0L
    val target get() = to

    fun set(target: Double, durationMs: Long, nowMs: Long) {
        if (target == to) return
        from = value(nowMs); to = target; startMs = nowMs; this.durationMs = durationMs
    }

    fun jump(v: Double) { from = v; to = v; durationMs = 0 }

    fun value(nowMs: Long): Double {
        if (durationMs <= 0) return to
        val t = ((nowMs - startMs).toDouble() / durationMs).coerceIn(0.0, 1.0)
        val s = t * t * (3 - 2 * t)
        return from + (to - from) * s
    }
}
