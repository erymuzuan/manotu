package my.gimano.app.nav

import my.gimano.app.core.GLog
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import kotlinx.coroutines.withTimeoutOrNull
import my.gimano.app.BuildConfig
import my.gimano.app.core.format.Lang
import my.gimano.app.core.geo.GeoPoint
import my.gimano.app.core.nav.LocationBatcher
import my.gimano.app.core.nav.ManeuverFormatter
import my.gimano.app.core.nav.NavProgress
import my.gimano.app.core.nav.NavigationTracker
import my.gimano.app.core.nav.OffRouteDetector
import my.gimano.app.core.nav.PuckPlacement
import my.gimano.app.core.nav.VoicePromptPlanner
import my.gimano.app.core.nav.headingDiff
import my.gimano.app.core.trip.StopList
import my.gimano.app.core.trip.TravelMode
import my.gimano.app.data.location.DriveSimulator
import my.gimano.app.data.location.Fix
import my.gimano.app.data.model.*
import my.gimano.app.data.repo.GimanoRepository
import my.gimano.app.data.settings.SoundMode
import java.time.Instant

data class NavDestination(
    val name: String, val address: String, val point: GeoPoint, val placeId: String?,
    /** A stop of an imported event (docs/events.md §7.7): the routing request carries its coordinates only, never its label. */
    val eventStop: Boolean = false,
    /** For an event stop: which event and stop, so a changed plan can warn the driver (never sent anywhere). */
    val eventId: String? = null,
    val stopId: String? = null,
) {
    fun toDto() = if (eventStop) LatLngDto(point.lat, point.lng) else LatLngDto(point.lat, point.lng, placeId, name)
}

data class NavState(
    val active: Boolean = false,
    val route: Route? = null,
    val destination: NavDestination? = null,
    /** Remaining intermediate stops, in order. */
    val stops: List<NavDestination> = emptyList(),
    val progress: NavProgress? = null,
    val fix: Fix? = null,
    val speedKmh: Int = 0,
    val rerouting: Boolean = false,
    val arrived: Boolean = false,
    /** Set while the "Arrived at {stop}" card is showing. */
    val arrivedAtStop: NavDestination? = null,
    val upcomingAlert: AlertOnRoute? = null,
    val alertDistanceM: Double? = null,
    val simulated: Boolean = false,
    val startedAt: Instant? = null,
    val mode: TravelMode = TravelMode.CAR,
    /** Where the puck is drawn: snapped to the route when close and heading-compatible. */
    val puck: GeoPoint? = null,
    val puckBearing: Double = 0.0,
    val puckSnapped: Boolean = false,
    /** Accuracy (m) of the last fix, drawn as a circle round the puck. */
    val accuracyM: Double? = null,
    /** "Isyarat GPS lemah · ±xx m" (accuracy > 50 m for > 10 s), else null. */
    val weakGpsM: Int? = null,
    /** Complaints v1: the driver left the route at a decision point and didn't rejoin (asked about later, on the phone). */
    val deviation: my.gimano.app.core.issues.Deviation? = null,
    /** One trip (kept when a stop is added mid-drive); "Share my drive" belongs to it and ends with it. */
    val tripId: String? = null,
    /** "Toll ahead" banner (docs/driving.md §1), null when no plaza is near. */
    val toll: my.gimano.app.core.nav.TollBanner? = null,
    /** Fares of the plazas already passed on this trip (kept across reroutes and added stops). */
    val tollsPaidMyr: Double = 0.0,
    /** Paid on earlier routes of this trip (before a reroute): added to the current route's estimate. */
    val tollsCarriedMyr: Double = 0.0,
)

/**
 * Owns an active drive: consumes fixes, tracks progress across legs, speaks prompts, detects
 * off-route (→ POST /routes/{id}/reroute with nextStopIndex) and batches anonymous location
 * pings (→ POST /locations) ONLY while a drive is active.
 */
