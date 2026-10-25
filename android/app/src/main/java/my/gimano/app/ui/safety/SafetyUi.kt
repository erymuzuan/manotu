package my.gimano.app.ui.safety

import android.content.Intent
import android.net.Uri
import androidx.activity.compose.BackHandler
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.*
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.automirrored.filled.OpenInNew
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.buildAnnotatedString
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.withStyle
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import my.gimano.app.R
import my.gimano.app.core.format.Formatters
import my.gimano.app.core.safety.SafetyAgreement
import my.gimano.app.core.safety.SafetyReminder
import my.gimano.app.ui.AgreementMode
import my.gimano.app.ui.SafetyCard
import my.gimano.app.ui.report.currentLang
import my.gimano.app.ui.theme.Gimano
import my.gimano.app.ui.theme.GimanoType
import my.gimano.app.ui.theme.Radius

private fun open(ctx: android.content.Context, url: String) {
    runCatching { ctx.startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(url))) }
}

/** Coral-tinted round icon tile used at the top of the safety screens and sheets. */
@Composable
private fun SafetyIcon(icon: ImageVector, warn: Boolean = false, size: Int = 56) {
    val c = Gimano.colors
    Box(Modifier.size(size.dp).clip(RoundedCornerShape(Radius.tile)).background(if (warn) c.reportTint else c.brandMist), contentAlignment = Alignment.Center) {
        Icon(icon, null, tint = if (warn) (if (c.isDark) c.report else Color(0xFF8B1A1A)) else c.brand, modifier = Modifier.size((size * 0.56f).dp))
    }
}

/**
 * docs/safety.md §1: the user agreement, full screen. Not dismissed by back or swipe ("Belum setuju" is the way out),
 * except when re-read from Settings.
 */
@Composable
fun SafetyAgreementScreen(mode: AgreementMode, onAgree: () -> Unit, onNotNow: () -> Unit) {
    val c = Gimano.colors
    val ctx = LocalContext.current
    BackHandler { if (mode == AgreementMode.REVIEW) onNotNow() }
    // Inside its own dialog window: dark status-bar icons on the light page (light icons in dark mode).
    val view = androidx.compose.ui.platform.LocalView.current
    val dark = c.isDark
    LaunchedEffect(view, dark) {
        (view.parent as? androidx.compose.ui.window.DialogWindowProvider)?.window?.let { w ->
            androidx.core.view.WindowCompat.getInsetsController(w, view).apply { isAppearanceLightStatusBars = !dark; isAppearanceLightNavigationBars = !dark }
        }
    }
    val items = listOf(
        R.string.safety_agree_1_lead to R.string.safety_agree_1_body,
        R.string.safety_agree_2_lead to R.string.safety_agree_2_body,
        R.string.safety_agree_3_lead to R.string.safety_agree_3_body,
        R.string.safety_agree_4_lead to R.string.safety_agree_4_body,
        R.string.safety_agree_5_lead to R.string.safety_agree_5_body,
    )
    // Swallows taps so nothing behind the screen reacts.
    Column(
        Modifier.fillMaxSize().background(c.background)
            .clickable(interactionSource = remember { MutableInteractionSource() }, indication = null) {}
            .windowInsetsPadding(WindowInsets.statusBars),
    ) {
        Column(Modifier.weight(1f).verticalScroll(rememberScrollState()).padding(horizontal = 20.dp).padding(top = 24.dp, bottom = 12.dp)) {
            SafetyIcon(Icons.Filled.HealthAndSafety)
            Spacer(Modifier.height(16.dp))
            Text(stringResource(R.string.safety_agree_title), style = GimanoType.title, fontSize = 28.sp, fontWeight = FontWeight.Black, color = c.text,
                modifier = Modifier.semantics { heading() })
            Text(stringResource(R.string.safety_agree_lead), fontSize = 16.sp, fontWeight = FontWeight.SemiBold, color = c.textMuted, modifier = Modifier.padding(top = 6.dp))
            Column(
                Modifier.padding(top = 18.dp).fillMaxWidth().clip(RoundedCornerShape(Radius.lg)).background(c.surface).padding(vertical = 6.dp),
            ) {
                items.forEachIndexed { i, (lead, body) ->
                    Row(Modifier.fillMaxWidth().padding(horizontal = 14.dp, vertical = 10.dp)) {
                        Box(Modifier.size(30.dp).clip(CircleShape).background(c.brandMist), contentAlignment = Alignment.Center) {
                            Text("${i + 1}", fontSize = 15.sp, fontWeight = FontWeight.Black, color = c.brandInk)
                        }
                        Spacer(Modifier.width(12.dp))
                        Text(
                            buildAnnotatedString {
                                withStyle(SpanStyle(fontWeight = FontWeight.Black, color = c.text)) { append(stringResource(lead)) }
                                append(" ")
                                append(stringResource(body))
                            },
                            fontSize = 15.sp, fontWeight = FontWeight.SemiBold, color = c.textMuted, lineHeight = 21.sp,
                        )
                    }
                    if (i < items.lastIndex) my.gimano.app.ui.common.Divider(Modifier.padding(start = 56.dp, end = 14.dp))
                }
            }
            Row(Modifier.padding(top = 8.dp), verticalAlignment = Alignment.CenterVertically) {
                TextButton(onClick = { open(ctx, SafetyAgreement.TERMS_URL) }) { Text(stringResource(R.string.safety_full_terms), fontWeight = FontWeight.ExtraBold) }
                Text("·", color = c.textMuted)
                TextButton(onClick = { open(ctx, SafetyAgreement.PRIVACY_URL) }) { Text(stringResource(R.string.safety_privacy), fontWeight = FontWeight.ExtraBold) }
            }
        }
        Surface(color = c.surface, shadowElevation = 8.dp) {
            Column(Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 12.dp).windowInsetsPadding(WindowInsets.navigationBars),
                horizontalAlignment = Alignment.CenterHorizontally) {
                Button(onClick = onAgree, Modifier.fillMaxWidth().heightIn(min = 56.dp), shape = RoundedCornerShape(Radius.md),
                    colors = ButtonDefaults.buttonColors(containerColor = c.brand, contentColor = c.brandOn)) {
                    Text(stringResource(R.string.safety_agree), style = GimanoType.button, textAlign = TextAlign.Center)
                }
                TextButton(onClick = onNotNow, Modifier.fillMaxWidth().heightIn(min = 48.dp)) {
                    Text(stringResource(R.string.safety_not_now), style = GimanoType.button, color = c.brandInk)
                }
                Text(stringResource(R.string.safety_agree_footer, SafetyAgreement.VERSION), fontSize = 12.sp, fontWeight = FontWeight.Bold, color = c.textMuted,
                    modifier = Modifier.padding(top = 2.dp))
            }
        }
    }
}

