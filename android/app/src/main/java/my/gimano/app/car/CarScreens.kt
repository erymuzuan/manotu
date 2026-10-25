package my.gimano.app.car

import androidx.car.app.CarToast
import androidx.car.app.Screen
import androidx.car.app.constraints.ConstraintManager
import androidx.car.app.model.Action
import androidx.car.app.model.ActionStrip
import androidx.car.app.model.CarColor
import androidx.car.app.model.CarIcon
import androidx.car.app.model.DateTimeWithZone
import androidx.car.app.model.Distance
import androidx.car.app.model.GridItem
import androidx.car.app.model.GridTemplate
import androidx.car.app.model.ItemList
import androidx.car.app.model.MessageTemplate
import androidx.car.app.model.Row
import androidx.car.app.model.SearchTemplate
import androidx.car.app.model.Template
import androidx.car.app.navigation.model.Maneuver
import androidx.car.app.navigation.model.MessageInfo
import androidx.car.app.navigation.model.NavigationTemplate
import androidx.car.app.navigation.model.PlaceListNavigationTemplate
import androidx.car.app.navigation.model.RoutePreviewNavigationTemplate
import androidx.car.app.navigation.model.RoutingInfo
import androidx.car.app.navigation.model.Step
import androidx.car.app.navigation.model.TravelEstimate
import androidx.core.graphics.drawable.IconCompat
import androidx.compose.material.icons.filled.Navigation
import androidx.lifecycle.lifecycleScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.launch
import my.gimano.app.R
import my.gimano.app.core.car.CarManeuvers
import my.gimano.app.core.car.CarRules
import my.gimano.app.core.format.Formatters
import my.gimano.app.core.geo.GeoMath
import my.gimano.app.core.geo.GeoPoint
import my.gimano.app.core.nav.ArrivalText
import my.gimano.app.core.nav.ManeuverFormatter
import my.gimano.app.core.nav.NavigationTracker
import my.gimano.app.core.nav.RouteGeometry
import my.gimano.app.core.safety.RestrictedZone
import my.gimano.app.data.model.CreateReportRequest
import my.gimano.app.data.model.LatLngDto
import my.gimano.app.data.model.PlaceSummary
import my.gimano.app.data.model.RouteRequest
import my.gimano.app.nav.NavDestination
import my.gimano.app.nav.NavState
import my.gimano.app.ui.common.Labels
import java.util.TimeZone


/** Not agreed on the phone yet: "Buka Manotu di telefon untuk bermula" + "Faham" (docs/driving.md §5). */
class CarAgreementScreen(private val s: ManotuCarSession) : Screen(s.carContext) {
    override fun onGetTemplate(): Template = MessageTemplate.Builder(s.str(R.string.car_open_phone))
        .setTitle(s.str(R.string.app_name))
        .setHeaderAction(Action.APP_ICON)
        .addAction(Action.Builder().setTitle(s.str(R.string.car_got_it)).setOnClickListener {
            // Agreed on the phone meanwhile → straight to "Ke mana?"; otherwise the message stays.
            if (s.agreed()) { screenManager.push(CarHomeScreen(s)); finish() } else invalidate()
        }.build())
        .build()
}

/** "Ke mana?": Rumah, Kerja, favourites and recents from this phone (≤ 6 rows while driving). */
class CarHomeScreen(private val s: ManotuCarSession) : Screen(s.carContext) {
    private var rows: List<NavDestination>? = null

    init {
        lifecycleScope.launch {
            val saved = runCatching { s.c.local.savedPlacesNow() }.getOrDefault(emptyList())
                .sortedWith(compareBy({ when (it.kind) { "home" -> 0; "work" -> 1; else -> 2 } }, { it.sortOrder }))
            val recents = runCatching { s.c.local.recents.first() }.getOrDefault(emptyList())
            val label = { k: String, n: String -> when (k) { "home" -> s.str(R.string.car_home); "work" -> s.str(R.string.car_work); else -> n } }
            val list = saved.map { NavDestination(label(it.kind, it.name), it.address, GeoPoint(it.lat, it.lng), it.placeId) } +
                recents.map { NavDestination(it.name, it.address, GeoPoint(it.lat, it.lng), it.placeId) }
            rows = list.distinctBy { "${(it.point.lat * 1e4).toInt()}:${(it.point.lng * 1e4).toInt()}" }
            invalidate()
        }
    }

