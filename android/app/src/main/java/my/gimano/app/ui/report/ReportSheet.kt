package my.gimano.app.ui.report

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.grid.GridCells
import androidx.compose.foundation.lazy.grid.LazyVerticalGrid
import androidx.compose.foundation.lazy.grid.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.Check
import my.gimano.app.core.safety.ContentGate
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import my.gimano.app.R
import my.gimano.app.ui.common.GIcons
import my.gimano.app.ui.common.Labels
import my.gimano.app.ui.common.ReportTile
import my.gimano.app.ui.theme.Gimano
import my.gimano.app.ui.theme.Radius
import my.gimano.app.ui.theme.ReportColors
import my.gimano.app.ui.theme.Sizes
import my.gimano.app.ui.theme.GimanoType
import androidx.compose.ui.semantics.liveRegion
import androidx.compose.ui.semantics.semantics
import my.gimano.app.core.report.ReportDefaults

/** "What do you see?" — 3×3 grid of report types, then one-tap subtypes. */
@Composable
fun ReportSheet(
    onDismiss: () -> Unit,
    onSubmit: (type: String, subtype: String?, comment: String?) -> Unit,
    /** Complaints v1 "Masalah jalan" group (during navigation, when the server has /issues). */
    onRoadProblem: ((type: String, durationHint: String?) -> Unit)? = null,
    /** Opened straight at this type's subtypes ("Details" after a quick report, docs/driving.md §6.4); back closes. */
    initialType: String? = null,
) {
    val c = Gimano.colors
    val sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)
    var type by remember { mutableStateOf(initialType) }
    var comment by remember { mutableStateOf("") }
    var road by remember { mutableStateOf<String?>(null) }
    ModalBottomSheet(
        onDismissRequest = onDismiss,
        sheetState = sheetState,
        containerColor = c.surface,
        shape = RoundedCornerShape(topStart = Radius.sheet, topEnd = Radius.sheet),
    ) {
        Column(Modifier.fillMaxWidth().verticalScroll(rememberScrollState()).padding(horizontal = 16.dp).padding(bottom = 24.dp)) {
            val t = type
            val rp = road
            if (rp != null && onRoadProblem != null) {
                my.gimano.app.ui.issues.RoadProblemConfirm(rp, onBack = { road = null }) { d -> onRoadProblem(rp, d) }
            } else if (t == null) {
                Spacer(Modifier.height(4.dp))
                LazyVerticalGrid(
                    GridCells.Fixed(3), verticalArrangement = Arrangement.spacedBy(14.dp), horizontalArrangement = Arrangement.spacedBy(10.dp),
                    userScrollEnabled = false, modifier = Modifier.heightIn(max = 560.dp),
                ) {
                    items(GIcons.reportTypes) { rt ->
                        val label = stringResource(Labels.shortType(rt))
                        Column(
                            Modifier.clip(RoundedCornerShape(Radius.md)).semantics(mergeDescendants = true) {}.clickable(onClickLabel = label) {
                                type = rt
                            }.padding(vertical = 4.dp),
                            horizontalAlignment = Alignment.CenterHorizontally,
                        ) {
                            ReportTile(rt, Sizes.reportTile, iconSize = Sizes.reportTileIcon, radius = Radius.reportTile)
                            Text(label, style = GimanoType.label.copy(fontSize = 15.sp), color = c.text, textAlign = TextAlign.Center, modifier = Modifier.padding(top = 6.dp), maxLines = 1)
                        }
                    }
                }
            } else {
                Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.padding(bottom = 12.dp)) {
                    IconButton(onClick = { if (initialType != null) onDismiss() else type = null }) { Icon(Icons.AutoMirrored.Filled.ArrowBack, stringResource(R.string.back), tint = c.text) }
                    ReportTile(t, 48.dp)
                    Spacer(Modifier.width(12.dp))
                    Text(stringResource(Labels.reportType(t)), fontSize = 22.sp, fontWeight = FontWeight.SemiBold, color = c.text)
                }
                val subs = Labels.subtypes[t].orEmpty()
                if (t == "map_issue" && onRoadProblem != null) {
                    // Map issue and the road problems: their own sheet, never sent by a timer.
                    my.gimano.app.ui.issues.RoadProblemGroup { road = it }
                } else {
                    DetailBody(t, subs, comment, { comment = it }, onSubmit, onDismiss = { if (initialType != null) onDismiss() else type = null })
                }
            }
        }
    }
}

