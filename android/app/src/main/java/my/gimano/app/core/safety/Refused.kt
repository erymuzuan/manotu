package my.gimano.app.core.safety

import kotlinx.serialization.builtins.ListSerializer
import kotlinx.serialization.builtins.serializer
import my.gimano.app.data.remote.GimanoJson
import java.time.Duration
import java.time.Instant

/*
 * Refused content kept on the phone only (docs/privacy-and-backup.md "refused_content", docs/content-safety.md "Appeals").
 * When the server answers 422 `content_rejected` it stores nothing, so the app keeps what the user wrote on the phone, to
 * edit or to appeal. It leaves the phone only when the user sends an appeal, and is deleted after 30 days. Pure code.
 */

enum class RefusedKind(val wire: String) {
    REVIEW("review"), PHOTO("photo"), PLACE("place");

    companion object { fun of(wire: String?): RefusedKind? = entries.firstOrNull { it.wire == wire } }
}

enum class AppealState(val wire: String) {
    NONE("none"), SENT("sent"), ANSWERED("answered");

    companion object { fun of(wire: String?): AppealState = entries.firstOrNull { it.wire == wire } ?: NONE }
}

/** One refused item. [photos] are files in the app's private storage (never picker URIs, which expire). */
data class RefusedItem(
    val id: String,
    val kind: RefusedKind,
    val placeId: String?,
    val placeName: String?,
    val text: String,
    val reasons: List<String>,
    val photos: List<String>,
    val createdAt: Instant,
    val appealState: AppealState = AppealState.NONE,
    /** 1..5 for a refused review: POST /appeals needs it (a review needs a rating). */
    val rating: Int? = null,
) {
    val issues: List<ContentIssue> get() = ContentGate.issues(reasons)
    /** An appeal can be sent: a review needs its rating. */
    val appealable: Boolean get() = kind != RefusedKind.REVIEW || rating in 1..5
    fun expiresAt(): Instant = createdAt.plus(RefusedRules.RETENTION)
    fun expired(now: Instant = Instant.now()): Boolean = !expiresAt().isAfter(now)

    /** Whole days left, 0 on the last day. */
    fun daysLeft(now: Instant = Instant.now()): Int = Duration.between(now, expiresAt()).toDays().toInt().coerceAtLeast(0)
}

object RefusedRules {
    const val RETENTION_DAYS = 30L
    val RETENTION: Duration = Duration.ofDays(RETENTION_DAYS)

    /** `text` of POST /appeals: at most 2000 characters. */
    const val TEXT_MAX = 2000

    private val stringList = ListSerializer(String.serializer())
    fun encodeList(l: List<String>): String = GimanoJson.encodeToString(stringList, l)
    fun decodeList(s: String?): List<String> = s?.let { runCatching { GimanoJson.decodeFromString(stringList, it) }.getOrNull() }.orEmpty()

    /** What is stored for a refused text: trimmed and clipped to the API limit. */
    fun clipText(text: String): String = text.replace('\u001f', ' ').trim().take(TEXT_MAX)

    /** Items still kept at [now], newest first, and the ids that have to go. */
    fun live(items: List<RefusedItem>, now: Instant): List<RefusedItem> = items.filterNot { it.expired(now) }.sortedByDescending { it.createdAt }
    fun expiredIds(items: List<RefusedItem>, now: Instant): List<String> = items.filter { it.expired(now) }.map { it.id }

    /** How many items still wait for the user to decide (the badge): not yet appealed. */
    fun badge(items: List<RefusedItem>, now: Instant): Int = items.count { !it.expired(now) && it.appealState == AppealState.NONE }
}

/** Why an appeal could not be sent (each has its own icon and line on the Appeal screen). */
enum class AppealError { ALREADY_APPEALED, NOTE_REQUIRED, PAUSED, BANNED, OFFLINE, TOO_LARGE, OTHER }

object AppealRules {
    /** `note`: required, trimmed, 1..200. */
    const val NOTE_MAX = 200
    const val MAX_PHOTOS = 3
    const val MAX_PHOTO_BYTES = 5L * 1024 * 1024

    /** What the field keeps while typing: never more than [NOTE_MAX] characters. */
    fun clipNote(raw: String): String = raw.take(NOTE_MAX)

    /** The note as sent (trimmed), or null while it would be refused (blank or too long). */
    fun validNote(raw: String): String? = raw.trim().takeIf { it.isNotEmpty() && it.length <= NOTE_MAX }

    /** Send is enabled only with a valid note, not while sending, and not for an item that was already appealed. */
    fun canSend(note: String, sending: Boolean, state: AppealState = AppealState.NONE): Boolean =
        !sending && state == AppealState.NONE && validNote(note) != null

    /** At most [MAX_PHOTOS] evidence photos. */
    fun clipPhotos(count: Int, adding: Int): Int = (MAX_PHOTOS - count).coerceIn(0, adding.coerceAtLeast(0))

    fun photoFits(bytes: Int): Boolean = bytes in 1..MAX_PHOTO_BYTES

    /** The app's answer to a failed POST (a status [code] and problem JSON [body], or no response at all). */
    fun errorOf(code: Int?, body: String?, noConnection: Boolean = false): AppealError {
        if (code == null) return if (noConnection) AppealError.OFFLINE else AppealError.OTHER
        val pd = body?.let { runCatching { GimanoJson.decodeFromString(my.gimano.app.data.model.ProblemDetails.serializer(), it) }.getOrNull() }
        return when {
            code == 409 -> AppealError.ALREADY_APPEALED
            code == 400 && pd?.code == "note_required" -> AppealError.NOTE_REQUIRED
            code == 403 && pd?.code == "posting_paused" -> AppealError.PAUSED
            code == 403 -> AppealError.BANNED
            code == 413 -> AppealError.TOO_LARGE
            else -> AppealError.OTHER
        }
    }

    /** The `until` of a `posting_paused` body, if any. */
    fun pausedUntil(body: String?): Instant? =
        body?.let { runCatching { GimanoJson.decodeFromString(my.gimano.app.data.model.ProblemDetails.serializer(), it) }.getOrNull() }
            ?.pausedUntil?.let(my.gimano.app.core.format.Formatters::parseInstant)
}

/** Posting paused (403 `posting_paused`) survives a restart: [encode] / [decode] are what the device store holds. */
object PausePersistence {
    fun encode(until: Instant?): String? = until?.toString()

    /** The saved pause if it is still running at [now]; an expired or unreadable one is dropped. */
    fun decode(saved: String?, now: Instant = Instant.now()): Instant? =
        saved?.let { runCatching { Instant.parse(it) }.getOrNull() }?.takeIf { it.isAfter(now) }
}
