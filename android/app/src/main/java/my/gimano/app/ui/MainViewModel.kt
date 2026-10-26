package my.gimano.app.ui

import androidx.annotation.StringRes
import androidx.lifecycle.ViewModel
import androidx.lifecycle.ViewModelProvider
import androidx.lifecycle.viewModelScope
import kotlinx.coroutines.FlowPreview
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharedFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.collectLatest
import kotlinx.coroutines.flow.debounce
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.withTimeoutOrNull
import kotlinx.coroutines.sync.withLock
import my.gimano.app.AppContainer
import my.gimano.app.R
import my.gimano.app.core.GLog
import my.gimano.app.core.feedback.FeedbackRules
import my.gimano.app.core.format.Formatters
import my.gimano.app.core.geo.GeoMath
import my.gimano.app.core.geo.GeoPoint
import my.gimano.app.core.geo.Polyline
import my.gimano.app.core.trip.StopList
import my.gimano.app.core.trip.TravelMode
import my.gimano.app.core.trip.OriginSource
import my.gimano.app.core.trip.RouteOrigin
import my.gimano.app.core.trip.GoAction
import my.gimano.app.core.trip.StartOption
import my.gimano.app.core.trip.StartOptions
import my.gimano.app.data.live.LiveEvent
import my.gimano.app.data.local.Favorites
import my.gimano.app.data.local.LegacyMigration
import my.gimano.app.data.local.LocalHit
import my.gimano.app.data.location.Fix
import my.gimano.app.data.model.*
import my.gimano.app.data.settings.SoundMode
import my.gimano.app.nav.NavDestination
import my.gimano.app.ui.map.CameraCommand
import my.gimano.app.ui.map.VisibleBounds
import java.time.Instant
import java.time.ZoneId

enum class SearchPurpose { NAVIGATE, SET_HOME, SET_WORK, ADD_STOP, ADD_STOP_PREVIEW, ADD_FAVORITE, PLAN_DRIVE, SET_ORIGIN, ENTRANCE,
    /** A stop of the event being organised (search or map; never reverse-geocoded). */
    EVENT_STOP,
    /** The vehicle entrance of an event stop (map only). */
    EVENT_ENTRANCE }

sealed interface Screen {
    data object Home : Screen
    data class Search(val purpose: SearchPurpose = SearchPurpose.NAVIGATE) : Screen
    data object PlaceCard : Screen
    data object RoutePreview : Screen
    data object Navigating : Screen
    data object Settings : Screen
    data object Backup : Screen
    data object MyFeedback : Screen
    data object Contributions : Screen
    data object AddPlace : Screen
    data object Planned : Screen
    data object Favourites : Screen
    data object Inbox : Screen
    data object Theme : Screen
    data object Account : Screen
    /** "Pilih pada peta" (canvas CariPeta): pin fixed at the centre, the map moves underneath. */
    data class PickOnMap(val purpose: SearchPurpose = SearchPurpose.NAVIGATE) : Screen
    /** What a dropped/chosen pin can become (canvas CariPin). */
    data object PinActions : Screen
    data object About : Screen
    data object Licences : Screen
    /** Imported events (side menu "Acara"). */
    data object Events : Screen
    /** One event over the map; [stopId] selects a stop (from `manotu://event?stop=…`). */
    data class EventDetail(val id: String, val stopId: String? = null) : Screen
    /** "Acara baharu" / editing an event this phone organises (HostEditor holds the draft). */
    data object EventEdit : Screen
    /** "Kongsi jemputan" for the event in the editor. */
    data object EventShare : Screen
    /** Route builder ("Bina laluan") over the map: a route of the event in the editor, or a personal route. */
    data class RouteBuilder(val forEvent: Boolean) : Screen
    /** "Laluan saya": personal routes on this phone. */
    data object MyRoutes : Screen
    /** Settings › Keselamatan (docs/safety.md §3). */
    data object Safety : Screen
}

data class PlaceSel(
    val summary: PlaceSummary, val detail: Place? = null, val loading: Boolean = false, val savedId: String? = null,
    /** "Just for me" place from the local DB (never on the server). */
    val privatePlace: my.gimano.app.data.local.PrivatePlaceEntity? = null,
    val privatePhotos: List<java.io.File> = emptyList(),
)

data class RoutePlan(
    val destination: NavDestination,
    /** Null while the user's location is unknown (never the map centre): no routes are computed. */
    val origin: GeoPoint?,
    val originSource: my.gimano.app.core.trip.OriginSource = my.gimano.app.core.trip.OriginSource.GPS,
    /** The start the user chose (list, search or map); null for GPS. */
    val originPlace: NavDestination? = null,
    /** After ⇅ from "Lokasi semasa": the destination is where the user was (swap back restores GPS). */
    val destinationIsHere: Boolean = false,
    /** Origin within 50 m of the first target: "Anda sudah di sini", nothing to route. */
    val alreadyHere: Boolean = false,
    val stops: List<NavDestination> = emptyList(),
    val routes: List<Route> = emptyList(),
    val decoded: Map<String, List<GeoPoint>> = emptyMap(),
    val selectedId: String? = null,
    val loading: Boolean = true,
    val error: Boolean = false,
    val mode: TravelMode = TravelMode.CAR,
    val avoid: AvoidOptions = AvoidOptions(),
    val departAt: Instant? = null,
    /** Opened with one tap (Home, Work, favourite, recent, planned drive): may auto-start if the user enabled it. */
    val quickPick: Boolean = false,
    /** "Lalu juga": issues whose exclusion is ignored for this trip only. */
    val ignoredIssues: Set<String> = emptySet(),
    val countdownRunning: Boolean = false,
    /** Short trips: the user tapped "N other routes" (long trips open the list by themselves, see [RouteChoices]). */
    val listOpen: Boolean = false,
    /** "Show anyway": routes the server marked as not worth offering are drawn and listed too. */
    val showHidden: Boolean = false,
    val request: RouteRequest? = null,
    val computedAt: Instant = Instant.now(),
    /** Opened from an event's stop: back returns to that event. */
    val returnToEvent: String? = null,
) {
    val selected: Route? get() = routes.firstOrNull { it.id == selectedId } ?: routes.firstOrNull()
    /** The routes on the map and in the list. */
    val visibleRoutes: List<Route> get() = if (showHidden) routes else my.gimano.app.core.trip.RouteChoices.shown(routes)
    val listMode: Boolean get() = listOpen || my.gimano.app.core.trip.RouteChoices.listFirst(routes, mode, stops.isNotEmpty())
    /** An event stop is the destination or a stop: no "Plan this drive" (its label must not be saved). */
    val hasEventStop: Boolean get() = destination.eventStop || stops.any { it.eventStop }
    val originName: String? get() = originPlace?.name
    val goAction: GoAction get() = StartOptions.goAction(originSource, alreadyHere, selected != null && !loading && !error)
}

/** The favourite sheet: a new favourite from a place, or editing an existing one. */
data class FavoriteDraft(
    val place: PlaceSummary?,
    val editingId: String? = null,
    val kind: String = "favorite",
    val label: String = "",
    val icon: String = "star",
)

data class UiState(
    val screen: Screen = Screen.Home,
    val myLocation: Fix? = null,
    val user: User? = null,
    val saved: List<SavedPlace> = emptyList(),
    val recents: List<Recent> = emptyList(),
    val query: String = "",
    val searchViewport: String? = null,
    val results: List<PlaceSummary> = emptyList(),
    val localHits: List<LocalHit> = emptyList(),
    val searching: Boolean = false,
    val searchedOnce: Boolean = false,
    val activeCategory: String? = null,
    val place: PlaceSel? = null,
    val plan: RoutePlan? = null,
    val alerts: List<Report> = emptyList(),
    val jams: List<Pair<Jam, List<GeoPoint>>> = emptyList(),
    val drivers: List<Driver> = emptyList(),
    val selectedAlertId: String? = null,
    val reportOpen: Boolean = false,
    /** "Hazard reported · street · just now" with Details / Undo after a hold-to-report (docs/driving.md §6.4). */
    val quickReport: QuickReportCard? = null,
    /** Details for the last quick report: the report sheet opened at this type's subtypes. */
    val quickDetails: String? = null,
    val camera: CameraCommand? = null,
    val following: Boolean = true,
    val departureSlots: List<DepartureSlot>? = null,
    val navExpanded: Boolean = false,
    val confirmStop: Boolean = false,
    val favoriteSheet: FavoriteDraft? = null,
    val tollSheet: Route? = null,
    val passengerPrompt: Boolean = false,
    /** Where the add-a-place flow starts (map centre / long-press point) and the typed name. */
    val addPlaceSeed: Pair<GeoPoint, String>? = null,
    /** Private places drawn from the local DB only. */
    val privatePins: List<Pair<String, GeoPoint>> = emptyList(),
    val inbox: List<InboxItem> = emptyList(),
    /** What the user granted (Android 12+ "Approximate" breaks turn-by-turn). Re-checked on every resume. */
    val precision: my.gimano.app.core.location.LocationPrecision = my.gimano.app.core.location.LocationPrecision.PRECISE,
    /** Show the "Navigasi perlukan lokasi tepat" explainer; [PreciseAsk.beforeNav] = start the drive afterwards. */
    val askPrecise: PreciseAsk? = null,
    val correctedQuery: String? = null,
    /** The last search failed (network), as opposed to "nothing matched". */
    val searchFailed: Boolean = false,
    val suggestions: List<SearchSuggestion> = emptyList(),
    /** "cari 'x' sahaja": the user turned the spelling correction off for this query. */
    val exactSearch: Boolean = false,
    val resultSort: my.gimano.app.core.search.ResultSort = my.gimano.app.core.search.ResultSort.RELEVANT,
    val pick: PickState? = null,
    val pin: PinSel? = null,
    /** "Nak namakan tempat ini?" after arriving at an unnamed pin (once). */
    val namePin: NavDestination? = null,
    /** Nearby pending community place to confirm (shown only while parked; see VerifyPromptGate). */
    val vetPrompt: PlaceSummary? = null,
    /** Complaints v1 (docs/complaints.md): shown only once the server has /issues. */
    val issuesAvailable: Boolean = false,
    /** "Kenapa tak ikut laluan?" waiting to be asked (after arrival / when stopped). */
    val deviationAsk: my.gimano.app.core.issues.Deviation? = null,
    /** "Masih ditutup?" for an issue within 300 m while driving. */
    val stillClosed: my.gimano.app.data.model.Issue? = null,
    /** Issues about the place on the card (badges). */
    val placeIssues: List<my.gimano.app.data.model.Issue> = emptyList(),
    /** Safety agreement on screen (null = not shown). */
    val safetyAgreement: AgreementMode? = null,
    /** "Setuju dahulu untuk mula memandu" sheet. */
    val safetyNeedAgreement: Boolean = false,
    val safetyCard: SafetyCard? = null,
    /** "Pandu dengan selamat. Patuhi undang-undang jalan raya." for 5 s (started while moving). */
    val safetyBanner: Boolean = false,
    /** The map's "Kawasan larangan" sheet (tap inside a restricted area). */
    val restrictedSheet: Boolean = false,
)

data class PreciseAsk(val beforeNav: Boolean)

/** Why the safety agreement is on screen (docs/safety.md §1). */
enum class AgreementMode {
    /** App start, before the location prompt (agreedVersion < VERSION). */
    FIRST_RUN,
    /** "Baca dan setuju" from the "Setuju dahulu" sheet: on agree, navigation starts. */
    BEFORE_DRIVE,
    /** Settings › Keselamatan › "Baca semula". */
    REVIEW,
}

/** The "Pandu dengan selamat" card; [preview] = from Settings (closes without starting anything). */
data class SafetyCard(val destination: String?, val durationS: Double?, val preview: Boolean = false)

/** State of "Pilih pada peta" while the user moves the map. */
data class PickState(
    val center: GeoPoint,
    /** Address of the point under the pin (GET /geocode/reverse after the map settles). */
    val label: String? = null,
    val area: String? = null,
    /** Full reverse-geocoded address, used as the chosen point's address. */
    val address: String? = null,
    /** "Adakah ini FamilyMart (40 m)?": a known place within 50 m of the pin. */
    val nearPoi: PlaceSummary? = null,
    val loading: Boolean = false,
    /** Where back goes. */
    val returnTo: Screen = Screen.Home,
    /** Favourite being placed ("pin at the gate"), when picking for the favourite sheet. */
    val favoriteDraft: FavoriteDraft? = null,
)

/** A pin and its actions: Navigasi ke sini · Simpan · Tambah tempat · Kongsi. */
data class PinSel(val place: PlaceSummary, val etaS: Double? = null, val routeM: Double? = null)

sealed interface UiEvent {
    data class Toast(@StringRes val res: Int) : UiEvent
    /** A 2 s toast (sound mode changes while driving). */
    data class BriefToast(@StringRes val res: Int, val sound: SoundMode? = null) : UiEvent
    data class ToastText(val text: String) : UiEvent
    data class Share(val text: String) : UiEvent
    data class Dial(val phone: String) : UiEvent
    data class Web(val url: String) : UiEvent
    /** Open the feedback sheet; the root captures a screenshot of what's behind it first. */
    data class OpenFeedback(val screen: String, val routeId: String?, val placeId: String?) : UiEvent
    /** Open the planned-drive editor for this destination. */
    data class PlanDrive(
        val dest: my.gimano.app.data.planned.PlacePoint, val origin: my.gimano.app.data.planned.PlacePoint?,
        val waypoints: List<my.gimano.app.data.planned.PlacePoint>, val vehicle: String,
    ) : UiEvent
    /** Open the add-a-place flow at this point (round 3). */
    data class AddPlace(val at: GeoPoint, val name: String) : UiEvent
}

/** Default position when no fix is available yet: KL Sentral. */
val DEFAULT_POINT = GeoPoint(3.1340, 101.6865)

@OptIn(FlowPreview::class)
class MainViewModel(private val c: AppContainer) : ViewModel() {
    // Declared before the init block: refreshAccount() starts in init and can reach migrateLegacy() without
    // suspending (demo data answers at once), so the lock must already exist (startup NPE in 0.3.1-dev).
    private val migrationLock = kotlinx.coroutines.sync.Mutex()
    private var navSeenActive = false
    val container: AppContainer get() = c
    private val repo = c.repo
    private val local = c.local
    private val settings = c.settings
    val nav = c.navigation.state
    val settingsState = settings.state
    val fallbackActive = repo.fallbackActive

    private val _ui = MutableStateFlow(UiState(
        // docs/safety.md §1: after the splash and before the location prompt, once per agreement version.
        safetyAgreement = if (my.gimano.app.core.safety.SafetyAgreement.needsAgreement(c.settings.current.safetyAgreedVersion)) AgreementMode.FIRST_RUN else null,
    ))
    val ui: StateFlow<UiState> = _ui.asStateFlow()

    private val _events = MutableSharedFlow<UiEvent>(extraBufferCapacity = 8)
    val events: SharedFlow<UiEvent> = _events

    private val queryFlow = MutableStateFlow("")
    private val boundsFlow = MutableStateFlow<VisibleBounds?>(null)
    private var locationJob: Job? = null
    private var centeredOnce = false

