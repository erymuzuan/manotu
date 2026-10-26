import Foundation

/// The demo stand-in for the server's public content check (docs/content-safety.md). It never calls a model: the same
/// local rules as the review pre-filter plus a few words, so every screen can be seen offline.
/// - phone number / link / WhatsApp or Telegram → rejected `external_contact`, with the rest of the text as `safeText`;
///   promo words or repeated characters → rejected `brand_promo` / `spam`; violent words → rejected `violence` (no safe text);
///   `#held` → held for a person; `#slow` → checking (published after 20 s, note in the Inbox); otherwise passed.
/// - A neutral mention ("a vape shop is next door") passes.
/// - Photos: caption `#reject` / `#held` or the debug default `GimanoDemoPhotoVerdict` (`rejected` | `held` | `checking`).
enum DemoContentCheck {
    struct Verdict: Equatable {
        var state: ModerationState
        var reasons: [String] = []
        var safeText: String?
    }

    /// How long a `#slow` check takes.
    static let slowCheck: TimeInterval = 20

    static func verdict(text: String?) -> Verdict {
        let raw = (text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = raw.lowercased()
        guard !raw.isEmpty else { return Verdict(state: .passed, reasons: ["ok"]) }
        if lower.contains("#slow") { return Verdict(state: .checking) }
        if lower.contains("#held") { return Verdict(state: .held, reasons: ["unclear"]) }
        if ["bunuh kau", "kill you", "i will kill", "bom ", "bomb"].contains(where: lower.contains) {
            return Verdict(state: .rejected, reasons: ["violence"])
        }
        let hints = ReviewPrefilter.hints(raw)
        guard !hints.isEmpty else { return Verdict(state: .passed, reasons: ["ok"]) }
        var reasons: [String] = []
        if hints.contains(.phone) || hints.contains(.link) { reasons.append("external_contact") }
        if hints.contains(.offer) { reasons.append(ReviewPrefilter.hasOfferWords(lower) ? "brand_promo" : "spam") }
        return Verdict(state: .rejected, reasons: reasons, safeText: safeText(raw))
    }

    /// The text without the sentences that look like an advert; nil when nothing is left.
    static func safeText(_ text: String) -> String? {
        var kept: [String] = [], current = ""
        func flush() {
            let s = current.trimmingCharacters(in: .whitespacesAndNewlines)
            if !s.isEmpty, !ReviewPrefilter.looksLikeAdvert(s) { kept.append(s) }
            current = ""
        }
        for ch in text {
            current.append(ch)
            if ".!?\n".contains(ch) { flush() }
        }
        flush()
        let out = kept.joined(separator: " ")
        return out.isEmpty || out == text ? nil : out
    }

    static func photoVerdict(caption: String?, debugDefault: String? = UserDefaults.standard.string(forKey: "GimanoDemoPhotoVerdict")) -> Verdict {
        let c = (caption ?? "").lowercased()
        if c.contains("#reject") { return Verdict(state: .rejected, reasons: ["adult"]) }
        if c.contains("#held") { return Verdict(state: .held, reasons: ["unclear"]) }
        switch debugDefault {
        case "rejected": return Verdict(state: .rejected, reasons: ["violence"])
        case "held": return Verdict(state: .held, reasons: ["unclear"])
        case "checking": return Verdict(state: .checking)
        default: return Verdict(state: .passed, reasons: ["ok"])
        }
    }

    /// Demo places that sell or host something worth a warning (OSM-style tags on the real server).
    static func warnings(forPlaceNamed name: String) -> [String]? {
        let n = name.lowercased()
        var out: [String] = []
        if ["bar ", " pub", "wine", "liquor", "beer", "bir "].contains(where: { (n + " ").contains($0) }) { out.append("alcohol") }
        if ["casino", "kasino", "4d", "toto", "magnum", "lottery"].contains(where: n.contains) { out.append("gambling") }
        if ["vape", "tobacco", "rokok", "cigar"].contains(where: n.contains) { out.append("tobacco") }
        return out.isEmpty ? nil : out
    }
}
