package my.gimano.app.ui.contribute

import android.net.Uri
import androidx.lifecycle.ViewModel
import androidx.lifecycle.ViewModelProvider
import androidx.lifecycle.viewModelScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharedFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import my.gimano.app.AppContainer
import my.gimano.app.R
import my.gimano.app.core.geo.GeoPoint
import my.gimano.app.core.places.OpeningHours
import my.gimano.app.core.places.RatingSummary
import my.gimano.app.core.safety.RestrictedZone
import my.gimano.app.data.model.*
import my.gimano.app.data.places.ContributionLog
import my.gimano.app.data.places.PhotoPrep
import my.gimano.app.data.remote.GimanoJson
import retrofit2.HttpException
import java.io.File
import java.util.UUID

enum class AddStep { PIN, DETAILS, VISIBILITY }

data class AddPlaceState(
    val step: AddStep = AddStep.PIN,
    val pin: GeoPoint = GeoPoint(0.0, 0.0),
    val address: String = "",
    val name: String = "",
    val category: String? = null,
    val phone: String = "",
    val website: String = "",
    val description: String = "",
    val amenities: Set<String> = emptySet(),
    val hoursEnabled: Boolean = false,
    val open247: Boolean = false,
    val week: Map<String, List<OpeningHours.Range>> = OpeningHours.DAYS.take(5).associateWith { listOf(OpeningHours.Range("09:00", "18:00")) },
    val photos: List<Uri> = emptyList(),
    val saving: Boolean = false,
    val duplicate: Place? = null,
    val error: String? = null,
    /** docs/safety.md §4: where the pin is relative to the restricted areas (checked on the phone, offline). */
    val zone: RestrictedZone = RestrictedZone.CLEAR,
    /** A: "Tidak boleh dikongsi di sini" instead of the form. */
    val blockedSheet: Boolean = false,
    /** "Simpan untuk saya sahaja" from A: a private place (allowed anywhere, photos included), never public. */
    val privateOnly: Boolean = false,
) {
    /** B: near an area, sharing publicly: a note, no photos, held for a moderator. */
    val nearArea get() = zone == RestrictedZone.NEAR && !privateOnly
    val hours: String? get() = if (!hoursEnabled) null else OpeningHours.build(week, open247).ifBlank { null }
    val canContinue get() = name.isNotBlank() && category != null
}

/** One photo being attached: uploading → processing → published (or failed). */
data class UploadItem(val key: String, val uri: Uri, val photo: Photo? = null, val failed: Boolean = false) {
    val processing get() = photo?.status == "processing"
}

data class ReviewDraft(val rating: Int = 0, val text: String = "", val uploads: List<UploadItem> = emptyList(), val editingId: String? = null, val sending: Boolean = false)

data class ReviewsState(
    val placeId: String? = null,
    val reviews: List<Review> = emptyList(),
    val loading: Boolean = false,
    val summary: RatingSummary = RatingSummary.of(emptyList()),
    val draft: ReviewDraft? = null,
    val placeUploads: List<UploadItem> = emptyList(),
)

sealed interface ContribEvent {
    data class Message(val res: Int) : ContribEvent
    /** Leave the add-a-place flow ("Batal" on the blocked-pin sheet). */
    data object Close : ContribEvent
    data class Text(val text: String) : ContribEvent
    data class ShowPlace(val summary: PlaceSummary) : ContribEvent
}

class ContributeViewModel(private val c: AppContainer) : ViewModel() {
    private val _add = MutableStateFlow(AddPlaceState())
    val add: StateFlow<AddPlaceState> = _add.asStateFlow()
    private val _reviews = MutableStateFlow(ReviewsState())
    val reviews: StateFlow<ReviewsState> = _reviews.asStateFlow()
    private val _events = MutableSharedFlow<ContribEvent>(extraBufferCapacity = 4)
    val events: SharedFlow<ContribEvent> = _events
    val log = ContributionLog(c.db.outbox())

    // ---------------------------------------------------------------- add a place

    fun startAdd(at: GeoPoint, name: String) {
        // Long-press / "Tambah tempat" inside a restricted area goes straight to A.
        val zone = c.restricted.zone(at)
        _add.value = AddPlaceState(pin = at, name = name, zone = zone, blockedSheet = zone == RestrictedZone.BLOCKED)
        onPinMoved(at)
    }

    private var geoJob: Job? = null

