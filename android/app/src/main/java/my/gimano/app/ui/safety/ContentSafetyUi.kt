package my.gimano.app.ui.safety

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import my.gimano.app.R
import my.gimano.app.core.safety.AdTile
import my.gimano.app.core.safety.ContentFailure
import my.gimano.app.core.safety.ContentGate
import my.gimano.app.core.safety.ContentIssue
import my.gimano.app.core.safety.ContentState
import my.gimano.app.core.safety.PhotoIssue
import my.gimano.app.core.safety.PlaceWarning
import my.gimano.app.ui.contribute.untilText
import my.gimano.app.ui.theme.Gimano
import my.gimano.app.ui.theme.GimanoType
import my.gimano.app.ui.theme.Radius
import java.time.Instant

/*
 * Public content safety screens (docs/content-safety.md). Icon-led: every tile carries one word at most, and every icon
 * button has an accessibility label. The copy comes from fixed reason codes (ContentGate), never from the model.
 */

/** Amber "warning" tones (design tokens: tile / fill / stroke), dark-theme variants from the dark amber of the Inbox. */
@Composable
fun warnTile(): Color = if (Gimano.colors.isDark) Color(0xFF3A2E12) else Color(0xFFFFF1CC)
@Composable
fun warnFill(): Color = if (Gimano.colors.isDark) Color(0xFF8A6A1E) else Color(0xFFFFD466)
@Composable
fun warnInk(): Color = if (Gimano.colors.isDark) Color(0xFFFFD98A) else Color(0xFF7A5200)

/** Calm green for "published", amber for "a person is checking", red for "no" (same tones as the add-place gate). */
@Composable
fun goodTile(): Color = if (Gimano.colors.isDark) Color(0xFF123B33) else Color(0xFFDDF4F2)
@Composable
fun goodInk(): Color = if (Gimano.colors.isDark) Color(0xFF7FE0C2) else Color(0xFF0E8A5F)

fun PlaceWarning.icon(): ImageVector = when (this) {
    PlaceWarning.ALCOHOL -> Icons.Filled.LocalBar
    PlaceWarning.GAMBLING -> Icons.Filled.Casino
    PlaceWarning.TOBACCO -> Icons.Filled.SmokingRooms
}

fun PlaceWarning.line(): Int = when (this) {
    PlaceWarning.ALCOHOL -> R.string.cs_warn_alcohol
    PlaceWarning.GAMBLING -> R.string.cs_warn_gambling
    PlaceWarning.TOBACCO -> R.string.cs_warn_tobacco
}

fun PlaceWarning.tileLabel(): Int = when (this) {
    PlaceWarning.ALCOHOL -> R.string.cs_know_alcohol
    PlaceWarning.GAMBLING -> R.string.cs_know_gambling
    PlaceWarning.TOBACCO -> R.string.cs_know_tobacco
}

// ------------------------------------------------------------------------------------------------ 1. place warning banner

/**
 * One icon per warning and one short line, in amber. `?` explains, the flag says "Not right? Tell us". The place stays
 * routable; this only tells people before they go. [onExplain] and [onTell] are null in the add-place preview.
 */
