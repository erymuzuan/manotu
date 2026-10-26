package my.gimano.app.ui.contribute

import android.net.Uri
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.PickVisualMediaRequest
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.selected
import my.gimano.app.ui.safety.icon
import my.gimano.app.ui.safety.tileLabel
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.core.content.FileProvider
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import coil3.compose.AsyncImage
import kotlinx.coroutines.delay
import my.gimano.app.R
import my.gimano.app.core.places.OpeningHours
import my.gimano.app.core.places.OpeningHours.Range
import my.gimano.app.ui.common.CategoryGlyph
import my.gimano.app.ui.common.Labels
import my.gimano.app.ui.common.SheetSurface
import my.gimano.app.ui.map.MapHandle
import my.gimano.app.ui.theme.Gimano
import my.gimano.app.ui.theme.GimanoType
import my.gimano.app.ui.theme.Radius
import java.io.File

/** Categories offered in the big icon grid (docs/api.md "Place categories"). */
val PLACE_CATEGORIES = listOf(
    "restaurant", "cafe", "fast_food", "fuel", "ev_charging", "parking", "mosque", "surau", "rest_area", "mall", "supermarket", "convenience",
    "hospital", "clinic", "pharmacy", "school", "hotel", "atm", "bank", "car_repair", "car_wash", "police", "temple", "church",
    "tourism", "transit_station", "toll_booth", "university", "government", "airport", "other",
)

val AMENITIES = listOf("toilets", "surau", "parking", "wifi", "card_payment", "ewallet", "wheelchair", "air_conditioning", "ev_charging", "atm", "food", "air_pump")

@Composable
fun AddPlaceScreen(cvm: ContributeViewModel, handle: MapHandle, onBack: () -> Unit) {
    val s by cvm.add.collectAsStateWithLifecycle()
    when (s.step) {
        AddStep.PIN -> PinStep(s, cvm, handle, onBack)
        AddStep.DETAILS -> DetailsStep(s, cvm)
        AddStep.WARNINGS -> WarningsStep(s, cvm)
        AddStep.VISIBILITY -> VisibilityStep(s, cvm)
    }
    // The AI gate (A1, A3, the answers, B1, B5, B6, C1) covers the form; the form stays behind it for "Edit and try again".
    AddPlaceOverlayScreen(s, cvm)
    // docs/safety.md §4 A: a public pin in a restricted area gets this sheet instead of the form.
    if (s.blockedSheet) my.gimano.app.ui.safety.BlockedPinSheet(onMove = cvm::blockedMove, onPrivate = cvm::blockedPrivate, onCancel = cvm::blockedCancel)
}

@Composable
private fun TopBar(title: String, onBack: () -> Unit) {
    val c = Gimano.colors
    Surface(color = c.surface, shadowElevation = 6.dp) {
        Row(Modifier.fillMaxWidth().windowInsetsPadding(WindowInsets.statusBars).padding(4.dp), verticalAlignment = Alignment.CenterVertically) {
            IconButton(onClick = onBack) { Icon(Icons.AutoMirrored.Filled.ArrowBack, stringResource(R.string.back), tint = c.text) }
            Text(title, style = GimanoType.title, color = c.text, maxLines = 1, overflow = TextOverflow.Ellipsis)
        }
    }
}

