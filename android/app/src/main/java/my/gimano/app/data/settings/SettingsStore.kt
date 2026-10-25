package my.gimano.app.data.settings

import android.content.Context
import androidx.datastore.preferences.core.Preferences
import androidx.datastore.preferences.core.booleanPreferencesKey
import androidx.datastore.preferences.core.edit
import androidx.datastore.preferences.core.stringPreferencesKey
import androidx.datastore.preferences.preferencesDataStore
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import my.gimano.app.BuildConfig
import my.gimano.app.core.safety.SafetyAgreement
import java.util.UUID

private val Context.dataStore by preferencesDataStore(name = "gimano_settings")

enum class SoundMode { ON, ALERTS_ONLY, OFF }

data class AppSettings(
    val token: String? = null,
    val userId: String? = null,
    val displayName: String? = null,
    val deviceId: String = "",
    val demoMode: Boolean = BuildConfig.DEMO_MODE_DEFAULT,
    val simulateDrive: Boolean = false,
    /** Debug builds only: the simulated drive leaves the route at the first turn (tests "Kenapa tak ikut laluan?"). */
    val simulateDetour: Boolean = false,
    val voiceLang: String = "auto", // auto | en | ms
    val soundMode: SoundMode = SoundMode.ON,
    /** Where a long-press "unmute" returns to (never OFF). */
    val lastNonMuteSound: SoundMode = SoundMode.ON,
    /** App voice volume for spoken directions, 0–100 % (on this phone only). */
    val voiceVolume: Int = SoundPrefs.DEFAULT_VOLUME,
    val vehicle: String = "car",     // car | motorcycle
    val apiBaseUrl: String = BuildConfig.API_BASE_URL,
    val mapStyleUrl: String = BuildConfig.MAP_STYLE_URL,
    val showTraffic: Boolean = true,
    val showAlerts: Boolean = true,
    val showDrivers: Boolean = true,
    val use24h: Boolean = false,
    /** Route preview "Go" countdown (10 s) for one-tap destinations. Default off. */
    val autoStartNav: Boolean = false,
    val autoBackup: Boolean = false,
    val lastBackupAt: String? = null,
    val lastBackupBytes: Long = 0,
    val lastBackupFingerprint: String? = null,
    val lastBackupDest: String? = null,
    val legacyMigrated: Boolean = false,
    val privacyCardDismissed: Boolean = false,
    /** "Sertakan maklumat peranti" (default ON per docs/api.md; previewed). Replaces 0.1.0's opt-in diagnostics. */
    val feedbackDevice: Boolean = false,
    val theme: String = "light",
    val inboxRead: Set<String> = emptySet(),
    /** "Kenapa tak ikut laluan?": "Jangan tanya lagi" and the last day it was asked (on this phone only). */
    val deviationNeverAsk: Boolean = false,
    val deviationLastAsked: String? = null,
    /**
     * Safety (docs/safety.md, on this phone and in the user's own backup only, never sent): the agreement version the
     * user agreed to (0 = never) and when; the drive reminder switch and when it was turned off.
     */
    val safetyAgreedVersion: Int = 0,
    val safetyAgreedAt: String? = null,
    val safetyReminderEnabled: Boolean = true,
    val safetyReminderDisabledAt: String? = null,
)

/** User-facing settings that travel with a backup (DB `settings` table, shared with iOS). */
fun AppSettings.toBackupMap(): Map<String, String> = mapOf(
    "voice_lang" to voiceLang,
    "sound_mode" to soundMode.name.lowercase(),
    "vehicle" to vehicle,
    "use_24h" to use24h.toString(),
    "show_traffic" to showTraffic.toString(),
    "show_alerts" to showAlerts.toString(),
    "show_drivers" to showDrivers.toString(),
    "theme" to theme,
    // Safety agreement + reminder (docs/safety.md): shared keys, so they travel with the user's own backup.
    SafetyAgreement.KEY_AGREED_VERSION to safetyAgreedVersion.toString(),
    SafetyAgreement.KEY_REMINDER_ENABLED to safetyReminderEnabled.toString(),
) + listOfNotNull(
    safetyAgreedAt?.let { SafetyAgreement.KEY_AGREED_AT to it },
    safetyReminderDisabledAt?.let { SafetyAgreement.KEY_REMINDER_DISABLED_AT to it },
)