@Composable
fun WarningBanner(warnings: List<PlaceWarning>, modifier: Modifier = Modifier, onTell: (() -> Unit)? = null) {
    if (warnings.isEmpty()) return
    val ink = warnInk()
    val line = warnings.map { stringResource(it.line()) }.joinToString(" · ")
    var explain by remember { mutableStateOf(false) }
    val cd = stringResource(R.string.cs_warn_banner_cd, line)
    Row(
        modifier.fillMaxWidth().clip(RoundedCornerShape(Radius.md)).background(warnTile()).padding(start = 12.dp, top = 4.dp, bottom = 4.dp, end = 2.dp)
            .semantics(mergeDescendants = true) { contentDescription = cd },
        verticalAlignment = Alignment.CenterVertically,
    ) {
        warnings.forEach { w ->
            Box(Modifier.padding(end = 8.dp).size(40.dp).clip(RoundedCornerShape(12.dp)).background(warnFill().copy(alpha = 0.6f)), contentAlignment = Alignment.Center) {
                Icon(w.icon(), null, tint = ink, modifier = Modifier.size(26.dp))
            }
        }
        Text(line, Modifier.weight(1f), fontSize = 15.sp, fontWeight = FontWeight.ExtraBold, color = ink, maxLines = 2, overflow = TextOverflow.Ellipsis)
        if (onTell != null) {
            IconButton(onClick = { explain = true }, Modifier.size(48.dp)) { Icon(Icons.Filled.HelpOutline, stringResource(R.string.cs_warn_explain_cd), tint = ink) }
            IconButton(onClick = onTell, Modifier.size(48.dp)) { Icon(Icons.Filled.Flag, stringResource(R.string.cs_warn_tell_cd), tint = ink) }
        }
    }
    if (explain) AlertDialog(
        onDismissRequest = { explain = false },
        icon = { Icon(Icons.Filled.HelpOutline, null, tint = ink) },
        text = { Text(stringResource(R.string.cs_warn_explain), fontSize = 16.sp, fontWeight = FontWeight.SemiBold) },
        confirmButton = { TextButton(onClick = { explain = false }, Modifier.heightIn(min = 48.dp)) { Text(stringResource(R.string.got_it), fontWeight = FontWeight.ExtraBold) } },
        dismissButton = if (onTell != null) ({
            TextButton(onClick = { explain = false; onTell() }, Modifier.heightIn(min = 48.dp)) { Text(stringResource(R.string.cs_warn_tell), fontWeight = FontWeight.ExtraBold) }
        }) else null,
    )
}

// ------------------------------------------------------------------------------------------------ icon tiles

/** A tile with one icon and one word; [crossed] draws a red diagonal over it ("not allowed"). */
@Composable
fun IconTile(icon: ImageVector, label: String, crossed: Boolean, modifier: Modifier = Modifier, cd: String? = null) {
    val c = Gimano.colors
    val ink = if (crossed) c.report else c.textMuted
    Column(modifier.semantics(mergeDescendants = true) { contentDescription = cd ?: label }, horizontalAlignment = Alignment.CenterHorizontally) {
        Box(
            Modifier.size(64.dp).clip(RoundedCornerShape(Radius.tile)).background(if (crossed) c.reportTint.copy(alpha = if (c.isDark) 0.5f else 1f) else c.surfaceAlt),
            contentAlignment = Alignment.Center,
        ) {
            Icon(icon, null, tint = ink, modifier = Modifier.size(32.dp))
            if (crossed) Canvas(Modifier.matchParentSize()) {
                val m = size.minDimension * 0.18f
                drawLine(c.report, Offset(m, size.height - m), Offset(size.width - m, m), strokeWidth = 5.dp.toPx(), cap = StrokeCap.Round)
            }
        }
        Text(label, Modifier.padding(top = 4.dp), fontSize = 12.sp, fontWeight = FontWeight.ExtraBold, color = ink, textAlign = TextAlign.Center, maxLines = 1, overflow = TextOverflow.Ellipsis)
    }
}

/** The write-review screen's three tiles: phone, link, offer. The ones that match the text are crossed out. */
@Composable
fun AdTilesRow(lit: Set<AdTile>, modifier: Modifier = Modifier) {
    Row(modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(14.dp)) {
        AdTile.entries.forEach { t ->
            val label = stringResource(when (t) { AdTile.PHONE -> R.string.cs_tile_phone; AdTile.LINK -> R.string.cs_tile_link; AdTile.OFFER -> R.string.cs_tile_offer })
            IconTile(when (t) { AdTile.PHONE -> Icons.Filled.Phone; AdTile.LINK -> Icons.Filled.Link; AdTile.OFFER -> Icons.Filled.LocalOffer },
                label, crossed = t in lit, cd = if (t in lit) stringResource(R.string.cs_tile_cd, label) else label)
        }
    }
}

