package my.gimano.app.ui.contribute

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.automirrored.filled.Send
import androidx.compose.material.icons.filled.*
import androidx.compose.material3.*
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.res.pluralStringResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import my.gimano.app.R
import my.gimano.app.core.format.Formatters
import my.gimano.app.core.geo.GeoMath
import my.gimano.app.core.geo.GeoPoint
import my.gimano.app.core.places.AddResult
import my.gimano.app.core.places.HoldReason
import my.gimano.app.core.places.PlaceGate
import my.gimano.app.core.places.RejectKind
import my.gimano.app.data.model.Place
import my.gimano.app.data.model.PlaceSummary
import my.gimano.app.ui.common.CategoryGlyph
import my.gimano.app.ui.common.Labels
import my.gimano.app.ui.report.currentLang
import my.gimano.app.ui.theme.Gimano
import my.gimano.app.ui.theme.GimanoType
import my.gimano.app.ui.theme.Radius
import java.time.Instant
import java.time.ZoneId
import java.time.format.DateTimeFormatter

/** The AI-gate screens over the add-a-place form (design "Add a place with an AI gate", boards A1–C1). */
@Composable
fun AddPlaceOverlayScreen(s: AddPlaceState, cvm: ContributeViewModel) {
    when (val o = s.overlay ?: return) {
        AddOverlay.Intro -> IntroScreen(cvm::introSeen)
        AddOverlay.Checking -> CheckingScreen(s.name.trim(), cvm::closeChecking)
        is AddOverlay.Result -> ResultScreen(o.place, o.kind, s, cvm)
        is AddOverlay.Duplicate -> DuplicateScreen(s, o.existing, cvm)
        is AddOverlay.Limit -> LimitScreen(
            title = o.minutes?.let { pluralStringResource(R.plurals.apg_limit_title, it, it) } ?: stringResource(R.string.apg_limit_title_later),
            body = stringResource(R.string.apg_limit_body), s, cvm,
        )
        is AddOverlay.Paused -> LimitScreen(
            title = o.until?.let { stringResource(R.string.apg_paused_title, untilText(it, cvm.use24h)) } ?: stringResource(R.string.apg_paused_title_later),
            body = stringResource(R.string.apg_paused_body), s, cvm,
        )
        AddOverlay.Offline -> SlowScreen(s.name.trim(), offline = true, onOk = cvm::finish)
        is AddOverlay.Appeal -> AppealScreen(o.place, s, cvm)
    }
}

// ------------------------------------------------------------------------------------------------ building blocks

/** Tile colours for the screens' big icon: the app's brand blue, green for "live", amber for "a person", red for "no". */
private enum class Tone { BRAND, GOOD, WAIT, STOP }

@Composable
private fun toneColors(t: Tone): Pair<Color, Color> {
    val c = Gimano.colors
    return when (t) {
        Tone.BRAND -> c.brandMist to c.brand
        Tone.GOOD -> (if (c.isDark) Color(0xFF123B33) else Color(0xFFDDF4F2)) to (if (c.isDark) Color(0xFF7FE0C2) else Color(0xFF0E8A5F))
        Tone.WAIT -> (if (c.isDark) Color(0xFF3A2E12) else Color(0xFFFFF1CC)) to (if (c.isDark) Color(0xFFFFD98A) else Color(0xFF7A5200))
        Tone.STOP -> c.reportTint to c.report
    }
}

