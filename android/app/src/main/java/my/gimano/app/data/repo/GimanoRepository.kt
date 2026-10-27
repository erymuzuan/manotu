package my.gimano.app.data.repo

import my.gimano.app.data.model.*

/**
 * Everything the app needs from the backend. Implemented by [RemoteRepository] and [DemoRepository].
 * Personal data (favourites, recents, private places) is deliberately absent: see LocalStore.
 */
interface GimanoRepository : my.gimano.app.data.share.ShareApi {
    suspend fun ensureAuth(): User
    suspend fun updateMe(body: UpdateMeRequest): User

    /** Legacy server copy for the one-time migration; null if the server has none / no endpoint. */
    suspend fun exportMyData(): MyDataExport?
    suspend fun deleteMyData()

    suspend fun search(q: String, lat: Double?, lng: Double?, limit: Int = 10, category: String? = null): List<PlaceSummary>
    /** Full response: results plus spelling correction and suggestions. [exact] = don't correct ("cari 'x' sahaja"). */
    suspend fun searchFull(q: String, lat: Double?, lng: Double?, limit: Int = 20, exact: Boolean = false, near: GeoPointLite? = null, viewport: String? = null, category: String? = null): SearchResponse =
        SearchResponse(search(q, lat, lng, limit, category).filter { viewport == null || my.gimano.app.core.geo.SearchArea.contains(viewport, it.lat, it.lng) })
    suspend fun nearby(lat: Double, lng: Double, category: String, radius: Int = 5000): List<PlaceSummary>
    /** Place detail. Never carries the user's position (distance is computed on the device, PlaceDistance). */
    suspend fun place(id: String): Place
    suspend fun reverse(lat: Double, lng: Double): ReverseGeocode
    suspend fun routes(req: RouteRequest): List<Route>
    suspend fun reroute(routeId: String, req: RerouteRequest): List<Route>
    suspend fun departureTimes(oLat: Double, oLng: Double, dLat: Double, dLng: Double, vehicle: String? = null): List<DepartureSlot>
    suspend fun live(minLng: Double, minLat: Double, maxLng: Double, maxLat: Double): LiveResponse
    suspend fun createReport(body: CreateReportRequest): Report
    suspend fun vote(reportId: String, stillThere: Boolean): Report
    /** Undo a quick report (docs/driving.md §6.4): withdraws your own report, within 2 minutes. */
    suspend fun deleteReport(reportId: String): Unit = throw UnsupportedOperationException()
    suspend fun thank(reportId: String)
    suspend fun postLocations(batch: LocationBatch)

    // Complaints v1. Callers go through IssueGate (hides the features when the server has no /issues).
    suspend fun createIssue(body: CreateIssueRequest): Issue
    suspend fun issuesNearby(minLng: Double, minLat: Double, maxLng: Double, maxLat: Double, kinds: List<String>? = null): List<Issue>
    suspend fun voteIssue(id: String, body: IssueVoteRequest): IssueVoteResult

    /** Inbox (public-contribution news); empty when the server has no inbox yet. */
    suspend fun inbox(): List<InboxItem>

    suspend fun sendFeedback(body: FeedbackRequest): FeedbackCreated
    suspend fun myFeedback(): List<FeedbackSummary>
    /** [token]: the contactToken from the create response (null for older feedback, withdrawn as its author). */
    suspend fun deleteFeedbackContact(id: String, token: String?)
    suspend fun deleteCrashContact(id: String, token: String)
    /** "Report place" (community places only). */
    suspend fun flagPlace(placeId: String, reason: String)
    suspend fun sendCrashReport(body: CrashReportRequest): CrashCreated

    suspend fun createPlace(body: CreatePlaceRequest): Place
    /** Owner edit of a community place (PATCH, signed): checked again; a rejected place may be edited ("Edit and try again"). */
    suspend fun updatePlace(placeId: String, body: CreatePlaceRequest): Place
    /** Owner only: a pending/rejected place is removed ("Discard"); a published one becomes closed. */
    suspend fun deletePlace(placeId: String)
    /** "Ask for a review" of a place the AI check didn't accept (signed, once per place) → the owner's Place, held. */
    suspend fun appealPlace(placeId: String, note: String?): Place
    suspend fun suggestEdit(placeId: String, body: SuggestEditRequest): SuggestionCreated
    suspend fun verifyPlace(placeId: String, body: VerifyRequest, ts: Long? = null): VerifyResult
    /** Pending community places in the geohash-6 [cell] and its 8 neighbours (excludes my own). */
    suspend fun pendingNearby(cell: String): List<PlaceSummary>
    suspend fun contributedPlaces(): List<PlaceSummary>

    suspend fun reviews(placeId: String, sort: String = "recent"): ReviewsPage
    suspend fun createReview(placeId: String, body: ReviewRequest): Review
    suspend fun updateReview(reviewId: String, body: ReviewRequest): Review
    suspend fun deleteReview(reviewId: String)
    suspend fun helpful(reviewId: String)
    suspend fun flagReview(reviewId: String, reason: String)
    /** "Report photo" (POST /photos/{id}/flag): same reasons as a review flag. */
    suspend fun flagPhoto(photoId: String, reason: String)
    suspend fun uploadPhoto(placeId: String, jpeg: ByteArray, caption: String?): Photo
    suspend fun photos(placeId: String): PhotosPage
    /** GET /photos/{id}: one photo's current status (polled after an upload; own photos carry `moderation`). */
    suspend fun photo(photoId: String): Photo
    /** "Ask a person" about a review or photo the AI check didn't accept (once each, held for a maintainer; 202). */
    /** [note] is required by the server (1..200 after trimming); [photos] are up to 3 evidence JPEGs (<= 5 MB each). */
    suspend fun appealReview(reviewId: String, note: String?, photos: List<ByteArray> = emptyList())
    suspend fun appealPhoto(photoId: String, note: String?, photos: List<ByteArray> = emptyList())
    /** POST /appeals: appeals a refusal that stored nothing (the refused text goes along, once). */
    suspend fun submitAppeal(refusalId: String, kind: String, placeId: String?, text: String, reasons: List<String>, note: String, photos: List<ByteArray> = emptyList(), rating: Int? = null): AppealAck
}

/** Map centre for `near=lat,lng` (ranking origin when the user is looking elsewhere). */
data class GeoPointLite(val lat: Double, val lng: Double)
