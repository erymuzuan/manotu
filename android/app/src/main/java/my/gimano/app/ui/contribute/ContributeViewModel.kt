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
import my.gimano.app.core.places.AddResult
import my.gimano.app.core.places.CreateFailure
import my.gimano.app.core.places.OpeningHours
import my.gimano.app.core.places.PlaceGate
import my.gimano.app.core.places.RatingSummary
import my.gimano.app.core.safety.AppealError
import my.gimano.app.core.safety.AppealRules
import my.gimano.app.core.safety.AppealState
import my.gimano.app.core.safety.RefusedItem
import my.gimano.app.core.safety.RefusedKind
import my.gimano.app.core.safety.ContentFailure
import my.gimano.app.core.safety.ContentGate
import my.gimano.app.core.safety.ContentState
import my.gimano.app.core.safety.PlaceWarning
import my.gimano.app.core.safety.PostingPause
import my.gimano.app.core.safety.ReviewState
import my.gimano.app.data.places.PlaceDraft
import my.gimano.app.core.safety.RestrictedZone
import my.gimano.app.data.model.*
import my.gimano.app.data.places.ContributionLog
import my.gimano.app.data.places.PhotoPrep
import my.gimano.app.data.remote.GimanoJson
import retrofit2.HttpException
import java.io.File
import java.util.UUID

enum class AddStep { PIN, DETAILS, WARNINGS, VISIBILITY }

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
    val error: String? = null,
    /** What the AI-gate flow shows over the form (A1, A3, the results, B1, B5, B6, C1); null = the form itself. */
    val overlay: AddOverlay? = null,
    /** Editing a place already on the server ("Edit and try again", "Edit description"): PATCH instead of POST. */
    val editingId: String? = null,
    /** [editingId] is a place the check didn't accept: "Just for me" then removes that server copy. */
    val editingRejected: Boolean = false,
    /** Sending a draft kept on this phone: removed once it is sent. */
    val draftId: String? = null,
    /** B1 "No, mine is a different place": the existing place's id, sent as notDuplicateOf. */
    val notDuplicateOf: String? = null,
    /** C1: the note being written (≤ 200 characters). */
    val appealNote: String = "",
    val appealSending: Boolean = false,
    /** The result was opened from the Inbox or My places (not right after sending): "OK" goes back there. */
    val fromList: Boolean = false,
    /** docs/safety.md §4: where the pin is relative to the restricted areas (checked on the phone, offline). */
    val zone: RestrictedZone = RestrictedZone.CLEAR,
    /** A: "Tidak boleh dikongsi di sini" instead of the form. */
    val blockedSheet: Boolean = false,
    /** "Simpan untuk saya sahaja" from A: a private place (allowed anywhere, photos included), never public. */
    val privateOnly: Boolean = false,
    /** "Anything people should know?": the owner's warnings, sent as `warnings[]` on a public place. */
    val warnings: Set<PlaceWarning> = emptySet(),
) {
    /** B: near an area, sharing publicly: a note, no photos, held for a moderator. */
    val nearArea get() = zone == RestrictedZone.NEAR && !privateOnly
    val hours: String? get() = if (!hoursEnabled) null else OpeningHours.build(week, open247).ifBlank { null }
    val canContinue get() = name.isNotBlank() && category != null

    fun request(): CreatePlaceRequest = CreatePlaceRequest(
        name.trim(), category ?: "other", pin.lat, pin.lng, address.ifBlank { null }, description.trim().ifBlank { null },
        phone.ifBlank { null }, website.ifBlank { null }, hours, amenities.toList().ifEmpty { null }, notDuplicateOf,
        PlaceWarning.wire(warnings),
    )
}

/** The AI-gate screens (design "Add a place with an AI gate", boards A1–C1). */
sealed interface AddOverlay {
    /** A1: how adding a place works (once, before the first shared place). */
    data object Intro : AddOverlay
    /** A3: waiting for the server's checks. */
    data object Checking : AddOverlay
    /** A4, A5, B2, B3, B4, B6 (still checking): what the server answered. */
    data class Result(val place: Place, val kind: AddResult) : AddOverlay
    /** B1: a similar place is already on the map (409). */
    data class Duplicate(val existing: PlaceSummary?) : AddOverlay
    /** B5: the hourly/daily limit (429), [minutes] until the next share. */
    data class Limit(val minutes: Int?, val retryAfterSeconds: Int?) : AddOverlay
    /** B5, paused variant (403 adding_paused). */
    data class Paused(val until: java.time.Instant?) : AddOverlay
    /** B6, no connection: saved on this phone, sent when back online. */
    data object Offline : AddOverlay
    /** C1: ask a person to review a place that wasn't accepted. [back] is the result screen it came from. */
    data class Appeal(val place: Place, val back: Result) : AddOverlay
}

/** One photo being attached: uploading → processing → published (or failed). */
data class UploadItem(val key: String, val uri: Uri, val photo: Photo? = null, val failed: Boolean = false, val refusal: PhotoRefusal? = null) {
    val processing get() = photo?.status == "processing"
    /** Still going up: no answer yet (a refusal or a failure is an answer). */
    val uploading get() = photo == null && !failed && refusal == null
}

/** POST /photos answered 422 `content_rejected`: nothing was stored; the photo is kept on the phone as [refusedId] (Not accepted). */
data class PhotoRefusal(val refusedId: String, val reasons: List<String>)