/** One full screen: icon tile, title, body, then the actions at the bottom. */
@Composable
private fun GateScreen(
    icon: ImageVector, tone: Tone, title: String,
    kicker: String? = null, onBack: (() -> Unit)? = null,
    actions: @Composable ColumnScope.() -> Unit,
    content: @Composable ColumnScope.() -> Unit,
) {
    val c = Gimano.colors
    val (tile, ink) = toneColors(tone)
    Surface(Modifier.fillMaxSize(), color = c.background) {
        Column(Modifier.fillMaxSize().windowInsetsPadding(WindowInsets.statusBars)) {
            if (onBack != null) IconButton(onClick = onBack, Modifier.padding(4.dp)) { Icon(Icons.AutoMirrored.Filled.ArrowBack, stringResource(R.string.back), tint = c.text) }
            Column(Modifier.weight(1f).verticalScroll(rememberScrollState()).padding(horizontal = 20.dp).padding(top = if (onBack == null) 28.dp else 4.dp)) {
                Box(Modifier.size(72.dp).clip(RoundedCornerShape(Radius.tile)).background(tile), contentAlignment = Alignment.Center) {
                    Icon(icon, null, tint = ink, modifier = Modifier.size(40.dp))
                }
                if (kicker != null) Text(kicker, Modifier.padding(top = 16.dp), fontSize = 12.sp, fontWeight = FontWeight.Black, color = ink, letterSpacing = 0.8.sp)
                Text(title, Modifier.padding(top = if (kicker != null) 4.dp else 16.dp), style = GimanoType.title, color = c.text)
                Spacer(Modifier.height(10.dp))
                content()
                Spacer(Modifier.height(16.dp))
            }
            Surface(color = c.surface, shadowElevation = 8.dp) {
                Column(Modifier.fillMaxWidth().padding(16.dp).windowInsetsPadding(WindowInsets.navigationBars), verticalArrangement = Arrangement.spacedBy(8.dp)) { actions() }
            }
        }
    }
}

@Composable
private fun Body(text: String, modifier: Modifier = Modifier) =
    Text(text, modifier.padding(top = 8.dp), fontSize = 16.sp, fontWeight = FontWeight.SemiBold, color = Gimano.colors.text, lineHeight = 22.sp)

@Composable
private fun Note(text: String, modifier: Modifier = Modifier) =
    Text(text, modifier.padding(top = 12.dp), fontSize = 14.sp, fontWeight = FontWeight.Bold, color = Gimano.colors.textMuted, lineHeight = 19.sp)

@Composable
private fun Chip(text: String, tone: Tone, icon: ImageVector? = null) {
    val (bg, ink) = toneColors(tone)
    Row(Modifier.padding(top = 10.dp).clip(RoundedCornerShape(Radius.pill)).background(bg).padding(horizontal = 12.dp, vertical = 6.dp), verticalAlignment = Alignment.CenterVertically) {
        if (icon != null) { Icon(icon, null, tint = ink, modifier = Modifier.size(16.dp)); Spacer(Modifier.width(6.dp)) }
        Text(text, fontSize = 13.sp, fontWeight = FontWeight.Black, color = ink)
    }
}

/** The place, as the user wrote it: category glyph, name, one line of detail. */
@Composable
private fun PlaceCardLine(name: String, category: String, detail: String?) {
    val c = Gimano.colors
    Row(Modifier.padding(top = 8.dp).fillMaxWidth().clip(RoundedCornerShape(Radius.lg)).background(c.surface).padding(14.dp), verticalAlignment = Alignment.CenterVertically) {
        Box(Modifier.size(48.dp).clip(RoundedCornerShape(16.dp)).background(c.brandMist), contentAlignment = Alignment.Center) { CategoryGlyph(category, 28.dp) }
        Spacer(Modifier.width(12.dp))
        Column(Modifier.weight(1f)) {
            Text(name, fontSize = 17.sp, fontWeight = FontWeight.Black, color = c.text)
            if (!detail.isNullOrBlank()) Text(detail, fontSize = 14.sp, fontWeight = FontWeight.Bold, color = c.textMuted)
        }
    }
}

@Composable
private fun Primary(text: String, icon: ImageVector? = null, enabled: Boolean = true, onClick: () -> Unit) {
    val c = Gimano.colors
    Button(onClick = onClick, enabled = enabled, modifier = Modifier.fillMaxWidth().heightIn(min = 56.dp), shape = RoundedCornerShape(Radius.md),
        colors = ButtonDefaults.buttonColors(containerColor = c.brand, contentColor = c.brandOn)) {
        if (icon != null) { Icon(icon, null); Spacer(Modifier.width(8.dp)) }
        Text(text, style = GimanoType.button)
    }
}

@Composable
private fun Secondary(text: String, icon: ImageVector? = null, onClick: () -> Unit) {
    OutlinedButton(onClick = onClick, modifier = Modifier.fillMaxWidth().heightIn(min = 52.dp), shape = RoundedCornerShape(Radius.md)) {
        if (icon != null) { Icon(icon, null); Spacer(Modifier.width(8.dp)) }
        Text(text, fontWeight = FontWeight.ExtraBold)
    }
}

