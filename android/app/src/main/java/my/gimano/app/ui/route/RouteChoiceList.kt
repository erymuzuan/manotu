package my.gimano.app.ui.route

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.pluralStringResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.selected
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import my.gimano.app.R
import my.gimano.app.core.format.Formatters
import my.gimano.app.core.trip.RouteChoices
import my.gimano.app.core.trip.TollBadge
import my.gimano.app.data.model.Route
import my.gimano.app.ui.MainViewModel
import my.gimano.app.ui.RoutePlan
import my.gimano.app.ui.common.Labels
import my.gimano.app.ui.report.currentLang
import my.gimano.app.ui.theme.Gimano
import my.gimano.app.ui.theme.Radius

// Route options before a drive (design RoPilihan / RoBanding / RoPendek / RoSatu).

private val TollTagBg = Color(0xFFFFE7C7)
private val TollTagInk = Color(0xFF7A4100)
private val RoadTagBg = Color(0xFFD6F2E8)
private val RoadTagInk = Color(0xFF0B4A3A)
private val Worse = Color(0xFF9A3412)
private val Better = Color(0xFF0B5D45)

/** The list: every shown route as a card; with another route picked, it grows a comparison and the rest shrink to rows. */
@Composable
internal fun RouteChoiceList(plan: RoutePlan, vm: MainViewModel) {
    val c = Gimano.colors
    val shown = RouteChoices.shown(plan.routes)
    val fastest = shown.firstOrNull() ?: plan.routes.firstOrNull() ?: return
    val selected = plan.selected
    val altPicked = selected != null && selected.id != fastest.id
    Column(Modifier.fillMaxWidth().heightIn(max = 430.dp).verticalScroll(rememberScrollState()), verticalArrangement = Arrangement.spacedBy(8.dp)) {
        Text(pluralStringResource(R.plurals.route_count_n, plan.visibleRoutes.size, plan.visibleRoutes.size),
            fontSize = 18.sp, fontWeight = FontWeight.Black, color = c.text, modifier = Modifier.padding(horizontal = 4.dp))
        plan.visibleRoutes.forEach { r ->
            val isSel = r.id == selected?.id
            if (altPicked && !isSel) CompactRow(r, fastest) { vm.selectRoute(r.id) }
            else RouteCard(r, fastest, shown, isSel, expanded = isSel && altPicked, plan, vm)
        }
        val hidden = RouteChoices.hidden(plan.routes)
        if (hidden.isNotEmpty() && !plan.showHidden) HiddenRow(hidden, vm)
    }
}

@Composable
private fun RouteCard(r: Route, fastest: Route, shown: List<Route>, selected: Boolean, expanded: Boolean, plan: RoutePlan, vm: MainViewModel) {
    val c = Gimano.colors
    val lang = currentLang()
    val shape = RoundedCornerShape(18.dp)
    Row(
        Modifier.fillMaxWidth().clip(shape)
            .background(if (selected) c.brandMist else c.surface)
            .border(2.dp, if (selected) c.brand else c.outline.copy(alpha = 0.6f), shape)
            .clickable(role = Role.RadioButton) { vm.selectRoute(r.id) }
            .semantics { this.selected = selected }
            .testTag("routeCard")
            .padding(horizontal = 12.dp, vertical = 10.dp),
    ) {
        Box(Modifier.width(6.dp).heightIn(min = 56.dp).fillMaxHeight().clip(RoundedCornerShape(Radius.pill)).background(if (selected) c.brand else c.textMuted.copy(alpha = 0.5f)))
        Spacer(Modifier.width(10.dp))
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(3.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text(Formatters.duration(r.effectiveDurationS, lang), fontSize = if (selected) 24.sp else 22.sp, fontWeight = FontWeight.Black,
                    color = if (selected) c.brand else c.text)
                Spacer(Modifier.width(8.dp))
                Tags(r, Modifier.weight(1f))
                Text(Formatters.distance(r.distanceM), fontSize = 14.sp, fontWeight = FontWeight.ExtraBold, color = c.textMuted)
            }
            Text(listOfNotNull(tollText(r), r.summary.ifBlank { null }).joinToString(" · "), fontSize = 14.sp, fontWeight = FontWeight.Bold,
                color = c.text, maxLines = 1, overflow = TextOverflow.Ellipsis,
                modifier = if (selected && r.tolls.isNotEmpty()) Modifier.clickable { vm.cancelCountdown(); vm.openTolls(r) } else Modifier)
            val cmp = RouteChoices.compare(r, fastest, shown)
            val third = when {
                r.id == fastest.id -> listOfNotNull(
                    if (plan.mode.isMotorised) Labels.traffic(r.trafficDescription) else null,
                    if (r.alerts.isNotEmpty()) stringResource(R.string.reports_on_route, r.alerts.size) else null,
                ).joinToString(" · ")
                expanded -> ""
                else -> compareLine(cmp)
            }
            if (third.isNotBlank()) Text(third, fontSize = 13.sp, fontWeight = FontWeight.Bold, color = c.textMuted)
            if (expanded) CompareTiles(cmp, r)
        }
    }
}