    val isDemo: Boolean get() = repo.isDemo

    init {
        viewModelScope.launch { local.savedPlaces.collect { p -> _ui.update { it.copy(saved = p) } } }
        viewModelScope.launch { local.recents.collect { r -> _ui.update { it.copy(recents = r) } } }
        viewModelScope.launch { local.privatePlaces.collect { l -> _ui.update { it.copy(privatePins = l.map { p -> p.id to GeoPoint(p.lat, p.lng) }) } } }
        refreshAccount()
        // collectLatest: a new query cancels the one in flight, so results never lag behind typing
        // (keyboards commit a few letters at a time; queued prefix searches showed stale "no results").
        viewModelScope.launch { queryFlow.debounce(250).distinctUntilChanged().collectLatest { runSearch(it) } }
        viewModelScope.launch { boundsFlow.debounce(400).collect { b -> if (b != null) loadLive(b) } }
        viewModelScope.launch {
            while (isActive) {
                delay(45_000)
                if (repo.fallbackActive.value && !settings.current.demoMode && repo.probeRemote()) {
                    c.liveHub.start(); refreshAccount()
                }
                boundsFlow.value?.let { loadLive(it) }
                c.issues.reprobeIfUnknown()   // started offline: show complaints once the server answers
                c.restricted.refresh()   // daily at most (every 30 min while there is no data); no request otherwise
                runCatching { c.feedback.retryDue() }
                runCatching { c.placeDrafts.retryQueued() }   // B6: places saved offline go out when the server answers
            }
        }
        viewModelScope.launch { c.liveHub.events.collect(::onLiveEvent) }
        // A crash reported after the route was calculated still reaches this trip (matched on the phone only).
        viewModelScope.launch {
            _ui.map { it.alerts }.distinctUntilChanged().collect { list -> c.navigation.setLiveAlerts(list.filterNot { it.id in ownReportIds }) }
        }
        viewModelScope.launch {
            c.navigation.state.collect { s ->
                // Arrived at an unnamed pin → "Nak namakan tempat ini?" once.
                val pd = pinDestination
                if (s.arrived && pd != null && s.destination != null && !s.destination.eventStop && GeoMath.distanceM(pd, s.destination.point) < 30) {
                    pinDestination = null
                    _ui.update { it.copy(namePin = s.destination) }
                }
                // A drive started on the car screen (Android Auto) while the phone shows the map: show it here too.
                if (s.active && !navSeenActive && _ui.value.screen == Screen.Home) {
                    _ui.update { it.copy(screen = Screen.Navigating, following = true, navExpanded = false) }
                }
                navSeenActive = s.active
                // The camera follows the puck on every frame in the map (DriveRenderer, docs/driving.md §2–3): no
                // camera commands per fix, which fought the puck.
            }
        }
        if (!repo.isDemo) c.liveHub.start()
        viewModelScope.launch { repo.fallbackActive.collect { if (it) c.liveHub.stop() } }
        viewModelScope.launch { c.issues.probe() }
        viewModelScope.launch { c.issues.available.collect { a -> _ui.update { it.copy(issuesAvailable = a) } } }
        viewModelScope.launch { c.navigation.state.collect(::onNavForIssues) }
    }

    fun refreshAccount() {
        viewModelScope.launch {
            runCatching { repo.ensureAuth() }.onSuccess { u -> _ui.update { it.copy(user = u) } }
                .onFailure { GLog.w("VM", "auth failed: ${it.javaClass.simpleName}") }
            migrateLegacy()
            refreshInbox()
            runCatching { c.feedback.retryDue() }
        }
    }

    /** One-time: pull any server-side favourites/recents into the device, then delete them there. */

    private suspend fun migrateLegacy() = migrationLock.withLock {
        if (settings.current.legacyMigrated || repo.isDemo) return@withLock
        val outcome = LegacyMigration(
            export = { repo.exportMyData() },
            import = { d -> local.importLegacy(d.savedPlaces, d.recents) },
            deleteRemote = { repo.deleteMyData() },
            markDone = { settings.setLegacyMigrated() },
        ).run()
        GLog.i("VM", "legacy migration: $outcome")
    }

    // --- Inbox (public-contribution news; read state kept on the device) -------------------------

    fun refreshInbox() = viewModelScope.launch {
        runCatching { repo.inbox() }.onSuccess { l -> _ui.update { it.copy(inbox = l.sortedByDescending { m -> m.createdAt }) } }
    }

    fun markInboxRead() = viewModelScope.launch { settings.markInboxRead(_ui.value.inbox.map { it.id }) }

    /** Shown under "Can't reach the server": path + status or exception type only (no query, no coordinates). */
    fun fallbackReason(): String? = repo.lastFallbackReason

    fun retryServer() {
        repo.retryRemote()
        c.liveHub.start()
        refreshAccount()
        boundsFlow.value?.let { b -> viewModelScope.launch { loadLive(b) } }
    }

    // --- Location -------------------------------------------------------------------------

    fun onLocationPermission(granted: Boolean) {
        if (!granted) {
            if (!centeredOnce) {
                centeredOnce = true
                _ui.update { it.copy(camera = CameraCommand.MoveTo(DEFAULT_POINT, 14.5, animate = false)) }
            }
            return
        }
        if (locationJob?.isActive == true) return
        locationJob = viewModelScope.launch {
            c.locations.lastKnown()?.let(::onFix)
            c.locations.updates(2_000).collect(::onFix)
        }
    }

    private fun onFix(f: Fix) {
        val prev = _ui.value.myLocation
        c.lastFix = f.point
        c.lastFixAccuracyM = f.accuracyM?.toInt()
        _ui.update { it.copy(myLocation = f) }
        // The car started moving while the safety card is open: close it and start at once with the banner.
        if (_ui.value.safetyCard?.preview == false && my.gimano.app.core.safety.SafetyReminder.isMoving(speedKmh(f))) {
            _ui.update { it.copy(safetyCard = null) }
            if (beginNavigation()) showSafetyBanner()
        }
        if (_ui.value.plan?.originSource == OriginSource.UNKNOWN && _ui.value.screen == Screen.RoutePreview) resolveOrigin()
        // A drive ended while still moving: ask "Kenapa tak ikut laluan?" once the phone is stopped.
        if (pendingDeviation != null && !nav.value.active) maybeAskDeviation(f.speedMps?.let { (it * 3.6f).toInt() } ?: 0)
        maybeAskNearby(f, prev)
        if (!centeredOnce) {
            centeredOnce = true
            _ui.update { it.copy(camera = CameraCommand.MoveTo(f.point, 14.5, animate = false)) }
        }
    }

    // ---------------------------------------------------------------- nearby verify prompt

    private val vetGate = my.gimano.app.core.vetting.VerifyPromptGate()

    private fun maybeAskNearby(f: Fix, prev: Fix?) {
        if (f.simulated) return
        val kmh = f.speedMps?.let { it * 3.6 } ?: prev?.let { p ->
            val dt = (f.timeMs - p.timeMs) / 1000.0
            if (dt in 0.5..30.0) GeoMath.distanceM(p.point, f.point) / dt * 3.6 else null
        }
        val fg = androidx.lifecycle.ProcessLifecycleOwner.get().lifecycle.currentState.isAtLeast(androidx.lifecycle.Lifecycle.State.STARTED)
        if (!vetGate.onFix(kmh, f.timeMs, nav.value.active, fg)) return
        val s = _ui.value
        if (s.screen != Screen.Home || s.vetPrompt != null || s.reportOpen) return
        vetGate.markPrompted(f.timeMs)
        viewModelScope.launch {
            val cell = my.gimano.app.core.vetting.Geohash.encode(f.point.lat, f.point.lng, 6)
            val answered = c.vetting.answered()
            val pick = runCatching { repo.pendingNearby(cell) }.getOrDefault(emptyList())
                .filter { it.id !in answered }
                .mapNotNull { p -> my.gimano.app.core.vetting.Proximity.withinM(f.point, GeoPoint(p.lat, p.lng), p.rural)?.let { p to GeoMath.distanceM(f.point, GeoPoint(p.lat, p.lng)) } }
                .minByOrNull { it.second }
                ?: return@launch
            if (_ui.value.screen == Screen.Home && !nav.value.active) _ui.update { it.copy(vetPrompt = pick.first.copy(distanceM = pick.second)) }
        }
    }

    /** Recovery code accepted by the server: refresh the profile under the restored pseudonym. */
    fun onIdentityRestored(name: String) {
        _events.tryEmit(UiEvent.ToastText(c.app.getString(R.string.recovery_restored, name)))
        refreshAccount()
    }

    fun dismissNearby(remember: Boolean) {
        val p = _ui.value.vetPrompt ?: return
        _ui.update { it.copy(vetPrompt = null) }
        if (remember) viewModelScope.launch { c.vetting.markAnswered(p.id) }
    }

    fun here(): GeoPoint = nav.value.fix?.point ?: _ui.value.myLocation?.point ?: boundsFlow.value?.center ?: DEFAULT_POINT

    fun recenter() {
        _ui.update { it.copy(following = true) }
        val s = nav.value
        val p = s.progress
        if (s.active && (p != null || s.puck != null)) {
            // Following again: the map's per-frame camera blends back to the arrow by itself.
        } else {
            _ui.update { it.copy(camera = CameraCommand.Reset2D(here(), 15.5)) }
        }
    }

    /** Height of the collapsed home sheet: the map's bottom inset on Home, so the puck is never under it. */
    private val _homeSheetDp = kotlinx.coroutines.flow.MutableStateFlow(0)
    val homeSheetDp: kotlinx.coroutines.flow.StateFlow<Int> = _homeSheetDp
    fun setHomeSheetDp(dp: Int) { _homeSheetDp.value = dp }

    /** Resting height of the place card (peek or full): the map's bottom inset there, so the pin stays visible. */
    private val _placeSheetDp = kotlinx.coroutines.flow.MutableStateFlow(0)
    val placeSheetDp: kotlinx.coroutines.flow.StateFlow<Int> = _placeSheetDp
    fun setPlaceSheetDp(dp: Int) { _placeSheetDp.value = dp }

    /** The recentre button while a place card is open: back to the pin (centred above the card), not to "me". */
    fun recenterOnPlace() {
        val p = _ui.value.place?.summary ?: return recenter()
        _ui.update { it.copy(following = false, camera = CameraCommand.MoveTo(GeoPoint(p.lat, p.lng), null)) }
    }

    /** Home panel state: Peek by default, and again after a drive ends or the app comes back. */
    private val _homeSheet = kotlinx.coroutines.flow.MutableStateFlow(my.gimano.app.ui.home.HomeSheetState.PEEK)
    val homeSheet: kotlinx.coroutines.flow.StateFlow<my.gimano.app.ui.home.HomeSheetState> = _homeSheet
    fun setHomeSheet(s: my.gimano.app.ui.home.HomeSheetState) { _homeSheet.value = s }
    fun collapseHomeSheet() = setHomeSheet(my.gimano.app.ui.home.HomeSheetState.PEEK)

    private var lastPanMs: Long? = null
    private var followResumeJob: Job? = null

    /** During navigation, follow resumes by itself 10 s after the last pan (the puck must not stay off-screen). */
    fun onUserPanned() {
        if (_ui.value.following) _ui.update { it.copy(following = false) }
        lastPanMs = System.currentTimeMillis()
        followResumeJob?.cancel()
        followResumeJob = viewModelScope.launch {
            delay(my.gimano.app.core.location.FixRules.FOLLOW_RESUME_MS)
            val s = _ui.value
            if (!s.following && s.screen == Screen.Navigating &&
                my.gimano.app.core.location.FixRules.shouldResumeFollow(lastPanMs, System.currentTimeMillis(), nav.value.active)) recenter()
        }
    }

    // --- Live map ---------------------------------------------------------------------------

    fun onCameraIdle(b: VisibleBounds) {
        if (_ui.value.screen is Screen.PickOnMap) onPickMoved(b.center)
        boundsFlow.value = b
    }

    private suspend fun loadLive(b: VisibleBounds) {
        val span = (b.maxLat - b.minLat).coerceAtMost(1.0) / 2
        val spanLng = (b.maxLng - b.minLng).coerceAtMost(1.0) / 2
        val cLat = (b.minLat + b.maxLat) / 2
        val cLng = (b.minLng + b.maxLng) / 2
        val box = VisibleBounds(cLng - spanLng, cLat - span, cLng + spanLng, cLat + span)
        c.liveHub.subscribe(box.minLng, box.minLat, box.maxLng, box.maxLat)
        runCatching { repo.live(box.minLng, box.minLat, box.maxLng, box.maxLat) }
            .onSuccess { r ->
                val jams = r.jams.mapNotNull { j -> runCatching { j to Polyline.decode(j.polyline) }.getOrNull() }
                _ui.update { it.copy(alerts = r.alerts, jams = jams, drivers = r.drivers) }
            }
            .onFailure { GLog.w("VM", "live failed: ${it.javaClass.simpleName}") }
    }

    private fun onLiveEvent(e: LiveEvent) {
        _ui.update { s ->
            when (e) {
                is LiveEvent.AlertCreated -> s.copy(alerts = s.alerts.filterNot { it.id == e.report.id } + e.report)
                is LiveEvent.AlertUpdated -> s.copy(alerts = s.alerts.map { if (it.id == e.report.id) e.report else it })
                is LiveEvent.AlertExpired -> s.copy(alerts = s.alerts.filterNot { it.id == e.reportId }, selectedAlertId = s.selectedAlertId.takeIf { it != e.reportId })
                is LiveEvent.JamUpdated -> {
                    if (e.jam.level == 0) return@update s.copy(jams = s.jams.filterNot { it.first.id == e.jam.id })
                    val pts = runCatching { Polyline.decode(e.jam.polyline) }.getOrNull() ?: return@update s
                    s.copy(jams = s.jams.filterNot { it.first.id == e.jam.id } + (e.jam to pts))
                }
            }
        }
    }

    fun selectAlert(id: String?) = _ui.update { it.copy(selectedAlertId = id) }

    /**
     * Community rules before the first public contribution (UgcTerms): true = carry on now; false = the rules are shown
     * and [retry] runs after "I agree" (or never, on "Not now").
     */
    private fun termsOk(retry: () -> Unit): Boolean {
        if (c.terms.accepted()) return true
        c.terms.require(retry)
        return false
    }

    fun vote(report: Report, stillThere: Boolean) {
        if (!termsOk { vote(report, stillThere) }) return
        viewModelScope.launch {
            runCatching { repo.vote(report.id, stillThere) }
                .onSuccess { upd -> _ui.update { s -> s.copy(alerts = s.alerts.map { if (it.id == upd.id) upd else it }) } }
            _events.tryEmit(UiEvent.Toast(R.string.thanks_vote))
            c.navigation.dismissAlert(report.id)
            _ui.update { it.copy(selectedAlertId = null) }
        }
    }

    fun dismissNavAlert(id: String) = c.navigation.dismissAlert(id)

    // --- Reports ----------------------------------------------------------------------------

