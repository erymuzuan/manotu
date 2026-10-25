package my.gimano.app.ui.issues

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.*
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import my.gimano.app.R
import my.gimano.app.core.issues.Deviation
import my.gimano.app.core.issues.IssueSupport
import my.gimano.app.core.issues.IssueText
import my.gimano.app.core.format.Lang
import my.gimano.app.data.model.Issue
import my.gimano.app.data.model.IssueKind
import my.gimano.app.data.model.RouteIssue
import my.gimano.app.ui.report.currentLang
import my.gimano.app.ui.theme.Gimano
import my.gimano.app.ui.theme.Radius
import java.time.Instant
import java.time.LocalDate
import java.time.ZoneId

private val Amber = Color(0xFFFFF1CC)
private val AmberInk = Color(0xFF7A5200)

private val roadIcons: Map<String, ImageVector> = mapOf(
    "closed" to Icons.Filled.Block, "no_road" to Icons.Filled.WrongLocation, "oneway" to Icons.Filled.TrendingFlat,
    "no_turn" to Icons.Filled.DoNotDisturbOn, "odd_route" to Icons.Filled.AltRoute, "new_road" to Icons.Filled.AddRoad,
)

private val roadLabels = mapOf(
    "closed" to R.string.rp_closed, "no_road" to R.string.rp_no_road, "oneway" to R.string.rp_oneway,
    "no_turn" to R.string.rp_no_turn, "odd_route" to R.string.rp_odd_route, "new_road" to R.string.rp_new_road,
)

private val durationLabels = mapOf(
    "unknown" to R.string.dur_unknown, "today" to R.string.dur_today, "few_days" to R.string.dur_days, "long_roadworks" to R.string.dur_long_works,
)

/** "Masalah jalan" group under the report grid (AduanLapor): 6 types. */
@Composable
fun RoadProblemGroup(onPick: (String) -> Unit) {
    val c = Gimano.colors
    Text(stringResource(R.string.road_problems), fontSize = 18.sp, fontWeight = FontWeight.Black, color = c.text, modifier = Modifier.padding(top = 14.dp, bottom = 8.dp))
    IssueSupport.roadProblemKinds.keys.chunked(3).forEach { row ->
        Row(Modifier.fillMaxWidth().padding(bottom = 8.dp), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            row.forEach { t ->
                val label = stringResource(roadLabels.getValue(t))
                Column(
                    Modifier.weight(1f).clip(RoundedCornerShape(Radius.md)).background(c.surfaceAlt).clickable(onClickLabel = label) { onPick(t) }.padding(vertical = 10.dp),
                    horizontalAlignment = Alignment.CenterHorizontally,
                ) {
                    Icon(roadIcons.getValue(t), null, tint = c.brandInk, modifier = Modifier.size(28.dp))
                    Text(label, fontSize = 14.sp, fontWeight = FontWeight.ExtraBold, color = c.text, textAlign = TextAlign.Center, maxLines = 2, modifier = Modifier.padding(top = 4.dp))
                }
            }
            repeat(3 - row.size) { Spacer(Modifier.weight(1f)) }
        }
    }
}

/** Second step: (duration chips for Ditutup) + Hantar. */
@Composable
fun RoadProblemConfirm(type: String, onBack: () -> Unit, onSend: (durationHint: String?) -> Unit) {
    val c = Gimano.colors
    var duration by remember { mutableStateOf("unknown") }
    Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.padding(bottom = 12.dp)) {
        IconButton(onClick = onBack) { Icon(Icons.AutoMirrored.Filled.ArrowBack, stringResource(R.string.back), tint = c.text) }
        Icon(roadIcons.getValue(type), null, tint = c.brandInk, modifier = Modifier.size(36.dp))
        Spacer(Modifier.width(12.dp))
        Text(stringResource(roadLabels.getValue(type)), fontSize = 22.sp, fontWeight = FontWeight.Black, color = c.text)
    }
    if (type == "closed") {
        Text(stringResource(R.string.rp_how_long), fontWeight = FontWeight.ExtraBold, color = c.text, modifier = Modifier.padding(bottom = 8.dp))
        IssueSupport.closureDurations.chunked(2).forEach { row ->
            Row(Modifier.fillMaxWidth().padding(bottom = 8.dp), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                row.forEach { d ->
                    FilterChip(selected = duration == d, onClick = { duration = d }, label = { Text(stringResource(durationLabels.getValue(d)), fontWeight = FontWeight.ExtraBold) },
                        modifier = Modifier.weight(1f).height(48.dp))
                }
            }
        }
    }
    Text(stringResource(R.string.rp_one_report_note), fontSize = 13.sp, color = c.textMuted, modifier = Modifier.padding(vertical = 8.dp))
    Button(onClick = { onSend(if (type == "closed") duration else null) }, modifier = Modifier.fillMaxWidth().height(56.dp), shape = RoundedCornerShape(Radius.md),
        colors = ButtonDefaults.buttonColors(containerColor = c.report, contentColor = c.reportOn)) {
        Text(stringResource(R.string.send), fontSize = 17.sp, fontWeight = FontWeight.Black)
    }
}

