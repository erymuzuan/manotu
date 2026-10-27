package my.gimano.app.core.safety

import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import my.gimano.app.core.format.Formatters
import my.gimano.app.data.model.ContentModeration
import my.gimano.app.data.model.InboxItem
import my.gimano.app.data.model.Photo
import my.gimano.app.data.model.ProblemDetails
import my.gimano.app.data.model.Review
import my.gimano.app.data.remote.GimanoJson
import java.time.Instant

/*
 * Public content safety on the phone (docs/content-safety.md). Everything here is pure: fixed reason codes in, the app's
 * own categories out. The model's words never reach the screen, and nothing the user wrote leaves the phone for this
 * (the pre-filter below runs locally, before anything is sent).
 */

/** A place warning (docs/content-safety.md "Place warnings"): `alcohol`, `gambling`, `tobacco`. */
enum class PlaceWarning(val wire: String) {
    ALCOHOL("alcohol"), GAMBLING("gambling"), TOBACCO("tobacco");

    companion object {
        /** The warnings in a stable order (alcohol, gambling, tobacco), unknown values ignored, duplicates dropped. */
        fun of(wire: Collection<String>?): List<PlaceWarning> {
            val set = wire.orEmpty().map { it.trim().lowercase() }.toSet()
            return entries.filter { it.wire in set }
        }

        fun wire(w: Collection<PlaceWarning>): List<String>? = entries.filter { it in w }.map { it.wire }.ifEmpty { null }
    }
}

/** The three crossed-out tiles of the write-review screen: phone, link, offer. */
enum class AdTile { PHONE, LINK, OFFER }

/**
 * The local pre-filter for a review (design "Reviews": three crossed-out tiles, Post disabled while it looks like an
 * advert). It only guesses: the server's AI check has the last word, so a miss here is caught there and a hit here is
 * only a nudge to take the contact or offer out. "A vape shop is next door" matches none of the rules on purpose.
 */
object ReviewPrefilter {
    /** docs/content-safety.md: the app shows 500, the API allows 2000. */
    const val SHOWN_MAX = 500

    private val link = Regex(
        """(https?://|www\.|\b(?:wa\.me|t\.me|bit\.ly|linktr\.ee|tinyurl\.com)\b|\b[a-z0-9][a-z0-9-]{1,}\.(?:com|net|org|my|co|io|me|ly|app|biz|info|shop|xyz|link|store|vip|bet|club|id|sg)\b)""",
        RegexOption.IGNORE_CASE,
    )
    private val contactWord = Regex("""\b(?:whats?app|wasap|wassap|telegram|telegrem|wechat|signal|line id)\b""", RegexOption.IGNORE_CASE)
    private val handle = Regex("""@[a-z0-9_.]{3,}""", RegexOption.IGNORE_CASE)
    private val repeated = Regex("""(.)\1{7,}""", RegexOption.IGNORE_CASE)
    private val offer = Regex(
        """(\bpromo(?:si)?\s*(?:code|kod)\b|\bkod\s*promo\b|\bvoucher\b|\bcoupon\b|\bkupon\b|\bjackpot\b|\bdeposit\b|\bbonus\b|\d+\s*%\s*off\b|\bdiskaun\s*\d+\s*%|\bdaftar\s+sekarang\b|\bsign\s*up\s+now\b|\border\s+now\b|\bbuy\s+now\b|\bhubungi\s+kami\b|\bcontact\s+us\b|\bklik\s+(?:sini|link|pautan)\b|\bclick\s+(?:here|the\s+link)\b|\bdm\s+(?:me|for)\b|\bpm\s+(?:me|saya)\b)""",
        RegexOption.IGNORE_CASE,
    )

    private val digitRun = Regex("""\+?\d[\d\s().\-]{6,}\d""")

    /** A phone number: 9 or more digits in one run, allowing spaces, dots, dashes, brackets and a leading +. */
    fun hasPhoneNumber(text: String): Boolean = digitRun.findAll(text).any { m -> m.value.count { it.isDigit() } >= 9 }

    /** Which of the three tiles light up (crossed out) for [text]. Empty = nothing that looks like an advert. */
    fun tiles(text: String): Set<AdTile> {
        if (text.isBlank()) return emptySet()
        val out = linkedSetOf<AdTile>()
        val contact = contactWord.containsMatchIn(text) && (handle.containsMatchIn(text) || text.any { it.isDigit() })
        if (hasPhoneNumber(text) || contact) out += AdTile.PHONE
        if (link.containsMatchIn(text)) out += AdTile.LINK
        if (offer.containsMatchIn(text) || repeated.containsMatchIn(text)) out += AdTile.OFFER
        return out
    }

