package my.gimano.app.car

import android.content.Intent
import android.content.res.Configuration
import androidx.car.app.AppManager
import androidx.car.app.CarAppService
import androidx.car.app.CarToast
import androidx.car.app.Screen
import androidx.car.app.ScreenManager
import androidx.car.app.Session
import androidx.car.app.model.Action
import androidx.car.app.model.Alert
import androidx.car.app.model.CarText
import androidx.car.app.navigation.NavigationManager
import androidx.car.app.navigation.NavigationManagerCallback
import androidx.car.app.validation.HostValidator
import androidx.car.app.versioning.CarAppApiLevels
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.lifecycleScope
import androidx.lifecycle.repeatOnLifecycle
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import my.gimano.app.AppContainer
import my.gimano.app.BuildConfig
import my.gimano.app.GimanoApp
import my.gimano.app.R
import my.gimano.app.core.car.CarRules
import my.gimano.app.core.car.OncePerKey
import my.gimano.app.core.car.Odometer
import my.gimano.app.core.car.StillThereGate
import my.gimano.app.core.format.Lang
import my.gimano.app.core.geo.GeoPoint
import my.gimano.app.core.geo.Polyline
import my.gimano.app.core.nav.LastMetres
import my.gimano.app.core.nav.TinjauText
import my.gimano.app.core.nav.TollText
import my.gimano.app.core.safety.SafetyAgreement
import my.gimano.app.data.location.Fix
import my.gimano.app.data.model.Route
import my.gimano.app.data.model.RouteRequest
import my.gimano.app.nav.NavDestination
import my.gimano.app.nav.NavState
import my.gimano.app.ui.map.CameraCommand
import my.gimano.app.ui.map.MapRenderState
import my.gimano.app.ui.map.RouteDraw
import java.util.Locale

/**
 * Android Auto (docs/driving.md §5): navigation-category car app. The car screen is a second view of the drive the
 * phone runs: the same [my.gimano.app.nav.NavigationController], route, voice and on-device data. Nothing new is sent
 * anywhere; the car only reads what the phone already has (saved places, recents, the active drive).
 */
class ManotuCarAppService : CarAppService() {
    override fun createHostValidator(): HostValidator =
        if (BuildConfig.DEBUG) HostValidator.ALLOW_ALL_HOSTS_VALIDATOR
        else HostValidator.Builder(applicationContext).addAllowedHosts(androidx.car.app.R.array.hosts_allowlist_sample).build()

    override fun onCreateSession(): Session = ManotuCarSession()
}

/** A route choice on the car: up to 3 routes to [destination], [selected] drawn on top. */
data class CarPreview(val destination: NavDestination, val request: RouteRequest, val routes: List<Route>, val selected: Int = 0)

class ManotuCarSession : Session() {
    lateinit var c: AppContainer
        private set
    lateinit var surface: CarMapSurface
        private set
    val preview = MutableStateFlow<CarPreview?>(null)
    val myLocation = MutableStateFlow<Fix?>(null)
    private val decoded = HashMap<String, List<GeoPoint>>()
    private val tollAlerts = OncePerKey()
    private val tinjauAlerts = OncePerKey()
    private val stillThere = StillThereGate()
    private val odometer = Odometer()
    private var navigating = false
    private var homeCamera = false
    private var navScreen: CarNavigationScreen? = null

    val lang: Lang get() = c.lang()

    /** Strings in the app's language (the car context doesn't follow the per-app locale by itself). */
    fun str(id: Int, vararg args: Any): String {
        val conf = Configuration(carContext.resources.configuration).apply { setLocale(Locale.forLanguageTag(lang.tag)) }
        return carContext.createConfigurationContext(conf).resources.getString(id, *args)
    }

    fun agreed(): Boolean = !SafetyAgreement.needsAgreement(c.settings.current.safetyAgreedVersion)

    fun toast(text: String) = CarToast.makeText(carContext, text, CarToast.LENGTH_LONG).show()

    val screens: ScreenManager get() = carContext.getCarService(ScreenManager::class.java)
    private val navManager: NavigationManager get() = carContext.getCarService(NavigationManager::class.java)

