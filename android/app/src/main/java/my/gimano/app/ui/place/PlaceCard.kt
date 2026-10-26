package my.gimano.app.ui.place

import android.net.Uri
import androidx.activity.compose.BackHandler
import androidx.compose.animation.core.Spring
import androidx.compose.animation.core.animate
import androidx.compose.animation.core.spring
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.gestures.Orientation
import androidx.compose.foundation.gestures.draggable
import androidx.compose.foundation.gestures.rememberDraggableState
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.pager.HorizontalPager
import androidx.compose.foundation.pager.rememberPagerState
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.graphics.vector.rememberVectorPainter
import androidx.compose.ui.input.nestedscroll.NestedScrollConnection
import androidx.compose.ui.input.nestedscroll.NestedScrollSource
import androidx.compose.ui.input.nestedscroll.nestedScroll
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.layout.onSizeChanged
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.res.pluralStringResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.collapse
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.expand
import androidx.compose.ui.semantics.selected
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.buildAnnotatedString
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.text.withStyle
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.Velocity
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import coil3.compose.AsyncImage
import kotlinx.coroutines.Job
import kotlinx.coroutines.launch
import my.gimano.app.R
import my.gimano.app.core.format.Formatters
import my.gimano.app.core.places.RatingSummary
import my.gimano.app.core.places.Verification
import my.gimano.app.core.safety.ContentGate
import my.gimano.app.core.safety.ContentState
import my.gimano.app.core.safety.PlaceWarning
import my.gimano.app.core.safety.ReviewPrefilter
import my.gimano.app.core.safety.ReviewState
import my.gimano.app.ui.safety.*
import my.gimano.app.data.model.Photo
import my.gimano.app.data.model.Place
import my.gimano.app.data.model.Review
import my.gimano.app.data.model.SuggestEditRequest
import my.gimano.app.ui.MainViewModel
import my.gimano.app.ui.PlaceSel
import my.gimano.app.ui.common.Attribution
import my.gimano.app.ui.common.CategoryBadge
import my.gimano.app.ui.common.GIcon
import my.gimano.app.ui.common.GrabHandle
import my.gimano.app.ui.common.Labels
import my.gimano.app.ui.common.RoundFab
import my.gimano.app.ui.common.SheetSurface
import my.gimano.app.ui.common.TwoTone
import my.gimano.app.ui.common.TwoToneIcon
import my.gimano.app.ui.common.TwoTonePalette
import my.gimano.app.ui.contribute.ContributeViewModel
import my.gimano.app.ui.contribute.UploadItem
import my.gimano.app.ui.theme.Gimano
import my.gimano.app.ui.theme.GimanoType
import my.gimano.app.ui.theme.Radius
import java.util.Locale
import kotlin.math.abs
import kotlin.math.roundToInt

/** Absolute URL for a media path (the API may return `/media/<key>.webp`). */
fun mediaUrl(url: String, apiBase: String): String =
    if (url.startsWith("/")) Regex("^(https?://[^/]+)").find(apiBase)?.value.orEmpty() + url else url

private val StarGold = Color(0xFFF5B301)
private val StarPale = Color(0xFFF9D77A)

/**
 * Place card (canvas "Place card from search"): two states, [PlaceSheetState].
 * - PEEK (default, ≤ 40 % of the screen): name, the rating line, category · address · open, Routes, and
 *   Save · Call · Share · Website.
 * - FULL (swipe up): + details, reviews (average, 5→1 bars, latest review, Write a review), photos with
 *   "Add photo" at the end, and Suggest an edit.
 * The resting height goes to [MainViewModel.setPlaceSheetDp], so the map centres the pin in the map left visible.
 */
