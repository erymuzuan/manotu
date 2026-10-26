package my.gimano.app.ui

import android.content.Intent
import android.net.Uri
import androidx.activity.compose.BackHandler
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import kotlinx.coroutines.launch
import my.gimano.app.R
import my.gimano.app.core.format.Formatters
import my.gimano.app.core.geo.Polyline
import my.gimano.app.ui.home.HomeOverlay
import my.gimano.app.ui.home.MapTopControls
import my.gimano.app.ui.map.GimanoMap
import my.gimano.app.ui.map.MapHandle
import my.gimano.app.ui.map.MapRenderState
import my.gimano.app.ui.map.RouteDraw
import my.gimano.app.ui.menu.SideMenu
import my.gimano.app.ui.navigation.NavigationOverlay
import my.gimano.app.ui.place.PlaceCard
import my.gimano.app.ui.report.ReportSheet
import my.gimano.app.ui.report.currentLang
import my.gimano.app.ui.route.RoutePreviewOverlay
import my.gimano.app.ui.search.SearchScreen
import my.gimano.app.ui.settings.SettingsScreen
import my.gimano.app.ui.theme.Gimano
import java.time.ZoneId
import java.time.ZonedDateTime

@Composable
fun GimanoRoot(vm: MainViewModel, onMic: () -> Unit, onExit: () -> Unit, onRequestPrecise: () -> Unit = {}, onRequestLocation: () -> Unit = {}) {
    val container = (LocalContext.current.applicationContext as my.gimano.app.GimanoApp).container
    val fvm: my.gimano.app.ui.feedback.FeedbackViewModel = androidx.lifecycle.viewmodel.compose.viewModel(factory = my.gimano.app.ui.feedback.FeedbackViewModel.Factory(container))
    val bvm: my.gimano.app.ui.backup.BackupViewModel = androidx.lifecycle.viewmodel.compose.viewModel(factory = my.gimano.app.ui.backup.BackupViewModel.Factory(container))
    val feedbackDraft by fvm.draft.collectAsStateWithLifecycle()
    val cvm: my.gimano.app.ui.contribute.ContributeViewModel = androidx.lifecycle.viewmodel.compose.viewModel(factory = my.gimano.app.ui.contribute.ContributeViewModel.Factory(container))
    val pvm: my.gimano.app.ui.planned.PlannedViewModel = androidx.lifecycle.viewmodel.compose.viewModel(factory = my.gimano.app.ui.planned.PlannedViewModel.Factory(container))
    val ui by vm.ui.collectAsStateWithLifecycle()
    val nav by vm.nav.collectAsStateWithLifecycle()
    val settings by vm.settingsState.collectAsStateWithLifecycle()
    val upd by container.updater.ui.collectAsStateWithLifecycle()
    val homeSheetDp by vm.homeSheetDp.collectAsStateWithLifecycle()
    val placeSheetDp by vm.placeSheetDp.collectAsStateWithLifecycle()
    var updateSheetOpen by remember { mutableStateOf(true) }
    var forceUpdateSheet by remember { mutableStateOf(false) }
    LaunchedEffect(Unit) { container.updater.check() }   // on launch; at most every 6 h
    LaunchedEffect(Unit) { container.crashes.onAppStart() }
    // data objects' toString() is a compile-time constant (survives R8); data classes → "Search(purpose=…)".
    LaunchedEffect(ui.screen) { container.crashes.screen = ui.screen.toString().substringBefore('(').lowercase() }
    val crashPending by container.crashes.pending.collectAsStateWithLifecycle()
    val fallback by vm.fallbackActive.collectAsStateWithLifecycle()
    val handle = remember { MapHandle() }
    val restrictedAreas by container.restricted.areas.collectAsStateWithLifecycle()
    // Events (docs/events.md): the open event, its selected stop, and the import dialogs' "open this event".
    val eventVersion by container.eventStore.version.collectAsStateWithLifecycle()
    val eventScreen = ui.screen as? Screen.EventDetail
    val eventDetail by produceState<my.gimano.app.data.events.SavedEvent?>(null, eventScreen?.id, eventVersion) {
        value = eventScreen?.let { runCatching { container.eventStore.load(it.id) }.getOrNull() }
    }
    var eventStopSel by remember(eventScreen?.id) { mutableStateOf(eventScreen?.stopId) }
    // An event from a short link (§5.6) is re-fetched when it is opened, so later revisions arrive by themselves.
    LaunchedEffect(eventScreen?.id) { eventScreen?.id?.let(container.eventImporter::refresh) }
    val eventPanelFraction = 0.58f
    val screenHeightDp = androidx.compose.ui.platform.LocalConfiguration.current.screenHeightDp
    LaunchedEffect(Unit) {
        container.eventImporter.open.collect { (id, stop) ->
            // The host's own event opens in the editor, never as an invitation from someone else.
            if (runCatching { container.hostStore.isHosted(id) }.getOrDefault(false)) vm.openHostEvent(id) else vm.open(Screen.EventDetail(id, stop))
        }
    }
    LaunchedEffect(eventDetail?.hash) {
        eventDetail?.let { vm.fitEvent(my.gimano.app.core.events.EventSchedule.mapPoints(it.plan), bottomDp = (screenHeightDp * eventPanelFraction).toInt() + 24) }
    }
    val drawer = rememberDrawerState(DrawerValue.Closed)
    val snackbar = remember { SnackbarHostState() }
    val scope = rememberCoroutineScope()
    val context = LocalContext.current

    val unreachableMsg = stringResource(R.string.server_unreachable)
    val retryLabel = stringResource(R.string.retry)
    LaunchedEffect(fallback) {
        if (fallback && !settings.demoMode) {
            val r = snackbar.showSnackbar(unreachableMsg, retryLabel, withDismissAction = true, duration = SnackbarDuration.Short)
            if (r == SnackbarResult.ActionPerformed) vm.retryServer()
        }
    }
    LaunchedEffect(Unit) {
        vm.events.collect { e ->
            when (e) {
                is UiEvent.Toast -> scope.launch { snackbar.currentSnackbarData?.dismiss(); snackbar.showSnackbar(context.getString(e.res)) }
                is UiEvent.BriefToast -> scope.launch {
                    snackbar.currentSnackbarData?.dismiss()
                    val msg = context.getString(e.res)
                    val shown = launch {
                        if (e.sound != null) snackbar.showSnackbar(SoundSnackVisuals(msg, e.sound)) else snackbar.showSnackbar(msg, duration = SnackbarDuration.Indefinite)
                    }
                    kotlinx.coroutines.delay(2_000); shown.cancel()   // cancelling dismisses it
                }
                is UiEvent.Share -> {
                    val text = if (e.text.startsWith("__share_drive__|")) {
                        val (_, name, eta, link) = e.text.split("|")
                        context.getString(R.string.share_drive_text, name, eta, link)
                    } else e.text
                    context.startActivity(Intent.createChooser(Intent(Intent.ACTION_SEND).setType("text/plain").putExtra(Intent.EXTRA_TEXT, text), null))
                }
                is UiEvent.ToastText -> scope.launch { snackbar.currentSnackbarData?.dismiss(); snackbar.showSnackbar(e.text) }
                is UiEvent.OpenFeedback -> scope.launch {
                    // Capture what's behind the sheet first (map included: PixelCopy reads the window).
                    val shot = (context as? android.app.Activity)?.let { my.gimano.app.ui.feedback.ScreenCapture.capture(it) }
                    val jpeg = shot?.let { my.gimano.app.ui.feedback.ScreenCapture.toJpeg(it) }
                    fvm.open(e.screen, jpeg, e.routeId, e.placeId)
                }
                is UiEvent.AddPlace -> { vm.startAddPlace(e.at, e.name); cvm.startAdd(e.at, e.name) }
                is UiEvent.PlanDrive -> pvm.newPlan(e.dest, e.origin, e.waypoints, e.vehicle)
                is UiEvent.Dial -> runCatching { context.startActivity(Intent(Intent.ACTION_DIAL, Uri.parse("tel:${e.phone}"))) }
                is UiEvent.Web -> runCatching { context.startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(e.url))) }
            }
        }
    }

    // A banned account's contribution was refused (403): one plain message, not a generic error.
    val bannedMsg = stringResource(R.string.banned_message, my.gimano.app.ui.about.CONTACT_EMAIL)
    LaunchedEffect(Unit) {
        my.gimano.app.data.repo.Moderation.banned.collect {
            snackbar.currentSnackbarData?.dismiss()
            snackbar.showSnackbar(bannedMsg, duration = SnackbarDuration.Long)
        }
    }
    LaunchedEffect(Unit) {
        cvm.events.collect { e ->
            when (e) {
                is my.gimano.app.ui.contribute.ContribEvent.Message -> { snackbar.currentSnackbarData?.dismiss(); snackbar.showSnackbar(context.getString(e.res)) }
                is my.gimano.app.ui.contribute.ContribEvent.Text -> { snackbar.currentSnackbarData?.dismiss(); snackbar.showSnackbar(e.text) }
                is my.gimano.app.ui.contribute.ContribEvent.ShowPlace -> vm.showPlace(e.summary)
                my.gimano.app.ui.contribute.ContribEvent.Close -> vm.back()
                my.gimano.app.ui.contribute.ContribEvent.OpenMyPlaces -> vm.open(Screen.Contributions)
                my.gimano.app.ui.contribute.ContribEvent.OpenAddPlace -> vm.open(Screen.AddPlace)
                is my.gimano.app.ui.contribute.ContribEvent.Share ->
                    context.startActivity(Intent.createChooser(Intent(Intent.ACTION_SEND).setType("text/plain").putExtra(Intent.EXTRA_TEXT, e.text), null))
            }
        }
    }
    LaunchedEffect(Unit) {
        fvm.result.collect { r ->
            val msg = when (r) {
                my.gimano.app.data.feedback.FeedbackSendResult.Sent -> R.string.fb_sent
                my.gimano.app.data.feedback.FeedbackSendResult.Queued -> R.string.fb_queued
                is my.gimano.app.data.feedback.FeedbackSendResult.Rejected -> R.string.fb_rejected
            }
            snackbar.currentSnackbarData?.dismiss(); snackbar.showSnackbar(context.getString(msg))
        }
    }

    val screen = ui.screen
    BackHandler(enabled = drawer.isOpen || screen != Screen.Home) {
        if (drawer.isOpen) scope.launch { drawer.close() } else vm.back()
    }
    LaunchedEffect(handle.userMovedCamera) {
        if (handle.userMovedCamera) {
            vm.onUserPanned()
            if (screen == Screen.RoutePreview) vm.cancelCountdown()
            handle.clearUserMoved()
        }
    }
    // If navigation ends elsewhere (notification "Stop"), leave the driving screen.
    LaunchedEffect(nav.active) {
        if (!nav.active && screen == Screen.Navigating) vm.stopNavigation()
    }

    // Route builder ("Bina laluan"): its state, and the finger handling the map hands over (drag a point, draw).
    val builderUi by container.routeBuilder.ui.collectAsStateWithLifecycle()
    val builderTouch = my.gimano.app.ui.routes.rememberBuilderTouch(container.routeBuilder, handle)
    val building = screen is Screen.RouteBuilder && builderUi != null
    // Steady arrow + camera modes (docs/driving.md §2–3): fed every navigation state, drawn every frame by the map.
    val driveRenderer = remember { my.gimano.app.nav.DriveRenderer() }
    LaunchedEffect(nav) { driveRenderer.onState(nav, android.os.SystemClock.elapsedRealtime()) }
    val navPoints = remember(nav.route?.id) { nav.route?.let { runCatching { Polyline.decode(it.polyline) }.getOrNull() }.orEmpty() }
    val navigating = screen == Screen.Navigating || (screen is Screen.Search && nav.active)
    val renderState = MapRenderState(
        lastMetres = when {
            navigating && nav.route != null -> my.gimano.app.core.nav.LastMetres.lines(navPoints.lastOrNull(),
                nav.route?.arrival?.let { my.gimano.app.core.geo.GeoPoint(it.lat, it.lng) }, nav.destination?.point)
            screen == Screen.RoutePreview -> ui.plan?.selected?.let { r ->
                my.gimano.app.core.nav.LastMetres.lines(ui.plan?.decoded?.get(r.id)?.lastOrNull(),
                    r.arrival?.let { my.gimano.app.core.geo.GeoPoint(it.lat, it.lng) }, ui.plan?.destination?.point)
            }.orEmpty()
            else -> emptyList()
        },
        tolls = when {
            navigating -> nav.route?.tolls.orEmpty().map { my.gimano.app.core.geo.GeoPoint(it.lat, it.lng) }
            screen == Screen.RoutePreview -> ui.plan?.selected?.tolls.orEmpty().map { my.gimano.app.core.geo.GeoPoint(it.lat, it.lng) }
            else -> emptyList()
        },
        routes = when {
            navigating && nav.route != null -> listOf(RouteDraw(nav.route!!.id, navPoints, true, nav.route!!.trafficSegments))
            screen == Screen.RoutePreview -> ui.plan?.visibleRoutes.orEmpty().map { r ->
                RouteDraw(r.id, ui.plan?.decoded?.get(r.id).orEmpty(), r.id == ui.plan?.selected?.id, r.trafficSegments)
            }
            // Sketch / GPX routes are drawn dashed (builder layer) so nobody mistakes them for roads.
            screen is Screen.EventDetail -> eventDetail?.plan?.routes.orEmpty().filter { it.source.navigable }.map { r -> RouteDraw("event-" + r.id, r.points, true, emptyList()) }
            else -> emptyList()
        },
        alerts = if (building) emptyList() else ui.alerts + if (screen == Screen.RoutePreview) ui.plan?.selected?.alerts.orEmpty().map { it.toReport() }.filter { a -> ui.alerts.none { it.id == a.id } } else emptyList(),
        jams = ui.jams,
        drivers = ui.drivers,
        // While driving, the steady arrow is drawn by the map's per-frame renderer (drive = …), not from here.
        puck = if (navigating && nav.active) null else if (navigating) nav.puck ?: nav.fix?.point else ui.myLocation?.point,
        puckBearing = if (navigating) nav.puckBearing.toFloat() else ui.myLocation?.bearing ?: 0f,
        puckAccuracyM = if (navigating) nav.accuracyM ?: nav.fix?.accuracyM?.toDouble() else ui.myLocation?.accuracyM?.toDouble(),
        pin = when (screen) {
            Screen.PlaceCard -> ui.place?.summary?.let { my.gimano.app.core.geo.GeoPoint(it.lat, it.lng) }
            Screen.PinActions -> ui.pin?.place?.let { my.gimano.app.core.geo.GeoPoint(it.lat, it.lng) }
            Screen.RoutePreview -> ui.plan?.destination?.point
            is Screen.EventDetail -> eventStopSel?.let { id -> eventDetail?.plan?.stop(id)?.navigationTarget }
            else -> if (navigating) nav.destination?.point else null
        },
        privatePins = if (screen == Screen.Home || screen == Screen.PlaceCard) ui.privatePins else emptyList(),
        stops = when {
            navigating -> nav.stops.map { it.point }
            screen == Screen.RoutePreview -> ui.plan?.stops.orEmpty().map { it.point }
            screen is Screen.EventDetail -> eventDetail?.plan?.stops.orEmpty().map { it.pin }
            building -> builderUi?.stops.orEmpty().map { it.pos.geo }
            else -> emptyList()
        },
        showTraffic = settings.showTraffic,
        showAlerts = settings.showAlerts,
        showDrivers = settings.showDrivers,
        navigating = navigating,
        builder = when {
            building -> my.gimano.app.ui.routes.builderDraw(builderUi!!, builderTouch)
            screen is Screen.EventDetail -> eventDetail?.plan?.routes.orEmpty().filter { !it.source.navigable }
                .takeIf { it.isNotEmpty() }?.let { rs -> my.gimano.app.ui.map.BuilderDraw(rs.map { my.gimano.app.ui.map.BuilderLine(it.points, "sketch") }) }
            else -> null
        },
    )

    ModalNavigationDrawer(
        drawerState = drawer,
        gesturesEnabled = drawer.isOpen,
        drawerContent = {
            SideMenu(
                ui.user, inboxUnread = ui.inbox.count { it.id !in settings.inboxRead },
                updateVersion = (upd.decision as? my.gimano.app.core.update.UpdateDecision.Available)?.manifest?.versionName,
                onUpdate = { scope.launch { drawer.close() }; updateSheetOpen = true; forceUpdateSheet = true; vm.goHome() },
                onProfile = { scope.launch { drawer.close() }; vm.open(Screen.Contributions) },
                onFavourites = { scope.launch { drawer.close() }; vm.open(Screen.Favourites) },
                onPlanned = { scope.launch { drawer.close() }; vm.open(Screen.Planned) },
                onEvents = { scope.launch { drawer.close() }; vm.open(Screen.Events) },
                onMyRoutes = { scope.launch { drawer.close() }; vm.openMyRoutes() },
                onInbox = { scope.launch { drawer.close() }; vm.open(Screen.Inbox) },
                onContributions = { scope.launch { drawer.close() }; vm.open(Screen.Contributions) },
                onAddPlace = { scope.launch { drawer.close() }; vm.startAddPlace(vm.here(), ""); cvm.startAdd(vm.here(), "") },
                onBackup = { scope.launch { drawer.close() }; vm.open(Screen.Backup) },
                onTheme = { scope.launch { drawer.close() }; vm.open(Screen.Theme) },
                onFeedback = { scope.launch { drawer.close() }; vm.requestFeedback("home") },
                onSettings = { scope.launch { drawer.close() }; vm.openSettings() },
            )
        },
    ) {
        Box(Modifier.fillMaxSize()) {
            GimanoMap(
                styleUrl = if (Gimano.colors.isDark) my.gimano.app.BuildConfig.MAP_STYLE_DARK_URL else settings.mapStyleUrl,
                state = renderState,
                camera = ui.camera,
                handle = handle,
                // The place card keeps its pin centred in the map left visible between the status bar and the card.
                bottomInsetDp = when {
                    screen == Screen.Home -> homeSheetDp
                    screen == Screen.PlaceCard && placeSheetDp > 0 -> placeSheetDp
                    else -> 0
                },
                topInsetDp = if (screen == Screen.PlaceCard && placeSheetDp > 0) WindowInsets.statusBars.asPaddingValues().calculateTopPadding().value.toInt() else 0,
                focus = if (screen == Screen.PlaceCard && placeSheetDp > 0) ui.place?.summary?.let { my.gimano.app.core.geo.GeoPoint(it.lat, it.lng) } else null,
                modifier = Modifier.fillMaxSize(),
                onCameraIdle = vm::onCameraIdle,
                onMapClick = { p ->
                    if (screen == Screen.Home) { vm.selectAlert(null); vm.collapseHomeSheet() }
                    else if (building) container.routeBuilder.tapMap(my.gimano.app.core.routes.Pos.of(p))
                },
                onMapLongClick = { p -> if (!building) vm.dropPin(p) },
                touchInterceptor = if (building) builderTouch::onTouch else null,
                onAlertClick = { id -> if (screen == Screen.Home || screen == Screen.PlaceCard) { vm.goHome(); vm.selectAlert(id) } },
                onRouteClick = { id -> if (screen == Screen.RoutePreview) vm.selectRoute(id) },
                onPrivateClick = { id -> if (screen == Screen.Home || screen == Screen.PlaceCard) vm.showPrivate(id) },
                restricted = restrictedAreas,
                drive = if (navigating && nav.active) driveRenderer else null,
                driveFollow = ui.following,
                driveTopDp = 190, driveBottomDp = 150,
                // docs/safety.md §4 D: tapping inside a restricted area explains it (no names, no details).
                onRestrictedClick = {
                    if (screen == Screen.Home || screen == Screen.PlaceCard || screen == Screen.PinActions) { vm.openRestrictedSheet(true); true } else false
                },
            )
            when (screen) {
                Screen.Home -> {
                    MapTopControls(ui, settings, vm, vm.isDemo || fallback, showMenu = true, onMenu = { scope.launch { drawer.open() } }, showRecenter = false)
                    HomeOverlay(ui, settings, vm, onMic)
                    if (handle.ready) androidx.compose.material3.FilledTonalButton(
                        onClick = { handle.captureSearchArea?.invoke()?.let(vm::searchThisArea) },
                        modifier = Modifier.align(Alignment.TopCenter).padding(top = 104.dp)
                    ) { Text(stringResource(R.string.search_this_area)) }
                }
                is Screen.PickOnMap -> ui.pick?.let { my.gimano.app.ui.pick.PickOnMapOverlay(it, vm, (ui.screen as Screen.PickOnMap).purpose) }
                Screen.PinActions -> {
                    MapTopControls(ui, settings, vm, vm.isDemo || fallback, showMenu = false, onMenu = {})
                    ui.pin?.let { my.gimano.app.ui.pick.PinActionsSheet(it, vm, Modifier.align(Alignment.BottomCenter)) }
                }
                Screen.PlaceCard -> {
                    // The recentre button sits above the card (it goes back to the pin).
                    MapTopControls(ui, settings, vm, vm.isDemo || fallback, showMenu = false, onMenu = {}, showRecenter = false)
                    ui.place?.let { PlaceCard(it, vm, cvm, settings.apiBaseUrl, Modifier.align(Alignment.BottomCenter)) }
                }
                Screen.RoutePreview -> ui.plan?.let { RoutePreviewOverlay(it, settings, vm, handle, onRequestLocation) }
                Screen.Navigating -> NavigationOverlay(nav, ui, settings, vm)
                is Screen.Search -> SearchScreen(ui, screen.purpose, vm, onMic)
                Screen.Settings -> SettingsScreen(settings, vm, fallback, ui.user?.displayName, onBackup = { vm.open(Screen.Backup) }, onMyFeedback = { vm.open(Screen.MyFeedback) }, onTheme = { vm.open(Screen.Theme) }, onAccount = { vm.open(Screen.Account) }, onAbout = { vm.open(Screen.About) }, onSafety = { vm.open(Screen.Safety) })
                Screen.Safety -> my.gimano.app.ui.safety.SafetySettingsScreen(settings, onBack = vm::back,
                    onReminder = { vm.setSafetyReminder(it) }, onPreview = vm::previewSafetyCard,
                    onReadAgain = { vm.openAgreement(AgreementMode.REVIEW) },
                    onDebugReset = if (my.gimano.app.BuildConfig.DEBUG) vm::debugResetSafety else null)
                Screen.About -> my.gimano.app.ui.about.AboutScreen(container, live = !fallback && !settings.demoMode, onBack = vm::back, onLicences = { vm.open(Screen.Licences) })
                Screen.Licences -> my.gimano.app.ui.about.LicencesScreen(onBack = vm::back)
                Screen.Account -> my.gimano.app.ui.account.AccountScreen(container, vm, ui.user, settings.displayName)
                Screen.Backup -> my.gimano.app.ui.backup.BackupScreen(bvm, onBack = vm::back)
                Screen.MyFeedback -> my.gimano.app.ui.feedback.MyFeedbackScreen(fvm, onBack = vm::back, onNew = { vm.requestFeedback("settings") })
                Screen.Contributions -> my.gimano.app.ui.contribute.ContributionsScreen(container, cvm, vm, ui.user)
                Screen.AddPlace -> my.gimano.app.ui.contribute.AddPlaceScreen(cvm, handle, onBack = vm::back)
                Screen.Favourites -> my.gimano.app.ui.more.FavouritesScreen(ui.saved, ui.myLocation?.point, settings.lastBackupAt, vm)
                Screen.Inbox -> my.gimano.app.ui.inbox.InboxScreen(ui.inbox, settings.inboxRead, onBack = vm::back, onRefresh = { vm.refreshInbox() }, onMarkAll = { vm.markInboxRead() },
                    // C2: the AI check's results open that place's result screen (appeal, edit, keep it just for me).
                    onOpenPlace = { item -> item.placeRef?.let { id -> cvm.openResult(id) } })
                Screen.Theme -> my.gimano.app.ui.more.ThemeScreen(settings.theme, onPick = { vm.setTheme(it) }, onBack = vm::back)
                Screen.Events -> my.gimano.app.ui.events.EventsListScreen(container.eventStore, container.hostStore, settings.use24h, onBack = vm::back,
                    onOpen = { id -> vm.open(Screen.EventDetail(id)) }, onOpenHosted = { id -> vm.openHostEvent(id) }, onNew = vm::newHostEvent)
                Screen.EventEdit -> my.gimano.app.ui.events.EventWizardScreen(container.hostEditor, ui.saved, settings.use24h, vm, container.personalRoutes)
                is Screen.RouteBuilder -> {
                    val draft by container.hostEditor.draft.collectAsStateWithLifecycle()
                    val days = remember(draft?.date, draft?.startTime, draft?.endTime) {
                        draft?.let { d -> runCatching {
                            val a = d.start().toLocalDate(); val b = d.end().toLocalDate()
                            generateSequence(a) { it.plusDays(1) }.takeWhile { !it.isAfter(b) }.take(15).map { it.toString() }.toList()
                        }.getOrNull() }.orEmpty()
                    }
                    my.gimano.app.ui.routes.RouteBuilderOverlay(container.routeBuilder, handle, builderTouch,
                        eventTitle = if (screen.forEvent) draft?.title else null, eventDays = if (screen.forEvent) days else emptyList(),
                        onBack = vm::routeBuilderBack, onClose = vm::closeRouteBuilder, onDeleteRoute = vm::deleteEventRoute,
                        onSaveToMine = if (screen.forEvent) { name, route -> container.personalRoutes.save(name, route) } else null)
                }
                Screen.MyRoutes -> my.gimano.app.ui.routes.MyRoutesScreen(container.personalRoutes, onBack = vm::back,
                    onOpen = { id -> vm.openPersonalRoute(id) }, onUseInEvent = vm::useRouteInEvent)
                Screen.EventShare -> my.gimano.app.ui.events.EventShareScreen(container.hostEditor, settings.use24h, onBack = vm::back)
                is Screen.EventDetail -> my.gimano.app.ui.events.EventDetailOverlay(
                    eventDetail, container.eventStore, settings.use24h, selected = eventStopSel,
                    onSelect = { id ->
                        eventStopSel = id
                        eventDetail?.plan?.stop(id)?.let { s -> vm.fitEvent(listOf(s.navigationTarget), 0) }
                    },
                    onBack = vm::back,
                    onDrive = { s -> vm.routeToEventStop(screen.id, s.id, s.label, s.navigationTarget) },
                    onDeleted = { vm.open(Screen.Events) },
                    onRefresh = { container.eventImporter.refresh(screen.id) },
                    panelFraction = eventPanelFraction,
                )
                Screen.Planned -> my.gimano.app.ui.planned.PlannedDrivesScreen(pvm, settings.use24h, onBack = vm::back,
                    onAdd = { vm.openSearch(SearchPurpose.PLAN_DRIVE) }, onGo = vm::goPlanned)
            }
            // Started while moving: "Pandu dengan selamat…" for 5 s under the turn banner, nothing to tap.
            if (ui.safetyBanner && screen == Screen.Navigating) {
                my.gimano.app.ui.safety.SafetyBanner(Modifier.align(Alignment.TopCenter).windowInsetsPadding(WindowInsets.statusBars).padding(top = 150.dp, start = 16.dp, end = 16.dp))
            }
            ui.safetyCard?.let { card ->
                my.gimano.app.ui.safety.SafetyReminderCard(card, onGo = vm::confirmSafetyCard, onDismiss = vm::dismissSafetyCard)
            }
            // Below the right-hand FAB column (3 × 64 dp + gaps) so it never covers controls.
            // While driving, below the End + Sound column (180–320 dp) so a sound toast never hides the new FAB state.
            SnackbarHost(snackbar, Modifier.align(Alignment.TopCenter).windowInsetsPadding(WindowInsets.statusBars)
                .padding(top = if (screen == Screen.Navigating) 336.dp else 250.dp, start = 16.dp, end = 16.dp)) { data ->
                val v = data.visuals
                if (v is SoundSnackVisuals) my.gimano.app.ui.common.SoundToastPill(v.mode, v.message) else Snackbar(data)
            }
        }
    }

    ui.favoriteSheet?.let { my.gimano.app.ui.sheets.FavoriteSheet(it, vm) }
    my.gimano.app.ui.events.EventImportDialogs(container.eventImporter, settings.use24h,
        navigatingTo = nav.destination?.takeIf { nav.active && it.eventStop },
        onRetarget = { eventId, st -> vm.retargetEventStop(eventId, st.id, st.label, st.navigationTarget) })
    // In-app update (sideloaded APK): sheet on Home when not snoozed, blocking gate below minSupported.
    val lang = container.lang().tag.take(2)
    when (val d = upd.decision) {
        is my.gimano.app.core.update.UpdateDecision.Available ->
            if ((!d.snoozed || forceUpdateSheet) && updateSheetOpen && ui.screen == Screen.Home && !nav.active && ui.safetyAgreement == null) my.gimano.app.ui.update.UpdateSheet(
                d.manifest, upd, lang, onUpdate = { scope.launch { container.updater.updateNow() } },
                onLater = { updateSheetOpen = false; forceUpdateSheet = false; container.updater.later() },
            )
        is my.gimano.app.core.update.UpdateDecision.Required ->
            if (ui.screen != Screen.Backup) my.gimano.app.ui.update.UpdateRequiredGate(
                d.manifest, upd, lang, onUpdate = { scope.launch { container.updater.updateNow() } }, onBackup = { vm.open(Screen.Backup) },
            )
        else -> Unit
    }
    my.gimano.app.ui.update.UpdateDialogs(container.updater, upd)
    LaunchedEffect(upd.justUpdatedTo) {
        upd.justUpdatedTo?.let { v -> snackbar.showSnackbar(context.getString(R.string.updated_to, v)); container.updater.dismissUpdatedNote() }
    }
    if (crashPending.isNotEmpty() && ui.screen == Screen.Home && !nav.active && ui.safetyAgreement == null) my.gimano.app.ui.feedback.CrashSheet(container.crashes, crashPending)
    ui.askPrecise?.let { my.gimano.app.ui.common.PreciseLocationDialog(onAllow = onRequestPrecise, onKeep = vm::onPreciseAnswered) }
    if (ui.precision == my.gimano.app.core.location.LocationPrecision.APPROXIMATE && (ui.screen == Screen.Home || ui.screen == Screen.Navigating)) {
        Box(Modifier.fillMaxSize().windowInsetsPadding(WindowInsets.statusBars).padding(horizontal = 12.dp).padding(top = if (ui.screen == Screen.Navigating) 250.dp else 96.dp)) {
            my.gimano.app.ui.common.ApproximateBanner(Modifier.align(Alignment.TopCenter))
        }
    }
    ui.namePin?.let { my.gimano.app.ui.pick.NamePinDialog(onName = vm::nameArrivedPin) }
    ui.vetPrompt?.let { if (ui.screen == Screen.Home) my.gimano.app.ui.contribute.NearbyVerifySheet(it, vm, cvm) }
    ui.tollSheet?.let { r ->
        my.gimano.app.ui.sheets.TollSheet(r, onDismiss = { vm.openTolls(null) }, onAvoidTolls = {
            vm.openTolls(null); ui.plan?.let { p -> vm.setAvoid(p.avoid.copy(tolls = true)) }
        })
    }
    // Community rules before the first public contribution (review, photo, place, report, complaint, vote).
    val termsPrompt by container.terms.prompt.collectAsStateWithLifecycle()
    if (termsPrompt) my.gimano.app.ui.contribute.CommunityRulesDialog(onAgree = container.terms::accept, onNotNow = container.terms::decline)
    if (feedbackDraft.open) my.gimano.app.ui.feedback.FeedbackSheet(fvm, feedbackDraft, here = { vm.here().let { it.lat to it.lng } }, onSend = {
        val h = vm.here(); fvm.send(h.lat, h.lng)
    })
    if (!settings.privacyCardDismissed && screen == Screen.Home && ui.safetyAgreement == null) {
        AlertDialog(
            onDismissRequest = vm::dismissPrivacyCard,
            text = { my.gimano.app.ui.common.PrivacyCard(onBackup = { vm.dismissPrivacyCard(); vm.open(Screen.Backup) }) },
            confirmButton = { TextButton(onClick = vm::dismissPrivacyCard) { Text(stringResource(R.string.got_it), fontWeight = FontWeight.ExtraBold) } },
            // Manotu's first run: offer (never automatic) to bring places over from a Gimano/Manotu backup file or Drive
            // (Drive only where BuildConfig.DRIVE_BACKUP; the Play build's Backup screen offers file restore only).
            // The Backup screen asks which backup and confirms before anything is replaced.
            dismissButton = if (my.gimano.app.BuildConfig.FLAVOR == "manotu") {
                { TextButton(onClick = { vm.dismissPrivacyCard(); vm.open(Screen.Backup) }) { Text(stringResource(R.string.restore_from_gimano), fontWeight = FontWeight.ExtraBold) } }
            } else null,
        )
    }
    ui.deviationAsk?.let { d -> my.gimano.app.ui.issues.DeviationSheet(d, vm::answerDeviation) }
    if (ui.reportOpen) {
        ReportSheet(onDismiss = { vm.openReport(false) }, onSubmit = vm::submitReport,
            onRoadProblem = if (ui.issuesAvailable && screen == Screen.Navigating) vm::submitRoadProblem else null)
    }
    // "Details" after a quick report: that type's subtypes; picking one replaces the quick report.
    ui.quickDetails?.let { t -> ReportSheet(onDismiss = vm::closeQuickDetails, onSubmit = vm::refineQuickReport, initialType = t) }
    ui.departureSlots?.let { slots -> DepartureDialog(slots, settings.use24h, vm) }
    // Safety (docs/safety.md): the map's restricted-area sheet, "agree first", and the agreement itself on top of all.
    if (ui.restrictedSheet) my.gimano.app.ui.safety.RestrictedAreaSheet(onClose = { vm.openRestrictedSheet(false) })
    if (ui.safetyNeedAgreement) my.gimano.app.ui.safety.NeedAgreementSheet(
        onRead = { vm.openAgreement(AgreementMode.BEFORE_DRIVE) }, onLater = vm::dismissNeedAgreement)
    ui.safetyAgreement?.let { mode ->
        androidx.compose.ui.window.Dialog(
            onDismissRequest = { if (mode == AgreementMode.REVIEW) vm.closeAgreement() },
            properties = androidx.compose.ui.window.DialogProperties(usePlatformDefaultWidth = false, dismissOnBackPress = mode == AgreementMode.REVIEW,
                dismissOnClickOutside = false, decorFitsSystemWindows = false),
        ) {
            my.gimano.app.ui.safety.SafetyAgreementScreen(mode, onAgree = vm::agreeSafety, onNotNow = vm::closeAgreement)
        }
    }
}

