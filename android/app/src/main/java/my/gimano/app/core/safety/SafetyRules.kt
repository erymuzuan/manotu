package my.gimano.app.core.safety

/**
 * The safety agreement and the drive reminder (docs/safety.md parts 1–2). Everything here is decided on the phone;
 * the agreement version/date and the reminder switch live in the settings store (and the user's own backup) only.
 */
object SafetyAgreement {
    /** Bump only when the terms change in a way that matters to drivers: everyone is asked again. */
    const val VERSION = 1
    const val TERMS_URL = "https://manotu.app/terms/"
    const val PRIVACY_URL = "https://manotu.app/privacy/"

    /** Shared backup `settings` keys (same names as docs/safety.md; iOS uses the same). */
    const val KEY_AGREED_VERSION = "safety.agreedVersion"
    const val KEY_AGREED_AT = "safety.agreedAt"
    const val KEY_REMINDER_ENABLED = "safety.reminderEnabled"
    const val KEY_REMINDER_DISABLED_AT = "safety.reminderDisabledAt"

    fun needsAgreement(agreedVersion: Int): Boolean = agreedVersion < VERSION

    /** Merge restore: keep whichever side agreed to the later version (with its date); ties keep this phone's. */
    fun newer(local: Pair<Int, String?>, backup: Pair<Int, String?>): Pair<Int, String?> =
        if (backup.first > local.first) backup else local
}

/** What happens when the user starts a drive. */
enum class ReminderAction {
    /** Show the "Pandu dengan selamat" card; guidance starts after its button. */
    CARD,
    /** Already moving: start at once with the one-line banner for [SafetyReminder.BANNER_MS]. */
    BANNER,
    /** Reminder turned off: nothing at all. */
    NONE,
}

object SafetyReminder {
    /** At or above this speed the card is never shown (or is closed): the driver must not read it. */
    const val MOVING_KMH = 10.0
    const val BANNER_MS = 5_000L
    /** Routes longer than this get the highlighted "rest every 2 hours" line. */
    const val LONG_DRIVE_S = 2 * 3600.0

    /** [speedKmh] null = unknown (no fix yet, or the fix has no speed): treated as stopped. */
    fun onStart(enabled: Boolean, speedKmh: Double?): ReminderAction = when {
        !enabled -> ReminderAction.NONE
        isMoving(speedKmh) -> ReminderAction.BANNER
        else -> ReminderAction.CARD
    }

    fun isMoving(speedKmh: Double?): Boolean = speedKmh != null && speedKmh >= MOVING_KMH

    fun isLongDrive(durationS: Double?): Boolean = durationS != null && durationS > LONG_DRIVE_S
}