/** Step 1: the map moves under a fixed centre pin. */
@Composable
private fun PinStep(s: AddPlaceState, cvm: ContributeViewModel, handle: MapHandle, onBack: () -> Unit) {
    val c = Gimano.colors
    LaunchedEffect(handle.cameraVersion) {
        delay(250)
        handle.bounds()?.center?.let { cvm.onPinMoved(it) }
    }
    Box(Modifier.fillMaxSize()) {
        Column(Modifier.align(Alignment.TopStart).fillMaxWidth()) { TopBar(stringResource(R.string.move_map_to_place), onBack) }
        Icon(
            Icons.Filled.Place, stringResource(R.string.place_pin), tint = c.report,
            modifier = Modifier.align(Alignment.Center).size(56.dp).offset(y = (-28).dp),
        )
        Box(Modifier.align(Alignment.Center).size(8.dp).clip(CircleShape).background(c.navBanner))
        SheetSurface(Modifier.align(Alignment.BottomCenter).fillMaxWidth()) {
            Column(Modifier.padding(16.dp).windowInsetsPadding(WindowInsets.navigationBars)) {
                Text(s.address.ifBlank { "%.5f, %.5f".format(s.pin.lat, s.pin.lng) }, fontSize = 16.sp, fontWeight = FontWeight.Bold, color = c.text)
                Spacer(Modifier.height(12.dp))
                Button(onClick = cvm::nextFromPin, Modifier.fillMaxWidth().height(56.dp), shape = RoundedCornerShape(Radius.md),
                    colors = ButtonDefaults.buttonColors(containerColor = c.brand, contentColor = c.brandOn)) { Text(stringResource(R.string.next), style = GimanoType.button) }
            }
        }
    }
}