@Composable
private fun Tags(r: Route, modifier: Modifier) {
    val c = Gimano.colors
    Row(modifier, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
        val tags = r.reasons.orEmpty().take(2).ifEmpty { listOfNotNull(r.hidden?.let { "hidden_$it" }) }
        tags.forEach { t ->
            val (bg, ink, label) = when (t) {
                "fastest" -> Triple(c.brand, c.brandOn, stringResource(R.string.reason_fastest))
                "shortest" -> Triple(c.surfaceAlt, c.brandInk, stringResource(R.string.reason_shortest))
                "lower_toll" -> Triple(TollTagBg, TollTagInk, stringResource(R.string.reason_lower_toll))
                "no_tolls" -> Triple(TollTagBg, TollTagInk, stringResource(R.string.reason_no_tolls))
                "fewer_reports" -> Triple(RoadTagBg, RoadTagInk, stringResource(R.string.reason_fewer_reports))
                "other_main_road" -> Triple(RoadTagBg, RoadTagInk, stringResource(R.string.reason_other_main_road))
                "hidden_same_road" -> Triple(c.surfaceAlt, c.textMuted, stringResource(R.string.hidden_same_road))
                "hidden_slower" -> Triple(c.surfaceAlt, c.textMuted, stringResource(R.string.hidden_slower))
                "hidden_worse" -> Triple(c.surfaceAlt, c.textMuted, stringResource(R.string.hidden_worse))
                else -> return@forEach
            }
            Text(label, Modifier.clip(RoundedCornerShape(8.dp)).background(bg).padding(horizontal = 8.dp, vertical = 2.dp),
                fontSize = 12.sp, fontWeight = FontWeight.Black, color = ink, maxLines = 1, overflow = TextOverflow.Ellipsis)
        }
    }
}

@Composable
private fun CompareTiles(cmp: RouteChoices.Compare, r: Route) {
    val c = Gimano.colors
    val lang = currentLang()
    Text(stringResource(R.string.compared_with_fastest).uppercase(), fontSize = 12.sp, fontWeight = FontWeight.Black, color = c.brandInk,
        modifier = Modifier.padding(top = 4.dp))
    Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(6.dp)) {
        val time = if (cmp.extraS >= 60) "+" + Formatters.duration(cmp.extraS, lang) to stringResource(R.string.tile_slower)
            else "=" to stringResource(R.string.tile_same_time)
        Tile(time.first, time.second, if (cmp.extraS >= 60) Worse else c.text, Modifier.weight(1f))
        when {
            cmp.tollSavedMyr != null -> Tile(TollBadge.rm(cmp.tollSavedMyr), stringResource(R.string.tile_less_toll), Better, Modifier.weight(1f))
            cmp.tollExtraMyr != null -> Tile(TollBadge.rm(cmp.tollExtraMyr), stringResource(R.string.tile_more_toll), Worse, Modifier.weight(1f))
            else -> Tile("=", stringResource(R.string.tile_same_toll), c.text, Modifier.weight(1f))
        }
        when {
            cmp.shorterM != null -> Tile(Formatters.distance(cmp.shorterM), stringResource(R.string.tile_shorter), Better, Modifier.weight(1f))
            cmp.longerM != null -> Tile(Formatters.distance(cmp.longerM), stringResource(R.string.tile_longer), Worse, Modifier.weight(1f))
            else -> Spacer(Modifier.weight(1f))
        }
    }
    if (r.alerts.isNotEmpty()) Text(stringResource(R.string.reports_on_route, r.alerts.size), fontSize = 13.sp, fontWeight = FontWeight.Bold, color = c.textMuted)
}