/** What an appeal is about. */
sealed interface AppealTarget {
    /** Something the server refused (422): POST /appeals with the saved text. */
    data class Refusal(val item: RefusedItem) : AppealTarget
    /** Something the server stored and held or rejected (an own review, photo or place): POST /{kind}s/{id}/appeal. */
    data class Existing(val kind: RefusedKind, val id: String, val placeName: String?, val text: String?, val reasons: List<String>) : AppealTarget
}

/** One evidence photo on the Appeal screen: a picker [uri] (copied when sent) or a [file] saved on the phone. */
data class AppealPhoto(val key: String, val uri: Uri? = null, val file: File? = null)

/** The Appeal screen. [done] shows the "pending" result; [error] an icon-led message; [pausedUntil] goes with PAUSED. */
data class AppealUi(
    val target: AppealTarget,
    val note: String = "",
    val photos: List<AppealPhoto> = emptyList(),
    val sending: Boolean = false,
    val error: AppealError? = null,
    val pausedUntil: java.time.Instant? = null,
    val done: Boolean = false,
) {
    val canSend: Boolean get() = AppealRules.canSend(note, sending, (target as? AppealTarget.Refusal)?.item?.appealState ?: AppealState.NONE) &&
        ((target as? AppealTarget.Refusal)?.item?.appealable ?: true)
}

data class ReviewDraft(
    val rating: Int = 0, val text: String = "", val uploads: List<UploadItem> = emptyList(), val editingId: String? = null, val sending: Boolean = false,
    /** 422 `content_rejected`: the "Can't post this" sheet (nothing was stored). */
    val rejection: ContentFailure.Rejected? = null,
    /** The saved copy of the last refusal of this draft (Not accepted list); removed once an edited version is posted. */
    val refusedId: String? = null,
    /** 403 `posting_paused`: the "Paused" sheet. */
    val paused: java.time.Instant? = null,
)

data class ReviewsState(
    val placeId: String? = null,
    val reviews: List<Review> = emptyList(),
    val loading: Boolean = false,
    val summary: RatingSummary = RatingSummary.of(emptyList()),
    val draft: ReviewDraft? = null,
    val placeName: String? = null,
    val placeUploads: List<UploadItem> = emptyList(),
    /** The rejected photo whose screen is open (its photo id). */
    val rejectedPhotoId: String? = null,
    /** The photo the server refused at upload (kept on the phone): its refused id. */
    val refusedPhotoId: String? = null,
)

sealed interface ContribEvent {
    data class Message(val res: Int) : ContribEvent
    /** Leave the add-a-place flow ("Batal" on the blocked-pin sheet). */
    data object Close : ContribEvent
    data class Text(val text: String) : ContribEvent
    data class ShowPlace(val summary: PlaceSummary) : ContribEvent
    /** Leave the flow for My places (the boards' "Done" / "OK"). */
    data object OpenMyPlaces : ContribEvent
    /** Show the add-a-place screen (a result or a draft opened from the Inbox or My places). */
    data object OpenAddPlace : ContribEvent
    /** A4 "Share place": the system share sheet with [text]. */
    data class Share(val text: String) : ContribEvent
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
        activeSend = 0
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

    val use24h: Boolean get() = c.settings.current.use24h

    /** My places (C3): drafts waiting on this phone. */
    val drafts get() = c.placeDrafts.drafts

    /** Pin step "Next": a pin in a restricted area (or within blockM) gets A instead of the form. */
    fun nextFromPin() {
        val s = _add.value
        if (!s.privateOnly && c.restricted.zone(s.pin) == RestrictedZone.BLOCKED) _add.update { it.copy(blockedSheet = true) }
        else {
            step(AddStep.DETAILS)
            // A1, once on this phone, before the first shared place (a "just for me" place never leaves the phone).
            if (!s.privateOnly && !c.addPlaceIntro.seen) _add.update { it.copy(overlay = AddOverlay.Intro) }
        }
    }