    /** The map moves under a fixed centre pin; the address follows (reverse geocoded). */
    fun onPinMoved(p: GeoPoint) {
        _add.update { it.copy(pin = p, zone = c.restricted.zone(p)) }
        geoJob?.cancel()
        geoJob = viewModelScope.launch {
            delay(350)
            val r = runCatching { c.repo.reverse(p.lat, p.lng) }.getOrNull()
            _add.update { it.copy(address = r?.address?.ifBlank { r.name } ?: it.address) }
        }
    }

    fun update(f: (AddPlaceState) -> AddPlaceState) = _add.update(f)

    /** Pin step "Next": a pin in a restricted area (or within blockM) gets A instead of the form. */
    fun nextFromPin() {
        val s = _add.value
        if (!s.privateOnly && c.restricted.zone(s.pin) == RestrictedZone.BLOCKED) _add.update { it.copy(blockedSheet = true) }
        else step(AddStep.DETAILS)
    }

    /** A · "Alih pin": back to the map, the pin stays where it was. */
    fun blockedMove() = _add.update { it.copy(blockedSheet = false, step = AddStep.PIN) }

    /** A · "Simpan untuk saya sahaja": a private place stays on the phone, so it is allowed anywhere. */
    fun blockedPrivate() = _add.update { it.copy(blockedSheet = false, privateOnly = true, step = AddStep.DETAILS) }

    /** A · "Batal". */
    fun blockedCancel() { _add.value = AddPlaceState(); _events.tryEmit(ContribEvent.Close) }

    /** The server's security terms (C), matched on the phone. */
    val sensitive get() = c.restricted.terms.value

    /** C · "Buang ayat ini". */
    fun removeSensitive(field: String) = _add.update {
        when (field) {
            "name" -> it.copy(name = sensitive.removeSentences(it.name))
            else -> it.copy(description = sensitive.removeSentences(it.description))
        }
    }

    /** C on a public place: the name or description mentions security details (held for a moderator). */
    fun sensitiveText(s: AddPlaceState): Boolean = sensitive.hasMatch(s.name) || sensitive.hasMatch(s.description)

    /** Public sharing will be held for a moderator (B or C): the button reads "Hantar untuk semakan". */
    fun willBeHeld(s: AddPlaceState): Boolean = s.nearArea || sensitiveText(s)

    /** The user-facing message for a failed write: the server's own words for a restricted area, else [fallback]. */
    private fun failure(e: Throwable, fallback: Int): ContribEvent =
        if (e is my.gimano.app.data.repo.RestrictedAreaException) ContribEvent.Text(e.detail) else ContribEvent.Message(fallback)
    fun showExisting(p: Place) { _add.value = AddPlaceState(); _events.tryEmit(ContribEvent.ShowPlace(p.summary())) }
    fun step(s: AddStep) = _add.update { it.copy(step = s, error = null) }
    fun addPhotos(uris: List<Uri>) = _add.update { it.copy(photos = (it.photos + uris).distinct().take(10)) }
    fun removePhoto(u: Uri) = _add.update { it.copy(photos = it.photos - u) }

    /** "Just for me": stays in the on-device DB (and the user's own backup), never sent to the server. */
    fun savePrivate() {
        val s = _add.value
        if (!s.canContinue) return
        _add.update { it.copy(saving = true) }
        viewModelScope.launch {
            val dir = File(c.app.filesDir, "photos")
            val files = s.photos.mapNotNull { u -> PhotoPrep.decode(c.app, u)?.let { PhotoPrep.saveWebp(it, dir, UUID.randomUUID().toString()) } }
            s.photos.forEach { PhotoPrep.deleteIfCameraTemp(c.app, it) }
            val e = c.local.addPrivatePlace(s.name.trim(), s.category!!, s.pin.lat, s.pin.lng, s.address.ifBlank { null }, s.description.ifBlank { null },
                s.phone.ifBlank { null }, s.website.ifBlank { null }, s.hours, s.amenities.toList(), files)
            _add.value = AddPlaceState()
            _events.tryEmit(ContribEvent.Message(R.string.place_saved_private))
            _events.tryEmit(ContribEvent.ShowPlace(PlaceSummary("private:${e.id}", e.name, e.category, e.address ?: "", e.lat, e.lng)))
        }
    }

    /** "Share with everyone": POST /places, then upload the photos; other drivers verify it. */
    /** Community rules before the first public contribution (UgcTerms); false = shown, [retry] runs after "I agree". */
    private fun termsOk(retry: () -> Unit): Boolean {
        if (c.terms.accepted()) return true
        c.terms.require(retry)
        return false
    }

