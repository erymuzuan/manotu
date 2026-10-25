package my.gimano.app.ui.report

import android.os.SystemClock
import android.view.HapticFeedbackConstants
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.gestures.awaitEachGesture
import androidx.compose.foundation.gestures.awaitFirstDown
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Close
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.layout.onGloballyPositioned
import androidx.compose.ui.layout.positionInRoot
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.LocalView
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.liveRegion
import androidx.compose.ui.semantics.onClick
import androidx.compose.ui.semantics.role
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import my.gimano.app.R
import my.gimano.app.core.drive.Countdown
import my.gimano.app.core.report.HoldToReport
import my.gimano.app.core.report.QuickFan
import my.gimano.app.ui.QuickReportCard
import my.gimano.app.ui.common.GIcon
import my.gimano.app.ui.common.GIcons
import my.gimano.app.ui.common.Labels
import my.gimano.app.ui.theme.Gimano
import my.gimano.app.ui.theme.Radius
import my.gimano.app.ui.theme.Sizes
import kotlin.math.roundToInt

private val Navy = Color(0xFF0B1F4A)

/** Shared between the report button (gesture) and the fan overlay drawn over the whole driving screen. */
@Stable
class QuickFanState {
    var open by mutableStateOf(false)
    var selected by mutableStateOf<QuickFan.Slot?>(null)
    /** The report button's centre, in root pixels. */
    var center by mutableStateOf(Offset.Zero)
    var scale by mutableFloatStateOf(1f)
}

/**
 * The driving report button (docs/driving.md §6.4): tap = the full sheet as before; hold ~300 ms = the fan of 8
 * quick actions; slide onto one (haptic tick) and release to send it at once; release elsewhere = cancel.
 * TalkBack / Switch Access users get the full sheet on a plain activation (no gesture needed).
 */
@Composable
fun HoldReportFab(fan: QuickFanState, onTap: () -> Unit, onSend: (String) -> Unit, modifier: Modifier = Modifier) {
    val c = Gimano.colors
    val view = LocalView.current
    val density = LocalDensity.current
    val label = stringResource(R.string.report_fab_desc)
    val tap by rememberUpdatedState(onTap)
    val send by rememberUpdatedState(onSend)
    val statusTopPx = WindowInsets.statusBars.getTop(density)
    Box(
        modifier.size(Sizes.reportFab)
            .onGloballyPositioned { lc ->
                val p = lc.positionInRoot()
                fan.center = Offset(p.x + lc.size.width / 2f, p.y + lc.size.height / 2f)
                val roomLeftDp = fan.center.x / density.density
                // Keep the fan below the turn banner area (status bar + ~110 dp).
                val roomUpDp = (fan.center.y - statusTopPx) / density.density - 110f
                fan.scale = QuickFan.scaleToFit(roomLeftDp, roomUpDp)
            }
            // While the fan is open the overlay draws a navy close button here; the coral one would show round it.
            .alpha(if (fan.open) 0f else 1f)
            .shadow(12.dp, RoundedCornerShape(Radius.reportFab), ambientColor = Color(0x73FF6B4A), spotColor = Color(0x73FF6B4A))
            .clip(RoundedCornerShape(Radius.reportFab))
            .background(c.report)
            .semantics {
                role = Role.Button
                contentDescription = label
                onClick { tap(); true }
            }
            .pointerInput(Unit) {
                awaitEachGesture {
                    val down = awaitFirstDown()
                    down.consume()
                    val g = HoldToReport().also { it.scale = fan.scale }
                    val cx = size.width / 2f
                    val cy = size.height / 2f
                    var pos = down.position
                    fun dx() = (pos.x - cx) / density.density
                    fun dy() = (pos.y - cy) / density.density
                    fun handle(e: HoldToReport.Effect) {
                        when (e) {
                            HoldToReport.Effect.None -> Unit
                            HoldToReport.Effect.OpenSheet -> tap()
                            HoldToReport.Effect.FanOpened -> {
                                fan.selected = null; fan.open = true
                                view.performHapticFeedback(HapticFeedbackConstants.LONG_PRESS)
                            }
                            is HoldToReport.Effect.Selected -> {
                                fan.open = true
                                fan.selected = e.slot
                                if (e.slot != null) view.performHapticFeedback(HapticFeedbackConstants.CLOCK_TICK)
                            }
                            is HoldToReport.Effect.Send -> {
                                fan.open = false; fan.selected = null
                                view.performHapticFeedback(HapticFeedbackConstants.CONFIRM)
                                send(e.type)
                            }
                            HoldToReport.Effect.Cancel -> { fan.open = false; fan.selected = null }
                        }
                    }
                    handle(g.down(SystemClock.uptimeMillis()))
                    var finished = false
                    try {
                        while (true) {
                            val ev = withTimeoutOrNull(16) { awaitPointerEvent() }
                            val now = SystemClock.uptimeMillis()
                            if (ev == null) { handle(g.tick(now)); continue }
                            val ch = ev.changes.firstOrNull { it.id == down.id } ?: break
                            pos = ch.position
                            if (!ch.pressed) { ch.consume(); finished = true; handle(g.up(dx(), dy(), now)); break }
                            ch.consume()
                            handle(g.move(dx(), dy(), now))
                        }
                    } finally {
                        if (!finished) handle(g.cancel())
                    }
                }
            },
        contentAlignment = Alignment.Center,
    ) {
        GIcon("report", null, size = Sizes.reportFabIcon, stroke = c.reportOn, fill = c.reportOn)
    }
}

