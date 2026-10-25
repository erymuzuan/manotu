package my.gimano.app.core.identity

import java.security.MessageDigest
import java.util.Base64

/**
 * Signed contribution requests (docs/identity-and-reputation.md §2):
 * `X-Gimano-Sig = base64(ed25519_sign(seed, "GIMANO1\n" + METHOD + "\n" + PATH_AND_QUERY + "\n" + ts + "\n" + hex(sha256(body))))`.
 * PATH_AND_QUERY is the request's encoded path as sent (including the `/api/v1` prefix) plus `?query` when present.
 */
object RequestSigning {
    const val HEADER_TS = "X-Gimano-Ts"
    const val HEADER_SIG = "X-Gimano-Sig"

    fun sha256Hex(bytes: ByteArray): String =
        MessageDigest.getInstance("SHA-256").digest(bytes).joinToString("") { "%02x".format(it) }

    fun canonical(method: String, pathAndQuery: String, ts: Long, body: ByteArray): String =
        "GIMANO1\n${method.uppercase()}\n$pathAndQuery\n$ts\n${sha256Hex(body)}"

    /** `POST /auth/token` proof: Ed25519 over "GIMANO-AUTH\n" + userId + "\n" + ts. */
    fun authMessage(userId: String, ts: Long): String = "GIMANO-AUTH\n$userId\n$ts"

    /** Sign-in by key (recovery code: the words give the seed, not the userId): "GIMANO1-LOGIN\n" + publicKey + "\n" + ts. */
    fun keyLoginMessage(publicKeyB64: String, ts: Long): String = "GIMANO1-LOGIN\n$publicKeyB64\n$ts"

    /** Play Integrity requestHash / App Attest clientData for a vote (docs §7): ts = the request's X-Gimano-Ts. */
    fun attestClientData(placeId: String, ts: Long): String = "GIMANO-ATTEST\n$placeId\n$ts"

    fun b64(bytes: ByteArray): String = Base64.getEncoder().encodeToString(bytes)

    private val rules: List<Pair<Set<String>, Regex>> = listOf(
        setOf("POST") to Regex("/places"),
        setOf("PATCH") to Regex("/places/[^/]+"),
        setOf("POST") to Regex("/places/[^/]+/(verify|suggest-edit|reviews)"),
        setOf("PATCH", "DELETE") to Regex("/reviews/[^/]+"),
        setOf("POST") to Regex("/photos"),
        setOf("POST") to Regex("/reports"),
        setOf("POST") to Regex("/reports/[^/]+/votes"),
        setOf("DELETE") to Regex("/reports/[^/]+"),
        // Complaints v1 (docs/api.md "Issues": auth, signed).
        setOf("POST") to Regex("/issues"),
        setOf("POST") to Regex("/issues/[^/]+/votes"),
    )

    /** True for the signed endpoints listed in the doc. [path] may carry the `/api/v1` prefix. */
    fun isSigned(method: String, path: String): Boolean {
        val p = path.substringAfter("/api/v1", path).trimEnd('/')
        return rules.any { (methods, re) -> method.uppercase() in methods && re.matches(p) }
    }
}