    override fun onGetTemplate(): Template {
        val b = PlaceListNavigationTemplate.Builder().setTitle(s.str(R.string.car_where_to)).setHeaderAction(Action.APP_ICON)
            .setActionStrip(ActionStrip.Builder().addAction(Action.Builder().setTitle(s.str(R.string.car_search))
                .setOnClickListener { screenManager.push(CarSearchScreen(s)) }.build()).build())
        val r = rows ?: return b.setLoading(true).build()
        val limit = runCatching { carContext.getCarService(ConstraintManager::class.java).getContentLimit(ConstraintManager.CONTENT_LIMIT_TYPE_PLACE_LIST) }
            .getOrDefault(CarRules.MAX_ROWS_DRIVING).coerceAtMost(CarRules.MAX_ROWS_DRIVING)
        val items = ItemList.Builder()
        if (r.isEmpty()) items.setNoItemsMessage(s.str(R.string.car_nothing_saved))
        r.take(limit).forEach { d ->
            items.addItem(Row.Builder().setTitle(d.name).apply { d.address.takeIf { it.isNotBlank() }?.let { addText(it) } }
                .setOnClickListener { screenManager.push(CarRoutePreviewScreen(s, d)) }.build())
        }
        return b.setItemList(items.build()).build()
    }
}

/** Search (the host shows the keyboard only when parked). */
class CarSearchScreen(private val s: ManotuCarSession) : Screen(s.carContext) {
    private var results: List<PlaceSummary> = emptyList()
    private var loading = false
    private var job: Job? = null

    private fun search(q: String, now: Boolean) {
        job?.cancel()
        if (q.isBlank()) { results = emptyList(); invalidate(); return }
        job = lifecycleScope.launch {
            if (!now) delay(400)
            loading = true; invalidate()
            val here = s.myLocation.value?.point
            results = runCatching { s.c.repo.search(q, here?.lat, here?.lng, CarRules.MAX_ROWS_DRIVING) }.getOrDefault(emptyList())
            loading = false; invalidate()
        }
    }

    override fun onGetTemplate(): Template {
        val b = SearchTemplate.Builder(object : SearchTemplate.SearchCallback {
            override fun onSearchTextChanged(searchText: String) = search(searchText, false)
            override fun onSearchSubmitted(searchText: String) = search(searchText, true)
        }).setHeaderAction(Action.BACK).setShowKeyboardByDefault(true).setSearchHint(s.str(R.string.car_where_to))
        if (loading) return b.setLoading(true).build()
        val items = ItemList.Builder()
        results.take(CarRules.MAX_ROWS_DRIVING).forEach { p ->
            items.addItem(Row.Builder().setTitle(p.name).apply { p.address.takeIf { it.isNotBlank() }?.let { addText(it) } }
                .setOnClickListener {
                    screenManager.push(CarRoutePreviewScreen(s, NavDestination(p.name, p.address, GeoPoint(p.lat, p.lng), p.id.takeUnless { it.startsWith("pin:") })))
                }.build())
        }
        return b.setItemList(items.build()).build()
    }
}

/** Route choice: up to 3 routes, "Tanpa tol" / "Tol RM 2.10"; "Mula" starts the drive. */
class CarRoutePreviewScreen(private val s: ManotuCarSession, private val dest: NavDestination) : Screen(s.carContext) {
    private var failed = false

    init {
        lifecycleScope.launch {
            val here = s.myLocation.value?.point ?: runCatching { s.c.locations.lastKnown() }.getOrNull()?.point
            if (here == null) { CarToast.makeText(carContext, s.str(R.string.car_no_location), CarToast.LENGTH_LONG).show(); failed = true; invalidate(); return@launch }
            val req = RouteRequest(LatLngDto(here.lat, here.lng), dest.toDto(), vehicle = s.c.settings.current.vehicle, alternatives = 2)
            val routes = runCatching { s.c.repo.routes(req) }.getOrDefault(emptyList()).take(CarRules.MAX_ROUTES)
            if (routes.isEmpty()) failed = true else s.preview.value = CarPreview(dest, req, routes)
            invalidate()
        }
        lifecycle.addObserver(object : androidx.lifecycle.DefaultLifecycleObserver {
            override fun onDestroy(owner: androidx.lifecycle.LifecycleOwner) {
                if (s.preview.value?.destination == dest && !s.c.navigation.state.value.active) s.preview.value = null
            }
        })
    }

