package my.gimano.app.ui.contribute

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import kotlin.math.roundToInt
import coil3.compose.AsyncImage
import my.gimano.app.AppContainer
import my.gimano.app.R
import androidx.compose.material.icons.filled.Delete
import my.gimano.app.core.places.MyPlaceStatus
import my.gimano.app.core.places.PlaceGate
import my.gimano.app.data.model.PlaceSummary
import my.gimano.app.data.model.User
import my.gimano.app.ui.MainViewModel
import my.gimano.app.ui.common.CategoryGlyph
import my.gimano.app.ui.common.GIcon
import my.gimano.app.ui.place.mediaUrl
import my.gimano.app.ui.theme.Gimano
import my.gimano.app.ui.theme.GimanoType

/** My contributions (design board): level ring + points, stats, tabs Places / Reviews / Photos. */
@Composable
fun ContributionsScreen(c: AppContainer, cvm: ContributeViewModel, vm: MainViewModel, user: User?) {
    val col = Gimano.colors
    var places by remember { mutableStateOf<List<PlaceSummary>?>(null) }
    val counts by cvm.log.counts.collectAsState(initial = 0 to emptyList())
    val reports by cvm.log.reports.collectAsState(initial = 0)
    val reviewNames by cvm.log.reviewEntries.collectAsState(initial = emptyList())
    var tab by remember { mutableIntStateOf(0) }
    val drafts by cvm.drafts.collectAsState(initial = emptyList())
    val privatePlaces by c.local.privatePlaces.collectAsState(initial = emptyList())
    // Reloaded when a draft goes out (sent from the queue or from the flow).
    LaunchedEffect(drafts.size) { places = runCatching { c.repo.contributedPlaces() }.getOrDefault(places ?: emptyList()) }
    val points = user?.points ?: 0

    Column(Modifier.fillMaxSize().background(col.background).windowInsetsPadding(WindowInsets.statusBars)) {
        Row(Modifier.fillMaxWidth().padding(8.dp), verticalAlignment = Alignment.CenterVertically) {
            IconButton(onClick = vm::back) { Icon(Icons.AutoMirrored.Filled.ArrowBack, stringResource(R.string.back), tint = col.text) }
            Text(stringResource(R.string.my_contributions), style = GimanoType.title, color = col.text)
        }
        // Trust tier ring (Baharu → Perak → Emas), accuracy and what the next tier still needs.
        val tier = user?.tier ?: "baharu"
        val tierProgress = when (tier) {
            "emas" -> 1f
            "perak" -> ((user?.placesAccepted ?: 0) / 50f).coerceIn(0f, 1f)
            else -> ((user?.placesAccepted ?: 0) / 10f).coerceIn(0f, 1f)
        }
        val ringColor = tierColor(tier)
        Row(Modifier.padding(horizontal = 16.dp).fillMaxWidth().clip(RoundedCornerShape(24.dp)).background(col.brand).padding(18.dp), verticalAlignment = Alignment.CenterVertically) {
            val ringLabel = tierName(tier)
            Box(Modifier.size(76.dp).semantics { contentDescription = ringLabel }, contentAlignment = Alignment.Center) {
                Canvas(Modifier.matchParentSize()) {
                    drawArc(Color.White.copy(alpha = 0.25f), 0f, 360f, false, style = Stroke(8.dp.toPx()))
                    drawArc(ringColor, -90f, 360f * tierProgress, false, style = Stroke(8.dp.toPx(), cap = StrokeCap.Round))
                }
                Text(ringLabel, color = col.brandOn, fontSize = 13.sp, fontWeight = FontWeight.Black)
            }
            Spacer(Modifier.width(16.dp))
            Column(verticalArrangement = Arrangement.spacedBy(2.dp)) {
                Text("%,d".format(points) + " " + stringResource(R.string.points_short), color = col.brandOn, fontSize = 26.sp, fontWeight = FontWeight.Black)
                Text(
                    user?.accuracy?.let { stringResource(R.string.accuracy_pct, (it * 100).roundToInt()) } ?: stringResource(R.string.accuracy_pending),
                    color = col.brandOn.copy(alpha = 0.9f), fontSize = 14.sp, fontWeight = FontWeight.ExtraBold,
                )
                val next = user?.nextTier
                Text(
                    if (tier == "emas" || next == null || next.name.isBlank()) stringResource(R.string.top_tier)
                    else stringResource(R.string.next_tier, tierName(next.name), next.missing.map { my.gimano.app.ui.common.Labels.tierNeed(it) }.joinToString(", ").ifBlank { "—" }),
                    color = col.brandOn.copy(alpha = 0.85f), fontSize = 13.sp, fontWeight = FontWeight.Bold,
                )
            }
        }
        Row(Modifier.fillMaxWidth().padding(16.dp), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            Stat("report", "$reports", stringResource(R.string.reports_n), Modifier.weight(1f))
            Stat("add_stop", "${places?.size ?: 0}", stringResource(R.string.places_n), Modifier.weight(1f))
            Stat("star", "${counts.first}", stringResource(R.string.reviews), Modifier.weight(1f))
            Stat("map", "${counts.second.size}", stringResource(R.string.photos), Modifier.weight(1f))
        }
        Row(Modifier.padding(horizontal = 16.dp).fillMaxWidth().clip(RoundedCornerShape(16.dp)).background(col.brandMist).padding(4.dp)) {
            listOf(R.string.places_n, R.string.reviews, R.string.photos).forEachIndexed { i, l ->
                val sel = tab == i
                Text(stringResource(l), Modifier.weight(1f).clip(RoundedCornerShape(12.dp)).background(if (sel) col.surface else Color.Transparent).clickable { tab = i }.padding(vertical = 12.dp),
                    fontSize = 15.sp, fontWeight = if (sel) FontWeight.Black else FontWeight.ExtraBold, color = if (sel) col.text else col.textMuted, textAlign = androidx.compose.ui.text.style.TextAlign.Center)
            }
        }
        if (tab == 0 && places == null) LinearProgressIndicator(Modifier.fillMaxWidth().padding(16.dp), color = col.brand, trackColor = col.surfaceAlt)
        LazyColumn(contentPadding = PaddingValues(16.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
            when (tab) {
                // C3 "My places": every place I added, wherever it is (server, a draft on this phone, or just for me).
                0 -> {
                    items(drafts, key = { "d-" + it.id }) { d ->
                        val left = d.readyAt()?.let { java.time.Duration.between(java.time.Instant.now(), it).seconds.toInt() }?.takeIf { it > 0 }
                        MyPlaceRow(d.request.name, d.request.category, MyPlaceStatus.DRAFT, if (d.queued) stringResource(R.string.mp_queued) else null,
                            next = if (d.queued) null else left?.let { stringResource(R.string.mp_share_in, PlaceGate.minutes(it) ?: 1) } ?: stringResource(R.string.mp_share_now),
                            onDiscard = { cvm.discardDraft(d.id) }) { cvm.openDraft(d.id) }
                    }
                    items(places.orEmpty(), key = { it.id }) { p ->
                        val st = PlaceGate.myStatus(p)
                        val next = when (st) {
                            MyPlaceStatus.LIVE_UNVERIFIED, MyPlaceStatus.WAITING -> PlaceGate.progress(p)?.let { (n, of) -> stringResource(R.string.mp_x_of_y, n, of) }
                            MyPlaceStatus.HELD -> stringResource(R.string.mp_within_24h)
                            MyPlaceStatus.NOT_ACCEPTED -> stringResource(if (p.screening?.canAppeal == true) R.string.mp_ask_review else R.string.mp_review_closed)
                            MyPlaceStatus.HIDDEN -> stringResource(R.string.mp_moderator)
                            else -> null
                        }
                        // The check's results open their screen (appeal, edit, keep it just for me); the rest open the place.
                        MyPlaceRow(p.name, p.category, st, null, next) {
                            if (st == MyPlaceStatus.NOT_ACCEPTED || st == MyPlaceStatus.HELD || st == MyPlaceStatus.CHECKING) cvm.openResult(p.id, p) else vm.showPlace(p)
                        }
                    }
                    items(privatePlaces, key = { "p-" + it.id }) { e ->
                        MyPlaceRow(stringResource(R.string.mp_just_for_me_name, e.name), e.category, MyPlaceStatus.JUST_FOR_ME, null, stringResource(R.string.mp_private_next)) { vm.showPrivate(e.id) }
                    }
                }
                1 -> items(reviewNames) { (name, held) ->
                    Row(Modifier.fillMaxWidth().clip(RoundedCornerShape(20.dp)).background(col.surface).padding(14.dp), verticalAlignment = Alignment.CenterVertically) {
                        GIcon("star", null, size = 30.dp); Spacer(Modifier.width(12.dp))
                        Text(name, Modifier.weight(1f), fontWeight = FontWeight.Black, fontSize = 16.sp, color = col.text)
                        if (held) HeldChip()
                    }
                }
                else -> items(counts.second) { url ->
                    AsyncImage(mediaUrl(url, c.settings.current.apiBaseUrl), null, Modifier.fillMaxWidth().height(180.dp).clip(RoundedCornerShape(20.dp)), contentScale = ContentScale.Crop)
                }
            }
        }
    }
}

@Composable
private fun Stat(icon: String, value: String, label: String, modifier: Modifier) {
    val c = Gimano.colors
    Column(modifier.clip(RoundedCornerShape(18.dp)).background(c.surface).padding(vertical = 12.dp, horizontal = 4.dp), horizontalAlignment = Alignment.CenterHorizontally) {
        GIcon(icon, null, size = 30.dp)
        Text(value, fontSize = 20.sp, fontWeight = FontWeight.Black, color = c.text)
        Text(label, fontSize = 12.sp, fontWeight = FontWeight.ExtraBold, color = c.textMuted, maxLines = 1)
    }
}

/** One row of My places (design C3): category, name, status chip, and what happens next on the right. */
@Composable
private fun MyPlaceRow(name: String, category: String, status: MyPlaceStatus, statusText: String?, next: String?, onDiscard: (() -> Unit)? = null, onClick: () -> Unit) {
    val col = Gimano.colors
    val (bg, fg) = when (status) {
        MyPlaceStatus.COMMUNITY_VERIFIED -> (if (col.isDark) Color(0xFF123B33) else Color(0xFFDDF4F2)) to (if (col.isDark) Color(0xFF7FE0C2) else Color(0xFF0B3D2E))
        MyPlaceStatus.LIVE_UNVERIFIED, MyPlaceStatus.WAITING -> (if (col.isDark) Color(0xFF3A2E12) else Color(0xFFFFF1CC)) to (if (col.isDark) Color(0xFFFFD98A) else Color(0xFF7A5200))
        MyPlaceStatus.HELD, MyPlaceStatus.CHECKING -> col.brandMist to col.brandInk
        MyPlaceStatus.DRAFT, MyPlaceStatus.JUST_FOR_ME -> col.surfaceAlt to col.textMuted
        MyPlaceStatus.NOT_ACCEPTED, MyPlaceStatus.HIDDEN, MyPlaceStatus.EXPIRED, MyPlaceStatus.CLOSED -> col.reportTint to col.report
    }
    val label = statusText ?: stringResource(when (status) {
        MyPlaceStatus.COMMUNITY_VERIFIED -> R.string.mp_verified
        MyPlaceStatus.LIVE_UNVERIFIED -> R.string.mp_live
        MyPlaceStatus.WAITING -> R.string.mp_waiting
        MyPlaceStatus.CHECKING -> R.string.mp_checking
        MyPlaceStatus.HELD -> R.string.mp_held
        MyPlaceStatus.NOT_ACCEPTED -> R.string.mp_not_accepted
        MyPlaceStatus.HIDDEN -> R.string.mp_hidden
        MyPlaceStatus.EXPIRED -> R.string.mp_expired
        MyPlaceStatus.CLOSED -> R.string.mp_closed
        MyPlaceStatus.DRAFT -> R.string.mp_draft
        MyPlaceStatus.JUST_FOR_ME -> R.string.mp_private
    })
    Row(Modifier.fillMaxWidth().clip(RoundedCornerShape(20.dp)).background(col.surface).clickable(onClick = onClick).padding(14.dp), verticalAlignment = Alignment.CenterVertically) {
        Box(Modifier.size(52.dp).clip(RoundedCornerShape(16.dp)).background(col.brandMist), contentAlignment = Alignment.Center) { CategoryGlyph(category, 30.dp) }
        Spacer(Modifier.width(12.dp))
        Column(Modifier.weight(1f)) {
            Text(name, fontWeight = FontWeight.Black, fontSize = 17.sp, color = col.text, maxLines = 2, overflow = TextOverflow.Ellipsis)
            Text(label, Modifier.padding(top = 4.dp).clip(RoundedCornerShape(999.dp)).background(bg).padding(horizontal = 10.dp, vertical = 4.dp),
                fontSize = 12.sp, fontWeight = FontWeight.Black, color = fg)
        }
        if (next != null) Text(next, Modifier.padding(start = 8.dp), fontSize = 13.sp, fontWeight = FontWeight.ExtraBold, color = col.textMuted)
        if (onDiscard != null) IconButton(onClick = onDiscard) {
            Icon(androidx.compose.material.icons.Icons.Filled.Delete, stringResource(R.string.mp_discard_draft), tint = col.textMuted)
        }
    }
}

/** "Sedang disemak": hidden until a moderator checks it (near a restricted area, or security details in the text). */
@Composable
private fun HeldChip() {
    Text(stringResource(R.string.status_held),
        Modifier.clip(RoundedCornerShape(999.dp)).background(Color(0xFFECEEF1)).padding(horizontal = 10.dp, vertical = 4.dp),
        fontSize = 12.sp, fontWeight = FontWeight.Black, color = Color(0xFF2F3640))
}