    fun openReport(open: Boolean) {
        if (open && !termsOk { openReport(true) }) return
        _ui.update { it.copy(reportOpen = open) }
    }

    /** Both doors (tap drawer, hold arc) end here: the detail sheet's Report, or its 3 s auto-send. */
    fun submitReport(type: String, subtype: String?, comment: String?) {
        _ui.update { it.copy(reportOpen = false, quickDetails = null) }
        sendReport(type, subtype, comment)
    }

    // --- Reporting (docs/driving.md §6.4) ---------------------------------------------------------

    private var quickSession: my.gimano.app.core.report.QuickReportSession? = null
    private var quickAt: Pair<GeoPoint, Double?>? = null
    private var quickKey = 0L

    /** Released on an arc bubble: the detail sheet for that type (default subtype picked, auto-send in 3 s). */
    fun openReportType(type: String) {
        if (!termsOk { openReportType(type) }) return
        _ui.update { it.copy(reportOpen = false, quickDetails = type) }
    }

    /** Sends at the current position and raises the "reported" card with Undo (5 s). */
    private fun sendReport(type: String, subtype: String?, comment: String?) {
        if (!termsOk { sendReport(type, subtype, comment) }) return
        val fix = nav.value.fix ?: _ui.value.myLocation
        val p = myFreshLocation() ?: run { _events.tryEmit(UiEvent.Toast(R.string.report_needs_location)); return }
        // docs/safety.md §4: inside a restricted area (≤ blockM) a road report is never sent.
        if (reportRefusedHere(p)) return
        val now = android.os.SystemClock.elapsedRealtime()
        val session = my.gimano.app.core.report.QuickReportSession(type, now)
        quickSession = session
        quickAt = p to fix?.bearing?.toDouble()
        val key = ++quickKey
        _ui.update { it.copy(quickReport = QuickReportCard(key, type, null, now)) }
        viewModelScope.launch {
            runCatching { repo.createReport(CreateReportRequest(type, subtype, p.lat, p.lng, fix?.bearing?.toDouble(), comment?.takeIf { it.isNotBlank() })) }
                .onSuccess { r ->
                    runCatching { my.gimano.app.data.places.ContributionLog(c.db.outbox()).report(r.id, r.type) }
                    ownReportIds += r.id
                    when (val a = session.onSent(r.id)) {
                        is my.gimano.app.core.report.QuickReportSession.Action.Delete -> retractQuick(a.reportId, toast = false)
                        else -> _ui.update { s ->
                            s.copy(alerts = s.alerts.filterNot { it.id == r.id } + r,
                                quickReport = s.quickReport?.let { q -> if (q.key == key) q.copy(street = r.street, sent = true) else q })
                        }
                    }
                    if (!nav.value.active) _events.tryEmit(UiEvent.Toast(R.string.report_sent))
                }
                .onFailure { e ->
                    session.onFailed()
                    _ui.update { s -> s.copy(quickReport = s.quickReport?.takeUnless { it.key == key }) }
                    _events.tryEmit(reportError(e))
                }
        }
    }

    /** Reports this phone sent: never asked "still there?" about its own. */
    private val ownReportIds = HashSet<String>()

    /** Undo on the card: deletes the report on the server, or cancels it while it is still being sent. */
    fun undoQuickReport() {
        val s = quickSession ?: return
        _ui.update { it.copy(quickReport = null) }
        when (val a = s.undo(android.os.SystemClock.elapsedRealtime())) {
            is my.gimano.app.core.report.QuickReportSession.Action.Delete -> retractQuick(a.reportId, toast = true)
            my.gimano.app.core.report.QuickReportSession.Action.CancelPending -> _events.tryEmit(UiEvent.Toast(R.string.qr_undone))
            my.gimano.app.core.report.QuickReportSession.Action.None -> Unit
        }
    }

    private fun retractQuick(id: String, toast: Boolean) {
        viewModelScope.launch {
            runCatching { repo.deleteReport(id) }
                .onSuccess {
                    _ui.update { s -> s.copy(alerts = s.alerts.filterNot { it.id == id }) }
                    if (toast) _events.tryEmit(UiEvent.Toast(R.string.qr_undone))
                }
                .onFailure { GLog.w("Report", "undo failed: ${it.javaClass.simpleName}"); _events.tryEmit(UiEvent.Toast(R.string.qr_undo_failed)) }
        }
    }

    /** The card's 5 s ran out: the report stays. */
    fun closeQuickReport(key: Long) = _ui.update { s -> s.copy(quickReport = s.quickReport?.takeUnless { it.key == key }) }

    fun closeQuickDetails() = _ui.update { it.copy(quickDetails = null) }

    /** Restricted area (the server's own words), rate limit (429), or a plain failure. */
    private fun reportError(e: Throwable): UiEvent = when {
        e is my.gimano.app.data.repo.RestrictedAreaException -> UiEvent.ToastText(e.detail)
        e is retrofit2.HttpException && e.code() == 429 -> UiEvent.Toast(R.string.report_rate_limited)
        else -> UiEvent.Toast(R.string.report_failed)
    }

    /** True (and says so) when [p] is inside a restricted area or within its `blockM`: the report is not sent. */
    private fun reportRefusedHere(p: GeoPoint): Boolean {
        if (c.restricted.zone(p) != my.gimano.app.core.safety.RestrictedZone.BLOCKED) return false
        _events.tryEmit(UiEvent.Toast(R.string.restricted_report_blocked))
        return true
    }

    // Leaving the app pauses (cancels) the route-preview countdown; coming back probes the live server at once.
    private val lifecycleObserver: androidx.lifecycle.LifecycleEventObserver =
        androidx.lifecycle.LifecycleEventObserver { _, e ->
            when (e) {
                androidx.lifecycle.Lifecycle.Event.ON_STOP -> { cancelCountdown(); collapseHomeSheet() }
                androidx.lifecycle.Lifecycle.Event.ON_START -> if (repo.fallbackActive.value && !settings.current.demoMode) viewModelScope.launch {
                    if (repo.probeRemote()) { c.liveHub.start(); refreshAccount() }
                }
                else -> Unit
            }
        }

    init { androidx.lifecycle.ProcessLifecycleOwner.get().lifecycle.addObserver(lifecycleObserver) }

    override fun onCleared() {
        androidx.lifecycle.ProcessLifecycleOwner.get().lifecycle.removeObserver(lifecycleObserver)
        super.onCleared()
    }

    // --- Complaints v1 (docs/complaints.md) ------------------------------------------------------

    /** "Masalah jalan" from the report sheet: one tap + Hantar, at the current fix and heading. */
    fun submitRoadProblem(type: String, durationHint: String?) {
        _ui.update { it.copy(reportOpen = false) }
        val kind = my.gimano.app.core.issues.IssueSupport.roadProblemKinds[type] ?: return
        val fix = nav.value.fix ?: _ui.value.myLocation
        val p = myFreshLocation() ?: run { _events.tryEmit(UiEvent.Toast(R.string.report_needs_location)); return }
        if (reportRefusedHere(p)) return
        val heading = fix?.bearing?.toDouble() ?: nav.value.progress?.bearing
        val s = nav.value
        val route = s.route
        val prog = s.progress
        val K = my.gimano.app.data.model.IssueKind
        val payload = kotlinx.serialization.json.buildJsonObject {
            route?.id?.let { put("routeId", kotlinx.serialization.json.JsonPrimitive(it)) }
            when (kind) {
                K.TURN_NOT_ALLOWED -> if (route != null && prog != null && prog.distanceToNextM <= 200) {
                    // Where the route wanted to go: just past the next turn.
                    val g = my.gimano.app.core.nav.RouteGeometry(my.gimano.app.core.geo.Polyline.decode(route.polyline))
                    val to = g.pointAt(prog.distanceAlongM + prog.distanceToNextM + 30).first
                    put("toLat", kotlinx.serialization.json.JsonPrimitive(round5(to.lat))); put("toLng", kotlinx.serialization.json.JsonPrimitive(round5(to.lng)))
                }
                K.ODD_ROUTE -> {
                    // Ends kept coarse (2 dp ≈ 1 km) on the phone.
                    put("fromLat", kotlinx.serialization.json.JsonPrimitive(my.gimano.app.core.issues.IssueSupport.round2(p.lat)))
                    put("fromLng", kotlinx.serialization.json.JsonPrimitive(my.gimano.app.core.issues.IssueSupport.round2(p.lng)))
                    s.destination?.point?.let { d ->
                        put("toLat", kotlinx.serialization.json.JsonPrimitive(my.gimano.app.core.issues.IssueSupport.round2(d.lat)))
                        put("toLng", kotlinx.serialization.json.JsonPrimitive(my.gimano.app.core.issues.IssueSupport.round2(d.lng)))
                    }
                    route?.summary?.takeIf { it.isNotBlank() }?.let { put("chosen", kotlinx.serialization.json.JsonPrimitive(it)) }
                }
                K.NEW_ROAD -> {
                    // The user chose to send the road they are on: the last ~1.5 km (server trims 200 m at each end).
                    val t = c.navigation.recentTrace()
                    put("trace", kotlinx.serialization.json.JsonArray(t.map { q -> kotlinx.serialization.json.JsonArray(listOf(
                        kotlinx.serialization.json.JsonPrimitive(round5(q.lat)), kotlinx.serialization.json.JsonPrimitive(round5(q.lng)))) }))
                }
                else -> prog?.nextManeuver?.streetName?.takeIf { it.isNotBlank() }?.let { put("roadName", kotlinx.serialization.json.JsonPrimitive(it)) }
            }
        }
        sendIssue(CreateIssueRequest(kind, lat = round5(p.lat), lng = round5(p.lng), heading = heading, vehicle = s.mode.wire,
            durationHint = durationHint.takeIf { kind == K.ROAD_CLOSED_TEMP }, source = "report",
            payload = payload.takeIf { it.isNotEmpty() }), R.string.issue_sent)
    }

    private fun jsonOf(m: Map<String, String>?): kotlinx.serialization.json.JsonObject? =
        m?.takeIf { it.isNotEmpty() }?.let { kotlinx.serialization.json.JsonObject(it.mapValues { (_, v) -> kotlinx.serialization.json.JsonPrimitive(v) }) }

    /** Vote proximity like place vetting: my geohash-6 cell + 100/300/1000 m; null = no fix or too far. */
    private fun voteProximity(target: GeoPoint): VerifyRequest.Proximity? {
        // Only a fresh fix proves where the voter is (an old last-known position could be anywhere by now).
        val me = myFreshLocation() ?: return null
        val within = my.gimano.app.core.issues.IssueSupport.voteWithinM(GeoMath.distanceM(me, target)) ?: return null
        return VerifyRequest.Proximity(my.gimano.app.core.vetting.Geohash.encode(me.lat, me.lng, 6), within)
    }

    private fun round5(v: Double) = my.gimano.app.core.issues.IssueSupport.round5(v)

    private fun sendIssue(body: CreateIssueRequest, okMsg: Int, after: (my.gimano.app.data.model.Issue) -> Unit = {}) {
        viewModelScope.launch {
            val r = c.issues.call { createIssue(body) }
            if (r != null) {
                runCatching { my.gimano.app.data.places.ContributionLog(c.db.outbox()).report(r.id, r.kind) }
                _events.tryEmit(UiEvent.Toast(okMsg)); after(r)
            } else c.issues.takeRestricted()?.let { _events.tryEmit(UiEvent.ToastText(it)) }
                ?: _events.tryEmit(UiEvent.Toast(if (_ui.value.issuesAvailable) R.string.report_failed else R.string.issues_unavailable))
        }
    }

    private var pendingDeviation: my.gimano.app.core.issues.Deviation? = null
    private var navWasActive = false
    private var navIssues: List<my.gimano.app.data.model.Issue> = emptyList()
    private var navIssuesAt: GeoPoint? = null
    private var navIssuesMs = 0L
    private val answeredIssues = HashSet<String>()

    private fun onNavForIssues(s: my.gimano.app.nav.NavState) {
        s.deviation?.let { pendingDeviation = it }
        if (s.active) navWasActive = true
        // Ask after arrival (stopped), or once the drive has ended. Never while moving.
        if ((s.arrived || (!s.active && navWasActive)) && pendingDeviation != null) maybeAskDeviation(if (s.active) s.speedKmh else null)
        if (!s.active) { navWasActive = false; return }
        if (!_ui.value.issuesAvailable || s.arrived) return
        val me = s.fix?.point ?: return
        if (s.fix.simulated && !repo.isDemo && !debugSim()) return
        val now = System.currentTimeMillis()
        val moved = navIssuesAt?.let { GeoMath.distanceM(it, me) } ?: Double.MAX_VALUE
        if (moved > 1_500 || now - navIssuesMs > 180_000) {
            navIssuesAt = me; navIssuesMs = now
            viewModelScope.launch {
                val b = my.gimano.app.core.issues.IssueSupport.bbox(me, 2_500.0)
                c.issues.call { issuesNearby(b[0], b[1], b[2], b[3], my.gimano.app.data.model.IssueKind.road.toList()) }?.let { navIssues = it }
            }
        }
        if (_ui.value.stillClosed == null) {
            val fromRoute = s.route?.issues.orEmpty().filter { it.lat != null && it.lng != null && !it.isAvoided }
                .map { my.gimano.app.data.model.Issue(it.id, it.kind, it.subtype, it.state, it.lat!!, it.lng!!, roadName = it.road, confirmations = it.confirmations, createdAt = it.createdAt ?: "") }
            my.gimano.app.core.issues.IssueText.stillClosedCandidate(navIssues + fromRoute, me, answeredIssues)?.let { i ->
                answeredIssues += i.id   // once per issue per trip
                _ui.update { it.copy(stillClosed = i) }
            }
        }
    }

    private fun maybeAskDeviation(speedKmh: Int?) {
        val d = pendingDeviation ?: return
        if (!_ui.value.issuesAvailable || _ui.value.deviationAsk != null) return
        val st = settings.current
        val speed = speedKmh ?: _ui.value.myLocation?.speedMps?.let { (it * 3.6f).toInt() }
        if (!my.gimano.app.core.issues.DeviationPromptGate.mayAsk(st.deviationNeverAsk, st.deviationLastAsked, java.time.LocalDate.now(), speed)) return
        pendingDeviation = null
        _ui.update { it.copy(deviationAsk = d) }
    }

    /** [answer] null = closed the sheet without answering. Only the answer + the segment are sent. */
    fun answerDeviation(answer: String?, neverAgain: Boolean) {
        val d = _ui.value.deviationAsk ?: return
        _ui.update { it.copy(deviationAsk = null) }
        viewModelScope.launch { settings.setDeviationAsked(java.time.LocalDate.now().toString(), neverAgain) }
        val kind = answer?.let(my.gimano.app.core.issues.IssueSupport::deviationKind) ?: run {
            if (answer != null) _events.tryEmit(UiEvent.Toast(R.string.thanks_noted)); return
        }
        // A turn is reported at the junction with where the route wanted to go; the rest at the segment not taken.
        val turn = kind == my.gimano.app.data.model.IssueKind.TURN_NOT_ALLOWED
        val at = if (turn) d.junction else d.point
        val payload = kotlinx.serialization.json.buildJsonObject {
            d.road?.let { put("roadName", kotlinx.serialization.json.JsonPrimitive(it)) }
            if (turn) { put("toLat", kotlinx.serialization.json.JsonPrimitive(round5(d.point.lat))); put("toLng", kotlinx.serialization.json.JsonPrimitive(round5(d.point.lng))) }
        }
        val send = {
            sendIssue(CreateIssueRequest(kind, lat = round5(at.lat), lng = round5(at.lng), heading = d.heading, vehicle = settings.current.vehicle,
                source = "deviation", payload = payload.takeIf { it.isNotEmpty() }), R.string.issue_sent)
        }
        if (termsOk { send() }) send()
    }