/** "Kenapa tak ikut laluan?" (AduanLencong): asked only when stopped; nothing is sent for jam / own choice. */
@Composable
fun DeviationSheet(d: Deviation, onAnswer: (answer: String?, neverAgain: Boolean) -> Unit) {
    val c = Gimano.colors
    var never by remember { mutableStateOf(false) }
    val labels = mapOf("closed" to R.string.dev_closed, "no_road" to R.string.dev_no_road, "oneway" to R.string.dev_oneway,
        "no_turn" to R.string.dev_no_turn, "jam" to R.string.dev_jam, "own_choice" to R.string.dev_own_choice)
    ModalBottomSheet(onDismissRequest = { onAnswer(null, never) }, sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true), containerColor = c.surface) {
        Column(Modifier.fillMaxWidth().padding(start = 16.dp, end = 16.dp, bottom = 24.dp)) {
            Text(stringResource(R.string.dev_title), fontSize = 22.sp, fontWeight = FontWeight.Black, color = c.text)
            Text(d.road?.let { stringResource(R.string.dev_body, it) } ?: stringResource(R.string.dev_body_noroad), fontSize = 15.sp, color = c.textMuted,
                modifier = Modifier.padding(top = 6.dp, bottom = 12.dp))
            IssueSupport.deviationAnswers.chunked(2).forEach { row ->
                Row(Modifier.fillMaxWidth().padding(bottom = 8.dp), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    row.forEach { a ->
                        OutlinedButton(onClick = { onAnswer(a, never) }, modifier = Modifier.weight(1f).height(54.dp), shape = RoundedCornerShape(Radius.md)) {
                            Text(stringResource(labels.getValue(a)), fontWeight = FontWeight.ExtraBold, fontSize = 15.sp, textAlign = TextAlign.Center)
                        }
                    }
                }
            }
            Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.fillMaxWidth().clickable { never = !never }.padding(vertical = 6.dp)) {
                Checkbox(never, { never = it })
                Text(stringResource(R.string.dev_never), fontWeight = FontWeight.Bold, color = c.text)
            }
            Text(stringResource(R.string.dev_privacy), fontSize = 13.sp, color = c.textMuted)
        }
    }
}

/** "Masih ditutup?" in the alert-ahead spot while driving. */
@Composable
fun StillClosedCard(i: Issue, onAnswer: (String?) -> Unit, modifier: Modifier = Modifier) {
    // "kind · street · age" (canvas NavSahkan); 10 s, then it goes away with no answer (as does tapping the ring).
    my.gimano.app.ui.common.ConfirmCard(
        key = i.id,
        title = stringResource(R.string.still_closed_q),
        subtitle = confirmLine(i.kind, i.subtype, i.road, i.createdAt),
        options = listOf(
            my.gimano.app.ui.common.ConfirmOption(stringResource(R.string.still_closed_yes), my.gimano.app.ui.common.ConfirmIcons.yes, my.gimano.app.ui.common.ConfirmStyle.SOLID) { onAnswer("still") },
            my.gimano.app.ui.common.ConfirmOption(stringResource(R.string.still_closed_open), my.gimano.app.ui.common.ConfirmIcons.cleared, my.gimano.app.ui.common.ConfirmStyle.PALE) { onAnswer("cleared") },
            my.gimano.app.ui.common.ConfirmOption(stringResource(R.string.not_sure), my.gimano.app.ui.common.ConfirmIcons.unsure, my.gimano.app.ui.common.ConfirmStyle.OUTLINED) { onAnswer("unsure") },
        ),
        onTimeout = { onAnswer(null) },
        modifier = modifier,
    ) {
        Box(Modifier.size(52.dp).clip(RoundedCornerShape(16.dp)).background(Amber), contentAlignment = Alignment.Center) {
            Icon(Icons.Filled.Block, null, tint = AmberInk, modifier = Modifier.size(30.dp))
        }
    }
}

