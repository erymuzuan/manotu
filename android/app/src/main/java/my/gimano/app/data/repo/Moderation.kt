package my.gimano.app.data.repo

import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.SharedFlow

/**
 * Moderation outcomes the app must explain: a moderator-banned account gets 403 on every public contribution
 * (docs/api.md). The UI shows one plain message ("your account can't post…, contact …") instead of a generic error.
 */
object Moderation {
    private val _banned = MutableSharedFlow<Unit>(extraBufferCapacity = 1)
    val banned: SharedFlow<Unit> = _banned

    fun reportBanned() { _banned.tryEmit(Unit) }

    /** Is this failure the "banned" 403? (Not the `adding_paused` 403, which only pauses new places.) */
    fun isBanned(t: Throwable?): Boolean = (t as? retrofit2.HttpException)?.let { it.code() == 403 && !isAddingPaused(it) } == true

    /**
     * 403 `code: "adding_paused"` (docs/api.md "AI check") or `posting_paused` (docs/content-safety.md "Reviews": 3 AI
     * rejections in 24 h). Neither is a ban. Reads the body without consuming it.
     */
    fun isAddingPaused(e: retrofit2.HttpException): Boolean {
        if (e.code() != 403) return false
        val body = runCatching { e.response()?.errorBody()?.source()?.peek()?.readUtf8() }.getOrNull() ?: return false
        return isPausedBody(body)
    }

    fun isPausedBody(body: String): Boolean {
        val pd = runCatching { my.gimano.app.data.remote.GimanoJson.decodeFromString(my.gimano.app.data.model.ProblemDetails.serializer(), body) }.getOrNull()
        return pd?.code == "adding_paused" || pd?.code == "posting_paused"
    }
}

/**
 * The server refused a write in or next to a restricted area (docs/api.md "Restricted areas": 422 ProblemDetails with
 * `code: "restricted_area"`). [detail] is the server's text, already in the app's language; it is shown as is.
 */
class RestrictedAreaException(val detail: String) : Exception(detail) {
    companion object {
        const val CODE = "restricted_area"

        /** The refusal inside [e], or null for any other error. Reads the body without consuming it. */
        fun from(e: retrofit2.HttpException): RestrictedAreaException? {
            if (e.code() != 422) return null
            val body = runCatching { e.response()?.errorBody()?.source()?.peek()?.readUtf8() }.getOrNull() ?: return null
            return parse(body)
        }

        fun parse(body: String): RestrictedAreaException? {
            val o = runCatching { my.gimano.app.data.remote.GimanoJson.decodeFromString(my.gimano.app.data.model.ProblemDetails.serializer(), body) }.getOrNull() ?: return null
            if (o.code != CODE) return null
            return RestrictedAreaException(o.detail?.takeIf { it.isNotBlank() } ?: o.title.orEmpty())
        }
    }
}
