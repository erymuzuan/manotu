package my.gimano.app.data.update

import android.content.Context
import android.content.Intent
import android.net.Uri
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.withContext
import my.gimano.app.BuildConfig
import my.gimano.app.core.update.StoreUpdateDecision
import my.gimano.app.core.update.StoreUpdatePolicy
import my.gimano.app.core.update.StoreVersion
import okhttp3.OkHttpClient
import okhttp3.Request
import java.util.concurrent.TimeUnit

data class StoreUpdateUi(
    val decision: StoreUpdateDecision = StoreUpdateDecision.None,
    /** "Later" was tapped in this process: the soft card stays hidden until the next cold start. */
    val laterThisLaunch: Boolean = false,
    val checking: Boolean = false,
)

/**
 * Google Play build: tells people a newer version is in the store (docs/app-updates.md). Anonymous plain GET of
 * `{apiBase}app/versions`: no identifiers, no auth header, failures are silent. The last answer is cached on the
 * phone so a forced update stays enforced offline. Never installs anything: it only opens the store listing.
 */
class StoreUpdater(private val context: Context, private val apiBase: () -> String) {
    companion object {
        private const val PREFS = "gimano.storeupdater"
        /** Debug builds only: lets the card be exercised without a Play install. */
        const val DEBUG_TOGGLE = "debugToggle"
    }

    private val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
    private val http = OkHttpClient.Builder().connectTimeout(10, TimeUnit.SECONDS).readTimeout(15, TimeUnit.SECONDS).build()
    private val current = BuildConfig.VERSION_NAME
    private val _ui = MutableStateFlow(StoreUpdateUi())
    val ui: StateFlow<StoreUpdateUi> = _ui.asStateFlow()

    fun enabled() = StoreUpdatePolicy.enabled(BuildConfig.DISTRIBUTION, BuildConfig.DEBUG, debugToggle())
    fun debugToggle() = BuildConfig.DEBUG && prefs.getBoolean(DEBUG_TOGGLE, false)
    fun setDebugToggle(on: Boolean) {
        if (!BuildConfig.DEBUG) return
        prefs.edit().putBoolean(DEBUG_TOGGLE, on).putLong("lastCheck", 0).apply()
        refreshFromCache()
    }

    private fun cached(): StoreVersion? = prefs.getString("body", null)?.let(StoreVersion::parse)
    fun storeVersion(): StoreVersion? = cached()

    /** Re-derive the decision from the cached answer (a forced update stays enforced offline). */
    fun refreshFromCache() = _ui.update { it.copy(decision = if (enabled()) StoreUpdatePolicy.decide(current, cached()) else StoreUpdateDecision.None) }

    /** At launch and on returning to the foreground, at most every 30 minutes. */
    suspend fun check() {
        if (!enabled()) { refreshFromCache(); return }
        refreshFromCache()
        val now = System.currentTimeMillis()
        if (_ui.value.checking || !StoreUpdatePolicy.shouldCheck(prefs.getLong("lastCheck", 0), now)) return
        _ui.update { it.copy(checking = true) }
        val text = withContext(Dispatchers.IO) {
            runCatching {
                val url = apiBase().let { if (it.endsWith("/")) it else "$it/" } + "app/versions"
                http.newCall(Request.Builder().url(url).header("Cache-Control", "no-cache").build()).execute().use { r ->
                    if (r.code == 200) r.body?.string() else null
                }
            }.getOrNull()
        }
        if (text != null && StoreVersion.parse(text) != null) prefs.edit().putString("body", text).putLong("lastCheck", now).apply()
        _ui.update { it.copy(checking = false) }
        refreshFromCache()
    }

    fun later() = _ui.update { it.copy(laterThisLaunch = true) }

    /** market:// first; the https store URL when no Play Store app can handle it. */
    fun openStore() {
        val https = StoreUpdatePolicy.storeUrl(cached())
        fun go(uri: String) = runCatching {
            context.startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(uri)).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
        }.isSuccess
        if (!go(StoreUpdatePolicy.MARKET_URI)) go(https)
    }
}