@Composable
private fun kindWord(kind: String): String = when (kind) {
    IssueKind.ROAD_CLOSED_TEMP -> stringResource(R.string.issue_kind_road_closed_temp)
    IssueKind.ROAD_NOT_EXIST -> stringResource(R.string.issue_kind_road_not_exist)
    IssueKind.ONEWAY_CLOSED_DIR -> stringResource(R.string.issue_kind_oneway_wrong_closed_dir)
    IssueKind.TURN_NOT_ALLOWED -> stringResource(R.string.issue_kind_turn_not_allowed)
    else -> stringResource(R.string.issue_kind_road_closed_temp)
}

@Composable
private fun subtypeWord(sub: String?): String? = when (sub) {
    "accident" -> stringResource(R.string.issue_sub_accident)
    "flood" -> stringResource(R.string.issue_sub_flood)
    "event" -> stringResource(R.string.issue_sub_event)
    "roadworks" -> stringResource(R.string.issue_sub_roadworks)
    else -> null
}

/** "ditutup (banjir) · disahkan 3 pemandu · 2 j lalu". */
@Composable
private fun issueLine(kind: String, subtype: String?, road: String?, state: String, confirmations: Double, createdAt: String?): String {
    val ms = currentLang() == Lang.MS
    val what = kindWord(kind) + (subtypeWord(subtype)?.let { " ($it)" } ?: "")
    val n = IssueText.drivers(confirmations)
    val conf = if (state == "confirmed" && n > 0) stringResource(R.string.confirmed_by_n, n) else stateWord(state)
    return listOfNotNull(road, what, conf, IssueText.age(createdAt, Instant.now(), ms)).joinToString(" · ")
}

/** Confirm card subtitle: "Tak boleh belok · Jalan SS 2/3 · 5 jam lalu". */
@Composable
private fun confirmLine(kind: String, subtype: String?, road: String?, createdAt: String?): String {
    val ms = currentLang() == Lang.MS
    val what = kindWord(kind) + (subtypeWord(subtype)?.let { " ($it)" } ?: "")
    return listOfNotNull(what, road, IssueText.age(createdAt, Instant.now(), ms)).joinToString(" · ").replaceFirstChar { it.uppercase() }
}

@Composable
private fun stateWord(state: String): String = when (state) {
    "confirmed" -> stringResource(R.string.issue_state_confirmed)
    "reported" -> stringResource(R.string.issue_state_reported)
    else -> stringResource(R.string.issue_state_suspected)
}

/** Route preview (AduanElak): "Mengelak {road}: ditutup (…) · disahkan N pemandu · 2 j lalu" + Butiran + "Lalu juga". */
@Composable
fun RouteIssueBanner(issues: List<RouteIssue>, ignored: Set<String>, onPassAnyway: (String) -> Unit) {
    val shown = IssueText.bannerIssues(issues).filter { it.id !in ignored }.take(2)
    if (shown.isEmpty()) return
    var details by remember { mutableStateOf<RouteIssue?>(null) }
    val ms = currentLang() == Lang.MS
    shown.forEach { i ->
        val road = i.road ?: stringResource(R.string.a_road)
        val what = kindWord(i.kind) + (subtypeWord(i.subtype)?.let { " ($it)" } ?: "")
        val n = IssueText.drivers(i.confirmations)
        val tail = listOfNotNull(if (i.state == "confirmed" && n > 0) stringResource(R.string.confirmed_by_n, n) else stateWord(i.state),
            IssueText.age(i.lastEvidenceAt ?: i.createdAt, Instant.now(), ms)).joinToString(" · ")
        Column(Modifier.fillMaxWidth().padding(bottom = 10.dp).clip(RoundedCornerShape(14.dp)).background(Amber).padding(12.dp)) {
            Row(verticalAlignment = Alignment.Top) {
                Icon(if (i.isAvoided) Icons.Filled.AltRoute else Icons.Filled.Warning, null, tint = AmberInk, modifier = Modifier.size(22.dp))
                Spacer(Modifier.width(10.dp))
                Text(
                    (if (i.isAvoided) stringResource(R.string.avoiding_banner, road, what) else stringResource(R.string.reported_on_route, road, what)) + " · " + tail,
                    color = AmberInk, fontSize = 14.sp, fontWeight = FontWeight.ExtraBold,
                )
            }
            Row(Modifier.padding(top = 4.dp), horizontalArrangement = Arrangement.spacedBy(4.dp)) {
                TextButton(onClick = { details = i }) { Text(stringResource(R.string.details), color = AmberInk, fontWeight = FontWeight.Black) }
                if (i.isAvoided) TextButton(onClick = { onPassAnyway(i.id) }) { Text(stringResource(R.string.pass_anyway), color = AmberInk, fontWeight = FontWeight.Black) }
            }
        }
    }
    details?.let { i ->
        AlertDialog(
            onDismissRequest = { details = null },
            title = { Text(i.road ?: stringResource(R.string.a_road), fontWeight = FontWeight.Black) },
            text = {
                Column {
                    Text(issueLine(i.kind, i.subtype, null, i.state, i.confirmations, i.lastEvidenceAt ?: i.createdAt), fontWeight = FontWeight.Bold)
                    i.summary?.let { Text(it, Modifier.padding(top = 8.dp)) }
                    if (i.isAvoided) Text(stringResource(R.string.pass_anyway_note), Modifier.padding(top = 8.dp), color = Gimano.colors.textMuted)
                }
            },
            confirmButton = {
                if (i.isAvoided) TextButton(onClick = { details = null; onPassAnyway(i.id) }) { Text(stringResource(R.string.pass_anyway), fontWeight = FontWeight.Black) }
                else TextButton(onClick = { details = null }) { Text(stringResource(R.string.ok)) }
            },
            dismissButton = if (i.isAvoided) ({ TextButton(onClick = { details = null }) { Text(stringResource(R.string.close)) } }) else null,
        )
    }
}

