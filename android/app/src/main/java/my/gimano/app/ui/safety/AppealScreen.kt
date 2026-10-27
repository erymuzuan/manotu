package my.gimano.app.ui.safety

import androidx.activity.compose.BackHandler
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.PickVisualMediaRequest
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.Send
import androidx.compose.material.icons.filled.*
import androidx.compose.material3.*
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import coil3.compose.AsyncImage
import my.gimano.app.R
import my.gimano.app.core.safety.AppealError
import my.gimano.app.core.safety.AppealRules
import my.gimano.app.core.safety.ContentIssue
import my.gimano.app.core.safety.RefusedKind
import my.gimano.app.ui.contribute.AppealTarget
import my.gimano.app.ui.contribute.AppealUi
import my.gimano.app.ui.contribute.untilText
import my.gimano.app.ui.theme.Gimano
import my.gimano.app.ui.theme.GimanoType
import my.gimano.app.ui.theme.Radius

fun RefusedKind.icon() = when (this) {
    RefusedKind.REVIEW -> Icons.Filled.RateReview
    RefusedKind.PHOTO -> Icons.Filled.Image
    RefusedKind.PLACE -> Icons.Filled.Storefront
}

fun RefusedKind.label() = when (this) {
    RefusedKind.REVIEW -> R.string.na_kind_review
    RefusedKind.PHOTO -> R.string.na_kind_photo
    RefusedKind.PLACE -> R.string.na_kind_place
}

/** The reasons as crossed-out icon tiles (at most four), small or large. */
@Composable
fun ReasonIcons(reasons: List<String>, modifier: Modifier = Modifier) {
    val issues = my.gimano.app.core.safety.ContentGate.issues(reasons)
    Row(modifier, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
        issues.forEach { i: ContentIssue ->
            val label = stringResource(i.label())
            IconTile(i.icon(), label, crossed = true, cd = stringResource(R.string.cs_issue_cd, label))
        }
    }
}

/**
 * "Ask a person": the saved text, a REQUIRED reason (max 200, Send stays off until it has text), up to 3 optional
 * evidence photos from the system photo picker (no permission), then Send. After Send: the "pending" result; the
 * answer arrives in the Inbox. Shown over everything, so it works from the sheet, the list, the Inbox and a photo.
 */
@Composable
fun AppealScreen(
    a: AppealUi, use24h: Boolean, onNote: (String) -> Unit, onPhotos: (List<android.net.Uri>) -> Unit, onDropPhoto: (String) -> Unit,
    onSend: () -> Unit, onClose: () -> Unit,
) {
    val c = Gimano.colors
    BackHandler(onBack = onClose)
    val picker = rememberLauncherForActivityResult(ActivityResultContracts.PickMultipleVisualMedia(AppealRules.MAX_PHOTOS)) { uris -> if (uris.isNotEmpty()) onPhotos(uris) }
    Dialog(onDismissRequest = onClose, properties = DialogProperties(usePlatformDefaultWidth = false, decorFitsSystemWindows = false)) {
        Surface(Modifier.fillMaxSize(), color = c.background) {
            Column(Modifier.fillMaxSize().windowInsetsPadding(WindowInsets.systemBars).imePadding()) {
                Row(Modifier.fillMaxWidth().padding(4.dp), verticalAlignment = Alignment.CenterVertically) {
                    IconButton(onClick = onClose, Modifier.size(48.dp)) { Icon(Icons.Filled.Close, stringResource(R.string.ap_close_cd), tint = c.text) }
                    Text(stringResource(R.string.ap_title), style = GimanoType.title, color = c.text, modifier = Modifier.weight(1f))
                }
                if (a.done) DoneBody(onClose) else FormBody(a, use24h, onNote, onDropPhoto, onSend, pick = {
                    picker.launch(PickVisualMediaRequest(ActivityResultContracts.PickVisualMedia.ImageOnly))
                })
            }
        }
    }
}

