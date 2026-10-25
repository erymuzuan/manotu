package my.gimano.app.ui.common

import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.selection.selectable
import androidx.compose.foundation.selection.selectableGroup
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.Image
import androidx.compose.material3.RadioButton
import androidx.compose.material3.RadioButtonDefaults
import androidx.compose.material3.Slider
import androidx.compose.material3.SliderDefaults
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.rememberVectorPainter
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.LiveRegionMode
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.liveRegion
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.IntRect
import androidx.compose.ui.unit.IntSize
import androidx.compose.ui.unit.LayoutDirection
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.window.Popup
import androidx.compose.ui.window.PopupPositionProvider
import androidx.compose.ui.window.PopupProperties
import my.gimano.app.R
import my.gimano.app.data.settings.SoundMode
import my.gimano.app.ui.theme.Gimano
import my.gimano.app.ui.theme.Sizes
import kotlin.math.roundToInt

private val MuteOrange = Color(0xFFC2410C)
private val MutePeach = Color(0xFFFFF1EA)

@Composable
private fun modeTitle(m: SoundMode) = stringResource(when (m) { SoundMode.ON -> R.string.sound_full; SoundMode.ALERTS_ONLY -> R.string.sound_alerts; SoundMode.OFF -> R.string.sound_mute })

@Composable
private fun modeSub(m: SoundMode) = stringResource(when (m) { SoundMode.ON -> R.string.sound_full_sub; SoundMode.ALERTS_ONLY -> R.string.sound_alerts_sub; SoundMode.OFF -> R.string.sound_mute_sub })

@Composable
fun SoundGlyph(m: SoundMode, size: Dp) {
    val c = Gimano.colors
    when (m) {
        SoundMode.ON -> TwoToneIcon("sound_full", null, size = size)
        SoundMode.ALERTS_ONLY -> TwoToneIcon("bell", null, size = size)
        SoundMode.OFF -> {
            val v = remember(c.brandTint) { TwoTone.vector("sound_mute", c.brandTint, MuteOrange) }
            Image(rememberVectorPainter(v), null, Modifier.size(size))
        }
    }
}

/**
 * Sound FAB (canvas NavBunyiKeadaan): one icon per mode (speaker + waves / bell / crossed speaker with an orange
 * ring). Tap opens the "BUNYI" panel; long-press is quick mute (or back to the last non-mute mode).
 * TalkBack reads "Sound: Alerts only"; the new choice is announced by the 2 s toast ([SoundToastPill], a live region).
 */
@OptIn(ExperimentalFoundationApi::class)
@Composable
fun SoundFab(
    mode: SoundMode,
    voiceVolume: Int,
    onSelect: (SoundMode) -> Unit,
    onLongPress: () -> Unit,
    onVolume: (Int) -> Unit,
    modifier: Modifier = Modifier,
    size: Dp = Sizes.roundFab,
) {
    val c = Gimano.colors
    var open by remember { mutableStateOf(false) }
    val title = modeTitle(mode)
    val desc = stringResource(R.string.sound_fab_desc, title)
    val chooseLabel = stringResource(R.string.sound_choose)
    val muteLabel = stringResource(if (mode == SoundMode.OFF) R.string.sound_unmute else R.string.sound_quick_mute)
    val muted = mode == SoundMode.OFF
    Box(modifier) {
        Box(
            Modifier.size(size)
                .shadow(8.dp, CircleShape, ambientColor = FabShadow, spotColor = FabShadow)
                .clip(CircleShape)
                .background(if (muted) MutePeach else c.surface)
                .then(if (muted) Modifier.border(3.dp, MuteOrange, CircleShape) else Modifier)
                .combinedClickable(onClickLabel = chooseLabel, onLongClickLabel = muteLabel, onLongClick = onLongPress) { open = true }
                .semantics {
                    contentDescription = desc
                    stateDescription = title
                },
            contentAlignment = Alignment.Center,
        ) { SoundGlyph(mode, size * 0.47f) }
        if (open) SoundPanel(mode, voiceVolume, onDismiss = { open = false },
            onSelect = { m -> open = false; onSelect(m) }, onVolume = onVolume)
    }
}

/** Below the FAB, right-aligned to it, kept inside the window (very large text included). */
private class BelowAnchorEnd(private val gapPx: Int, private val marginPx: Int) : PopupPositionProvider {
    override fun calculatePosition(anchorBounds: IntRect, windowSize: IntSize, layoutDirection: LayoutDirection, popupContentSize: IntSize): IntOffset {
        val x = (anchorBounds.right - popupContentSize.width).coerceIn(marginPx, (windowSize.width - popupContentSize.width - marginPx).coerceAtLeast(marginPx))
        val below = anchorBounds.bottom + gapPx
        val y = if (below + popupContentSize.height + marginPx <= windowSize.height) below
            else (windowSize.height - popupContentSize.height - marginPx).coerceAtLeast(marginPx)
        return IntOffset(x, y)
    }
}