    fun savePublic(force: Boolean = false) {
        if (!termsOk { savePublic(force) }) return
        val s = _add.value
        if (!s.canContinue || s.privateOnly) return
        // Checked again at the moment of sending (the areas may have arrived since the pin step).
        if (c.restricted.zone(s.pin) == RestrictedZone.BLOCKED) { _add.update { it.copy(blockedSheet = true, zone = RestrictedZone.BLOCKED) }; return }
        val near = c.restricted.zone(s.pin) == RestrictedZone.NEAR
        _add.update { it.copy(saving = true, error = null, duplicate = if (force) null else it.duplicate) }
        viewModelScope.launch {
            try {
                val p = c.repo.createPlace(CreatePlaceRequest(
                    s.name.trim(), s.category!!, s.pin.lat, s.pin.lng, s.address.ifBlank { null }, s.description.ifBlank { null },
                    s.phone.ifBlank { null }, s.website.ifBlank { null }, s.hours, s.amenities.toList().ifEmpty { null },
                ))
                // Photos are refused within reviewM of a restricted area (docs/safety.md B): never sent from there.
                if (!near) s.photos.forEach { u -> PhotoPrep.decode(c.app, u)?.let { b -> runCatching { c.repo.uploadPhoto(p.id, PhotoPrep.jpeg(b), null) }.onSuccess { ph -> log.photo(ph.id, ph.url) } } }
                s.photos.forEach { PhotoPrep.deleteIfCameraTemp(c.app, it) }
                _add.value = AddPlaceState()
                _events.tryEmit(ContribEvent.Message(if (p.heldForReview) R.string.restricted_held else R.string.place_added_public))
                _events.tryEmit(ContribEvent.ShowPlace(p.summary()))
            } catch (e: HttpException) {
                val body = runCatching { e.response()?.errorBody()?.string() }.getOrNull()
                if (e.code() == 409) {
                    val existing = body?.let { b -> runCatching { GimanoJson.decodeFromString(Place.serializer(), b) }.getOrNull()
                        ?: runCatching { GimanoJson.decodeFromString(DuplicateProblem.serializer(), b).place }.getOrNull() }
                    _add.update { it.copy(saving = false, duplicate = existing, error = if (existing == null) "duplicate" else null) }
                } else {
                    _add.update { it.copy(saving = false, error = problemDetail(body) ?: "HTTP ${e.code()}") }
                }
            } catch (e: my.gimano.app.data.repo.RestrictedAreaException) {
                _add.update { it.copy(saving = false, error = e.detail) }   // 422 restricted_area: the server's own words
            } catch (e: Exception) {
                _add.update { it.copy(saving = false, error = e.message ?: e.javaClass.simpleName) }
            }
        }
    }

    private fun problemDetail(body: String?): String? = body?.let { b ->
        runCatching { GimanoJson.decodeFromString(ProblemDetails.serializer(), b) }.getOrNull()?.let { p ->
            p.errors?.toString()?.replace(Regex("[\\[\\]{}\"]"), "")?.replace(":", ": ")?.takeIf { it.isNotBlank() } ?: p.detail ?: p.title
        }
    }

    // ---------------------------------------------------------------- verify / suggest an edit

    /**
     * Vote on a pending community place (docs/identity-and-reputation.md §4). The phone checks it is within
     * 1 km (5 km rural) and sends only {cell, withinM}; the request is signed by the interceptor.
     */
    fun verify(target: VetTarget, answer: String, nameCorrect: Boolean?, locationCorrect: Boolean?, onDone: (VerifyResult) -> Unit = {}): kotlinx.coroutines.Job? {
        if (!termsOk { verify(target, answer, nameCorrect, locationCorrect, onDone) }) return null
        return verifyNow(target, answer, nameCorrect, locationCorrect, onDone)
    }