/** "Belum setuju" + Mula: "Setuju dahulu untuk mula memandu". */
@Composable
fun NeedAgreementSheet(onRead: () -> Unit, onLater: () -> Unit) {
    val c = Gimano.colors
    ModalBottomSheet(onDismissRequest = onLater, containerColor = c.surface, shape = RoundedCornerShape(topStart = Radius.sheet, topEnd = Radius.sheet)) {
        Column(Modifier.fillMaxWidth().padding(horizontal = 20.dp).padding(bottom = 24.dp)) {
            SafetyIcon(Icons.Filled.HealthAndSafety, size = 48)
            Text(stringResource(R.string.safety_need_title), style = GimanoType.title, color = c.text, modifier = Modifier.padding(top = 12.dp))
            Text(stringResource(R.string.safety_need_body), fontSize = 15.sp, fontWeight = FontWeight.SemiBold, color = c.textMuted, modifier = Modifier.padding(top = 6.dp))
            Button(onClick = onRead, Modifier.fillMaxWidth().padding(top = 18.dp).heightIn(min = 56.dp), shape = RoundedCornerShape(Radius.md),
                colors = ButtonDefaults.buttonColors(containerColor = c.brand, contentColor = c.brandOn)) {
                Text(stringResource(R.string.safety_need_read), style = GimanoType.button)
            }
            TextButton(onClick = onLater, Modifier.fillMaxWidth().heightIn(min = 48.dp)) {
                Text(stringResource(R.string.safety_need_later), style = GimanoType.button, color = c.brandInk)
            }
        }
    }
}

/**
 * docs/safety.md §2: "Pandu dengan selamat" over the map (the route stays drawn behind it). Guidance starts only after
 * the big button. No voice: the voice is for directions only.
 */
