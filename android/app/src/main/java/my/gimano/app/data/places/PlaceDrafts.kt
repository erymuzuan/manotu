package my.gimano.app.data.places

import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.map
import kotlinx.serialization.Serializable
import my.gimano.app.core.places.CreateFailure
import my.gimano.app.core.places.PlaceGate
import my.gimano.app.data.local.OutboxDao
import my.gimano.app.data.local.OutboxEntity
import my.gimano.app.data.model.CreatePlaceRequest
import my.gimano.app.data.model.Place
import my.gimano.app.data.remote.GimanoJson
import my.gimano.app.data.repo.GimanoRepository
import retrofit2.HttpException
import java.io.File
import java.io.IOException
import java.time.Instant

/**
 * A place to share that is waiting on this phone (design B5 / B6): [reason] `limit` (429: share after [notBefore]),
 * `paused` (403 adding_paused, until [notBefore]) or `offline` (no connection: sent by itself when the server answers).
 * [photos] are metadata-stripped JPEG copies in the app's files dir. [nearArea]: near a restricted area, photos are
 * never sent (docs/safety.md B).
 */
@Serializable
data class PlaceDraft(
    val id: String,
    val request: CreatePlaceRequest,
    val reason: String,
    val notBefore: String? = null,
    val createdAt: String,
    val photos: List<String> = emptyList(),
    val nearArea: Boolean = false,
) {
    val queued get() = reason == OFFLINE
    fun readyAt(): Instant? = notBefore?.let { runCatching { Instant.parse(it) }.getOrNull() }
    fun ready(now: Instant): Boolean = readyAt()?.let { !now.isBefore(it) } ?: true

    companion object {
        const val LIMIT = "limit"
        const val PAUSED = "paused"
        const val OFFLINE = "offline"
    }
}

/**
 * Drafts live in the device-local outbox table (kind `place_draft`): on this phone only, never in a backup (the backup
 * drops the outbox), never on a server until the user shares them. Offline ones are retried with the feedback outbox.
 */
class PlaceDrafts(
    private val outbox: OutboxDao,
    private val repo: GimanoRepository,
    private val photoDir: File,
    private val now: () -> Instant = Instant::now,
) {
    companion object {
        const val KIND = "place_draft"
        private const val NEVER = "9999-12-31T00:00:00Z"
    }

    val drafts: Flow<List<PlaceDraft>> = outbox.observe(KIND).map { l -> l.mapNotNull(::decode).sortedByDescending { it.createdAt } }

    private fun decode(e: OutboxEntity): PlaceDraft? = runCatching { GimanoJson.decodeFromString(PlaceDraft.serializer(), e.payloadJson) }.getOrNull()

    /** Where a draft's photo [i] is kept (the caller writes the JPEG there). */
    fun photoFile(draftId: String, i: Int): File = File(photoDir.apply { mkdirs() }, "$draftId-$i.jpg")

    suspend fun save(d: PlaceDraft) =
        outbox.upsert(OutboxEntity(d.id, KIND, GimanoJson.encodeToString(PlaceDraft.serializer(), d), 0, if (d.queued) now().toString() else NEVER))

    suspend fun get(id: String): PlaceDraft? = outbox.all(KIND).firstOrNull { it.id == id }?.let(::decode)

    /** Removes the draft and its photo copies (after sending, or "Discard"). */
    suspend fun delete(id: String) {
        get(id)?.photos?.forEach { File(it).delete() }
        outbox.delete(id)
    }

    /**
     * Sends one draft as it is. Success → the owner's Place (photos uploaded, draft gone). A refusal the flow explains
     * (limit, pause, duplicate) keeps it as a draft with that reason; no connection keeps it queued.
     */
    suspend fun send(d: PlaceDraft): Result<Place> = try {
        val p = repo.createPlace(d.request)
        if (!d.nearArea) d.photos.forEach { f -> runCatching { repo.uploadPhoto(p.id, File(f).readBytes(), null) } }
        delete(d.id)
        Result.success(p)
    } catch (e: HttpException) {
        val body = runCatching { e.response()?.errorBody()?.source()?.peek()?.readUtf8() }.getOrNull()
        when (val f = PlaceGate.failure(e.code(), body, e.response()?.headers()?.get("Retry-After"))) {
            is CreateFailure.RateLimited -> save(d.copy(reason = PlaceDraft.LIMIT, notBefore = f.retryAfterSeconds?.let { now().plusSeconds(it.toLong()).toString() }))
            is CreateFailure.Paused -> save(d.copy(reason = PlaceDraft.PAUSED, notBefore = f.until?.toString()))
            // Duplicate or anything else: the user decides when they open it ("Share now" shows B1 again).
            else -> save(d.copy(reason = PlaceDraft.LIMIT, notBefore = null))
        }
        Result.failure(e)
    } catch (e: IOException) {
        Result.failure(e)
    } catch (e: kotlinx.coroutines.CancellationException) {
        throw e
    } catch (e: Exception) {
        // e.g. 422 restricted_area: no longer sent by itself; the user opens it from My places.
        save(d.copy(reason = PlaceDraft.LIMIT, notBefore = null))
        Result.failure(e)
    }

    /** Offline drafts, sent when the server answers again. Returns how many went out. */
    suspend fun retryQueued(): Int = outbox.all(KIND).mapNotNull(::decode).filter { it.queued }.count { send(it).isSuccess }
}
