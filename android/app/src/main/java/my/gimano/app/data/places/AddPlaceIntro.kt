package my.gimano.app.data.places

import android.content.SharedPreferences

/** A1 "How adding a place works" (design TpIntro): shown once on this phone, before the first shared place. */
class AddPlaceIntro(private val prefs: SharedPreferences) {
    val seen: Boolean get() = prefs.getBoolean(KEY, false)
    fun markSeen() = prefs.edit().putBoolean(KEY, true).apply()

    private companion object { const val KEY = "intro_seen" }
}
