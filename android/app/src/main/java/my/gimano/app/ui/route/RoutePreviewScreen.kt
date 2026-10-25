package my.gimano.app.ui.route

import androidx.compose.animation.core.Animatable
import androidx.compose.animation.core.LinearEasing
import androidx.compose.animation.core.tween
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.gestures.detectDragGesturesAfterLongPress
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.layout.layout
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import my.gimano.app.R
import my.gimano.app.core.format.Formatters
import my.gimano.app.core.nav.RouteGeometry
import my.gimano.app.core.trip.GoAction
import my.gimano.app.core.trip.OriginSource
import my.gimano.app.core.trip.StartOption
import androidx.compose.foundation.verticalScroll
import my.gimano.app.core.trip.RouteLegs
import my.gimano.app.core.trip.TollBadge
import my.gimano.app.core.trip.TravelMode
import my.gimano.app.data.model.AvoidOptions
import my.gimano.app.data.model.Route
import my.gimano.app.data.settings.AppSettings
import my.gimano.app.ui.MainViewModel
import my.gimano.app.ui.RoutePlan
import my.gimano.app.ui.common.GIcon
import my.gimano.app.ui.common.Labels
import my.gimano.app.ui.common.Pill
import my.gimano.app.ui.common.SheetSurface
import my.gimano.app.ui.map.MapHandle
import my.gimano.app.ui.report.currentLang
import my.gimano.app.ui.sheets.tollBadgeText
import my.gimano.app.ui.theme.Gimano
import my.gimano.app.ui.theme.GimanoType
import my.gimano.app.ui.theme.Radius
import java.time.Instant
import java.time.ZoneId
import java.time.ZonedDateTime
import kotlin.math.roundToInt

private const val COUNTDOWN_MS = 10_000