@Composable
fun PlaceCard(sel: PlaceSel, vm: MainViewModel, cvm: ContributeViewModel, apiBase: String, modifier: Modifier = Modifier) =
    BoxWithConstraints(modifier.fillMaxSize()) {
    val c = Gimano.colors
    val p = sel.summary
    val d = sel.detail
    val priv = sel.privatePlace
    val density = LocalDensity.current
    val screenH = maxHeight.value
    val navInset = WindowInsets.navigationBars.asPaddingValues().calculateBottomPadding().value
    val statusInset = WindowInsets.statusBars.asPaddingValues().calculateTopPadding().value
    val reviews by cvm.reviews.collectAsStateWithLifecycle()
    val uiState by vm.ui.collectAsState()
    var viewer by remember { mutableStateOf<ViewerState?>(null) }
    var reportPlace by remember { mutableStateOf(false) }
    // Blocked authors (this phone only): their reviews and photos are hidden everywhere.
    val blockedList by vm.container.blocks.blocked.collectAsStateWithLifecycle()
    val blocked = remember(blockedList) { blockedList.mapTo(HashSet()) { it.ref } }
    val openPhotos: (List<Photo>, Int) -> Unit = { list, i ->
        viewer = ViewerState(list.map { mediaUrl(it.url, apiBase) }, i, list)
    }
    var suggest by remember { mutableStateOf(false) }
    LaunchedEffect(d?.id) { if (d != null) cvm.loadReviews(d) }
    // B1 "Yes, that's it: suggest an edit": opens this place's suggest-an-edit once its details are in.
    val suggestFor by cvm.suggestFor.collectAsStateWithLifecycle()
    LaunchedEffect(suggestFor, d?.id) {
        if (suggestFor != null && d?.id == suggestFor) { suggest = true; cvm.suggestFor.value = null }
    }
    val addPhoto = my.gimano.app.ui.common.rememberPhotoSource(10) { uris ->
        if (d != null && uris.isNotEmpty()) cvm.addPlacePhotos(d, uris) { vm.refreshPlace() }
    }

    // --- Sheet geometry: measured content, two anchors, drag / fling / nested scroll (as the home panel) ---
    fun px(dp: Float) = dp * density.density
    var headerPx by remember { mutableIntStateOf(0) }    // handle + name/rating/meta (+ "add place here")
    var footerPx by remember { mutableIntStateOf(0) }    // Routes + the action row
    var allContentPx by remember { mutableIntStateOf(0) }
    val measured = headerPx > 0 && footerPx > 0
    val headerDp = headerPx / density.density
    val footerDp = footerPx / density.density
    // Largest fonts: Routes and the actions stay pinned (visible) at the bottom of the card.
    val pinFooter = measured && PlaceSheetLayout.pinFooter(headerDp, footerDp, navInset, screenH)
    val peekDp = if (measured) PlaceSheetLayout.peekHeight(headerDp + footerDp, navInset, screenH) else PlaceSheetLayout.peekCap(screenH)
    val fullDp = PlaceSheetLayout.fullHeight(peekDp, allContentPx / density.density + (if (pinFooter) footerDp else 0f), navInset, screenH, statusInset)
    val anchors = PlaceSheetLayout.anchors(peekDp, fullDp)
    val anchorsPx = anchors.map(::px)
    var state by remember(p.id) { mutableStateOf(PlaceSheetState.PEEK) }
    var heightPx by remember(p.id) { mutableFloatStateOf(-1f) }
    val scope = rememberCoroutineScope()
    var anim by remember { mutableStateOf<Job?>(null) }
    val scroll = rememberScrollState()
    fun animateTo(target: Float) {
        anim?.cancel()
        val from = if (heightPx < 0f) target else heightPx
        anim = scope.launch { animate(from, target, animationSpec = spring(stiffness = Spring.StiffnessMediumLow)) { v, _ -> heightPx = v } }
    }
    fun go(s: PlaceSheetState) { state = s; animateTo(anchorsPx[s.ordinal]) }
    fun dragBy(dyPx: Float): Float {   // dy > 0: finger down (shrink). Returns the part used.
        anim?.cancel()
        val cur = if (heightPx < 0f) anchorsPx[0] else heightPx
        val next = (cur - dyPx).coerceIn(anchorsPx.first(), anchorsPx.last())
        heightPx = next
        return cur - next
    }
    fun release(downVelocityPx: Float) =
        go(PlaceSheetLayout.settle(heightPx / density.density, -downVelocityPx / density.density, anchors, state))
    // First measurement snaps; later changes (details loaded, font scale, rotation) animate to the new anchor.
    LaunchedEffect(state, anchorsPx[0], anchorsPx[1], measured) {
        if (!measured) return@LaunchedEffect
        val target = anchorsPx[state.ordinal]
        if (heightPx < 0f) heightPx = target else if (abs(heightPx - target) > 1f) animateTo(target)
    }
    // The map centres the pin above the resting card (recomputed whenever the resting height changes).
    LaunchedEffect(state, anchors[0].roundToInt(), anchors[1].roundToInt(), measured) {
        if (measured) vm.setPlaceSheetDp(PlaceSheetLayout.cameraBottomPaddingDp(anchors[state.ordinal], screenH).roundToInt())
    }
    LaunchedEffect(state) { if (state == PlaceSheetState.PEEK) scroll.animateScrollTo(0) }
    BackHandler(enabled = state == PlaceSheetState.FULL) { go(PlaceSheetState.PEEK) }

    val sheetPx = if (heightPx < 0f) anchorsPx[0] else heightPx
    val progress = ((sheetPx - anchorsPx[0]) / (anchorsPx[1] - anchorsPx[0]).coerceAtLeast(1f)).coerceIn(0f, 1f)
    val nested = remember(p.id, anchorsPx[0], anchorsPx[1]) {
        object : NestedScrollConnection {
            // Finger up: open the card before its content scrolls.
            override fun onPreScroll(available: Offset, source: NestedScrollSource): Offset =
                if (available.y < 0 && source == NestedScrollSource.UserInput && (if (heightPx < 0f) anchorsPx[0] else heightPx) < anchorsPx.last() - 0.5f)
                    Offset(0f, -dragBy(available.y)) else Offset.Zero
            // Finger down with the content at its top: close it.
            override fun onPostScroll(consumed: Offset, available: Offset, source: NestedScrollSource): Offset =
                if (available.y > 0 && source == NestedScrollSource.UserInput) Offset(0f, -dragBy(available.y)) else Offset.Zero
            // Settle whenever the card isn't resting at its state's height, including a drag clamped exactly onto
            // the other anchor (a swipe down to the peek must still switch the state and re-centre the map).
            override suspend fun onPreFling(available: Velocity): Velocity {
                if (heightPx >= 0f && PlaceSheetLayout.needsSettle(heightPx / density.density, state, anchors)) { release(available.y); return available }
                return Velocity.Zero
            }
        }
    }

    // Attribution (left) and "back to the pin" (right) ride just above the card; the recentre button fades as it opens.
    Box(
        Modifier.fillMaxWidth().align(Alignment.BottomStart)
            .offset { IntOffset(0, -sheetPx.roundToInt()) }
            .padding(horizontal = 16.dp, vertical = 10.dp),
    ) {
        Attribution(Modifier.align(Alignment.BottomStart))
        if (progress < 0.5f) RoundFab(
            Icons.Filled.MyLocation, stringResource(R.string.recenter_on_place),
            Modifier.align(Alignment.BottomEnd).alpha(1f - progress * 2f), size = 52.dp, onClick = vm::recenterOnPlace,
        )
    }

    val sheetLabel = stringResource(R.string.place_sheet)
    val stateLabel = stringResource(if (state == PlaceSheetState.PEEK) R.string.place_sheet_peek else R.string.place_sheet_full)
    val expandLabel = stringResource(R.string.home_sheet_expand)
    val collapseLabel = stringResource(R.string.home_sheet_collapse)
    // Routes + Save · Call · Share · Website: under the header, or pinned to the card's bottom at the largest fonts.
    val footerDrag = rememberDraggableState { dragBy(it) }
    val footer: @Composable (Modifier) -> Unit = { m ->
        Column(m.fillMaxWidth().onSizeChanged { footerPx = it.height }.padding(horizontal = 16.dp)) {
            Button(
                onClick = vm::routeToPlace,
                modifier = Modifier.fillMaxWidth().padding(top = 12.dp).heightIn(min = 56.dp),
                shape = RoundedCornerShape(18.dp),
                colors = ButtonDefaults.buttonColors(containerColor = c.brand, contentColor = c.brandOn),
            ) {
                val v = remember(c.brandOn) { TwoTone.vector("route", c.brandOn.copy(alpha = 0.25f), c.brandOn) }
                Image(rememberVectorPainter(v), null, Modifier.size(26.dp))
                Spacer(Modifier.width(10.dp))
                Text(stringResource(R.string.routes), style = GimanoType.button, fontSize = 18.sp, fontWeight = FontWeight.Black, maxLines = 1, overflow = TextOverflow.Ellipsis)
            }
            ActionRow(sel, vm)
        }
    }
    SheetSurface(Modifier.align(Alignment.BottomCenter).fillMaxWidth().height(with(density) { sheetPx.toDp() })) {
        Box(Modifier.fillMaxWidth().weight(1f)) {
            Column(Modifier.fillMaxWidth().nestedScroll(nested).verticalScroll(scroll)) {
                Column(Modifier.fillMaxWidth().onSizeChanged { allContentPx = it.height }) {
                    // ---------------- PEEK ----------------
                    Column(Modifier.fillMaxWidth().onSizeChanged { headerPx = it.height }.padding(horizontal = 16.dp)) {
                        // Handle: tap toggles peek ↔ full. TalkBack: "Place card, collapsed. Swipe up for reviews and photos."
                        Box(
                            Modifier.fillMaxWidth().height(22.dp)
                                .semantics(mergeDescendants = true) {
                                    contentDescription = "$sheetLabel, $stateLabel"
                                    if (state == PlaceSheetState.PEEK) expand { go(PlaceSheetState.FULL); true }
                                    else collapse { go(PlaceSheetState.PEEK); true }
                                }
                                .clickable(onClickLabel = if (state == PlaceSheetState.PEEK) expandLabel else collapseLabel) {
                                    go(if (state == PlaceSheetState.PEEK) PlaceSheetState.FULL else PlaceSheetState.PEEK)
                                },
                            contentAlignment = Alignment.TopCenter,
                        ) { GrabHandle(Modifier.padding(top = 8.dp)) }
                        PeekHeader(sel, vm, reviews, onSuggest = { suggest = true },
                            onReportPlace = if (d?.isCommunity == true) ({ reportPlace = true }) else null)
                        // Content safety: the place is listed and routable; the banner only tells people before they go.
                        val warnings = PlaceWarning.of(d?.warnings?.ifEmpty { null } ?: p.warnings)
                        if (warnings.isNotEmpty()) WarningBanner(warnings, Modifier.padding(top = 8.dp), onTell = if (d != null) ({ cvm.flagWarning(d) }) else null)
                        if (p.id.startsWith("pin:")) {
                            OutlinedButton(onClick = { cvm.startAdd(my.gimano.app.core.geo.GeoPoint(p.lat, p.lng), ""); vm.startAddPlace(my.gimano.app.core.geo.GeoPoint(p.lat, p.lng), "") },
                                Modifier.fillMaxWidth().padding(top = 10.dp).heightIn(min = 52.dp), shape = RoundedCornerShape(Radius.md)) {
                                Icon(Icons.Filled.AddLocationAlt, null); Spacer(Modifier.width(8.dp)); Text(stringResource(R.string.add_place_here), fontWeight = FontWeight.ExtraBold)
                            }
                        }
                    }
                    if (!pinFooter) footer(Modifier)

                    // ---------------- FULL ----------------
                    // Hidden from TalkBack while collapsed (it is below the card's edge).
                    Column(
                        Modifier.fillMaxWidth().padding(horizontal = 16.dp).alpha((progress * 3f).coerceAtMost(1f))
                            .then(if (state == PlaceSheetState.PEEK && progress < 0.01f) Modifier.clearAndSetSemantics { } else Modifier),
                    ) {
                        Details(sel, vm, cvm)
                        if (d != null) ReviewsSection(d, my.gimano.app.data.ugc.Blocking.reviews(reviews.reviews, blocked), reviews.summary, reviews.loading, cvm, apiBase, openPhotos)

                        // Photos, with "Add photo" (camera or gallery; EXIF stripped before upload) at the END of the strip.
                        val placePhotos = my.gimano.app.data.ugc.Blocking.photos(d?.photos.orEmpty(), blocked)
                        val photoUrls = if (priv != null) sel.privatePhotos.map { Uri.fromFile(it).toString() } else placePhotos.map { mediaUrl(it.thumbUrl.ifBlank { it.url }, apiBase) }
                        val pending = reviews.placeUploads.filter { it.photo?.status != "published" }
                        if (photoUrls.isNotEmpty() || d != null || pending.isNotEmpty()) {
                            SectionLabel(stringResource(R.string.photos))
                            LazyRow(horizontalArrangement = Arrangement.spacedBy(8.dp), modifier = Modifier.padding(bottom = 8.dp)) {
                                items(photoUrls.size) { i ->
                                    AsyncImage(photoUrls[i], stringResource(R.string.photos), Modifier.size(96.dp).clip(RoundedCornerShape(14.dp)).clickable {
                                        // "Just for me" photos are local files (no report/block); public ones carry their metadata.
                                        viewer = if (priv != null) ViewerState(photoUrls, i, List(photoUrls.size) { null }) else ViewerState(placePhotos.map { mediaUrl(it.url, apiBase) }, i, placePhotos)
                                    }, contentScale = ContentScale.Crop)
                                }
                                items(pending) { u -> UploadTile(u, 96, onRejected = { id -> cvm.showRejectedPhoto(id) }) }
                                // docs/safety.md B: no public photos within reviewM of a restricted area (the server refuses them).
                                val photosOn = d != null && cvm.photosAllowedAt(d.lat, d.lng)
                                if (d != null && !photosOn) item {
                                    Column(
                                        Modifier.sizeIn(minWidth = 96.dp, minHeight = 96.dp, maxWidth = 160.dp).clip(RoundedCornerShape(14.dp)).background(c.surfaceAlt).padding(6.dp),
                                        horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.Center,
                                    ) {
                                        Icon(Icons.Filled.NoPhotography, null, tint = c.textMuted, modifier = Modifier.size(26.dp))
                                        Text(stringResource(R.string.restricted_b_photos_off), fontSize = 11.sp, fontWeight = FontWeight.Bold, color = c.textMuted,
                                            maxLines = 4, overflow = TextOverflow.Ellipsis, textAlign = androidx.compose.ui.text.style.TextAlign.Center,
                                            modifier = Modifier.padding(top = 2.dp))
                                    }
                                }
                                if (d != null && photosOn) item {
                                    Column(
                                        // Grows with very large text (label on up to two lines) instead of truncating it.
                                        Modifier.sizeIn(minWidth = 96.dp, minHeight = 96.dp, maxWidth = 160.dp).clip(RoundedCornerShape(14.dp))
                                            .background(c.brandMist).clickable { vm.container.terms.require { addPhoto() } }.padding(6.dp),   // rules before a first public photo
                                        horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.Center,
                                    ) {
                                        TwoToneIcon("add_photo", null, size = 30.dp)
                                        Text(stringResource(R.string.add_photo), fontSize = 12.sp, fontWeight = FontWeight.ExtraBold, color = c.brandInk,
                                            maxLines = 2, overflow = TextOverflow.Ellipsis, textAlign = androidx.compose.ui.text.style.TextAlign.Center,
                                            modifier = Modifier.padding(top = 2.dp))
                                    }
                                }
                            }
                        }
                        if (d != null) Row(
                            Modifier.fillMaxWidth().clip(RoundedCornerShape(Radius.md)).clickable { suggest = true }.padding(horizontal = 2.dp, vertical = 12.dp),
                            verticalAlignment = Alignment.CenterVertically,
                        ) {
                            TwoToneIcon("edit", null, size = 22.dp)
                            Spacer(Modifier.width(10.dp))
                            Text(stringResource(R.string.suggest_edit), fontSize = 15.sp, fontWeight = FontWeight.ExtraBold, color = c.brandInk)
                        }
                        if (priv != null) TextButton(onClick = { vm.deletePrivatePlace(priv.id) }, Modifier.align(Alignment.End)) {
                            Text(stringResource(R.string.delete), color = c.report, fontWeight = FontWeight.ExtraBold)
                        }
                        Spacer(Modifier.height(12.dp))
                    }
                }
                if (!pinFooter) Spacer(Modifier.height(navInset.dp))
            }
            if (sel.loading) LinearProgressIndicator(Modifier.fillMaxWidth().align(Alignment.TopCenter).padding(top = 18.dp, start = 40.dp, end = 40.dp).height(2.dp), color = c.brand, trackColor = c.surfaceAlt)
        }
        if (pinFooter) {
            // Swiping on the pinned footer moves the card too.
            footer(Modifier.background(c.surface).draggable(footerDrag, Orientation.Vertical, onDragStopped = { v -> release(v) }))
            Spacer(Modifier.height(navInset.dp))
        }
    }

    if (reportPlace && d != null) AlertDialog(
        onDismissRequest = { reportPlace = false },
        title = { Text(stringResource(R.string.report_place), style = GimanoType.title) },
        text = {
            Column {
                FlagReasons.forEach { (k, l) ->
                    Column(Modifier.fillMaxWidth().clickable { reportPlace = false; cvm.flagPlace(d, k) }.padding(vertical = 12.dp)) {
                        Text(stringResource(l), fontSize = 16.sp)
                        if (k == SENSITIVE) Text(stringResource(R.string.flag_sensitive_desc), fontSize = 13.sp, color = c.textMuted)
                    }
                }
            }
        },
        confirmButton = { TextButton(onClick = { reportPlace = false }) { Text(stringResource(R.string.cancel)) } },
    )
    viewer?.let { v ->
        PhotoViewer(v, onClose = { viewer = null },
            onReport = { p, reason -> cvm.flagPhoto(p, reason) },
            onBlock = { a -> viewer = null; cvm.blockAuthor(a) })
    }
    // "Cadangkan suntingan": the six complaint options when the server has /issues; otherwise the classic edit form.
    var suggestForm by remember { mutableStateOf(false) }
    val issuesOn = uiState.issuesAvailable && d?.id?.startsWith("st-") != true
    if (suggest && d != null && issuesOn) my.gimano.app.ui.issues.PlaceSuggestSheet(
        onDismiss = { suggest = false },
        onClosedPerm = { suggest = false; vm.reportPlaceIssue(my.gimano.app.data.model.IssueKind.PLACE_CLOSED_PERM) },
        onClosedTemp = { day -> suggest = false; vm.reportPlaceIssue(my.gimano.app.data.model.IssueKind.PLACE_CLOSED_TEMP, mapOf("until" to day.toString())) },
        onHours = { h -> suggest = false; vm.reportPlaceIssue(my.gimano.app.data.model.IssueKind.PLACE_HOURS_WRONG, mapOf("openingHours" to h)) },
        onEntrance = { suggest = false; vm.pickEntrance() },
        onInfo = { suggest = false; suggestForm = true },
        onDuplicate = { other -> suggest = false; vm.reportPlaceIssue(my.gimano.app.data.model.IssueKind.PLACE_DUPLICATE, other?.let { mapOf("comment" to it) }) },
    )
    if (((suggest && !issuesOn) || suggestForm) && d != null) SuggestEditDialog(d, onDismiss = { suggest = false; suggestForm = false }) { body ->
        suggest = false; suggestForm = false; cvm.suggestEdit(d.id, body)
    }
    reviews.draft?.let { if (d != null) WriteReviewSheet(d, it, cvm) }
    // A rejected photo: why, "Another photo", "Ask a person". Shown over the place card or the write-review sheet.
    reviews.rejectedPhotoId?.let { id ->
        val item = (reviews.placeUploads + reviews.draft?.uploads.orEmpty()).firstOrNull { it.photo?.id == id }
        val ph = item?.photo
        if (ph != null && d != null) {
            val pick = my.gimano.app.ui.common.rememberPhotoSource(5) { uris -> if (reviews.draft != null) cvm.addReviewPhotos(uris) else cvm.addPlacePhotos(d, uris) {} }
            RejectedPhotoScreen(ph.moderation?.reasons.orEmpty(), canAppeal = ContentGate.canAppeal(ph),
                onAnother = { cvm.dropPhoto(id); pick() }, onAsk = { cvm.appealPhoto(id) }, onClose = cvm::closeRejectedPhoto)
        }
    }
}

