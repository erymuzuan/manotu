package my.gimano.app.ui.about

import android.content.Intent
import android.net.Uri
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.SystemUpdate
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import kotlinx.coroutines.launch
import my.gimano.app.AppContainer
import my.gimano.app.BuildConfig
import my.gimano.app.R
import my.gimano.app.core.update.UpdateDecision
import my.gimano.app.ui.theme.Gimano

private const val SITE = "https://manotu.app/"
const val GITHUB = "https://github.com/erymuzuan/manotu"
/** Privacy, account deletion and content reports. */
const val CONTACT_EMAIL = "privacy@bukitbunga.com"

/** Settings → "Tentang Manotu": version, server, updates, links and map attribution. */
@Composable
fun AboutScreen(c: AppContainer, live: Boolean, onBack: () -> Unit, onLicences: () -> Unit) {
    val col = Gimano.colors
    val ctx = LocalContext.current
    val scope = rememberCoroutineScope()
    val u by c.updater.ui.collectAsState()
    fun open(url: String) = runCatching { ctx.startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(url))) }
    // The public server is just "Manotu" (its host name is infrastructure); other servers (dev) show their host.
    val url = c.settings.current.apiBaseUrl
    val host = if (my.gimano.app.core.format.ServerLabel.isPublic(url, my.gimano.app.BuildConfig.API_BASE_URL, my.gimano.app.BuildConfig.DEBUG)) stringResource(R.string.app_name)
        else runCatching { Uri.parse(url).host }.getOrNull() ?: "—"
    Column(Modifier.fillMaxSize().background(col.background).windowInsetsPadding(WindowInsets.statusBars)) {
        Row(Modifier.fillMaxWidth().padding(4.dp), verticalAlignment = Alignment.CenterVertically) {
            IconButton(onClick = onBack) { Icon(Icons.AutoMirrored.Filled.ArrowBack, stringResource(R.string.back), tint = col.text) }
            Text(stringResource(R.string.about_gimano), fontSize = 22.sp, fontWeight = FontWeight.Black, color = col.text)
        }
        Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(16.dp), verticalArrangement = Arrangement.spacedBy(12.dp), horizontalAlignment = Alignment.CenterHorizontally) {
            Box(Modifier.size(96.dp).clip(RoundedCornerShape(26.dp)).background(Color0.brand), contentAlignment = Alignment.Center) {
                Image(painterResource(R.drawable.ic_launcher_foreground), null, Modifier.size(132.dp))
            }
            Text(stringResource(R.string.app_name), fontSize = 28.sp, fontWeight = FontWeight.Black, color = col.text)
            Text(stringResource(R.string.about_version, BuildConfig.VERSION_NAME, BuildConfig.VERSION_CODE), fontSize = 17.sp, fontWeight = FontWeight.ExtraBold, color = col.text)
            Text(stringResource(R.string.about_server, host, stringResource(if (live) R.string.mode_live else R.string.mode_demo)), fontSize = 14.sp, fontWeight = FontWeight.Bold, color = col.textMuted)
            // Google Play build: Play delivers updates, so no in-app updater card, just where the app came from.
            if (!BuildConfig.SELF_UPDATE) Text(stringResource(R.string.about_distribution_play), fontSize = 14.sp, fontWeight = FontWeight.Bold, color = col.textMuted)
            val su by c.storeUpdater.ui.collectAsState()
            val storeLatest = (su.decision as? my.gimano.app.core.update.StoreUpdateDecision.Soft)?.latest
                ?: (su.decision as? my.gimano.app.core.update.StoreUpdateDecision.Forced)?.latest
            if (storeLatest != null) Row(Modifier.fillMaxWidth().clip(RoundedCornerShape(20.dp)).background(col.surface).padding(horizontal = 16.dp, vertical = 12.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                Icon(Icons.Filled.SystemUpdate, null, tint = col.brandInk, modifier = Modifier.size(28.dp))
                Column(Modifier.weight(1f)) {
                    Text(stringResource(R.string.update_available), fontWeight = FontWeight.Black, color = col.text)
                    Text(storeLatest, fontSize = 14.sp, fontWeight = FontWeight.Bold, color = col.brand)
                }
                Button(onClick = c.storeUpdater::openStore, colors = ButtonDefaults.buttonColors(containerColor = col.brand, contentColor = col.brandOn)) { Text(stringResource(R.string.update_now), fontWeight = FontWeight.ExtraBold) }
            }
            if (BuildConfig.DEBUG) {
                var dbg by remember { mutableStateOf(c.storeUpdater.debugToggle()) }
                Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                    Text(stringResource(R.string.store_update_debug), Modifier.weight(1f), fontSize = 13.sp, color = col.textMuted)
                    Switch(checked = dbg, onCheckedChange = { dbg = it; c.storeUpdater.setDebugToggle(it); scope.launch { c.storeUpdater.check() } })
                }
            }
            else Column(Modifier.fillMaxWidth().clip(RoundedCornerShape(20.dp)).background(col.surface).padding(16.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
                val latest = when (val d = u.decision) { is UpdateDecision.Available -> d.manifest.versionName; is UpdateDecision.Required -> d.manifest.versionName; else -> null }
                Text(if (latest != null) stringResource(R.string.update_latest, latest) else stringResource(R.string.update_up_to_date), fontWeight = FontWeight.Black, color = if (latest != null) col.brand else col.text)
                if (u.lastCheckMs > 0) Text(stringResource(R.string.update_checked, my.gimano.app.core.format.Formatters.localStamp(java.time.Instant.ofEpochMilli(u.lastCheckMs).toString())), fontSize = 13.sp, color = col.textMuted)
                Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                    OutlinedButton(onClick = { scope.launch { c.updater.check(force = true) } }, enabled = !u.checking) {
                        Text(stringResource(if (u.checking) R.string.update_checking else R.string.update_check_now), fontWeight = FontWeight.ExtraBold)
                    }
                    if (latest != null) Button(onClick = { scope.launch { c.updater.updateNow() } }, enabled = u.progress == null && !u.installing,
                        colors = ButtonDefaults.buttonColors(containerColor = col.brand, contentColor = col.brandOn)) { Text(stringResource(R.string.update_now), fontWeight = FontWeight.ExtraBold) }
                }
                u.progress?.let { LinearProgressIndicator(progress = { it }, Modifier.fillMaxWidth(), color = col.brand) }
            }
            Column(Modifier.fillMaxWidth().clip(RoundedCornerShape(20.dp)).background(col.surface)) {
                LinkRow(stringResource(R.string.about_privacy)) { open(SITE + "privacy/") }
                LinkRow(stringResource(R.string.about_terms)) { open(SITE + "terms/") }
                // Contact for privacy, deletion and content reports (store listings use the same address).
                LinkRow(stringResource(R.string.about_contact, CONTACT_EMAIL)) { open("mailto:$CONTACT_EMAIL") }
                LinkRow(stringResource(R.string.about_source)) { open(GITHUB) }
                LinkRow(stringResource(R.string.about_licences), onLicences)
            }
            Text(stringResource(R.string.about_map_credit), Modifier.clickable { open("https://www.openstreetmap.org/copyright") }, fontSize = 13.sp, fontWeight = FontWeight.Bold, color = col.textMuted)
        }
    }
}