@Composable
private fun Quiet(text: String, color: Color = Gimano.colors.textMuted, onClick: () -> Unit) {
    TextButton(onClick = onClick, modifier = Modifier.fillMaxWidth().heightIn(min = 48.dp)) { Text(text, fontWeight = FontWeight.ExtraBold, color = color) }
}

@Composable
private fun categoryLine(p: Place, vararg extra: String?): String =
    (listOf(Labels.category(p.category)) + extra.toList()).filterNot { it.isNullOrBlank() }.joinToString(" · ")

/** "9:40 PM, Mon 26 Oct" in Malaysia time (or the phone's zone). */
internal fun untilText(t: Instant, use24h: Boolean): String {
    val z = t.atZone(ZoneId.systemDefault())
    val today = java.time.LocalDate.now(ZoneId.systemDefault())
    val clock = Formatters.clock(z, use24h)
    return if (z.toLocalDate() == today) clock else clock + ", " + z.format(DateTimeFormatter.ofPattern("EEE d MMM", java.util.Locale.getDefault()))
}

// ------------------------------------------------------------------------------------------------ A1

@Composable
private fun IntroScreen(onGotIt: () -> Unit) {
    val c = Gimano.colors
    BackHandler(onBack = onGotIt)
    GateScreen(Icons.Filled.AddLocationAlt, Tone.BRAND, stringResource(R.string.apg_intro_title), kicker = stringResource(R.string.apg_intro_kicker),
        actions = { Primary(stringResource(R.string.got_it), onClick = onGotIt) }) {
        listOf(
            Triple(Icons.Filled.Public, R.string.apg_intro_s1_t, R.string.apg_intro_s1_b) to Tone.BRAND,
            Triple(Icons.Filled.VerifiedUser, R.string.apg_intro_s2_t, R.string.apg_intro_s2_b) to Tone.STOP,
            Triple(Icons.Filled.Groups, R.string.apg_intro_s3_t, R.string.apg_intro_s3_b) to Tone.GOOD,
        ).forEach { (step, tone) ->
            val (bg, ink) = toneColors(tone)
            Row(Modifier.padding(top = 12.dp).fillMaxWidth()) {
                Box(Modifier.size(44.dp).clip(RoundedCornerShape(14.dp)).background(bg), contentAlignment = Alignment.Center) { Icon(step.first, null, tint = ink, modifier = Modifier.size(24.dp)) }
                Spacer(Modifier.width(12.dp))
                Column {
                    Text(stringResource(step.second), fontSize = 17.sp, fontWeight = FontWeight.Black, color = c.text)
                    Text(stringResource(step.third), fontSize = 15.sp, fontWeight = FontWeight.SemiBold, color = c.textMuted, lineHeight = 20.sp)
                }
            }
        }
        Row(Modifier.padding(top = 18.dp).fillMaxWidth().clip(RoundedCornerShape(Radius.md)).background(c.brandMist).padding(12.dp)) {
            Icon(Icons.Filled.Lock, null, tint = c.brand, modifier = Modifier.size(20.dp))
            Spacer(Modifier.width(10.dp))
            Text(stringResource(R.string.apg_intro_rules), fontSize = 14.sp, fontWeight = FontWeight.Bold, color = c.brandInk, lineHeight = 19.sp)
        }
    }
}

// ------------------------------------------------------------------------------------------------ A3

