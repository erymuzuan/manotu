package my.gimano.app.data.places

import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.map
import my.gimano.app.data.local.OutboxDao
import my.gimano.app.data.local.OutboxEntity

/**
 * A device-local log of what this user contributed publicly (reviews, photos), so "My
 * contributions" can show them; public places come from GET /me/places/contributed.
 * Lives in the device-local outbox table (never backed up, never sent anywhere).
 */
class ContributionLog(private val outbox: OutboxDao) {
    companion object {
        const val REVIEW = "contrib_review"
        const val PHOTO = "contrib_photo"
        const val REPORT = "contrib_report"
        private const val NEVER = "9999-12-31T00:00:00Z"
    }

    /** A review held for a moderator is logged with the "rh-" prefix: "Sedang disemak" in My contributions. */
    suspend fun review(reviewId: String, placeName: String, held: Boolean = false) =
        outbox.upsert(OutboxEntity((if (held) "rh-" else "r-") + reviewId, REVIEW, placeName, 0, NEVER))
    suspend fun photo(photoId: String, url: String) = outbox.upsert(OutboxEntity("p-$photoId", PHOTO, url, 0, NEVER))
    suspend fun report(reportId: String, type: String) = outbox.upsert(OutboxEntity("rp-$reportId", REPORT, type, 0, NEVER))

    val reports: Flow<Int> = outbox.observe(REPORT).map { it.size }
    val reviewNames: Flow<List<String>> = outbox.observe(REVIEW).map { l -> l.map { it.payloadJson } }
    /** (place name, held for review) */
    val reviewEntries: Flow<List<Pair<String, Boolean>>> = outbox.observe(REVIEW).map { l -> l.map { it.payloadJson to it.id.startsWith("rh-") } }

    /** (reviews, photos) */
    val counts: Flow<Pair<Int, List<String>>> = combine(outbox.observe(REVIEW), outbox.observe(PHOTO)) { r, p -> r.size to p.map { it.payloadJson } }
}