@Composable
fun RoutePreviewOverlay(plan: RoutePlan, settings: AppSettings, vm: MainViewModel, handle: MapHandle, onRequestLocation: () -> Unit = {}) {
    val c = Gimano.colors
    val lang = currentLang()
    var startSheet by remember { mutableStateOf(false) }
    if (startSheet) StartSheet(vm) { startSheet = false }
    Box(Modifier.fillMaxSize()) {
        RouteBubbles(plan, handle, vm)

        Column(Modifier.align(Alignment.TopStart).fillMaxWidth()) {
            Surface(color = c.surface, shadowElevation = 6.dp, shape = RoundedCornerShape(bottomStart = Radius.lg, bottomEnd = Radius.lg)) {
                Column(Modifier.fillMaxWidth().windowInsetsPadding(WindowInsets.statusBars).padding(start = 4.dp, end = 4.dp, top = 4.dp, bottom = 10.dp)) {
                    Row(verticalAlignment = Alignment.Top) {
                        IconButton(onClick = vm::back) { Icon(Icons.AutoMirrored.Filled.ArrowBack, stringResource(R.string.back), tint = c.text) }
                        StopsPanel(plan, settings, vm, Modifier.weight(1f).padding(top = 10.dp)) { vm.cancelCountdown(); startSheet = true }
                        IconButton(onClick = { vm.cancelCountdown(); vm.swapStartDestination() }, enabled = plan.origin != null, modifier = Modifier.padding(top = 18.dp)) {
                            Icon(Icons.Filled.SwapVert, stringResource(R.string.swap_start_dest), tint = if (plan.origin != null) c.text else c.outline)
                        }
                        Overflow(vm, plan.hasEventStop)
                    }
                }
            }
            Row(Modifier.padding(horizontal = 16.dp, vertical = 10.dp), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                if (plan.mode.isMotorised) AvoidDropdown(plan.avoid) { vm.cancelCountdown(); vm.setAvoid(it) }
                plan.departAt?.let { t ->
                    val clock = Formatters.clock(ZonedDateTime.ofInstant(t, ZoneId.systemDefault()), settings.use24h, lang)
                    Pill(stringResource(R.string.leave_at, clock), icon = Icons.Filled.Schedule, onClick = { vm.chooseDeparture(null) })
                }
            }
        }

        SheetSurface(Modifier.align(Alignment.BottomCenter).fillMaxWidth()) {
            Column(Modifier.fillMaxWidth().padding(16.dp).windowInsetsPadding(WindowInsets.navigationBars)) {
                // With the route list showing, slimmer tabs leave room for the map (design RoPilihan).
                ModeTabs(plan.mode, compact = plan.listMode && !plan.loading) { vm.cancelCountdown(); vm.setMode(it) }
                Spacer(Modifier.height(if (plan.listMode && !plan.loading) 8.dp else 14.dp))
                val r = plan.selected
                when {
                    plan.originSource == OriginSource.LOCATING -> {
                        LinearProgressIndicator(Modifier.fillMaxWidth().height(3.dp), color = c.brand, trackColor = c.surfaceAlt)
                        Text(stringResource(R.string.origin_locating), Modifier.padding(vertical = 22.dp), color = c.textMuted, fontSize = 17.sp)
                    }
                    plan.originSource == OriginSource.UNKNOWN -> OriginChoices(
                        stringResource(R.string.origin_unknown), stringResource(R.string.origin_unknown_body), vm, onRequestLocation,
                    )
                    plan.alreadyHere -> OriginChoices(stringResource(R.string.already_here), stringResource(R.string.already_here_body), vm, null)
                    plan.loading -> {
                        LinearProgressIndicator(Modifier.fillMaxWidth().height(3.dp), color = c.brand, trackColor = c.surfaceAlt)
                        Text(stringResource(R.string.loading_routes), Modifier.padding(vertical = 22.dp), color = c.textMuted, fontSize = 17.sp)
                    }
                    plan.error || r == null -> {
                        Text(stringResource(R.string.route_error), Modifier.padding(vertical = 12.dp), color = c.text, fontSize = 17.sp)
                        OutlinedButton(onClick = { vm.setAvoid(plan.avoid) }) { Text(stringResource(R.string.retry)) }
                    }
                    else -> {
                        if (plan.originSource == OriginSource.CHOSEN) StartElsewhereNote(plan.originName ?: "")
                        my.gimano.app.ui.issues.RouteIssueBanner(r.issues, plan.ignoredIssues, vm::passAnyway)
                        if (plan.listMode) RouteChoiceList(plan, vm) else {
                            RouteInfo(r, plan, vm)
                            OtherRoutesRow(plan, vm)
                        }
                    }
                }
                Spacer(Modifier.height(16.dp))
                if (vm.goActionFor(plan) == GoAction.DRIVE_TO_START) {
                    // Design LaluanMulaLain: turn-by-turn can't begin away from the phone, so drive to the start first.
                    val start = plan.originName ?: ""
                    Button(onClick = vm::driveToStart, modifier = Modifier.fillMaxWidth().height(56.dp), shape = RoundedCornerShape(Radius.md),
                        colors = ButtonDefaults.buttonColors(containerColor = c.brand)) {
                        Text(stringResource(R.string.drive_to_start, start), fontWeight = FontWeight.ExtraBold, fontSize = 17.sp, maxLines = 1, overflow = TextOverflow.Ellipsis)
                    }
                    // Event stops: no "Save trip" (the stop label must not go into planned drives).
                    if (!plan.hasEventStop) Spacer(Modifier.height(8.dp))
                    if (!plan.hasEventStop) OutlinedButton(onClick = vm::planThisDrive, modifier = Modifier.fillMaxWidth().height(52.dp), shape = RoundedCornerShape(Radius.md)) {
                        GIcon("recent", null, size = 22.dp); Spacer(Modifier.width(8.dp))
                        Text(stringResource(R.string.save_trip), fontWeight = FontWeight.ExtraBold, fontSize = 16.sp)
                    }
                } else Row(horizontalArrangement = Arrangement.spacedBy(10.dp), verticalAlignment = Alignment.CenterVertically) {
                    BigIconButton("add_stop", stringResource(R.string.add_stop), enabled = plan.stops.size < RouteLegs.MAX_STOPS, onClick = vm::addStopInPreview)
                    if (!plan.hasEventStop) BigIconButton("recent", stringResource(R.string.plan_this_drive), enabled = !plan.loading && !plan.error, onClick = vm::planThisDrive)
                    GoNowButton(plan, Modifier.weight(1f), vm.goActionFor(plan), label = startLabel(plan), onGo = vm::startNavigation)
                }
            }
        }
    }
}