/** Badges on the place card (AduanTempat). The "reported closed" one asks for a vote. */
@Composable
fun PlaceIssueBadges(issues: List<Issue>, onVote: (Issue, String) -> Unit) {
    if (issues.isEmpty()) return
    val c = Gimano.colors
    var ask by remember { mutableStateOf<Issue?>(null) }
    Column(Modifier.padding(top = 8.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
        issues.forEach { i ->
            val text = i.summary?.takeIf { it.isNotBlank() } ?: when (i.kind) {
                IssueKind.PLACE_CLOSED_PERM -> stringResource(R.string.badge_reported_closed)
                IssueKind.PLACE_CLOSED_TEMP -> i.untilDate?.take(10)?.let { d -> runCatching { LocalDate.parse(d) }.getOrNull() }
                    ?.let { stringResource(R.string.badge_closed_until, my.gimano.app.core.format.Formatters.shortDate(it, currentLang())) }
                    ?: stringResource(R.string.badge_closed_temp)
                IssueKind.PLACE_HOURS_WRONG -> stringResource(R.string.badge_hours_changed)
                else -> null
            } ?: return@forEach
            Row(
                Modifier.clip(RoundedCornerShape(999.dp)).background(Amber)
                    .then(if (i.kind == IssueKind.PLACE_CLOSED_PERM) Modifier.clickable { ask = i } else Modifier)
                    .padding(horizontal = 12.dp, vertical = 7.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Icon(Icons.Filled.Info, null, tint = AmberInk, modifier = Modifier.size(18.dp))
                Spacer(Modifier.width(6.dp))
                Text(text, color = AmberInk, fontSize = 14.sp, fontWeight = FontWeight.ExtraBold)
            }
        }
    }
    ask?.let { i ->
        AlertDialog(
            onDismissRequest = { ask = null },
            title = { Text(stringResource(R.string.place_still_open_q), fontWeight = FontWeight.Black) },
            text = {
                Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    Button(onClick = { ask = null; onVote(i, "cleared") }, Modifier.fillMaxWidth()) { Text(stringResource(R.string.place_vote_open), fontWeight = FontWeight.ExtraBold) }
                    OutlinedButton(onClick = { ask = null; onVote(i, "still") }, Modifier.fillMaxWidth()) { Text(stringResource(R.string.place_vote_closed), fontWeight = FontWeight.ExtraBold) }
                    TextButton(onClick = { ask = null; onVote(i, "unsure") }, Modifier.fillMaxWidth()) { Text(stringResource(R.string.not_sure)) }
                }
            },
            confirmButton = {},
        )
    }
}

/** "Cadangkan suntingan": the six options. */
@Composable
fun PlaceSuggestSheet(
    onDismiss: () -> Unit,
    onClosedPerm: () -> Unit,
    onClosedTemp: (LocalDate) -> Unit,
    onHours: (String) -> Unit,
    onEntrance: () -> Unit,
    onInfo: () -> Unit,
    onDuplicate: (String?) -> Unit,
) {
    val c = Gimano.colors
    var step by remember { mutableStateOf("menu") }
    ModalBottomSheet(onDismissRequest = onDismiss, sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true), containerColor = c.surface) {
        Column(Modifier.fillMaxWidth().verticalScroll(rememberScrollState()).padding(start = 16.dp, end = 16.dp, bottom = 24.dp)) {
            when (step) {
                "menu" -> {
                    Text(stringResource(R.string.suggest_edit), fontSize = 21.sp, fontWeight = FontWeight.Black, color = c.text, modifier = Modifier.padding(bottom = 8.dp))
                    SuggestRow(Icons.Filled.Block, stringResource(R.string.suggest_closed_perm)) { onClosedPerm() }
                    SuggestRow(Icons.Filled.EventBusy, stringResource(R.string.suggest_closed_temp)) { step = "temp" }
                    SuggestRow(Icons.Filled.Schedule, stringResource(R.string.suggest_hours)) { step = "hours" }
                    SuggestRow(Icons.Filled.LocalParking, stringResource(R.string.suggest_entrance)) { onEntrance() }
                    SuggestRow(Icons.Filled.Edit, stringResource(R.string.suggest_info)) { onInfo() }
                    SuggestRow(Icons.Filled.ContentCopy, stringResource(R.string.suggest_duplicate)) { step = "dup" }
                }
                "temp" -> {
                    val today = LocalDate.now()
                    val max = today.plusDays(IssueText.MAX_TEMP_CLOSED_DAYS)
                    val zone = ZoneId.of("UTC")
                    val state = rememberDatePickerState(
                        initialSelectedDateMillis = today.plusDays(7).atStartOfDay(zone).toInstant().toEpochMilli(),
                        selectableDates = object : SelectableDates {
                            override fun isSelectableDate(utcTimeMillis: Long): Boolean {
                                val d = Instant.ofEpochMilli(utcTimeMillis).atZone(zone).toLocalDate()
                                return !d.isBefore(today) && !d.isAfter(max)
                            }
                        },
                    )
                    Text(stringResource(R.string.closed_until_pick), fontSize = 20.sp, fontWeight = FontWeight.Black, color = c.text)
                    DatePicker(state, showModeToggle = false, title = null, headline = null)
                    Button(onClick = { state.selectedDateMillis?.let { onClosedTemp(Instant.ofEpochMilli(it).atZone(zone).toLocalDate()) } },
                        enabled = state.selectedDateMillis != null, modifier = Modifier.fillMaxWidth().height(54.dp), shape = RoundedCornerShape(Radius.md)) {
                        Text(stringResource(R.string.send), fontWeight = FontWeight.Black)
                    }
                }
                "hours" -> {
                    var draft by remember { mutableStateOf(my.gimano.app.ui.contribute.HoursDraft()) }
                    Text(stringResource(R.string.suggest_hours), fontSize = 20.sp, fontWeight = FontWeight.Black, color = c.text)
                    my.gimano.app.ui.contribute.HoursFields(draft) { f -> draft = f(draft) }
                    val osm = draft.osm
                    if (osm.isNotBlank()) Text(osm, fontSize = 13.sp, color = c.textMuted, modifier = Modifier.padding(top = 4.dp))
                    Button(onClick = { onHours(osm) }, enabled = osm.isNotBlank(), modifier = Modifier.fillMaxWidth().padding(top = 8.dp).height(54.dp), shape = RoundedCornerShape(Radius.md)) {
                        Text(stringResource(R.string.send), fontWeight = FontWeight.Black)
                    }
                }
                "dup" -> {
                    var other by remember { mutableStateOf("") }
                    Text(stringResource(R.string.suggest_duplicate), fontSize = 20.sp, fontWeight = FontWeight.Black, color = c.text)
                    OutlinedTextField(other, { other = it.take(120) }, Modifier.fillMaxWidth().padding(vertical = 8.dp), placeholder = { Text(stringResource(R.string.duplicate_hint)) }, singleLine = true)
                    Button(onClick = { onDuplicate(other.trim().ifBlank { null }) }, modifier = Modifier.fillMaxWidth().height(54.dp), shape = RoundedCornerShape(Radius.md)) {
                        Text(stringResource(R.string.send), fontWeight = FontWeight.Black)
                    }
                }
            }
        }
    }
}

@Composable
private fun SuggestRow(icon: ImageVector, label: String, onClick: () -> Unit) {
    val c = Gimano.colors
    Row(Modifier.fillMaxWidth().heightIn(min = 56.dp).clickable(onClick = onClick).padding(vertical = 6.dp), verticalAlignment = Alignment.CenterVertically) {
        Box(Modifier.size(42.dp).clip(RoundedCornerShape(14.dp)).background(c.brandMist), contentAlignment = Alignment.Center) {
            Icon(icon, null, tint = c.brandInk, modifier = Modifier.size(24.dp))
        }
        Spacer(Modifier.width(14.dp))
        Text(label, fontSize = 17.sp, fontWeight = FontWeight.ExtraBold, color = c.text)
    }
}