@Composable
private fun ColumnScope.DoneBody(onClose: () -> Unit) {
    val c = Gimano.colors
    Column(Modifier.weight(1f).fillMaxWidth().padding(24.dp), horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.Center) {
        Box(Modifier.size(104.dp).clip(RoundedCornerShape(32.dp)).background(warnTile()), contentAlignment = Alignment.Center) {
            Icon(Icons.Filled.HourglassTop, null, tint = warnInk(), modifier = Modifier.size(60.dp))
        }
        Text(stringResource(R.string.ap_pending_title), Modifier.padding(top = 16.dp), style = GimanoType.title, color = c.text)
        Text(stringResource(R.string.ap_pending_body), Modifier.padding(top = 6.dp), fontSize = 16.sp, fontWeight = FontWeight.Bold, color = c.textMuted, textAlign = TextAlign.Center)
    }
    Button(onClick = onClose, Modifier.fillMaxWidth().padding(16.dp).heightIn(min = 56.dp), shape = RoundedCornerShape(Radius.md),
        colors = ButtonDefaults.buttonColors(containerColor = c.brand, contentColor = c.brandOn)) {
        Icon(Icons.Filled.Check, stringResource(R.string.ok), Modifier.size(26.dp))
    }
}

@Composable
private fun ColumnScope.FormBody(a: AppealUi, use24h: Boolean, onNote: (String) -> Unit, onDropPhoto: (String) -> Unit, onSend: () -> Unit, pick: () -> Unit) {
    val c = Gimano.colors
    Column(Modifier.weight(1f).fillMaxWidth().verticalScroll(rememberScrollState()).padding(horizontal = 16.dp)) {
        // What is being appealed: kind icon, place, reason tiles, and the saved text.
        val (kind, place, text, reasons) = when (val t = a.target) {
            is AppealTarget.Refusal -> Quad4(t.item.kind, t.item.placeName, t.item.text, t.item.reasons)
            is AppealTarget.Existing -> Quad4(t.kind, t.placeName, t.text.orEmpty(), t.reasons)
        }
        Row(verticalAlignment = Alignment.CenterVertically) {
            Box(Modifier.size(48.dp).clip(RoundedCornerShape(16.dp)).background(c.reportTint.copy(alpha = if (c.isDark) 0.5f else 1f)), contentAlignment = Alignment.Center) {
                Icon(kind.icon(), stringResource(kind.label()), tint = c.report, modifier = Modifier.size(28.dp))
            }
            Spacer(Modifier.width(12.dp))
            Text(place.orEmpty().ifBlank { stringResource(kind.label()) }, fontSize = 17.sp, fontWeight = FontWeight.Black, color = c.text, maxLines = 2, overflow = TextOverflow.Ellipsis)
        }
        if (reasons.isNotEmpty()) ReasonIcons(reasons, Modifier.padding(top = 12.dp))
        if (text.isNotBlank()) Box(Modifier.padding(top = 12.dp).fillMaxWidth().clip(RoundedCornerShape(Radius.md)).background(c.surfaceAlt).padding(14.dp)) {
            Text(text, fontSize = 15.sp, fontWeight = FontWeight.SemiBold, color = c.text, maxLines = 8, overflow = TextOverflow.Ellipsis)
        }
        // The reason: required.
        val noteMissing = a.error == AppealError.NOTE_REQUIRED
        OutlinedTextField(
            a.note, onNote, Modifier.padding(top = 16.dp).fillMaxWidth(), minLines = 3, maxLines = 5, enabled = !a.sending, isError = noteMissing,
            label = { Text(stringResource(R.string.ap_why_label) + " *") },
            placeholder = { Text(stringResource(R.string.ap_why_hint)) },
            shape = RoundedCornerShape(Radius.md),
            supportingText = {
                Row(Modifier.fillMaxWidth()) {
                    if (a.note.isBlank()) Text(stringResource(R.string.ap_why_required), color = if (noteMissing) c.report else c.textMuted, fontWeight = FontWeight.Bold)
                    Spacer(Modifier.weight(1f))
                    Text(stringResource(R.string.ap_count, a.note.length, AppealRules.NOTE_MAX), textAlign = TextAlign.End)
                }
            },
        )
        // Optional evidence photos: system photo picker, no permission prompt.
        Row(Modifier.padding(top = 12.dp), horizontalArrangement = Arrangement.spacedBy(10.dp), verticalAlignment = Alignment.CenterVertically) {
            a.photos.forEach { p ->
                Box(Modifier.size(84.dp).clip(RoundedCornerShape(Radius.md))) {
                    AsyncImage(p.uri ?: p.file, null, Modifier.matchParentSize(), contentScale = ContentScale.Crop)
                    if (!a.sending) IconButton(onClick = { onDropPhoto(p.key) }, Modifier.align(Alignment.TopEnd).size(36.dp)) {
                        Box(Modifier.size(24.dp).clip(androidx.compose.foundation.shape.CircleShape).background(Color0), contentAlignment = Alignment.Center) {
                            Icon(Icons.Filled.Close, stringResource(R.string.ap_remove_photo_cd), tint = androidx.compose.ui.graphics.Color.White, modifier = Modifier.size(16.dp))
                        }
                    }
                }
            }
            if (a.photos.size < AppealRules.MAX_PHOTOS && !a.sending) {
                val cd = stringResource(R.string.ap_photos_cd)
                Box(Modifier.size(84.dp).clip(RoundedCornerShape(Radius.md)).background(c.brandMist).semantics { contentDescription = cd }
                    .clickable(onClickLabel = cd, onClick = pick), contentAlignment = Alignment.Center) {
                    Icon(Icons.Filled.AddAPhoto, null, tint = c.brand, modifier = Modifier.size(34.dp))
                }
            }
            Text(stringResource(R.string.ap_count, a.photos.size, AppealRules.MAX_PHOTOS), fontSize = 13.sp, fontWeight = FontWeight.ExtraBold, color = c.textMuted)
        }
        a.error?.takeIf { it != AppealError.NOTE_REQUIRED }?.let { ErrorLine(it, a, use24h) }
        Row(Modifier.padding(top = 14.dp, bottom = 12.dp), verticalAlignment = Alignment.CenterVertically) {
            Icon(Icons.Filled.Lock, null, tint = c.textMuted, modifier = Modifier.size(18.dp))
            Spacer(Modifier.width(8.dp))
            Text(stringResource(R.string.ap_privacy), fontSize = 13.sp, fontWeight = FontWeight.Bold, color = c.textMuted)
        }
    }
    Button(onClick = onSend, enabled = a.canSend, modifier = Modifier.fillMaxWidth().padding(16.dp).heightIn(min = 56.dp), shape = RoundedCornerShape(Radius.md),
        colors = ButtonDefaults.buttonColors(containerColor = c.brand, contentColor = c.brandOn)) {
        if (a.sending) CircularProgressIndicator(Modifier.size(24.dp).semantics { contentDescription = "" }, color = c.brandOn, strokeWidth = 3.dp)
        else {
            Icon(Icons.AutoMirrored.Filled.Send, null, Modifier.size(24.dp)); Spacer(Modifier.width(8.dp))
            Text(stringResource(R.string.ap_send), style = GimanoType.button)
        }
    }
}