fun ContentIssue.icon(): ImageVector = when (this) {
    ContentIssue.PHONE -> Icons.Filled.Phone
    ContentIssue.LINK -> Icons.Filled.Link
    ContentIssue.OFFER -> Icons.Filled.LocalOffer
    ContentIssue.GAMBLING -> Icons.Filled.Casino
    ContentIssue.ALCOHOL -> Icons.Filled.LocalBar
    ContentIssue.TOBACCO -> Icons.Filled.SmokingRooms
    ContentIssue.SCAM -> Icons.Filled.GppBad
    ContentIssue.MONEY -> Icons.Filled.Paid
    ContentIssue.VIOLENCE -> Icons.Filled.Dangerous
    ContentIssue.ADULT -> Icons.Filled.NoAdultContent
    ContentIssue.DRUGS -> Icons.Filled.Medication
    ContentIssue.PERSONAL -> Icons.Filled.Badge
    ContentIssue.HATE -> Icons.Filled.SpeakerNotesOff
    ContentIssue.ILLEGAL -> Icons.Filled.Gavel
    ContentIssue.OTHER -> Icons.Filled.Block
}

fun ContentIssue.label(): Int = when (this) {
    ContentIssue.PHONE -> R.string.cs_issue_phone
    ContentIssue.LINK -> R.string.cs_issue_link
    ContentIssue.OFFER -> R.string.cs_issue_offer
    ContentIssue.GAMBLING -> R.string.cs_issue_gambling
    ContentIssue.ALCOHOL -> R.string.cs_issue_alcohol
    ContentIssue.TOBACCO -> R.string.cs_issue_tobacco
    ContentIssue.SCAM -> R.string.cs_issue_scam
    ContentIssue.MONEY -> R.string.cs_issue_money
    ContentIssue.VIOLENCE -> R.string.cs_issue_violence
    ContentIssue.ADULT -> R.string.cs_issue_adult
    ContentIssue.DRUGS -> R.string.cs_issue_drugs
    ContentIssue.PERSONAL -> R.string.cs_issue_personal
    ContentIssue.HATE -> R.string.cs_issue_hate
    ContentIssue.ILLEGAL -> R.string.cs_issue_illegal
    ContentIssue.OTHER -> R.string.cs_issue_other
}

// ------------------------------------------------------------------------------------------------ 2. "Can't post this"

/**
 * The 422 `content_rejected` sheet: a big shield-x, the offending items crossed out (from the reason codes), the safe part
 * when the server sent one, then "Post this part" and "Edit". Nothing was stored. No appeal here: there is no review to
 * appeal yet (docs/content-safety.md); a review that was stored and rejected later is appealed from the place page / Inbox.
 */
@Composable
fun CantPostSheet(f: ContentFailure.Rejected, onPostPart: () -> Unit, onEdit: () -> Unit, canPostPart: Boolean = true) {
    val c = Gimano.colors
    ModalBottomSheet(
        onDismissRequest = onEdit, sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true), containerColor = c.surface,
        shape = RoundedCornerShape(topStart = Radius.sheet, topEnd = Radius.sheet),
    ) {
        Column(Modifier.fillMaxWidth().verticalScroll(rememberScrollState()).padding(horizontal = 20.dp).padding(bottom = 24.dp), horizontalAlignment = Alignment.CenterHorizontally) {
            Box(Modifier.size(88.dp).clip(RoundedCornerShape(28.dp)).background(c.reportTint.copy(alpha = if (c.isDark) 0.5f else 1f)), contentAlignment = Alignment.Center) {
                Icon(Icons.Filled.GppBad, null, tint = c.report, modifier = Modifier.size(52.dp))
            }
            Text(stringResource(R.string.cs_cant_post), Modifier.padding(top = 12.dp), style = GimanoType.title, color = c.text)
            Row(Modifier.padding(top = 16.dp), horizontalArrangement = Arrangement.spacedBy(14.dp)) {
                f.issues.forEach { i ->
                    val label = stringResource(i.label())
                    IconTile(i.icon(), label, crossed = true, cd = stringResource(R.string.cs_issue_cd, label))
                }
            }
            val part = ContentGate.safePart(f)
            if (part != null) {
                Box(Modifier.padding(top = 16.dp).fillMaxWidth().clip(RoundedCornerShape(Radius.md)).background(c.surfaceAlt).padding(14.dp)) {
                    Text(part, fontSize = 15.sp, fontWeight = FontWeight.SemiBold, color = c.text, maxLines = 6, overflow = TextOverflow.Ellipsis)
                }
                if (canPostPart) Button(
                    onClick = onPostPart, Modifier.padding(top = 12.dp).fillMaxWidth().heightIn(min = 56.dp), shape = RoundedCornerShape(Radius.md),
                    colors = ButtonDefaults.buttonColors(containerColor = c.brand, contentColor = c.brandOn),
                ) {
                    Icon(Icons.Filled.Check, null, Modifier.size(22.dp)); Spacer(Modifier.width(8.dp))
                    Text(stringResource(R.string.cs_post_part), style = GimanoType.button)
                }
            }
            OutlinedButton(onClick = onEdit, Modifier.padding(top = 10.dp).fillMaxWidth().heightIn(min = 56.dp), shape = RoundedCornerShape(Radius.md)) {
                Icon(Icons.Filled.Edit, null, Modifier.size(22.dp)); Spacer(Modifier.width(8.dp))
                Text(stringResource(R.string.cs_edit), style = GimanoType.button)
            }
        }
    }
}