    /** "Masih ditutup?" answers: still | cleared | unsure. */
    fun answerStillClosed(answer: String?) {
        val i = _ui.value.stillClosed ?: return
        _ui.update { it.copy(stillClosed = null) }
        if (answer == null) return
        if (!termsOk { voteStillClosed(i, answer) }) return
        voteStillClosed(i, answer)
    }

    private fun voteStillClosed(i: my.gimano.app.data.model.Issue, answer: String) {
        val prox = voteProximity(GeoPoint(i.lat, i.lng)) ?: return
        viewModelScope.launch {
            if (c.issues.call(collection = false) { voteIssue(i.id, my.gimano.app.data.model.IssueVoteRequest(answer, prox)) } != null) _events.tryEmit(UiEvent.Toast(R.string.thanks_vote))
        }
    }

    /** "Lalu juga (saya tahu jalan ini)": recompute without that exclusion, for this trip only. */
    fun passAnyway(issueId: String) {
        val plan = _ui.value.plan ?: return
        cancelCountdown()
        fetchRoutes(plan.copy(ignoredIssues = plan.ignoredIssues + issueId))
    }

    /** Badges for the place on the card: issues about it within a small box. */
    private fun loadPlaceIssues(placeId: String, at: GeoPoint) {
        // The server puts an open place issue on the place itself (badge); fall back to /issues/nearby.
        val sel = _ui.value.place
        val badge = sel?.detail?.badge ?: sel?.summary?.badge
        _ui.update { it.copy(placeIssues = listOfNotNull(badge?.toIssue(at.lat, at.lng))) }
        if (badge != null || !_ui.value.issuesAvailable || placeId.startsWith("pin:") || placeId.startsWith("private:")) return
        viewModelScope.launch {
            val b = my.gimano.app.core.issues.IssueSupport.bbox(at, 150.0)
            val list = c.issues.call { issuesNearby(b[0], b[1], b[2], b[3], null) }.orEmpty()
                .filter { it.placeId == placeId && it.state in my.gimano.app.data.model.IssueState.open }
            _ui.update { s -> if (s.place?.summary?.id == placeId) s.copy(placeIssues = list) else s }
        }
    }

    /** "Cadangkan suntingan": a place issue with its payload (until / openingHours / navLat+navLng / comment). */
    fun reportPlaceIssue(kind: String, payload: Map<String, String>? = null, at: GeoPoint? = null) = reportPlaceIssueJson(kind, jsonOf(payload), at)

    private fun reportPlaceIssueJson(kind: String, payload: kotlinx.serialization.json.JsonObject?, at: GeoPoint? = null) {
        if (!termsOk { reportPlaceIssueJson(kind, payload, at) }) return
        val p = _ui.value.place?.summary ?: return
        val pt = at ?: GeoPoint(p.lat, p.lng)
        sendIssue(CreateIssueRequest(kind, lat = round5(pt.lat), lng = round5(pt.lng), placeId = p.id, source = "place_edit", payload = payload), R.string.issue_sent) {
            loadPlaceIssues(p.id, GeoPoint(p.lat, p.lng))
        }
    }

    fun votePlaceIssue(i: my.gimano.app.data.model.Issue, answer: String) {
        if (!termsOk { votePlaceIssue(i, answer) }) return
        val prox = voteProximity(GeoPoint(i.lat, i.lng)) ?: run { _events.tryEmit(UiEvent.Toast(R.string.vote_need_near)); return }
        viewModelScope.launch {
            if (c.issues.call(collection = false) { voteIssue(i.id, my.gimano.app.data.model.IssueVoteRequest(answer, prox)) } != null) {
                _events.tryEmit(UiEvent.Toast(R.string.thanks_vote))
                _ui.update { s -> s.copy(placeIssues = s.placeIssues.filterNot { it.id == i.id }) }
            }
        }
    }

    /**
     * "Pintu masuk salah?" on the arrival card (docs/driving.md §4): ends the drive, opens the destination's place card
     * and starts the existing place_entrance_wrong flow (pick the right entrance on the map).
     */
    fun wrongEntrance() {
        val d = nav.value.destination ?: return
        val id = d.placeId ?: return
        stopNavigation()
        showPlace(PlaceSummary(id, d.name, address = d.address, lat = d.point.lat, lng = d.point.lng))
        pickEntrance()
    }

    /** "Pintu masuk / parkir salah": pick the right point with a green pin. */
    fun pickEntrance() {
        val p = _ui.value.place?.summary ?: return
        openPickOnMap(SearchPurpose.ENTRANCE, start = GeoPoint(p.lat, p.lng))
    }

    // --- Search -----------------------------------------------------------------------------

    fun openSearch(purpose: SearchPurpose = SearchPurpose.NAVIGATE, initial: String = "") {
        _ui.update { it.copy(screen = Screen.Search(purpose), query = initial, searchViewport = null, results = emptyList(), localHits = emptyList(), activeCategory = null, searchedOnce = false,
            correctedQuery = null, suggestions = emptyList(), exactSearch = false) }
        queryFlow.value = initial
    }

    fun onQuery(q: String) {
        _ui.update { it.copy(query = q, activeCategory = null, exactSearch = false) }
        queryFlow.value = q
    }

    fun searchThisArea(viewport: String) {
        val query = _ui.value.query
        openSearch(initial = query)
        _ui.update { it.copy(searchViewport = viewport) }
        if (query.isNotBlank()) viewModelScope.launch { runSearch(query) }
    }

    private suspend fun runSearch(q: String) {
        if (q.isBlank()) {
            _ui.update { it.copy(results = if (it.activeCategory != null) it.results else emptyList(), localHits = emptyList(), searching = false, searchedOnce = false) }
            return
        }
        _ui.update { it.copy(searching = true) }
        val me = here()
        // Local favourites and private places are matched on the device and shown first.
        val localHits = runCatching { local.search(q, me) }.getOrDefault(emptyList())
        // Ranking origin = the user. (Sending the map centre as `near` ranked results around wherever an earlier
        // search or the picker had left the map, which the search screen doesn't even show.)
        val near: my.gimano.app.data.repo.GeoPointLite? = null
        val viewport = _ui.value.searchViewport
        val got = runCatching { repo.searchFull(q, me.lat, me.lng, 20, exact = _ui.value.exactSearch, near = near, viewport = viewport, category = _ui.value.activeCategory) }
        (got.exceptionOrNull() as? kotlinx.coroutines.CancellationException)?.let { throw it }   // superseded by a newer query
        val full = got.getOrDefault(SearchResponse())
        if (_ui.value.query == q && _ui.value.searchViewport == viewport) _ui.update {
            it.copy(results = full.results.filter { p -> viewport == null || my.gimano.app.core.geo.SearchArea.contains(viewport, p.lat, p.lng) }.withDistanceFrom(me), localHits = localHits.filter { h -> viewport == null || my.gimano.app.core.geo.SearchArea.contains(viewport, h.lat, h.lng) }, searching = false, searchedOnce = true, searchFailed = got.isFailure,
                correctedQuery = full.correctedQuery?.takeIf { c -> !c.equals(q.trim(), ignoreCase = true) }, suggestions = if (viewport == null) full.suggestions else emptyList())
        }
    }

    /** Quick category chips (GET /search/nearby). Surau also includes mosques and vice versa. */
    fun searchCategory(cat: String) {
        if (_ui.value.searchViewport != null) {
            _ui.update { it.copy(query = cat, activeCategory = cat, searching = true) }
            viewModelScope.launch { runSearch(cat) }
            return
        }
        _ui.update { it.copy(activeCategory = cat, query = "", searching = true, localHits = emptyList()) }
        queryFlow.value = ""
        viewModelScope.launch {
            val me = here()
            val cats = when (cat) { "mosque", "surau" -> listOf("surau", "mosque"); else -> listOf(cat) }
            val res = cats.flatMap { k -> runCatching { repo.nearby(me.lat, me.lng, k, 10_000) }.getOrDefault(emptyList()) }
                .distinctBy { it.id }.withDistanceFrom(me).sortedBy { it.distanceM ?: Double.MAX_VALUE }
            _ui.update { it.copy(results = res, searching = false, searchedOnce = true) }
        }
    }

    /** "cari 'x' sahaja": search the literal text, without the server's spelling fix. */
    fun searchExact() {
        val q = _ui.value.query
        _ui.update { it.copy(exactSearch = true, correctedQuery = null) }
        viewModelScope.launch { runSearch(q) }
    }

    fun setResultSort(s: my.gimano.app.core.search.ResultSort) = _ui.update { it.copy(resultSort = s) }

    /** A "Mungkin anda maksudkan" chip: a place goes straight to it; otherwise search the suggested text/category. */
    fun pickSuggestion(s: SearchSuggestion) {
        when {
            s.lat != null && s.lng != null -> pickResult(PlaceSummary(s.placeId ?: "pin:${s.lat},${s.lng}", s.label, s.category ?: "other", "", s.lat, s.lng,
                GeoMath.distanceM(here(), GeoPoint(s.lat, s.lng))))
            s.category != null && s.query == null -> searchCategory(s.category)
            else -> onQuery(s.query ?: s.label)
        }
    }

    // --- Pilih pada peta (select on map) ------------------------------------------------------

    private var pickJob: Job? = null

    /**
     * Opens the map picker. Starts at [start], else the searched area (first results), else the user's location.
     * [purpose] decides what "Pilih titik ini" does (same as choosing a search result for that purpose).
     */
    fun openPickOnMap(purpose: SearchPurpose = (_ui.value.screen as? Screen.Search)?.purpose ?: SearchPurpose.NAVIGATE,
                      start: GeoPoint? = null, favorite: FavoriteDraft? = null) {
        val s = _ui.value
        val at = start ?: s.results.firstOrNull()?.let { GeoPoint(it.lat, it.lng) } ?: here()
        _ui.update {
            it.copy(screen = Screen.PickOnMap(purpose), following = false, favoriteSheet = null,
                pick = PickState(at, returnTo = s.screen, favoriteDraft = favorite), camera = CameraCommand.Reset2D(at, 17.5))
        }
        onPickMoved(at)
    }

    /** Camera settled while picking: look up the address under the pin after ~400 ms of stillness. */
    fun onPickMoved(center: GeoPoint) {
        val screen = _ui.value.screen as? Screen.PickOnMap ?: return
        // Event stops: no reverse geocoding. Nothing about an event reaches the server (docs/events.md §1).
        if (screen.purpose == SearchPurpose.EVENT_STOP || screen.purpose == SearchPurpose.EVENT_ENTRANCE) {
            pickJob?.cancel()
            _ui.update { it.copy(pick = it.pick?.copy(center = center, loading = false)) }
            return
        }
        _ui.update { it.copy(pick = it.pick?.copy(center = center, loading = true)) }
        pickJob?.cancel()
        pickJob = viewModelScope.launch {
            delay(400)
            val r = runCatching { repo.reverse(center.lat, center.lng) }.getOrNull()
            val poi = r?.let { rv ->
                rv.nearby.mapNotNull { p -> GeoMath.distanceM(center, GeoPoint(p.lat, p.lng)).takeIf { it <= 50 }?.let { p.copy(distanceM = it) } }.minByOrNull { it.distanceM ?: 0.0 }
                    ?: GeoMath.distanceM(center, GeoPoint(rv.lat, rv.lng)).takeIf { it <= 50 && rv.name.isNotBlank() && !rv.address.startsWith(rv.name) }
                        ?.let { d -> PlaceSummary("pin:${rv.lat},${rv.lng}", rv.name, "other", rv.address, rv.lat, rv.lng, d) }
            }
            _ui.update {
                it.copy(pick = it.pick?.copy(loading = false, nearPoi = poi, address = r?.address?.takeIf { a -> a.isNotBlank() },
                    label = r?.let(::pickTitle),
                    area = r?.let { rv -> listOfNotNull(rv.area, rv.city).filter { a -> a.isNotBlank() }.distinct().joinToString(", ").ifBlank { null } ?: rv.address.substringAfter(", ", "").ifBlank { null } }))
            }
        }
    }

    /** "Dekat 18, Jalan SS 2/24" from the structured reverse fields; older servers: first part of the address. */
    private fun pickTitle(r: ReverseGeocode): String? {
        val street = r.street?.takeIf { it.isNotBlank() }
        val core = when {
            street != null && !r.houseNumber.isNullOrBlank() -> "${r.houseNumber}, $street"
            street != null -> street
            else -> r.address.substringBefore(",").takeIf { it.isNotBlank() }
        } ?: return r.label
        return c.app.getString(R.string.pick_near, core)
    }

    /** "Adakah ini …?": snap the pin to that place. */
    fun pickPoi() {
        val p = _ui.value.pick?.nearPoi ?: return
        _ui.update { it.copy(camera = CameraCommand.Reset2D(GeoPoint(p.lat, p.lng), 18.0)) }
    }

    /** "Pilih titik ini". */
    fun finishPick() {
        val s = _ui.value
        val pk = s.pick ?: return
        val purpose = (s.screen as? Screen.PickOnMap)?.purpose ?: SearchPurpose.NAVIGATE
        val poi = pk.nearPoi?.takeIf { purpose != SearchPurpose.ENTRANCE && GeoMath.distanceM(pk.center, GeoPoint(it.lat, it.lng)) <= 10 }
        val p = poi ?: PlaceSummary(
            "pin:${pk.center.lat},${pk.center.lng}", pk.label ?: c.app.getString(R.string.pin_on_map), "other",
            pk.address ?: "", pk.center.lat, pk.center.lng, GeoMath.distanceM(here(), pk.center),
        )
        pk.favoriteDraft?.let { d ->
            // Favourite placed precisely ("pin at the gate"): back to the sheet with the new point.
            _ui.update { it.copy(pick = null, screen = pk.returnTo, favoriteSheet = d.copy(place = p.copy(name = d.place?.name ?: p.name))) }
            return
        }
        _ui.update { it.copy(pick = null) }
        pickResultFor(purpose, p, fromMap = true)
    }

    // --- Pin actions (canvas CariPin) -----------------------------------------------------------

