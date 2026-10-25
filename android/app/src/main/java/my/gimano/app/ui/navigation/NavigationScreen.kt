package my.gimano.app.ui.navigation

import androidx.compose.animation.AnimatedVisibility
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.VolumeOff
import androidx.compose.material.icons.automirrored.filled.VolumeUp
import androidx.compose.material.icons.filled.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalView
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import kotlinx.coroutines.delay
import my.gimano.app.R
import my.gimano.app.core.format.Formatters
import my.gimano.app.core.nav.ManeuverFormatter
import my.gimano.app.core.nav.NavigationTracker
import my.gimano.app.data.model.Maneuver
import my.gimano.app.data.settings.AppSettings
import my.gimano.app.data.settings.SoundMode
import my.gimano.app.nav.NavState
import my.gimano.app.ui.MainViewModel
import my.gimano.app.ui.UiState
import my.gimano.app.ui.common.*
import my.gimano.app.ui.report.AlertCard
import my.gimano.app.ui.report.currentLang
import my.gimano.app.ui.theme.Gimano
import my.gimano.app.ui.theme.GimanoType
import my.gimano.app.ui.theme.Radius
import my.gimano.app.ui.theme.Sizes
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import java.time.Instant
import java.time.ZoneId

@Composable
fun NavigationOverlay(nav: NavState, ui: UiState, settings: AppSettings, vm: MainViewModel) {
    val c = Gimano.colors
    val lang = currentLang()
    val p = nav.progress
    // Tick so the ETA clock stays fresh even when stationary.
    var now by remember { mutableStateOf(Instant.now()) }
    LaunchedEffect(Unit) { while (true) { delay(10_000); now = Instant.now() } }
    // The screen stays on for the whole drive (as on iOS); it may sleep again once navigation ends.
    val view = LocalView.current
    DisposableEffect(view) {
        view.keepScreenOn = true
        onDispose { view.keepScreenOn = false }
    }

    Box(Modifier.fillMaxSize()) {
        // ---- Top: turn banner + "then" strip --------------------------------------------
        Column(Modifier.align(Alignment.TopStart).fillMaxWidth().windowInsetsPadding(WindowInsets.statusBars).padding(horizontal = 10.dp, vertical = 6.dp)) {
            TurnBanner(nav)
            val next = p?.nextManeuver
            val then = p?.thenManeuver
            if (!nav.rerouting && NavigationTracker.showThen(next, then) && then != null) {
                Row(
                    Modifier.padding(start = 12.dp).clip(RoundedCornerShape(bottomStart = Radius.md, bottomEnd = Radius.md))
                        .background(Color(0xFF1F2A36)).padding(horizontal = 14.dp, vertical = 6.dp),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Text(stringResource(R.string.then), color = c.navBannerOn.copy(alpha = 0.8f), fontSize = 16.sp)
                    Spacer(Modifier.width(8.dp))
                    Icon(GIcons.maneuver(ManeuverFormatter.icon(then.type)), null, tint = c.navBannerOn, modifier = Modifier.size(24.dp))
                }
            }
        }

        // ---- "Sharing" chip: tap to stop sharing --------------------------------------------
        val sharing by vm.sharing.collectAsState()
        var confirmUnshare by remember { mutableStateOf(false) }
        if (sharing != null) {
            Box(Modifier.align(Alignment.TopStart).windowInsetsPadding(WindowInsets.statusBars).padding(top = 196.dp, start = 14.dp)) {
                Pill(stringResource(R.string.sharing_stop), color = c.report, textColor = c.reportOn, icon = Icons.Filled.Share, onClick = { confirmUnshare = true })
            }
        }
        if (confirmUnshare) AlertDialog(
            onDismissRequest = { confirmUnshare = false },
            title = { Text(stringResource(R.string.stop_sharing_title), style = GimanoType.title) },
            text = { Text(stringResource(R.string.stop_sharing_body)) },
            confirmButton = { Button(onClick = { confirmUnshare = false; vm.stopSharing() }) { Text(stringResource(R.string.stop_sharing), fontWeight = FontWeight.ExtraBold) } },
            dismissButton = { TextButton(onClick = { confirmUnshare = false }) { Text(stringResource(R.string.keep_sharing)) } },
        )

        // ---- Right column: sound + recenter ----------------------------------------------
        Column(
            Modifier.align(Alignment.TopEnd).windowInsetsPadding(WindowInsets.statusBars).padding(top = 180.dp, end = 14.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            // Big, always-visible End button (no need to open the trip sheet).
            val endLabel = stringResource(R.string.end_nav)
            FloatingSurface(
                Modifier.size(Sizes.roundFab).semantics { contentDescription = endLabel },
                CircleShape, color = c.report, onClick = { vm.askStop(true) },
            ) { GIcon("close", null, size = Sizes.roundFabIcon, stroke = c.reportOn, fill = c.reportOn) }
            SoundFab(settings.soundMode, settings.voiceVolume, onSelect = vm::selectSound, onLongPress = vm::toggleMute, onVolume = vm::setVoiceVolume)
            if (!ui.following) RoundFab(Icons.Filled.Navigation, stringResource(R.string.recenter), onClick = vm::recenter)
        }

        // ---- Bottom: alert card, speedometer, report, ETA bar ------------------------------
        Column(Modifier.align(Alignment.BottomCenter).fillMaxWidth()) {
            val alert = nav.upcomingAlert
            val toll = nav.toll
            // Tinjau (docs/driving.md §2): while the camera shows the jam / closure ahead.
            val tinjau = nav.camera?.tinjau
            AnimatedVisibility(tinjau != null && !nav.arrived) {
                if (tinjau != null) TinjauBanner(tinjau, Modifier.padding(horizontal = 12.dp, vertical = 6.dp))
            }
            AnimatedVisibility(toll != null && !nav.arrived) {
                if (toll != null) TollBannerCard(toll, Modifier.padding(horizontal = 12.dp, vertical = 6.dp))
            }
            val still = ui.stillClosed
            if (still != null && !nav.arrived && alert == null) my.gimano.app.ui.issues.StillClosedCard(still, vm::answerStillClosed,
                Modifier.padding(horizontal = 12.dp, vertical = 8.dp))
            AnimatedVisibility(alert != null && !nav.arrived) {
                if (alert != null) {
                    AlertCard(
                        alert.toReport(), null,
                        onVote = { v -> vm.vote(alert.toReport(), v) },
                        onClose = { vm.dismissNavAlert(alert.id) },
                        distanceAheadM = nav.alertDistanceM?.coerceAtLeast(0.0),
                        modifier = Modifier.padding(horizontal = 12.dp, vertical = 8.dp),
                    )
                }
            }
            // Hidden while the trip sheet is expanded so it can't ride up over the sound/End buttons.
            if (!ui.navExpanded) Row(Modifier.fillMaxWidth().padding(horizontal = 14.dp, vertical = 10.dp), verticalAlignment = Alignment.Bottom) {
                Column {
                    nav.weakGpsM?.let { my.gimano.app.ui.common.WeakGpsChip(it); Spacer(Modifier.height(8.dp)) }
                    if (nav.simulated) {
                        Pill(stringResource(R.string.simulated), icon = Icons.Filled.Science)
                        Spacer(Modifier.height(8.dp))
                    }
                    Speedometer(nav.speedKmh, null)
                    Spacer(Modifier.height(6.dp))
                    Attribution()
                }
                Spacer(Modifier.weight(1f))
                ReportFab { vm.openReport(true) }
            }
            when {
                nav.arrived -> ArrivedCard(nav, vm)
                nav.arrivedAtStop != null -> StopArrivedCard(nav.arrivedAtStop.name, vm)
                else -> EtaBar(nav, ui, settings, vm, now)
            }
        }
    }
    if (ui.confirmStop) StopDialog(vm)
    if (ui.passengerPrompt) PassengerDialog(vm)
}

/** "Arrived at {stop}" → Continue to the next leg. */
@Composable
private fun StopArrivedCard(name: String, vm: MainViewModel) {
    val c = Gimano.colors
    SheetSurface(Modifier.fillMaxWidth()) {
        Column(Modifier.fillMaxWidth().windowInsetsPadding(WindowInsets.navigationBars).padding(20.dp), horizontalAlignment = Alignment.CenterHorizontally) {
            GIcon("add_stop", null, size = 48.dp)
            Text(stringResource(R.string.arrived_at_stop, name), style = GimanoType.title, color = c.text, modifier = Modifier.padding(top = 8.dp))
            Spacer(Modifier.height(16.dp))
            Button(
                onClick = vm::continueAfterStop, Modifier.fillMaxWidth().height(56.dp), shape = RoundedCornerShape(Radius.md),
                colors = ButtonDefaults.buttonColors(containerColor = c.brand, contentColor = c.brandOn),
            ) { Text(stringResource(R.string.continue_drive), style = GimanoType.button) }
        }
    }
}

@Composable
private fun PassengerDialog(vm: MainViewModel) {
    val c = Gimano.colors
    AlertDialog(
        onDismissRequest = { vm.confirmPassenger(false) },
        title = { Text(stringResource(R.string.passenger_title), style = GimanoType.title) },
        text = { Text(stringResource(R.string.passenger_body)) },
        confirmButton = {
            Button(onClick = { vm.confirmPassenger(true) }, Modifier.height(56.dp), colors = ButtonDefaults.buttonColors(containerColor = c.brand, contentColor = c.brandOn)) {
                Text(stringResource(R.string.passenger_yes), fontWeight = FontWeight.ExtraBold)
            }
        },
        dismissButton = {
            OutlinedButton(onClick = { vm.confirmPassenger(false) }, Modifier.height(56.dp)) { Text(stringResource(R.string.passenger_no), fontWeight = FontWeight.ExtraBold) }
        },
    )
}

@Composable
private fun StopDialog(vm: MainViewModel) {
    val c = Gimano.colors
    AlertDialog(
        onDismissRequest = { vm.askStop(false) },
        title = { Text(stringResource(R.string.stop_nav_title), style = GimanoType.title) },
        confirmButton = {
            Button(
                onClick = vm::stopNavigation, Modifier.height(56.dp), shape = RoundedCornerShape(Radius.md),
                colors = ButtonDefaults.buttonColors(containerColor = c.report, contentColor = c.reportOn),
            ) { Text(stringResource(R.string.stop), fontSize = 18.sp, fontWeight = FontWeight.ExtraBold) }
        },
        dismissButton = {
            Button(
                onClick = { vm.askStop(false) }, Modifier.height(56.dp), shape = RoundedCornerShape(Radius.md),
                colors = ButtonDefaults.buttonColors(containerColor = c.brand, contentColor = c.brandOn),
            ) { Text(stringResource(R.string.keep_driving), fontSize = 18.sp, fontWeight = FontWeight.ExtraBold) }
        },
    )
}

@Composable
private fun TurnBanner(nav: NavState) {
    val c = Gimano.colors
    val lang = currentLang()
    val p = nav.progress
    val m: Maneuver? = p?.nextManeuver
    Row(
        Modifier.fillMaxWidth().clip(RoundedCornerShape(Radius.lg)).background(c.navBanner).padding(horizontal = 16.dp, vertical = 14.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        if (nav.rerouting || m == null) {
            CircularProgressIndicator(Modifier.size(40.dp), color = c.brand, strokeWidth = 4.dp)
            Spacer(Modifier.width(16.dp))
            // No progress yet and not rerouting = no usable GPS fix (e.g. "Approximate" location): say so.
            Text(stringResource(if (nav.rerouting) R.string.rerouting else R.string.waiting_for_gps), color = c.navBannerOn, style = GimanoType.title)
            return@Row
        }
        Icon(GIcons.maneuver(ManeuverFormatter.icon(m.type)), null, tint = c.navBannerOn, modifier = Modifier.size(60.dp))
        Spacer(Modifier.width(14.dp))
        Column(Modifier.weight(1f)) {
            Text(Formatters.navDistance(p.distanceToNextM), color = c.navBannerOn, style = GimanoType.navDistance, lineHeight = 42.sp)
            val road = ManeuverFormatter.road(m)
            Text(
                road ?: ManeuverFormatter.instruction(m, lang, nav.mode.wire),
                color = c.navBannerOn.copy(alpha = 0.92f), fontSize = 20.sp, fontWeight = FontWeight.SemiBold,
                maxLines = 1, overflow = TextOverflow.Ellipsis,
            )
            if (road != null) Text(ManeuverFormatter.instruction(m, lang, nav.mode.wire), color = c.navBannerOn.copy(alpha = 0.65f), fontSize = 14.sp, maxLines = 1, overflow = TextOverflow.Ellipsis)
        }
    }
}

@Composable
private fun EtaBar(nav: NavState, ui: UiState, settings: AppSettings, vm: MainViewModel, now: Instant) {
    val c = Gimano.colors
    val lang = currentLang()
    val p = nav.progress
    SheetSurface(Modifier.fillMaxWidth()) {
        Column(Modifier.fillMaxWidth().windowInsetsPadding(WindowInsets.navigationBars).padding(bottom = 8.dp)) {
            Box(Modifier.fillMaxWidth().padding(top = 8.dp), contentAlignment = Alignment.Center) { GrabHandle() }
            Row(Modifier.fillMaxWidth().padding(horizontal = 8.dp, vertical = 6.dp), verticalAlignment = Alignment.CenterVertically) {
                IconButton(onClick = vm::addStop, Modifier.size(56.dp)) { GIcon("search", stringResource(R.string.add_stop), size = 30.dp) }
                Column(Modifier.weight(1f).clickable { vm.setNavExpanded(!ui.navExpanded) }, horizontalAlignment = Alignment.CenterHorizontally) {
                    val eta = p?.let { Formatters.etaClock(now, it.remainingS, ZoneId.systemDefault(), settings.use24h, lang) } ?: "--:--"
                    Text(eta, style = GimanoType.etaClock, color = c.text, lineHeight = 36.sp)
                    Text(p?.let { Formatters.remainingLine(it.remainingS, it.remainingM, lang) } ?: "", fontSize = 15.sp, color = c.textMuted)
                    // "Tol setakat ini RM x · anggaran RM y" (docs/driving.md §1), only on routes with tolls.
                    nav.route?.let { r -> my.gimano.app.core.nav.TollText.tripLine(nav.tollsPaidMyr, r, nav.tollsCarriedMyr, lang) }?.let {
                        Text(it, fontSize = 13.sp, color = c.textMuted, maxLines = 1, overflow = TextOverflow.Ellipsis)
                    }
                }
                IconButton(onClick = vm::overview, Modifier.size(52.dp)) { Icon(Icons.Filled.AltRoute, stringResource(R.string.overview), tint = c.text, modifier = Modifier.size(28.dp)) }
            }
            AnimatedVisibility(ui.navExpanded) {
                Column(Modifier.padding(horizontal = 16.dp)) {
                    Divider()
                    nav.stops.firstOrNull()?.let { st ->
                        val legs = nav.route?.let { my.gimano.app.core.trip.RouteLegs.stopEtas(it, nav.startedAt ?: now) }
                        val eta = legs?.getOrNull(0)?.let { Formatters.clock(java.time.ZonedDateTime.ofInstant(it, ZoneId.systemDefault()), settings.use24h, currentLang()) } ?: ""
                        Text(stringResource(R.string.next_stop, st.name, eta), Modifier.padding(top = 12.dp), fontSize = 15.sp, fontWeight = FontWeight.Bold, color = c.brand)
                    }
                    nav.destination?.let { d ->
                        Text(d.name, Modifier.padding(top = 8.dp), fontSize = 18.sp, fontWeight = FontWeight.SemiBold, color = c.text, maxLines = 1, overflow = TextOverflow.Ellipsis)
                        nav.route?.summary?.takeIf { it.isNotBlank() }?.let { Text(it, fontSize = 14.sp, color = c.textMuted, maxLines = 1, overflow = TextOverflow.Ellipsis) }
                    }
                    Spacer(Modifier.height(8.dp))
                    ExpandedRow(Icons.Filled.AddLocationAlt, stringResource(R.string.add_stop), vm::addStop)
                    ExpandedRow(Icons.Filled.Schedule, stringResource(R.string.best_time), vm::openBestTimeFromNav)
                    // Share my drive carries the destination name: not for event stops.
                    if (nav.destination?.eventStop != true && nav.stops.none { it.eventStop }) ExpandedRow(Icons.Filled.Share, stringResource(R.string.share_drive), vm::shareDrive)
                    ExpandedRow(Icons.Filled.Feedback, stringResource(R.string.add_feedback)) { vm.requestFeedback("navigation") }
                    Spacer(Modifier.height(10.dp))
                    Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                        Button(
                            onClick = vm::stopNavigation, Modifier.weight(1f).height(54.dp), shape = RoundedCornerShape(Radius.md),
                            colors = ButtonDefaults.buttonColors(containerColor = c.report, contentColor = c.reportOn),
                        ) { Text(stringResource(R.string.stop), fontSize = 17.sp, fontWeight = FontWeight.SemiBold) }
                        Button(
                            onClick = { vm.setNavExpanded(false) }, Modifier.weight(1f).height(54.dp), shape = RoundedCornerShape(Radius.md),
                            colors = ButtonDefaults.buttonColors(containerColor = c.brand, contentColor = c.brandOn),
                        ) { Text(stringResource(R.string.continue_drive), fontSize = 17.sp, fontWeight = FontWeight.SemiBold) }
                    }
                    Spacer(Modifier.height(8.dp))
                }
            }
        }
    }
}

@Composable
private fun ExpandedRow(icon: ImageVector, label: String, onClick: () -> Unit) {
    val c = Gimano.colors
    Row(Modifier.fillMaxWidth().clip(RoundedCornerShape(Radius.md)).clickable(onClick = onClick).padding(vertical = 12.dp), verticalAlignment = Alignment.CenterVertically) {
        Box(Modifier.size(40.dp).clip(CircleShape).background(c.surfaceAlt), contentAlignment = Alignment.Center) { Icon(icon, null, tint = c.brand) }
        Spacer(Modifier.width(14.dp))
        Text(label, fontSize = 17.sp, color = c.text)
    }
}

@Composable
private fun ArrivedCard(nav: NavState, vm: MainViewModel) {
    val c = Gimano.colors
    // Tracking already stopped on arrival; close the card by itself if the driver doesn't.
    LaunchedEffect(Unit) { delay(20_000); vm.stopNavigation() }
    val lang = currentLang()
    // docs/driving.md §4: which side the entrance is on, and how far from the road.
    val side = remember(nav.route?.id, lang) {
        val r = nav.route
        val g = r?.let { runCatching { my.gimano.app.core.nav.RouteGeometry(my.gimano.app.core.geo.Polyline.decode(it.polyline)) }.getOrNull() }
        val end = g?.points?.lastOrNull()
        val travel = g?.takeIf { it.lengthM > 1 }?.let { my.gimano.app.core.geo.GeoMath.bearingDeg(it.pointAt(it.lengthM - 20).first, it.pointAt(it.lengthM).first) }
        my.gimano.app.core.nav.ArrivalText.line(r?.arrival, end, travel, nav.destination?.point, lang)
    }
    val dest = nav.destination
    val canReport = dest?.placeId != null && !dest.eventStop && !dest.placeId.startsWith("pin:") && !dest.placeId.startsWith("private:")
    SheetSurface(Modifier.fillMaxWidth()) {
        Column(Modifier.fillMaxWidth().windowInsetsPadding(WindowInsets.navigationBars).padding(20.dp), horizontalAlignment = Alignment.CenterHorizontally) {
            Icon(Icons.Filled.SportsScore, null, tint = c.brand, modifier = Modifier.size(48.dp))
            Text(stringResource(R.string.arrived), style = GimanoType.title, color = c.text, modifier = Modifier.padding(top = 8.dp))
            dest?.let { Text(it.name, fontSize = 16.sp, color = c.textMuted, modifier = Modifier.padding(top = 4.dp)) }
            side?.let {
                Row(Modifier.padding(top = 10.dp), verticalAlignment = Alignment.CenterVertically) {
                    Icon(Icons.Filled.MeetingRoom, null, tint = c.brand, modifier = Modifier.size(24.dp))
                    Spacer(Modifier.width(8.dp))
                    Text(it, fontSize = 16.sp, fontWeight = FontWeight.SemiBold, color = c.text)
                }
            }
            Spacer(Modifier.height(16.dp))
            Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                if (canReport) OutlinedButton(
                    onClick = vm::wrongEntrance, Modifier.weight(1f).height(54.dp), shape = RoundedCornerShape(Radius.md),
                ) { Text(stringResource(R.string.wrong_entrance), fontSize = 16.sp, fontWeight = FontWeight.SemiBold, color = c.text, maxLines = 1) }
                Button(
                    onClick = vm::stopNavigation, Modifier.weight(1f).height(54.dp), shape = RoundedCornerShape(Radius.md),
                    colors = ButtonDefaults.buttonColors(containerColor = c.brand, contentColor = c.brandOn),
                ) { Text(stringResource(R.string.done), fontSize = 17.sp, fontWeight = FontWeight.SemiBold) }
            }
        }
    }
}