    override fun onGetTemplate(): Template {
        val b = RoutePreviewNavigationTemplate.Builder().setTitle(dest.name).setHeaderAction(Action.BACK)
        val p = s.preview.value?.takeIf { it.destination == dest }
        if (p == null) {
            if (!failed) return b.setLoading(true).build()
            return MessageTemplate.Builder(s.str(R.string.car_no_route)).setTitle(dest.name).setHeaderAction(Action.BACK).build()
        }
        val items = ItemList.Builder()
        p.routes.forEach { r ->
            val dur = Formatters.duration(r.effectiveDurationS, s.lang)
            items.addItem(Row.Builder().setTitle("$dur · ${Formatters.distance(r.distanceM)}")
                .addText(listOf(CarRules.tollLabel(r, s.lang), r.summary).filter { it.isNotBlank() }.joinToString(" · ")).build())
        }
        items.setSelectedIndex(p.selected)
        items.setOnSelectedListener { i -> s.preview.value = s.preview.value?.copy(selected = i); invalidate() }
        return b.setItemList(items.build())
            .setNavigateAction(Action.Builder().setTitle(s.str(R.string.car_go)).setOnClickListener { s.start(s.preview.value ?: p) }.build())
            .build()
    }
}

/** Navigating: our map on the surface, RoutingInfo + TravelEstimate from the phone's drive; Lapor and Tamat. */
class CarNavigationScreen(private val s: ManotuCarSession) : Screen(s.carContext) {
    private var nav: NavState = s.c.navigation.state.value
    private var lastStepKey: Any? = null
    private var lastInvalidateMs = 0L
    private var geometryFor: String? = null
    private var endInfo: Pair<GeoPoint, Double>? = null

    fun onNav(n: NavState) {
        if (lifecycle.currentState == androidx.lifecycle.Lifecycle.State.DESTROYED) return
        nav = n
        val key = listOf(n.progress?.nextManeuverIndex, n.rerouting, n.arrived, n.arrivedAtStop?.name)
        val now = android.os.SystemClock.elapsedRealtime()
        // NavigationTemplate updates are cheap, but once a second (or at once on a new step) is plenty.
        if (key != lastStepKey || now - lastInvalidateMs >= 1_000) {
            lastStepKey = key; lastInvalidateMs = now
            invalidate()
        }
    }

    private fun arrivalLine(): String? {
        val r = nav.route ?: return null
        if (geometryFor != r.id) {
            geometryFor = r.id
            endInfo = runCatching {
                val g = RouteGeometry(my.gimano.app.core.geo.Polyline.decode(r.polyline))
                g.points.last() to GeoMath.bearingDeg(g.pointAt(g.lengthM - 20).first, g.points.last())
            }.getOrNull()
        }
        val (end, travel) = endInfo ?: return null
        return ArrivalText.line(r.arrival, end, travel, nav.destination?.point, s.lang)
    }

    override fun onGetTemplate(): Template {
        val n = nav
        val actions = ActionStrip.Builder()
            .addAction(Action.Builder().setTitle(s.str(R.string.car_report)).setOnClickListener { screenManager.push(CarReportScreen(s)) }.build())
            .addAction(Action.Builder().setTitle(s.str(R.string.car_end)).setOnClickListener { s.c.navigation.stop() }.build())
            .build()
        val mapActions = ActionStrip.Builder().addAction(Action.PAN)
            .addAction(Action.Builder().setIcon(CarIcon.Builder(IconCompat.createWithBitmap(
                CarIcons.render(androidx.compose.material.icons.Icons.Filled.Navigation, 96, androidx.compose.ui.graphics.Color.White))).build())
                .setOnClickListener { s.surface.recenter() }.build())
            .build()
        val b = NavigationTemplate.Builder().setActionStrip(actions).setMapActionStrip(mapActions)
            .setPanModeListener { }
        // Arrived: "Anda sudah tiba", the place, and which side the entrance is (no report button in the car).
        if (n.arrived) {
            val info = MessageInfo.Builder(s.str(R.string.arrived)).setText(listOfNotNull(n.destination?.name, arrivalLine()).joinToString("\n"))
                .setImage(CarIcons.maneuver("arrive")).build()
            return b.setNavigationInfo(info).setActionStrip(ActionStrip.Builder()
                .addAction(Action.Builder().setTitle(s.str(R.string.done)).setOnClickListener { s.c.navigation.stop() }.build()).build()).build()
        }
        n.arrivedAtStop?.let { st ->
            val info = MessageInfo.Builder(s.str(R.string.arrived_at_stop, st.name)).build()
            return b.setNavigationInfo(info).setActionStrip(ActionStrip.Builder()
                .addAction(Action.Builder().setTitle(s.str(R.string.continue_drive)).setOnClickListener { s.c.navigation.continueAfterStop() }.build()).build()).build()
        }
        val p = n.progress
        val next = p?.nextManeuver
        if (p == null || next == null || n.rerouting) return b.setNavigationInfo(RoutingInfo.Builder().setLoading(true).build()).build()

        val routing = RoutingInfo.Builder().setCurrentStep(step(next.type, next), distance(p.distanceToNextM))
        p.thenManeuver?.takeIf { NavigationTracker.showThen(next, it) }?.let { routing.setNextStep(step(it.type, it)) }
        b.setNavigationInfo(routing.build())
        val arrive = DateTimeWithZone.create(System.currentTimeMillis() + (p.remainingS * 1000).toLong(), TimeZone.getDefault())
        b.setDestinationTravelEstimate(TravelEstimate.Builder(distance(p.remainingM), arrive)
            .setRemainingTimeSeconds(p.remainingS.toLong().coerceAtLeast(0)).build())
        return b.build()
    }