/** Amber note (design LaluanMulaLain) when the route doesn't start where the phone is. */
@Composable
private fun StartElsewhereNote(name: String) {
    Row(Modifier.fillMaxWidth().padding(bottom = 10.dp).clip(RoundedCornerShape(14.dp)).background(Color(0xFFFFF1CC)).padding(12.dp),
        verticalAlignment = Alignment.CenterVertically) {
        Icon(Icons.Filled.Info, null, tint = Color(0xFF7A5200), modifier = Modifier.size(22.dp))
        Spacer(Modifier.width(10.dp))
        Text(stringResource(R.string.start_elsewhere_note, name), color = Color(0xFF7A5200), fontSize = 14.sp, fontWeight = FontWeight.ExtraBold)
    }
}

/** "Mula dari" (design LaluanPilihMula): current location, Home, Work, favourites, recents, search, map. */
@Composable
private fun StartSheet(vm: MainViewModel, onClose: () -> Unit) {
    val c = Gimano.colors
    val options = remember { vm.startOptions() }
    ModalBottomSheet(onDismissRequest = onClose, sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true), containerColor = c.surface) {
        Column(Modifier.fillMaxWidth().verticalScroll(androidx.compose.foundation.rememberScrollState()).padding(start = 16.dp, end = 16.dp, bottom = 24.dp)) {
            Text(stringResource(R.string.start_from), fontSize = 20.sp, fontWeight = FontWeight.Black, color = c.text, modifier = Modifier.padding(bottom = 8.dp))
            options.forEach { o ->
                val (icon, title) = when (o.kind) {
                    StartOption.Kind.CURRENT -> Icons.Filled.MyLocation to stringResource(R.string.start_current)
                    StartOption.Kind.HOME -> Icons.Filled.Home to stringResource(R.string.home)
                    StartOption.Kind.WORK -> Icons.Filled.Work to stringResource(R.string.work)
                    StartOption.Kind.FAVORITE -> Icons.Filled.Star to o.name
                    StartOption.Kind.RECENT -> Icons.Filled.History to o.name
                }
                val sub = when (o.kind) { StartOption.Kind.HOME, StartOption.Kind.WORK -> o.address.ifBlank { o.name }; StartOption.Kind.CURRENT -> ""; else -> o.address }
                StartRow(icon, title, sub) { onClose(); vm.chooseStart(o) }
            }
            HorizontalDivider(Modifier.padding(vertical = 6.dp), color = c.outline.copy(alpha = 0.4f))
            StartRow(Icons.Filled.Search, stringResource(R.string.start_search), "") { onClose(); vm.chooseOriginBySearch() }
            StartRow(Icons.Filled.Place, stringResource(R.string.start_on_map), "") { onClose(); vm.chooseOriginOnMap() }
        }
    }
}

@Composable
private fun StartRow(icon: ImageVector, title: String, sub: String, onClick: () -> Unit) {
    val c = Gimano.colors
    Row(Modifier.fillMaxWidth().heightIn(min = 60.dp).clickable(onClick = onClick).padding(vertical = 6.dp), verticalAlignment = Alignment.CenterVertically) {
        Box(Modifier.size(44.dp).clip(RoundedCornerShape(14.dp)).background(c.brandMist), contentAlignment = Alignment.Center) {
            Icon(icon, null, tint = c.brandInk, modifier = Modifier.size(24.dp))
        }
        Spacer(Modifier.width(14.dp))
        Column(Modifier.weight(1f)) {
            Text(title, fontSize = 17.sp, fontWeight = FontWeight.ExtraBold, color = c.text, maxLines = 1, overflow = TextOverflow.Ellipsis)
            if (sub.isNotBlank()) Text(sub, fontSize = 13.sp, color = c.textMuted, maxLines = 1, overflow = TextOverflow.Ellipsis)
        }
    }
}