@Composable
fun SafetyReminderCard(card: SafetyCard, onGo: (dontShowAgain: Boolean) -> Unit, onDismiss: () -> Unit) {
    val c = Gimano.colors
    val lang = currentLang()
    var dontShow by remember { mutableStateOf(false) }
    BackHandler(onBack = onDismiss)
    val long = SafetyReminder.isLongDrive(card.durationS)
    Box(
        Modifier.fillMaxSize().background(Color(0x66091A3A))
            .clickable(interactionSource = remember { MutableInteractionSource() }, indication = null) {},
        contentAlignment = Alignment.BottomCenter,
    ) {
        Surface(
            Modifier.fillMaxWidth().padding(10.dp).windowInsetsPadding(WindowInsets.navigationBars),
            shape = RoundedCornerShape(Radius.sheet), color = c.surface, shadowElevation = 14.dp,
        ) {
            Column(Modifier.verticalScroll(rememberScrollState()).padding(18.dp)) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    SafetyIcon(Icons.Filled.HealthAndSafety, size = 52)
                    Spacer(Modifier.width(12.dp))
                    Column(Modifier.weight(1f)) {
                        Text(stringResource(R.string.safety_card_title), style = GimanoType.title, fontWeight = FontWeight.Black, color = c.text,
                            modifier = Modifier.semantics { heading() })
                        if (card.destination != null) {
                            val dur = card.durationS?.let { Formatters.duration(it, lang) }
                            Text(if (dur != null) stringResource(R.string.safety_card_sub, card.destination, dur) else card.destination,
                                fontSize = 14.sp, fontWeight = FontWeight.Bold, color = c.textMuted, maxLines = 2)
                        }
                    }
                }
                Spacer(Modifier.height(10.dp))
                CardLine(Icons.Filled.Gavel, stringResource(R.string.safety_card_1))
                CardLine(Icons.Filled.NoDrinks, stringResource(R.string.safety_card_2))
                CardLine(Icons.Filled.PhonelinkErase, stringResource(R.string.safety_card_3))
                CardLine(Icons.Filled.AltRoute, stringResource(R.string.safety_card_4))
                CardLine(Icons.Filled.Bedtime, stringResource(if (long) R.string.safety_card_rest_long else R.string.safety_card_rest), highlight = long)
                Row(
                    Modifier.fillMaxWidth().padding(top = 6.dp).clip(RoundedCornerShape(Radius.md))
                        .clickable(role = Role.Checkbox) { dontShow = !dontShow }.padding(vertical = 4.dp),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Checkbox(dontShow, { dontShow = it }, colors = CheckboxDefaults.colors(checkedColor = c.brand))
                    Text(stringResource(R.string.safety_card_dont_show), fontSize = 15.sp, fontWeight = FontWeight.Bold, color = c.text)
                }
                Button(
                    onClick = { onGo(dontShow) }, Modifier.fillMaxWidth().padding(top = 8.dp).heightIn(min = 64.dp),
                    shape = RoundedCornerShape(Radius.lg), colors = ButtonDefaults.buttonColors(containerColor = c.brand, contentColor = c.brandOn),
                ) { Text(stringResource(R.string.safety_card_go), style = GimanoType.button, fontSize = 19.sp, fontWeight = FontWeight.Black) }
            }
        }
    }
}

