package my.gimano.app.ui.search

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalSoftwareKeyboardController
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import my.gimano.app.R
import my.gimano.app.core.format.Formatters
import my.gimano.app.data.model.PlaceSummary
import my.gimano.app.ui.MainViewModel
import my.gimano.app.ui.SearchPurpose
import my.gimano.app.ui.UiState
import my.gimano.app.ui.common.CategoryBadge
import my.gimano.app.ui.common.Divider
import my.gimano.app.ui.common.GIcons
import my.gimano.app.ui.common.GIcon
import my.gimano.app.ui.common.CategoryGlyph
import my.gimano.app.ui.theme.Sizes
import my.gimano.app.ui.home.PlaceRow
import my.gimano.app.ui.home.RecentRow
import my.gimano.app.ui.theme.Gimano
import my.gimano.app.ui.theme.Radius

private val quickCategories = listOf(
    "fuel" to R.string.cat_fuel, "parking" to R.string.cat_parking, "restaurant" to R.string.cat_food,
    "ev_charging" to R.string.cat_ev, "mosque" to R.string.cat_mosque, "rest_area" to R.string.cat_rest_area,
    "hospital" to R.string.cat_hospital,
)

@Composable
fun SearchScreen(ui: UiState, purpose: SearchPurpose, vm: MainViewModel, onMic: () -> Unit) {
    // Distances only from a real fix (otherwise they would be from the map view).
    val hasFix = vm.myFreshLocation() != null
    val c = Gimano.colors
    val focus = remember { FocusRequester() }
    val kb = LocalSoftwareKeyboardController.current
    LaunchedEffect(Unit) { focus.requestFocus() }
    Column(
        Modifier.fillMaxSize().background(c.surface).windowInsetsPadding(WindowInsets.statusBars).imePadding(),
    ) {
        val title = when (purpose) {
            SearchPurpose.SET_HOME -> R.string.set_home_title
            SearchPurpose.SET_WORK -> R.string.set_work_title
            SearchPurpose.ADD_STOP -> R.string.add_stop_title
            SearchPurpose.ADD_FAVORITE -> R.string.add_favorite_title
            SearchPurpose.ADD_STOP_PREVIEW -> R.string.add_stop_title
            SearchPurpose.PLAN_DRIVE -> R.string.plan_a_drive
            SearchPurpose.SET_ORIGIN -> R.string.change_start
            SearchPurpose.ENTRANCE -> R.string.suggest_entrance
            SearchPurpose.EVENT_STOP -> R.string.host_stop_search
            SearchPurpose.EVENT_ENTRANCE -> R.string.host_entrance_pick
            SearchPurpose.NAVIGATE -> null
        }
        Row(Modifier.fillMaxWidth().padding(start = 4.dp, end = 12.dp, top = 8.dp, bottom = 8.dp), verticalAlignment = Alignment.CenterVertically) {
            IconButton(onClick = vm::back) { Icon(Icons.AutoMirrored.Filled.ArrowBack, stringResource(R.string.back), tint = c.text) }
            TextField(
                value = ui.query,
                onValueChange = vm::onQuery,
                modifier = Modifier.weight(1f).heightIn(min = Sizes.searchField).focusRequester(focus),
                leadingIcon = { GIcon("search", null, size = 26.dp) },
                textStyle = LocalTextStyle.current.copy(fontSize = 18.sp, fontWeight = FontWeight.ExtraBold),
                placeholder = { Text(if (title != null) stringResource(title) else stringResource(R.string.search_hint), color = c.textMuted) },
                singleLine = true,
                shape = RoundedCornerShape(Radius.search),
                colors = TextFieldDefaults.colors(
                    focusedContainerColor = c.surfaceAlt, unfocusedContainerColor = c.surfaceAlt,
                    focusedIndicatorColor = Color.Transparent, unfocusedIndicatorColor = Color.Transparent,
                    cursorColor = c.brand,
                ),
                trailingIcon = {
                    if (ui.query.isNotEmpty()) IconButton(onClick = { vm.onQuery("") }) { Icon(Icons.Filled.Close, stringResource(R.string.close)) }
                    else IconButton(onClick = onMic) { GIcon("mic", stringResource(R.string.voice_search), size = 26.dp) }
                },
                // No keyboard autocorrect: place names aren't dictionary words ("famly mart" → server corrects; "Damansara" stays).
                keyboardOptions = KeyboardOptions(imeAction = ImeAction.Search, autoCorrectEnabled = false, capitalization = androidx.compose.ui.text.input.KeyboardCapitalization.None),
                keyboardActions = KeyboardActions(onSearch = { kb?.hide() }),
            )
        }
        if (ui.searching) LinearProgressIndicator(Modifier.fillMaxWidth().height(2.dp), color = c.brand, trackColor = c.surfaceAlt)
        else Spacer(Modifier.height(2.dp))

        if (ui.searchViewport != null) Text(stringResource(R.string.search_area_scope), modifier = Modifier.padding(16.dp))
        val showingResults = ui.query.isNotBlank() || ui.activeCategory != null
        val noResults = vm.canAddPlaceFromSearch() && ui.activeCategory == null
        if (noResults) {
            NoResults(ui, vm, onPick = { kb?.hide(); vm.openPickOnMap() }, onAdd = { kb?.hide(); vm.addPlaceFromSearch() })
            return@Column
        }
        Box(Modifier.fillMaxSize()) {
        LazyColumn(Modifier.fillMaxSize(), contentPadding = PaddingValues(bottom = (if (showingResults) 110.dp else 24.dp) + WindowInsets.navigationBars.asPaddingValues().calculateBottomPadding())) {
            if (ui.query.isBlank()) {
                item {
        LazyRow(contentPadding = PaddingValues(horizontal = 16.dp, vertical = 10.dp), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                        items(quickCategories) { (cat, label) ->
                            FilterChip(
                                selected = ui.activeCategory == cat,
                                onClick = { vm.searchCategory(cat) },
                                label = { Text(stringResource(label)) },
                                leadingIcon = { CategoryGlyph(cat, 22.dp) },
                                shape = RoundedCornerShape(Radius.pill),
                                colors = FilterChipDefaults.filterChipColors(selectedContainerColor = c.brandMist, selectedLabelColor = c.brandInk),
                                modifier = Modifier.height(40.dp),
                            )
                        }
                    }
                }
            }
            if (!showingResults) {
                item { SectionTitle(stringResource(R.string.recents)) }
                items(ui.recents.filter { r -> ui.searchViewport?.let { my.gimano.app.core.geo.SearchArea.contains(it, r.lat, r.lng) } ?: true }, key = { "r" + it.id }) { r ->
                    RecentRow(r, ui.myLocation?.point) {
                        vm.pickResult(PlaceSummary(r.placeId ?: "pin:${r.lat},${r.lng}", r.name, "other", r.address, r.lat, r.lng))
                    }
                }
            } else {
                if (ui.searchFailed && ui.results.isEmpty()) item {
                    Row(Modifier.padding(16.dp).fillMaxWidth().clip(RoundedCornerShape(16.dp)).background(c.surfaceAlt).padding(14.dp), verticalAlignment = Alignment.CenterVertically) {
                        Text(stringResource(R.string.search_failed), Modifier.weight(1f), fontWeight = FontWeight.Bold, color = c.text)
                        TextButton(onClick = vm::retrySearch) { Text(stringResource(R.string.retry), fontWeight = FontWeight.Black) }
                    }
                }
                if (ui.results.isNotEmpty()) item { SortChips(ui, vm) }
                ui.correctedQuery?.let { cq ->
                    item {
                        Row(Modifier.padding(horizontal = 16.dp, vertical = 4.dp).fillMaxWidth().clip(RoundedCornerShape(16.dp)).background(Color(0xFFFFF6DB))
                            .clickable { vm.searchExact() }.padding(horizontal = 14.dp, vertical = 10.dp)) {
                            Text(
                                androidx.compose.ui.text.buildAnnotatedString {
                                    append(stringResource(R.string.search_corrected, cq)); append(" · ")
                                    pushStyle(androidx.compose.ui.text.SpanStyle(color = c.brand)); append(stringResource(R.string.search_exact, ui.query.trim())); pop()
                                },
                                fontSize = 14.sp, fontWeight = FontWeight.ExtraBold, color = Color(0xFF4A3600),
                            )
                        }
                    }
                }
                // On-device matches (favourites, private places) come first.
                items(ui.localHits, key = { "l" + it.id }) { h ->
                    Column {
                        PlaceRow(h.icon, h.name, h.address, ui.myLocation?.point?.let { Formatters.distance(my.gimano.app.core.geo.GeoMath.distanceM(it, my.gimano.app.core.geo.GeoPoint(h.lat, h.lng))) },
                            onClick = { kb?.hide(); vm.pickLocal(h) },
                            leading = { my.gimano.app.ui.home.IconTile { if (h.kind == "private") Icon(Icons.Filled.Lock, null, tint = c.brand) else GIcon(h.icon, null, size = 26.dp) } })
                        Divider(Modifier.padding(start = 70.dp))
                    }
                }
                val sort = if (ui.activeCategory != null) my.gimano.app.core.search.ResultSort.NEAREST else ui.resultSort
                val rows = my.gimano.app.core.search.ResultGrouping.rows(ui.results, sort)
                if (sort == my.gimano.app.core.search.ResultSort.OPEN_NOW && rows.isEmpty() && ui.results.isNotEmpty()) item {
                    Text(stringResource(R.string.open_now_unknown), Modifier.padding(24.dp), color = c.textMuted, fontWeight = FontWeight.Bold)
                }
                rows.forEach { row ->
                    when (row) {
                        is my.gimano.app.core.search.ResultRow.Single -> item(key = "s" + row.place.id) { ResultRow(row.place, hasFix) { kb?.hide(); vm.pickResult(row.place) } }
                        is my.gimano.app.core.search.ResultRow.Chain -> item(key = "g" + row.key) { ChainGroup(row, hasFix) { p -> kb?.hide(); vm.pickResult(p) } }
                    }
                }
            }
        }
        if (showingResults) {
            // "Pilih pada peta": always a way out of a search (secondary while there are results).
            OutlinedPickButton(Modifier.align(Alignment.BottomCenter).padding(16.dp).navigationBarsPadding()) { kb?.hide(); vm.openPickOnMap() }
        }
        }
    }
}