/** No usable start: say so (never "Your location"), and offer location, a point on the map or a searched start. */
@Composable
private fun OriginChoices(title: String, body: String, vm: MainViewModel, onRequestLocation: (() -> Unit)?) {
    val c = Gimano.colors
    Column(Modifier.fillMaxWidth().padding(bottom = 4.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
        Text(title, fontSize = 20.sp, fontWeight = FontWeight.Black, color = c.text)
        Text(body, fontSize = 15.sp, color = c.textMuted)
        if (onRequestLocation != null) Button(onClick = onRequestLocation, modifier = Modifier.fillMaxWidth().height(52.dp), shape = RoundedCornerShape(Radius.md),
            colors = ButtonDefaults.buttonColors(containerColor = c.brand)) {
            Icon(Icons.Filled.MyLocation, null); Spacer(Modifier.width(8.dp)); Text(stringResource(R.string.allow_location), fontWeight = FontWeight.ExtraBold, fontSize = 16.sp)
        }
        OutlinedButton(onClick = vm::chooseOriginOnMap, modifier = Modifier.fillMaxWidth().height(52.dp), shape = RoundedCornerShape(Radius.md)) {
            Icon(Icons.Filled.Place, null); Spacer(Modifier.width(8.dp)); Text(stringResource(R.string.choose_start_on_map), fontWeight = FontWeight.ExtraBold, fontSize = 16.sp)
        }
        OutlinedButton(onClick = vm::chooseOriginBySearch, modifier = Modifier.fillMaxWidth().height(52.dp), shape = RoundedCornerShape(Radius.md)) {
            Icon(Icons.Filled.Search, null); Spacer(Modifier.width(8.dp)); Text(stringResource(R.string.search_start), fontWeight = FontWeight.ExtraBold, fontSize = 16.sp)
        }
    }
}

@Composable
private fun BigIconButton(icon: String, label: String, enabled: Boolean, onClick: () -> Unit) {
    val c = Gimano.colors
    Box(
        Modifier.size(58.dp).clip(RoundedCornerShape(20.dp)).background(c.surfaceAlt).clickable(enabled = enabled, onClick = onClick).semantics { contentDescription = label },
        contentAlignment = Alignment.Center,
    ) { GIcon(icon, null, size = 30.dp, stroke = if (enabled) c.brandInk else c.outline, fill = if (enabled) c.brandTint else c.surfaceAlt) }
}

@Composable
private fun Overflow(vm: MainViewModel, eventStop: Boolean) {
    var open by remember { mutableStateOf(false) }
    Box {
        IconButton(onClick = { open = true }) { Icon(Icons.Filled.MoreVert, stringResource(R.string.more), tint = Gimano.colors.text) }
        DropdownMenu(open, onDismissRequest = { open = false }) {
            DropdownMenuItem(
                text = { Text(stringResource(R.string.leave_later), fontWeight = FontWeight.Bold) },
                leadingIcon = { Icon(Icons.Filled.Schedule, null) },
                onClick = { open = false; vm.openLeaveLater() },
            )
            if (!eventStop) DropdownMenuItem(
                text = { Text(stringResource(R.string.plan_this_drive), fontWeight = FontWeight.Bold) },
                leadingIcon = { GIcon("recent", null, size = 24.dp) },
                onClick = { open = false; vm.planThisDrive() },
            )
            DropdownMenuItem(
                text = { Text(stringResource(R.string.add_feedback), fontWeight = FontWeight.Bold) },
                leadingIcon = { GIcon("feedback", null, size = 24.dp) },
                onClick = { open = false; vm.requestFeedback("route_preview") },
            )
        }
    }
}

/** Your location → stops (drag to reorder, × to remove, ETA each) → destination, plus "Add a stop". */
@Composable
private fun StopsPanel(plan: RoutePlan, settings: AppSettings, vm: MainViewModel, modifier: Modifier, onStart: () -> Unit) {
    val c = Gimano.colors
    val lang = currentLang()
    val etas = plan.selected?.let { r -> if (r.legs.size == plan.stops.size + 1) RouteLegs.stopEtas(r, plan.departAt ?: Instant.now()) else null }
    fun eta(i: Int) = etas?.getOrNull(i)?.let { Formatters.clock(ZonedDateTime.ofInstant(it, ZoneId.systemDefault()), settings.use24h, lang) }
    val density = LocalDensity.current
    val rowPx = with(density) { 44.dp.toPx() }
    var dragging by remember { mutableIntStateOf(-1) }
    var dragDy by remember { mutableFloatStateOf(0f) }

    Column(modifier) {
        // The start row: "Your location" ONLY for a recent GPS fix; a chosen start shows its name; tap to change.
        val (label, colour) = when (plan.originSource) {
            OriginSource.GPS -> stringResource(R.string.your_location) to c.textMuted
            OriginSource.CHOSEN -> (plan.originName ?: stringResource(R.string.pin_on_map)) to c.text
            OriginSource.LOCATING -> stringResource(R.string.origin_locating) to c.textMuted
            OriginSource.UNKNOWN -> stringResource(R.string.origin_unknown) to c.speeding
        }
        val changeStart = stringResource(R.string.change_start)
        Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.height(30.dp).clickable(onClickLabel = changeStart, onClick = onStart)) {
            Box(Modifier.size(10.dp).clip(CircleShape).background(if (plan.originSource == OriginSource.UNKNOWN) c.speeding else c.brand))
            Spacer(Modifier.width(12.dp))
            Text(label, fontSize = 15.sp, color = colour, fontWeight = FontWeight.SemiBold, maxLines = 1, overflow = TextOverflow.Ellipsis)
        }
        plan.stops.forEachIndexed { i, s ->
            val offset = if (dragging == i) dragDy.roundToInt() else 0
            Row(
                verticalAlignment = Alignment.CenterVertically,
                modifier = Modifier.height(44.dp).offset { IntOffset(0, offset) }
                    .then(if (dragging == i) Modifier.shadow(6.dp, RoundedCornerShape(12.dp)).background(c.surface, RoundedCornerShape(12.dp)) else Modifier),
            ) {
                Box(Modifier.size(22.dp).clip(CircleShape).background(c.brandMist), contentAlignment = Alignment.Center) {
                    Text("${i + 1}", fontSize = 12.sp, fontWeight = FontWeight.Black, color = c.brandInk)
                }
                Spacer(Modifier.width(6.dp))
                Text(s.name, Modifier.weight(1f), fontSize = 16.sp, fontWeight = FontWeight.ExtraBold, color = c.text, maxLines = 1, overflow = TextOverflow.Ellipsis)
                eta(i)?.let { Text(it, fontSize = 13.sp, color = c.textMuted, fontWeight = FontWeight.Bold) }
                val dragLabel = stringResource(R.string.reorder_stop)
                Icon(
                    Icons.Filled.DragHandle, dragLabel, tint = c.textMuted,
                    modifier = Modifier.size(40.dp).padding(8.dp).pointerInput(plan.stops) {
                        detectDragGesturesAfterLongPress(
                            onDragStart = { dragging = i; dragDy = 0f },
                            onDrag = { change, d -> change.consume(); dragDy += d.y },
                            onDragEnd = {
                                val to = (i + (dragDy / rowPx).roundToInt()).coerceIn(0, plan.stops.lastIndex)
                                dragging = -1; dragDy = 0f
                                vm.moveStop(i, to)
                            },
                            onDragCancel = { dragging = -1; dragDy = 0f },
                        )
                    }.semantics { contentDescription = dragLabel },
                )
                IconButton(onClick = { vm.removeStop(i) }, Modifier.size(40.dp)) { Icon(Icons.Filled.Close, stringResource(R.string.remove_stop), tint = c.textMuted) }
            }
        }
        Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.heightIn(min = 34.dp)) {
            Icon(Icons.Filled.Place, null, tint = c.report, modifier = Modifier.size(14.dp))
            Spacer(Modifier.width(8.dp))
            Text(plan.destination.name, Modifier.weight(1f), fontSize = 17.sp, fontWeight = FontWeight.Black, color = c.text, maxLines = 1, overflow = TextOverflow.Ellipsis)
            if (plan.stops.isNotEmpty()) eta(plan.stops.size)?.let { Text(it, fontSize = 13.sp, color = c.textMuted, fontWeight = FontWeight.Bold) }
        }
        if (plan.stops.size < RouteLegs.MAX_STOPS) {
            Row(
                Modifier.clip(RoundedCornerShape(Radius.pill)).clickable(onClick = vm::addStopInPreview).padding(vertical = 6.dp, horizontal = 4.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                GIcon("add_stop", null, size = 26.dp)
                Spacer(Modifier.width(8.dp))
                Text(stringResource(R.string.add_stop), fontWeight = FontWeight.ExtraBold, color = c.brand, fontSize = 15.sp)
            }
        }
    }
}