// ------------------------------------------------------------------------------------------------ paused

/** "Paused": 403 `posting_paused` until [until] (3 rejections in 24 h). */
@Composable
fun PausedSheet(until: Instant?, use24h: Boolean, onClose: () -> Unit) {
    val c = Gimano.colors
    ModalBottomSheet(
        onDismissRequest = onClose, sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true), containerColor = c.surface,
        shape = RoundedCornerShape(topStart = Radius.sheet, topEnd = Radius.sheet),
    ) {
        Column(Modifier.fillMaxWidth().padding(horizontal = 20.dp).padding(bottom = 24.dp), horizontalAlignment = Alignment.CenterHorizontally) {
            PausedBody(until, use24h)
            Button(onClick = onClose, Modifier.padding(top = 16.dp).fillMaxWidth().heightIn(min = 56.dp), shape = RoundedCornerShape(Radius.md),
                colors = ButtonDefaults.buttonColors(containerColor = c.brand, contentColor = c.brandOn)) {
                Icon(Icons.Filled.Check, stringResource(R.string.ok))
            }
        }
    }
}

@Composable
private fun PausedBody(until: Instant?, use24h: Boolean) {
    val c = Gimano.colors
    Box(Modifier.size(88.dp).clip(RoundedCornerShape(28.dp)).background(warnTile()), contentAlignment = Alignment.Center) {
        Icon(Icons.Filled.PauseCircle, null, tint = warnInk(), modifier = Modifier.size(52.dp))
    }
    Text(stringResource(R.string.cs_paused_title), Modifier.padding(top = 12.dp), style = GimanoType.title, color = c.text)
    Text(until?.let { stringResource(R.string.cs_paused_until, untilText(it, use24h)) } ?: stringResource(R.string.cs_paused_later),
        Modifier.padding(top = 4.dp), fontSize = 16.sp, fontWeight = FontWeight.Bold, color = c.textMuted)
}

/** The Inbox card for an active pause. */
@Composable
fun PausedCard(until: Instant?, use24h: Boolean, modifier: Modifier = Modifier) {
    val c = Gimano.colors
    Row(modifier.fillMaxWidth().clip(RoundedCornerShape(20.dp)).background(warnTile()).padding(14.dp), verticalAlignment = Alignment.CenterVertically) {
        Box(Modifier.size(48.dp).clip(RoundedCornerShape(16.dp)).background(warnFill().copy(alpha = 0.6f)), contentAlignment = Alignment.Center) {
            Icon(Icons.Filled.PauseCircle, null, tint = warnInk(), modifier = Modifier.size(28.dp))
        }
        Spacer(Modifier.width(12.dp))
        Column {
            Text(stringResource(R.string.cs_paused_title), fontSize = 16.sp, fontWeight = FontWeight.Black, color = warnInk())
            Text(until?.let { stringResource(R.string.cs_paused_until, untilText(it, use24h)) } ?: stringResource(R.string.cs_paused_later),
                fontSize = 14.sp, fontWeight = FontWeight.Bold, color = c.textMuted)
        }
    }
}