    private fun verifyNow(target: VetTarget, answer: String, nameCorrect: Boolean?, locationCorrect: Boolean?, onDone: (VerifyResult) -> Unit) = viewModelScope.launch {
        val me = c.lastFix ?: run { _events.tryEmit(ContribEvent.Message(R.string.vet_need_location)); return@launch }
        val within = my.gimano.app.core.vetting.Proximity.withinM(me, my.gimano.app.core.geo.GeoPoint(target.lat, target.lng), target.rural)
            ?: run { _events.tryEmit(ContribEvent.Text(c.app.getString(R.string.vet_too_far, my.gimano.app.core.format.Formatters.distance(my.gimano.app.core.vetting.Proximity.limitM(target.rural).toDouble())))); return@launch }
        val cell = my.gimano.app.core.vetting.Geohash.encode(me.lat, me.lng, 6)
        val ts = c.remote.nowTs()
        val att = c.integrity.token(my.gimano.app.core.identity.RequestSigning.attestClientData(target.id, ts))?.let { VerifyRequest.Attestation("android", it) }
        runCatching { c.repo.verifyPlace(target.id, VerifyRequest(answer, nameCorrect, locationCorrect, VerifyRequest.Proximity(cell, within), att), ts) }
            .onSuccess { r ->
                c.vetting.markAnswered(target.id)
                onDone(r)
                _events.tryEmit(
                    if (r.status == "published") ContribEvent.Message(R.string.vet_published)
                    else ContribEvent.Text(c.app.getString(R.string.vet_thanks, fmtWeight(r.confirmationsWeighted), fmtWeight(r.required))),
                )
            }
            .onFailure { e ->
                val msg = (e as? my.gimano.app.data.repo.RestrictedAreaException)?.detail
                    ?: (e as? retrofit2.HttpException)?.response()?.errorBody()?.string()?.let(::problemDetail)
                _events.tryEmit(if (msg != null) ContribEvent.Text(msg) else ContribEvent.Message(R.string.action_failed))
            }
    }

    fun suggestEdit(placeId: String, body: SuggestEditRequest) {
        if (!termsOk { suggestEdit(placeId, body) }) return
        suggestEditNow(placeId, body)
    }

    private fun suggestEditNow(placeId: String, body: SuggestEditRequest) = viewModelScope.launch {
        runCatching { c.repo.suggestEdit(placeId, body) }
            .onSuccess { _events.tryEmit(ContribEvent.Message(R.string.thanks_suggestion)) }
            .onFailure { _events.tryEmit(failure(it, R.string.action_failed)) }
    }

    // ---------------------------------------------------------------- reviews & photos

    fun loadReviews(place: Place) {
        _reviews.value = ReviewsState(placeId = place.id, loading = true, summary = RatingSummary.of(emptyList(), place.rating, place.reviewCount))
        viewModelScope.launch {
            val page = runCatching { c.repo.reviews(place.id, "recent") }.getOrNull()
            val list = page?.reviews.orEmpty()
            _reviews.update {
                if (it.placeId != place.id) it else it.copy(reviews = list, loading = false,
                    summary = RatingSummary.of(list.map { r -> r.rating }, place.rating ?: list.takeIf { l -> l.isNotEmpty() }?.map { r -> r.rating }?.average(), maxOf(place.reviewCount, list.size)))
            }
        }
    }

    private var myReviewIds = HashSet<String>()
    fun mine(r: Review) = r.mine || r.id in myReviewIds

    fun openReview(existing: Review? = null) {
        if (!termsOk { openReview(existing) }) return
        _reviews.update { it.copy(draft = existing?.let { r -> ReviewDraft(r.rating, r.text.orEmpty(), editingId = r.id) } ?: ReviewDraft()) }
    }
    fun closeReview() = _reviews.update { it.copy(draft = null) }
    fun updateDraft(f: (ReviewDraft) -> ReviewDraft) = _reviews.update { it.copy(draft = it.draft?.let(f)) }

    /** C in a review: "Buang ayat ini". */
    fun removeSensitiveFromReview() = updateDraft { it.copy(text = sensitive.removeSentences(it.text)) }

    /** Photos of a public place are off within reviewM of a restricted area (the server refuses them too). */
    fun photosAllowedAt(lat: Double, lng: Double): Boolean = c.restricted.zone(GeoPoint(lat, lng)) == RestrictedZone.CLEAR

    /** Review photos upload as soon as they are picked (≤ 5); the review then references them. */
    fun addReviewPhotos(uris: List<Uri>) {
        val placeId = _reviews.value.placeId ?: return
        val room = 5 - (_reviews.value.draft?.uploads?.size ?: 0)
        uris.take(room).forEach { u ->
            val item = UploadItem(UUID.randomUUID().toString(), u)
            updateDraft { it.copy(uploads = it.uploads + item) }
            viewModelScope.launch {
                val ph = upload(placeId, u)
                updateDraft { d -> d.copy(uploads = d.uploads.map { if (it.key == item.key) it.copy(photo = ph, failed = ph == null) else it }) }
            }
        }
    }

    private suspend fun upload(placeId: String, u: Uri): Photo? {
        val b = PhotoPrep.decode(c.app, u) ?: return null
        return runCatching { c.repo.uploadPhoto(placeId, PhotoPrep.jpeg(b), null) }
            .onFailure { e -> if (e is my.gimano.app.data.repo.RestrictedAreaException) _events.tryEmit(ContribEvent.Text(e.detail)) }
            .getOrNull()?.also {
            log.photo(it.id, it.url)
            PhotoPrep.deleteIfCameraTemp(c.app, u)   // uploaded: the camera's temp file is no longer needed
        }
    }