/** Icon tile, name, the one rating line, badges, and "category · address · open". */
@Composable
private fun PeekHeader(sel: PlaceSel, vm: MainViewModel, reviews: my.gimano.app.ui.contribute.ReviewsState, onSuggest: () -> Unit, onReportPlace: (() -> Unit)? = null) {
    val c = Gimano.colors
    val p = sel.summary
    val d = sel.detail
    val priv = sel.privatePlace
    // Distance only from a real fix (search distances are from the map view otherwise).
    val distance = my.gimano.app.core.places.PlaceDistance.metres(vm.myFreshLocation(), p.lat, p.lng)?.let { Formatters.distance(it) }
    Row(Modifier.padding(top = 2.dp), verticalAlignment = Alignment.CenterVertically) {
        CategoryBadge(p.category, size = 52.dp)
        Spacer(Modifier.width(12.dp))
        Column(Modifier.weight(1f)) {
            // Very large text: one line for the name so the rating line still fits in the peek (full name in TalkBack).
            val big = LocalDensity.current.fontScale >= 1.5f
            Text(p.name, fontSize = 21.sp, fontWeight = FontWeight.Black, color = c.text, maxLines = if (big) 1 else 2, overflow = TextOverflow.Ellipsis, lineHeight = 24.sp)
            when {
                priv != null -> Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.padding(top = 2.dp)) {
                    Badge(stringResource(R.string.just_for_me), c.brandMist, c.brandInk, Icons.Filled.Lock)
                    distance?.let { Text("  $it", fontSize = 13.sp, fontWeight = FontWeight.Bold, color = c.textMuted) }
                }
                p.id.startsWith("pin:") -> distance?.let { Text(it, fontSize = 13.sp, fontWeight = FontWeight.Bold, color = c.textMuted) }
                else -> {
                    // The card's review summary once loaded for this place, else the detail's / search result's figures.
                    val summary = reviews.summary.takeIf { reviews.placeId != null && reviews.placeId == d?.id }
                    val mean = summary?.mean ?: d?.rating ?: p.rating
                    val count = summary?.count ?: d?.reviewCount ?: p.reviewCount
                    RatingLineView(mean, count, distance)
                }
            }
        }
        PlaceOverflow(vm, canSuggest = d != null, onSuggest = onSuggest, onReportPlace = onReportPlace)
        IconButton(onClick = vm::back) { Icon(Icons.Filled.Close, stringResource(R.string.close), tint = c.textMuted) }
    }
    if (d?.isCommunity == true || d?.isUnverified == true || d?.isGold == true) {
        Row(horizontalArrangement = Arrangement.spacedBy(6.dp), modifier = Modifier.padding(top = 6.dp)) {
            if (d.isCommunity) Badge(stringResource(R.string.community), c.brandMist, c.brandInk)
            if (d.isUnverified) my.gimano.app.ui.contribute.UnverifiedChip(d.confirmationsWeighted, d.required)
            if (d.isGold) my.gimano.app.ui.contribute.GoldChip()
        }
    }
    val uiState by vm.ui.collectAsState()
    if (priv == null) my.gimano.app.ui.issues.PlaceIssueBadges(uiState.placeIssues, vm::votePlaceIssue)
    val address = priv?.address ?: p.address
    val open = d?.openNow
    val openText = open?.let { stringResource(if (it) R.string.open_now else R.string.closed) }
    val meta = buildAnnotatedString {
        append(listOf(Labels.category(p.category), address).filter { it.isNotBlank() }.joinToString(" · "))
        if (openText != null) {
            append(" · ")
            withStyle(SpanStyle(color = if (open == true) c.brand else c.report, fontWeight = FontWeight.ExtraBold)) { append(openText) }
        }
    }
    Text(meta, Modifier.padding(top = 8.dp), fontSize = 14.sp, fontWeight = FontWeight.Bold, color = c.textMuted, maxLines = 2, overflow = TextOverflow.Ellipsis)
}