    override fun onCreateScreen(intent: Intent): Screen {
        c = (carContext.applicationContext as GimanoApp).container
        surface = CarMapSurface(carContext, c)
        carContext.getCarService(AppManager::class.java).setSurfaceCallback(surface)
        navManager.setNavigationManagerCallback(object : NavigationManagerCallback {
            override fun onStopNavigation() = c.navigation.stop()
        })
        lifecycleScope.launch { lifecycle.repeatOnLifecycle(Lifecycle.State.STARTED) { observe() } }
        lifecycle.addObserver(object : androidx.lifecycle.DefaultLifecycleObserver {
            override fun onDestroy(owner: androidx.lifecycle.LifecycleOwner) {
                surface.release()
                if (navigating) runCatching { navManager.navigationEnded() }
            }
        })
        // docs/driving.md §5: the agreement is never shown in the car; until it is agreed on the phone, say so.
        if (!agreed()) return CarAgreementScreen(this)
        val home = CarHomeScreen(this)
        if (c.navigation.state.value.active) {
            // The car connected mid-drive: the host needs navigationStarted() before the first NavigationTemplate.
            navigating = true
            runCatching { navManager.navigationStarted() }
            screens.push(home)
            return navigationScreen()
        }
        return home
    }

    /** A new screen each time: a popped (destroyed) Screen can never be pushed again. */
    fun navigationScreen(): CarNavigationScreen = CarNavigationScreen(this).also { navScreen = it }

    private suspend fun observe() {
        launchLocation()
        // Resume following 10 s after a pan.
        lifecycleScope.launch { while (isActive) { delay(1_000); surface.tick() } }
        combine(c.navigation.state, preview, myLocation) { n, p, l -> Triple(n, p, l) }.collect { (n, p, l) ->
            surface.renderer.onState(n, android.os.SystemClock.elapsedRealtime())
            surface.content.value = content(n, p, l)
            onNav(n)
        }
    }

    private var locationJob: Job? = null
    private fun launchLocation() {
        locationJob?.cancel()
        if (!c.locations.hasPermission()) return
        locationJob = lifecycleScope.launch {
            runCatching { c.locations.lastKnown() }.getOrNull()?.let { myLocation.value = it }
            // On-device only: the car shows where you are; nothing is sent.
            runCatching { c.locations.updates(2_000).collect { myLocation.value = it } }
        }
    }

    private fun points(r: Route) = decoded.getOrPut(r.id) { runCatching { Polyline.decode(r.polyline) }.getOrDefault(emptyList()) }

    private fun content(n: NavState, p: CarPreview?, l: Fix?): CarMapContent {
        val route = n.route
        if (n.active && route != null) {
            val pts = points(route)
            return CarMapContent(
                render = MapRenderState(
                    routes = listOf(RouteDraw(route.id, pts, true, route.trafficSegments)),
                    alerts = route.alerts.map { it.toReport() },
                    tolls = route.tolls.map { GeoPoint(it.lat, it.lng) },
                    pin = n.destination?.point,
                    stops = n.stops.map { it.point },
                    lastMetres = LastMetres.lines(pts.lastOrNull(), route.arrival?.let { GeoPoint(it.lat, it.lng) }, n.destination?.point),
                    showDrivers = false, navigating = true,
                ),
                navigating = true, speedKmh = n.speedKmh,
            )
        }
        if (p != null && p.routes.isNotEmpty()) {
            val sel = p.routes.getOrNull(p.selected) ?: p.routes.first()
            val all = p.routes.flatMap { points(it) }
            return CarMapContent(
                render = MapRenderState(
                    routes = p.routes.map { RouteDraw(it.id, points(it), it.id == sel.id, it.trafficSegments) },
                    tolls = sel.tolls.map { GeoPoint(it.lat, it.lng) },
                    pin = p.destination.point, puck = l?.point, puckAccuracyM = l?.accuracyM?.toDouble(),
                    lastMetres = LastMetres.lines(points(sel).lastOrNull(), sel.arrival?.let { GeoPoint(it.lat, it.lng) }, p.destination.point),
                    showDrivers = false,
                ),
                camera = previewCamera(p, all),
            )
        }
        val here = l?.point
        return CarMapContent(
            render = MapRenderState(puck = here, puckBearing = l?.bearing ?: 0f, puckAccuracyM = l?.accuracyM?.toDouble(), showDrivers = false),
            camera = if (here != null && !homeCamera) { homeCamera = true; CameraCommand.MoveTo(here, 15.0) } else surface.content.value.camera.takeUnless { it is CameraCommand.Fit },
        )
    }

    private var lastPreviewKey: Any? = null
    private var lastPreviewCamera: CameraCommand? = null
    private fun previewCamera(p: CarPreview, all: List<GeoPoint>): CameraCommand? {
        val key = p.routes.map { it.id }
        if (key == lastPreviewKey) return lastPreviewCamera
        lastPreviewKey = key
        // The route list card covers the left of the car screen: fit the routes to the right of it.
        lastPreviewCamera = CameraCommand.Fit(all + p.destination.point, topDp = 40, bottomDp = 30, sideDp = 40, startDp = 300)
        return lastPreviewCamera
    }