class NavigationController(
    private val scope: CoroutineScope,
    private val repo: GimanoRepository,
    private val fixSource: FixSource,
    private val voice: Speaker,
    private val service: NavServiceControl,
    private val soundMode: () -> SoundMode,
    private val langProvider: () -> Lang,
) {
    private val _state = MutableStateFlow(NavState())
    val state: StateFlow<NavState> = _state.asStateFlow()

    private var job: Job? = null
    private var tracker: NavigationTracker? = null
    private val offRoute = OffRouteDetector()
    private val deviation = my.gimano.app.core.issues.DeviationTracker()
    private var lastOnRoute: NavProgress? = null
    /** "Jalan baharu" opt-in: the last ~1.5 km driven, in memory only (never stored, sent only if the user reports a new road). */
    private val trace = my.gimano.app.core.issues.RecentTrace()

    fun recentTrace(): List<GeoPoint> = trace.points()
    private var planner = VoicePromptPlanner()
    private var tolls: my.gimano.app.core.nav.TollTracker? = null
    /** Tolls paid on earlier routes of this trip (a reroute or an added stop starts a new route). */
    private var tollsCarried = 0.0
    private val batcher = LocationBatcher()
    private val announcedAlerts = HashSet<String>()
    private val dismissedAlerts = HashSet<String>()
    private var lastRequest: RouteRequest? = null

    /** Stops of [lastRequest] already reached → `nextStopIndex` for reroutes. */
    private var stopsVisited = 0
    private val stopGate = MutableStateFlow(-1)
    /** Along-route distance where the current stop card was raised. */
    private var stopCardAlongM = 0.0

    /** Debug: the simulated drive leaves the route at the first turn and the off-route / deviation checks run on it. */
    private var simDetour = false

    /** DEBUG builds only (adb replay, see MainActivity): speed profile and start offset for the next simulated drive. */
    data class DebugSim(val cruiseKmh: Double, val startAlongM: Double = 0.0)
    var debugSim: DebugSim? = null

    fun start(
        route: Route, destination: NavDestination, request: RouteRequest?, simulate: Boolean, stops: List<NavDestination> = emptyList(), detour: Boolean = false,
        tripId: String = java.util.UUID.randomUUID().toString(),
    ) {
        // Same trip re-planned (stop added): the tolls already paid stay on the trip bar.
        val prev = _state.value
        tollsCarried = if (prev.active && prev.tripId == tripId) prev.tollsPaidMyr else 0.0
        // No idle state in between: watchers (share, notification) must not see a drive "end" when it is re-planned.
        stopInternal(flush = false, publishIdle = false)
        simDetour = detour && simulate && BuildConfig.DEBUG
        lastRequest = request
        stopsVisited = 0
        stopGate.value = -1
        val mode = TravelMode.from(route.vehicle ?: request?.vehicle)
        tracker = NavigationTracker(route)
        tolls = my.gimano.app.core.nav.TollTracker(route, tracker!!.geometry)
        planner = VoicePromptPlanner(mode.wire)
        offRoute.reset(); announcedAlerts.clear(); dismissedAlerts.clear()
        deviation.reset(); lastOnRoute = null; trace.clear()
        _state.value = NavState(active = true, route = route, destination = destination, stops = stops, simulated = simulate, startedAt = Instant.now(), mode = mode, tripId = tripId,
            tollsPaidMyr = tollsCarried, tollsCarriedMyr = tollsCarried)
        gpsQuality.reset()
        val lang = langProvider()
        val first = tracker!!.maneuvers.firstOrNull()
        if (soundMode() == SoundMode.ON && first != null) {
            voice.speak(ManeuverFormatter.spokenNow(first, lang, mode.wire), lang, flush = true)
        }
        service.start()
        job = scope.launch { fixes(route, simulate, mode).collect { onFix(it) } }
    }

    private fun fixes(route: Route, simulate: Boolean, mode: TravelMode): Flow<Fix> {
        val t = tracker!!
        return if (simulate && simDetour) {
            DriveSimulator.drive(my.gimano.app.core.issues.SimDetour.geometry(t.geometry, t.maneuvers.map { t.geometry.distanceAtIndex(it.beginShapeIndex) }), 40.0)
        } else if (simulate && BuildConfig.DEBUG && debugSim != null) {
            val d = debugSim!!
            debugSim = null
            DriveSimulator.drive(t.geometry, d.cruiseKmh, startAlongM = d.startAlongM,
                speedAt = my.gimano.app.core.nav.SimSpeedProfile(route, t).let { prof -> { along -> prof.speedAt(along, d.cruiseKmh) } })
        } else if (simulate) {
            val avg = if (route.effectiveDurationS > 0) route.distanceM / route.effectiveDurationS * 3.6 else mode.simSpeedKmh
            val speed = if (mode.isMotorised) (avg.coerceIn(25.0, 70.0) * 1.6) else mode.simSpeedKmh * 2.5
            DriveSimulator.drive(t.geometry, speed, holdAtM = t.stopAlongM, awaitResume = { k ->
                // Wait at the stop until Continue (or 45 s), like a real driver getting back in.
                withTimeoutOrNull(45_000) { stopGate.first { it >= k } }
                continueAfterStop()
            })
        } else fixSource.updates()
    }

    private val gpsQuality = my.gimano.app.core.location.GpsQuality()

    private suspend fun onFix(fix: Fix) {
        val t = tracker ?: return
        val acc = fix.accuracyM?.toDouble()
        val weak = if (fix.simulated) null else gpsQuality.onFix(acc, fix.timeMs)
        // A poor fix (> 100 m, e.g. "Approximate" location) must never snap the puck or advance the
        // instructions, but the puck stays visible: keep the last good one, or show the raw fix.
        if (!my.gimano.app.core.location.FixRules.usable(acc, fix.simulated)) {
            _state.update {
                it.copy(fix = fix, accuracyM = acc, weakGpsM = weak ?: acc?.toInt(), speedKmh = ((fix.speedMps ?: 0f) * 3.6f).toInt(),
                    puck = it.puck ?: fix.point, puckBearing = it.puckBearing, puckSnapped = it.puck != null && it.puckSnapped)
            }
            return
        }
        if (!fix.simulated || simDetour) {
            deviation.onFix(fix.point)?.let { d -> GLog.d("Nav", "deviation confirmed"); _state.update { it.copy(deviation = d) } }
            trace.add(fix.point)
        }
        val p = t.update(fix.point) ?: return
        if (p.distanceFromRouteM < 20) lastOnRoute = p
        val speed = ((fix.speedMps ?: 0f) * 3.6f).toInt()
        val lang = langProvider()
        val sound = soundMode()
        val mode = _state.value.mode.wire

        // Intermediate stop reached → "Arrived at {stop}" then continue to the next leg.
        t.stopReached(p)?.let { k ->
            val stop = _state.value.stops.getOrNull(0)
                ?: _state.value.route?.legs?.getOrNull(k)?.to?.let { NavDestination(it.name ?: "", "", GeoPoint(it.lat, it.lng), null) }
            if (stop != null) {
                stopsVisited++
                stopCardAlongM = p.distanceAlongM
                _state.update { it.copy(arrivedAtStop = stop) }
                if (sound == SoundMode.ON) voice.speak(ManeuverFormatter.arrivedAtStop(stop.name.ifBlank { if (lang == Lang.MS) "hentian" else "your stop" }, lang), lang, flush = true)
            }
        }

        val next = p.nextManeuver
        if (sound == SoundMode.ON && next != null && !p.arrived && _state.value.arrivedAtStop == null) {
            when (planner.check(p.nextManeuverIndex, p.distanceToNextM, speed.toDouble())) {
                VoicePromptPlanner.Stage.FAR, VoicePromptPlanner.Stage.NEAR ->
                    voice.speak(ManeuverFormatter.spokenApproach(next, p.distanceToNextM, lang, mode), lang)
                VoicePromptPlanner.Stage.NOW -> if (next.type != "arrive") voice.speak(ManeuverFormatter.spokenNow(next, lang, mode), lang)
                null -> Unit
            }
        }

        val alerts = _state.value.route?.alerts.orEmpty()
        val ahead = alerts
            .filter { it.id !in dismissedAlerts }
            .map { it to (it.distanceAlongRouteM - p.distanceAlongM) }
            .filter { it.second in -60.0..800.0 }
            .minByOrNull { it.second }
        if (ahead != null && sound != SoundMode.OFF && announcedAlerts.add(ahead.first.id)) {
            voice.speak(alertPhrase(ahead.first.type, lang), lang)
        }

        // Toll ahead (docs/driving.md §1): banner at 1 km (500 m below 60 km/h), spoken once per plaza in Full and
        // Alerts only, running total of the plazas passed.
        val toll = tolls?.update(p.distanceAlongM, speed.toDouble(), fix.timeMs)
        if (toll?.speak != null && sound != SoundMode.OFF && _state.value.mode.isMotorised) {
            voice.speak(my.gimano.app.core.nav.TollText.spoken(toll.speak, lang), lang)
        }

        // Traffic probes are real drivers only: a simulated drive (demo, debug) or a walk/ride would feed fake or
        // pedestrian speeds into the road-speed aggregation (docs/traffic.md) once the live server is reachable.
        if (!fix.simulated && _state.value.mode.isMotorised) batcher.offer(
            LocationPoint(fix.point.lat, fix.point.lng, speed.toDouble(), fix.bearing?.toDouble(), fix.accuracyM?.toDouble(), Instant.ofEpochMilli(fix.timeMs).toString()),
            fix.timeMs,
        )?.let { send(it) }

        val placement = PuckPlacement.place(fix.point, fix.bearing?.toDouble(), speed.toDouble(), p)
        _state.update {
            it.copy(
                puck = placement.point, puckBearing = placement.bearing, puckSnapped = placement.snapped,
                accuracyM = acc, weakGpsM = weak,
                progress = p, fix = fix, speedKmh = speed, arrived = p.arrived,
                upcomingAlert = ahead?.first, alertDistanceM = ahead?.second,
                toll = toll?.banner, tollsPaidMyr = tollsCarried + (toll?.paidMyr ?: 0.0),
            )
        }

        if (p.arrived) {
            if (sound == SoundMode.ON) voice.speak(if (lang == Lang.MS) "Anda telah tiba di destinasi" else "You have arrived at your destination", lang)
            finishTracking()
            return
        }

        // A real driver pulling away from a stop dismisses the stop card by itself.
        if (_state.value.arrivedAtStop != null && !fix.simulated && p.distanceAlongM > stopCardAlongM + 100) continueAfterStop()

        if ((!fix.simulated || simDetour) && offRoute.update(p.distanceFromRouteM, fix.accuracyM?.toDouble(), fix.timeMs, headingDiff(fix.bearing?.toDouble(), p.bearing), speed.toDouble())) {
            lastOnRoute?.let { lp ->
                val prev = t.maneuvers.getOrNull(lp.nextManeuverIndex - 1)
                val since = prev?.let { lp.distanceAlongM - t.geometry.distanceAtIndex(it.beginShapeIndex) }
                deviation.onLeftRoute(lp.distanceAlongM, lp.distanceToNextM, lp.nextManeuver?.streetName, t.geometry, since, prev?.streetName)
                GLog.d("Nav", "left route ${lp.distanceToNextM.toInt()} m before / ${since?.toInt()} m after a manoeuvre")
            }
            reroute(fix)
        }
    }

    /** Dismisses "Arrived at {stop}" and resumes the next leg. */
    fun continueAfterStop() {
        val s = _state.value
        if (s.arrivedAtStop == null) return
        _state.update { it.copy(arrivedAtStop = null, stops = it.stops.drop(1)) }
        stopGate.value = stopGate.value + 1
    }

    private fun alertPhrase(type: String, lang: Lang): String {
        val en = mapOf(
            "police" to "Police reported ahead", "accident" to "Accident reported ahead", "hazard" to "Hazard reported ahead",
            "traffic" to "Traffic jam ahead", "closure" to "Road closed ahead", "blocked_lane" to "Lane blocked ahead",
            "map_issue" to "Map issue reported ahead", "weather" to "Bad weather reported ahead", "animal" to "Animal reported ahead",
        )
        val ms = mapOf(
            "police" to "Polis dilaporkan di hadapan", "accident" to "Kemalangan dilaporkan di hadapan", "hazard" to "Bahaya dilaporkan di hadapan",
            "traffic" to "Kesesakan di hadapan", "closure" to "Jalan ditutup di hadapan", "blocked_lane" to "Lorong terhalang di hadapan",
            "map_issue" to "Isu peta dilaporkan di hadapan", "weather" to "Cuaca buruk dilaporkan di hadapan", "animal" to "Haiwan dilaporkan di hadapan",
        )
        return (if (lang == Lang.MS) ms else en)[type] ?: (if (lang == Lang.MS) "Laporan di hadapan" else "Report ahead")
    }

    private suspend fun reroute(fix: Fix) {
        val route = _state.value.route ?: return
        _state.update { it.copy(rerouting = true) }
        val lang = langProvider()
        if (soundMode() == SoundMode.ON) voice.speak(if (lang == Lang.MS) "Mengira semula laluan" else "Recalculating route", lang)
        try {
            val req = RerouteRequest(fix.point.lat, fix.point.lng, fix.bearing?.toDouble(), nextStopIndex = stopsVisited.takeIf { lastRequest?.waypoints?.isNotEmpty() == true })
            repo.reroute(route.id, req).firstOrNull()?.let { replaceRoute(it) }
        } catch (e: Exception) {
            GLog.w("Nav", "Reroute failed: ${e.javaClass.simpleName}")
        } finally {
            _state.update { it.copy(rerouting = false) }
        }
    }

    private fun replaceRoute(route: Route) {
        lastOnRoute = null
        // Along-route distances restart at the driver's position on the new route: a stop card still showing must
        // close after 100 m of driving on it (not after the old route's distance), or voice prompts stay muted.
        stopCardAlongM = 0.0
        tracker = NavigationTracker(route)
        // Plazas passed on the old route stay paid; the new route's plazas start from here.
        tollsCarried += tolls?.paidMyr ?: 0.0
        tolls = my.gimano.app.core.nav.TollTracker(route, tracker!!.geometry)
        planner = VoicePromptPlanner(_state.value.mode.wire)
        offRoute.reset()
        _state.update { it.copy(route = route, toll = null, tollsPaidMyr = tollsCarried, tollsCarriedMyr = tollsCarried) }
    }

    /** Add a stop while driving: it becomes the NEXT stop, then the trip is re-planned from here. */
    suspend fun addStop(stop: NavDestination): Boolean {
        val s = _state.value
        val dest = s.destination ?: return false
        val here = s.fix?.point ?: s.progress?.snapped ?: return false
        val stops = runCatching { StopList.insertNext(s.stops, stop) }.getOrElse { return false }
        val base = lastRequest ?: RouteRequest(LatLngDto(here.lat, here.lng), dest.toDto(), vehicle = s.mode.wire)
        val req = base.copy(origin = LatLngDto(here.lat, here.lng), waypoints = stops.map { it.toDto() }, alternatives = 0, departAt = null)
        return try {
            val r = repo.routes(req).firstOrNull() ?: return false
            // The drive may have ended (End, notification Stop, arrival) or been replaced while the route loaded:
            // never resurrect it.
            val now = _state.value
            if (!now.active || now.arrived || now.startedAt != s.startedAt) return false
            start(r, dest, req, s.simulated, stops, tripId = s.tripId ?: java.util.UUID.randomUUID().toString())
            true
        } catch (e: kotlinx.coroutines.CancellationException) {
            throw e
        } catch (e: Exception) {
            false
        }
    }

    fun dismissAlert(id: String) {
        dismissedAlerts += id
        _state.update { if (it.upcomingAlert?.id == id) it.copy(upcomingAlert = null) else it }
    }

    /** Ends the drive from any exit path (End button, Back, notification, Done, task removed). */
    fun stop() = stopInternal(flush = true)

    /**
     * Arrived: stop GPS, pings and the foreground service (and its notification) but keep the
     * final state so the UI can show the arrival card until the driver taps Done.
     */
    private fun finishTracking() {
        job?.cancel()
        job = null
        batcher.drain()?.let { send(it) }
        service.stop()
    }

    private fun stopInternal(flush: Boolean, publishIdle: Boolean = true) {
        trace.clear()
        job?.cancel()
        job = null
        voice.stop()
        if (flush) batcher.drain()?.let { send(it) }
        val wasActive = _state.value.active
        if (publishIdle) _state.value = NavState()
        if (wasActive) service.stop()
    }

    private fun send(points: List<LocationPoint>) {
        val routeId = _state.value.route?.id
        scope.launch { runCatching { repo.postLocations(LocationBatch(routeId, points)) } }
    }
}