/** ★★★★☆ 4.3 · 12 ulasan · 450 m, or grey stars and "Baharu · 450 m" with no reviews. */
@Composable
private fun RatingLineView(mean: Double?, count: Int, distance: String?) {
    val c = Gimano.colors
    val newLabel = stringResource(R.string.rating_new)
    val res = androidx.compose.ui.platform.LocalContext.current.resources
    val line = RatingLine.of(mean, count, distance, newLabel, countLabel = { n -> res.getQuantityString(R.plurals.review_count_n, n, n) },
        decimal = { String.format(Locale.US, "%.1f", it) })
    Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.padding(top = 2.dp).semantics(mergeDescendants = true) { }) {
        StarRow(line.stars, 16)
        Spacer(Modifier.width(6.dp))
        Text(
            buildAnnotatedString {
                line.mean?.let { withStyle(SpanStyle(color = c.text, fontWeight = FontWeight.Black)) { append(it) }; append(" · ") }
                append(line.parts.joinToString(" · "))
            },
            fontSize = 13.sp, fontWeight = FontWeight.Bold, color = c.textMuted, maxLines = 2, overflow = TextOverflow.Ellipsis,
        )
    }
}

@Composable
private fun StarRow(stars: List<StarFill>, size: Int) {
    val c = Gimano.colors
    Row(horizontalArrangement = Arrangement.spacedBy(1.dp)) {
        stars.forEach { f ->
            val fill = when (f) { StarFill.FULL -> StarGold; StarFill.PALE -> StarPale; StarFill.EMPTY -> c.outline }
            GIcon("star", null, size = size.dp, stroke = fill, fill = fill)
        }
    }
}