@OptIn(androidx.compose.foundation.layout.ExperimentalLayoutApi::class)
@Composable
private fun RouteInfo(r: Route, plan: RoutePlan, vm: MainViewModel) {
    val c = Gimano.colors
    val lang = currentLang()
    Row(verticalAlignment = Alignment.Bottom) {
        Text(Formatters.duration(r.effectiveDurationS, lang), fontSize = 30.sp, fontWeight = FontWeight.Black, color = if (r.isBest) c.brand else c.text)
        if (r.isBest && plan.routes.size > 1) {
            Spacer(Modifier.width(8.dp))
            Text(
                stringResource(R.string.best), Modifier.padding(bottom = 6.dp).clip(RoundedCornerShape(Radius.sm)).background(c.brand).padding(horizontal = 8.dp, vertical = 2.dp),
                color = c.brandOn, fontSize = 13.sp, fontWeight = FontWeight.Bold,
            )
        }
        Spacer(Modifier.weight(1f))
        Text(Formatters.distance(r.distanceM), fontSize = 17.sp, color = c.textMuted, modifier = Modifier.padding(bottom = 4.dp))
    }
    if (r.summary.isNotBlank()) Text(r.summary, fontSize = 16.sp, color = c.text, maxLines = 1, overflow = TextOverflow.Ellipsis)
    Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.padding(top = 4.dp)) {
        val bits = buildList {
            if (plan.mode.isMotorised) Labels.traffic(r.trafficDescription)?.let { add(it) }
            if (r.alerts.isNotEmpty()) add(stringResource(R.string.reports_on_route, r.alerts.size))
        }
        Text(bits.joinToString(" · "), fontSize = 14.sp, color = c.textMuted, modifier = Modifier.weight(1f))
        Unit
    }
    // Toll chips (car & motorcycle): fare · plazas · Avoid tolls. Tap → plaza list with fares and sources.
    val badge = if (plan.mode.isMotorised) tollBadgeText(TollBadge.of(r)) else null
    if (badge != null) {
        androidx.compose.foundation.layout.FlowRow(horizontalArrangement = Arrangement.spacedBy(8.dp), verticalArrangement = Arrangement.spacedBy(6.dp), modifier = Modifier.padding(top = 8.dp)) {
            Row(
                Modifier.height(38.dp).clip(RoundedCornerShape(Radius.pill)).background(c.brandMist).clickable { vm.cancelCountdown(); vm.openTolls(r) }.padding(horizontal = 12.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                GIcon("fare", null, size = 22.dp); Spacer(Modifier.width(6.dp))
                Text(badge, fontWeight = FontWeight.Black, fontSize = 15.sp, color = c.brandInk)
            }
            if (r.tolls.isNotEmpty()) {
                val hw = r.tolls.mapNotNull { it.highway }.distinct().take(2).joinToString(", ")
                Text(stringResource(R.string.plaza_count, r.tolls.size) + if (hw.isNotEmpty()) " · $hw" else "",
                    Modifier.height(38.dp).clip(RoundedCornerShape(Radius.pill)).background(c.background).clickable { vm.cancelCountdown(); vm.openTolls(r) }.padding(horizontal = 12.dp, vertical = 9.dp),
                    fontSize = 14.sp, fontWeight = FontWeight.ExtraBold, color = c.textMuted)
            }
            Text(stringResource(R.string.avoid_tolls_action),
                Modifier.height(38.dp).clip(RoundedCornerShape(Radius.pill)).border(2.dp, c.outline, RoundedCornerShape(Radius.pill)).clickable { vm.cancelCountdown(); vm.setAvoid(plan.avoid.copy(tolls = true)) }.padding(horizontal = 12.dp, vertical = 8.dp),
                fontSize = 14.sp, fontWeight = FontWeight.Black, color = c.brandInk)
        }
    }
}