// ------------------------------------------------------------------------------------------------ 3. photos

/** The round status badge on a photo: tick (published), clock (processing / checking), cross (rejected). */
@Composable
fun StatusBadge(state: ContentState, modifier: Modifier = Modifier, size: Dp = 28.dp) {
    val c = Gimano.colors
    val (bg, fg, icon, label) = when (state) {
        ContentState.PUBLISHED -> Quad(goodInk(), if (c.isDark) Color(0xFF06241D) else Color.White, Icons.Filled.Check, R.string.cs_photo_published)
        ContentState.PROCESSING -> Quad(warnFill(), warnInk(), Icons.Filled.Schedule, R.string.cs_photo_processing)
        ContentState.REJECTED -> Quad(c.report, c.reportOn, Icons.Filled.Close, R.string.cs_photo_rejected)
    }
    val cd = stringResource(R.string.cs_photo_status_cd, stringResource(label))
    Box(modifier.size(size).clip(CircleShape).background(bg).semantics { contentDescription = cd }, contentAlignment = Alignment.Center) {
        Icon(icon, null, tint = fg, modifier = Modifier.size(size * 0.62f))
    }
}

private data class Quad(val a: Color, val b: Color, val c: ImageVector, val d: Int)

/** The four tiles of the rejected photo screen. */
fun PhotoIssue.icon(): ImageVector = when (this) {
    PhotoIssue.VIOLENCE -> Icons.Filled.Dangerous
    PhotoIssue.ADULT -> Icons.Filled.NoAdultContent
    PhotoIssue.GAMBLING_DRUGS -> Icons.Filled.Casino
    PhotoIssue.PLATES_FACES -> Icons.Filled.Face
}

fun PhotoIssue.label(): Int = when (this) {
    PhotoIssue.VIOLENCE -> R.string.cs_pi_violence
    PhotoIssue.ADULT -> R.string.cs_pi_adult
    PhotoIssue.GAMBLING_DRUGS -> R.string.cs_pi_gambling_drugs
    PhotoIssue.PLATES_FACES -> R.string.cs_pi_plates_faces
}

/**
 * A rejected photo: a hidden-photo tile, the four reasons (the ones that apply are crossed out; with no known reason
 * none are), "Another photo" and "Ask a person" (an appeal, only when the server says it can still be appealed).
 */