@Composable
private fun Stars(value: Double, size: Int) = StarRow(RatingLine.stars(value), size)

/** Save · Call · Share · Website (four equal columns, flat two-tone icons in pale cobalt circles). */
@Composable
private fun ActionRow(sel: PlaceSel, vm: MainViewModel) {
    val d = sel.detail
    val priv = sel.privatePlace
    val phone = priv?.phone ?: d?.phone
    val web = priv?.website ?: d?.website
    Row(Modifier.fillMaxWidth().padding(top = 12.dp, bottom = 12.dp)) {
        val saved = sel.savedId != null
        Action("bookmark", stringResource(if (saved) R.string.saved else R.string.save), if (saved) TwoTonePalette.GOLD else TwoTonePalette.COBALT) { vm.openFavoriteSheet() }
        Action("call", stringResource(R.string.call), enabled = phone != null) { phone?.let(vm::call) }
        Action("share", stringResource(R.string.share), enabled = priv == null) { vm.sharePlace() }
        Action("website", stringResource(R.string.website), enabled = web != null) { web?.let(vm::openWeb) }
    }
}

@Composable
private fun RowScope.Action(icon: String, label: String, palette: TwoTonePalette = TwoTonePalette.COBALT, enabled: Boolean = true, onClick: () -> Unit) {
    val c = Gimano.colors
    Column(
        Modifier.weight(1f).clip(RoundedCornerShape(Radius.md)).clickable(enabled = enabled, onClickLabel = label, onClick = onClick).padding(vertical = 4.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        Box(Modifier.size(48.dp).clip(CircleShape).background(if (enabled) c.brandMist else c.surfaceAlt), contentAlignment = Alignment.Center) {
            TwoToneIcon(icon, null, size = 26.dp, palette = if (enabled) palette else TwoTonePalette.MUTED)
        }
        Text(label, fontSize = 12.sp, fontWeight = FontWeight.Bold, color = if (enabled) c.textMuted else c.textMuted.copy(alpha = 0.5f),
            maxLines = 1, overflow = TextOverflow.Ellipsis, modifier = Modifier.padding(top = 4.dp))
    }
}

/** Full only: opening hours, description, and "Is this place here?" for nearby people. */
@Composable
private fun Details(sel: PlaceSel, vm: MainViewModel, cvm: ContributeViewModel) {
    val c = Gimano.colors
    val p = sel.summary
    val d = sel.detail
    val priv = sel.privatePlace
    (priv?.openingHours ?: d?.openingHours)?.let { Text(stringResource(R.string.hours, it), Modifier.padding(top = 2.dp, bottom = 4.dp), fontSize = 14.sp, color = c.textMuted) }
    (priv?.description ?: d?.description)?.let { Text(it, Modifier.padding(bottom = 6.dp), fontSize = 15.sp, color = c.text) }
    // Nearby check from the phone's own fresh fix (no position is sent to load the card).
    val nearM = my.gimano.app.core.places.PlaceDistance.metres(vm.myFreshLocation(), p.lat, p.lng)
    if (d != null && Verification.canVerify(d.isCommunity, d.status, nearM, d.rural)) {
        Column(Modifier.fillMaxWidth().padding(vertical = 8.dp).clip(RoundedCornerShape(Radius.md)).background(c.brandMist).padding(14.dp)) {
            my.gimano.app.ui.contribute.VerifyPanel(onAnswer = { a, n, l ->
                cvm.verify(my.gimano.app.ui.contribute.VetTarget.of(d), a, n, l) { vm.refreshPlace() }
            })
        }
    }
}

@Composable
private fun SectionLabel(t: String) {
    Text(t.uppercase(), Modifier.padding(top = 10.dp, bottom = 8.dp), fontSize = 12.sp, fontWeight = FontWeight.Black, letterSpacing = 0.6.sp, color = Gimano.colors.textMuted)
}

/** Big average, 5→1 bars, the latest review (the rest on request), and Write a review. No bars without reviews. */
@Composable
private fun ReviewsSection(place: Place, reviews: List<Review>, summary: RatingSummary, loading: Boolean, cvm: ContributeViewModel, apiBase: String, onPhoto: (List<Photo>, Int) -> Unit) {
    val c = Gimano.colors
    SectionLabel(stringResource(R.string.reviews))
    if (summary.count > 0) {
        Row(Modifier.fillMaxWidth().padding(bottom = 8.dp), verticalAlignment = Alignment.CenterVertically) {
            Column(horizontalAlignment = Alignment.CenterHorizontally, modifier = Modifier.widthIn(min = 86.dp)) {
                Text(if (summary.isNew) stringResource(R.string.rating_new) else String.format(Locale.US, "%.1f", summary.mean ?: 0.0),
                    fontSize = if (summary.isNew) 22.sp else 34.sp, fontWeight = FontWeight.Black, color = c.text)
                Stars(summary.mean ?: 0.0, 14)
                Text(pluralStringResource(R.plurals.review_count_n, summary.count, summary.count), fontSize = 12.sp, fontWeight = FontWeight.Bold, color = c.textMuted)
            }
            Spacer(Modifier.width(14.dp))
            Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(3.dp)) {
                val total = summary.distribution.values.sum().coerceAtLeast(1)
                (5 downTo 1).forEach { n ->
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Text("$n", fontSize = 12.sp, fontWeight = FontWeight.Bold, color = c.textMuted, modifier = Modifier.width(14.dp))
                        Box(Modifier.weight(1f).height(6.dp).clip(RoundedCornerShape(3.dp)).background(c.surfaceAlt)) {
                            Box(Modifier.fillMaxHeight().fillMaxWidth((summary.distribution[n] ?: 0).toFloat() / total).background(StarGold))
                        }
                    }
                }
            }
        }
    } else if (!loading) {
        Text(stringResource(R.string.no_reviews_yet), fontSize = 14.sp, fontWeight = FontWeight.Bold, color = c.textMuted, modifier = Modifier.padding(bottom = 8.dp))
    }
    if (loading) LinearProgressIndicator(Modifier.fillMaxWidth().padding(vertical = 6.dp), color = c.brand, trackColor = c.surfaceAlt)
    var all by remember(place.id) { mutableStateOf(false) }
    val shown = if (all) reviews.take(10) else reviews.take(1)
    shown.forEachIndexed { i, r ->
        Box(Modifier.padding(bottom = 8.dp).fillMaxWidth().clip(RoundedCornerShape(14.dp)).background(if (i == 0) c.background else Color.Transparent).padding(horizontal = 12.dp)) {
            ReviewRow(r, place, cvm, apiBase, onPhoto)
        }
    }
    if (reviews.size > 1) TextButton(onClick = { all = !all }) {
        Text(if (all) stringResource(R.string.fewer_reviews) else stringResource(R.string.all_reviews, reviews.size.coerceAtMost(10)), fontWeight = FontWeight.ExtraBold)
    }
    val mine = reviews.firstOrNull { cvm.mine(it) }
    // Tap a star to start a review with that rating (48 dp targets).
    if (mine == null) Row(Modifier.fillMaxWidth().padding(top = 4.dp), horizontalArrangement = Arrangement.SpaceEvenly) {
        (1..5).forEach { n ->
            Box(Modifier.size(48.dp).clip(CircleShape).clickable(onClickLabel = stringResource(R.string.cs_rate_cd, n)) { cvm.openReview(null, n) }, contentAlignment = Alignment.Center) {
                GIcon("star", stringResource(R.string.cs_rate_cd, n), size = 36.dp, stroke = c.outline, fill = Color.Transparent)
            }
        }
    }
    OutlinedButton(
        onClick = { cvm.openReview(mine) }, Modifier.fillMaxWidth().heightIn(min = 48.dp).padding(top = 4.dp),
        shape = RoundedCornerShape(14.dp), border = androidx.compose.foundation.BorderStroke(2.dp, c.outline),
    ) {
        TwoToneIcon("review", null, size = 22.dp); Spacer(Modifier.width(8.dp))
        Text(stringResource(if (mine != null) R.string.edit_review else R.string.write_review), fontSize = 15.sp, fontWeight = FontWeight.Black, color = c.brandInk)
    }
}


