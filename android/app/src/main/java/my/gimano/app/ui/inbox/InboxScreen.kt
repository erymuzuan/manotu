package my.gimano.app.ui.inbox

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.foundation.clickable
import androidx.compose.material.icons.filled.Campaign
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.Inbox
import androidx.compose.material.icons.filled.Schedule
import androidx.compose.ui.graphics.Color
import androidx.compose.material3.*
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import my.gimano.app.R
import my.gimano.app.core.format.Formatters
import my.gimano.app.data.model.InboxItem
import my.gimano.app.ui.common.GIcon
import my.gimano.app.ui.report.currentLang
import my.gimano.app.ui.theme.Gimano
import my.gimano.app.ui.theme.GimanoType
import java.time.Instant

/**
 * The AI check's Inbox kinds (docs/api.md: place_held, place_not_accepted, place_live; refType "place"). The server's
 * title and body are its own fixed, localized copy (InboxRules), never the check's text; the app adds the icon.
 */
enum class InboxGate(val icon: androidx.compose.ui.graphics.vector.ImageVector) {
    LIVE(Icons.Filled.Check), HELD(Icons.Filled.Schedule), NOT_ACCEPTED(Icons.Filled.Close);

    companion object {
        fun of(kind: String): InboxGate? = when (kind) {
            "place_live" -> LIVE
            "place_held" -> HELD
            "place_not_accepted" -> NOT_ACCEPTED
            else -> null
        }
    }
}

/** Inbox: news about the user's public contributions + announcements (nothing personal). */
@Composable
fun InboxScreen(items: List<InboxItem>, read: Set<String>, onBack: () -> Unit, onRefresh: () -> Unit, onMarkAll: () -> Unit, onOpenPlace: (InboxItem) -> Unit = {}) {
    val c = Gimano.colors
    val lang = currentLang()
    LaunchedEffect(Unit) { onRefresh() }
    Column(Modifier.fillMaxSize().background(c.background).windowInsetsPadding(WindowInsets.statusBars)) {
        Row(Modifier.fillMaxWidth().padding(8.dp), verticalAlignment = Alignment.CenterVertically) {
            IconButton(onClick = onBack) { Icon(Icons.AutoMirrored.Filled.ArrowBack, stringResource(R.string.back), tint = c.text) }
            Text(stringResource(R.string.inbox), style = GimanoType.title, color = c.text, modifier = Modifier.weight(1f))
            if (items.any { it.id !in read }) FilledTonalButton(onClick = onMarkAll) { Text(stringResource(R.string.mark_all_read), fontWeight = FontWeight.Black, fontSize = 14.sp) }
        }
        Text(stringResource(R.string.inbox_intro), Modifier.padding(horizontal = 20.dp, vertical = 4.dp), fontSize = 14.sp, fontWeight = FontWeight.Bold, color = c.textMuted)
        if (items.isEmpty()) {
            Column(Modifier.fillMaxWidth().padding(40.dp), horizontalAlignment = Alignment.CenterHorizontally) {
                Icon(Icons.Filled.Inbox, null, tint = c.brandTint, modifier = Modifier.size(72.dp))
                Text(stringResource(R.string.inbox_empty), fontWeight = FontWeight.ExtraBold, color = c.textMuted, modifier = Modifier.padding(top = 12.dp))
            }
        }
        LazyColumn(contentPadding = PaddingValues(16.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
            items(items, key = { it.id }) { m ->
                val unread = m.id !in read
                val gate = InboxGate.of(m.kind)
                val opens = gate != null && m.placeRef != null
                Row(
                    Modifier.fillMaxWidth().clip(RoundedCornerShape(20.dp)).background(c.surface)
                        .then(if (unread) Modifier.border(2.dp, c.report, RoundedCornerShape(20.dp)) else Modifier)
                        .then(if (opens) Modifier.clickable { onOpenPlace(m) } else Modifier).padding(14.dp),
                ) {
                    // C2: the AI check's three kinds: a tick (live), a clock (a person checks), a cross (not accepted).
                    val (tile, ink) = when (gate) {
                        InboxGate.LIVE -> (if (c.isDark) Color(0xFF123B33) else Color(0xFFDDF4F2)) to (if (c.isDark) Color(0xFF7FE0C2) else Color(0xFF0E8A5F))
                        InboxGate.HELD -> (if (c.isDark) Color(0xFF3A2E12) else Color(0xFFFFF1CC)) to (if (c.isDark) Color(0xFFFFD98A) else Color(0xFF7A5200))
                        InboxGate.NOT_ACCEPTED -> c.reportTint to c.report
                        null -> c.brandMist to c.brandInk
                    }
                    Box(Modifier.size(48.dp).clip(RoundedCornerShape(16.dp)).background(tile), contentAlignment = Alignment.Center) {
                        if (gate != null) Icon(gate.icon, null, tint = ink, modifier = Modifier.size(26.dp))
                        else when (m.kind) {
                            "place_published", "place_rejected" -> GIcon("add_stop", null, size = 28.dp)
                            "report_thanks" -> GIcon("heart", null, size = 28.dp)
                            "review_helpful" -> GIcon("star", null, size = 28.dp)
                            "feedback_status" -> GIcon("feedback", null, size = 28.dp)
                            "edit_accepted" -> GIcon("map", null, size = 28.dp)
                            "issue_confirmed", "issue_refuted", "issue_resolved" -> GIcon("map", null, size = 28.dp)
                            else -> Icon(Icons.Filled.Campaign, null, tint = c.brandInk, modifier = Modifier.size(26.dp))
                        }
                    }
                    Spacer(Modifier.width(12.dp))
                    Column(Modifier.weight(1f)) {
                        val title = m.title.ifBlank {
                            when (m.kind) {
                                "issue_confirmed" -> stringResource(R.string.inbox_issue_confirmed)
                                "issue_refuted" -> stringResource(R.string.inbox_issue_refuted)
                                "issue_resolved" -> stringResource(R.string.inbox_issue_resolved)
                                "place_held" -> stringResource(R.string.inbox_place_held)
                                "place_not_accepted" -> stringResource(R.string.inbox_place_not_accepted)
                                "place_live" -> stringResource(R.string.inbox_place_live)
                                else -> ""
                            }
                        }
                        Text(title, fontSize = 16.sp, fontWeight = FontWeight.Black, color = c.text)
                        if (m.body.isNotBlank()) Text(m.body, fontSize = 14.sp, fontWeight = FontWeight.Bold, color = c.textMuted)
                        Formatters.parseInstant(m.createdAt)?.let { Text(Formatters.reportAge(it, Instant.now(), lang), fontSize = 12.sp, fontWeight = FontWeight.ExtraBold, color = c.textMuted) }
                    }
                }
            }
        }
    }
}