@Composable
private fun CheckingScreen(name: String, onClose: () -> Unit) {
    val c = Gimano.colors
    BackHandler(onBack = onClose)
    GateScreen(Icons.Filled.TravelExplore, Tone.BRAND, name, onBack = onClose,
        actions = {
            Button(onClick = {}, enabled = false, modifier = Modifier.fillMaxWidth().heightIn(min = 56.dp), shape = RoundedCornerShape(Radius.md)) {
                CircularProgressIndicator(Modifier.size(20.dp), strokeWidth = 2.5.dp, color = c.textMuted)
                Spacer(Modifier.width(10.dp))
                Text(stringResource(R.string.apg_checking_button), style = GimanoType.button)
            }
            Quiet(stringResource(R.string.close), onClick = onClose)
        }) {
        Text(stringResource(R.string.apg_checking_title), fontSize = 16.sp, fontWeight = FontWeight.Bold, color = c.textMuted)
        // The restricted-area check already ran on the phone; the rest is the server's, answered in one response.
        CheckRow(R.string.apg_check_location_t, R.string.apg_check_location_s, CheckState.DONE)
        CheckRow(R.string.apg_check_dup_t, R.string.apg_check_dup_s, CheckState.RUNNING)
        CheckRow(R.string.apg_check_content_t, R.string.apg_check_content_s, CheckState.RUNNING)
        CheckRow(R.string.apg_check_live_t, R.string.apg_check_live_s, CheckState.NEXT)
        Note(stringResource(R.string.apg_checking_note))
    }
}

private enum class CheckState { DONE, RUNNING, NEXT }

@Composable
private fun CheckRow(title: Int, sub: Int, state: CheckState) {
    val c = Gimano.colors
    val (goodBg, good) = toneColors(Tone.GOOD)
    Row(Modifier.padding(top = 10.dp).fillMaxWidth().clip(RoundedCornerShape(Radius.md)).background(if (state == CheckState.RUNNING) c.brandMist else c.surface).padding(12.dp),
        verticalAlignment = Alignment.CenterVertically) {
        Box(Modifier.size(32.dp).clip(CircleShape).background(if (state == CheckState.DONE) goodBg else c.surfaceAlt), contentAlignment = Alignment.Center) {
            when (state) {
                CheckState.DONE -> Icon(Icons.Filled.Check, null, tint = good, modifier = Modifier.size(20.dp))
                CheckState.RUNNING -> CircularProgressIndicator(Modifier.size(18.dp), strokeWidth = 2.dp, color = c.brand)
                CheckState.NEXT -> Icon(Icons.Filled.MoreHoriz, null, tint = c.textMuted, modifier = Modifier.size(20.dp))
            }
        }
        Spacer(Modifier.width(12.dp))
        Column {
            Text(stringResource(title), fontSize = 16.sp, fontWeight = FontWeight.Black, color = c.text)
            Text(stringResource(sub), fontSize = 14.sp, fontWeight = FontWeight.SemiBold, color = c.textMuted)
        }
    }
}

// ------------------------------------------------------------------------------------------------ A4 A5 B2 B3 B4 B6

@Composable
private fun ResultScreen(p: Place, kind: AddResult, s: AddPlaceState, cvm: ContributeViewModel) {
    BackHandler(onBack = cvm::finish)
    when (kind) {
        AddResult.LIVE, AddResult.PENDING -> LiveScreen(p, plain = kind == AddResult.PENDING, cvm)
        AddResult.GOLD -> GoldScreen(p, cvm)
        AddResult.HELD -> HeldScreen(p, cvm)
        AddResult.NOT_ACCEPTED -> NotAcceptedScreen(p, cvm)
        AddResult.NOT_ACCEPTED_PERSONAL -> PersonalScreen(p, s, cvm)
        AddResult.CHECKING -> SlowScreen(p.name, offline = false, onOk = cvm::finish)
    }
}

/** A4 "It's on the map" (or the plain path, when the check didn't run). */
@Composable
private fun LiveScreen(p: Place, plain: Boolean, cvm: ContributeViewModel) {
    GateScreen(if (plain) Icons.Filled.HourglassTop else Icons.Filled.WhereToVote, if (plain) Tone.WAIT else Tone.GOOD,
        stringResource(if (plain) R.string.apg_pending_title else R.string.apg_live_title),
        actions = {
            if (!plain) Secondary(stringResource(R.string.apg_share_place), Icons.Filled.Share) { cvm.sharePlace(p) }
            Primary(stringResource(R.string.done), onClick = cvm::finish)
        }) {
        PlaceCardLine(p.name, p.category, categoryLine(p, p.openingHours))
        PlaceGate.progress(p.summary())?.let { (n, of) -> Chip(stringResource(R.string.apg_not_verified_n, n, of), Tone.WAIT, Icons.Filled.Schedule) }
            ?: Chip(stringResource(R.string.apg_not_verified), Tone.WAIT, Icons.Filled.Schedule)
        Body(stringResource(if (plain) R.string.apg_pending_body else R.string.apg_live_body))
        if (!plain) Note(stringResource(R.string.apg_live_note))
    }
}