/**
 * A photo being attached: the picture, a round status badge (tick published, clock processing or checking, cross not
 * accepted) and a spinner while it uploads. Tap a rejected one to see why ([onRejected] gets its photo id).
 */
@Composable
fun UploadTile(u: UploadItem, sizeDp: Int, onRejected: ((String) -> Unit)? = null) {
    val c = Gimano.colors
    val photo = u.photo
    val state = photo?.let { ContentGate.photoState(it) }
    val rejected = state == ContentState.REJECTED
    val cd = if (rejected) stringResource(R.string.cs_photo_rejected_cd) else null
    Box(
        Modifier.size(sizeDp.dp).clip(RoundedCornerShape(Radius.md))
            .then(if (rejected && photo != null && onRejected != null) Modifier.clickable { onRejected(photo.id) } else Modifier)
            .then(if (cd != null) Modifier.semantics { contentDescription = cd } else Modifier),
    ) {
        if (rejected) Box(Modifier.matchParentSize().background(c.surfaceAlt), contentAlignment = Alignment.Center) {
            Icon(Icons.Filled.HideImage, null, tint = c.textMuted, modifier = Modifier.size((sizeDp / 2).dp))
        } else AsyncImage(u.uri, null, Modifier.matchParentSize(), contentScale = ContentScale.Crop)
        when {
            u.failed -> Box(Modifier.matchParentSize().background(Color(0x99000000)), contentAlignment = Alignment.Center) {
                Icon(Icons.Filled.ErrorOutline, stringResource(R.string.action_failed), tint = Color.White)
            }
            photo == null -> Box(Modifier.matchParentSize().background(Color(0x99000000)), contentAlignment = Alignment.Center) {
                CircularProgressIndicator(Modifier.size(28.dp), color = Color.White, strokeWidth = 3.dp)
            }
            else -> StatusBadge(state ?: ContentState.PROCESSING, Modifier.align(Alignment.BottomEnd).padding(6.dp))
        }
    }
}

@Composable
private fun Badge(text: String, bg: Color, fg: Color, icon: ImageVector? = null) {
    Row(Modifier.clip(RoundedCornerShape(999.dp)).background(bg).padding(horizontal = 8.dp, vertical = 3.dp), verticalAlignment = Alignment.CenterVertically) {
        if (icon != null) { Icon(icon, null, tint = fg, modifier = Modifier.size(12.dp)); Spacer(Modifier.width(4.dp)) }
        Text(text, fontSize = 12.sp, fontWeight = FontWeight.ExtraBold, color = fg)
    }
}

@Composable
private fun ReviewRow(r: Review, place: Place, cvm: ContributeViewModel, apiBase: String, onPhoto: (List<Photo>, Int) -> Unit) {
    val c = Gimano.colors
    var flagMenu by remember { mutableStateOf(false) }
    var confirmBlock by remember { mutableStateOf(false) }
    Column(Modifier.fillMaxWidth().padding(vertical = 10.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Box(Modifier.size(32.dp).clip(CircleShape).background(c.brandMist), contentAlignment = Alignment.Center) {
                Text(r.author.displayName.take(1).uppercase(), fontWeight = FontWeight.Black, color = c.brandInk)
            }
            Spacer(Modifier.width(8.dp))
            Column(Modifier.weight(1f)) {
                Text(r.author.displayName.ifBlank { stringResource(R.string.app_name) } + (r.author.level?.let { " · L$it" } ?: ""), fontWeight = FontWeight.ExtraBold, fontSize = 14.sp, color = c.text)
                Row(verticalAlignment = Alignment.CenterVertically) { Stars(r.rating.toDouble(), 12); Spacer(Modifier.width(6.dp)); Text(my.gimano.app.core.format.Formatters.localStamp(r.createdAt).take(10), fontSize = 12.sp, color = c.textMuted) }
            }
        }
        r.text?.let { Text(it, fontSize = 15.sp, color = c.text, modifier = Modifier.padding(top = 4.dp)) }
        // The author's own view of the AI check: clock (checking), person (a person is looking), cross (not accepted).
        val rs = if (cvm.mine(r)) ContentGate.reviewState(r) else ReviewState.PASSED
        if (rs != ReviewState.PASSED) {
            ReviewStatusLine(rs, Modifier.padding(top = 6.dp))
            if (rs == ReviewState.REJECTED && r.moderation?.canAppeal == true) TextButton(onClick = { cvm.appealReview(r, place) }, Modifier.heightIn(min = 48.dp)) {
                Icon(Icons.Filled.Person, null, Modifier.size(18.dp)); Spacer(Modifier.width(6.dp)); Text(stringResource(R.string.cs_appeal), fontWeight = FontWeight.ExtraBold)
            }
        }
        if (r.photos.isNotEmpty()) {
            LazyRow(horizontalArrangement = Arrangement.spacedBy(6.dp), modifier = Modifier.padding(top = 6.dp)) {
                items(r.photos.size) { i -> AsyncImage(mediaUrl(r.photos[i].thumbUrl.ifBlank { r.photos[i].url }, apiBase), null, Modifier.size(72.dp).clip(RoundedCornerShape(Radius.sm)).clickable { onPhoto(r.photos, i) }, contentScale = ContentScale.Crop) }
            }
        }
        Row(verticalAlignment = Alignment.CenterVertically) {
            TextButton(onClick = { cvm.helpful(r) }) { Icon(Icons.Filled.ThumbUp, null, Modifier.size(16.dp)); Spacer(Modifier.width(4.dp)); Text(stringResource(R.string.helpful_n, r.helpfulCount), fontSize = 13.sp) }
            Box {
                TextButton(onClick = { flagMenu = true }) { Icon(Icons.Filled.Flag, null, Modifier.size(16.dp)); Spacer(Modifier.width(4.dp)); Text(stringResource(R.string.flag), fontSize = 13.sp) }
                DropdownMenu(flagMenu, { flagMenu = false }) {
                    FlagReasons.forEach { (k, l) ->
                        DropdownMenuItem(text = { FlagReasonText(k, l) }, onClick = { flagMenu = false; cvm.flag(r, k) })
                    }
                }
            }
            if (cvm.mine(r)) TextButton(onClick = { cvm.openReview(r) }) { Text(stringResource(R.string.edit), fontSize = 13.sp) }
            // "Block this user" (on this phone only): hides this author's reviews and photos everywhere.
            else if (r.author.authorRef != null) TextButton(onClick = { confirmBlock = true }) {
                Icon(Icons.Filled.Block, null, Modifier.size(16.dp)); Spacer(Modifier.width(4.dp)); Text(stringResource(R.string.block_user_short), fontSize = 13.sp)
            }
        }
    }
    if (confirmBlock) BlockConfirmDialog(r.author.displayName, onDismiss = { confirmBlock = false }) { confirmBlock = false; cvm.blockAuthor(r.author) }
}