    /** A1 · "Got it". */
    fun introSeen() {
        c.addPlaceIntro.markSeen()
        _add.update { it.copy(overlay = null) }
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
    fun step(s: AddStep) = _add.update { it.copy(step = s, error = null) }
    fun addPhotos(uris: List<Uri>) = _add.update { it.copy(photos = (it.photos + uris).distinct().take(10)) }
    fun removePhoto(u: Uri) = _add.update { it.copy(photos = it.photos - u) }

    /**
     * "Just for me": stays in the on-device DB (and the user's own backup), never sent to the server. From B4 ("Keep it
     * just for me") or B5, the server's not-accepted copy and any draft on the phone are removed too.
     */
    fun savePrivate() {
        val s = _add.value
        if (!s.canContinue) return
        _add.update { it.copy(saving = true, overlay = null) }
        viewModelScope.launch {
            // B4 "Keep it just for me": the not-accepted public copy goes; the place now lives only on this phone.
            s.editingId?.takeIf { s.editingRejected }?.let { id -> runCatching { c.repo.deletePlace(id) } }
            val dir = File(c.app.filesDir, "photos")
            val files = s.photos.mapNotNull { u -> PhotoPrep.decode(c.app, u)?.let { PhotoPrep.saveWebp(it, dir, UUID.randomUUID().toString()) } }
            s.photos.forEach { PhotoPrep.deleteIfCameraTemp(c.app, it) }
            s.draftId?.let { id -> runCatching { c.placeDrafts.delete(id) } }   // after its photos were copied
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

    /** Which send is on screen; 0 after "Close" on A3 (the answer then arrives as a short message and in the Inbox). */
    private var activeSend = 0
    private var sendSeq = 0

    /**
     * "Share with everyone": POST /places (or PATCH when editing a place the check held or didn't accept), then the
     * photos. While the server checks, A3; then the answer's screen (A4/A5/B2/B3/B4/B6) or B1/B5 for a refusal.
     */
    fun savePublic() {
        if (!termsOk { savePublic() }) return
        val s = _add.value
        if (!s.canContinue || s.privateOnly) return
        // Checked again at the moment of sending (the areas may have arrived since the pin step).
        if (c.restricted.zone(s.pin) == RestrictedZone.BLOCKED) { _add.update { it.copy(blockedSheet = true, zone = RestrictedZone.BLOCKED) }; return }
        val near = c.restricted.zone(s.pin) == RestrictedZone.NEAR
        val token = ++sendSeq
        activeSend = token
        _add.update { it.copy(saving = true, error = null, overlay = AddOverlay.Checking) }
        viewModelScope.launch {
            try {
                val req = s.request()
                val p = if (s.editingId != null) c.repo.updatePlace(s.editingId, req) else c.repo.createPlace(req)
                // Photos are refused within reviewM of a restricted area (docs/safety.md B): never sent from there.
                if (!near) s.photos.forEach { u -> PhotoPrep.decode(c.app, u)?.let { b -> runCatching { c.repo.uploadPhoto(p.id, PhotoPrep.jpeg(b), null) }.onSuccess { ph -> log.photo(ph.id, ph.url) } } }
                s.photos.forEach { PhotoPrep.deleteIfCameraTemp(c.app, it) }
                s.draftId?.let { runCatching { c.placeDrafts.delete(it) } }
                val kind = PlaceGate.result(p)
                if (activeSend != token) { _events.tryEmit(ContribEvent.Message(lateMessage(kind))); return@launch }
                // The form stays behind the result: "Edit and try again" / "Keep it just for me" reuse it.
                _add.update { it.copy(saving = false, overlay = AddOverlay.Result(p, kind), editingId = p.id, editingRejected = kind.notAccepted, draftId = null,
                    notDuplicateOf = null, photos = emptyList()) }
            } catch (e: HttpException) {
                val body = runCatching { e.response()?.errorBody()?.string() }.getOrNull()
                val f = PlaceGate.failure(e.code(), body, e.response()?.headers()?.get("Retry-After"))
                if (activeSend != token) { if (f !is CreateFailure.Other) _events.tryEmit(ContribEvent.Message(R.string.add_late_attention)); return@launch }
                _add.update {
                    when (f) {
                        is CreateFailure.Duplicate -> it.copy(saving = false, overlay = AddOverlay.Duplicate(f.existing))
                        is CreateFailure.RateLimited -> it.copy(saving = false, overlay = AddOverlay.Limit(f.minutes, f.retryAfterSeconds))
                        is CreateFailure.Paused -> it.copy(saving = false, overlay = AddOverlay.Paused(f.until))
                        is CreateFailure.Other -> it.copy(saving = false, overlay = null, error = problemDetail(body) ?: "HTTP ${e.code()}")
                    }
                }
            } catch (e: my.gimano.app.data.repo.RestrictedAreaException) {
                _add.update { it.copy(saving = false, overlay = null, error = e.detail) }   // 422 restricted_area: the server's own words
            } catch (e: java.io.IOException) {
                // B6, no connection: kept on the phone and sent (and checked) when the server answers again.
                if (s.editingId == null && my.gimano.app.core.net.Reachability.isUnreachable(e)) {
                    val id = saveDraft(s, PlaceDraft.OFFLINE, null)
                    if (activeSend != token) { _events.tryEmit(ContribEvent.Message(R.string.add_offline_saved)); return@launch }
                    _add.update { it.copy(saving = false, overlay = AddOverlay.Offline, draftId = id) }
                } else _add.update { it.copy(saving = false, overlay = null, error = e.message ?: e.javaClass.simpleName) }
            } catch (e: kotlinx.coroutines.CancellationException) {
                throw e
            } catch (e: Exception) {
                _add.update { it.copy(saving = false, overlay = null, error = e.message ?: e.javaClass.simpleName) }
            }
        }
    }

    /** A3 · "Close": the request carries on; its answer comes as a short message (and in the Inbox). */
    fun closeChecking() {
        activeSend = 0
        _add.value = AddPlaceState()
        _events.tryEmit(ContribEvent.Close)
    }

    private fun lateMessage(kind: AddResult): Int = when (kind) {
        AddResult.LIVE, AddResult.GOLD -> R.string.add_late_live
        AddResult.HELD -> R.string.add_late_held
        AddResult.NOT_ACCEPTED, AddResult.NOT_ACCEPTED_PERSONAL -> R.string.add_late_not_accepted
        AddResult.CHECKING -> R.string.add_late_checking
        AddResult.PENDING -> R.string.place_added_public
    }

    /** Leaves the result screens: back to My places (the boards' "Done" / "OK"). */
    fun finish() {
        activeSend = 0
        _add.value = AddPlaceState()
        _events.tryEmit(ContribEvent.OpenMyPlaces)
    }

    fun dismissOverlay() = _add.update { it.copy(overlay = null) }

    /** A4 · "Share place". */
    fun sharePlace(p: Place) {
        val link = String.format(java.util.Locale.US, "https://www.openstreetmap.org/?mlat=%.5f&mlon=%.5f#map=17/%.5f/%.5f", p.lat, p.lng, p.lat, p.lng)
        _events.tryEmit(ContribEvent.Share(listOf(p.name, p.address, link).filter { it.isNotBlank() }.joinToString("\n")))
    }

    /** B1 · "Yes, that's it: suggest an edit": the existing place's card with its suggest-an-edit sheet open. */
    fun duplicateIsSame(existing: PlaceSummary) {
        _add.value = AddPlaceState()
        suggestFor.value = existing.id
        _events.tryEmit(ContribEvent.ShowPlace(existing))
    }

    /** B1 · "No, mine is a different place": sent again with that answer (notDuplicateOf). */
    fun duplicateIsDifferent(existing: PlaceSummary?) {
        _add.update { it.copy(overlay = null, notDuplicateOf = existing?.id) }
        savePublic()
    }

    /** The place card opens "Suggest an edit" for this id once (B1). */
    val suggestFor = MutableStateFlow<String?>(null)

    /** B2 "Edit description" / B3 "Edit and try again": back to the form; the next send is a PATCH of the same place. */
    fun editAgain() = _add.update { it.copy(overlay = null, step = AddStep.DETAILS, error = null) }

    /** B3 / B4 · "Discard": the not-accepted place is removed from the server (only its owner could see it). */
    fun discard(p: Place) {
        viewModelScope.launch {
            runCatching { c.repo.deletePlace(p.id) }
            _add.value = AddPlaceState()
            _events.tryEmit(ContribEvent.Message(R.string.add_discarded))
            _events.tryEmit(ContribEvent.OpenMyPlaces)
        }
    }

    /** B3 / B4 → C1 "Ask for a review". */
    fun openAppeal() = _add.update { s ->
        val r = s.overlay as? AddOverlay.Result ?: return@update s
        s.copy(overlay = AddOverlay.Appeal(r.place, r), appealNote = "")
    }

    fun appealNote(v: String) = _add.update { it.copy(appealNote = v.take(PlaceGate.APPEAL_MAX)) }

    /** C1 · back arrow: the result it came from. */
    fun closeAppeal() = _add.update { s -> (s.overlay as? AddOverlay.Appeal)?.let { s.copy(overlay = it.back) } ?: s }

    /** C1 · "Send for review": POST /places/{id}/appeal → held for a maintainer (B2, "You asked for a review"). */
    fun sendAppeal() {
        val s = _add.value
        val a = s.overlay as? AddOverlay.Appeal ?: return
        if (!termsOk { sendAppeal() }) return
        _add.update { it.copy(appealSending = true) }
        viewModelScope.launch {
            runCatching { c.repo.appealPlace(a.place.id, s.appealNote.trim().ifBlank { null }) }
                .onSuccess { p -> _add.update { it.copy(appealSending = false, overlay = AddOverlay.Result(p, AddResult.HELD), appealNote = "") } }
                .onFailure { e ->
                    _add.update { it.copy(appealSending = false) }
                    _events.tryEmit(failure(e, if ((e as? HttpException)?.code() == 409) R.string.appeal_already else R.string.action_failed))
                }
        }
    }

    // ---------------------------------------------------------------- drafts on the phone (B5, B6)

    /** B5 · "Save draft": kept on this phone (outbox, never backed up), shared later from My places. */
    fun saveLimitedDraft() {
        val s = _add.value
        val (reason, notBefore) = when (val o = s.overlay) {
            is AddOverlay.Limit -> PlaceDraft.LIMIT to o.retryAfterSeconds?.let { java.time.Instant.now().plusSeconds(it.toLong()) }
            is AddOverlay.Paused -> PlaceDraft.PAUSED to o.until
            else -> PlaceDraft.LIMIT to null
        }
        viewModelScope.launch {
            saveDraft(s, reason, notBefore)
            _add.value = AddPlaceState()
            _events.tryEmit(ContribEvent.Message(R.string.add_draft_saved))
            _events.tryEmit(ContribEvent.OpenMyPlaces)
        }
    }

    /** Copies the photos (metadata-stripped JPEG) and stores the draft; returns its id. */
    private suspend fun saveDraft(s: AddPlaceState, reason: String, notBefore: java.time.Instant?): String {
        val id = s.draftId ?: ("draft-" + UUID.randomUUID().toString())
        val near = c.restricted.zone(s.pin) == RestrictedZone.NEAR
        val existing = c.placeDrafts.get(id)?.photos.orEmpty().toSet()
        val photos = if (near) emptyList() else s.photos.mapIndexedNotNull { i, u ->
            u.path?.takeIf { u.scheme == "file" && it in existing }
                ?: PhotoPrep.decode(c.app, u)?.let { b -> c.placeDrafts.photoFile(id, i + existing.size).also { f -> f.writeBytes(PhotoPrep.jpeg(b)) }.path }
        }
        s.photos.forEach { PhotoPrep.deleteIfCameraTemp(c.app, it) }
        c.placeDrafts.save(PlaceDraft(id, s.request().copy(notDuplicateOf = s.notDuplicateOf), reason, notBefore?.toString(),
            java.time.Instant.now().toString(), photos, nearArea = near))
        return id
    }

    /** My places · a draft: back into the flow; before its time is up, B5 says how long is left. */
    fun openDraft(id: String) {
        viewModelScope.launch {
            val d = c.placeDrafts.get(id) ?: return@launch
            val r = d.request
            val pin = GeoPoint(r.lat, r.lng)
            val now = java.time.Instant.now()
            val left = d.readyAt()?.takeIf { it.isAfter(now) }?.let { java.time.Duration.between(now, it).seconds.toInt() }
            _add.value = AddPlaceState(
                step = AddStep.VISIBILITY, pin = pin, address = r.address.orEmpty(), name = r.name, category = r.category, phone = r.phone.orEmpty(),
                website = r.website.orEmpty(), description = r.description.orEmpty(), amenities = r.amenities.orEmpty().toSet(),
                hoursEnabled = r.openingHours != null, photos = d.photos.map { Uri.fromFile(File(it)) }, zone = c.restricted.zone(pin),
                draftId = d.id, notDuplicateOf = r.notDuplicateOf, fromList = true, warnings = PlaceWarning.of(r.warnings).toSet(),
                overlay = when {
                    left == null -> null
                    d.reason == PlaceDraft.PAUSED -> AddOverlay.Paused(d.readyAt())
                    else -> AddOverlay.Limit(PlaceGate.minutes(left), left)
                },
            ).let { st -> r.openingHours?.let { h -> st.withHours(h) } ?: st }
            _events.tryEmit(ContribEvent.OpenAddPlace)
        }
    }

    /** My places · "Discard" on a draft. */
    fun discardDraft(id: String) = viewModelScope.launch { c.placeDrafts.delete(id) }

    /**
     * Inbox (place_held / place_not_accepted / place_live) or My places: the result screen for one of my places, with
     * the form filled in behind it (so "Edit and try again" and "Keep it just for me" work).
     */
    fun openResult(placeId: String, summary: PlaceSummary? = null) {
        viewModelScope.launch {
            val mine = summary ?: runCatching { c.repo.contributedPlaces() }.getOrNull()?.firstOrNull { it.id == placeId }
            val detail = runCatching { c.repo.place(placeId) }.getOrNull()
            val p = (detail ?: mine?.let { m -> Place(m.id, m.name, m.category, m.address, m.lat, m.lng, source = m.source) } ?: run {
                _events.tryEmit(ContribEvent.Message(R.string.action_failed)); return@launch
            }).let { d ->
                // The owner's view (status, check, confirmations) comes from GET /me/places/contributed.
                if (mine == null) d else d.copy(status = mine.status ?: d.status, heldForReview = mine.heldForReview, screening = mine.screening ?: d.screening,
                    confirmationsWeighted = mine.confirmationsWeighted ?: d.confirmationsWeighted, required = mine.required ?: d.required)
            }
            val pin = GeoPoint(p.lat, p.lng)
            _add.value = AddPlaceState(
                step = AddStep.DETAILS, pin = pin, address = p.address, name = p.name, category = p.category, phone = p.phone.orEmpty(),
                website = p.website.orEmpty(), description = p.description.orEmpty(), amenities = p.amenities.toSet(), zone = c.restricted.zone(pin),
                editingId = p.id, editingRejected = PlaceGate.result(p).notAccepted, fromList = true, warnings = PlaceWarning.of(p.warnings).toSet(), overlay = AddOverlay.Result(p, PlaceGate.result(p)),
            ).let { st -> p.openingHours?.let { h -> st.withHours(h) } ?: st }
            _events.tryEmit(ContribEvent.OpenAddPlace)
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

    /** [keep]: the author's own review that the list may not carry yet (held or still being checked): shown with its status. */
    fun loadReviews(place: Place, keep: Review? = null) {
        _reviews.value = ReviewsState(placeId = place.id, placeName = place.name, loading = true, summary = RatingSummary.of(emptyList(), place.rating, place.reviewCount))
        viewModelScope.launch {
            val page = runCatching { c.repo.reviews(place.id, "recent") }.getOrNull()
            val list = page?.reviews.orEmpty().let { l -> if (keep != null && l.none { it.id == keep.id }) listOf(keep) + l else l }
            _reviews.update {
                if (it.placeId != place.id) it else it.copy(reviews = list, loading = false,
                    summary = RatingSummary.of(list.map { r -> r.rating }, place.rating ?: list.takeIf { l -> l.isNotEmpty() }?.map { r -> r.rating }?.average(), maxOf(place.reviewCount, list.size)))
            }
        }
    }

    private var myReviewIds = HashSet<String>()
    fun mine(r: Review) = r.mine || r.id in myReviewIds

    /** [rating] = the star tapped on the place page (1-5), 0 to start without one. */
    fun openReview(existing: Review? = null, rating: Int = 0) {
        if (!termsOk { openReview(existing, rating) }) return
        PostingPause.active()?.let { until -> _reviews.update { it.copy(draft = ReviewDraft(paused = until)) }; return }
        _reviews.update { it.copy(draft = existing?.let { r -> ReviewDraft(r.rating, r.text.orEmpty(), editingId = r.id) } ?: ReviewDraft(rating = rating.coerceIn(0, 5))) }
    }
    fun closeReview() = _reviews.update { it.copy(draft = null) }

    /** "Can't post this" · Appeal: the Appeal screen for the saved copy of the refused review. */
    fun appealRejection() { _reviews.value.draft?.refusedId?.let(::openAppealFor) }

    /** "Can't post this" · Edit: back to the text, as it was. */
    fun dismissRejection() = updateDraft { it.copy(rejection = null) }

    /** "Can't post this" · "Post this part": the server's safe text replaces the draft and is sent again. */
    fun postSafePart(place: Place) {
        val part = _reviews.value.draft?.rejection?.let(ContentGate::safePart) ?: return
        updateDraft { it.copy(text = part, rejection = null) }
        submitReview(place)
    }
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
                val (ph, refusal) = upload(placeId, _reviews.value.placeName, u)
                updateDraft { d -> d.copy(uploads = d.uploads.map { if (it.key == item.key) it.copy(photo = ph, failed = ph == null && refusal == null, refusal = refusal) else it }) }
            }
        }
    }

    private suspend fun upload(placeId: String, placeName: String?, u: Uri): Pair<Photo?, PhotoRefusal?> {
        val b = PhotoPrep.decode(c.app, u) ?: return null to null
        val jpeg = PhotoPrep.jpeg(b)
        val photo = runCatching { c.repo.uploadPhoto(placeId, jpeg, null) }
            .onFailure { e ->
                if (e is my.gimano.app.data.repo.RestrictedAreaException) _events.tryEmit(ContribEvent.Text(e.detail))
                else if (e is HttpException) when (val f = ContentGate.failure(e.code(), runCatching { e.response()?.errorBody()?.string() }.getOrNull())) {
                    is ContentFailure.Paused -> { PostingPause.set(f.until ?: java.time.Instant.now().plusSeconds(24 * 3600)); _events.tryEmit(ContribEvent.Message(R.string.cs_paused_short)) }
                    // POST /photos never answers 422 (docs/content-safety.md "Photos"): a refused photo is stored and turns
                    // `rejected` later (GET /photos/{id}, polled by track()); its reason icons + Appeal come from that photo.
                    else -> Unit
                }
            }
            .getOrNull()?.also {
                log.photo(it.id, it.url)
                PhotoPrep.deleteIfCameraTemp(c.app, u)   // uploaded: the camera's temp file is no longer needed
                track(it)
            }
        return photo to null
    }

    // ---------------------------------------------------------------- refused content (on the phone only) and appeals

    /** Keeps what the server refused in the on-device DB (never sent anywhere unless the user appeals). */
    private suspend fun keepRefused(kind: RefusedKind, placeId: String?, placeName: String?, text: String, reasons: List<String>, photo: ByteArray? = null, rating: Int? = null): PhotoRefusal? {
        val id = UUID.randomUUID().toString()
        val store = c.refused
        val name = photo?.let { runCatching { store.savePhoto(id, 0, it) }.getOrNull() }
        val saved = runCatching { store.save(RefusedItem(id, kind, placeId, placeName, text, reasons, listOfNotNull(name), java.time.Instant.now(), rating = rating)) }.getOrNull() ?: return null
        return PhotoRefusal(saved.id, reasons)
    }

    private val _appeal = MutableStateFlow<AppealUi?>(null)
    val appeal: StateFlow<AppealUi?> = _appeal.asStateFlow()
    /** After an appeal of an own review, the place's reviews reload so the status line is current. */
    private var appealReload: Place? = null

    /** The Appeal screen for a saved refusal (from "Can't post this", the Not accepted list, or a refused photo). */
    fun openAppealFor(refusedId: String) {
        viewModelScope.launch {
            val item = c.refused.get(refusedId) ?: return@launch
            val files = item.photos.mapNotNull { n -> c.refused.photoFile(item.id, n)?.let { AppealPhoto("saved-$n", file = it) } }
            appealReload = null
            _appeal.value = AppealUi(AppealTarget.Refusal(item), photos = files.take(AppealRules.MAX_PHOTOS))
        }
    }

    /** The Appeal screen for an item the server stored and held or rejected (own review, photo or place). */
    fun openAppealExisting(kind: RefusedKind, id: String, placeName: String? = null, text: String? = null, reasons: List<String> = emptyList(), reload: Place? = null) {
        if (!termsOk { openAppealExisting(kind, id, placeName, text, reasons, reload) }) return
        appealReload = reload
        _appeal.value = AppealUi(AppealTarget.Existing(kind, id, placeName, text, reasons))
    }

    fun appealEditNote(v: String) = _appeal.update { it?.copy(note = AppealRules.clipNote(v), error = if (it.error == AppealError.NOTE_REQUIRED) null else it.error) }

    /** From the system photo picker (no permission prompt): up to 3 photos in all. */
    fun appealPickPhotos(uris: List<Uri>) = _appeal.update { a ->
        a ?: return@update null
        val take = AppealRules.clipPhotos(a.photos.size, uris.size)
        a.copy(photos = a.photos + uris.take(take).map { AppealPhoto(UUID.randomUUID().toString(), uri = it) }, error = null)
    }

    fun appealDropPhoto(key: String) = _appeal.update { it?.copy(photos = it.photos.filterNot { p -> p.key == key }) }

    fun appealDismiss() {
        _appeal.value = null
        appealReload = null
    }

    /** Send -> POST /appeals (a refusal) or /reviews|/photos|/places/{id}/appeal. Disabled until the note is filled. */
    fun appealSubmit() {
        val a = _appeal.value ?: return
        val note = AppealRules.validNote(a.note)
        if (note == null || a.sending) { _appeal.update { it?.copy(error = AppealError.NOTE_REQUIRED) }; return }
        _appeal.update { it?.copy(sending = true, error = null) }
        viewModelScope.launch {
            val evidence = a.photos.mapNotNull { evidenceBytes(it) }
            if (evidence.size < a.photos.size || evidence.any { !AppealRules.photoFits(it.size) }) {
                _appeal.update { it?.copy(sending = false, error = AppealError.TOO_LARGE) }
                return@launch
            }
            try {
                when (val t = a.target) {
                    is AppealTarget.Refusal -> {
                        val i = t.item
                        // kind=photo: refusalId is the photo's own id and placeId is not sent; kind=place: placeId plus any UUID.
                        c.repo.submitAppeal(i.id, i.kind.wire, i.placeId.takeIf { i.kind != RefusedKind.PHOTO }, i.text, i.reasons, note, evidence, i.rating.takeIf { i.kind == RefusedKind.REVIEW })
                        c.refused.setState(i.id, AppealState.SENT)
                    }
                    is AppealTarget.Existing -> when (t.kind) {
                        RefusedKind.REVIEW -> c.repo.appealReview(t.id, note, evidence)
                        RefusedKind.PHOTO -> c.repo.appealPhoto(t.id, note, evidence)
                        RefusedKind.PLACE -> { c.repo.appealPlace(t.id, note); Unit }
                    }
                }
                _appeal.update { it?.copy(sending = false, done = true, error = null) }
                appealReload?.let { loadReviews(it) }
            } catch (e: kotlinx.coroutines.CancellationException) {
                throw e
            } catch (e: Exception) {
                val http = e as? HttpException
                val body = http?.let { runCatching { it.response()?.errorBody()?.string() }.getOrNull() }
                val err = AppealRules.errorOf(http?.code(), body, noConnection = e is java.io.IOException)
                when (err) {
                    AppealError.ALREADY_APPEALED -> (a.target as? AppealTarget.Refusal)?.let { runCatching { c.refused.setState(it.item.id, AppealState.SENT) } }
                    AppealError.PAUSED -> PostingPause.set(AppealRules.pausedUntil(body) ?: java.time.Instant.now().plusSeconds(24 * 3600))
                    else -> Unit
                }
                _appeal.update { it?.copy(sending = false, error = err, pausedUntil = if (err == AppealError.PAUSED) PostingPause.active() else it.pausedUntil) }
            }
        }
    }

    /** JPEG bytes of one evidence photo: a saved file as is, a picked photo decoded, EXIF/GPS stripped, re-encoded smaller until it fits 5 MB. */
    private suspend fun evidenceBytes(p: AppealPhoto): ByteArray? {
        p.file?.let { f -> return runCatching { f.readBytes() }.getOrNull() }
        val uri = p.uri ?: return null
        val bmp = PhotoPrep.decode(c.app, uri) ?: return null
        for (q in intArrayOf(85, 70, 55)) {
            val b = PhotoPrep.jpeg(bmp, q)
            if (AppealRules.photoFits(b.size)) return b
        }
        return PhotoPrep.jpeg(bmp, 40)
    }

    /** Not accepted list: remove one (and its photo files). */
    fun deleteRefused(id: String) { viewModelScope.launch { runCatching { c.refused.delete(id) } } }

    // ---- photo status: tick (published) / clock (processing, checking) / cross (rejected); polls GET /photos/{id}

    private val polling = HashSet<String>()

    /** Polls an uploaded photo every few seconds until it is published or rejected (or about two minutes pass). */
    private fun track(photo: Photo) {
        if (!ContentGate.shouldPoll(photo) || !polling.add(photo.id)) return
        viewModelScope.launch {
            try {
                repeat(ContentGate.POLL_TRIES) {
                    delay(ContentGate.POLL_MS)
                    val now = runCatching { c.repo.photo(photo.id) }.getOrNull() ?: return@repeat
                    applyPhoto(now)
                    if (!ContentGate.shouldPoll(now)) return@launch
                }
            } finally { polling.remove(photo.id) }
        }
    }

    /** A fresher copy of an uploaded photo: replaces it in the review draft and in the place's pending strip. */
    private fun applyPhoto(p: Photo) {
        fun List<UploadItem>.swap() = map { if (it.photo?.id == p.id) it.copy(photo = p) else it }
        _reviews.update { s -> s.copy(placeUploads = s.placeUploads.swap(), draft = s.draft?.let { d -> d.copy(uploads = d.uploads.swap()) }) }
    }

    /** [id] = a server photo id, or the refused id of a photo the server refused at upload. */
    fun showRejectedPhoto(id: String) = _reviews.update { s ->
        val refused = (s.placeUploads + s.draft?.uploads.orEmpty()).any { it.refusal?.refusedId == id }
        if (refused) s.copy(refusedPhotoId = id) else s.copy(rejectedPhotoId = id)
    }
    fun closeRejectedPhoto() = _reviews.update { it.copy(rejectedPhotoId = null, refusedPhotoId = null) }

    /** Refused photo · "Another photo": it leaves the draft / strip (the saved copy stays in Not accepted until it expires). */
    fun dropRefusedPhoto(refusedId: String) {
        _reviews.update { s ->
            s.copy(refusedPhotoId = null, placeUploads = s.placeUploads.filterNot { it.refusal?.refusedId == refusedId },
                draft = s.draft?.let { d -> d.copy(uploads = d.uploads.filterNot { it.refusal?.refusedId == refusedId }) })
        }
    }

    /** Refused photo · "Ask a person": the Appeal screen for the saved photo. */
    fun appealRefusedPhoto(refusedId: String) {
        _reviews.update { it.copy(refusedPhotoId = null) }
        openAppealFor(refusedId)
    }

    /** Rejected photo · "Another photo": the rejected one leaves the draft / strip; the picker opens in the screen. */
    fun dropPhoto(id: String) {
        _reviews.update { s ->
            s.copy(rejectedPhotoId = null, placeUploads = s.placeUploads.filterNot { it.photo?.id == id },
                draft = s.draft?.let { d -> d.copy(uploads = d.uploads.filterNot { it.photo?.id == id }) })
        }
    }

    /** Rejected photo · "Ask a person": the Appeal screen (a note is required) for POST /photos/{id}/appeal. */
    fun appealPhoto(id: String) {
        _reviews.update { it.copy(rejectedPhotoId = null) }
        val name = _reviews.value.placeName
        openAppealExisting(RefusedKind.PHOTO, id, placeName = name, reasons = (_reviews.value.placeUploads + _reviews.value.draft?.uploads.orEmpty()).firstOrNull { it.photo?.id == id }?.photo?.moderation?.reasons.orEmpty())
    }

    /** A stored review the check didn't accept (or held): "Ask a person" opens the Appeal screen (POST /reviews/{id}/appeal). */
    fun appealReview(r: Review, place: Place) =
        openAppealExisting(RefusedKind.REVIEW, r.id, place.name, r.text, r.moderation?.reasons.orEmpty(), reload = place)

    /** Inbox · Appeal on a rejected review, photo or place: the same screen. */
    fun appealContent(kind: String?, id: String, placeName: String? = null, reasons: List<String> = emptyList()) {
        val k = RefusedKind.of(kind) ?: return
        openAppealExisting(k, id, placeName, null, reasons)
    }

    fun submitReview(place: Place) {
        val d = _reviews.value.draft ?: return
        if (d.rating !in 1..5 || d.sending) return
        PostingPause.active()?.let { until -> updateDraft { it.copy(paused = until) }; return }
        updateDraft { it.copy(sending = true) }
        viewModelScope.launch {
            val body = ReviewRequest(d.rating, d.text.trim().ifBlank { null }, d.uploads.filter { it.photo != null && ContentGate.photoState(it.photo) != ContentState.REJECTED }.mapNotNull { it.photo?.id }.ifEmpty { null })
            runCatching { if (d.editingId != null) c.repo.updateReview(d.editingId, body) else c.repo.createReview(place.id, body) }
                .onSuccess { r ->
                    d.refusedId?.let { id -> runCatching { c.refused.deleteIfUnappealed(id) } }   // fixed and posted: no longer "not accepted"
                    myReviewIds += r.id
                    val state = ContentGate.reviewState(r)
                    log.review(r.id, place.name, held = state != ReviewState.PASSED)
                    _reviews.update { it.copy(draft = null) }
                    _events.tryEmit(ContribEvent.Message(when (state) {
                        ReviewState.PASSED -> if (r.heldForReview) R.string.restricted_held else R.string.review_posted
                        ReviewState.HELD -> R.string.cs_review_held
                        ReviewState.CHECKING -> R.string.cs_review_checking
                        ReviewState.REJECTED -> R.string.cs_review_rejected
                    }))
                    loadReviews(place, keep = r.takeIf { state != ReviewState.PASSED }?.copy(mine = true))
                }
                .onFailure { e ->
                    updateDraft { it.copy(sending = false) }
                    val http = e as? HttpException
                    val f = http?.let { ContentGate.failure(it.code(), runCatching { it.response()?.errorBody()?.string() }.getOrNull()) }
                    when (f) {
                        // 422 content_rejected: nothing was stored. The "Can't post this" sheet explains it (never the model's words).
                        is ContentFailure.Rejected -> {
                            // Kept on the phone only (Not accepted, 30 days) so it can be edited or appealed; the server stored nothing.
                            val saved = keepRefused(RefusedKind.REVIEW, place.id, place.name, d.text, f.reasons, rating = d.rating)
                            updateDraft { it.copy(rejection = f, refusedId = saved?.refusedId ?: it.refusedId) }
                        }
                        // 403 posting_paused: 3 rejections in 24 h.
                        is ContentFailure.Paused -> {
                            val until = f.until ?: java.time.Instant.now().plusSeconds(24 * 3600)
                            PostingPause.set(until); updateDraft { it.copy(paused = until) }
                        }
                        else -> _events.tryEmit(failure(e, if (http?.code() == 409) R.string.review_one_per_place else R.string.action_failed))
                    }
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

    /** Warning banner · "Not right? Tell us": POST /places/{id}/flag {reason: "other"}; the server takes OSM places too. */
    fun flagWarning(placeId: String) = viewModelScope.launch {
        runCatching { c.repo.flagPlace(placeId, "other") }
            .onSuccess { _events.tryEmit(ContribEvent.Message(R.string.thanks_flag)) }
            .onFailure { _events.tryEmit(ContribEvent.Message(R.string.action_failed)) }
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
                val (ph, refusal) = upload(place.id, place.name, u)
                _reviews.update { s -> s.copy(placeUploads = s.placeUploads.map { if (it.key == item.key) it.copy(photo = ph, failed = ph == null && refusal == null, refusal = refusal) else it }) }
                if (ph != null) onDone()
            }
        }
    }

    class Factory(private val c: AppContainer) : ViewModelProvider.Factory {
        @Suppress("UNCHECKED_CAST")
        override fun <T : ViewModel> create(modelClass: Class<T>): T = ContributeViewModel(c) as T
    }
}

/** The form with a place's OSM opening_hours filled in (unreadable hours leave the editor off). */
fun AddPlaceState.withHours(h: String): AddPlaceState =
    OpeningHours.parse(h)?.let { (w, all) -> copy(hoursEnabled = true, week = w, open247 = all) } ?: this

/** What a vote needs about the place. */
data class VetTarget(val id: String, val lat: Double, val lng: Double, val rural: Boolean) {
    companion object {
        fun of(p: PlaceSummary) = VetTarget(p.id, p.lat, p.lng, p.rural)
        fun of(p: Place) = VetTarget(p.id, p.lat, p.lng, p.rural)
    }
}

/** "1", "1.5", "2" */
fun fmtWeight(w: Double): String = if (w % 1.0 == 0.0) w.toLong().toString() else "%.1f".format(java.util.Locale.US, w)
