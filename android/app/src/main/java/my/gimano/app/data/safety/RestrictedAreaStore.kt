package my.gimano.app.data.safety

import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import kotlinx.serialization.Serializable
import my.gimano.app.core.GLog
import my.gimano.app.core.geo.GeoPoint
import my.gimano.app.core.safety.RestrictedAreas
import my.gimano.app.core.safety.RestrictedZone
import my.gimano.app.core.safety.SensitiveTerms
import my.gimano.app.data.remote.GimanoJson
import okhttp3.OkHttpClient
import okhttp3.Request
import java.io.File
import java.util.concurrent.TimeUnit

/** GET /restricted-areas (docs/api.md "Restricted areas"). Parsed leniently. */
@Serializable
data class RestrictedAreasDto(
    val version: String = "",
    val blockM: Double = 100.0,
    val reviewM: Double = 300.0,
    val terms: List<String> = emptyList(),
    /** Outer rings, `[[lng, lat], …]`. */
    val areas: List<List<List<Double>>> = emptyList(),
) {
    fun toAreas() = RestrictedAreas(version, blockM, reviewM, terms,
        areas.map { ring -> ring.mapNotNull { c -> if (c.size >= 2) GeoPoint(c[1], c[0]) else null } })

    companion object {
        fun parse(json: String): RestrictedAreasDto = GimanoJson.decodeFromString(serializer(), json)
    }
}

/**
 * The phone's copy of the restricted areas. The WHOLE set is downloaded (never a bounding box), anonymously (no account
 * token), so the request says nothing about where the user is; the check itself runs offline. Fetched at start-up and
 * at most once a day, with If-None-Match; the last good copy is kept in a file. With no copy (endpoint not deployed:
 * 404, offline), there is simply no client-side check: the server still refuses.
 */
class RestrictedAreaStore(
    private val dir: File,
    private val baseUrl: () -> String,
    private val offline: () -> Boolean = { false },
    private val client: OkHttpClient = OkHttpClient.Builder().connectTimeout(8, TimeUnit.SECONDS).callTimeout(40, TimeUnit.SECONDS).build(),
    private val now: () -> Long = System::currentTimeMillis,
    /** Debug builds only: a fixture used while the server has no data (never set in release). */
    private val debugFixture: (() -> String?)? = null,
) {
    private val dataFile get() = File(dir, "restricted-areas.json")
    private val metaFile get() = File(dir, "restricted-areas.meta")
    private val lock = Mutex()

    private val _areas = MutableStateFlow<RestrictedAreas?>(null)
    /** Null = no data (no client-side check). */
    val areas: StateFlow<RestrictedAreas?> = _areas.asStateFlow()
    private val _terms = MutableStateFlow(SensitiveTerms(emptyList()))
    val terms: StateFlow<SensitiveTerms> = _terms.asStateFlow()
    /** True while the areas come from the debug fixture. */
    @Volatile var fromFixture = false
        private set

    private var lastAttemptMs = 0L
    private var lastSuccessMs = 0L
    private var etag: String? = null

    fun zone(p: GeoPoint): RestrictedZone = _areas.value?.zone(p) ?: RestrictedZone.CLEAR
    fun inside(p: GeoPoint): Boolean = _areas.value?.contains(p) == true

    /** Loads the cached copy (or the debug fixture). Call once at start-up, off the main thread. */
    suspend fun loadCached() = withContext(Dispatchers.IO) {
        lock.withLock {
            runCatching {
                metaFile.takeIf { it.exists() }?.readLines()?.let { l ->
                    etag = l.getOrNull(0)?.takeIf { it.isNotBlank() }
                    lastSuccessMs = l.getOrNull(1)?.toLongOrNull() ?: 0L
                }
                dataFile.takeIf { it.exists() }?.readText()?.let { publish(RestrictedAreasDto.parse(it), fixture = false) }
            }.onFailure { GLog.w("Restricted", "cache unreadable (${it.javaClass.simpleName})") }
            // Debug only: no shapes yet (no copy, or the server's list is still empty) → the fixture's shapes.
            if (_areas.value?.isEmpty != false) useFixture(serverTerms = _areas.value?.terms)
        }
    }

    /** Fetches when the copy is older than a day ([force]: now). 304 keeps the copy; 404/offline keeps whatever there is. */
    suspend fun refresh(force: Boolean = false) = withContext(Dispatchers.IO) {
        lock.withLock {
            val t = now()
            if (offline()) return@withLock
            // A real, non-empty copy is re-checked daily; an empty one (server still importing) like no data at all.
            val hasData = _areas.value?.isEmpty == false && !fromFixture
            if (!force && hasData && t - lastSuccessMs < DAY_MS) return@withLock
            // Without data (e.g. the endpoint isn't deployed yet): at most one try per RETRY_MS.
            if (!force && t - lastAttemptMs < RETRY_MS) return@withLock
            lastAttemptMs = t
            val url = baseUrl().let { if (it.endsWith("/")) it else "$it/" } + "restricted-areas"
            val req = Request.Builder().url(url).header("Accept", "application/json")
                .apply { if (!fromFixture) etag?.let { header("If-None-Match", it) } }.build()
            try {
                client.newCall(req).execute().use { r ->
                    when {
                        r.code == 304 -> { lastSuccessMs = t; writeMeta() }
                        r.isSuccessful -> {
                            val body = r.body?.string().orEmpty()
                            val dto = RestrictedAreasDto.parse(body)
                            etag = r.header("ETag")
                            lastSuccessMs = t
                            File(dir, "restricted-areas.json.tmp").apply { writeText(body); renameTo(dataFile) }
                            writeMeta()
                            publish(dto, fixture = false)
                            // Debug only: while the server's list is still empty, keep testing against the fixture.
                            if (dto.areas.isEmpty()) useFixture(serverTerms = dto.terms)
                            GLog.i("Restricted", "areas v${dto.version}: ${dto.areas.size} shapes, ${dto.terms.size} terms")
                        }
                        else -> GLog.i("Restricted", "GET restricted-areas → HTTP ${r.code}; keeping ${if (_areas.value == null) "no data" else "the last copy"}")
                    }
                }
            } catch (e: Exception) {
                GLog.i("Restricted", "GET restricted-areas failed (${e.javaClass.simpleName})")
            }
        }
    }

    private fun writeMeta() = runCatching { metaFile.writeText("${etag.orEmpty()}\n$lastSuccessMs\n") }

    private fun useFixture(serverTerms: List<String>? = null) {
        val json = debugFixture?.invoke() ?: return
        runCatching { RestrictedAreasDto.parse(json).let { f -> publish(if (serverTerms.isNullOrEmpty()) f else f.copy(terms = serverTerms), fixture = true) } }
            .onSuccess { GLog.i("Restricted", "DEBUG fixture in use (${_areas.value?.rings?.size} shapes)") }
    }

    private fun publish(dto: RestrictedAreasDto, fixture: Boolean) {
        fromFixture = fixture
        _areas.value = dto.toAreas()
        _terms.value = SensitiveTerms(dto.terms)
    }

    companion object {
        const val DAY_MS = 24 * 3600 * 1000L
        const val RETRY_MS = 30 * 60 * 1000L
    }
}