/** Primary button that fills left→right as a countdown and auto-starts navigation. */
@Composable
private fun GoNowButton(plan: RoutePlan, modifier: Modifier, goAction: GoAction = plan.goAction, label: String? = null, onGo: () -> Unit) {
    val c = Gimano.colors
    val progress = remember { Animatable(0f) }
    val enabled = goAction == GoAction.NAVIGATE
    LaunchedEffect(plan.countdownRunning, plan.selectedId, plan.loading) {
        if (plan.countdownRunning && enabled) {
            progress.snapTo(0f)
            progress.animateTo(1f, tween(COUNTDOWN_MS, easing = LinearEasing))
            onGo()
        } else {
            progress.snapTo(1f)
        }
    }
    val shape = RoundedCornerShape(Radius.md)
    Box(
        modifier.height(56.dp).clip(shape)
            .background(if (enabled) c.brand.copy(alpha = 0.55f) else c.surfaceAlt)
            .clickable(enabled = enabled, onClick = onGo),
        contentAlignment = Alignment.Center,
    ) {
        if (enabled) Box(Modifier.align(Alignment.CenterStart).fillMaxHeight().fillMaxWidth(progress.value).background(c.brand))
        Text(label ?: stringResource(R.string.go_now), color = if (enabled) c.brandOn else c.textMuted, fontSize = 17.sp, fontWeight = FontWeight.ExtraBold,
            maxLines = 1, overflow = TextOverflow.Ellipsis, modifier = Modifier.padding(horizontal = 8.dp))
    }
}