@Composable
private fun SortChips(ui: UiState, vm: MainViewModel) {
    val c = Gimano.colors
    Row(Modifier.padding(horizontal = 16.dp, vertical = 8.dp), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        listOf(
            my.gimano.app.core.search.ResultSort.NEAREST to R.string.sort_nearest,
            my.gimano.app.core.search.ResultSort.RELEVANT to R.string.sort_relevant,
            my.gimano.app.core.search.ResultSort.OPEN_NOW to R.string.sort_open_now,
        ).forEach { (s, l) ->
            val on = ui.resultSort == s
            Text(stringResource(l), Modifier.height(36.dp).clip(RoundedCornerShape(999.dp)).background(if (on) c.brand else c.brandMist)
                .clickable { vm.setResultSort(s) }.padding(horizontal = 14.dp, vertical = 8.dp),
                fontSize = 13.sp, fontWeight = FontWeight.Black, color = if (on) c.brandOn else c.brandInk)
        }
    }
}

@Composable
private fun ChainGroup(g: my.gimano.app.core.search.ResultRow.Chain, hasFix: Boolean, onPick: (PlaceSummary) -> Unit) {
    val c = Gimano.colors
    var open by rememberSaveable(g.key) { mutableStateOf(false) }
    Column {
        Row(Modifier.padding(horizontal = 16.dp, vertical = 4.dp).fillMaxWidth().clip(RoundedCornerShape(20.dp)).background(c.surfaceAlt)
            .clickable { open = !open }.padding(horizontal = 14.dp, vertical = 12.dp), verticalAlignment = Alignment.CenterVertically) {
            CategoryBadge(g.nearest.category)
            Spacer(Modifier.width(12.dp))
            Column(Modifier.weight(1f)) {
                Text(g.name, fontSize = 17.sp, fontWeight = FontWeight.Black, color = c.text)
                Text(stringResource(R.string.chain_nearby, maxOf(g.countNearby ?: 0, g.branches.size)), fontSize = 13.sp, fontWeight = FontWeight.ExtraBold, color = c.textMuted)
            }
            g.nearest.distanceM?.takeIf { hasFix }?.let { Text(Formatters.distance(it), fontSize = 15.sp, fontWeight = FontWeight.Black, color = c.brand) }
            Icon(if (open) Icons.Filled.ExpandLess else Icons.Filled.ExpandMore, null, tint = c.brand)
        }
        if (open) g.branches.forEach { p ->
            Row(Modifier.fillMaxWidth().clickable { onPick(p) }.padding(start = 78.dp, end = 20.dp, top = 12.dp, bottom = 12.dp), verticalAlignment = Alignment.CenterVertically) {
                Column(Modifier.weight(1f)) {
                    Text(p.name, fontSize = 15.sp, fontWeight = FontWeight.Black, color = c.text)
                    if (p.address.isNotBlank()) Text(p.address, fontSize = 13.sp, fontWeight = FontWeight.Bold, color = c.textMuted, maxLines = 1)
                }
                p.distanceM?.takeIf { hasFix }?.let { Text(Formatters.distance(it), fontSize = 15.sp, fontWeight = FontWeight.Black, color = c.brand) }
            }
            Divider(Modifier.padding(start = 78.dp))
        }
    }
}

