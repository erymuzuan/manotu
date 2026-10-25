package my.gimano.app.ui.common

import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.QuestionMark
import androidx.compose.material.icons.filled.ThumbDown
import androidx.compose.material.icons.filled.ThumbUp
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.layout.Layout
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import android.os.SystemClock
import androidx.compose.runtime.withFrameMillis
import androidx.compose.ui.unit.Dp
import my.gimano.app.core.drive.Countdown
import my.gimano.app.core.drive.LabelFit
import my.gimano.app.R
import my.gimano.app.ui.theme.Gimano

/** Solid cobalt (primary), pale cobalt, or outlined. */
enum class ConfirmStyle { SOLID, PALE, OUTLINED }

data class ConfirmOption(val label: String, val icon: ImageVector, val style: ConfirmStyle, val onClick: () -> Unit)

object ConfirmIcons {
    val yes: ImageVector get() = Icons.Filled.Close          // "Masih ditutup": the closure is still there
    val cleared: ImageVector get() = Icons.Filled.Check      // "Sudah dibuka"
    val unsure: ImageVector get() = Icons.Filled.QuestionMark
    val up: ImageVector get() = Icons.Filled.ThumbUp
    val down: ImageVector get() = Icons.Filled.ThumbDown
}

/**
 * Driving confirm buttons (canvas NavSahkan): equal widths, at least 84 dp tall, the icon above the FULL label
 * (up to 2 lines, never clipped: at very large text the buttons grow, all to the same height).
 */
@Composable
fun ConfirmButtons(options: List<ConfirmOption>, modifier: Modifier = Modifier) {
    // Equal-height row: every button takes the tallest one's height (min 84 dp).
    Layout(
        content = { options.forEach { o -> ConfirmButton(o) } },
        modifier = modifier.fillMaxWidth(),
    ) { measurables, constraints ->
        val gap = 8.dp.roundToPx()
        val n = measurables.size.coerceAtLeast(1)
        val w = ((constraints.maxWidth - gap * (n - 1)) / n).coerceAtLeast(0)
        val minH = 84.dp.roundToPx()
        val h = maxOf(minH, measurables.maxOfOrNull { it.minIntrinsicHeight(w) } ?: minH)
        val placeables = measurables.map { it.measure(androidx.compose.ui.unit.Constraints.fixed(w, h)) }
        layout(constraints.maxWidth, h) {
            placeables.forEachIndexed { i, p -> p.placeRelative(i * (w + gap), 0) }
        }
    }
}