@Composable
fun RejectedPhotoScreen(reasons: List<String>, canAppeal: Boolean, onAnother: () -> Unit, onAsk: () -> Unit, onClose: () -> Unit) {
    val c = Gimano.colors
    val lit = ContentGate.photoIssues(reasons)
    Dialog(onDismissRequest = onClose, properties = DialogProperties(usePlatformDefaultWidth = false)) {
        Surface(Modifier.fillMaxSize(), color = c.background) {
            Column(Modifier.fillMaxSize().windowInsetsPadding(WindowInsets.systemBars)) {
                IconButton(onClick = onClose, Modifier.padding(4.dp).size(48.dp)) { Icon(Icons.Filled.Close, stringResource(R.string.cs_photo_close_cd), tint = c.text) }
                Column(Modifier.weight(1f).verticalScroll(rememberScrollState()).padding(horizontal = 20.dp), horizontalAlignment = Alignment.CenterHorizontally) {
                    Box(Modifier.padding(top = 8.dp).size(160.dp).clip(RoundedCornerShape(Radius.reportTile)).background(c.surfaceAlt)
                        .semantics { contentDescription = "" }, contentAlignment = Alignment.Center) {
                        Icon(Icons.Filled.HideImage, null, tint = c.textMuted, modifier = Modifier.size(84.dp))
                    }
                    Text(stringResource(R.string.cs_photo_hidden), Modifier.padding(top = 16.dp), style = GimanoType.title, color = c.text, textAlign = TextAlign.Center)
                    Row(Modifier.padding(top = 20.dp), horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                        PhotoIssue.entries.forEach { i ->
                            val label = stringResource(i.label())
                            IconTile(i.icon(), label, crossed = i in lit, cd = if (i in lit) stringResource(R.string.cs_issue_cd, label) else label)
                        }
                    }
                }
                Column(Modifier.fillMaxWidth().padding(16.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
                    Button(onClick = onAnother, Modifier.fillMaxWidth().heightIn(min = 56.dp), shape = RoundedCornerShape(Radius.md),
                        colors = ButtonDefaults.buttonColors(containerColor = c.brand, contentColor = c.brandOn)) {
                        Icon(Icons.Filled.AddAPhoto, null, Modifier.size(22.dp)); Spacer(Modifier.width(8.dp))
                        Text(stringResource(R.string.cs_photo_another), style = GimanoType.button)
                    }
                    if (canAppeal) OutlinedButton(onClick = onAsk, Modifier.fillMaxWidth().heightIn(min = 56.dp), shape = RoundedCornerShape(Radius.md)) {
                        Icon(Icons.Filled.Person, null, Modifier.size(22.dp)); Spacer(Modifier.width(8.dp))
                        Text(stringResource(R.string.cs_photo_ask), style = GimanoType.button)
                    }
                }
            }
        }
    }
}

// ------------------------------------------------------------------------------------------------ 6. inbox / review status

/** The big status icon of an Inbox content item or an own review: clock (checking), person (a person), cross (no). */
@Composable
fun ContentStatusTile(kind: my.gimano.app.core.safety.InboxContent, modifier: Modifier = Modifier, size: Dp = 56.dp) {
    val c = Gimano.colors
    val (tile, ink, icon, cd) = when (kind) {
        my.gimano.app.core.safety.InboxContent.PUBLISHED -> Quad(goodTile(), goodInk(), Icons.Filled.Check, R.string.cs_inbox_published)
        my.gimano.app.core.safety.InboxContent.HELD -> Quad(warnTile(), warnInk(), Icons.Filled.Person, R.string.cs_inbox_held)
        my.gimano.app.core.safety.InboxContent.REJECTED -> Quad(c.reportTint.copy(alpha = if (c.isDark) 0.5f else 1f), c.report, Icons.Filled.Close, R.string.cs_inbox_rejected)
    }
    val label = stringResource(cd)
    Box(modifier.size(size).clip(RoundedCornerShape(18.dp)).background(tile).semantics { contentDescription = label }, contentAlignment = Alignment.Center) {
        Icon(icon, null, tint = ink, modifier = Modifier.size(size * 0.55f))
    }
}

/** A line under one of my reviews while it waits or was not accepted: icon + one short phrase. */
@Composable
fun ReviewStatusLine(state: my.gimano.app.core.safety.ReviewState, modifier: Modifier = Modifier) {
    val c = Gimano.colors
    val (icon, ink, text) = when (state) {
        my.gimano.app.core.safety.ReviewState.CHECKING -> Triple(Icons.Filled.Schedule, warnInk(), R.string.cs_state_checking)
        my.gimano.app.core.safety.ReviewState.HELD -> Triple(Icons.Filled.Person, warnInk(), R.string.cs_state_held)
        my.gimano.app.core.safety.ReviewState.REJECTED -> Triple(Icons.Filled.Close, c.report, R.string.cs_state_rejected)
        my.gimano.app.core.safety.ReviewState.PASSED -> return
    }
    Row(modifier, verticalAlignment = Alignment.CenterVertically) {
        Icon(icon, null, tint = ink, modifier = Modifier.size(20.dp))
        Spacer(Modifier.width(6.dp))
        Text(stringResource(text), fontSize = 13.sp, fontWeight = FontWeight.ExtraBold, color = ink)
    }
}