/** "Tol Sungai Besi · 900 m di hadapan · RM 2.10" (docs/driving.md §1). */
@Composable
fun TollBannerCard(b: my.gimano.app.core.nav.TollBanner, modifier: Modifier = Modifier) {
    val c = Gimano.colors
    val lang = currentLang()
    val fare = b.kind == my.gimano.app.core.nav.TollKind.FARE
    FloatingSurface(modifier.fillMaxWidth(), RoundedCornerShape(Radius.lg)) {
        Row(Modifier.padding(horizontal = 16.dp, vertical = 12.dp), verticalAlignment = Alignment.CenterVertically) {
            Box(Modifier.size(44.dp).clip(RoundedCornerShape(14.dp)).background(c.brandMist), contentAlignment = Alignment.Center) {
                GIcon("toll", null, size = 28.dp)
            }
            Spacer(Modifier.width(12.dp))
            Column(Modifier.weight(1f)) {
                Text(my.gimano.app.core.nav.TollText.title(b.toll.plaza, lang), fontSize = 18.sp, fontWeight = FontWeight.Bold, color = c.text,
                    maxLines = 1, overflow = TextOverflow.Ellipsis)
                val detail = if (fare) {
                    if (b.passed) null else Formatters.navDistance(b.distanceM) + if (lang == my.gimano.app.core.format.Lang.MS) " di hadapan" else " ahead"
                } else my.gimano.app.core.nav.TollText.detail(b, lang)
                detail?.let { Text(it, fontSize = 15.sp, color = c.textMuted, maxLines = 2) }
            }
            if (fare) {
                Spacer(Modifier.width(10.dp))
                Text(my.gimano.app.core.trip.TollBadge.rm(b.fareMyr ?: 0.0), fontSize = 20.sp, fontWeight = FontWeight.ExtraBold, color = c.brand)
            }
        }
    }
}

/** "Sesak 4.8 km di hadapan · 1.2 km panjang · +6 min" while the Tinjau camera is out. */
@Composable
fun TinjauBanner(t: my.gimano.app.core.nav.TinjauInfo, modifier: Modifier = Modifier) {
    val c = Gimano.colors
    val lang = currentLang()
    val type = when (t.problem.kind) { "jam" -> "traffic"; else -> t.problem.kind }
    FloatingSurface(modifier.fillMaxWidth(), RoundedCornerShape(Radius.lg)) {
        Row(Modifier.padding(horizontal = 16.dp, vertical = 12.dp), verticalAlignment = Alignment.CenterVertically) {
            ReportTile(type, 44.dp)
            Spacer(Modifier.width(12.dp))
            Text(my.gimano.app.core.nav.TinjauText.line(t, lang), fontSize = 17.sp, fontWeight = FontWeight.SemiBold, color = c.text, maxLines = 2)
        }
    }
}
