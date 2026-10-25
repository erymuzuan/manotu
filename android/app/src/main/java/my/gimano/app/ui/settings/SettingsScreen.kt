package my.gimano.app.ui.settings

import kotlinx.coroutines.launch
import androidx.lifecycle.compose.collectAsStateWithLifecycle

import androidx.appcompat.app.AppCompatDelegate
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.core.os.LocaleListCompat
import my.gimano.app.BuildConfig
import my.gimano.app.R
import my.gimano.app.data.settings.AppSettings
import my.gimano.app.data.settings.SoundMode
import my.gimano.app.ui.MainViewModel
import my.gimano.app.ui.theme.Gimano
import my.gimano.app.ui.theme.Radius

@Composable
fun SettingsScreen(s: AppSettings, vm: MainViewModel, fallback: Boolean, displayName: String?, onBackup: () -> Unit, onMyFeedback: () -> Unit, onTheme: () -> Unit = {}, onAccount: () -> Unit = {}, onAbout: () -> Unit = {}, onSafety: () -> Unit = {}) {
    val c = Gimano.colors
    Column(Modifier.fillMaxSize().background(c.surface).windowInsetsPadding(WindowInsets.statusBars)) {
        Row(Modifier.fillMaxWidth().padding(4.dp), verticalAlignment = Alignment.CenterVertically) {
            IconButton(onClick = vm::back) { Icon(Icons.AutoMirrored.Filled.ArrowBack, stringResource(R.string.back), tint = c.text) }
            Text(stringResource(R.string.settings), fontSize = 22.sp, fontWeight = FontWeight.SemiBold, color = c.text)
        }
        Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(horizontal = 16.dp).windowInsetsPadding(WindowInsets.navigationBars).imePadding()) {
            if (fallback && !s.demoMode) {
                Card(colors = CardDefaults.cardColors(containerColor = c.report.copy(alpha = 0.12f)), modifier = Modifier.fillMaxWidth().padding(vertical = 8.dp)) {
                    Column(Modifier.padding(14.dp)) {
                        Text(stringResource(R.string.server_unreachable), color = c.text)
                        vm.fallbackReason()?.let { Text(stringResource(R.string.fallback_reason, it), color = c.textMuted, fontSize = 13.sp) }
                        TextButton(onClick = vm::retryServer) { Text(stringResource(R.string.retry)) }
                    }
                }
            }
            my.gimano.app.ui.common.PrivacyCard(onBackup = onBackup, modifier = Modifier.padding(vertical = 8.dp))
            // Demo mode, near the top for everyone (try Manotu anywhere, no account, nothing sent to the server).
            SwitchRow(stringResource(R.string.demo_mode), stringResource(R.string.demo_mode_desc), s.demoMode, vm::setDemoMode)
            NavRow(stringResource(R.string.account), onAccount)
            NavRow(stringResource(R.string.backup_restore), onBackup)
            NavRow(stringResource(R.string.my_feedback), onMyFeedback)
            NavRow(stringResource(R.string.theme), onTheme)
            NavRow(stringResource(R.string.safety_settings), onSafety)
            TextSetting(stringResource(R.string.display_name), displayName ?: s.displayName ?: "", onApply = vm::setDisplayName)

            // Privacy: blocked users (kept on this phone only; included in your own backup).
            Section(stringResource(R.string.privacy))
            val blocked by vm.container.blocks.blocked.collectAsStateWithLifecycle()
            val scope = rememberCoroutineScope()
            Text(stringResource(R.string.blocked_users), fontSize = 16.sp, fontWeight = FontWeight.ExtraBold, color = c.text)
            Text(stringResource(R.string.blocked_users_desc), fontSize = 13.sp, color = c.textMuted)
            if (blocked.isEmpty()) Text(stringResource(R.string.blocked_none), Modifier.padding(vertical = 8.dp), fontSize = 14.sp, color = c.textMuted)
            blocked.forEach { b ->
                Row(Modifier.fillMaxWidth().padding(vertical = 4.dp), verticalAlignment = Alignment.CenterVertically) {
                    Text(b.name.ifBlank { "—" }, Modifier.weight(1f), fontSize = 15.sp, fontWeight = FontWeight.Bold, color = c.text)
                    TextButton(onClick = { scope.launch { vm.container.blocks.unblock(b.ref) } }) {
                        Text(stringResource(R.string.unblock), fontWeight = FontWeight.ExtraBold)
                    }
                }
            }

            Section(stringResource(R.string.language))
            val appLocales = AppCompatDelegate.getApplicationLocales()
            val current = if (appLocales.isEmpty) "" else appLocales[0]?.language ?: ""
            Choice(listOf("" to stringResource(R.string.lang_system), "en" to stringResource(R.string.english), "ms" to stringResource(R.string.malay)), current) {
                AppCompatDelegate.setApplicationLocales(if (it.isEmpty()) LocaleListCompat.getEmptyLocaleList() else LocaleListCompat.forLanguageTags(it))
            }

            Section(stringResource(R.string.voice_language))
            Choice(listOf("auto" to stringResource(R.string.voice_auto), "en" to stringResource(R.string.english), "ms" to stringResource(R.string.malay)), s.voiceLang) { vm.setVoiceLang(it) }

            Section(stringResource(R.string.sound))
            Choice(
                listOf(SoundMode.ON.name to stringResource(R.string.sound_on), SoundMode.ALERTS_ONLY.name to stringResource(R.string.sound_alerts), SoundMode.OFF.name to stringResource(R.string.sound_off)),
                s.soundMode.name,
            ) { vm.setSoundMode(SoundMode.valueOf(it)) }

            Section(stringResource(R.string.vehicle))
            Choice(listOf("car" to stringResource(R.string.car), "motorcycle" to stringResource(R.string.motorbike), "bicycle" to stringResource(R.string.bicycle), "walk" to stringResource(R.string.walk)), s.vehicle) { vm.setVehicleHome(it) }

            Spacer(Modifier.height(8.dp))
            SwitchRow(stringResource(R.string.clock_24h), null, s.use24h, vm::setUse24h)
            SwitchRow(stringResource(R.string.auto_start_nav), stringResource(R.string.auto_start_nav_desc), s.autoStartNav, vm::setAutoStartNav)
            // Developer settings: debug builds only.
            if (BuildConfig.DEBUG) {
                SwitchRow(stringResource(R.string.simulate_drive), stringResource(R.string.simulate_drive_desc), s.simulateDrive, vm::setSimulate)
                SwitchRow(stringResource(R.string.simulate_detour), stringResource(R.string.simulate_detour_desc), s.simulateDetour, vm::setSimulateDetour)
                Section(stringResource(R.string.server_url))
                TextSetting(null, s.apiBaseUrl, onApply = vm::setApiBaseUrl)
                Section(stringResource(R.string.map_style))
                TextSetting(null, s.mapStyleUrl, onApply = vm::setMapStyleUrl)
            }

            Section(stringResource(R.string.about))
            Text(stringResource(R.string.about_text), color = c.textMuted, fontSize = 14.sp)
            Section(stringResource(R.string.crash_reports))
            var crashMode by remember { mutableStateOf(vm.container.crashes.mode) }
            my.gimano.app.ui.feedback.CrashModeChoice(crashMode) { crashMode = it; vm.container.crashes.mode = it }
            Spacer(Modifier.height(8.dp))
            NavRow(stringResource(R.string.about_gimano), onAbout)
            Text("v${BuildConfig.VERSION_NAME} (${if (BuildConfig.DEBUG) "debug" else "release"})", color = c.textMuted, fontSize = 13.sp, modifier = Modifier.padding(top = 6.dp, bottom = 32.dp))
        }
    }
}