@Composable
private fun OutlinedPickButton(modifier: Modifier, onClick: () -> Unit) {
    val c = Gimano.colors
    Row(modifier.fillMaxWidth().height(64.dp).clip(RoundedCornerShape(20.dp)).background(c.brandMist).clickable(onClick = onClick),
        horizontalArrangement = Arrangement.Center, verticalAlignment = Alignment.CenterVertically) {
        Icon(Icons.Filled.Map, null, tint = c.brandInk, modifier = Modifier.size(26.dp)); Spacer(Modifier.width(10.dp))
        Text(stringResource(R.string.pick_on_map), fontSize = 18.sp, fontWeight = FontWeight.Black, color = c.brandInk)
    }
}

/** Canvas CariTiada: never a dead end. */
@Composable
private fun NoResults(ui: UiState, vm: MainViewModel, onPick: () -> Unit, onAdd: () -> Unit) {
    val hasFix = vm.myFreshLocation() != null
    val c = Gimano.colors
    Column(Modifier.fillMaxSize().navigationBarsPadding().padding(horizontal = 16.dp)) {
        Column(Modifier.weight(1f).verticalScroll(rememberScrollState()).padding(top = 32.dp), horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(12.dp)) {
            Icon(Icons.Filled.SearchOff, null, tint = c.brandTint, modifier = Modifier.size(96.dp))
            Text(if (ui.searchViewport != null) stringResource(R.string.no_results_area) else stringResource(R.string.no_results_title, ui.query.trim()), fontSize = 22.sp, fontWeight = FontWeight.Black, color = c.text, textAlign = androidx.compose.ui.text.style.TextAlign.Center)
            Text(if (ui.searchViewport != null) stringResource(R.string.search_area_scope) else stringResource(R.string.no_results_body), fontSize = 15.sp, fontWeight = FontWeight.Bold, color = c.textMuted, textAlign = androidx.compose.ui.text.style.TextAlign.Center)
            if (ui.suggestions.isNotEmpty()) {
                Spacer(Modifier.height(12.dp))
                Text(stringResource(R.string.did_you_mean), Modifier.fillMaxWidth(), fontSize = 14.sp, fontWeight = FontWeight.Black, color = c.textMuted)
                @OptIn(androidx.compose.foundation.layout.ExperimentalLayoutApi::class)
                FlowRow(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(8.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    ui.suggestions.take(6).forEach { s ->
                        val extra = s.count?.let { " · $it" } ?: s.distanceM?.takeIf { hasFix }?.let { " · " + Formatters.distance(it) } ?: ""
                        Text(s.label + extra, Modifier.height(40.dp).clip(RoundedCornerShape(999.dp)).background(c.brandMist).clickable { vm.pickSuggestion(s) }
                            .padding(horizontal = 14.dp, vertical = 10.dp), fontSize = 14.sp, fontWeight = FontWeight.Black, color = c.brandInk)
                    }
                }
            }
        }
        Row(Modifier.fillMaxWidth().height(72.dp).clip(RoundedCornerShape(20.dp)).background(c.brand).clickable(onClick = onPick),
            horizontalArrangement = Arrangement.Center, verticalAlignment = Alignment.CenterVertically) {
            Icon(Icons.Filled.Map, null, tint = c.brandOn, modifier = Modifier.size(28.dp)); Spacer(Modifier.width(10.dp))
            Text(stringResource(R.string.pick_on_map), fontSize = 19.sp, fontWeight = FontWeight.Black, color = c.brandOn)
        }
        Spacer(Modifier.height(10.dp))
        Box(Modifier.fillMaxWidth().height(56.dp).clip(RoundedCornerShape(18.dp)).background(c.surfaceAlt).clickable(onClick = onAdd), contentAlignment = Alignment.Center) {
            Text(stringResource(R.string.add_missing_place), fontSize = 16.sp, fontWeight = FontWeight.Black, color = c.brandInk)
        }
        Spacer(Modifier.height(16.dp))
    }
}

@Composable
private fun SectionTitle(t: String) {
    Text(t, Modifier.padding(horizontal = 16.dp, vertical = 10.dp), fontWeight = FontWeight.SemiBold, fontSize = 15.sp, color = Gimano.colors.textMuted)
}

@Composable
private fun ResultRow(p: PlaceSummary, hasFix: Boolean, onClick: () -> Unit) {
    Column {
        PlaceRow(
            "map", p.name, p.address,
            p.distanceM?.takeIf { hasFix }?.let { Formatters.distance(it) }, onClick,
            leading = { CategoryBadge(p.category) },
            badge = if (p.source == "community") stringResource(if (p.status == "published") R.string.community else R.string.unverified) else null,
        )
        Divider(Modifier.padding(start = 70.dp))
    }
}