@Composable
private fun Tile(value: String, label: String, colour: Color, modifier: Modifier) {
    val c = Gimano.colors
    Column(modifier.clip(RoundedCornerShape(12.dp)).background(c.surface).padding(8.dp)) {
        Text(value, fontSize = 17.sp, fontWeight = FontWeight.Black, color = colour, maxLines = 1)
        Text(label, fontSize = 12.sp, fontWeight = FontWeight.Bold, color = c.textMuted, maxLines = 1)
    }
}

@Composable
private fun CompactRow(r: Route, fastest: Route, onClick: () -> Unit) {
    val c = Gimano.colors
    val lang = currentLang()
    val shape = RoundedCornerShape(16.dp)
    Row(
        Modifier.fillMaxWidth().heightIn(min = 52.dp).clip(shape).background(c.surface).border(2.dp, c.outline.copy(alpha = 0.6f), shape)
            .clickable(role = Role.RadioButton, onClick = onClick).testTag("routeRow").padding(horizontal = 12.dp, vertical = 6.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Box(Modifier.size(6.dp, 30.dp).clip(RoundedCornerShape(Radius.pill)).background(c.textMuted.copy(alpha = 0.5f)))
        Spacer(Modifier.width(10.dp))
        Text(Formatters.duration(r.effectiveDurationS, lang), fontSize = 18.sp, fontWeight = FontWeight.Black, color = c.text)
        Spacer(Modifier.width(10.dp))
        val reason = r.reasons.orEmpty().firstOrNull()?.let { reasonLabel(it) }
        Text(listOfNotNull(reason, viaOf(r), tollText(r)).joinToString(" · "), fontSize = 13.sp, fontWeight = FontWeight.Bold, color = c.textMuted,
            maxLines = 1, overflow = TextOverflow.Ellipsis)
    }
}

@Composable
private fun HiddenRow(hidden: List<Route>, vm: MainViewModel) {
    val c = Gimano.colors
    val lang = currentLang()
    val one = hidden.singleOrNull()
    val detail = one?.let { r ->
        val why = when (r.hidden) {
            "same_road" -> stringResource(R.string.hidden_same_road)
            "slower" -> stringResource(R.string.hidden_slower)
            else -> stringResource(R.string.hidden_worse)
        }
        ": " + Formatters.duration(r.effectiveDurationS, lang) + ", " + why
    }.orEmpty()
    Row(Modifier.fillMaxWidth().heightIn(min = 44.dp).clickable { vm.showHiddenRoutes() }.padding(horizontal = 4.dp), verticalAlignment = Alignment.CenterVertically) {
        Text(pluralStringResource(R.plurals.hidden_routes_n, hidden.size, hidden.size) + detail, Modifier.weight(1f),
            fontSize = 13.sp, fontWeight = FontWeight.Bold, color = c.textMuted)
        Text(stringResource(R.string.show_anyway), fontSize = 14.sp, fontWeight = FontWeight.Black, color = c.brand, modifier = Modifier.padding(start = 8.dp))
    }
}

/** Short trips (design RoPendek): "2 other routes · +6 min via FT20 · …", Show opens the list and stops the countdown. */
@Composable
internal fun OtherRoutesRow(plan: RoutePlan, vm: MainViewModel) {
    val c = Gimano.colors
    val lang = currentLang()
    val shown = RouteChoices.shown(plan.routes)
    val fastest = shown.firstOrNull() ?: return
    val others = shown.filter { it.id != plan.selected?.id }
    if (shown.size < 2 || others.isEmpty()) return
    val shape = RoundedCornerShape(16.dp)
    Row(
        Modifier.padding(top = 10.dp).fillMaxWidth().heightIn(min = 52.dp).clip(shape).background(c.background).border(2.dp, c.outline.copy(alpha = 0.6f), shape)
            .clickable { vm.openRouteList() }.testTag("otherRoutes").padding(horizontal = 12.dp, vertical = 6.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Column(Modifier.weight(1f)) {
            Text(pluralStringResource(R.plurals.other_routes_n, others.size, others.size), fontSize = 16.sp, fontWeight = FontWeight.Black, color = c.text)
            val line = others.joinToString(" · ") { r ->
                val d = r.effectiveDurationS - fastest.effectiveDurationS
                val t = if (r.id == fastest.id) Formatters.duration(r.effectiveDurationS, lang) else "+" + Formatters.duration(d.coerceAtLeast(60.0), lang)
                // Same road name as the fastest says nothing: show the distance instead.
                val road = viaOf(r)?.takeIf { it != viaOf(fastest) } ?: Formatters.distance(r.distanceM)
                "$t $road"
            }
            Text(line, fontSize = 13.sp, fontWeight = FontWeight.Bold, color = c.textMuted, maxLines = 1, overflow = TextOverflow.Ellipsis)
        }
        Text(stringResource(R.string.show_routes), fontSize = 14.sp, fontWeight = FontWeight.Black, color = c.brand)
    }
}

/** "Start · 43 min via E5" in the list; null keeps "Go now". */
@Composable
internal fun startLabel(plan: RoutePlan): String? {
    if (!plan.listMode) return null
    val r = plan.selected ?: return null
    val time = Formatters.duration(r.effectiveDurationS, currentLang())
    return viaOf(r)?.let { stringResource(R.string.start_route, time, it) } ?: stringResource(R.string.start_route_short, time)
}

@Composable
private fun compareLine(cmp: RouteChoices.Compare): String {
    val lang = currentLang()
    val and = stringResource(R.string.cmp_and)
    return listOfNotNull(
        "+" + Formatters.duration(cmp.extraS.coerceAtLeast(60.0), lang),
        cmp.tollSavedMyr?.let { stringResource(R.string.cmp_saves, TollBadge.rm(it)) },
        cmp.tollExtraMyr?.let { stringResource(R.string.cmp_more_toll, TollBadge.rm(it)) },
        cmp.shorterM?.let { stringResource(R.string.cmp_shorter, Formatters.distance(it)) },
        cmp.longerM?.let { stringResource(R.string.cmp_longer, Formatters.distance(it)) },
        cmp.avoids.takeIf { it.isNotEmpty() }?.let { stringResource(R.string.cmp_avoids, it.take(2).joinToString(" $and ")) },
    ).joinToString(" · ")
}

@Composable
private fun tollText(r: Route): String? = when {
    r.vehicle == "bicycle" || r.vehicle == "walk" -> null
    !r.hasTolls -> stringResource(R.string.route_no_tolls)
    r.tollFareComplete && r.tollEstimateMyr != null -> stringResource(R.string.route_toll, TollBadge.rm(r.tollEstimateMyr))
    r.tollEstimateMyr != null -> stringResource(R.string.route_toll_from, TollBadge.rm(r.tollEstimateMyr))
    else -> null
}

@Composable
private fun reasonLabel(code: String): String? = when (code) {
    "fastest" -> stringResource(R.string.reason_fastest)
    "shortest" -> stringResource(R.string.reason_shortest)
    "lower_toll" -> stringResource(R.string.reason_lower_toll)
    "no_tolls" -> stringResource(R.string.reason_no_tolls)
    "fewer_reports" -> stringResource(R.string.reason_fewer_reports)
    "other_main_road" -> stringResource(R.string.reason_other_main_road)
    else -> null
}

/** The road a route is known by: its own main road, else the first road of "Via E5 …". */
private fun viaOf(r: Route): String? {
    r.viaRoads.orEmpty().firstOrNull()?.let { return it }
    val first = r.summary.removePrefix("Via ").substringBefore(",").trim()
    val ref = first.substringBefore(" ")
    return (if (ROAD_REF.matches(ref)) ref else first).ifBlank { null }
}

private val ROAD_REF = Regex("^(AH|FT|[A-Z])?\\d{1,4}[A-Z]?$")