/** Four big travel-mode tabs: Car, Motorcycle, Bicycle, Walk. */
@Composable
private fun ModeTabs(mode: TravelMode, compact: Boolean = false, onSelect: (TravelMode) -> Unit) {
    val c = Gimano.colors
    val labels = mapOf(TravelMode.CAR to R.string.car, TravelMode.MOTORCYCLE to R.string.motorbike, TravelMode.BICYCLE to R.string.bicycle, TravelMode.WALK to R.string.walk)
    Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        TravelMode.entries.forEach { m ->
            val sel = m == mode
            val label = stringResource(labels.getValue(m))
            val tile = Modifier.weight(1f).height(if (compact) 48.dp else 72.dp).clip(RoundedCornerShape(Radius.tile))
                .background(if (sel) c.brandMist else c.surfaceAlt)
                .then(if (sel) Modifier.border(2.dp, c.brand, RoundedCornerShape(Radius.tile)) else Modifier)
                .clickable { onSelect(m) }
                .semantics { contentDescription = label }
            if (compact) Box(tile, contentAlignment = Alignment.Center) {
                GIcon(m.icon, null, size = 30.dp, stroke = if (sel) c.brandInk else c.textMuted, fill = if (sel) c.brandTint else c.outline)
            } else Column(tile, horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.Center) {
                GIcon(m.icon, null, size = 34.dp, stroke = if (sel) c.brandInk else c.textMuted, fill = if (sel) c.brandTint else c.outline)
                Text(label, fontSize = 12.sp, fontWeight = FontWeight.ExtraBold, color = if (sel) c.text else c.textMuted, maxLines = 1)
            }
        }
    }
}