/** DataStore-backed settings mirrored into a StateFlow so non-suspending code can read them. */
class SettingsStore(private val context: Context, private val scope: CoroutineScope) {
    private object K {
        val token = stringPreferencesKey("token")
        val userId = stringPreferencesKey("userId")
        val displayName = stringPreferencesKey("displayName")
        val deviceId = stringPreferencesKey("deviceId")
        val demoMode = booleanPreferencesKey("demoMode")
        val simulateDrive = booleanPreferencesKey("simulateDrive")
        val simulateDetour = booleanPreferencesKey("simulateDetour")
        val voiceLang = stringPreferencesKey("voiceLang")
        val soundMode = SoundPrefs.mode
        val vehicle = stringPreferencesKey("vehicle")
        val apiBaseUrl = stringPreferencesKey("apiBaseUrl")
        val mapStyleUrl = stringPreferencesKey("mapStyleUrl")
        val showTraffic = booleanPreferencesKey("showTraffic")
        val showAlerts = booleanPreferencesKey("showAlerts")
        val showDrivers = booleanPreferencesKey("showDrivers")
        val use24h = booleanPreferencesKey("use24h")
        val autoStartNav = booleanPreferencesKey("autoStartNav")
        val autoBackup = booleanPreferencesKey("autoBackup")
        val lastBackupAt = stringPreferencesKey("lastBackupAt")
        val lastBackupBytes = stringPreferencesKey("lastBackupBytes")
        val lastBackupFingerprint = stringPreferencesKey("lastBackupFingerprint")
        val lastBackupDest = stringPreferencesKey("lastBackupDest")
        val legacyMigrated = booleanPreferencesKey("legacyMigrated")
        val privacyCardDismissed = booleanPreferencesKey("privacyCardDismissed")
        val feedbackDevice = booleanPreferencesKey("feedbackDevice")
        val theme = stringPreferencesKey("theme")
        val inboxRead = androidx.datastore.preferences.core.stringSetPreferencesKey("inboxRead")
        val deviationNeverAsk = booleanPreferencesKey("deviationNeverAsk")
        val deviationLastAsked = stringPreferencesKey("deviationLastAsked")
        val safetyAgreedVersion = androidx.datastore.preferences.core.intPreferencesKey("safetyAgreedVersion")
        val safetyAgreedAt = stringPreferencesKey("safetyAgreedAt")
        val safetyReminderEnabled = booleanPreferencesKey("safetyReminderEnabled")
        val safetyReminderDisabledAt = stringPreferencesKey("safetyReminderDisabledAt")
    }

    private val _state: MutableStateFlow<AppSettings>
    val state: StateFlow<AppSettings>
    val current: AppSettings get() = _state.value

    init {
        // One small synchronous read at startup so the first frame has real settings.
        val initial = runBlocking { map(context.dataStore.data.first()) }
        _state = MutableStateFlow(initial)
        state = _state.asStateFlow()
        if (initial.deviceId.isBlank()) {
            scope.launch { context.dataStore.edit { it[K.deviceId] = UUID.randomUUID().toString() } }
        }
        scope.launch { context.dataStore.data.collect { _state.value = map(it) } }
    }

