package my.gimano.app.ui.safety

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.*
import androidx.compose.material3.*
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import my.gimano.app.R
import my.gimano.app.core.safety.AppealState
import my.gimano.app.core.safety.RefusedItem
import my.gimano.app.ui.theme.Gimano
import my.gimano.app.ui.theme.GimanoType
import my.gimano.app.ui.theme.Radius
import java.time.Instant

/** The Inbox's "Not accepted" row: a cross icon, a badge with the number waiting. Only shown when there is something. */
@Composable
fun NotAcceptedRow(waiting: Int, total: Int, onClick: () -> Unit, modifier: Modifier = Modifier) {
    if (total <= 0) return
    val c = Gimano.colors
    val cd = stringResource(R.string.na_row_cd, waiting)
    Row(
        modifier.fillMaxWidth().clip(RoundedCornerShape(20.dp)).background(c.reportTint.copy(alpha = if (c.isDark) 0.5f else 1f))
            .semantics(mergeDescendants = true) { contentDescription = cd }
            .clickable(onClick = onClick).padding(14.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Icon(Icons.Filled.GppBad, null, tint = c.report, modifier = Modifier.size(36.dp))
        Spacer(Modifier.width(12.dp))
        Text(stringResource(R.string.na_row), Modifier.weight(1f), fontSize = 17.sp, fontWeight = FontWeight.Black, color = c.report)
        if (waiting > 0) Box(Modifier.size(28.dp).clip(androidx.compose.foundation.shape.CircleShape).background(c.report), contentAlignment = Alignment.Center) {
            Text(waiting.coerceAtMost(99).toString(), fontSize = 14.sp, fontWeight = FontWeight.Black, color = c.reportOn)
        }
        Icon(Icons.Filled.ChevronRight, null, tint = c.report)
    }
}

/** Refused content kept on this phone for 30 days: reasons as icons, Appeal, Delete. Nothing here was posted. */
@Composable
fun NotAcceptedScreen(items: List<RefusedItem>, onBack: () -> Unit, onAppeal: (String) -> Unit, onDelete: (String) -> Unit) {
    val c = Gimano.colors
    val now = Instant.now()
    Column(Modifier.fillMaxSize().background(c.background).windowInsetsPadding(WindowInsets.statusBars)) {
        Row(Modifier.fillMaxWidth().padding(8.dp), verticalAlignment = Alignment.CenterVertically) {
            IconButton(onClick = onBack) { Icon(Icons.AutoMirrored.Filled.ArrowBack, stringResource(R.string.back), tint = c.text) }
            Text(stringResource(R.string.na_title), style = GimanoType.title, color = c.text, modifier = Modifier.weight(1f))
        }
        Row(Modifier.padding(horizontal = 20.dp, vertical = 4.dp), verticalAlignment = Alignment.CenterVertically) {
            Icon(Icons.Filled.Lock, null, tint = c.textMuted, modifier = Modifier.size(18.dp)); Spacer(Modifier.width(8.dp))
            Text(stringResource(R.string.na_intro), fontSize = 14.sp, fontWeight = FontWeight.Bold, color = c.textMuted)
        }
        if (items.isEmpty()) Column(Modifier.fillMaxWidth().padding(40.dp), horizontalAlignment = Alignment.CenterHorizontally) {
            Icon(Icons.Filled.GppGood, null, tint = c.brandTint, modifier = Modifier.size(72.dp))
            Text(stringResource(R.string.na_empty), fontWeight = FontWeight.ExtraBold, color = c.textMuted, modifier = Modifier.padding(top = 12.dp))
        }
        LazyColumn(contentPadding = PaddingValues(16.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
            items(items, key = { it.id }) { i -> Card(i, now, onAppeal, onDelete) }
        }
    }
}

@Composable
private fun Card(i: RefusedItem, now: Instant, onAppeal: (String) -> Unit, onDelete: (String) -> Unit) {
    val c = Gimano.colors
    Column(Modifier.fillMaxWidth().clip(RoundedCornerShape(20.dp)).background(c.surface).padding(14.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Box(Modifier.size(44.dp).clip(RoundedCornerShape(14.dp)).background(c.reportTint.copy(alpha = if (c.isDark) 0.5f else 1f)), contentAlignment = Alignment.Center) {
                Icon(i.kind.icon(), stringResource(i.kind.label()), tint = c.report, modifier = Modifier.size(26.dp))
            }
            Spacer(Modifier.width(12.dp))
            Column(Modifier.weight(1f)) {
                Text(i.placeName.orEmpty().ifBlank { stringResource(i.kind.label()) }, fontSize = 16.sp, fontWeight = FontWeight.Black, color = c.text, maxLines = 1, overflow = TextOverflow.Ellipsis)
                Text(stringResource(R.string.na_days_left, i.daysLeft(now)), fontSize = 12.sp, fontWeight = FontWeight.ExtraBold, color = c.textMuted)
            }
            IconButton(onClick = { onDelete(i.id) }, Modifier.size(48.dp)) { Icon(Icons.Filled.DeleteOutline, stringResource(R.string.na_delete_cd), tint = c.textMuted) }
        }
        if (i.text.isNotBlank()) Text(i.text, Modifier.padding(top = 8.dp), fontSize = 15.sp, fontWeight = FontWeight.SemiBold, color = c.text, maxLines = 3, overflow = TextOverflow.Ellipsis)
        ReasonIcons(i.reasons, Modifier.padding(top = 10.dp))
        when (i.appealState) {
            AppealState.NONE -> Button(
                onClick = { onAppeal(i.id) }, Modifier.padding(top = 12.dp).fillMaxWidth().heightIn(min = 52.dp), shape = RoundedCornerShape(Radius.md),
                colors = ButtonDefaults.buttonColors(containerColor = c.brand, contentColor = c.brandOn),
            ) {
                Icon(Icons.Filled.Person, null, Modifier.size(22.dp)); Spacer(Modifier.width(8.dp))
                Text(stringResource(R.string.cs_appeal), style = GimanoType.button)
            }
            AppealState.SENT -> StateLine(Icons.Filled.HourglassTop, R.string.na_sent, warnTile(), warnInk())
            AppealState.ANSWERED -> StateLine(Icons.Filled.MarkEmailRead, R.string.na_answered, goodTile(), goodInk())
        }
    }
}

@Composable
private fun StateLine(icon: androidx.compose.ui.graphics.vector.ImageVector, text: Int, bg: androidx.compose.ui.graphics.Color, ink: androidx.compose.ui.graphics.Color) {
    Row(Modifier.padding(top = 12.dp).fillMaxWidth().clip(RoundedCornerShape(Radius.md)).background(bg).padding(12.dp), verticalAlignment = Alignment.CenterVertically) {
        Icon(icon, null, tint = ink, modifier = Modifier.size(26.dp)); Spacer(Modifier.width(10.dp))
        Text(stringResource(text), fontSize = 15.sp, fontWeight = FontWeight.ExtraBold, color = ink)
    }
}