/** "Block <name>?": what it does (hide their reviews and photos), that it stays on this phone, where to undo it. */
@Composable
fun BlockConfirmDialog(name: String, onDismiss: () -> Unit, onConfirm: () -> Unit) {
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text(stringResource(R.string.block_user_title, name.ifBlank { "?" }), style = GimanoType.title) },
        text = { Text(stringResource(R.string.block_user_body)) },
        confirmButton = { Button(onClick = onConfirm) { Text(stringResource(R.string.block_user), fontWeight = FontWeight.ExtraBold) } },
        dismissButton = { TextButton(onClick = onDismiss) { Text(stringResource(R.string.cancel)) } },
    )
}

/** The photo viewer's pages; [photos] carries the metadata for Report/Block (null for "Just for me" local photos). */
data class ViewerState(val urls: List<String>, val start: Int, val photos: List<Photo?>)

@Composable
private fun WriteReviewSheet(place: Place, d: my.gimano.app.ui.contribute.ReviewDraft, cvm: ContributeViewModel) {
    val c = Gimano.colors
    val pick = my.gimano.app.ui.common.rememberPhotoSource(5) { cvm.addReviewPhotos(it) }
    ModalBottomSheet(onDismissRequest = cvm::closeReview, sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true), containerColor = c.surface,
        shape = RoundedCornerShape(topStart = Radius.sheet, topEnd = Radius.sheet)) {
        Column(Modifier.fillMaxWidth().verticalScroll(rememberScrollState()).padding(horizontal = 16.dp).padding(bottom = 24.dp).imePadding()) {
            Text(place.name, style = GimanoType.title, color = c.text)
            Row(Modifier.padding(vertical = 8.dp), horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                (1..5).forEach { n ->
                    val on = d.rating >= n
                    val cd = stringResource(R.string.cs_rate_cd, n)
                    Box(Modifier.size(52.dp).clip(RoundedCornerShape(16.dp)).semantics { selected = d.rating == n }
                        .clickable(onClickLabel = cd) { cvm.updateDraft { it.copy(rating = n) } }, contentAlignment = Alignment.Center) {
                        GIcon("star", cd, size = 44.dp, stroke = if (on) c.report else c.outline, fill = if (on) c.report else Color.Transparent)
                    }
                }
            }
            OutlinedTextField(d.text, { v -> cvm.updateDraft { it.copy(text = v.take(ReviewPrefilter.SHOWN_MAX)) } }, Modifier.fillMaxWidth(), minLines = 3, maxLines = 6,
                placeholder = { Text(stringResource(R.string.review_hint)) }, shape = RoundedCornerShape(Radius.md),
                supportingText = { Text(stringResource(R.string.cs_review_count, d.text.length, ReviewPrefilter.SHOWN_MAX), Modifier.fillMaxWidth(), textAlign = androidx.compose.ui.text.style.TextAlign.End) })
            // Local pre-filter (nothing is sent): phone, link and offer tiles are crossed out while the text looks like an advert.
            val lit = remember(d.text) { ReviewPrefilter.tiles(d.text) }
            Row(Modifier.padding(top = 8.dp), verticalAlignment = Alignment.CenterVertically) {
                AdTilesRow(lit, Modifier.weight(1f))
            }
            Text(stringResource(if (lit.isNotEmpty()) R.string.cs_post_blocked else R.string.cs_review_ok_hint), Modifier.padding(top = 8.dp),
                fontSize = 13.sp, fontWeight = FontWeight.Bold, color = if (lit.isNotEmpty()) c.report else c.textMuted)
            // docs/safety.md C: security details → a warning; the review is held for a moderator.
            val sensitiveText = cvm.sensitive.hasMatch(d.text)
            if (sensitiveText) my.gimano.app.ui.safety.SensitiveWordsWarning(cvm::removeSensitiveFromReview, Modifier.padding(top = 6.dp))
            val photosOn = cvm.photosAllowedAt(place.lat, place.lng)
            // Photos: 2-column grid, a round status badge on each (tick / clock / cross), polled while they are checked.
            val cells = d.uploads.size + if (d.uploads.size < 5 && photosOn) 1 else 0
            (0 until cells).chunked(2).forEach { row ->
                Row(Modifier.padding(top = 10.dp), horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                    row.forEach { i ->
                        val u = d.uploads.getOrNull(i)
                        if (u != null) UploadTile(u, 144, onRejected = cvm::showRejectedPhoto)
                        else Box(Modifier.size(144.dp).clip(RoundedCornerShape(Radius.md)).background(c.brandMist).clickable(onClickLabel = stringResource(R.string.add_photo)) { pick() }, contentAlignment = Alignment.Center) {
                            Icon(Icons.Filled.AddAPhoto, stringResource(R.string.add_photo), tint = c.brand, modifier = Modifier.size(36.dp))
                        }
                    }
                }
            }
            if (!photosOn) Text(stringResource(R.string.restricted_b_photos_off), fontSize = 13.sp, fontWeight = FontWeight.Bold, color = c.textMuted, modifier = Modifier.padding(top = 8.dp))
            val uploading = d.uploads.any { it.photo == null && !it.failed }
            Button(onClick = { cvm.submitReview(place) }, enabled = d.rating in 1..5 && !d.sending && !uploading && lit.isEmpty(),
                modifier = Modifier.padding(top = 12.dp).fillMaxWidth().height(56.dp), shape = RoundedCornerShape(Radius.md),
                colors = ButtonDefaults.buttonColors(containerColor = c.brand, contentColor = c.brandOn)) {
                Text(stringResource(when { sensitiveText -> R.string.restricted_send_review; d.editingId != null -> R.string.save; else -> R.string.post_review }), style = GimanoType.button)
            }
        }
    }
    // 422 content_rejected: nothing was stored. Big shield-x, the offending items crossed out, the safe part, Edit.
    d.rejection?.let { f -> CantPostSheet(f, onPostPart = { cvm.postSafePart(place) }, onEdit = cvm::dismissRejection) }
    // 403 posting_paused.
    d.paused?.let { PausedSheet(it, cvm.use24h) { cvm.closeReview() } }
}