    fun showPin(p: PlaceSummary) {
        val g = GeoPoint(p.lat, p.lng)
        _ui.update { it.copy(screen = Screen.PinActions, pin = PinSel(p), place = null, following = false, camera = CameraCommand.MoveTo(g, 16.5)) }
        viewModelScope.launch {
            val me = (gpsFix() as? RouteOrigin.Gps.Fresh)?.point ?: return@launch   // no ETA from the map centre
            if (RouteOrigin.sameSpot(me, g)) return@launch
            val r = runCatching {
                repo.routes(RouteRequest(LatLngDto(me.lat, me.lng), LatLngDto(g.lat, g.lng), vehicle = settings.current.vehicle, alternatives = 0))
            }.getOrNull()?.firstOrNull()
            _ui.update { s -> if (s.pin?.place?.id == p.id) s.copy(pin = s.pin.copy(etaS = r?.durationS, routeM = r?.distanceM)) else s }
        }
    }

    private var pinDestination: GeoPoint? = null

    fun pinNavigate() {
        val p = _ui.value.pin?.place ?: return
        pinDestination = GeoPoint(p.lat, p.lng)
        routeTo(p.toDestination())
    }

    /** Simpan: a favourite on this phone only. */
    fun pinSave() {
        val p = _ui.value.pin?.place ?: return
        _ui.update { it.copy(favoriteSheet = FavoriteDraft(p, label = "", icon = "star")) }
    }

    /** Tambah tempat: the existing add-place flow at this point ("Untuk saya" or public is asked there). */
    fun pinAddPlace() {
        val p = _ui.value.pin?.place ?: return
        _events.tryEmit(UiEvent.AddPlace(GeoPoint(p.lat, p.lng), ""))
    }

    /** Kongsi: plain coordinates + a geo: and an OpenStreetMap link. No account, no Gimano server. */
    fun pinShare() {
        val p = _ui.value.pin?.place ?: return
        val ll = String.format(java.util.Locale.US, "%.6f,%.6f", p.lat, p.lng)
        val text = listOfNotNull(p.name.takeIf { !it.startsWith("pin:") }, p.address.takeIf { it.isNotBlank() && it != p.name }, ll,
            "geo:$ll?q=$ll", "https://www.openstreetmap.org/?mlat=${ll.substringBefore(',')}&mlon=${ll.substringAfter(',')}#map=18/${ll.replace(',', '/')}").joinToString("\n")
        _events.tryEmit(UiEvent.Share(text))
    }

    /** "Nak namakan tempat ini?" → saved as a favourite on the phone. */
    fun nameArrivedPin(name: String?) {
        val d = _ui.value.namePin ?: return
        _ui.update { it.copy(namePin = null) }
        if (name.isNullOrBlank()) return
        viewModelScope.launch {
            runCatching { local.addFavorite(Favorites.normalizeLabel(name).ifEmpty { name.take(Favorites.MAX_LABEL) }, "star", d.point.lat, d.point.lng, d.address, null) }
            _events.tryEmit(UiEvent.Toast(R.string.favorite_saved))
        }
    }

    private fun List<PlaceSummary>.withDistanceFrom(me: GeoPoint) =
        map { if (it.distanceM == null) it.copy(distanceM = GeoMath.distanceM(me, GeoPoint(it.lat, it.lng))) else it }

    fun pickLocal(h: LocalHit) {
        pickResult(PlaceSummary(if (h.kind == "private") h.id else (h.placeId ?: "pin:${h.lat},${h.lng}"), h.name, "other", h.address, h.lat, h.lng, GeoMath.distanceM(here(), GeoPoint(h.lat, h.lng))))
    }

    fun pickResult(p: PlaceSummary) = pickResultFor((_ui.value.screen as? Screen.Search)?.purpose ?: SearchPurpose.NAVIGATE, p)

    private fun pickResultFor(purpose: SearchPurpose, p: PlaceSummary, fromMap: Boolean = false) {
        when (purpose) {
            SearchPurpose.NAVIGATE -> if (fromMap || p.id.startsWith("pin:") || (my.gimano.app.core.search.ResultGrouping.isSearchOnly(p.id) && !p.id.startsWith("st-"))) showPin(p) else showPlace(p)
            SearchPurpose.SET_HOME -> setHomeWork("home", p, R.string.home_set)
            SearchPurpose.SET_WORK -> setHomeWork("work", p, R.string.work_set)
            SearchPurpose.ADD_FAVORITE -> {
                showPlace(p)
                openFavoriteSheet()
            }
            SearchPurpose.ADD_STOP -> {
                _ui.update { it.copy(screen = Screen.Navigating) }
                viewModelScope.launch {
                    val ok = c.navigation.addStop(p.toDestination())
                    if (ok || nav.value.active) _events.tryEmit(UiEvent.Toast(if (ok) R.string.stop_added else R.string.stops_full))
                }
            }
            SearchPurpose.PLAN_DRIVE -> {
                _ui.update { it.copy(screen = Screen.Planned) }
                _events.tryEmit(UiEvent.PlanDrive(p.toPoint(), null, emptyList(), settings.current.vehicle))
            }
            SearchPurpose.ENTRANCE -> {
                _ui.update { it.copy(screen = Screen.PlaceCard) }
                // navLat/navLng are JSON numbers (docs/api.md); the server rejects strings.
                reportPlaceIssueJson(my.gimano.app.data.model.IssueKind.PLACE_ENTRANCE_WRONG, kotlinx.serialization.json.buildJsonObject {
                    put("navLat", kotlinx.serialization.json.JsonPrimitive(round5(p.lat))); put("navLng", kotlinx.serialization.json.JsonPrimitive(round5(p.lng)))
                    put("kind", kotlinx.serialization.json.JsonPrimitive("entrance"))
                })
            }
            SearchPurpose.SET_ORIGIN -> {
                _ui.update { it.copy(screen = Screen.RoutePreview) }
                setPlanOrigin(GeoPoint(p.lat, p.lng), OriginSource.CHOSEN, p.toDestination())
            }
            SearchPurpose.EVENT_STOP -> {
                _ui.update { it.copy(screen = Screen.EventEdit) }
                c.hostEditor.addStop(p.lat, p.lng, if (fromMap || p.id.startsWith("pin:")) "" else p.name)
            }
            SearchPurpose.EVENT_ENTRANCE -> {
                _ui.update { it.copy(screen = Screen.EventEdit) }
                c.hostEditor.setEntrance(p.lat, p.lng)
            }
            SearchPurpose.ADD_STOP_PREVIEW -> {
                val plan = _ui.value.plan
                _ui.update { it.copy(screen = Screen.RoutePreview) }
                if (plan != null) runCatching { StopList.add(plan.stops, p.toDestination()) }
                    .onSuccess { fetchRoutes(plan.copy(stops = it)) }
                    .onFailure { _events.tryEmit(UiEvent.Toast(R.string.stops_full)) }
            }
        }
    }

    private fun PlaceSummary.toPoint() = my.gimano.app.data.planned.PlacePoint(lat, lng, name, address,
        id.takeUnless { it.startsWith("pin:") || it.startsWith("private:") || my.gimano.app.core.search.ResultGrouping.isSearchOnly(it) })
    private fun NavDestination.toPoint() = my.gimano.app.data.planned.PlacePoint(point.lat, point.lng, name, address, placeId)
    private fun my.gimano.app.data.planned.PlacePoint.toDestination() = NavDestination(name, address, GeoPoint(lat, lng), placeId)

    /** Route preview overflow → "Plan this drive". */
    fun planThisDrive() {
        val plan = _ui.value.plan ?: return
        // Event stop names stay out of planned drives (gimano.db is backed up; event data must not be).
        if (plan.hasEventStop) return
        cancelCountdown()
        val origin = plan.originPlace?.takeIf { plan.originSource == OriginSource.CHOSEN }?.toPoint()
        _events.tryEmit(UiEvent.PlanDrive(plan.destination.toPoint(), origin, plan.stops.map { it.toPoint() }, plan.mode.wire))
        _ui.update { it.copy(screen = Screen.Planned) }
    }

    /** Planned drive "Go" or its reminder notification → route preview. */
    fun goPlanned(d: my.gimano.app.data.planned.PlannedDrive) {
        viewModelScope.launch { settings.setVehicle(d.vehicle) }
        routeTo(d.destination.toDestination(), d.waypoints.map { it.toDestination() }, quickPick = true)
    }

    fun openPlannedDrive(id: String) = viewModelScope.launch { c.planned.byId(id)?.let { goPlanned(it) } }

    private fun PlaceSummary.toDestination() = NavDestination(name, address, GeoPoint(lat, lng),
        id.takeUnless { it.startsWith("pin:") || it.startsWith("private:") || my.gimano.app.core.search.ResultGrouping.isSearchOnly(it) })

    private fun setHomeWork(kind: String, p: PlaceSummary, @StringRes msg: Int) {
        viewModelScope.launch {
            local.setHomeWork(kind, p.name, p.lat, p.lng, p.address, p.id.takeUnless { it.startsWith("pin:") || it.startsWith("private:") || my.gimano.app.core.search.ResultGrouping.isSearchOnly(it) })
            _events.tryEmit(UiEvent.Toast(msg))
        }
        goHome()
    }

    fun canAddPlaceFromSearch(): Boolean = _ui.value.searchedOnce && !_ui.value.searching && !_ui.value.searchFailed && _ui.value.results.isEmpty() && _ui.value.localHits.isEmpty()

    fun retrySearch() { val q = _ui.value.query; viewModelScope.launch { runSearch(q) } }

    fun startAddPlace(at: GeoPoint, name: String) {
        _ui.update { it.copy(screen = Screen.AddPlace, addPlaceSeed = at to name, place = null, following = false, camera = CameraCommand.MoveTo(at, 18.0)) }
    }

    fun showPrivate(id: String) {
        viewModelScope.launch {
            val e = local.privatePlace(id) ?: return@launch
            showPlace(PlaceSummary("private:$id", e.name, e.category, e.address ?: "", e.lat, e.lng, GeoMath.distanceM(here(), GeoPoint(e.lat, e.lng))))
        }
    }

    fun deletePrivatePlace(id: String) = viewModelScope.launch {
        local.privatePhotos(id).forEach { java.io.File(java.io.File(c.app.filesDir, "photos"), it.fileName).delete() }
        local.deletePrivatePlace(id)
        goHome()
    }

    fun addPlaceFromSearch() {
        val name = _ui.value.query.trim()
        _events.tryEmit(UiEvent.AddPlace(boundsFlow.value?.center ?: here(), name))
    }

    // --- Place card -------------------------------------------------------------------------

    private var placeLinkJob: kotlinx.coroutines.Job? = null

    fun openPlaceLink(id: String) {
        placeLinkJob?.cancel()
        placeLinkJob = viewModelScope.launch {
            if (nav.value.active) {
                _events.emit(UiEvent.Toast(R.string.place_link_finish_drive))
                return@launch
            }
            try {
                val place = repo.place(id)
                kotlinx.coroutines.currentCoroutineContext().ensureActive()
                if (!nav.value.active) showPlace(place.summary())
            } catch (e: kotlinx.coroutines.CancellationException) {
                throw e
            } catch (_: Exception) {
                _events.emit(UiEvent.Toast(R.string.place_link_unavailable))
            }
        }
    }

    fun showPlace(p: PlaceSummary) {
        val savedId = _ui.value.saved.firstOrNull { (it.placeId != null && it.placeId == p.id) || (GeoMath.distanceM(GeoPoint(it.lat, it.lng), GeoPoint(p.lat, p.lng)) < 15) }?.id
        _ui.update { it.copy(screen = Screen.PlaceCard, place = PlaceSel(p, loading = true, savedId = savedId), camera = CameraCommand.MoveTo(GeoPoint(p.lat, p.lng), 15.5), following = false) }
        if (p.id.startsWith("private:")) {
            viewModelScope.launch {
                val id = p.id.removePrefix("private:")
                val e = local.privatePlace(id)
                val photos = local.privatePhotos(id).map { java.io.File(java.io.File(c.app.filesDir, "photos"), it.fileName) }.filter { it.exists() }
                _ui.update { s -> if (s.place?.summary?.id == p.id) s.copy(place = s.place.copy(loading = false, privatePlace = e, privatePhotos = photos)) else s }
            }
            return
        }
        if (p.id.startsWith("pin:")) {
            _ui.update { it.copy(place = it.place?.copy(loading = false)) }
            return
        }
        viewModelScope.launch {
            // No position on GET /places/{id}: the card computes the distance on the phone (PlaceDistance).
            val d = runCatching { repo.place(p.id) }.getOrNull()
            _ui.update { s -> if (s.place?.summary?.id == p.id) s.copy(place = s.place.copy(detail = d, loading = false)) else s }
            loadPlaceIssues(p.id, GeoPoint(p.lat, p.lng))
        }
    }

    fun refreshPlace() {
        val p = _ui.value.place?.summary ?: return
        if (p.id.startsWith("pin:") || p.id.startsWith("private:")) return
        viewModelScope.launch {
            val d = runCatching { repo.place(p.id) }.getOrNull() ?: return@launch
            _ui.update { s -> if (s.place?.summary?.id == p.id) s.copy(place = s.place.copy(detail = d)) else s }
        }
    }

    /** Long-press on the home map → straight to the pin and its actions (canvas CariRules). */
    fun dropPin(g: GeoPoint) {
        if (_ui.value.screen != Screen.Home && _ui.value.screen != Screen.PlaceCard && _ui.value.screen != Screen.PinActions) return
        showPin(PlaceSummary("pin:${g.lat},${g.lng}", c.app.getString(R.string.pin_on_map), "other", "", g.lat, g.lng, GeoMath.distanceM(here(), g)))
        viewModelScope.launch {
            val r = runCatching { repo.reverse(g.lat, g.lng) }.getOrNull() ?: return@launch
            val label = pickTitle(r)
            _ui.update { s -> if (s.pin?.place?.id == "pin:${g.lat},${g.lng}") s.copy(pin = s.pin.copy(place = s.pin.place.copy(name = label ?: s.pin.place.name, address = r.address))) else s }
        }
    }

    fun call(phone: String) = _events.tryEmit(UiEvent.Dial(phone))
    fun openWeb(url: String) = _events.tryEmit(UiEvent.Web(url))

    fun sharePlace() {
        val p = _ui.value.place?.summary ?: return
        _events.tryEmit(UiEvent.Share("${p.name}\n${p.address}\n${osmLink(GeoPoint(p.lat, p.lng))}"))
    }

    private fun osmLink(p: GeoPoint) = String.format(java.util.Locale.US, "https://www.openstreetmap.org/?mlat=%.5f&mlon=%.5f#map=17/%.5f/%.5f", p.lat, p.lng, p.lat, p.lng)

    // --- Favourites (on-device) ---------------------------------------------------------------

    /** Place card "Save": opens the label/icon sheet. */
    fun openFavoriteSheet() {
        val p = _ui.value.place?.summary ?: return
        val existing = _ui.value.saved.firstOrNull { it.id == _ui.value.place?.savedId }
        _ui.update {
            it.copy(favoriteSheet = if (existing != null) FavoriteDraft(p, existing.id, existing.kind, existing.name, existing.icon)
            else FavoriteDraft(p, label = "", icon = "star"))
        }
    }

    fun editFavorite(sp: SavedPlace) {
        _ui.update { it.copy(favoriteSheet = FavoriteDraft(null, sp.id, sp.kind, sp.name, sp.icon)) }
    }

