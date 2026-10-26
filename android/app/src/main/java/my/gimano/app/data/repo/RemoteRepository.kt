package my.gimano.app.data.repo

import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import my.gimano.app.data.model.*
import my.gimano.app.data.remote.ApiFactory
import my.gimano.app.data.remote.GimanoApi
import my.gimano.app.data.settings.SettingsStore
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.MultipartBody
import okhttp3.RequestBody.Companion.toRequestBody
import retrofit2.HttpException
import java.util.Locale
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import my.gimano.app.core.identity.RequestSigning

/** Talks to the real Gimano backend. Re-authenticates once on HTTP 401. */
class RemoteRepository(
    private val settings: SettingsStore,
    private val identity: my.gimano.app.data.identity.IdentityService,
    private val acceptLanguage: () -> String = { ApiFactory.acceptLanguage(false) },
) : GimanoRepository {
    val signer = my.gimano.app.data.remote.SigningInterceptor({ m, pq, ts, body -> identity.signRequest(m, pq, ts, body) })
    private val client = ApiFactory.okHttp({ settings.current.token }, signer, acceptLanguage)
    private var apiBase: String? = null
    private var apiInstance: GimanoApi? = null
    private val authLock = Mutex()

    private val api: GimanoApi
        get() {
            val base = settings.current.apiBaseUrl
            if (apiInstance == null || apiBase != base) {
                apiInstance = ApiFactory.create(base, client)
                apiBase = base
            }
            return apiInstance!!
        }

    private fun locale() = Locale.getDefault().toLanguageTag()
    private fun HttpException.missingEndpoint() = code() in setOf(404, 405, 501)

    /**
     * Gets a JWT for this phone's pseudonym (docs/identity-and-reputation.md §1):
     * registered key → `POST /auth/token` (signed); new key → `POST /auth/register`.
     * A server that doesn't have the new endpoints yet gets the legacy `POST /auth/device`.
     */
    private suspend fun authenticate() = withContext(Dispatchers.IO) {
        val id = identity.ensure()
        if (id.registered) {
            try {
                val ts = nowTs()
                val r = api.authToken(TokenRequest(userId = id.userId, ts = ts, sig = identity.sign(RequestSigning.authMessage(id.userId, ts))))
                settings.saveAuth(r.token, r.userId ?: id.userId, r.displayName ?: id.displayName ?: settings.current.displayName)
                return@withContext
            } catch (e: HttpException) {
                // 401 = this server doesn't know the key (a fresh/reset server, or a dev build pointed at another
                // server): register the same key there. A key it does know answers 409 and the 401 stands.
                if (e.code() == 401) {
                    val r = try { api.authRegister(RegisterRequest(identity.publicKeyB64(), "android", locale())) } catch (e2: HttpException) { throw e }
                    settings.saveAuth(r.token, r.userId, r.displayName)
                    identity.markRegistered(r.userId, r.displayName)
                    return@withContext
                }
                if (!e.missingEndpoint()) throw e
            }
        } else {
            try {
                val r = api.authRegister(RegisterRequest(identity.publicKeyB64(), "android", locale()))
                settings.saveAuth(r.token, r.userId, r.displayName)
                identity.markRegistered(r.userId, r.displayName)
                return@withContext
            } catch (e: HttpException) {
                if (!e.missingEndpoint()) throw e
            }
        }
        // Legacy server: device auth, then try to attach the key so the account is ready for signed requests.
        val res = api.authDevice(DeviceAuthRequest(settings.deviceId(), "android", locale()))
        settings.saveAuth(res.token, res.userId, res.displayName)
        attachKeyIfNeeded()
    }

    /** 0.1.0 accounts (JWT from `/auth/device`, no key): attach this phone's key with `POST /me/keys`. Best effort. */
    private suspend fun attachKeyIfNeeded() = withContext(Dispatchers.IO) {
        val id = identity.ensure()
        val userId = settings.current.userId ?: return@withContext
        if (id.registered || settings.current.token == null) return@withContext
        try {
            api.attachKey(AttachKeyRequest(identity.publicKeyB64())).let { r ->
                if (r.isSuccessful) identity.markRegistered(userId, settings.current.displayName)
            }
        } catch (_: HttpException) { } catch (_: java.io.IOException) { }
    }

    /** After a backup restore brought a different pseudonym: drop the old JWT and sign in as the restored one. */
    suspend fun adoptRestoredIdentity() {
        val id = withContext(Dispatchers.IO) { identity.current() } ?: return
        if (!id.registered || id.userId == settings.current.userId) return
        settings.saveAuth(null, null, null)
        authLock.withLock { authenticate() }
    }

    /**
     * Recovery code: prove the key and learn its userId (`POST /auth/token` with publicKey). Only when the
     * server accepts it does the phone switch to that identity. Returns the display name.
     */
    /**
     * DELETE /me. Returns normally when the server account is gone: deleted now, or already absent (404/410).
     * Anything else throws, and the caller must not touch the phone's identity.
     */
    suspend fun deleteAccount() {
        val r = authed { deleteMe() }
        if (!r.isSuccessful && r.code() != 404 && r.code() != 410) throw HttpException(r)
    }

    suspend fun restoreFromSeed(seed: ByteArray): String = withContext(Dispatchers.IO) {
        val pk = identity.publicKeyOf(seed)
        val ts = nowTs()
        val r = api.authToken(TokenRequest(publicKey = pk, ts = ts, sig = identity.signWith(seed, RequestSigning.keyLoginMessage(pk, ts))))
        val userId = r.userId ?: throw IllegalStateException("server did not return a userId")
        identity.adopt(seed, userId, r.displayName)
        settings.saveAuth(r.token, userId, r.displayName)
        r.displayName ?: ""
    }

    /** The app JWT for a call made outside Retrofit (event short links, `POST /drops`); [refresh] after a 401. */
    suspend fun bearerToken(refresh: Boolean): String? {
        if (refresh || settings.current.token == null) authLock.withLock { if (refresh || settings.current.token == null) authenticate() }
        return settings.current.token
    }

    private suspend fun <T> authed(block: suspend GimanoApi.() -> T): T {
        if (settings.current.token == null) authLock.withLock { if (settings.current.token == null) authenticate() }
        return try {
            api.block()
        } catch (e: HttpException) {
            if (e.code() == 401) {
                authLock.withLock { authenticate() }
                api.block()
            } else throw e
        }
    }

    private fun retrofit2.Response<*>.orThrow() { if (!isSuccessful) throw HttpException(this) }

    override suspend fun ensureAuth(): User = authed { me() }.also { attachKeyIfNeeded() }
    override suspend fun updateMe(body: UpdateMeRequest) = authed { updateMe(body) }

    override suspend fun exportMyData(): MyDataExport? = try {
        authed { exportMyData() }
    } catch (e: HttpException) {
        if (e.code() in setOf(404, 405, 410)) null else throw e
    }

    override suspend fun deleteMyData() {
        val r = authed { deleteMyData() }
        if (!r.isSuccessful && r.code() !in setOf(404, 405, 410)) throw HttpException(r)
    }

    override suspend fun search(q: String, lat: Double?, lng: Double?, limit: Int, category: String?) =
        authed { search(q, lat, lng, limit, category).results }
    override suspend fun nearby(lat: Double, lng: Double, category: String, radius: Int) = authed { nearby(lat, lng, category, radius).results }
    override suspend fun place(id: String) = authed { place(id) }
    override suspend fun reverse(lat: Double, lng: Double) = authed { reverse(lat, lng) }
    override suspend fun searchFull(q: String, lat: Double?, lng: Double?, limit: Int, exact: Boolean, near: GeoPointLite?, viewport: String?, category: String?) =
        authed { search(q, lat, lng, limit, category, if (exact) true else null, near?.let { String.format(java.util.Locale.US, "%.5f,%.5f", it.lat, it.lng) }, viewport) }
    override suspend fun routes(req: RouteRequest) = authed { routes(req).routes }
    override suspend fun reroute(routeId: String, req: RerouteRequest) = authed { reroute(routeId, req).routes }
    override suspend fun departureTimes(oLat: Double, oLng: Double, dLat: Double, dLng: Double, vehicle: String?) =
        authed { departureTimes(oLat, oLng, dLat, dLng, null, vehicle?.takeIf { it == "car" || it == "motorcycle" }).slots }
    override suspend fun live(minLng: Double, minLat: Double, maxLng: Double, maxLat: Double) =
        authed { live(String.format(Locale.US, "%.5f,%.5f,%.5f,%.5f", minLng, minLat, maxLng, maxLat)) }
    override suspend fun createReport(body: CreateReportRequest) = authed { createReport(body) }
    override suspend fun vote(reportId: String, stillThere: Boolean) = authed { vote(reportId, VoteRequest(stillThere)) }
    override suspend fun deleteReport(reportId: String) { authed { deleteReport(reportId) }.orThrow() }
    override suspend fun thank(reportId: String) { authed { thank(reportId) }.orThrow() }
    override suspend fun postLocations(batch: LocationBatch) { authed { postLocations(batch) }.orThrow() }

    override suspend fun createIssue(body: CreateIssueRequest) = authed { createIssue(body) }
    override suspend fun issuesNearby(minLng: Double, minLat: Double, maxLng: Double, maxLat: Double, kinds: List<String>?) =
        authed { issuesNearby(String.format(Locale.US, "%.5f,%.5f,%.5f,%.5f", minLng, minLat, maxLng, maxLat), kinds?.joinToString(",")) }.issues
    override suspend fun voteIssue(id: String, body: IssueVoteRequest) = authed { voteIssue(id, body) }

    override suspend fun inbox(): List<InboxItem> = try { authed { inbox() } } catch (e: HttpException) { if (e.code() in setOf(404, 405, 501)) emptyList() else throw e }
    override suspend fun sendFeedback(body: FeedbackRequest) = authed { feedback(body) }
    override suspend fun myFeedback() = authed { myFeedback() }
    /**
     * With the report's contactToken: no sign-in needed (the report isn't linked to the account), so withdrawing never
     * registers anything. Without one (older feedback): as its author. 404 = already gone.
     */
    override suspend fun deleteFeedbackContact(id: String, token: String?) {
        val r = if (token != null) api.deleteFeedbackContact(id, token) else authed { deleteFeedbackContact(id, null) }
        if (!r.isSuccessful && r.code() != 404) throw HttpException(r)
    }
    override suspend fun deleteCrashContact(id: String, token: String) {
        val r = api.deleteCrashContact(id, token)
        if (!r.isSuccessful && r.code() != 404) throw HttpException(r)
    }
    override suspend fun flagPlace(placeId: String, reason: String) { authed { flagPlace(placeId, FlagRequest(reason)) }.orThrow() }
    override suspend fun sendCrashReport(body: CrashReportRequest) = authed { crashReport(body) }

    override suspend fun createPlace(body: CreatePlaceRequest) = authed { createPlace(body) }
    override suspend fun updatePlace(placeId: String, body: CreatePlaceRequest) = authed { updatePlace(placeId, body.copy(notDuplicateOf = null)) }
    override suspend fun deletePlace(placeId: String) {
        val r = authed { deletePlace(placeId) }
        if (!r.isSuccessful && r.code() != 404) throw HttpException(r)   // 404: already gone
    }
    override suspend fun appealPlace(placeId: String, note: String?) = authed { appealPlace(placeId, AppealRequest(note?.trim()?.ifBlank { null })) }
    override suspend fun suggestEdit(placeId: String, body: SuggestEditRequest) = authed { suggestEdit(placeId, body) }
    override suspend fun verifyPlace(placeId: String, body: VerifyRequest, ts: Long?) = authed { verifyPlace(placeId, body, ts?.toString()) }
    fun nowTs(): Long = signer.nowTs()
    override suspend fun pendingNearby(cell: String): List<PlaceSummary> = try {
        authed { pendingNearby(cell) }
    } catch (e: HttpException) {
        if (e.missingEndpoint()) emptyList() else throw e
    }
    override suspend fun contributedPlaces() = authed { contributedPlaces() }

    override suspend fun reviews(placeId: String, sort: String) = authed { reviews(placeId, sort) }
    override suspend fun createReview(placeId: String, body: ReviewRequest) = authed { createReview(placeId, body) }
    override suspend fun updateReview(reviewId: String, body: ReviewRequest) = authed { updateReview(reviewId, body) }
    override suspend fun deleteReview(reviewId: String) { authed { deleteReview(reviewId) }.orThrow() }
    override suspend fun helpful(reviewId: String) { authed { helpful(reviewId) }.orThrow() }
    override suspend fun flagReview(reviewId: String, reason: String) { authed { flagReview(reviewId, FlagRequest(reason)) }.orThrow() }
    override suspend fun flagPhoto(photoId: String, reason: String) { authed { flagPhoto(photoId, FlagRequest(reason)) }.orThrow() }

    override suspend fun uploadPhoto(placeId: String, jpeg: ByteArray, caption: String?): Photo = authed {
        val part = MultipartBody.Part.createFormData("file", "photo.jpg", jpeg.toRequestBody("image/jpeg".toMediaType()))
        uploadPhoto(part, placeId.toRequestBody("text/plain".toMediaType()), caption?.toRequestBody("text/plain".toMediaType()))
    }

    override suspend fun photos(placeId: String) = authed { photos(placeId) }

    override suspend fun createShare(expiresInMinutes: Int) = authed { createShare(my.gimano.app.data.share.CreateShareRequest(expiresInMinutes)) }
    override suspend fun updateShare(shareId: String, writeToken: String, sealed: my.gimano.app.data.share.SealedShare) { api.updateShare(shareId, "Share $writeToken", sealed).orThrow() }
    override suspend fun deleteShare(shareId: String, writeToken: String) { api.deleteShare(shareId, "Share $writeToken").orThrow() }
}