/** Step 2: name, category, optional details, opening hours, photos. */
@OptIn(ExperimentalLayoutApi::class)
@Composable
private fun DetailsStep(s: AddPlaceState, cvm: ContributeViewModel) {
    val c = Gimano.colors
    val context = LocalContext.current
    var cameraUri by remember { mutableStateOf<Uri?>(null) }
    val pick = rememberLauncherForActivityResult(ActivityResultContracts.PickMultipleVisualMedia(10)) { cvm.addPhotos(it) }
    val camera = rememberLauncherForActivityResult(ActivityResultContracts.TakePicture()) { ok ->
        val u = cameraUri
        if (ok && u != null) cvm.addPhotos(listOf(u)) else if (u != null) my.gimano.app.data.places.PhotoPrep.deleteIfCameraTemp(context, u)
    }
    Column(Modifier.fillMaxSize().background(c.background)) {
        // Opened from My places or the Inbox the map isn't at the pin, so back leaves instead of moving it.
        TopBar(stringResource(R.string.add_a_place)) { if (s.fromList) cvm.finish() else cvm.step(AddStep.PIN) }
        Column(Modifier.weight(1f).verticalScroll(rememberScrollState()).padding(16.dp).imePadding()) {
            // B: near a restricted area (public): the note, no photos, a moderator checks it first.
            if (s.nearArea) my.gimano.app.ui.safety.NearRestrictedNote(Modifier.padding(bottom = 12.dp))
            OutlinedTextField(s.name, { v -> cvm.update { it.copy(name = v.take(80)) } }, Modifier.fillMaxWidth(), singleLine = true,
                label = { Text(stringResource(R.string.place_name_required)) }, shape = RoundedCornerShape(Radius.md),
                textStyle = LocalTextStyle.current.copy(fontSize = 18.sp, fontWeight = FontWeight.ExtraBold))
            // C: security details in a public name (a private place never leaves the phone).
            if (!s.privateOnly && cvm.sensitive.hasMatch(s.name)) my.gimano.app.ui.safety.SensitiveWordsWarning({ cvm.removeSensitive("name") }, Modifier.padding(top = 6.dp))
            Section(stringResource(R.string.category))
            PLACE_CATEGORIES.chunked(4).forEach { row ->
                Row(Modifier.fillMaxWidth().padding(vertical = 4.dp), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    row.forEach { cat ->
                        val sel = s.category == cat
                        val label = Labels.category(cat)
                        Column(
                            Modifier.weight(1f).clip(RoundedCornerShape(Radius.tile)).background(if (sel) c.brandMist else c.surface)
                                .then(if (sel) Modifier.border(2.dp, c.brand, RoundedCornerShape(Radius.tile)) else Modifier)
                                .clickable { cvm.update { it.copy(category = cat) } }.semantics { contentDescription = label }.padding(vertical = 10.dp),
                            horizontalAlignment = Alignment.CenterHorizontally,
                        ) {
                            CategoryGlyph(cat, 34.dp)
                            Text(label, fontSize = 11.sp, fontWeight = FontWeight.ExtraBold, color = c.text, maxLines = 1, overflow = TextOverflow.Ellipsis, modifier = Modifier.padding(top = 4.dp, start = 2.dp, end = 2.dp))
                        }
                    }
                    repeat(4 - row.size) { Spacer(Modifier.weight(1f)) }
                }
            }
            Section(stringResource(R.string.photos))
            val photosOn = !s.nearArea
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                OutlinedButton(enabled = photosOn, onClick = {
                    val f = my.gimano.app.data.places.PhotoPrep.newCameraFile(context)
                    cameraUri = my.gimano.app.data.places.PhotoPrep.cameraUri(context, f)
                    camera.launch(cameraUri!!)
                }, shape = RoundedCornerShape(Radius.md)) { Icon(Icons.Filled.PhotoCamera, null); Spacer(Modifier.width(6.dp)); Text(stringResource(R.string.camera), fontWeight = FontWeight.ExtraBold) }
                OutlinedButton(enabled = photosOn, onClick = { pick.launch(PickVisualMediaRequest(ActivityResultContracts.PickVisualMedia.ImageOnly)) }, shape = RoundedCornerShape(Radius.md)) {
                    Icon(Icons.Filled.PhotoLibrary, null); Spacer(Modifier.width(6.dp)); Text(stringResource(R.string.gallery), fontWeight = FontWeight.ExtraBold)
                }
            }
            if (!photosOn) Text(stringResource(R.string.restricted_b_photos_off), fontSize = 13.sp, fontWeight = FontWeight.Bold, color = c.textMuted, modifier = Modifier.padding(top = 4.dp))
            if (s.photos.isNotEmpty()) LazyRow(horizontalArrangement = Arrangement.spacedBy(8.dp), modifier = Modifier.padding(top = 8.dp)) {
                items(s.photos) { u ->
                    Box {
                        AsyncImage(u, null, Modifier.size(84.dp).clip(RoundedCornerShape(Radius.md)), contentScale = ContentScale.Crop)
                        Box(Modifier.align(Alignment.TopEnd).padding(4.dp).size(26.dp).clip(CircleShape).background(c.surface).clickable { cvm.removePhoto(u) }, contentAlignment = Alignment.Center) {
                            Icon(Icons.Filled.Close, stringResource(R.string.remove_stop), Modifier.size(16.dp))
                        }
                    }
                }
            }
            Section(stringResource(R.string.optional_details))
            OutlinedTextField(s.phone, { v -> cvm.update { it.copy(phone = v.take(30)) } }, Modifier.fillMaxWidth(), singleLine = true, label = { Text(stringResource(R.string.phone)) },
                keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Phone), shape = RoundedCornerShape(Radius.md))
            OutlinedTextField(s.website, { v -> cvm.update { it.copy(website = v.take(200)) } }, Modifier.fillMaxWidth().padding(top = 6.dp), singleLine = true, label = { Text(stringResource(R.string.website)) },
                keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Uri), shape = RoundedCornerShape(Radius.md))
            OutlinedTextField(s.description, { v -> cvm.update { it.copy(description = v.take(500)) } }, Modifier.fillMaxWidth().padding(top = 6.dp), minLines = 2, label = { Text(stringResource(R.string.description)) }, shape = RoundedCornerShape(Radius.md))
            if (!s.privateOnly && cvm.sensitive.hasMatch(s.description)) my.gimano.app.ui.safety.SensitiveWordsWarning({ cvm.removeSensitive("description") }, Modifier.padding(top = 6.dp))
            Section(stringResource(R.string.amenities))
            FlowRow(horizontalArrangement = Arrangement.spacedBy(6.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
                AMENITIES.forEach { a ->
                    FilterChip(selected = a in s.amenities, onClick = { cvm.update { it.copy(amenities = if (a in it.amenities) it.amenities - a else it.amenities + a) } },
                        label = { Text(my.gimano.app.ui.common.Labels.amenity(a)) }, shape = RoundedCornerShape(Radius.pill))
                }
            }
            HoursEditor(s, cvm)
            Spacer(Modifier.height(80.dp))
        }
        Surface(color = c.surface, shadowElevation = 8.dp) {
            Button(onClick = { cvm.step(AddStep.WARNINGS) }, enabled = s.canContinue,
                modifier = Modifier.fillMaxWidth().padding(16.dp).windowInsetsPadding(WindowInsets.navigationBars).height(56.dp), shape = RoundedCornerShape(Radius.md),
                colors = ButtonDefaults.buttonColors(containerColor = c.brand, contentColor = c.brandOn)) { Text(stringResource(R.string.next), style = GimanoType.button) }
        }
    }
}