/** A5 "Live and verified" (an Emas contributor's place). */
@Composable
private fun GoldScreen(p: Place, cvm: ContributeViewModel) {
    GateScreen(Icons.Filled.Verified, Tone.GOOD, stringResource(R.string.apg_gold_title), actions = { Primary(stringResource(R.string.done), onClick = cvm::finish) }) {
        PlaceCardLine(p.name, p.category, categoryLine(p, p.address, p.phone))
        Chip(stringResource(R.string.apg_gold_chip), Tone.WAIT, Icons.Filled.WorkspacePremium)
        Body(stringResource(R.string.apg_gold_body))
        Note(stringResource(R.string.apg_gold_note))
    }
}

/** B2 "A person will check this one". */
@Composable
private fun HeldScreen(p: Place, cvm: ContributeViewModel) {
    val reason = PlaceGate.holdReason(p.screening)
    GateScreen(Icons.Filled.SupervisorAccount, Tone.BRAND, stringResource(R.string.apg_held_title),
        actions = {
            if (reason == HoldReason.SECURITY) Secondary(stringResource(R.string.apg_edit_description), Icons.Filled.Edit, onClick = cvm::editAgain)
            Primary(stringResource(R.string.ok), onClick = cvm::finish)
        }) {
        PlaceCardLine(p.name, p.category, categoryLine(p))
        Chip(stringResource(R.string.apg_held_chip), Tone.BRAND, Icons.Filled.Schedule)
        Body(stringResource(when (reason) {
            HoldReason.APPEALED -> R.string.apg_held_why_appealed
            HoldReason.SECURITY -> R.string.apg_held_why_security
            HoldReason.DUPLICATE -> R.string.apg_held_why_duplicate
            HoldReason.UNSURE -> R.string.apg_held_why_unsure
        }))
        Body(stringResource(R.string.apg_held_only_you))
        if (reason != HoldReason.APPEALED) Note(stringResource(R.string.apg_held_note))
    }
}

/** B3: not accepted (advert, scam, illegal, adult, gibberish, other), in the app's own words. */
@Composable
private fun NotAcceptedScreen(p: Place, cvm: ContributeViewModel) {
    val c = Gimano.colors
    val k = PlaceGate.rejectKind(p.screening?.reasons.orEmpty())
    val (title, body) = rejectCopy(k)
    val canAppeal = p.screening?.canAppeal == true
    GateScreen(Icons.Filled.Block, Tone.STOP, stringResource(title),
        actions = {
            Primary(stringResource(R.string.apg_edit_try_again), Icons.Filled.Edit, onClick = cvm::editAgain)
            if (canAppeal) Secondary(stringResource(R.string.apg_ask_review_wrong), Icons.Filled.SupervisorAccount, onClick = cvm::openAppeal)
            Quiet(stringResource(R.string.apg_discard), c.report) { cvm.discard(p) }
        }) {
        // The user's own words, so they can see what was read; never the check's text.
        Column(Modifier.padding(top = 8.dp).fillMaxWidth().clip(RoundedCornerShape(Radius.lg)).background(c.surface).padding(14.dp)) {
            Text(p.name, fontSize = 17.sp, fontWeight = FontWeight.Black, color = c.text)
            p.description?.takeIf { it.isNotBlank() }?.let { Text("“$it”", fontSize = 14.sp, fontStyle = FontStyle.Italic, fontWeight = FontWeight.SemiBold, color = c.textMuted, maxLines = 3) }
        }
        Body(stringResource(body))
        if (k == RejectKind.ADVERT || k == RejectKind.SCAM || k == RejectKind.OTHER || k == RejectKind.GIBBERISH) Body(stringResource(R.string.apg_rej_hint))
        if (p.screening?.appealed == true && !canAppeal) Note(stringResource(R.string.apg_review_closed))
    }
}