    private fun map(p: Preferences) = AppSettings(
        token = p[K.token],
        userId = p[K.userId],
        displayName = p[K.displayName],
        deviceId = p[K.deviceId] ?: "",
        demoMode = p[K.demoMode] ?: BuildConfig.DEMO_MODE_DEFAULT,
        simulateDrive = BuildConfig.DEBUG && (p[K.simulateDrive] ?: false),
        simulateDetour = BuildConfig.DEBUG && (p[K.simulateDetour] ?: false),
        voiceLang = p[K.voiceLang] ?: "auto",
        soundMode = SoundPrefs.mode(p),
        lastNonMuteSound = SoundPrefs.lastNonMute(p),
        voiceVolume = SoundPrefs.volume(p),
        vehicle = p[K.vehicle] ?: "car",
        // Release builds always use the built-in server; the override is a debug-only developer setting.
        apiBaseUrl = p[K.apiBaseUrl]?.takeIf { BuildConfig.DEBUG && it.isNotBlank() } ?: BuildConfig.API_BASE_URL,
        mapStyleUrl = p[K.mapStyleUrl]?.takeIf { it.isNotBlank() } ?: BuildConfig.MAP_STYLE_URL,
        showTraffic = p[K.showTraffic] ?: true,
        showAlerts = p[K.showAlerts] ?: true,
        showDrivers = p[K.showDrivers] ?: true,
        use24h = p[K.use24h] ?: false,
        autoStartNav = p[K.autoStartNav] ?: false,
        autoBackup = p[K.autoBackup] ?: false,
        lastBackupAt = p[K.lastBackupAt],
        lastBackupBytes = p[K.lastBackupBytes]?.toLongOrNull() ?: 0,
        lastBackupFingerprint = p[K.lastBackupFingerprint],
        lastBackupDest = p[K.lastBackupDest],
        legacyMigrated = p[K.legacyMigrated] ?: false,
        privacyCardDismissed = p[K.privacyCardDismissed] ?: false,
        // Opt-in: device info on feedback starts unticked (store review, user decision 2026-10-24).
        feedbackDevice = p[K.feedbackDevice] ?: false,
        theme = p[K.theme] ?: "light",
        inboxRead = p[K.inboxRead] ?: emptySet(),
        deviationNeverAsk = p[K.deviationNeverAsk] ?: false,
        deviationLastAsked = p[K.deviationLastAsked],
        safetyAgreedVersion = p[K.safetyAgreedVersion] ?: 0,
        safetyAgreedAt = p[K.safetyAgreedAt],
        safetyReminderEnabled = p[K.safetyReminderEnabled] ?: true,
        safetyReminderDisabledAt = p[K.safetyReminderDisabledAt],
    )

    /**
     * Writes and publishes at once: callers read [current] right after a setter (demo mode → which repository answers,
     * server URL → where the next request goes), before the DataStore collector would have caught up.
     */
    private suspend fun edit(block: suspend (androidx.datastore.preferences.core.MutablePreferences) -> Unit): Preferences =
        context.dataStore.edit(block).also { _state.value = map(it) }

    suspend fun deviceId(): String {
        current.deviceId.takeIf { it.isNotBlank() }?.let { return it }
        val id = UUID.randomUUID().toString()
        context.dataStore.edit { if (it[K.deviceId].isNullOrBlank()) it[K.deviceId] = id }
        return context.dataStore.data.first()[K.deviceId] ?: id
    }

    suspend fun saveAuth(token: String?, userId: String?, displayName: String?) = context.dataStore.edit {
        if (token == null) it.remove(K.token) else it[K.token] = token
        if (userId == null) it.remove(K.userId) else it[K.userId] = userId
        if (displayName == null) it.remove(K.displayName) else it[K.displayName] = displayName
    }.also { _state.value = _state.value.copy(token = token, userId = userId, displayName = displayName) }