@Composable
private fun NavRow(title: String, onClick: () -> Unit) {
    Row(Modifier.fillMaxWidth().clickable(onClick = onClick).padding(vertical = 14.dp), verticalAlignment = Alignment.CenterVertically) {
        Text(title, fontSize = 17.sp, fontWeight = FontWeight.ExtraBold, color = Gimano.colors.text, modifier = Modifier.weight(1f))
        Text("›", fontSize = 22.sp, color = Gimano.colors.textMuted)
    }
}

@Composable
private fun Section(t: String) {
    Text(t, Modifier.padding(top = 18.dp, bottom = 6.dp), fontWeight = FontWeight.SemiBold, fontSize = 15.sp, color = Gimano.colors.textMuted)
}

@Composable
@OptIn(ExperimentalLayoutApi::class)
private fun Choice(options: List<Pair<String, String>>, selected: String, onSelect: (String) -> Unit) {
    val c = Gimano.colors
    FlowRow(horizontalArrangement = Arrangement.spacedBy(8.dp), modifier = Modifier.fillMaxWidth()) {
        options.forEach { (k, label) ->
            FilterChip(
                selected = k == selected, onClick = { onSelect(k) }, label = { Text(label, fontSize = 14.sp) },
                shape = RoundedCornerShape(Radius.pill),
                colors = FilterChipDefaults.filterChipColors(selectedContainerColor = c.brand, selectedLabelColor = c.brandOn),
            )
        }
    }
}