@Composable
private fun ConfirmButton(o: ConfirmOption) {
    val c = Gimano.colors
    val shape = RoundedCornerShape(18.dp)
    val (bg, fg) = when (o.style) {
        ConfirmStyle.SOLID -> c.brand to c.brandOn
        ConfirmStyle.PALE -> c.brandMist to c.brandInk
        ConfirmStyle.OUTLINED -> c.surface to c.text
    }
    Column(
        Modifier.clip(shape).background(bg)
            .then(if (o.style == ConfirmStyle.OUTLINED) Modifier.border(BorderStroke(2.dp, c.outline), shape) else Modifier)
            .clickable(role = Role.Button, onClick = o.onClick)
            .padding(horizontal = 6.dp, vertical = 10.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.Center,
    ) {
        val iconBg = when (o.style) { ConfirmStyle.SOLID -> Color.White.copy(alpha = 0.22f); ConfirmStyle.PALE -> c.brandTint; ConfirmStyle.OUTLINED -> c.surfaceAlt }
        Box(Modifier.size(28.dp).clip(CircleShape).background(iconBg), contentAlignment = Alignment.Center) {
            Icon(o.icon, null, tint = if (o.style == ConfirmStyle.PALE) c.brand else fg, modifier = Modifier.size(18.dp))
        }
        Spacer(Modifier.height(6.dp))
        // Full label, up to 2 lines, never ellipsized: the font shrinks first (15 → 11 sp), then the row grows.
        FitLabel(o.label, fg)
    }
}

/** Up to 2 lines at 15 sp; on overflow one size smaller at a time down to 11 sp; at 11 sp it wraps freely (never cut). */
@Composable
private fun FitLabel(label: String, color: Color) {
    var sp by remember(label) { mutableFloatStateOf(LabelFit.MAX_SP) }
    val atMin = LabelFit.shrink(sp) == null
    Text(
        label, color = color, fontSize = sp.sp, fontWeight = FontWeight.Black, textAlign = TextAlign.Center,
        lineHeight = (sp * 1.2f).sp, maxLines = if (atMin) Int.MAX_VALUE else LabelFit.MAX_LINES, softWrap = true,
        onTextLayout = { r -> if (r.hasVisualOverflow) LabelFit.shrink(sp)?.let { sp = it } },
    )
}

/**
 * The 10 s countdown ring (canvas NavSahkan): a draining arc and the seconds left; at 0 it calls [onTimeout]
 * (no answer). Tapping it dismisses early (also no answer).
 */
@Composable
fun CountdownRing(key: Any, totalMs: Long = Countdown.CONFIRM_MS, onTimeout: () -> Unit, modifier: Modifier = Modifier, size: Dp = 48.dp, onDark: Boolean = false, tappable: Boolean = true) {
    val c = Gimano.colors
    val countdown = remember(key) { Countdown(totalMs, SystemClock.uptimeMillis()) }
    var now by remember(key) { mutableLongStateOf(SystemClock.uptimeMillis()) }
    val done by rememberUpdatedState(onTimeout)
    LaunchedEffect(key) {
        while (!countdown.expired(now)) { withFrameMillis { }; now = SystemClock.uptimeMillis() }
        done()
    }
    val left = countdown.secondsLeft(now)
    val label = stringResource(R.string.confirm_dismiss_in, left)
    val track = if (onDark) Color.White.copy(alpha = 0.35f) else c.brandMist
    val arcColor = if (onDark) Color.White else c.brand
    Box(
        modifier.size(size).clip(CircleShape)
            .then(if (tappable) Modifier.clickable(role = Role.Button) { done() }.semantics { contentDescription = label } else Modifier),
        contentAlignment = Alignment.Center,
    ) {
        Canvas(Modifier.size(size * 0.84f)) {
            val stroke = (size.toPx() / 12f).coerceAtLeast(3.dp.toPx())
            val inset = stroke / 2
            val arc = Size(this.size.width - stroke, this.size.height - stroke)
            drawArc(track, 0f, 360f, false, Offset(inset, inset), arc, style = Stroke(stroke))
            drawArc(arcColor, -90f, 360f * countdown.fraction(now), false, Offset(inset, inset), arc, style = Stroke(stroke, cap = StrokeCap.Round))
        }
        Text("$left", color = if (onDark) Color.White else c.brandInk, fontSize = (size.value / 3.2f).sp, fontWeight = FontWeight.Black)
    }
}

/**
 * The driving confirm card (docs/driving.md §6.1, canvas NavSahkan): icon tile, question, "kind · street · age",
 * the 10 s ring, then three equal 84 dp buttons. Used for "Still closed?" (road issues) and "Still there?" (alerts).
 * At very large text the tile is dropped and the subtitle kept to 2 lines, so the card never rides up over the
 * maneuver banner.
 */
@Composable
fun ConfirmCard(
    key: Any,
    title: String,
    subtitle: String,
    options: List<ConfirmOption>,
    onTimeout: () -> Unit,
    modifier: Modifier = Modifier,
    tile: @Composable () -> Unit,
) {
    val c = Gimano.colors
    androidx.compose.material3.Surface(modifier.fillMaxWidth(), shape = RoundedCornerShape(24.dp), color = c.surface, shadowElevation = 10.dp) {
        Column(Modifier.padding(16.dp)) {
            val big = androidx.compose.ui.platform.LocalDensity.current.fontScale >= 1.5f
            Row(verticalAlignment = Alignment.CenterVertically) {
                if (!big) { tile(); Spacer(Modifier.width(12.dp)) }
                Column(Modifier.weight(1f).semantics(mergeDescendants = true) {}) {
                    Text(title, fontSize = 22.sp, fontWeight = FontWeight.Black, color = c.text, lineHeight = 25.sp)
                    Text(subtitle, fontSize = 14.sp, fontWeight = FontWeight.Bold, color = c.textMuted,
                        maxLines = if (big) 2 else 3, overflow = androidx.compose.ui.text.style.TextOverflow.Ellipsis)
                }
                Spacer(Modifier.width(8.dp))
                CountdownRing(key, onTimeout = onTimeout)
            }
            Spacer(Modifier.height(14.dp))
            ConfirmButtons(options)
        }
    }
}
