package my.gimano.app.nav

import my.gimano.app.core.geo.GeoPoint
import my.gimano.app.core.geo.Polyline
import my.gimano.app.core.nav.CameraMode
import my.gimano.app.core.nav.Easer
import my.gimano.app.core.nav.HeadingFilter
import my.gimano.app.core.nav.PuckAnimator
import my.gimano.app.core.nav.RouteGeometry
import my.gimano.app.core.nav.TinjauPlanner
import my.gimano.app.core.nav.TinjauZoom

/**
 * Steady arrow + camera for one map view (phone or car surface), docs/driving.md §2–3. Fed every navigation state;
 * asked for a [Frame] on every display frame. The camera follows the animated puck (no per-fix camera animations),
 * and zoom / tilt / arrow height ease to the controller's mode. Pure: callers pass the clock.
 */
class DriveRenderer {
    data class Frame(
        val point: GeoPoint, val bearing: Double, val zoom: Double, val tilt: Double,
        /** Where the arrow sits, as a fraction of the map height from the top. */
        val anchorY: Double, val accuracyM: Double?, val mode: CameraMode?,
    )

    private var routeId: String? = null
    private var geometry: RouteGeometry? = null
    private var animator = PuckAnimator(null)
    private val heading = HeadingFilter()
    private val zoom = Easer(15.0)
    private val tilt = Easer(0.0)
    private val anchor = Easer(0.5)
    private var lastFixMs: Long? = null
    private var mode: CameraMode? = null
    private var modeKey: String? = null
    private var driveKey: java.time.Instant? = null
    private var started = false
    private var fallbackBearing = 0.0
    private var accuracyM: Double? = null
    private var pendingTinjau: Pair<Double, GeoPoint>? = null
    private var motorised = true
    private var hasProgress = false

    fun onState(s: NavState, nowMs: Long) {
        if (!s.active) { reset(); return }
        // A new drive (not a reroute) starts from scratch: no heading or camera carried over from the last one.
        val drive = s.startedAt
        if (drive != driveKey) { reset(); driveKey = drive }
        val route = s.route
        if (route?.id != routeId) {
            routeId = route?.id
            geometry = route?.let { runCatching { RouteGeometry(Polyline.decode(it.polyline)) }.getOrNull() }
            animator = PuckAnimator(geometry)
            lastFixMs = null
        }
        motorised = s.mode.isMotorised
        hasProgress = s.progress != null
        accuracyM = s.accuracyM
        fallbackBearing = s.puckBearing
        val fix = s.fix
        val puck = s.puck ?: fix?.point
        if (fix != null && puck != null && fix.timeMs != lastFixMs) {
            lastFixMs = fix.timeMs
            animator.onFix(puck, s.puckAlongM, (fix.speedMps ?: 0f).toDouble(), s.nextManeuverAlongM, nowMs)
        }
        val target = s.camera
        val newMode = target?.mode
        val key = newMode?.name ?: if (hasProgress) "progress" else "none"
        if (key != modeKey || !started) {
            val (z, t, a) = when {
                target != null -> Triple(target.zoom, target.tilt, target.anchorY)
                !hasProgress -> Triple(15.0, 0.0, 0.5)
                motorised -> Triple(CameraMode.PERLAHAN.zoom, CameraMode.PERLAHAN.tilt, CameraMode.PERLAHAN.anchorY)
                else -> Triple(17.5, 45.0, 0.66)
            }
            val dur = when {
                newMode == CameraMode.TINJAU -> TinjauPlanner.OUT_MS
                mode == CameraMode.TINJAU -> TinjauPlanner.BACK_MS
                else -> MODE_EASE_MS
            }
            if (!started) { zoom.jump(z); tilt.jump(t); anchor.jump(a) } else {
                zoom.set(z, dur, nowMs); tilt.set(t, dur, nowMs); anchor.set(a, dur, nowMs)
            }
            // Tinjau's zoom depends on the map size: fitted on the next frame.
            pendingTinjau = target?.tinjau?.let { it.distanceM to it.problem.start }
            mode = newMode
            modeKey = key
            started = puck != null
        }
    }

    fun frame(nowMs: Long, mapHeightDp: Double): Frame? {
        val pose = animator.pose(nowMs) ?: return null
        pendingTinjau?.let { (dist, _) ->
            pendingTinjau = null
            val z = TinjauZoom.fit(dist, pose.point.lat, mapHeightDp, CameraMode.TINJAU.anchorY, CameraMode.BANDAR.zoom)
            zoom.set(z, TinjauPlanner.OUT_MS, nowMs)
        }
        val g = geometry
        val target = if (pose.alongM != null && g != null) g.bearingAhead(pose.alongM, 20.0) else fallbackBearing
        val b = heading.update(target, nowMs)
        return Frame(pose.point, b, zoom.value(nowMs), tilt.value(nowMs), anchor.value(nowMs), accuracyM, mode)
    }

    fun reset() {
        routeId = null; geometry = null; animator = PuckAnimator(null); heading.reset()
        lastFixMs = null; mode = null; modeKey = null; started = false; pendingTinjau = null
    }

    companion object {
        const val MODE_EASE_MS = 2_000L
    }
}