private object Color0 { val brand = androidx.compose.ui.graphics.Color(0xFF0047AB) }

@Composable
private fun LinkRow(label: String, onClick: () -> Unit) {
    val c = Gimano.colors
    Row(Modifier.fillMaxWidth().clickable(onClick = onClick).padding(horizontal = 16.dp, vertical = 16.dp), verticalAlignment = Alignment.CenterVertically) {
        Text(label, Modifier.weight(1f), fontSize = 16.sp, fontWeight = FontWeight.ExtraBold, color = c.text)
        Text("›", fontSize = 20.sp, color = c.textMuted)
    }
}

/** What Gimano is built from (docs/supply-chain.md), Android side. Honest about the closed Google Play services. */
private val LICENCES = listOf(
    Triple("OpenStreetMap data", "ODbL 1.0", "OpenStreetMap Foundation & contributors"),
    Triple("MapLibre Native Android", "BSD-2-Clause", "MapLibre (Linux Foundation project)"),
    Triple("OpenFreeMap styles", "MIT (data ODbL)", "OpenFreeMap"),
    Triple("Kotlin, kotlinx.coroutines, kotlinx.serialization", "Apache-2.0", "JetBrains"),
    Triple("Jetpack Compose, AndroidX (Room, WorkManager, DataStore, Biometric…)", "Apache-2.0", "Android Open Source Project"),
    Triple("OkHttp, Retrofit, Okio", "Apache-2.0", "Square"),
    Triple("SignalR Java client", "MIT", ".NET Foundation"),
    Triple("Coil", "Apache-2.0", "Coil contributors"),
    Triple("libsodium", "ISC", "libsodium project"),
    Triple("Lazysodium for Android", "MPL-2.0", "Terl"),
    Triple("JNA", "Apache-2.0 / LGPL-2.1", "JNA project"),
    Triple("Nunito", "SIL OFL 1.1", "Nunito project"),
    Triple("BIP-39 English word list", "MIT", "Bitcoin BIPs"),
)