    fun updateFavoriteDraft(d: FavoriteDraft) = _ui.update { it.copy(favoriteSheet = d) }
    fun closeFavoriteSheet() = _ui.update { it.copy(favoriteSheet = null) }

    fun saveFavorite() {
        val d = _ui.value.favoriteSheet ?: return
        val label = Favorites.normalizeLabel(d.label)
        viewModelScope.launch {
            try {
                if (d.editingId != null) {
                    local.updateFavorite(d.editingId, label, d.icon)
                } else {
                    val p = d.place ?: return@launch
                    val sp = local.addFavorite(label.ifEmpty { p.name.take(Favorites.MAX_LABEL) }, d.icon, p.lat, p.lng, p.address, p.id.takeUnless { it.startsWith("pin:") || it.startsWith("private:") })
                    _ui.update { s -> s.copy(place = s.place?.copy(savedId = sp.id)) }
                }
                _ui.update { it.copy(favoriteSheet = null) }
                _events.tryEmit(UiEvent.Toast(R.string.place_saved))
            } catch (e: IllegalStateException) {
                _events.tryEmit(UiEvent.Toast(R.string.favorites_full))
            }
        }
    }

    fun setDraftAsHomeWork(kind: String) {
        val d = _ui.value.favoriteSheet ?: return
        val p = d.place ?: _ui.value.saved.firstOrNull { it.id == d.editingId }?.let { PlaceSummary(it.placeId ?: "pin:", it.name, "other", it.address, it.lat, it.lng) } ?: return
        viewModelScope.launch {
            local.setHomeWork(kind, p.name, p.lat, p.lng, p.address, p.id.takeUnless { it.startsWith("pin:") || it.startsWith("private:") })
            _ui.update { it.copy(favoriteSheet = null) }
            _events.tryEmit(UiEvent.Toast(if (kind == "home") R.string.home_set else R.string.work_set))
        }
    }

    fun deleteFavorite(id: String) {
        viewModelScope.launch {
            local.deleteSaved(id)
            _ui.update { s -> s.copy(favoriteSheet = null, place = s.place?.let { if (it.savedId == id) it.copy(savedId = null) else it }) }
        }
    }

    fun moveFavorite(id: String, delta: Int) = viewModelScope.launch { local.moveFavorite(id, delta) }

    // --- Route planning ---------------------------------------------------------------------

    fun routeTo(dest: NavDestination, stops: List<NavDestination> = emptyList(), quickPick: Boolean = false, returnToEvent: String? = null) {
        val st = settings.current
        val prev = _ui.value.plan
        val plan = RoutePlan(destination = dest, origin = null, originSource = OriginSource.LOCATING, stops = stops, quickPick = quickPick,
            mode = TravelMode.from(st.vehicle), avoid = prev?.avoid ?: AvoidOptions(), loading = false, returnToEvent = returnToEvent)
        GLog.d("VM", "route preview, ${stops.size} stops")
        _ui.update { it.copy(screen = Screen.RoutePreview, plan = plan, following = false, selectedAlertId = null) }
        // Event stops never go into recents (gimano.db is backed up; event data must not be: docs/events.md §7.6).
        if (!dest.eventStop) viewModelScope.launch { local.recordRecent(dest.name, dest.address, dest.point.lat, dest.point.lng, dest.placeId) }
        resolveOrigin()
    }

    /**
     * "Pandu" on an event stop: route preview to the stop's vehicle entrance, else its pin (§7.7). The label is shown on
     * this phone only; the routing request carries coordinates and travel mode only ([NavDestination.eventStop]).
     */
    fun routeToEventStop(eventId: String, stopId: String, label: String, target: GeoPoint) =
        routeTo(NavDestination(label, "", target, null, eventStop = true, eventId = eventId, stopId = stopId), returnToEvent = eventId)

    /**
     * The guest accepted an updated plan and asked to drive to the stop's new position (EvUpdate): stop the current drive
     * and open the route preview to the new target. Never done without that tap.
     */
    fun retargetEventStop(eventId: String, stopId: String, label: String, target: GeoPoint) {
        if (nav.value.active) stopNavigation()
        routeToEventStop(eventId, stopId, label, target)
    }

    // --- Events this phone organises (host side) ------------------------------------------------

    fun newHostEvent() {
        c.hostEditor.newEvent(if (c.lang() == my.gimano.app.core.format.Lang.EN) "en" else "ms")
        _ui.update { it.copy(screen = Screen.EventEdit) }
    }

    fun openHostEvent(id: String) = viewModelScope.launch {
        if (c.hostEditor.open(id)) _ui.update { it.copy(screen = Screen.EventEdit) }
    }

    fun closeEventEditor() {
        c.hostEditor.close()
        _ui.update { it.copy(screen = Screen.Events) }
    }

    /** Wizard back arrow / system back: the previous step, else leave (the draft is saved). */
    fun eventWizardBack() { if (!c.hostEditor.back()) closeEventEditor() }

    /**
     * "Bina laluan di peta" for day [day] of a journey: that day's route, or a new one through the day's stops in order
     * (start → stops → finish, each point linked to its stop) in the wizard's travel mode.
     */
    fun openEventRouteForDay(day: Int) {
        val ed = c.hostEditor
        val d = ed.draft.value ?: return
        val date = if (d.multiDay) runCatching { d.dayDate(day).toString() }.getOrNull() else null
        val existing = d.routes.firstOrNull { r -> date == null || r.day == date } ?: d.routes.firstOrNull { date != null && it.day == null && d.routes.size == 1 }
        if (existing != null) { openEventRoute(existing.id); return }
        if (d.routes.size >= my.gimano.app.core.events.EventLimits.MAX_ROUTES) return
        var r = my.gimano.app.core.routes.BuilderRoute(id = my.gimano.app.core.events.EventIds.newItemId(), mode = ed.defaultMode(), day = date)
        d.stops.filter { (if (d.multiDay) it.day == day else true) }.forEach { s ->
            r = my.gimano.app.core.routes.RouteEdit.addPoint(r, my.gimano.app.core.routes.Pos(s.lat, s.lng), s.id) ?: r
        }
        ed.saveRoute(r)
        openEventRoute(r.id)
    }

    fun addEventStopBySearch() = openSearch(SearchPurpose.EVENT_STOP)

    fun addEventStopOnMap() {
        val d = c.hostEditor.draft.value
        val last = d?.stops?.lastOrNull()?.let { GeoPoint(it.lat, it.lng) }
        openPickOnMap(SearchPurpose.EVENT_STOP, start = last ?: here())
    }

    fun addEventStopFromSaved(p: SavedPlace) = c.hostEditor.addStop(p.lat, p.lng, p.name)

    fun pickEventEntrance(stopId: String) {
        val s = c.hostEditor.draft.value?.stops?.firstOrNull { it.id == stopId } ?: return
        c.hostEditor.entranceFor = stopId
        openPickOnMap(SearchPurpose.EVENT_ENTRANCE, start = s.entrance ?: GeoPoint(s.lat, s.lng))
    }

    /** "Kongsi jemputan". [onBlocked] runs (main thread) when problems stop it, so the editor can show the first one. */
    fun shareHostEvent(onBlocked: () -> Unit = {}) = viewModelScope.launch {
        if (c.hostEditor.publish()) _ui.update { it.copy(screen = Screen.EventShare) }
        else if (c.hostEditor.issues.value.isNotEmpty()) onBlocked()
    }

    /** "Draf": save and leave the wizard. */
    fun saveEventDraft() = closeEventEditor()

    fun toastText(text: String) = _events.tryEmit(UiEvent.ToastText(text))

    // --- Route builder ("Bina laluan") and "Laluan saya" ------------------------------------------------------

    private fun builderCamera(points: List<GeoPoint>): CameraCommand = when {
        points.size >= 2 -> CameraCommand.Fit(points, topDp = 150, bottomDp = 300)
        points.size == 1 -> CameraCommand.MoveTo(points[0], 14.0)
        else -> CameraCommand.MoveTo(here(), 13.0)
    }

    /** From the event editor: edit route [routeId], or a new one (null). */
    fun openEventRoute(routeId: String?) {
        val ed = c.hostEditor
        val d = ed.draft.value ?: return
        if (routeId == null && d.routes.size >= my.gimano.app.core.events.EventLimits.MAX_ROUTES) return
        val r = routeId?.let(ed::route) ?: my.gimano.app.core.routes.BuilderRoute(
            id = my.gimano.app.core.events.EventIds.newItemId(), mode = ed.defaultMode(),
            day = runCatching { d.localDate().toString() }.getOrNull()?.takeIf { d.routes.isEmpty() && runCatching { d.end().toLocalDate() != d.start().toLocalDate() }.getOrDefault(false) },
        )
        val stops = d.stops.map { my.gimano.app.data.routes.StopRef(it.id, it.label, my.gimano.app.core.routes.Pos(it.lat, it.lng)) }
        c.routeBuilder.start(r, my.gimano.app.data.routes.BuilderTarget.Event, stops) { ed.saveRoute(it) }
        val pts = r.points.map { it.geo }.ifEmpty { stops.map { it.pos.geo } }
        _ui.update { it.copy(screen = Screen.RouteBuilder(forEvent = true), camera = builderCamera(pts)) }
    }

    fun openMyRoutes() = _ui.update { it.copy(screen = Screen.MyRoutes) }

    /** "Laluan saya": open route [id], or a new one (null). Its name is the route title. */
    fun openPersonalRoute(id: String?) = viewModelScope.launch {
        val p = id?.let { runCatching { c.personalRoutes.get(it) }.getOrNull() }
        val vehicle = settings.current.vehicle.takeIf { v -> my.gimano.app.core.events.EventTravelMode.entries.any { it.wire == v } } ?: "car"
        val r = p?.route?.copy(title = p.name) ?: my.gimano.app.core.routes.BuilderRoute(my.gimano.app.core.events.EventIds.newItemId(), mode = vehicle)
        c.routeBuilder.start(r, my.gimano.app.data.routes.BuilderTarget.Personal(isNew = p == null)) { c.personalRoutes.save(it.title, it) }
        _ui.update { it.copy(screen = Screen.RouteBuilder(forEvent = false), camera = builderCamera(r.points.map { p -> p.geo })) }
    }

    fun closeRouteBuilder() {
        val forEvent = (_ui.value.screen as? Screen.RouteBuilder)?.forEvent ?: false
        c.routeBuilder.close()
        _ui.update { it.copy(screen = if (forEvent) Screen.EventEdit else Screen.MyRoutes) }
    }

    /** Back in the builder: leaves at once when nothing changed, else the builder asks first. */
    fun routeBuilderBack() { if (c.routeBuilder.requestBack()) closeRouteBuilder() }

    /** Removes the route being edited from the event and leaves the builder. */
    fun deleteEventRoute(id: String) {
        c.hostEditor.removeRoute(id)
        c.routeBuilder.close()
        _ui.update { it.copy(screen = Screen.EventEdit) }
    }

    /** "Dari Laluan saya": a copy of a personal route becomes a route of the event in the editor. */
    fun copyPersonalRouteToEvent(p: my.gimano.app.data.routes.PersonalRoute) {
        val ed = c.hostEditor
        val d = ed.draft.value ?: return
        if (d.routes.size >= my.gimano.app.core.events.EventLimits.MAX_ROUTES) return
        ed.saveRoute(p.route.copy(id = my.gimano.app.core.events.EventIds.newItemId(), title = p.name.take(my.gimano.app.core.events.EventLimits.ROUTE_TITLE_CHARS),
            points = p.route.points.map { it.copy(stopId = null) }))
    }

    /**
     * "Guna dalam acara": a new event (ride / convoy / trip by mode) with a start stop (and a finish stop unless it is a
     * loop) and a copy of the route linked to them. The personal route stays as it is.
     */
    fun useRouteInEvent(p: my.gimano.app.data.routes.PersonalRoute, startLabel: String, finishLabel: String) {
        val pts = p.route.points
        if (pts.size < 2) return
        newHostEvent()
        val ed = c.hostEditor
        val first = pts.first()
        val last = pts.last()
        val loop = first.pos == last.pos
        val start = my.gimano.app.core.events.HostStop(my.gimano.app.core.events.EventIds.newItemId(), "start", startLabel, first.lat, first.lng)
        val finish = if (loop) null else my.gimano.app.core.events.HostStop(my.gimano.app.core.events.EventIds.newItemId(), "finish", finishLabel, last.lat, last.lng)
        val route = p.route.copy(
            id = my.gimano.app.core.events.EventIds.newItemId(), title = "",
            points = pts.mapIndexed { i, pt ->
                when {
                    i == 0 -> pt.copy(stopId = start.id)
                    i == pts.lastIndex -> pt.copy(stopId = finish?.id ?: start.id)
                    else -> pt.copy(stopId = null)
                }
            },
        )
        val template = when (p.route.mode) { "bicycle" -> "ride"; "motorcycle" -> "convoy"; else -> "trip" }
        ed.update { it.copy(template = template, title = p.name.take(my.gimano.app.core.events.EventLimits.TITLE_CHARS), stops = listOfNotNull(start, finish), routes = listOf(route)) }
    }

    /** Event screen: fit its stops and route lines above the bottom panel. */
    fun fitEvent(points: List<GeoPoint>, bottomDp: Int) {
        if (points.isEmpty()) return
        _ui.update { it.copy(camera = if (points.size == 1) CameraCommand.MoveTo(points[0], 15.5) else CameraCommand.Fit(points, topDp = 120, bottomDp = bottomDp)) }
    }

    /** The user's own position for routing: a fix no older than 2 min, else null. Never the camera centre. */
    private fun gpsFix(nowMs: Long = System.currentTimeMillis()): RouteOrigin.Gps {
        val n = nav.value
        // After arrival the drive's fix is frozen (GPS tracking stopped): the live location is the user's position.
        val f = if (n.active && !n.arrived) n.fix ?: _ui.value.myLocation else _ui.value.myLocation ?: n.fix
        if (f != null && f.simulated && !repo.isDemo && !debugSim()) return RouteOrigin.Gps.None
        return RouteOrigin.classify(f?.point, f?.timeMs, nowMs)
    }

    /** The user's position if a fix is no older than 2 min; null otherwise (UI must not invent "from you"). */
    fun myFreshLocation(): GeoPoint? = (gpsFix() as? RouteOrigin.Gps.Fresh)?.point

    private var originJob: Job? = null