    fun submitReview(place: Place) {
        val d = _reviews.value.draft ?: return
        if (d.rating !in 1..5) return
        updateDraft { it.copy(sending = true) }
        viewModelScope.launch {
            val body = ReviewRequest(d.rating, d.text.trim().ifBlank { null }, d.uploads.mapNotNull { it.photo?.id }.ifEmpty { null })
            runCatching { if (d.editingId != null) c.repo.updateReview(d.editingId, body) else c.repo.createReview(place.id, body) }
                .onSuccess { r ->
                    myReviewIds += r.id
                    log.review(r.id, place.name, held = r.heldForReview)
                    _reviews.update { it.copy(draft = null) }
                    _events.tryEmit(ContribEvent.Message(if (r.heldForReview) R.string.restricted_held else R.string.review_posted))
                    loadReviews(place)
                }
                .onFailure { e ->
                    updateDraft { it.copy(sending = false) }
                    _events.tryEmit(failure(e, if ((e as? HttpException)?.code() == 409) R.string.review_one_per_place else R.string.action_failed))
                }
        }
    }

    fun helpful(r: Review) {
        if (!termsOk { helpful(r) }) return
        helpfulNow(r)
    }

    private fun helpfulNow(r: Review) = viewModelScope.launch {
        runCatching { c.repo.helpful(r.id) }.onSuccess {
            _reviews.update { s -> s.copy(reviews = s.reviews.map { if (it.id == r.id) it.copy(helpfulCount = it.helpfulCount + 1) else it }) }
        }
    }

    fun flag(r: Review, reason: String) = viewModelScope.launch {
        runCatching { c.repo.flagReview(r.id, reason) }.onSuccess { _events.tryEmit(ContribEvent.Message(R.string.thanks_flag)) }
    }

    /** "Report photo" (POST /photos/{id}/flag), same reasons as a review. */
    fun flagPhoto(p: my.gimano.app.data.model.Photo, reason: String) = viewModelScope.launch {
        runCatching { c.repo.flagPhoto(p.id, reason) }.onSuccess { _events.tryEmit(ContribEvent.Message(R.string.thanks_flag)) }
    }

    /** "Report place" (community places only; POST /places/{id}/flag). */
    fun flagPlace(p: Place, reason: String) = viewModelScope.launch {
        runCatching { c.repo.flagPlace(p.id, reason) }.onSuccess { _events.tryEmit(ContribEvent.Message(R.string.thanks_flag)) }
    }

    /** "Block this user": on this phone only (never sent); their reviews and photos disappear everywhere. */
    fun blockAuthor(a: my.gimano.app.data.model.Author) = viewModelScope.launch {
        if (a.authorRef == null) return@launch
        c.blocks.block(a)
        _events.tryEmit(ContribEvent.Message(R.string.blocked_done))
    }

    /** "Add photo" on the place card: upload with progress, then show the processing state. */
    fun addPlacePhotos(place: Place, uris: List<Uri>, onDone: () -> Unit) {
        uris.take(10).forEach { u ->
            val item = UploadItem(UUID.randomUUID().toString(), u)
            _reviews.update { it.copy(placeUploads = it.placeUploads + item) }
            viewModelScope.launch {
                val ph = upload(place.id, u)
                _reviews.update { s -> s.copy(placeUploads = s.placeUploads.map { if (it.key == item.key) it.copy(photo = ph, failed = ph == null) else it }) }
                if (ph != null) onDone()
            }
        }
    }

    class Factory(private val c: AppContainer) : ViewModelProvider.Factory {
        @Suppress("UNCHECKED_CAST")
        override fun <T : ViewModel> create(modelClass: Class<T>): T = ContributeViewModel(c) as T
    }
}

@kotlinx.serialization.Serializable
data class DuplicateProblem(val place: Place? = null)

/** What a vote needs about the place. */
data class VetTarget(val id: String, val lat: Double, val lng: Double, val rural: Boolean) {
    companion object {
        fun of(p: PlaceSummary) = VetTarget(p.id, p.lat, p.lng, p.rural)
        fun of(p: Place) = VetTarget(p.id, p.lat, p.lng, p.rural)
    }
}

/** "1", "1.5", "2" */
fun fmtWeight(w: Double): String = if (w % 1.0 == 0.0) w.toLong().toString() else "%.1f".format(java.util.Locale.US, w)