/** The fan over the dimmed map (canvas NavLaporTahan / NavLaporPilih): 8 slots, the top banner, and the close button. */
@Composable
fun QuickFanOverlay(fan: QuickFanState) {
    val density = LocalDensity.current
    var origin by remember { mutableStateOf(Offset.Zero) }
    Box(
        Modifier.fillMaxSize()
            .onGloballyPositioned { origin = it.positionInRoot() }
            .background(Color(0x800B1B3A))
            // Swallows taps while open (the button's own gesture tracks the finger).
            .clickable(interactionSource = remember { MutableInteractionSource() }, indication = null) {},
    ) {
        val sel = fan.selected
        val cx = fan.center.x - origin.x
        val cy = fan.center.y - origin.y
        QuickFan.slots.forEach { s ->
            val (ox, oy) = QuickFan.offset(s, fan.scale)
            val chosen = s == sel
            val sizeDp = (if (chosen) QuickFan.SELECTED_SIZE_DP else s.sizeDp) * fan.scale
            val px = with(density) { sizeDp.dp.toPx() }
            val x = cx + ox * density.density - px / 2
            val y = cy + oy * density.density - px / 2
            FanSlot(s, sizeDp, chosen, dim = sel != null && !chosen,
                modifier = Modifier.offset { IntOffset(x.roundToInt(), y.roundToInt()) })
        }
        // Where the report button was: a navy close button (release on it = cancel).
        val btn = with(density) { Sizes.reportFab.toPx() }
        Box(
            Modifier.offset { IntOffset((cx - btn / 2).roundToInt(), (cy - btn / 2).roundToInt()) }
                .size(Sizes.reportFab).shadow(10.dp, CircleShape).clip(CircleShape).background(Navy),
            contentAlignment = Alignment.Center,
        ) { Icon(Icons.Filled.Close, stringResource(R.string.qr_close), tint = Color.White, modifier = Modifier.size(32.dp)) }
        FanBanner(sel, Modifier.align(Alignment.TopCenter).windowInsetsPadding(WindowInsets.statusBars).padding(top = 162.dp, start = 10.dp, end = 10.dp))
    }
}

@Composable
private fun FanSlot(s: QuickFan.Slot, sizeDp: Float, chosen: Boolean, dim: Boolean, modifier: Modifier) {
    val color = Color(s.color)
    val ink = Color(s.ink)
    // The label hangs below the circle; the Column is as wide as the circle so its centre stays on the slot.
    Column(modifier.width(sizeDp.dp).alpha(if (dim) 0.45f else 1f), horizontalAlignment = Alignment.CenterHorizontally) {
        Box(
            Modifier.size(sizeDp.dp)
                .then(if (chosen) Modifier.drawBehind { drawCircle(color.copy(alpha = 0.45f), radius = size.minDimension / 2 + 8.dp.toPx()) } else Modifier)
                .shadow(if (chosen) 12.dp else 6.dp, CircleShape).clip(CircleShape).background(color)
                .border(BorderStroke(if (chosen) 4.dp else 3.dp, Color.White.copy(alpha = 0.9f)), CircleShape),
            contentAlignment = Alignment.Center,
        ) { GIcon(GIcons.report(s.type), null, size = (sizeDp * 0.48f).dp, stroke = ink, fill = ink.copy(alpha = 0.3f)) }
        Text(
            stringResource(Labels.shortType(s.type)), color = Color.White, fontSize = if (chosen) 15.sp else 13.sp,
            fontWeight = FontWeight.Black, maxLines = 1, softWrap = false, modifier = Modifier.wrapContentWidth(unbounded = true).padding(top = 4.dp),
            style = androidx.compose.ui.text.TextStyle(shadow = androidx.compose.ui.graphics.Shadow(Color(0x99000000), Offset(0f, 1f), 3f)),
        )
    }
}