/** One-line note with a counter and an OK tick that puts the keyboard away. */
@Composable
private fun NoteField(note: String, onNote: (String) -> Unit, modifier: Modifier = Modifier) {
    val focus = androidx.compose.ui.platform.LocalFocusManager.current
    OutlinedTextField(
        note, onNote, modifier.fillMaxWidth(),
        placeholder = { Text(stringResource(R.string.cs_note_hint)) }, minLines = 1, maxLines = 3,
        shape = RoundedCornerShape(Radius.md),
        supportingText = if (note.isNotEmpty()) ({ Text(stringResource(R.string.cs_note_count, note.length, ContentGate.NOTE_MAX), Modifier.fillMaxWidth(), textAlign = TextAlign.End) }) else null,
        trailingIcon = {
            IconButton(onClick = { focus.clearFocus() }, Modifier.size(48.dp)) { Icon(Icons.Filled.Check, stringResource(R.string.cs_note_ok_cd), tint = Gimano.colors.brand) }
        },
        keyboardOptions = androidx.compose.foundation.text.KeyboardOptions(imeAction = androidx.compose.ui.text.input.ImeAction.Done),
        keyboardActions = androidx.compose.foundation.text.KeyboardActions(onDone = { focus.clearFocus() }),
    )
}

/**
 * The sheet both doors end on (docs/driving.md §6.4, canvas RpDetail): the default subtype is picked, and Report sends
 * itself after [ReportDefaults.AUTO_SEND_MS] (the button fills as it runs). Touching an option or the comment stops the
 * timer; Cancel closes without sending.
 */
@Composable
private fun DetailBody(
    t: String, subs: List<Pair<String, Int>>, comment: String, onComment: (String) -> Unit,
    onSubmit: (String, String?, String?) -> Unit, onDismiss: () -> Unit,
) {
    val c = Gimano.colors
    var picked by remember(t) { mutableStateOf(ReportDefaults.defaultSubtype(t)) }
    var timerOn by remember(t) { mutableStateOf(ReportDefaults.autoSends(t) && comment.isBlank()) }
    val fill = remember(t) { androidx.compose.animation.core.Animatable(0f) }
    val send by rememberUpdatedState { onSubmit(t, picked, comment.takeIf { it.isNotBlank() }) }
    LaunchedEffect(timerOn) {
        if (!timerOn) { fill.snapTo(0f); return@LaunchedEffect }
        fill.animateTo(1f, androidx.compose.animation.core.tween(ReportDefaults.AUTO_SEND_MS.toInt(), easing = androidx.compose.animation.core.LinearEasing))
        send()
    }
    if (subs.isNotEmpty()) {
        LazyVerticalGrid(
            GridCells.Fixed(2), verticalArrangement = Arrangement.spacedBy(10.dp), horizontalArrangement = Arrangement.spacedBy(10.dp),
            modifier = Modifier.heightIn(max = 420.dp),
        ) {
            items(subs) { (sub, label) ->
                val on = picked == sub
                val tone = ReportColors.duotone(t)
                Button(
                    onClick = { picked = sub; timerOn = false },
                    modifier = Modifier.fillMaxWidth().height(64.dp),
                    shape = RoundedCornerShape(Radius.md),
                    border = if (on) androidx.compose.foundation.BorderStroke(3.dp, tone.stroke) else null,
                    colors = ButtonDefaults.buttonColors(containerColor = if (on) tone.tile else c.surfaceAlt, contentColor = if (on) tone.stroke else c.text),
                ) { Text(stringResource(label), fontSize = 16.sp, fontWeight = if (on) FontWeight.Black else FontWeight.SemiBold, textAlign = TextAlign.Center) }
            }
        }
    }
    // docs/content-safety.md "Report notes": at most 140 characters; the server may drop a note that fails the check
    // (the report still goes out and a one-line note says so).
    NoteField(comment, { onComment(it.take(ContentGate.NOTE_MAX)); timerOn = false }, Modifier.padding(top = if (subs.isNotEmpty()) 10.dp else 0.dp))
    if (timerOn) {
        val secs = (ReportDefaults.AUTO_SEND_MS / 1000 * (1f - fill.value)).let { kotlin.math.ceil(it).toInt().coerceAtLeast(1) }
        Text(stringResource(R.string.report_sends_in, secs), fontSize = 14.sp, fontWeight = FontWeight.Bold, color = c.textMuted,
            modifier = Modifier.padding(top = 10.dp).semantics { liveRegion = androidx.compose.ui.semantics.LiveRegionMode.Polite })
    }
    Spacer(Modifier.height(12.dp))
    Row(horizontalArrangement = Arrangement.spacedBy(10.dp), modifier = Modifier.fillMaxWidth()) {
        OutlinedButton(onClick = onDismiss, modifier = Modifier.weight(1f).height(56.dp), shape = RoundedCornerShape(Radius.md)) {
            Text(stringResource(R.string.cancel), fontSize = 17.sp, fontWeight = FontWeight.SemiBold)
        }
        Box(Modifier.weight(1.4f).height(56.dp).clip(RoundedCornerShape(Radius.md)).background(c.report)) {
            // The sweep shows the time left before it sends itself.
            if (timerOn) Box(Modifier.fillMaxHeight().fillMaxWidth(fill.value).background(androidx.compose.ui.graphics.Color.Black.copy(alpha = 0.22f)))
            TextButton(onClick = { send() }, modifier = Modifier.fillMaxSize(), colors = ButtonDefaults.textButtonColors(contentColor = c.reportOn)) {
                Text(stringResource(R.string.report_action), fontSize = 17.sp, fontWeight = FontWeight.Black)
            }
        }
    }
}