    /** Post stays disabled while this is true. */
    fun looksLikeAdvert(text: String): Boolean = tiles(text).isNotEmpty()
}

/** What an offending part of a rejected text or note was (one crossed-out tile each; see [ContentGate.issues]). */
enum class ContentIssue { PHONE, LINK, OFFER, GAMBLING, ALCOHOL, TOBACCO, SCAM, MONEY, VIOLENCE, ADULT, DRUGS, PERSONAL, HATE, ILLEGAL, OTHER }

/** The four tiles of the rejected-photo screen. */
enum class PhotoIssue { VIOLENCE, ADULT, GAMBLING_DRUGS, PLATES_FACES }

/** What the review/photo badge shows (tick, clock, cross). */
enum class ContentState { PUBLISHED, PROCESSING, REJECTED }

/** What a stored review is doing right now (the author's view). */
enum class ReviewState { PASSED, HELD, CHECKING, REJECTED }

/** A refused POST /places/{id}/reviews that the screens explain instead of showing an error. */
sealed interface ContentFailure {
    /** 422 `content_rejected`: nothing was stored. [safeText] = the review without the offending part, when one exists. */
    data class Rejected(val reasons: List<String>, val safeText: String?) : ContentFailure {
        val issues: List<ContentIssue> get() = ContentGate.issues(reasons)
    }
    /** 403 `posting_paused`: 3 AI rejections in 24 h. */
    data class Paused(val until: Instant?) : ContentFailure
    data class Other(val status: Int, val detail: String?) : ContentFailure
}

/** The inbox's three content kinds. */
enum class InboxContent { PUBLISHED, HELD, REJECTED }

object ContentGate {
    /** docs/content-safety.md "Report notes": the road-report note is at most 140 characters. */
    const val NOTE_MAX = 140

    /** docs/api.md: `POST /…/appeal {note?: ≤ 200}`. */
    const val APPEAL_MAX = 200

    /** Poll a photo every few seconds while it is processing, for about two minutes. */
    const val POLL_MS = 3_000L
    const val POLL_TRIES = 40

    // ---------------------------------------------------------------- reason codes → app categories

    /** Fixed reason codes → the crossed-out items, in a stable order (at most four, as the server sends at most four). */
    fun issues(reasons: List<String>): List<ContentIssue> {
        val out = linkedSetOf<ContentIssue>()
        for (r in reasons.map { it.trim().lowercase() }) {
            when (r) {
                "external_contact" -> { out += ContentIssue.PHONE; out += ContentIssue.LINK }
                "spam", "brand_promo", "counterfeit", "medical_claims" -> out += ContentIssue.OFFER
                "gambling_promo" -> out += ContentIssue.GAMBLING
                "alcohol_promo" -> out += ContentIssue.ALCOHOL
                "tobacco_promo" -> out += ContentIssue.TOBACCO
                "scam" -> out += ContentIssue.SCAM
                "high_risk_investment", "loan_shark", "mlm" -> out += ContentIssue.MONEY
                "violence" -> out += ContentIssue.VIOLENCE
                "adult" -> out += ContentIssue.ADULT
                "drugs" -> out += ContentIssue.DRUGS
                "personal_data", "private_home" -> out += ContentIssue.PERSONAL
                "harassment", "3r" -> out += ContentIssue.HATE
                "illegal" -> out += ContentIssue.ILLEGAL
                "ok", "sensitive_alcohol", "sensitive_gambling", "sensitive_tobacco" -> Unit
                else -> out += ContentIssue.OTHER   // gibberish, unclear, security, duplicate, wrong_category, and codes we don't know yet
            }
        }
        if (out.size > 1) out -= ContentIssue.OTHER   // a specific reason beats "something else"
        return out.toList().take(4).ifEmpty { listOf(ContentIssue.OTHER) }
    }

    /** The photo tiles that apply (crossed out); the rest of the four stay plain. Empty reasons light none. */
    fun photoIssues(reasons: List<String>): Set<PhotoIssue> {
        val out = linkedSetOf<PhotoIssue>()
        for (r in reasons.map { it.trim().lowercase() }) when (r) {
            "violence" -> out += PhotoIssue.VIOLENCE
            "adult" -> out += PhotoIssue.ADULT
            "drugs", "gambling_promo", "alcohol_promo", "tobacco_promo", "brand_promo", "illegal", "counterfeit" -> out += PhotoIssue.GAMBLING_DRUGS
            "personal_data", "private_home", "harassment" -> out += PhotoIssue.PLATES_FACES
        }
        return out
    }