@Composable
private fun AvoidDropdown(avoid: AvoidOptions, onChange: (AvoidOptions) -> Unit) {
    var open by remember { mutableStateOf(false) }
    val active = listOf(avoid.tolls, avoid.highways, avoid.ferries).count { it }
    Box {
        Pill(
            stringResource(R.string.avoid) + if (active > 0) " ($active)" else "",
            icon = Icons.Filled.Tune,
            color = if (active > 0) Gimano.colors.brand else Gimano.colors.surface,
            textColor = if (active > 0) Gimano.colors.brandOn else Gimano.colors.text,
            onClick = { open = true },
        )
        DropdownMenu(open, onDismissRequest = { open = false }) {
            AvoidItem(R.string.avoid_tolls, "toll", avoid.tolls) { onChange(avoid.copy(tolls = it)) }
            AvoidItem(R.string.avoid_highways, "lane", avoid.highways) { onChange(avoid.copy(highways = it)) }
            AvoidItem(R.string.avoid_ferries, "flood", avoid.ferries) { onChange(avoid.copy(ferries = it)) }
        }
    }
}

@Composable
private fun AvoidItem(label: Int, icon: String, checked: Boolean, onChange: (Boolean) -> Unit) {
    DropdownMenuItem(
        text = { Text(stringResource(label), fontWeight = FontWeight.Bold) },
        leadingIcon = { GIcon(icon, null, size = 24.dp) },
        trailingIcon = { Checkbox(checked, onCheckedChange = null) },
        onClick = { onChange(!checked) },
    )
}

@Composable
private fun RouteBubbles(plan: RoutePlan, handle: MapHandle, vm: MainViewModel) {
    val c = Gimano.colors
    val lang = currentLang()
    @Suppress("UNUSED_VARIABLE") val tick = handle.cameraVersion
    val geoms = remember(plan.decoded) { plan.decoded.mapValues { RouteGeometry(it.value) } }
    Box(Modifier.fillMaxSize()) {
        plan.visibleRoutes.forEachIndexed { i, r ->
            val g = geoms[r.id] ?: return@forEachIndexed
            if (g.points.size < 2) return@forEachIndexed
            val frac = when (i) { 0 -> 0.5; 1 -> 0.38; else -> 0.62 }
            val anchor = handle.project(g.pointAt(g.lengthM * frac).first) ?: return@forEachIndexed
            val selected = r.id == plan.selected?.id
            Box(
                Modifier.layout { m, cons ->
                    val p = m.measure(cons.copy(minWidth = 0, minHeight = 0))
                    layout(p.width, p.height) { p.place(anchor.x.roundToInt() - p.width / 2, anchor.y.roundToInt() - p.height - 6) }
                },
            ) {
                Column(
                    Modifier.shadow(4.dp, RoundedCornerShape(Radius.md)).clip(RoundedCornerShape(Radius.md))
                        .background(if (selected) c.routeActive else c.surface)
                        .clickable { vm.selectRoute(r.id) }
                        .padding(horizontal = 10.dp, vertical = 5.dp),
                    horizontalAlignment = Alignment.CenterHorizontally,
                ) {
                    if (r.isBest && plan.routes.size > 1) Text(stringResource(R.string.best), fontSize = 11.sp, fontWeight = FontWeight.Bold, color = if (selected) Color.White else c.brand, lineHeight = 12.sp)
                    Text(Formatters.duration(r.effectiveDurationS, lang), fontSize = 15.sp, fontWeight = FontWeight.Black, color = if (selected) Color.White else c.text, lineHeight = 17.sp)
                }
            }
        }
    }
}