/** B4: someone's home (private_home) or a person (harassment): "Keep it just for me" is the safe answer. */
@Composable
private fun PersonalScreen(p: Place, s: AddPlaceState, cvm: ContributeViewModel) {
    val c = Gimano.colors
    val home = PlaceGate.rejectKind(p.screening?.reasons.orEmpty()) == RejectKind.PRIVATE_HOME
    val canAppeal = p.screening?.canAppeal == true
    GateScreen(if (home) Icons.Filled.Home else Icons.Filled.PersonOff, Tone.STOP, stringResource(if (home) R.string.apg_home_t else R.string.apg_person_t),
        actions = {
            Primary(stringResource(R.string.apg_keep_private), Icons.Filled.Lock, enabled = s.canContinue && !s.saving, onClick = cvm::savePrivate)
            if (canAppeal) Secondary(stringResource(R.string.apg_ask_review_business), Icons.Filled.Storefront, onClick = cvm::openAppeal)
            Quiet(stringResource(R.string.apg_discard), c.report) { cvm.discard(p) }
        }) {
        PlaceCardLine(p.name, p.category, categoryLine(p, p.address))
        Body(stringResource(if (home) R.string.apg_home_b else R.string.apg_person_b))
        if (home) Note(stringResource(R.string.apg_home_hint))
        if (p.screening?.appealed == true && !canAppeal) Note(stringResource(R.string.apg_review_closed))
    }
}

/** B6: the check took longer than 4 s (the worker finishes it), or there was no connection (kept on the phone). */
@Composable
private fun SlowScreen(name: String, offline: Boolean, onOk: () -> Unit) {
    BackHandler(onBack = onOk)
    GateScreen(if (offline) Icons.Filled.CloudOff else Icons.Filled.CloudDone, if (offline) Tone.WAIT else Tone.BRAND,
        stringResource(if (offline) R.string.apg_offline_title else R.string.apg_slow_title),
        actions = { Primary(stringResource(R.string.ok), onClick = onOk) }) {
        Body(if (offline) stringResource(R.string.apg_offline_body) else stringResource(R.string.apg_slow_body, name))
        if (!offline) Note(stringResource(R.string.apg_slow_note))
    }
}

private fun rejectCopy(k: RejectKind): Pair<Int, Int> = when (k) {
    RejectKind.ADVERT -> R.string.apg_rej_advert_t to R.string.apg_rej_advert_b
    RejectKind.SCAM -> R.string.apg_rej_scam_t to R.string.apg_rej_scam_b
    RejectKind.ILLEGAL -> R.string.apg_rej_illegal_t to R.string.apg_rej_illegal_b
    RejectKind.ADULT -> R.string.apg_rej_adult_t to R.string.apg_rej_adult_b
    RejectKind.GIBBERISH -> R.string.apg_rej_gibberish_t to R.string.apg_rej_gibberish_b
    RejectKind.PRIVATE_HOME -> R.string.apg_home_t to R.string.apg_home_b
    RejectKind.HARASSMENT -> R.string.apg_person_t to R.string.apg_person_b
    RejectKind.OTHER -> R.string.apg_rej_other_t to R.string.apg_rej_other_b
}

/** C1's short reason ("Not accepted: looks like someone's home"). */
fun reasonShort(k: RejectKind): Int = when (k) {
    RejectKind.ADVERT -> R.string.apg_reason_advert
    RejectKind.SCAM -> R.string.apg_reason_scam
    RejectKind.ILLEGAL -> R.string.apg_reason_illegal
    RejectKind.ADULT -> R.string.apg_reason_adult
    RejectKind.GIBBERISH -> R.string.apg_reason_gibberish
    RejectKind.PRIVATE_HOME -> R.string.apg_reason_home
    RejectKind.HARASSMENT -> R.string.apg_reason_person
    RejectKind.OTHER -> R.string.apg_reason_other
}

// ------------------------------------------------------------------------------------------------ B1