@Composable
private fun SwitchRow(title: String, desc: String?, checked: Boolean, onChange: (Boolean) -> Unit) {
    val c = Gimano.colors
    Row(Modifier.fillMaxWidth().clickable { onChange(!checked) }.padding(vertical = 10.dp), verticalAlignment = Alignment.CenterVertically) {
        Column(Modifier.weight(1f)) {
            Text(title, fontSize = 17.sp, color = c.text)
            if (desc != null) Text(desc, fontSize = 13.sp, color = c.textMuted)
        }
        Switch(checked, onChange, colors = SwitchDefaults.colors(checkedTrackColor = c.brand))
    }
}

@Composable
private fun TextSetting(label: String?, value: String, onApply: (String) -> Unit) {
    var text by remember(value) { mutableStateOf(value) }
    Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.fillMaxWidth().padding(vertical = 4.dp)) {
        OutlinedTextField(
            text, { text = it }, Modifier.weight(1f), singleLine = true,
            label = label?.let { { Text(it) } }, shape = RoundedCornerShape(Radius.md), textStyle = LocalTextStyle.current.copy(fontSize = 14.sp),
        )
        if (text != value) TextButton(onClick = { onApply(text) }) { Text(stringResource(R.string.apply)) }
    }
}


/** Settings → app version: installed / latest / last checked, and "Check now". */
@Composable
private fun UpdateSection(vm: MainViewModel) {
    val c = Gimano.colors
    val updater = vm.container.updater
    val u by updater.ui.collectAsState()
    val scope = rememberCoroutineScope()
    Section(stringResource(R.string.update_section))
    val latest = when (val d = u.decision) {
        is my.gimano.app.core.update.UpdateDecision.Available -> d.manifest.versionName
        is my.gimano.app.core.update.UpdateDecision.Required -> d.manifest.versionName
        else -> null
    }
    Text(stringResource(R.string.update_installed, BuildConfig.VERSION_NAME), color = c.text, fontSize = 15.sp)
    Text(
        if (latest != null) stringResource(R.string.update_latest, latest) else stringResource(R.string.update_up_to_date),
        color = if (latest != null) c.brand else c.textMuted, fontSize = 15.sp, fontWeight = FontWeight.Bold,
    )
    if (u.lastCheckMs > 0) Text(
        stringResource(R.string.update_checked, my.gimano.app.core.format.Formatters.localStamp(java.time.Instant.ofEpochMilli(u.lastCheckMs).toString())),
        color = c.textMuted, fontSize = 13.sp,
    )
    Row(horizontalArrangement = Arrangement.spacedBy(10.dp), modifier = Modifier.padding(top = 8.dp)) {
        OutlinedButton(onClick = { scope.launch { updater.check(force = true) } }, enabled = !u.checking) {
            Text(stringResource(if (u.checking) R.string.update_checking else R.string.update_check_now), fontWeight = FontWeight.ExtraBold)
        }
        if (latest != null) Button(onClick = { scope.launch { updater.updateNow() } }, enabled = u.progress == null && !u.installing,
            colors = ButtonDefaults.buttonColors(containerColor = c.brand, contentColor = c.brandOn)) {
            Text(stringResource(R.string.update_now), fontWeight = FontWeight.ExtraBold)
        }
    }
    if (u.progress != null) LinearProgressIndicator(progress = { u.progress ?: 0f }, Modifier.fillMaxWidth().padding(top = 8.dp), color = c.brand)
}