@Composable
private fun SuggestEditDialog(place: Place, onDismiss: () -> Unit, onSend: (SuggestEditRequest) -> Unit) {
    var name by remember { mutableStateOf(place.name) }
    var phone by remember { mutableStateOf(place.phone.orEmpty()) }
    var hours by remember { mutableStateOf(place.openingHours.orEmpty()) }
    var comment by remember { mutableStateOf("") }
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text(stringResource(R.string.suggest_edit), style = GimanoType.title) },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
                OutlinedTextField(name, { name = it }, singleLine = true, label = { Text(stringResource(R.string.plan_name)) })
                if (!place.id.startsWith("st-")) OutlinedTextField(phone, { phone = it }, singleLine = true, label = { Text(stringResource(R.string.phone)) })
                if (!place.id.startsWith("st-")) OutlinedTextField(hours, { hours = it }, singleLine = true, label = { Text(stringResource(R.string.opening_hours)) })
                OutlinedTextField(comment, { comment = it }, minLines = 2, label = { Text(stringResource(R.string.comment_hint)) })
            }
        },
        confirmButton = {
            Button(onClick = {
                onSend(SuggestEditRequest(
                    name = name.takeIf { it != place.name && it.isNotBlank() }, phone = phone.takeIf { it != place.phone.orEmpty() },
                    openingHours = hours.takeIf { it != place.openingHours.orEmpty() }, comment = comment.ifBlank { null },
                ))
            }) { Text(stringResource(R.string.send)) }
        },
        dismissButton = { TextButton(onClick = onDismiss) { Text(stringResource(R.string.cancel)) } },
    )
}

@Composable
private fun PhotoViewer(v: ViewerState, onClose: () -> Unit, onReport: (Photo, String) -> Unit, onBlock: (my.gimano.app.data.model.Author) -> Unit) {
    val urls = v.urls
    Dialog(onDismissRequest = onClose, properties = DialogProperties(usePlatformDefaultWidth = false)) {
        Box(Modifier.fillMaxSize().background(Color.Black)) {
            val pager = rememberPagerState(initialPage = v.start) { urls.size }
            HorizontalPager(pager, Modifier.fillMaxSize()) { i -> AsyncImage(urls[i], null, Modifier.fillMaxSize(), contentScale = ContentScale.Fit) }
            IconButton(onClick = onClose, Modifier.align(Alignment.TopEnd).windowInsetsPadding(WindowInsets.statusBars).padding(8.dp)) {
                Icon(Icons.Filled.Close, stringResource(R.string.close), tint = Color.White, modifier = Modifier.size(32.dp))
            }
            Column(Modifier.align(Alignment.BottomCenter).windowInsetsPadding(WindowInsets.navigationBars).padding(12.dp), horizontalAlignment = Alignment.CenterHorizontally) {
                // Public photos: "Report photo" (reasons) and, for someone else's photo, "Block this user".
                val photo = v.photos.getOrNull(pager.currentPage)
                if (photo != null) Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    var menu by remember { mutableStateOf(false) }
                    var confirmBlock by remember(photo.id) { mutableStateOf(false) }
                    Box {
                        TextButton(onClick = { menu = true }) {
                            Icon(Icons.Filled.Flag, null, Modifier.size(18.dp), tint = Color.White); Spacer(Modifier.width(6.dp))
                            Text(stringResource(R.string.report_photo), color = Color.White, fontWeight = FontWeight.ExtraBold)
                        }
                        DropdownMenu(menu, { menu = false }) {
                            FlagReasons.forEach { (k, l) -> DropdownMenuItem(text = { FlagReasonText(k, l) }, onClick = { menu = false; onReport(photo, k) }) }
                        }
                    }
                    val author = photo.uploadedBy
                    if (author?.authorRef != null) {
                        TextButton(onClick = { confirmBlock = true }) {
                            Icon(Icons.Filled.Block, null, Modifier.size(18.dp), tint = Color.White); Spacer(Modifier.width(6.dp))
                            Text(stringResource(R.string.block_user_short), color = Color.White, fontWeight = FontWeight.ExtraBold)
                        }
                        if (confirmBlock) BlockConfirmDialog(author.displayName, onDismiss = { confirmBlock = false }) { confirmBlock = false; onBlock(author) }
                    }
                }
                Text("${pager.currentPage + 1} / ${urls.size}", color = Color.White, modifier = Modifier.padding(top = 4.dp))
            }
        }
    }
}

private const val SENSITIVE = "sensitive_location"

/**
 * Report reasons for places, reviews and photos (POST /places|reviews|photos/{id}/flag). `sensitive_location` hides the
 * item after one report (docs/safety.md §4 E).
 */
private val FlagReasons = listOf(
    "spam" to R.string.flag_spam, "offensive" to R.string.flag_offensive, "off_topic" to R.string.flag_off_topic,
    "conflict_of_interest" to R.string.flag_conflict, SENSITIVE to R.string.flag_sensitive, "other" to R.string.fb_other,
)

/** A reason, with the explainer under "Lokasi sensitif atau keselamatan". */
@Composable
private fun FlagReasonText(key: String, label: Int) {
    Column(Modifier.widthIn(max = 300.dp)) {
        Text(stringResource(label))
        if (key == SENSITIVE) Text(stringResource(R.string.flag_sensitive_desc), fontSize = 12.sp, color = Gimano.colors.textMuted, lineHeight = 16.sp)
    }
}

@Composable
private fun PlaceOverflow(vm: MainViewModel, canSuggest: Boolean, onSuggest: () -> Unit, onReportPlace: (() -> Unit)? = null) {
    var open by remember { mutableStateOf(false) }
    Box {
        IconButton(onClick = { open = true }) { Icon(Icons.Filled.MoreVert, stringResource(R.string.more), tint = Gimano.colors.textMuted) }
        DropdownMenu(open, onDismissRequest = { open = false }) {
            if (canSuggest) DropdownMenuItem(
                text = { Text(stringResource(R.string.suggest_edit), fontWeight = FontWeight.Bold) },
                leadingIcon = { Icon(Icons.Filled.EditNote, null) },
                onClick = { open = false; onSuggest() },
            )
            // Community places only: "Report place" (abusive or fake listing; 3 reports hide it until reviewed).
            if (onReportPlace != null) DropdownMenuItem(
                text = { Text(stringResource(R.string.report_place), fontWeight = FontWeight.Bold) },
                leadingIcon = { Icon(Icons.Filled.Flag, null) },
                onClick = { open = false; onReportPlace() },
            )
            DropdownMenuItem(
                text = { Text(stringResource(R.string.add_feedback), fontWeight = FontWeight.Bold) },
                leadingIcon = { GIcon("feedback", null, size = 24.dp) },
                onClick = { open = false; vm.requestFeedback("place") },
            )
        }
    }
}