    // ---------------------------------------------------------------- reviews (201 and 422)

    /** A stored review (201, or the author's list): what is happening to it. */
    fun reviewState(r: Review): ReviewState = when (r.moderation?.state?.lowercase()) {
        "rejected" -> ReviewState.REJECTED
        "held" -> ReviewState.HELD
        "checking" -> ReviewState.CHECKING
        "passed", "skipped" -> ReviewState.PASSED
        else -> if (r.heldForReview) ReviewState.HELD else ReviewState.PASSED
    }

    /** The refusal behind a failed review/photo write: [code] the HTTP status, [body] the problem JSON. */
    fun failure(code: Int, body: String?): ContentFailure {
        val pd = body?.let { runCatching { GimanoJson.decodeFromString(ProblemDetails.serializer(), it) }.getOrNull() }
        return when {
            code == 422 && pd?.code == "content_rejected" -> ContentFailure.Rejected(pd.reasons, pd.safeText?.trim()?.takeIf { it.isNotEmpty() })
            code == 403 && pd?.code == "posting_paused" -> ContentFailure.Paused(Formatters.parseInstant(pd.pausedUntil))
            else -> ContentFailure.Other(code, pd?.detail ?: pd?.title)
        }
    }

    /** "Post this part": the text to send again. Never longer than the app's limit. */
    fun safePart(f: ContentFailure.Rejected): String? = f.safeText?.take(ReviewPrefilter.SHOWN_MAX)

    // ---------------------------------------------------------------- photos

    fun photoState(p: Photo): ContentState {
        val m = p.moderation?.state?.lowercase()
        return when {
            p.status == "rejected" || m == "rejected" -> ContentState.REJECTED
            p.status == "published" && (m == null || m == "passed" || m == "skipped") -> ContentState.PUBLISHED
            else -> ContentState.PROCESSING   // processing, or held/checking for a person
        }
    }

    fun shouldPoll(p: Photo): Boolean = photoState(p) == ContentState.PROCESSING

    fun canAppeal(p: Photo): Boolean = p.moderation?.canAppeal == true

    // ---------------------------------------------------------------- road-report notes

    /** `noteDropped` on the POST /reports response: show a one-line note; the report itself was sent. */
    fun noteDropped(r: my.gimano.app.data.model.Report): Boolean = r.noteDropped

    // ---------------------------------------------------------------- inbox

    fun inboxContent(kind: String): InboxContent? = when (kind) {
        "content_published" -> InboxContent.PUBLISHED
        "content_held" -> InboxContent.HELD
        "content_rejected" -> InboxContent.REJECTED
        else -> null
    }

    /** "Appeal" shows on a rejected item the server says can still be appealed. */
    fun canAppeal(i: InboxItem): Boolean = inboxContent(i.kind) == InboxContent.REJECTED && i.canAppeal && i.subjectId != null

    /** "Edit": a review or a place can be edited; a photo is replaced ("Another photo") from its place. */
    fun canEdit(i: InboxItem): Boolean = inboxContent(i.kind) == InboxContent.REJECTED || inboxContent(i.kind) == InboxContent.HELD
}

/**
 * `403 posting_paused` until [until] (3 AI rejections in 24 h). Kept in memory and, through [persist], on this phone
 * (DataStore, never sent): a restart no longer forgets a pause that is still running. The server still decides.
 */
object PostingPause {
    private val _until = MutableStateFlow<Instant?>(null)
    val until: StateFlow<Instant?> = _until.asStateFlow()

    /** Told every change (a new pause, or null when cleared); set once by the app container. */
    @Volatile var persist: ((Instant?) -> Unit)? = null

    fun set(until: Instant?) { _until.value = until; persist?.invoke(until) }
    fun clear() { _until.value = null; persist?.invoke(null) }

    /** Loads the pause saved by a previous run; one that already ended is ignored (and not written back). */
    fun restore(saved: Instant?, now: Instant = Instant.now()) { _until.value = saved?.takeIf { it.isAfter(now) } }

    /** The pause that is still running at [now], or null. */
    fun active(now: Instant = Instant.now()): Instant? = _until.value?.takeIf { it.isAfter(now) }
}