    suspend fun setDisplayName(v: String) = edit { it[K.displayName] = v }
    suspend fun setDemoMode(v: Boolean) = edit { it[K.demoMode] = v }
    suspend fun setSimulateDrive(v: Boolean) = edit { it[K.simulateDrive] = v }
    suspend fun setSimulateDetour(v: Boolean) = edit { it[K.simulateDetour] = v }
    suspend fun setVoiceLang(v: String) = edit { it[K.voiceLang] = v }
    suspend fun setSoundMode(v: SoundMode) = edit { SoundPrefs.setMode(it, v) }
    suspend fun setVoiceVolume(percent: Int) = edit { SoundPrefs.setVolume(it, percent) }
    suspend fun setVehicle(v: String) = edit { it[K.vehicle] = v }
    suspend fun setApiBaseUrl(v: String) = edit {
        it[K.apiBaseUrl] = v.trim().let { u -> if (u.isEmpty() || u.endsWith("/")) u else "$u/" }
        // A different server means a different identity.
        it.remove(K.token)
    }
    suspend fun setMapStyleUrl(v: String) = edit { it[K.mapStyleUrl] = v.trim() }
    suspend fun setLayers(traffic: Boolean, alerts: Boolean, drivers: Boolean) = edit {
        it[K.showTraffic] = traffic; it[K.showAlerts] = alerts; it[K.showDrivers] = drivers
    }
    suspend fun setUse24h(v: Boolean) = edit { it[K.use24h] = v }
    suspend fun setAutoStartNav(v: Boolean) = edit { it[K.autoStartNav] = v }
    suspend fun setAutoBackup(v: Boolean) = edit { it[K.autoBackup] = v }
    suspend fun setLastBackup(at: String, bytes: Long, fingerprint: String, dest: String) = edit {
        it[K.lastBackupAt] = at; it[K.lastBackupBytes] = bytes.toString(); it[K.lastBackupFingerprint] = fingerprint; it[K.lastBackupDest] = dest
    }
    suspend fun setLegacyMigrated() = edit { it[K.legacyMigrated] = true }
    suspend fun setPrivacyCardDismissed() = edit { it[K.privacyCardDismissed] = true }
    suspend fun setFeedbackDevice(v: Boolean) = edit { it[K.feedbackDevice] = v }
    suspend fun setTheme(v: String) = edit { it[K.theme] = v }
    suspend fun setDeviationAsked(day: String, neverAgain: Boolean) = edit {
        it[K.deviationLastAsked] = day; if (neverAgain) it[K.deviationNeverAsk] = true
    }
    /** "Saya faham dan setuju": the version and the moment (ISO-8601 UTC), on this phone only. */
    suspend fun agreeSafety(version: Int, at: String) = edit { it[K.safetyAgreedVersion] = version; it[K.safetyAgreedAt] = at }
    /** The drive reminder on/off; turning it off remembers when ("Dimatikan pada {date}"). */
    suspend fun setSafetyReminder(enabled: Boolean, at: String) = edit {
        it[K.safetyReminderEnabled] = enabled
        if (enabled) it.remove(K.safetyReminderDisabledAt) else it[K.safetyReminderDisabledAt] = at
    }
    /** Debug builds only ("Reset safety"): back to a first run without wiping anything else. */
    suspend fun resetSafetyDebug() = edit {
        it.remove(K.safetyAgreedVersion); it.remove(K.safetyAgreedAt); it.remove(K.safetyReminderEnabled); it.remove(K.safetyReminderDisabledAt)
    }
    /** Local read/unread state for the inbox (kept to the last 500 ids). */
    suspend fun markInboxRead(ids: Collection<String>) = edit { p ->
        p[K.inboxRead] = ((p[K.inboxRead] ?: emptySet()) + ids).toList().takeLast(500).toSet()
    }

    /** Applies settings restored from a backup's `settings` table. */
    suspend fun applyBackupMap(m: Map<String, String>) = edit { p ->
        m["voice_lang"]?.let { p[K.voiceLang] = it }
        m["sound_mode"]?.let { v -> runCatching { SoundMode.valueOf(v.uppercase()) }.getOrNull()?.let { SoundPrefs.setMode(p, it) } }
        m["vehicle"]?.let { p[K.vehicle] = it }
        m["use_24h"]?.let { p[K.use24h] = it.toBoolean() }
        m["show_traffic"]?.let { p[K.showTraffic] = it.toBoolean() }
        m["show_alerts"]?.let { p[K.showAlerts] = it.toBoolean() }
        m["show_drivers"]?.let { p[K.showDrivers] = it.toBoolean() }
        m["theme"]?.let { p[K.theme] = it }
        // Agreement: the later version wins (a restore never asks someone to agree again for terms they accepted).
        m[SafetyAgreement.KEY_AGREED_VERSION]?.toIntOrNull()?.let { v ->
            val (ver, at) = SafetyAgreement.newer(
                (p[K.safetyAgreedVersion] ?: 0) to p[K.safetyAgreedAt], v to m[SafetyAgreement.KEY_AGREED_AT])
            p[K.safetyAgreedVersion] = ver
            if (at != null) p[K.safetyAgreedAt] = at
        }
        m[SafetyAgreement.KEY_REMINDER_ENABLED]?.let { v ->
            val on = v.toBoolean()
            p[K.safetyReminderEnabled] = on
            val at = m[SafetyAgreement.KEY_REMINDER_DISABLED_AT]
            if (on || at == null) p.remove(K.safetyReminderDisabledAt) else p[K.safetyReminderDisabledAt] = at
        }
    }
}
