package my.gimano.app.core.safety

import java.text.Normalizer
import java.util.Locale

/**
 * The server's `terms` (docs/api.md "Restricted areas"): security details that must not be written about anywhere
 * (entrances, guards, CCTV, fences, patrol times…). Matched as whole words or phrases, ignoring case and accents.
 * The phone only warns; the server holds a matching place or review for a moderator.
 */
class SensitiveTerms(terms: List<String>) {
    private val needles: List<Pair<String, String>> = terms.mapNotNull { t -> norm(t).takeIf { it.isNotBlank() }?.let { t to " $it " } }

    val isEmpty: Boolean get() = needles.isEmpty()

    /** The terms (as the server sent them) found in [text]. */
    fun matches(text: String?): List<String> {
        if (text.isNullOrBlank() || needles.isEmpty()) return emptyList()
        val hay = " ${norm(text)} "
        return needles.filter { (_, n) -> hay.contains(n) }.map { it.first }
    }

    fun hasMatch(text: String?): Boolean = matches(text).isNotEmpty()

    /** "Buang ayat ini": removes every sentence that contains a term, keeps the rest as written. */
    fun removeSentences(text: String): String =
        sentences(text).filterNot { hasMatch(it) }.joinToString("").replace(Regex("[ \\t]{2,}"), " ").trim()

    companion object {
        private val MARKS = Regex("\\p{M}+")
        private val NON_WORD = Regex("[^\\p{L}\\p{N}]+")
        private val SENTENCE = Regex("[^.!?\\n]+[.!?\\n]*|[.!?\\n]+")

        /** Lower case, accents dropped, punctuation → single spaces. */
        fun norm(s: String): String =
            MARKS.replace(Normalizer.normalize(s, Normalizer.Form.NFD), "").lowercase(Locale.ROOT).replace(NON_WORD, " ").trim()

        fun sentences(text: String): List<String> = SENTENCE.findAll(text).map { it.value }.toList()
    }
}