/** Day chips + time ranges, "Open 24 hours", "Closed" → OSM opening_hours. */
@Composable
private fun HoursEditor(s: AddPlaceState, cvm: ContributeViewModel) {
    val c = Gimano.colors
    Row(Modifier.fillMaxWidth().padding(top = 16.dp), verticalAlignment = Alignment.CenterVertically) {
        Text(stringResource(R.string.opening_hours), fontWeight = FontWeight.Black, fontSize = 16.sp, color = c.text, modifier = Modifier.weight(1f))
        Switch(s.hoursEnabled, { v -> cvm.update { it.copy(hoursEnabled = v) } }, colors = SwitchDefaults.colors(checkedTrackColor = c.brand))
    }
    if (!s.hoursEnabled) return
    HoursFields(HoursDraft(s.week, s.open247)) { f -> cvm.update { st -> f(HoursDraft(st.week, st.open247)).let { d -> st.copy(week = d.week, open247 = d.open247) } } }
    s.hours?.let { Text(it, fontSize = 13.sp, color = c.textMuted, modifier = Modifier.padding(top = 4.dp)) }
}

/** Week + "Open 24 hours" being edited (add a place, "Waktu buka salah"). */
data class HoursDraft(val week: Map<String, List<Range>> = emptyMap(), val open247: Boolean = false) {
    val osm: String get() = OpeningHours.build(week, open247)
}