    /** GPS origin for the current preview: fresh fix → route; stale/none with permission → wait briefly for a new fix; else unknown. */
    private fun resolveOrigin() {
        originJob?.cancel()
        routeJob?.cancel()   // routes for the previous origin/destination must not land in this preview
        val g = gpsFix()
        if (g is RouteOrigin.Gps.Fresh) { setPlanOrigin(g.point, OriginSource.GPS, null); return }
        if (repo.isDemo) { setPlanOrigin(here(), OriginSource.GPS, null); return }
        _ui.update { s -> s.copy(plan = s.plan?.copy(originPlace = null)) }
        if (!c.locations.hasPermission()) { markOriginUnknown(); return }
        _ui.update { s -> s.copy(plan = s.plan?.copy(origin = null, originSource = OriginSource.LOCATING, loading = false, routes = emptyList())) }
        originJob = viewModelScope.launch {
            val fresh = withTimeoutOrNull(8_000) {
                _ui.first { gpsFix() is RouteOrigin.Gps.Fresh }
                (gpsFix() as RouteOrigin.Gps.Fresh).point
            }
            if (_ui.value.plan?.originSource != OriginSource.LOCATING) return@launch
            if (fresh != null) setPlanOrigin(fresh, OriginSource.GPS, null) else markOriginUnknown()
        }
    }

    private fun markOriginUnknown() = _ui.update { s ->
        s.copy(plan = s.plan?.copy(origin = null, originSource = OriginSource.UNKNOWN, loading = false, error = false, routes = emptyList(), countdownRunning = false))
    }

    private fun setPlanOrigin(p: GeoPoint, source: OriginSource, place: NavDestination?) {
        originJob?.cancel()
        val plan = _ui.value.plan ?: return
        val first = plan.stops.firstOrNull()?.point ?: plan.destination.point
        val updated = plan.copy(origin = p, originSource = source, originPlace = if (source == OriginSource.GPS) null else place,
            alreadyHere = RouteOrigin.sameSpot(p, first))
        if (updated.alreadyHere) {
            _ui.update { it.copy(plan = updated.copy(loading = false, error = false, routes = emptyList(), countdownRunning = false)) }
            return
        }
        fetchRoutes(updated)
    }

    /** Route preview with no usable location: "Benarkan lokasi" came back granted → try again. */
    fun retryOrigin() { if (_ui.value.plan != null) resolveOrigin() }

    /** "Pilih titik mula pada peta". */
    fun chooseOriginOnMap() {
        val plan = _ui.value.plan ?: return
        openPickOnMap(SearchPurpose.SET_ORIGIN, start = plan.origin ?: plan.destination.point)
    }

    /** Search a start place. */
    fun chooseOriginBySearch() = openSearch(SearchPurpose.SET_ORIGIN)

    /** The "Mula dari" sheet: Lokasi semasa, Home, Work, favourites, recents. */
    fun startOptions(): List<StartOption> {
        val plan = _ui.value.plan ?: return emptyList()
        return StartOptions.build(_ui.value.saved, _ui.value.recents, plan.destination.point)
    }

    fun chooseStart(o: StartOption) {
        val p = o.point
        if (o.kind == StartOption.Kind.CURRENT || p == null) { resolveOrigin(); return }
        setPlanOrigin(p, OriginSource.CHOSEN, NavDestination(o.name, o.address, p, o.placeId))
    }

    /** ⇅: swap start and destination (stops reversed). Needs a known start. */
    fun swapStartDestination() {
        val plan = _ui.value.plan ?: return
        val o = plan.origin ?: return
        val newDest = plan.originPlace ?: NavDestination(c.app.getString(R.string.start_current), "", o, null)
        val newOrigin = plan.destination
        _ui.update { it.copy(plan = plan.copy(destination = newDest, stops = plan.stops.reversed(),
            destinationIsHere = plan.originSource == OriginSource.GPS, routes = emptyList())) }
        if (plan.destinationIsHere) resolveOrigin()   // swapping back: the start is the live position again
        else setPlanOrigin(newOrigin.point, OriginSource.CHOSEN, newOrigin)
    }

    /** "Pandu ke {start} dahulu": turn-by-turn only ever begins from the live position, so go to the chosen start. */
    fun driveToStart() {
        val start = _ui.value.plan?.originPlace ?: return
        routeTo(start)
    }

    fun routeToPlace() {
        val p = _ui.value.place?.summary ?: return
        routeTo(p.toDestination())
    }

    fun routeToSaved(sp: SavedPlace) = routeTo(NavDestination(sp.name, sp.address, GeoPoint(sp.lat, sp.lng), sp.placeId), quickPick = true)
    fun routeToRecent(r: Recent) = routeTo(NavDestination(r.name, r.address, GeoPoint(r.lat, r.lng), r.placeId), quickPick = true)

    private var routeJob: Job? = null

    private fun fetchRoutes(plan: RoutePlan) {
        routeJob?.cancel()
        val origin = plan.origin
        val first = plan.stops.firstOrNull()?.point ?: plan.destination.point
        if (origin == null || plan.originSource == OriginSource.UNKNOWN || plan.originSource == OriginSource.LOCATING) {
            _ui.update { it.copy(plan = plan.copy(loading = false, routes = emptyList(), countdownRunning = false)) }
            return
        }
        if (RouteOrigin.sameSpot(origin, first)) {   // never route a 0 m trip
            _ui.update { it.copy(plan = plan.copy(alreadyHere = true, loading = false, error = false, routes = emptyList(), countdownRunning = false)) }
            return
        }
        _ui.update { it.copy(plan = plan.copy(alreadyHere = false, loading = true, error = false, countdownRunning = false)) }
        routeJob = viewModelScope.launch {
            val req = RouteRequest(
                origin = LatLngDto(origin.lat, origin.lng),
                destination = plan.destination.toDto(),
                waypoints = plan.stops.map { it.toDto() },
                vehicle = plan.mode.wire,
                avoid = if (plan.mode.isMotorised) plan.avoid else AvoidOptions(),
                departAt = plan.departAt?.toString(),
                alternatives = if (plan.stops.isEmpty()) 2 else 0,
                ignoreIssues = plan.ignoredIssues.sorted().ifEmpty { null },
            )
            val got = runCatching { repo.routes(req) }
            // Superseded (mode/avoid/stops/origin changed, or the preview closed): the newer request owns the plan.
            (got.exceptionOrNull() as? kotlinx.coroutines.CancellationException)?.let { throw it }
            val routes = got.getOrNull().orEmpty()
            if (routes.isEmpty()) {
                _ui.update { it.copy(plan = it.plan?.copy(loading = false, error = true)) }
                return@launch
            }
            val decoded = routes.associate { it.id to runCatching { Polyline.decode(it.polyline) }.getOrDefault(emptyList()) }
            val best = routes.firstOrNull { it.isBest } ?: routes.first()
            _ui.update {
                if (it.plan == null) return@update it   // preview closed meanwhile: no routes, no camera jump
                it.copy(
                    plan = it.plan.copy(routes = routes, decoded = decoded, selectedId = best.id, loading = false, error = false, request = req,
                        // A real choice on a long trip: the list opens and nothing starts until the driver picks (design RoPilihan).
                        countdownRunning = my.gimano.app.core.trip.AutoStart.shouldCountdown(settings.current.autoStartNav, plan.quickPick,
                            plan.originSource == OriginSource.GPS, plan.stops.isNotEmpty(), plan.departAt != null, my.gimano.app.core.net.AppForeground.foreground)
                            && !my.gimano.app.core.trip.RouteChoices.listFirst(routes, plan.mode, plan.stops.isNotEmpty()),
                        showHidden = false, computedAt = Instant.now()),
                    camera = CameraCommand.Fit(my.gimano.app.core.trip.RouteChoices.shown(routes).flatMap { r -> decoded[r.id].orEmpty() } + origin + plan.destination.point,
                        topDp = 170, bottomDp = if (my.gimano.app.core.trip.RouteChoices.listFirst(routes, plan.mode, plan.stops.isNotEmpty())) 570 else 430),
                )
            }
        }
    }

    fun selectRoute(id: String) = _ui.update { s -> s.copy(plan = s.plan?.copy(selectedId = id, countdownRunning = false)) }
    fun cancelCountdown() = _ui.update { s -> s.copy(plan = s.plan?.copy(countdownRunning = false)) }
    fun openRouteList() = _ui.update { s -> s.copy(plan = s.plan?.copy(listOpen = true, countdownRunning = false)) }
    fun showHiddenRoutes() = _ui.update { s -> s.copy(plan = s.plan?.copy(showHidden = true, listOpen = true, countdownRunning = false)) }

    /** Travel mode tabs. The choice is remembered on the device and on the profile (PATCH /me). */
    fun setMode(m: TravelMode) {
        val plan = _ui.value.plan ?: return
        if (plan.mode == m) return
        rememberMode(m)
        fetchRoutes(plan.copy(mode = m))
    }

    fun rememberMode(m: TravelMode) {
        viewModelScope.launch {
            settings.setVehicle(m.wire)
            runCatching { repo.updateMe(UpdateMeRequest(vehicle = m.wire)) }
        }
    }

    fun setAvoid(a: AvoidOptions) {
        val plan = _ui.value.plan ?: return
        fetchRoutes(plan.copy(avoid = a))
    }

    // Stops in route preview
    fun addStopInPreview() {
        val plan = _ui.value.plan ?: return
        cancelCountdown()
        if (plan.stops.size >= my.gimano.app.core.trip.RouteLegs.MAX_STOPS) { _events.tryEmit(UiEvent.Toast(R.string.stops_full)); return }
        openSearch(SearchPurpose.ADD_STOP_PREVIEW)
    }

    fun removeStop(index: Int) {
        val plan = _ui.value.plan ?: return
        fetchRoutes(plan.copy(stops = StopList.remove(plan.stops, index)))
    }

    fun moveStop(from: Int, to: Int) {
        val plan = _ui.value.plan ?: return
        if (from == to) return
        fetchRoutes(plan.copy(stops = StopList.move(plan.stops, from, to)))
    }

    fun openTolls(route: Route?) = _ui.update { it.copy(tollSheet = route) }

    fun openLeaveLater() {
        cancelCountdown()
        val plan = _ui.value.plan ?: return
        viewModelScope.launch {
            val o = plan.origin ?: return@launch
            val slots = runCatching {
                repo.departureTimes(o.lat, o.lng, plan.destination.point.lat, plan.destination.point.lng, plan.mode.wire)
            }.getOrDefault(emptyList())
            _ui.update { it.copy(departureSlots = slots) }
        }
    }

    fun openBestTimeFromNav() {
        val s = nav.value
        val d = s.destination ?: return
        val o = s.fix?.point ?: here()
        viewModelScope.launch {
            val slots = runCatching { repo.departureTimes(o.lat, o.lng, d.point.lat, d.point.lng, s.mode.wire) }.getOrDefault(emptyList())
            _ui.update { it.copy(departureSlots = slots) }
        }
    }

    fun closeSlots() = _ui.update { it.copy(departureSlots = null) }

    fun chooseDeparture(slot: DepartureSlot?) {
        val plan = _ui.value.plan
        _ui.update { it.copy(departureSlots = null) }
        if (plan == null || _ui.value.screen != Screen.RoutePreview) return
        fetchRoutes(plan.copy(departAt = slot?.let { Formatters.parseInstant(it.departAt) }))
    }

    // --- Navigation -------------------------------------------------------------------------

    private var preciseAskedThisSession = false

    /** Called on start and every resume (users can switch to Approximate in Settings at any time). */
    fun refreshPrecision() {
        val p = c.locations.precision()
        _ui.update { it.copy(precision = p) }
        if (p == my.gimano.app.core.location.LocationPrecision.APPROXIMATE && !preciseAskedThisSession && _ui.value.askPrecise == null) {
            preciseAskedThisSession = true
            _ui.update { it.copy(askPrecise = PreciseAsk(beforeNav = false)) }
        }
    }

    /** The explainer was answered (after the system dialog, if the user chose to ask again). */
    fun onPreciseAnswered() {
        val ask = _ui.value.askPrecise
        _ui.update { it.copy(askPrecise = null, precision = c.locations.precision()) }
        if (ask?.beforeNav == true) startNavigation(skipPreciseCheck = true)
    }

    fun startNavigation(skipPreciseCheck: Boolean = false) {
        // docs/safety.md §1: no turn-by-turn before the safety agreement ("Setuju dahulu untuk mula memandu").
        if (!safetyAgreed()) {
            _ui.update { it.copy(safetyNeedAgreement = true, plan = it.plan?.copy(countdownRunning = false)) }
            return
        }
        if (!skipPreciseCheck && !repo.isDemo && c.locations.precision() == my.gimano.app.core.location.LocationPrecision.APPROXIMATE) {
            _ui.update { it.copy(askPrecise = PreciseAsk(beforeNav = true), plan = it.plan?.copy(countdownRunning = false)) }
            return
        }
        val plan = _ui.value.plan ?: return
        if (goActionFor(plan) != GoAction.NAVIGATE) return
        val route = plan.selected ?: return
        // docs/safety.md §2: the reminder at every START (never on resume/reroute: those don't come through here).
        when (my.gimano.app.core.safety.SafetyReminder.onStart(settings.current.safetyReminderEnabled, speedKmh(_ui.value.myLocation))) {
            my.gimano.app.core.safety.ReminderAction.CARD ->
                _ui.update { it.copy(safetyCard = SafetyCard(plan.destination.name, route.effectiveDurationS), plan = plan.copy(countdownRunning = false)) }
            my.gimano.app.core.safety.ReminderAction.BANNER -> if (beginNavigation()) showSafetyBanner()
            my.gimano.app.core.safety.ReminderAction.NONE -> beginNavigation()
        }
    }

    /** Starts guidance for the previewed route; false when there is nothing (left) to start. */
    private fun beginNavigation(): Boolean {
        val plan = _ui.value.plan ?: return false
        // Never turn-by-turn from a point that isn't the live GPS position (chosen start → "Pandu ke … dahulu").
        if (goActionFor(plan) != GoAction.NAVIGATE) return false
        val route = plan.selected ?: return false
        // Release: never fake a drive just because GPS has no fix yet (debug keeps that for desk testing).
        val simulate = repo.isDemo || settings.current.simulateDrive || (my.gimano.app.BuildConfig.DEBUG && _ui.value.myLocation == null)
        c.navigation.start(route.copy(vehicle = route.vehicle ?: plan.mode.wire), plan.destination, plan.request, simulate, plan.stops,
            detour = simulate && my.gimano.app.BuildConfig.DEBUG && settings.current.simulateDetour)
        _ui.update { it.copy(screen = Screen.Navigating, following = true, navExpanded = false, plan = plan.copy(countdownRunning = false)) }
        return true
    }

    // --- Safety (docs/safety.md) -----------------------------------------------------------------

    /** Agreed in this session, before the (asynchronous) save lands. */
    @Volatile private var agreedNow = false

    fun safetyAgreed(): Boolean = agreedNow || !my.gimano.app.core.safety.SafetyAgreement.needsAgreement(settings.current.safetyAgreedVersion)

    /** A fix's speed (km/h), or null when unknown or older than 10 s (a stale speed says nothing about now). */
    private fun speedKmh(f: Fix?): Double? =
        f?.takeIf { System.currentTimeMillis() - it.timeMs < 10_000 }?.speedMps?.let { it * 3.6 }

    /** "Saya faham dan setuju": stored on this phone only (version + date); a drive waiting for it starts now. */
    fun agreeSafety() {
        val mode = _ui.value.safetyAgreement
        agreedNow = true
        viewModelScope.launch { settings.agreeSafety(my.gimano.app.core.safety.SafetyAgreement.VERSION, Instant.now().toString()) }
        _ui.update { it.copy(safetyAgreement = null) }
        if (mode == AgreementMode.BEFORE_DRIVE) startNavigation()
    }