@Composable
private fun DuplicateScreen(s: AddPlaceState, existing: PlaceSummary?, cvm: ContributeViewModel) {
    val c = Gimano.colors
    BackHandler(onBack = cvm::dismissOverlay)
    val dist = existing?.let { e -> e.distanceM ?: GeoMath.distanceM(s.pin, GeoPoint(e.lat, e.lng)) }?.let { Formatters.distance(it) }
    GateScreen(Icons.Filled.ContentCopy, Tone.WAIT, stringResource(R.string.apg_dup_title), onBack = cvm::dismissOverlay,
        actions = {
            if (existing != null) Primary(stringResource(R.string.apg_dup_same), Icons.Filled.EditNote) { cvm.duplicateIsSame(existing) }
            Secondary(stringResource(R.string.apg_dup_different)) { cvm.duplicateIsDifferent(existing) }
        }) {
        Body(if (dist != null) stringResource(R.string.apg_dup_body, dist, s.name.trim()) else stringResource(R.string.apg_dup_body_near, s.name.trim()))
        if (existing != null) {
            val status = when {
                existing.source != "community" -> null
                existing.status == "published" -> stringResource(R.string.apg_community_verified)
                else -> stringResource(R.string.apg_not_verified)
            }
            PlaceCardLine(existing.name, existing.category, listOf(Labels.category(existing.category), dist, status).filterNot { it.isNullOrBlank() }.joinToString(" · "))
            if (existing.address.isNotBlank()) Text(existing.address, Modifier.padding(top = 6.dp, start = 4.dp), fontSize = 14.sp, fontWeight = FontWeight.Bold, color = c.textMuted)
        }
        Note(stringResource(R.string.apg_dup_note))
    }
}

// ------------------------------------------------------------------------------------------------ B5

@Composable
private fun LimitScreen(title: String, body: String, s: AddPlaceState, cvm: ContributeViewModel) {
    BackHandler(onBack = cvm::dismissOverlay)
    GateScreen(Icons.Filled.Timer, Tone.WAIT, title,
        actions = {
            Primary(stringResource(R.string.apg_save_draft), Icons.Filled.SaveAlt, onClick = cvm::saveLimitedDraft)
            Secondary(stringResource(R.string.apg_private_instead), Icons.Filled.Lock, onClick = cvm::savePrivate)
        }) {
        PlaceCardLine(s.name.trim(), s.category ?: "other", s.address)
        Body(body)
        Body(stringResource(R.string.apg_limit_draft))
    }
}

// ------------------------------------------------------------------------------------------------ C1

@Composable
private fun AppealScreen(p: Place, s: AddPlaceState, cvm: ContributeViewModel) {
    val c = Gimano.colors
    BackHandler(onBack = cvm::closeAppeal)
    val k = PlaceGate.rejectKind(p.screening?.reasons.orEmpty())
    GateScreen(Icons.Filled.SupervisorAccount, Tone.BRAND, stringResource(R.string.apg_appeal_title), onBack = cvm::closeAppeal,
        actions = { Primary(stringResource(R.string.apg_appeal_send), Icons.AutoMirrored.Filled.Send, enabled = !s.appealSending, onClick = cvm::sendAppeal) }) {
        PlaceCardLine(p.name, p.category, stringResource(R.string.apg_not_accepted_reason, stringResource(reasonShort(k))))
        OutlinedTextField(s.appealNote, cvm::appealNote, Modifier.padding(top = 14.dp).fillMaxWidth(), minLines = 4,
            label = { Text(stringResource(R.string.apg_appeal_label)) }, shape = RoundedCornerShape(Radius.md),
            supportingText = { Text(stringResource(R.string.apg_appeal_count, s.appealNote.length, PlaceGate.APPEAL_MAX), Modifier.fillMaxWidth(), textAlign = androidx.compose.ui.text.style.TextAlign.End) })
        Body(stringResource(R.string.apg_appeal_info))
        Row(Modifier.padding(top = 12.dp).fillMaxWidth().clip(RoundedCornerShape(Radius.md)).background(c.brandMist).padding(12.dp)) {
            Icon(Icons.Filled.Lightbulb, null, tint = c.brand, modifier = Modifier.size(20.dp))
            Spacer(Modifier.width(10.dp))
            Text(stringResource(if (k.personal) R.string.apg_appeal_tip_home else R.string.apg_appeal_tip), fontSize = 14.sp, fontWeight = FontWeight.Bold, color = c.brandInk)
        }
        if (s.appealSending) LinearProgressIndicator(Modifier.fillMaxWidth().padding(top = 12.dp), color = c.brand, trackColor = c.surfaceAlt)
    }
}