    private fun step(type: String, m: my.gimano.app.data.model.Maneuver): Step {
        // docs/driving.md §5: the final step says where the entrance is.
        val cue = if (type == "arrive") arrivalLine() ?: ManeuverFormatter.instruction(m, s.lang, nav.mode.wire)
            else ManeuverFormatter.instruction(m, s.lang, nav.mode.wire)
        val sb = Step.Builder(cue).setManeuver(Maneuver.Builder(CarManeuvers.type(type)).setIcon(CarIcons.maneuver(type)).build())
        ManeuverFormatter.road(m)?.let { sb.setRoad(it) }
        return sb.build()
    }

    private fun distance(m: Double): Distance = when {
        m >= 1_000 -> Distance.create(Math.round(m / 100) / 10.0, Distance.UNIT_KILOMETERS)
        else -> Distance.create(Formatters.navDistance(m).substringBefore(" ").toDoubleOrNull() ?: m, Distance.UNIT_METERS)
    }
}

/** "Lapor": six types, one tap. Never sent inside a restricted area; nothing sent without the terms agreed on the phone. */
class CarReportScreen(private val s: ManotuCarSession) : Screen(s.carContext) {
    override fun onGetTemplate(): Template {
        val items = ItemList.Builder()
        TYPES.forEach { t ->
            items.addItem(GridItem.Builder().setTitle(s.str(Labels.reportType(t))).setImage(CarIcons.report(t), GridItem.IMAGE_TYPE_LARGE)
                .setOnClickListener { send(t) }.build())
        }
        return GridTemplate.Builder().setTitle(s.str(R.string.car_report)).setHeaderAction(Action.BACK).setSingleList(items.build()).build()
    }

    private fun send(type: String) {
        val nav = s.c.navigation.state.value
        val fix = nav.fix ?: s.myLocation.value
        val p = fix?.takeIf { System.currentTimeMillis() - it.timeMs < 120_000 }?.point
        screenManager.pop()
        when {
            p == null -> s.toast(s.str(R.string.report_needs_location))
            // docs/safety.md §4 / driving.md §5: refused inside a restricted area, and nothing is sent.
            s.c.restricted.zone(p) == RestrictedZone.BLOCKED -> CarToast.makeText(carContext, s.str(R.string.restricted_report_blocked), CarToast.LENGTH_SHORT).show()
            !s.c.terms.accepted() -> s.toast(s.str(R.string.car_open_phone))
            else -> s.c.scope.launch {
                val ok = runCatching { s.c.repo.createReport(CreateReportRequest(type, null, p.lat, p.lng, fix.bearing?.toDouble(), null)) }
                    .onSuccess { r -> runCatching { my.gimano.app.data.places.ContributionLog(s.c.db.outbox()).report(r.id, r.type) } }.isSuccess
                s.toast(s.str(if (ok) R.string.report_sent else R.string.report_failed))
            }
        }
    }

    companion object {
        val TYPES = listOf("traffic", "police", "accident", "hazard", "closure", "blocked_lane")
    }
}

