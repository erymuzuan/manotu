import Foundation

/// Safety agreement + drive reminder (docs/safety.md parts 1–3). Everything here is on the device only: the
/// agreement version and date and the reminder switch live in the shared `settings` table, go into the user's own
/// backup, and are never sent anywhere (no analytics, no log line).
enum SafetyPolicy {
    /// Bump only when the terms change in a way that matters to drivers: everyone sees the agreement once more.
    static let agreementVersion = 1

    // Shared settings keys (same as Android).
    static let agreedVersionKey = "safety.agreedVersion"
    static let agreedAtKey = "safety.agreedAt"
    static let reminderEnabledKey = "safety.reminderEnabled"
    static let reminderDisabledAtKey = "safety.reminderDisabledAt"

    static let termsURL = URL(string: "https://manotu.app/terms/")!
    static let privacyURL = URL(string: "https://manotu.app/privacy/")!

    /// At or above this speed the card is never shown (or is closed): a one-line banner instead.
    static let movingKmh: Double = 10
    /// Routes longer than this get the highlighted "rest every 2 hours" line.
    static let longDriveS: Double = 2 * 3600
    static let bannerSeconds: Double = 5

    static func needsAgreement(agreedVersion: Int) -> Bool { agreedVersion < agreementVersion }

    /// Settings values are text: "1" / "true" are on; a missing row is the default.
    static func parseBool(_ raw: String?, default def: Bool) -> Bool {
        guard let raw = raw?.trimmingCharacters(in: .whitespaces).lowercased(), !raw.isEmpty else { return def }
        return raw == "1" || raw == "true" || raw == "yes"
    }

    static func parseVersion(_ raw: String?) -> Int { raw.flatMap { Int($0.trimmingCharacters(in: .whitespaces)) } ?? 0 }

    enum StartReminder: Equatable {
        /// Reminder off: start at once, nothing shown.
        case none
        /// Stopped (or speed unknown): the card over the map; guidance starts after its button.
        case card
        /// Already moving: start at once with a 5 s one-line banner, nothing to tap.
        case banner
    }

    /// What to show when navigation is started (never on resume/reroute).
    static func reminder(enabled: Bool, speedKmh: Double?) -> StartReminder {
        guard enabled else { return .none }
        guard let v = speedKmh, v >= 0 else { return .card }
        return v >= movingKmh ? .banner : .card
    }

    /// The open card closes (and guidance starts with the banner) once the speed reaches 10 km/h.
    static func shouldCloseCard(speedKmh: Double?) -> Bool { (speedKmh ?? 0) >= movingKmh }

    static func isLongDrive(durationS: Double?) -> Bool { (durationS ?? 0) > longDriveS }

    /// Merge restore: the later agreement version wins, with its date; the reminder switch keeps this phone's value.
    static func mergedAgreement(local: (version: String?, at: String?), backup: (version: String?, at: String?))
        -> (version: String?, at: String?) {
        parseVersion(backup.version) > parseVersion(local.version) ? backup : local
    }
}

/// The safety settings as the app uses them.
struct SafetySettings: Equatable {
    var agreedVersion = 0
    var agreedAt: Date?
    var reminderEnabled = true
    var reminderDisabledAt: Date?

    var hasAgreed: Bool { !SafetyPolicy.needsAgreement(agreedVersion: agreedVersion) }

    init() {}

    init(store: LocalStore) {
        agreedVersion = SafetyPolicy.parseVersion(try? store.setting(SafetyPolicy.agreedVersionKey))
        agreedAt = LocalStore.date(try? store.setting(SafetyPolicy.agreedAtKey))
        reminderEnabled = SafetyPolicy.parseBool(try? store.setting(SafetyPolicy.reminderEnabledKey), default: true)
        reminderDisabledAt = LocalStore.date(try? store.setting(SafetyPolicy.reminderDisabledAtKey))
    }

    func save(to store: LocalStore) {
        try? store.setSetting(SafetyPolicy.agreedVersionKey, agreedVersion > 0 ? String(agreedVersion) : nil)
        try? store.setSetting(SafetyPolicy.agreedAtKey, agreedAt.map { LocalStore.timestamp($0) })
        try? store.setSetting(SafetyPolicy.reminderEnabledKey, reminderEnabled ? "true" : "false")
        try? store.setSetting(SafetyPolicy.reminderDisabledAtKey, reminderEnabled ? nil : reminderDisabledAt.map { LocalStore.timestamp($0) })
    }
}