@Composable
private fun CardLine(icon: ImageVector, text: String, highlight: Boolean = false) {
    val c = Gimano.colors
    Row(
        Modifier.fillMaxWidth().padding(vertical = 3.dp).clip(RoundedCornerShape(Radius.md))
            .background(if (highlight) c.reportTint.copy(alpha = if (c.isDark) 0.6f else 0.55f) else Color.Transparent)
            .padding(horizontal = if (highlight) 10.dp else 0.dp, vertical = if (highlight) 8.dp else 5.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Box(Modifier.size(36.dp).clip(RoundedCornerShape(12.dp)).background(if (highlight) c.surface else c.brandMist), contentAlignment = Alignment.Center) {
            Icon(icon, null, tint = if (highlight) c.report else c.brand, modifier = Modifier.size(22.dp))
        }
        Spacer(Modifier.width(12.dp))
        Text(text, fontSize = 16.sp, fontWeight = if (highlight) FontWeight.Black else FontWeight.Bold, color = c.text, lineHeight = 21.sp)
    }
}

/** Started while moving (≥ 10 km/h): one line for 5 s, nothing to tap. */
@Composable
fun SafetyBanner(modifier: Modifier = Modifier) {
    val c = Gimano.colors
    Row(
        modifier.clip(RoundedCornerShape(Radius.pill)).background(c.navBanner).padding(horizontal = 16.dp, vertical = 10.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Icon(Icons.Filled.HealthAndSafety, null, tint = c.navBannerOn, modifier = Modifier.size(20.dp))
        Spacer(Modifier.width(8.dp))
        Text(stringResource(R.string.safety_banner), color = c.navBannerOn, fontSize = 15.sp, fontWeight = FontWeight.ExtraBold, maxLines = 1)
    }
}

/** docs/safety.md §4 D: tap inside a restricted area on the map. */
@Composable
fun RestrictedAreaSheet(onClose: () -> Unit) {
    val c = Gimano.colors
    ModalBottomSheet(onDismissRequest = onClose, containerColor = c.surface, shape = RoundedCornerShape(topStart = Radius.sheet, topEnd = Radius.sheet)) {
        Column(Modifier.fillMaxWidth().padding(horizontal = 20.dp).padding(bottom = 24.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                SafetyIcon(Icons.Filled.GppMaybe, warn = true, size = 48)
                Spacer(Modifier.width(12.dp))
                Text(stringResource(R.string.restricted_area), style = GimanoType.title, color = c.text)
            }
            Spacer(Modifier.height(12.dp))
            InfoLine(Icons.Filled.Block, stringResource(R.string.restricted_d_1))
            InfoLine(Icons.Filled.NoPhotography, stringResource(R.string.restricted_d_2))
            InfoLine(Icons.Filled.AltRoute, stringResource(R.string.restricted_d_3))
            OutlinedButton(onClick = onClose, Modifier.fillMaxWidth().padding(top = 14.dp).heightIn(min = 52.dp), shape = RoundedCornerShape(Radius.md)) {
                Text(stringResource(R.string.close), fontWeight = FontWeight.ExtraBold)
            }
        }
    }
}

@Composable
private fun InfoLine(icon: ImageVector, text: String) {
    val c = Gimano.colors
    Row(Modifier.fillMaxWidth().padding(vertical = 6.dp), verticalAlignment = Alignment.CenterVertically) {
        Icon(icon, null, tint = c.textMuted, modifier = Modifier.size(22.dp))
        Spacer(Modifier.width(12.dp))
        Text(text, fontSize = 15.sp, fontWeight = FontWeight.Bold, color = c.text)
    }
}

/** docs/safety.md §4 A: a public pin inside a restricted area (or within blockM): a sheet instead of the form. */
@Composable
fun BlockedPinSheet(onMove: () -> Unit, onPrivate: () -> Unit, onCancel: () -> Unit) {
    val c = Gimano.colors
    ModalBottomSheet(onDismissRequest = onMove, sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true), containerColor = c.surface,
        shape = RoundedCornerShape(topStart = Radius.sheet, topEnd = Radius.sheet)) {
        Column(Modifier.fillMaxWidth().verticalScroll(rememberScrollState()).padding(horizontal = 20.dp).padding(bottom = 24.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                SafetyIcon(Icons.Filled.GppBad, warn = true, size = 52)
                Spacer(Modifier.width(12.dp))
                Column {
                    Text(stringResource(R.string.restricted_a_title), style = GimanoType.title, color = c.text)
                    Text(stringResource(R.string.restricted_a_sub), fontSize = 14.sp, fontWeight = FontWeight.Bold, color = c.textMuted)
                }
            }
            Text(stringResource(R.string.restricted_a_body), fontSize = 15.sp, fontWeight = FontWeight.SemiBold, color = c.text, modifier = Modifier.padding(top = 14.dp))
            Row(Modifier.padding(top = 12.dp).fillMaxWidth().clip(RoundedCornerShape(Radius.md)).background(c.brandMist).padding(12.dp)) {
                Icon(Icons.Filled.Storefront, null, tint = c.brand, modifier = Modifier.size(22.dp))
                Spacer(Modifier.width(10.dp))
                Text(stringResource(R.string.restricted_a_hint), fontSize = 14.sp, fontWeight = FontWeight.Bold, color = c.brandInk)
            }
            Button(onClick = onMove, Modifier.fillMaxWidth().padding(top = 18.dp).heightIn(min = 56.dp), shape = RoundedCornerShape(Radius.md),
                colors = ButtonDefaults.buttonColors(containerColor = c.brand, contentColor = c.brandOn)) {
                Icon(Icons.Filled.OpenWith, null); Spacer(Modifier.width(8.dp)); Text(stringResource(R.string.restricted_a_move), style = GimanoType.button)
            }
            OutlinedButton(onClick = onPrivate, Modifier.fillMaxWidth().padding(top = 8.dp).heightIn(min = 52.dp), shape = RoundedCornerShape(Radius.md)) {
                Icon(Icons.Filled.Lock, null); Spacer(Modifier.width(8.dp)); Text(stringResource(R.string.restricted_a_private), fontWeight = FontWeight.ExtraBold)
            }
            TextButton(onClick = onCancel, Modifier.fillMaxWidth().heightIn(min = 48.dp)) {
                Text(stringResource(R.string.cancel), fontWeight = FontWeight.ExtraBold, color = c.textMuted)
            }
        }
    }
}

/** docs/safety.md §4 B: at the top of a public form near (≤ reviewM) a restricted area. */
@Composable
fun NearRestrictedNote(modifier: Modifier = Modifier) = WarningBox(
    Icons.Filled.GppMaybe, stringResource(R.string.restricted_b_title), stringResource(R.string.restricted_b_body), modifier,
)

/** docs/safety.md §4 C: under a field that contains a security term. */
@Composable
fun SensitiveWordsWarning(onRemove: () -> Unit, modifier: Modifier = Modifier) = WarningBox(
    Icons.Filled.VisibilityOff, stringResource(R.string.restricted_c_title), stringResource(R.string.restricted_c_body), modifier,
    action = stringResource(R.string.restricted_c_remove) to onRemove,
)

@Composable
private fun WarningBox(icon: ImageVector, title: String, body: String, modifier: Modifier, action: Pair<String, () -> Unit>? = null) {
    val c = Gimano.colors
    val ink = if (c.isDark) Color(0xFFFFD98A) else Color(0xFF7A5200)
    val bg = if (c.isDark) Color(0xFF3A2E12) else Color(0xFFFFF1CC)
    Column(modifier.fillMaxWidth().clip(RoundedCornerShape(Radius.md)).background(bg).border(1.dp, ink.copy(alpha = 0.25f), RoundedCornerShape(Radius.md)).padding(12.dp)) {
        Row(verticalAlignment = Alignment.Top) {
            Icon(icon, null, tint = ink, modifier = Modifier.size(22.dp))
            Spacer(Modifier.width(10.dp))
            Column(Modifier.weight(1f)) {
                Text(title, fontSize = 15.sp, fontWeight = FontWeight.Black, color = ink)
                Text(body, fontSize = 14.sp, fontWeight = FontWeight.SemiBold, color = c.text, modifier = Modifier.padding(top = 2.dp))
            }
        }
        if (action != null) TextButton(onClick = action.second, Modifier.align(Alignment.End)) {
            Text(action.first, fontWeight = FontWeight.Black, color = ink)
        }
    }
}

/** Settings › Keselamatan (docs/safety.md §3). */
@Composable
fun SafetySettingsScreen(
    s: my.gimano.app.data.settings.AppSettings,
    onBack: () -> Unit,
    onReminder: (Boolean) -> Unit,
    onPreview: () -> Unit,
    onReadAgain: () -> Unit,
    onDebugReset: (() -> Unit)? = null,
) {
    val c = Gimano.colors
    val ctx = LocalContext.current
    val lang = currentLang()
    fun day(iso: String?): String? = Formatters.parseInstant(iso)?.let { Formatters.shortDate(it.atZone(java.time.ZoneId.systemDefault()).toLocalDate(), lang) }
    Column(Modifier.fillMaxSize().background(c.background).windowInsetsPadding(WindowInsets.statusBars)) {
        Row(Modifier.fillMaxWidth().padding(4.dp), verticalAlignment = Alignment.CenterVertically) {
            IconButton(onClick = onBack) { Icon(Icons.AutoMirrored.Filled.ArrowBack, stringResource(R.string.back), tint = c.text) }
            Text(stringResource(R.string.safety_settings), style = GimanoType.title, color = c.text)
        }
        Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(horizontal = 16.dp).windowInsetsPadding(WindowInsets.navigationBars),
            verticalArrangement = Arrangement.spacedBy(12.dp)) {
            Group {
                Row(Modifier.fillMaxWidth().clickable(role = Role.Switch) { onReminder(!s.safetyReminderEnabled) }.padding(16.dp), verticalAlignment = Alignment.CenterVertically) {
                    SafetyIcon(Icons.Filled.HealthAndSafety, size = 44)
                    Spacer(Modifier.width(12.dp))
                    Column(Modifier.weight(1f)) {
                        Text(stringResource(R.string.safety_switch), fontSize = 16.sp, fontWeight = FontWeight.ExtraBold, color = c.text)
                        if (!s.safetyReminderEnabled) day(s.safetyReminderDisabledAt)?.let {
                            Text(stringResource(R.string.safety_switch_off, it), fontSize = 13.sp, fontWeight = FontWeight.Bold, color = c.report)
                        }
                    }
                    Switch(s.safetyReminderEnabled, onReminder, colors = SwitchDefaults.colors(checkedTrackColor = c.brand))
                }
                my.gimano.app.ui.common.Divider()
                Row(Modifier.fillMaxWidth().clickable(onClick = onPreview).padding(16.dp), verticalAlignment = Alignment.CenterVertically) {
                    Column(Modifier.weight(1f)) {
                        Text(stringResource(R.string.safety_show_now), fontSize = 16.sp, fontWeight = FontWeight.ExtraBold, color = c.text)
                        Text(stringResource(R.string.safety_show_now_desc), fontSize = 13.sp, fontWeight = FontWeight.Bold, color = c.textMuted)
                    }
                    Text("›", fontSize = 22.sp, color = c.textMuted)
                }
            }
            Group {
                Row(Modifier.fillMaxWidth().padding(16.dp), verticalAlignment = Alignment.CenterVertically) {
                    Column(Modifier.weight(1f)) {
                        Text(stringResource(R.string.safety_agreement_row), fontSize = 16.sp, fontWeight = FontWeight.ExtraBold, color = c.text)
                        val agreed = !SafetyAgreement.needsAgreement(s.safetyAgreedVersion)
                        Text(
                            if (agreed) stringResource(R.string.safety_agreed_on, day(s.safetyAgreedAt) ?: "—", s.safetyAgreedVersion)
                            else stringResource(R.string.safety_not_agreed, SafetyAgreement.VERSION),
                            fontSize = 13.sp, fontWeight = FontWeight.Bold, color = c.textMuted,
                        )
                    }
                    OutlinedButton(onClick = onReadAgain, shape = RoundedCornerShape(Radius.pill)) {
                        Text(stringResource(R.string.safety_read_again), fontWeight = FontWeight.ExtraBold)
                    }
                }
                my.gimano.app.ui.common.Divider()
                Row(Modifier.fillMaxWidth().clickable { open(ctx, SafetyAgreement.TERMS_URL) }.padding(16.dp), verticalAlignment = Alignment.CenterVertically) {
                    Text(stringResource(R.string.safety_terms_link), Modifier.weight(1f), fontSize = 16.sp, fontWeight = FontWeight.ExtraBold, color = c.brand)
                    Icon(Icons.AutoMirrored.Filled.OpenInNew, null, tint = c.brand, modifier = Modifier.size(20.dp))
                }
            }
            Row(Modifier.fillMaxWidth().clip(RoundedCornerShape(Radius.lg)).background(c.brandMist).padding(14.dp)) {
                Icon(Icons.Filled.Lock, null, tint = c.brand, modifier = Modifier.size(20.dp))
                Spacer(Modifier.width(10.dp))
                Text(stringResource(R.string.safety_info), fontSize = 14.sp, fontWeight = FontWeight.Bold, color = c.brandInk)
            }
            if (onDebugReset != null) TextButton(onClick = onDebugReset) { Text(stringResource(R.string.safety_debug_reset), color = c.report) }
            Spacer(Modifier.height(24.dp))
        }
    }
}

@Composable
private fun Group(content: @Composable ColumnScope.() -> Unit) {
    Column(Modifier.fillMaxWidth().clip(RoundedCornerShape(Radius.lg)).background(Gimano.colors.surface), content = content)
}