    /** "Belum setuju" (or closing a re-read): the map, search and route preview keep working. */
    fun closeAgreement() = _ui.update { it.copy(safetyAgreement = null) }

    fun openAgreement(mode: AgreementMode) = _ui.update { it.copy(safetyAgreement = mode, safetyNeedAgreement = false) }

    fun dismissNeedAgreement() = _ui.update { it.copy(safetyNeedAgreement = false) }

    /** "Faham, mula pandu" (with "Jangan tunjuk lagi" ticked or not). */
    fun confirmSafetyCard(dontShowAgain: Boolean) {
        val card = _ui.value.safetyCard ?: return
        _ui.update { it.copy(safetyCard = null) }
        if (dontShowAgain) {
            viewModelScope.launch { settings.setSafetyReminder(false, Instant.now().toString()) }
            _events.tryEmit(UiEvent.Toast(R.string.safety_card_off_toast))
        }
        if (!card.preview) beginNavigation()
    }

    /** Back on the card: nothing starts (the route preview stays). */
    fun dismissSafetyCard() = _ui.update { it.copy(safetyCard = null) }

    fun previewSafetyCard() = _ui.update { it.copy(safetyCard = SafetyCard(null, null, preview = true)) }

    fun setSafetyReminder(enabled: Boolean) = viewModelScope.launch { settings.setSafetyReminder(enabled, Instant.now().toString()) }

    private var bannerJob: Job? = null
    private fun showSafetyBanner() {
        bannerJob?.cancel()
        _ui.update { it.copy(safetyBanner = true) }
        bannerJob = viewModelScope.launch {
            delay(my.gimano.app.core.safety.SafetyReminder.BANNER_MS)
            _ui.update { it.copy(safetyBanner = false) }
        }
    }

    /** Debug builds only: forget the agreement and turn the reminder back on (tests the first run without wiping data). */
    fun debugResetSafety() {
        if (!my.gimano.app.BuildConfig.DEBUG) return
        agreedNow = false
        viewModelScope.launch { settings.resetSafetyDebug() }
        _ui.update { it.copy(safetyAgreement = AgreementMode.FIRST_RUN) }
    }

    /** Debug builds only (MainActivity extra `gimano.moveTo`). */
    /**
     * DEBUG builds only: replay a drive along a freshly planned route (see MainActivity `gimano.debugDrive`), at
     * [cruiseKmh] with slow turns, starting [startAlongM] metres in. [jamAtM] adds a 1.2 km level-4 jam there (+6 min) so
     * the "Tinjau" camera can be seen at a desk. Nothing about it is sent anywhere (simulated drives send no pings).
     */
    fun debugDrive(from: GeoPoint, to: GeoPoint, placeId: String?, name: String, cruiseKmh: Double, startAlongM: Double, jamAtM: Double?) {
        if (!my.gimano.app.BuildConfig.DEBUG) return
        viewModelScope.launch {
            val req = RouteRequest(LatLngDto(from.lat, from.lng), LatLngDto(to.lat, to.lng, placeId, name.takeIf { placeId != null }), vehicle = "car", alternatives = 0)
            val route = runCatching { repo.routes(req).firstOrNull() }.onFailure { GLog.w("Debug", "debugDrive: ${it.javaClass.simpleName}") }.getOrNull() ?: return@launch
            val r = if (jamAtM == null) route else {
                val g = my.gimano.app.core.nav.RouteGeometry(my.gimano.app.core.geo.Polyline.decode(route.polyline))
                val a = g.segmentAt(jamAtM); val b = g.segmentAt(jamAtM + 1_200) + 1
                route.copy(trafficSegments = route.trafficSegments + TrafficSegment(a, b, 4), trafficDurationS = route.effectiveDurationS + 360)
            }
            c.navigation.debugSim = my.gimano.app.nav.NavigationController.DebugSim(cruiseKmh, startAlongM)
            c.navigation.start(r, NavDestination(name, "", to, placeId), req, simulate = true)
            _ui.update { it.copy(screen = Screen.Navigating, following = true, navExpanded = false, plan = null) }
        }
    }

    fun debugMoveTo(p: GeoPoint, zoom: Double) {
        if (!my.gimano.app.BuildConfig.DEBUG) return
        centeredOnce = true
        _ui.update { it.copy(screen = Screen.Home, following = false, camera = CameraCommand.MoveTo(p, zoom)) }
    }

    fun openRestrictedSheet(open: Boolean) = _ui.update { it.copy(restrictedSheet = open) }

    fun stopNavigation() {
        c.navigation.stop()
        collapseHomeSheet()
        viewModelScope.launch { c.share.stop() }
        _ui.update { it.copy(screen = Screen.Home, plan = null, navExpanded = false, confirmStop = false, passengerPrompt = false, following = true, camera = CameraCommand.Reset2D(here(), 15.0)) }
    }

    fun continueAfterStop() = c.navigation.continueAfterStop()

    /** Back / End during a drive asks first; never traps the driver, never keeps navigating silently. */
    fun askStop(v: Boolean) = _ui.update { it.copy(confirmStop = v) }

    fun setNavExpanded(v: Boolean) = _ui.update { it.copy(navExpanded = v) }

    fun overview() {
        val r = nav.value.route ?: return
        val pts = runCatching { Polyline.decode(r.polyline) }.getOrDefault(emptyList())
        _ui.update { it.copy(following = false, camera = CameraCommand.Fit(pts, topDp = 200, bottomDp = 260)) }
    }

    /** "Share my drive": end-to-end encrypted live ETA link (docs/api.md "Share my drive"). */
    val sharing = c.share.active

    fun shareDrive() {
        val s = nav.value
        val d = s.destination ?: return
        // The live link carries the destination name: never an event stop's label.
        if (d.eventStop || s.stops.any { it.eventStop }) return
        setNavExpanded(false)
        viewModelScope.launch {
            try {
                val share = c.share.start()
                val eta = s.progress?.let { Formatters.etaClock(Instant.now(), it.remainingS, ZoneId.systemDefault(), settings.current.use24h, c.lang()) } ?: "-"
                _events.tryEmit(UiEvent.Share("__share_drive__|${d.name}|$eta|${share.link}"))
            } catch (e: Exception) {
                _events.tryEmit(UiEvent.Toast(R.string.share_failed))
            }
        }
    }

    fun stopSharing() = viewModelScope.launch { c.share.stop(); _events.tryEmit(UiEvent.Toast(R.string.sharing_stopped)) }

    fun addStop() {
        setNavExpanded(false)
        if (nav.value.stops.size >= my.gimano.app.core.trip.RouteLegs.MAX_STOPS) { _events.tryEmit(UiEvent.Toast(R.string.stops_full)); return }
        openSearch(SearchPurpose.ADD_STOP)
    }

    // --- Feedback -----------------------------------------------------------------------------

    fun requestFeedback(screen: String) {
        val s = _ui.value
        if (s.screen == Screen.Navigating && nav.value.active && !FeedbackRules.allowedWhileNavigating(nav.value.speedKmh, false)) {
            _ui.update { it.copy(passengerPrompt = true) }
            return
        }
        openFeedbackNow(screen)
    }

    fun confirmPassenger(yes: Boolean) {
        _ui.update { it.copy(passengerPrompt = false) }
        if (yes) openFeedbackNow("navigation") else _events.tryEmit(UiEvent.Toast(R.string.feedback_later))
    }

    private fun openFeedbackNow(screen: String) {
        setNavExpanded(false)
        _events.tryEmit(UiEvent.OpenFeedback(screen, nav.value.route?.id ?: _ui.value.plan?.selected?.id, _ui.value.place?.summary?.id?.takeUnless { it.startsWith("pin:") || it.startsWith("private:") }))
    }

    // --- Misc -------------------------------------------------------------------------------

    fun goHome() {
        val nav = nav.value
        _ui.update { it.copy(screen = if (nav.active) Screen.Navigating else Screen.Home, place = null, departureSlots = null) }
    }

    fun open(screen: Screen) = _ui.update { it.copy(screen = screen) }

    fun back() {
        val s = _ui.value
        when {
            s.favoriteSheet != null -> closeFavoriteSheet()
            s.tollSheet != null -> openTolls(null)
            else -> when (s.screen) {
                is Screen.Search -> when ((s.screen as Screen.Search).purpose) {
                    SearchPurpose.ADD_STOP -> _ui.update { it.copy(screen = Screen.Navigating) }
                    SearchPurpose.ADD_STOP_PREVIEW, SearchPurpose.SET_ORIGIN -> _ui.update { it.copy(screen = Screen.RoutePreview) }
                    SearchPurpose.EVENT_STOP, SearchPurpose.EVENT_ENTRANCE -> _ui.update { it.copy(screen = Screen.EventEdit) }
                    else -> goHome()
                }
                Screen.PlaceCard -> goHome()
                is Screen.PickOnMap -> {
                    val pk = s.pick
                    _ui.update { it.copy(pick = null, screen = pk?.returnTo ?: Screen.Home, favoriteSheet = pk?.favoriteDraft) }
                }
                Screen.PinActions -> { _ui.update { it.copy(pin = null) }; goHome() }
                // Back to the place card at the place's zoom (not the route overview), pin centred above the card.
                Screen.RoutePreview -> if (s.place != null) _ui.update {
                    it.copy(screen = Screen.PlaceCard, plan = null, camera = CameraCommand.MoveTo(GeoPoint(s.place.summary.lat, s.place.summary.lng), 15.5))
                } else if (s.plan?.returnToEvent != null) _ui.update {
                    it.copy(screen = Screen.EventDetail(s.plan.returnToEvent), plan = null)
                } else _ui.update { it.copy(screen = Screen.Home, plan = null) }
                Screen.Settings -> goHome()
                Screen.Backup, Screen.MyFeedback, Screen.Account, Screen.About, Screen.Safety -> _ui.update { it.copy(screen = Screen.Settings) }
                Screen.Licences -> _ui.update { it.copy(screen = Screen.About) }
                Screen.Contributions, Screen.AddPlace, Screen.Planned, Screen.Favourites, Screen.Inbox -> goHome()
                Screen.Theme -> goHome()
                Screen.Events -> goHome()
                is Screen.EventDetail -> _ui.update { it.copy(screen = Screen.Events) }
                Screen.EventEdit -> eventWizardBack()
                Screen.EventShare -> { c.hostEditor.closeShare(); _ui.update { it.copy(screen = Screen.EventEdit) } }
                is Screen.RouteBuilder -> routeBuilderBack()
                Screen.MyRoutes -> goHome()
                Screen.Navigating -> when {
                    s.navExpanded -> setNavExpanded(false)
                    nav.value.arrived -> stopNavigation()
                    else -> askStop(true)
                }
                Screen.Home -> Unit
            }
        }
    }

    fun openSettings() = _ui.update { it.copy(screen = Screen.Settings) }

    /** Sound panel: a row picked (canvas NavBunyi). Remembered across drives; a 2 s toast says what it does. */
    fun selectSound(mode: SoundMode) {
        if (mode == settings.current.soundMode) return
        viewModelScope.launch { settings.setSoundMode(mode) }
        if (mode == SoundMode.OFF) c.voice.stop()   // mute takes effect mid-sentence
        _events.tryEmit(UiEvent.BriefToast(soundToast(mode), mode))
    }

    /** Long-press on the sound FAB: quick mute, or back to the last non-mute mode. */
    fun toggleMute() = selectSound(my.gimano.app.data.settings.SoundModes.longPress(settings.current.soundMode, settings.current.lastNonMuteSound))

    fun setVoiceVolume(percent: Int) { viewModelScope.launch { settings.setVoiceVolume(percent) } }

    private fun soundToast(m: SoundMode) = when (m) {
        SoundMode.ON -> R.string.sound_toast_on
        SoundMode.ALERTS_ONLY -> R.string.sound_toast_alerts
        SoundMode.OFF -> R.string.sound_toast_off
    }

    fun setLayers(traffic: Boolean, alerts: Boolean, drivers: Boolean) {
        viewModelScope.launch { settings.setLayers(traffic, alerts, drivers) }
    }

    fun setDemoMode(v: Boolean) {
        viewModelScope.launch {
            settings.setDemoMode(v)
            if (!v) retryServer() else { c.liveHub.stop(); refreshAccount() }
            boundsFlow.value?.let { loadLive(it) }
        }
    }
    fun setSimulate(v: Boolean) = viewModelScope.launch { settings.setSimulateDrive(v) }
    fun setSimulateDetour(v: Boolean) = viewModelScope.launch { settings.setSimulateDetour(v) }

    /** Debug builds with "Simulate drive": simulated positions count as the user's, and a chosen start can be driven. */
    private fun debugSim() = my.gimano.app.BuildConfig.DEBUG && settings.current.simulateDrive

    /** What "Go" does for [plan] (debug simulation may drive from a chosen start; release never does). */
    fun goActionFor(plan: RoutePlan): GoAction =
        if (debugSim() && plan.originSource == OriginSource.CHOSEN && plan.goAction == GoAction.DRIVE_TO_START) GoAction.NAVIGATE else plan.goAction
    fun setVoiceLang(v: String) = viewModelScope.launch { settings.setVoiceLang(v) }
    fun setSoundMode(v: SoundMode) = viewModelScope.launch { settings.setSoundMode(v) }
    fun setUse24h(v: Boolean) = viewModelScope.launch { settings.setUse24h(v) }
    fun setAutoStartNav(v: Boolean) = viewModelScope.launch { settings.setAutoStartNav(v) }
    fun setVehicleHome(v: String) = rememberMode(TravelMode.from(v))
    fun setApiBaseUrl(v: String) = viewModelScope.launch {
        settings.setApiBaseUrl(v)
        c.liveHub.stop()
        retryServer()
    }
    fun setMapStyleUrl(v: String) = viewModelScope.launch { settings.setMapStyleUrl(v) }
    fun setDisplayName(v: String) = viewModelScope.launch {
        settings.setDisplayName(v)
        runCatching { repo.updateMe(UpdateMeRequest(displayName = v)) }.onSuccess { u -> _ui.update { it.copy(user = u) } }
    }
    fun setTheme(v: String) = viewModelScope.launch {
        settings.setTheme(v)
        local.putSetting("theme", v)   // also in the shared settings table (travels with backups)
    }
    fun dismissPrivacyCard() = viewModelScope.launch { settings.setPrivacyCardDismissed() }

    fun toast(@StringRes r: Int) = _events.tryEmit(UiEvent.Toast(r))

    class Factory(private val c: AppContainer) : ViewModelProvider.Factory {
        @Suppress("UNCHECKED_CAST")
        override fun <T : ViewModel> create(modelClass: Class<T>): T = MainViewModel(c) as T
    }
}

/** The card after a quick report (§6.4); [startedMs] is SystemClock.elapsedRealtime() at release (the 5 s Undo). */
data class QuickReportCard(val key: Long, val type: String, val street: String?, val startedMs: Long, val sent: Boolean = false)
