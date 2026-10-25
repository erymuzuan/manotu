package my.gimano.app.core.places

import my.gimano.app.core.format.Formatters
import my.gimano.app.data.model.Place
import my.gimano.app.data.model.PlaceScreening
import my.gimano.app.data.model.PlaceSummary
import my.gimano.app.data.model.ProblemDetails
import my.gimano.app.data.remote.GimanoJson
import java.time.Instant
import kotlin.math.ceil

/**
 * Which screen the add-a-place flow shows after the server answered (design "Add a place with an AI gate"):
 * A4 [LIVE], A5 [GOLD], B2 [HELD], B3 [NOT_ACCEPTED], B4 [NOT_ACCEPTED_PERSONAL], B6 [CHECKING]. [PENDING] is the
 * plain path (the check was off, over budget or not run): waiting for 3 confirmations, as before.
 */
enum class AddResult {
    LIVE, GOLD, HELD, NOT_ACCEPTED, NOT_ACCEPTED_PERSONAL, CHECKING, PENDING;

    val notAccepted get() = this == NOT_ACCEPTED || this == NOT_ACCEPTED_PERSONAL
}

/** The app's own copy for a rejection (never the model's words). B4 for [PRIVATE_HOME] and [HARASSMENT], B3 for the rest. */
enum class RejectKind {
    ADVERT, SCAM, ILLEGAL, ADULT, GIBBERISH, PRIVATE_HOME, HARASSMENT, OTHER;

    /** About a person rather than a business: B4, which offers "Keep it just for me". */
    val personal get() = this == PRIVATE_HOME || this == HARASSMENT
}

/** Why B2 says "A person will check this one". */
enum class HoldReason { APPEALED, SECURITY, DUPLICATE, UNSURE }

/** A refused POST /places that the flow explains instead of showing an error. */
sealed interface CreateFailure {
    /** 409: B1 "Is it already on the map?" ([existing] is null when the body had no usable place). */
    data class Duplicate(val existing: PlaceSummary?) : CreateFailure
    /** 429: B5 "You can add more in N minutes". */
    data class RateLimited(val retryAfterSeconds: Int?) : CreateFailure {
        val minutes: Int? get() = PlaceGate.minutes(retryAfterSeconds)
    }
    /** 403 `adding_paused`: B5's paused variant. */
    data class Paused(val until: Instant?) : CreateFailure
    data class Other(val status: Int, val detail: String?) : CreateFailure
}

/** "My places" (C3): one status per place, wherever it lives (server, draft on the phone, or just for me). */
enum class MyPlaceStatus { COMMUNITY_VERIFIED, LIVE_UNVERIFIED, WAITING, CHECKING, HELD, NOT_ACCEPTED, HIDDEN, EXPIRED, CLOSED, DRAFT, JUST_FOR_ME }

object PlaceGate {
    /** docs/api.md: POST /places/{id}/appeal {note?: ≤ 200}. */
    const val APPEAL_MAX = 200

    fun result(p: Place): AddResult = result(p.status, p.heldForReview, p.screening)
    fun result(p: PlaceSummary): AddResult = result(p.status, p.heldForReview, p.screening)

    fun result(status: String?, heldForReview: Boolean, screening: PlaceScreening?): AddResult {
        val state = screening?.state
        return when {
            state == "checking" -> AddResult.CHECKING
            state == "rejected" || status == "rejected" ->
                if (rejectKind(screening?.reasons.orEmpty()).personal) AddResult.NOT_ACCEPTED_PERSONAL else AddResult.NOT_ACCEPTED
            state == "held" || heldForReview -> AddResult.HELD
            // Published straight away: only an Emas contributor's place (the check passed or it was skipped).
            status == "published" -> AddResult.GOLD
            state == "passed" -> AddResult.LIVE
            else -> AddResult.PENDING
        }
    }