@Composable
private fun FanBanner(sel: QuickFan.Slot?, modifier: Modifier) {
    val bg = sel?.let { Color(it.color) } ?: Navy
    val fg = sel?.let { Color(it.ink) } ?: Color.White
    Column(
        modifier.fillMaxWidth().shadow(12.dp, RoundedCornerShape(20.dp)).clip(RoundedCornerShape(20.dp)).background(bg)
            .semantics(mergeDescendants = true) { liveRegion = androidx.compose.ui.semantics.LiveRegionMode.Polite }
            .padding(horizontal = 18.dp, vertical = 14.dp),
    ) {
        Text(if (sel == null) stringResource(R.string.qr_hint_title) else stringResource(Labels.reportType(sel.type)),
            color = fg, fontSize = 22.sp, fontWeight = FontWeight.Black, lineHeight = 26.sp)
        Text(stringResource(if (sel == null) R.string.qr_hint_sub else R.string.qr_release_sub),
            color = fg.copy(alpha = 0.9f), fontSize = 14.sp, fontWeight = FontWeight.Bold)
    }
}

/**
 * "Hazard reported · Jalan SS 2/55 · just now" with Details and a 5 s Undo (canvas NavLaporHantar). When the 5 s run
 * out the card closes and the report stays.
 */
@Composable
fun QuickReportSentCard(card: QuickReportCard, onDetails: () -> Unit, onUndo: () -> Unit, onTimeout: () -> Unit, modifier: Modifier = Modifier) {
    val c = Gimano.colors
    val slot = QuickFan.slot(card.type)
    val color = slot?.let { Color(it.color) } ?: c.report
    val ink = slot?.let { Color(it.ink) } ?: Color.White
    val what = stringResource(Labels.reportType(card.type))
    Row(
        modifier.fillMaxWidth().shadow(12.dp, RoundedCornerShape(22.dp)).clip(RoundedCornerShape(22.dp)).background(c.surface)
            .semantics(mergeDescendants = false) { liveRegion = androidx.compose.ui.semantics.LiveRegionMode.Polite }
            .padding(12.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Box(Modifier.size(48.dp).clip(CircleShape).background(color), contentAlignment = Alignment.Center) {
            GIcon(GIcons.report(card.type), null, size = 28.dp, stroke = ink, fill = ink.copy(alpha = 0.3f))
        }
        Spacer(Modifier.width(12.dp))
        Column(Modifier.weight(1f).semantics(mergeDescendants = true) {}) {
            Text(stringResource(R.string.qr_reported, what), fontSize = 18.sp, fontWeight = FontWeight.Black, color = c.text,
                lineHeight = 21.sp, maxLines = 2, overflow = TextOverflow.Ellipsis)
            Text(listOfNotNull(card.street?.takeIf { it.isNotBlank() }, stringResource(R.string.qr_just_now)).joinToString(" · "),
                fontSize = 13.sp, fontWeight = FontWeight.Bold, color = c.textMuted, maxLines = 2, overflow = TextOverflow.Ellipsis)
        }
        Spacer(Modifier.width(8.dp))
        Box(
            Modifier.height(48.dp).clip(RoundedCornerShape(14.dp)).border(BorderStroke(2.dp, c.outline), RoundedCornerShape(14.dp))
                .background(c.surface).clickable(role = Role.Button, onClick = onDetails).padding(horizontal = 12.dp),
            contentAlignment = Alignment.Center,
        ) { Text(stringResource(R.string.details), fontSize = 15.sp, fontWeight = FontWeight.Black, color = c.brandInk) }
        Spacer(Modifier.width(8.dp))
        Row(
            Modifier.height(48.dp).clip(RoundedCornerShape(14.dp)).background(c.brand)
                .clickable(role = Role.Button, onClick = onUndo).padding(start = 8.dp, end = 12.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            my.gimano.app.ui.common.CountdownRing(card.key, totalMs = Countdown.UNDO_MS, onTimeout = onTimeout, size = 30.dp, onDark = true, tappable = false)
            Spacer(Modifier.width(4.dp))
            Text(stringResource(R.string.qr_undo), fontSize = 15.sp, fontWeight = FontWeight.Black, color = c.brandOn)
        }
    }
}