/** "Open 24 hours" switch, day rows with time ranges, "copy Monday" and the time picker. */
@Composable
fun HoursFields(draft: HoursDraft, update: ((HoursDraft) -> HoursDraft) -> Unit) {
    val c = Gimano.colors
    var editing by remember { mutableStateOf<Triple<String, Int, Boolean>?>(null) }   // day, range index, editing "from"?
    Row(verticalAlignment = Alignment.CenterVertically) {
        Text(stringResource(R.string.open_24h), Modifier.weight(1f), fontWeight = FontWeight.Bold, color = c.text)
        Switch(draft.open247, { v -> update { it.copy(open247 = v) } }, colors = SwitchDefaults.colors(checkedTrackColor = c.brand))
    }
    if (!draft.open247) {
        OpeningHours.DAYS.forEach { d ->
            val ranges = draft.week[d].orEmpty()
            Row(Modifier.fillMaxWidth().padding(vertical = 3.dp), verticalAlignment = Alignment.CenterVertically) {
                Text(my.gimano.app.ui.common.Labels.day(d), Modifier.width(44.dp), fontWeight = FontWeight.Black, color = c.text)
                if (ranges.isEmpty()) {
                    Text(stringResource(R.string.closed), Modifier.weight(1f), color = c.textMuted)
                    TextButton(onClick = { update { it.copy(week = it.week + (d to listOf(Range("09:00", "18:00")))) } }) { Text(stringResource(R.string.open_verb)) }
                } else {
                    Column(Modifier.weight(1f)) {
                        ranges.forEachIndexed { i, r ->
                            Row(verticalAlignment = Alignment.CenterVertically) {
                                TextButton(onClick = { editing = Triple(d, i, true) }) { Text(r.from, fontWeight = FontWeight.Black) }
                                Text("–")
                                TextButton(onClick = { editing = Triple(d, i, false) }) { Text(r.to, fontWeight = FontWeight.Black) }
                                if (i == ranges.lastIndex && ranges.size < 3) IconButton(onClick = {
                                    update { it.copy(week = it.week + (d to ranges + Range("14:00", "18:00".takeIf { r.to < "14:00" } ?: "23:00"))) }
                                }, Modifier.size(36.dp)) { Icon(Icons.Filled.Add, stringResource(R.string.add_range), Modifier.size(18.dp)) }
                            }
                        }
                    }
                    TextButton(onClick = { update { it.copy(week = it.week - d) } }) { Text(stringResource(R.string.closed)) }
                }
            }
        }
        TextButton(onClick = { update { st -> st.copy(week = st.week + OpeningHours.DAYS.take(5).associateWith { st.week["Mo"].orEmpty() }) } }) {
            Text(stringResource(R.string.copy_monday), fontWeight = FontWeight.Bold)
        }
    }
    editing?.let { (d, i, from) ->
        val r = draft.week[d].orEmpty().getOrNull(i) ?: run { editing = null; return }
        val t = (if (from) r.from else r.to).let { if (it == "24:00") "00:00" else it }
        val st = rememberTimePickerState(t.substring(0, 2).toInt(), t.substring(3).toInt(), is24Hour = true)
        AlertDialog(
            onDismissRequest = { editing = null },
            confirmButton = {
                TextButton(onClick = {
                    val v = "%02d:%02d".format(st.hour, st.minute)
                    val nr = runCatching { if (from) Range(v, r.to) else Range(r.from, if (v == "00:00") "24:00" else v) }.getOrNull()
                    if (nr != null) update { it.copy(week = it.week + (d to it.week[d].orEmpty().toMutableList().also { l -> l[i] = nr })) }
                    editing = null
                }) { Text(stringResource(R.string.ok)) }
            },
            text = { TimePicker(st) },
        )
    }
}

/**
 * Step 3: "Anything people should know?" Four big tiles (alcohol, gambling, cigarettes · vape, none) and a live preview of
 * the warning the place page will show. Sent as `warnings[]` on POST /places; a private place never leaves the phone.
 */
@Composable
private fun WarningsStep(s: AddPlaceState, cvm: ContributeViewModel) {
    val c = Gimano.colors
    Column(Modifier.fillMaxSize().background(c.background)) {
        TopBar(stringResource(R.string.cs_know_title)) { cvm.step(AddStep.DETAILS) }
        Column(Modifier.weight(1f).verticalScroll(rememberScrollState()).padding(16.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
            val tiles = my.gimano.app.core.safety.PlaceWarning.entries
            (tiles.map<my.gimano.app.core.safety.PlaceWarning, my.gimano.app.core.safety.PlaceWarning?> { it } + null).chunked(2).forEach { row ->
                Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                    row.forEach { w ->
                        val on = if (w == null) s.warnings.isEmpty() else w in s.warnings
                        val label = stringResource(w?.tileLabel() ?: R.string.cs_know_none)
                        Column(
                            Modifier.weight(1f).heightIn(min = 132.dp).clip(RoundedCornerShape(Radius.lg))
                                .background(if (on) (if (w == null) c.brandMist else my.gimano.app.ui.safety.warnTile()) else c.surface)
                                .border(if (on) 3.dp else 1.dp, if (on) (if (w == null) c.brand else my.gimano.app.ui.safety.warnInk()) else c.outline, RoundedCornerShape(Radius.lg))
                                .semantics(mergeDescendants = true) { selected = on }
                                .clickable(onClickLabel = label) {
                                    cvm.update { st -> st.copy(warnings = if (w == null) emptySet() else if (w in st.warnings) st.warnings - w else st.warnings + w) }
                                }.padding(12.dp),
                            horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.Center,
                        ) {
                            Icon(w?.icon() ?: Icons.Filled.CheckCircle, null, modifier = Modifier.size(56.dp),
                                tint = if (on) (if (w == null) c.brand else my.gimano.app.ui.safety.warnInk()) else c.textMuted)
                            Text(label, Modifier.padding(top = 8.dp), fontSize = 16.sp, fontWeight = FontWeight.ExtraBold, color = c.text,
                                textAlign = androidx.compose.ui.text.style.TextAlign.Center)
                        }
                    }
                }
            }
            // Live preview: what the place page will say.
            val previewCd = stringResource(R.string.cs_know_preview_cd)
            if (s.warnings.isNotEmpty()) Column(Modifier.semantics(mergeDescendants = true) { contentDescription = previewCd }) {
                my.gimano.app.ui.safety.WarningBanner(my.gimano.app.core.safety.PlaceWarning.entries.filter { it in s.warnings })
            }
        }
        Surface(color = c.surface, shadowElevation = 8.dp) {
            Button(onClick = { cvm.step(AddStep.VISIBILITY) },
                modifier = Modifier.fillMaxWidth().padding(16.dp).windowInsetsPadding(WindowInsets.navigationBars).height(56.dp), shape = RoundedCornerShape(Radius.md),
                colors = ButtonDefaults.buttonColors(containerColor = c.brand, contentColor = c.brandOn)) { Text(stringResource(R.string.next), style = GimanoType.button) }
        }
    }
}