    /** Fixed reason codes → the app's copy. A home or a person comes first: the safe answer is "just for me". */
    fun rejectKind(reasons: List<String>): RejectKind {
        val r = reasons.map { it.lowercase() }.toSet()
        return when {
            "private_home" in r -> RejectKind.PRIVATE_HOME
            "harassment" in r -> RejectKind.HARASSMENT
            "scam" in r -> RejectKind.SCAM
            "illegal" in r -> RejectKind.ILLEGAL
            "adult" in r -> RejectKind.ADULT
            "spam" in r -> RejectKind.ADVERT
            "gibberish" in r -> RejectKind.GIBBERISH
            else -> RejectKind.OTHER
        }
    }

    fun holdReason(s: PlaceScreening?): HoldReason {
        val r = s?.reasons.orEmpty().map { it.lowercase() }.toSet()
        return when {
            s?.appealed == true -> HoldReason.APPEALED
            "security" in r -> HoldReason.SECURITY
            "duplicate" in r -> HoldReason.DUPLICATE
            else -> HoldReason.UNSURE
        }
    }

    /** Whole minutes, rounded up (40 min for 2,400 s, 1 min for 5 s); null when unknown. */
    fun minutes(seconds: Int?): Int? = seconds?.takeIf { it > 0 }?.let { ceil(it / 60.0).toInt().coerceAtLeast(1) }

    /**
     * The refusal behind a failed POST /places: [code] the HTTP status, [body] the problem JSON, [retryAfter] the
     * Retry-After header (seconds). Older servers sent the duplicate as a Place or as {place}; both still work.
     */
    fun failure(code: Int, body: String?, retryAfter: String?): CreateFailure {
        val pd = body?.let { runCatching { GimanoJson.decodeFromString(ProblemDetails.serializer(), it) }.getOrNull() }
        return when {
            code == 409 -> CreateFailure.Duplicate(pd?.existing ?: body?.let(::legacyDuplicate))
            code == 429 -> CreateFailure.RateLimited(pd?.retryAfterSeconds ?: retryAfter?.trim()?.toIntOrNull())
            code == 403 && pd?.code == "adding_paused" -> CreateFailure.Paused(Formatters.parseInstant(pd.pausedUntil))
            else -> CreateFailure.Other(code, pd?.detail ?: pd?.title)
        }
    }

    private fun legacyDuplicate(body: String): PlaceSummary? =
        runCatching { GimanoJson.decodeFromString(Place.serializer(), body).summary() }.getOrNull()
            ?: runCatching { GimanoJson.decodeFromString(LegacyDuplicate.serializer(), body).place?.summary() }.getOrNull()

    @kotlinx.serialization.Serializable
    private data class LegacyDuplicate(val place: Place? = null)

    /** C3 status of one of my community places (GET /me/places/contributed, owner view). */
    fun myStatus(p: PlaceSummary): MyPlaceStatus {
        val state = p.screening?.state
        return when {
            state == "rejected" || p.status == "rejected" -> MyPlaceStatus.NOT_ACCEPTED
            state == "checking" -> MyPlaceStatus.CHECKING
            state == "held" || p.heldForReview -> MyPlaceStatus.HELD
            p.status == "published" -> MyPlaceStatus.COMMUNITY_VERIFIED
            p.status == "hidden" -> MyPlaceStatus.HIDDEN
            p.status == "expired" -> MyPlaceStatus.EXPIRED
            p.status == "closed" -> MyPlaceStatus.CLOSED
            state == "passed" -> MyPlaceStatus.LIVE_UNVERIFIED
            else -> MyPlaceStatus.WAITING
        }
    }

    /** "0 of 1": confirmations so far / required, as the server weighs them. */
    fun progress(p: PlaceSummary): Pair<String, String>? {
        val req = p.required ?: return null
        return fmt(p.confirmationsWeighted ?: 0.0) to fmt(req)
    }

    private fun fmt(w: Double): String = if (w % 1.0 == 0.0) w.toLong().toString() else "%.1f".format(java.util.Locale.US, w)
}