    /** Session-wide reactions to the drive: car navigation state, screens, alerts. */
    private fun onNav(n: NavState) {
        if (n.active && !navigating) {
            navigating = true
            homeCamera = false
            tollAlerts.reset(); tinjauAlerts.reset(); stillThere.reset(); odometer.reset()
            runCatching { navManager.navigationStarted() }
            preview.value = null
            if (screens.top !is CarNavigationScreen) screens.push(navigationScreen())
        } else if (!n.active && navigating) {
            navigating = false
            runCatching { navManager.navigationEnded() }
            if (screens.top is CarNavigationScreen) screens.popToRoot()
            homeCamera = false
        }
        if (!n.active) return
        navScreen?.onNav(n)
        if (n.arrived) return
        // Toll ahead: an 8 s alert without buttons (the voice is the phone's, through the car audio, once).
        n.toll?.takeIf { !it.passed }?.let { t ->
            if (tollAlerts.first(t.toll.plaza.plazaId.ifBlank { t.toll.alongM.toString() })) {
                alert(TollText.title(t.toll.plaza, lang), TollText.carDetail(t, lang), CarRules.TOLL_ALERT_MS)
            }
        }
        // Tinjau: the jam / closure ahead, in the alert.
        n.camera?.tinjau?.let { t ->
            if (tinjauAlerts.first(t.problem.key)) alert(TinjauText.line(t, lang), null, my.gimano.app.core.nav.TinjauPlanner.SHOW_MS)
        }
        // Masih ada? (Ya / Tiada), 8 s, at most one per 2 km.
        val odo = n.progress?.let { odometer.update(it.distanceAlongM, n.route?.id) } ?: odometer.metres
        val a = n.upcomingAlert
        val ahead = n.alertDistanceM
        if (a != null && ahead != null && carContext.carAppApiLevel >= CarAppApiLevels.LEVEL_5 && stillThere.shouldAsk(a.id, ahead, odo)) {
            val title = str(my.gimano.app.ui.common.Labels.reportType(a.type)) + " · " + my.gimano.app.core.format.Formatters.navDistance(ahead)
            val yes = Action.Builder().setTitle(str(R.string.car_yes)).setOnClickListener { vote(a.id, true) }.build()
            val no = Action.Builder().setTitle(str(R.string.car_gone)).setOnClickListener { vote(a.id, false) }.build()
            showAlert(Alert.Builder(a.id.hashCode(), CarText.create(title), CarRules.STILL_THERE_MS)
                .setSubtitle(CarText.create(str(R.string.car_still_there))).addAction(yes).addAction(no).build())
        }
    }

    private fun vote(id: String, still: Boolean) {
        val cm = carContext.getCarService(AppManager::class.java)
        runCatching { cm.dismissAlert(id.hashCode()) }
        if (!c.terms.accepted()) { toast(str(R.string.car_open_phone)); return }
        c.scope.launch { runCatching { c.repo.vote(id, still) } }
        c.navigation.dismissAlert(id)
        toast(str(R.string.thanks_vote))
    }

    private var alertSeq = 1
    private fun alert(title: String, subtitle: String?, durationMs: Long) {
        if (carContext.carAppApiLevel >= CarAppApiLevels.LEVEL_5) {
            val b = Alert.Builder(1_000 + (alertSeq++ % 1_000), CarText.create(title), durationMs)
            subtitle?.let { b.setSubtitle(CarText.create(it)) }
            showAlert(b.build())
        } else toast(listOfNotNull(title, subtitle).joinToString(" · "))
    }

    private fun showAlert(a: Alert) = runCatching { carContext.getCarService(AppManager::class.java).showAlert(a) }

    /** Starts the drive chosen on the car (route choice → "Mula"). Shares the phone's navigation session. */
    fun start(p: CarPreview) {
        if (!agreed()) { toast(str(R.string.car_open_phone)); return }
        val route = p.routes.getOrNull(p.selected) ?: return
        val simulate = c.repo.isDemo || c.settings.current.simulateDrive
        c.navigation.start(route.copy(vehicle = route.vehicle ?: p.request.vehicle), p.destination, p.request, simulate)
        // docs/driving.md §5: no reminder card in the car; a toast at the start when the reminder is on.
        if (c.settings.current.safetyReminderEnabled) CarToast.makeText(carContext, str(R.string.safety_banner), CarToast.LENGTH_LONG).show()
        if (!p.destination.eventStop) c.scope.launch {
            runCatching { c.local.recordRecent(p.destination.name, p.destination.address, p.destination.point.lat, p.destination.point.lng, p.destination.placeId) }
        }
    }
}