/** Step 4: "Just for me" or "Share with everyone". */
@Composable
private fun VisibilityStep(s: AddPlaceState, cvm: ContributeViewModel) {
    val c = Gimano.colors
    Column(Modifier.fillMaxSize().background(c.background)) {
        TopBar(stringResource(R.string.who_can_see)) { cvm.step(AddStep.WARNINGS) }
        Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(14.dp)) {
            Text(s.name, style = GimanoType.title, color = c.text)
            BigChoice(Icons.Filled.Lock, stringResource(R.string.just_for_me), stringResource(R.string.just_for_me_desc), enabled = !s.saving) { cvm.savePrivate() }
            // After A's "Simpan untuk saya sahaja" there is no public choice. B/C: held, so it says "Hantar untuk semakan".
            // A2: shared places get the automatic check, then people nearby confirm them.
            if (!s.privateOnly) BigChoice(Icons.Filled.Groups,
                stringResource(if (cvm.willBeHeld(s)) R.string.restricted_send_review else R.string.share_everyone),
                stringResource(R.string.apg_share_hint), enabled = !s.saving) { cvm.savePublic() }
            if (s.saving) LinearProgressIndicator(Modifier.fillMaxWidth(), color = c.brand, trackColor = c.surfaceAlt)
            s.error?.let { Text(it, color = c.report, fontWeight = FontWeight.Bold) }
        }
    }
}

@Composable
private fun BigChoice(icon: androidx.compose.ui.graphics.vector.ImageVector, title: String, desc: String, enabled: Boolean, onClick: () -> Unit) {
    val c = Gimano.colors
    Row(
        Modifier.fillMaxWidth().clip(RoundedCornerShape(Radius.lg)).background(c.surface).clickable(enabled = enabled, onClick = onClick).padding(18.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Box(Modifier.size(64.dp).clip(RoundedCornerShape(Radius.tile)).background(c.brandMist), contentAlignment = Alignment.Center) { Icon(icon, null, tint = c.brand, modifier = Modifier.size(36.dp)) }
        Spacer(Modifier.width(14.dp))
        Column {
            Text(title, fontSize = 19.sp, fontWeight = FontWeight.Black, color = c.text)
            Text(desc, fontSize = 14.sp, color = c.textMuted)
        }
    }
}

@Composable
private fun Section(t: String) {
    Text(t, Modifier.padding(top = 18.dp, bottom = 6.dp), fontWeight = FontWeight.Black, fontSize = 16.sp, color = Gimano.colors.text)
}