@Composable
private fun DepartureDialog(slots: List<my.gimano.app.data.model.DepartureSlot>, use24h: Boolean, vm: MainViewModel) {
    val c = Gimano.colors
    val lang = currentLang()
    val best = slots.minByOrNull { it.durationS }
    AlertDialog(
        onDismissRequest = vm::closeSlots,
        confirmButton = { TextButton(onClick = vm::closeSlots) { Text(stringResource(R.string.cancel)) } },
        title = { Text(stringResource(R.string.best_time_title)) },
        text = {
            LazyColumn(Modifier.heightIn(max = 420.dp)) {
                item {
                    Text(stringResource(R.string.leave_now), Modifier.fillMaxWidth().clickable { vm.chooseDeparture(null) }.padding(vertical = 12.dp), fontWeight = FontWeight.SemiBold, color = c.brand)
                }
                items(slots) { s ->
                    val t = Formatters.parseInstant(s.departAt) ?: return@items
                    Row(Modifier.fillMaxWidth().clickable { vm.chooseDeparture(s) }.padding(vertical = 12.dp), verticalAlignment = Alignment.CenterVertically) {
                        Text(Formatters.clock(ZonedDateTime.ofInstant(t, ZoneId.systemDefault()), use24h, lang), Modifier.weight(1f), fontSize = 17.sp, color = c.text)
                        Text(
                            Formatters.duration(s.durationS, lang), fontSize = 16.sp,
                            fontWeight = if (s == best) FontWeight.Bold else FontWeight.Normal,
                            color = if (s == best) c.brand else c.textMuted,
                        )
                    }
                }
            }
        },
    )
}

/** A sound-mode toast (docs/driving.md §6.2): drawn as the navy pill with the mode's icon, dismissed after 2 s. */
private class SoundSnackVisuals(override val message: String, val mode: my.gimano.app.data.settings.SoundMode) : SnackbarVisuals {
    override val actionLabel: String? get() = null
    override val withDismissAction: Boolean get() = false
    override val duration: SnackbarDuration get() = SnackbarDuration.Indefinite
}