private val Color0 = androidx.compose.ui.graphics.Color(0x99000000)
private data class Quad4(val kind: RefusedKind, val place: String?, val text: String, val reasons: List<String>)

/** One icon-led line per failure: a big icon, a short phrase. */
@Composable
private fun ErrorLine(e: AppealError, a: AppealUi, use24h: Boolean) {
    val c = Gimano.colors
    val (icon, text) = when (e) {
        AppealError.ALREADY_APPEALED -> Icons.Filled.HourglassTop to stringResource(R.string.ap_err_already)
        AppealError.NOTE_REQUIRED -> Icons.Filled.EditNote to stringResource(R.string.ap_err_note)
        AppealError.PAUSED -> Icons.Filled.PauseCircle to (a.pausedUntil?.let { stringResource(R.string.ap_err_paused, untilText(it, use24h)) } ?: stringResource(R.string.ap_err_paused_later))
        AppealError.BANNED -> Icons.Filled.Block to stringResource(R.string.ap_err_banned)
        AppealError.OFFLINE -> Icons.Filled.WifiOff to stringResource(R.string.ap_err_offline)
        AppealError.TOO_LARGE -> Icons.Filled.BrokenImage to stringResource(R.string.ap_err_large)
        AppealError.OTHER -> Icons.Filled.ErrorOutline to stringResource(R.string.ap_err_other)
    }
    val neutral = e == AppealError.ALREADY_APPEALED || e == AppealError.PAUSED
    Row(Modifier.padding(top = 12.dp).fillMaxWidth().clip(RoundedCornerShape(Radius.md)).background(if (neutral) warnTile() else c.reportTint.copy(alpha = if (c.isDark) 0.5f else 1f)).padding(12.dp),
        verticalAlignment = Alignment.CenterVertically) {
        Icon(icon, null, tint = if (neutral) warnInk() else c.report, modifier = Modifier.size(32.dp))
        Spacer(Modifier.width(12.dp))
        Text(text, fontSize = 15.sp, fontWeight = FontWeight.ExtraBold, color = if (neutral) warnInk() else c.report)
    }
}