/** "BUNYI": Full / Alerts only / Mute (current one checked) and the app voice volume. Pick or tap outside = close. */
@Composable
private fun SoundPanel(mode: SoundMode, voiceVolume: Int, onDismiss: () -> Unit, onSelect: (SoundMode) -> Unit, onVolume: (Int) -> Unit) {
    val c = Gimano.colors
    val density = LocalDensity.current
    val provider = remember(density) { with(density) { BelowAnchorEnd(10.dp.roundToPx(), 12.dp.roundToPx()) } }
    Popup(popupPositionProvider = provider, onDismissRequest = onDismiss, properties = PopupProperties(focusable = true)) {
        Surface(
            Modifier.widthIn(min = 280.dp, max = 340.dp),
            shape = RoundedCornerShape(24.dp), color = c.surface, shadowElevation = 12.dp,
        ) {
            Column(Modifier.padding(horizontal = 12.dp, vertical = 14.dp)) {
                Text(stringResource(R.string.sound_panel_title).uppercase(), Modifier.padding(start = 8.dp, bottom = 8.dp),
                    fontSize = 12.sp, fontWeight = FontWeight.Black, letterSpacing = 0.6.sp, color = c.textMuted)
                Column(Modifier.selectableGroup(), verticalArrangement = Arrangement.spacedBy(6.dp)) {
                    SoundMode.entries.forEach { m ->
                        val sel = m == mode
                        Row(
                            Modifier.fillMaxWidth().heightIn(min = 64.dp).clip(RoundedCornerShape(16.dp))
                                .background(if (sel) c.brandMist else Color.Transparent)
                                .then(if (sel) Modifier.border(2.dp, c.brand, RoundedCornerShape(16.dp)) else Modifier)
                                .selectable(selected = sel, role = Role.RadioButton) { onSelect(m) }
                                .padding(horizontal = 10.dp, vertical = 8.dp),
                            verticalAlignment = Alignment.CenterVertically,
                        ) {
                            Box(Modifier.size(44.dp).clip(CircleShape).background(if (sel) c.surface else c.brandMist), contentAlignment = Alignment.Center) {
                                SoundGlyph(m, 26.dp)
                            }
                            Spacer(Modifier.width(12.dp))
                            Column(Modifier.weight(1f)) {
                                Text(modeTitle(m), fontSize = 17.sp, fontWeight = FontWeight.Black, color = c.text)
                                Text(modeSub(m), fontSize = 13.sp, fontWeight = FontWeight.Bold, color = c.textMuted)
                            }
                            RadioButton(selected = sel, onClick = null, colors = RadioButtonDefaults.colors(selectedColor = c.brand, unselectedColor = c.outline))
                        }
                    }
                }
                // App voice volume (spoken directions), persisted on this phone when the finger lifts.
                var v by remember(voiceVolume) { mutableFloatStateOf(voiceVolume.toFloat()) }
                val volLabel = stringResource(R.string.voice_volume)
                val slider = @Composable { m: Modifier ->
                    Slider(
                        value = v, onValueChange = { v = it }, valueRange = 0f..100f,
                        onValueChangeFinished = { onVolume(v.roundToInt()) },
                        modifier = m.semantics { contentDescription = volLabel },
                        colors = SliderDefaults.colors(thumbColor = c.brand, activeTrackColor = c.brand, inactiveTrackColor = c.surfaceAlt),
                    )
                }
                if (LocalDensity.current.fontScale < 1.5f) {
                    Row(Modifier.fillMaxWidth().padding(start = 8.dp, end = 8.dp, top = 8.dp), verticalAlignment = Alignment.CenterVertically) {
                        Text(volLabel, fontSize = 14.sp, fontWeight = FontWeight.ExtraBold, color = c.text)
                        Spacer(Modifier.width(10.dp))
                        slider(Modifier.weight(1f))
                        Spacer(Modifier.width(8.dp))
                        Text("${v.roundToInt()}%", fontSize = 14.sp, fontWeight = FontWeight.ExtraBold, color = c.text)
                    }
                } else {
                    // Very large text: label + value on one line, the slider full width below it.
                    Column(Modifier.fillMaxWidth().padding(start = 8.dp, end = 8.dp, top = 8.dp)) {
                        Row(verticalAlignment = Alignment.CenterVertically) {
                            Text(volLabel, Modifier.weight(1f), fontSize = 14.sp, fontWeight = FontWeight.ExtraBold, color = c.text)
                            Text("${v.roundToInt()}%", fontSize = 14.sp, fontWeight = FontWeight.ExtraBold, color = c.text)
                        }
                        slider(Modifier.fillMaxWidth())
                    }
                }
            }
        }
    }
}

/**
 * The 2 s sound toast (canvas NavBunyiKeadaan): a navy pill with the new mode's icon, "Alerts only · voice directions
 * off". A polite live region, so TalkBack announces the new choice.
 */
@Composable
fun SoundToastPill(mode: SoundMode, text: String, modifier: Modifier = Modifier) {
    Row(
        modifier.clip(RoundedCornerShape(999.dp)).background(Color(0xFF0B1F4A))
            .semantics { liveRegion = LiveRegionMode.Polite; contentDescription = text }
            .padding(horizontal = 18.dp, vertical = 12.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        SoundGlyph(mode, 24.dp)
        Spacer(Modifier.width(10.dp))
        Text(text, color = Color.White, fontSize = 15.sp, fontWeight = FontWeight.ExtraBold)
    }
}