@Composable
fun LicencesScreen(onBack: () -> Unit) {
    val c = Gimano.colors
    val ctx = LocalContext.current
    Column(Modifier.fillMaxSize().background(c.background).windowInsetsPadding(WindowInsets.statusBars)) {
        Row(Modifier.fillMaxWidth().padding(4.dp), verticalAlignment = Alignment.CenterVertically) {
            IconButton(onClick = onBack) { Icon(Icons.AutoMirrored.Filled.ArrowBack, stringResource(R.string.back), tint = c.text) }
            Text(stringResource(R.string.about_licences), fontSize = 22.sp, fontWeight = FontWeight.Black, color = c.text)
        }
        LazyColumn(contentPadding = PaddingValues(16.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
            item { Text(stringResource(R.string.licences_intro), fontSize = 14.sp, color = c.textMuted, fontWeight = FontWeight.Bold) }
            items(LICENCES) { (name, licence, who) ->
                Column(Modifier.fillMaxWidth().clip(RoundedCornerShape(16.dp)).background(c.surface).padding(14.dp)) {
                    Text(name, fontSize = 15.sp, fontWeight = FontWeight.Black, color = c.text)
                    Text("$licence · $who", fontSize = 13.sp, fontWeight = FontWeight.Bold, color = c.textMuted)
                }
            }
            // Approved Google platform exceptions (AGENTS.md, docs/supply-chain.md): named honestly.
            item {
                Column(Modifier.fillMaxWidth().padding(top = 12.dp).clip(RoundedCornerShape(16.dp)).background(androidx.compose.ui.graphics.Color(0xFFFFF1CC)).padding(14.dp),
                    verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    Text(stringResource(R.string.closed_title), fontSize = 17.sp, fontWeight = FontWeight.Black, color = androidx.compose.ui.graphics.Color(0xFF5C3D00))
                    // Play build: no Drive backup, so Google sign-in / Drive authorisation is never used there.
                    val drive = my.gimano.app.BuildConfig.DRIVE_BACKUP
                    Text(stringResource(if (drive) R.string.closed_intro else R.string.closed_intro_no_drive), fontSize = 14.sp, fontWeight = FontWeight.Bold, color = androidx.compose.ui.graphics.Color(0xFF5C3D00))
                    listOf(R.string.closed_location, if (drive) R.string.closed_drive else R.string.closed_drive_not_used, R.string.closed_integrity).forEach {
                        Text("• " + stringResource(it), fontSize = 14.sp, color = androidx.compose.ui.graphics.Color(0xFF3D2900))
                    }
                }
            }
            item {
                TextButton(onClick = { runCatching { ctx.startActivity(Intent(Intent.ACTION_VIEW, Uri.parse("$GITHUB/blob/main/docs/supply-chain.md"))) } }) {
                    Text(stringResource(R.string.licences_full_list), fontWeight = FontWeight.ExtraBold)
                }
            }
        }
    }
}
