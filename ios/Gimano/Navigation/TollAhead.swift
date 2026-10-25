import Foundation

// MARK: - Toll ahead (docs/driving.md §1)

/// A toll plaza placed on the active route: `distanceAlongRouteM` from the server, or the plaza projected onto the
/// route when an older server leaves it out.
struct RouteToll: Sendable, Hashable, Identifiable {
    var plaza: TollPlaza
    var alongM: Double
    var id: String { plaza.plazaId }

    var isClosedEntry: Bool { plaza.system == "closed_entry" }
    /// A fare to show and say: known, and not the "pay at the exit" entry of a closed system.
    var fare: Double? { isClosedEntry ? nil : plaza.fareMyr }

    /// "Sungai Besi" from "Plaza Tol Sungai Besi" / "Sungai Besi Toll Plaza".
    var shortName: String { TollText.shortName(plaza.name) }
}

/// Which plaza the banner shows, when to speak, and the trip's running total. Pure, so it is unit-testable.
struct TollTracker: Sendable {
    /// Banner and voice this far ahead…
    static let showWithinM = 1000.0
    /// …or this far below `slowKmh`.
    static let showWithinSlowM = 500.0
    static let slowKmh = 60.0
    /// The banner stays this long after passing the plaza.
    static let hideAfterPassingS: TimeInterval = 10
    /// Plazas projected from lat/lng must be this close to the route to count.
    static let maxProjectionM = 150.0

    let tolls: [RouteToll]
    private(set) var announced: Set<String>
    private(set) var passed: Set<String>
    /// Fares of the plazas passed on this trip (kept across reroutes by the session).
    private(set) var paidMyr: Double
    /// The plaza on the banner and, once passed, when.
    private(set) var current: RouteToll?
    private(set) var currentPassedAt: Date?

    init(route: Route, geometry: RouteGeometry, announced: Set<String> = [], passed: Set<String> = [], paidMyr: Double = 0) {
        self.tolls = Self.place(route.tolls ?? [], on: geometry)
        self.announced = announced
        self.passed = passed
        self.paidMyr = paidMyr
    }

    /// Plazas in route order with their distance along it.
    static func place(_ plazas: [TollPlaza], on geometry: RouteGeometry) -> [RouteToll] {
        plazas.compactMap { p -> RouteToll? in
            if let d = p.distanceAlongRouteM { return RouteToll(plaza: p, alongM: d) }
            guard let s = project(LatLng(lat: p.lat, lng: p.lng), on: geometry), s.distanceM <= maxProjectionM else { return nil }
            return RouteToll(plaza: p, alongM: s.alongM)
        }
        .sorted { $0.alongM < $1.alongM }
    }

    private static func project(_ p: LatLng, on g: RouteGeometry) -> (alongM: Double, distanceM: Double)? {
        let pts = g.points
        guard pts.count >= 2 else { return nil }
        var best: (Double, Double)?
        for i in 0..<(pts.count - 1) {
            let r = Geo.project(p, onto: pts[i], pts[i + 1])
            if best == nil || r.distanceM < best!.1 {
                best = (g.cumulative[i] + (g.cumulative[i + 1] - g.cumulative[i]) * r.t, r.distanceM)
            }
        }
        return best.map { (alongM: $0.0, distanceM: $0.1) }
    }

    static func showWithin(speedKmh: Double) -> Double { speedKmh < slowKmh ? showWithinSlowM : showWithinM }

    /// Advances to `alongM`. Returns the plaza to announce now (once per plaza), if any.
    mutating func update(alongM: Double, speedKmh: Double, now: Date) -> RouteToll? {
        for t in tolls where t.alongM <= alongM && !passed.contains(t.id) {
            passed.insert(t.id)
            paidMyr += t.plaza.fareMyr ?? 0
            if current?.id == t.id { currentPassedAt = now }
        }
        // Once on the banner a plaza stays until passed (slowing down must not make it flicker).
        if let c = current, !passed.contains(c.id) { return nil }
        let within = Self.showWithin(speedKmh: speedKmh)
        if let next = tolls.first(where: { !passed.contains($0.id) && $0.alongM > alongM }), next.alongM - alongM <= within {
            current = next
            currentPassedAt = nil
            return announced.insert(next.id).inserted ? next : nil
        }
        // A passed plaza stays on the banner for a few seconds (unless the next one is already in range, above).
        if current != nil, let at = currentPassedAt, now.timeIntervalSince(at) < Self.hideAfterPassingS { return nil }
        current = nil
        currentPassedAt = nil
        return nil
    }

    func distanceAhead(_ t: RouteToll, alongM: Double) -> Double { max(0, t.alongM - alongM) }
}

/// Trip bar: "Tolls so far RM x · estimate RM y".
struct TollTotals: Equatable, Sendable {
    var paidMyr: Double
    /// Whole trip: paid on earlier routes + this route's estimate.
    var estimateMyr: Double?
    var estimateComplete: Bool

    var text: String {
        let paid = TollBadge.myr(paidMyr)
        guard let estimateMyr else { return String(localized: "Tolls so far \(paid)") }
        let est = estimateComplete ? TollBadge.myr(estimateMyr) : String(localized: "from \(TollBadge.myr(estimateMyr))")
        return String(localized: "Tolls so far \(paid) · estimate \(est)")
    }
}

enum TollText {
    static func shortName(_ name: String) -> String {
        var s = name.trimmingCharacters(in: .whitespaces)
        for prefix in ["Plaza Tol ", "Toll Plaza ", "Plaza Tol", "Tol "] where s.lowercased().hasPrefix(prefix.lowercased()) {
            s = String(s.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
            break
        }
        for suffix in [" Toll Plaza", " Toll"] where s.lowercased().hasSuffix(suffix.lowercased()) {
            s = String(s.dropLast(suffix.count)).trimmingCharacters(in: .whitespaces)
            break
        }
        return s.isEmpty ? name : s
    }

    /// Banner title: "Sungai Besi toll" / "Tol Sungai Besi".
    static func title(_ t: RouteToll) -> String { String(localized: "\(t.shortName) toll") }

    /// Banner detail after the distance: the fare case (docs/driving.md §1 table).
    static func fareLine(_ t: RouteToll) -> String? {
        if t.isClosedEntry { return String(localized: "Toll entry · pay at the exit") }
        if t.plaza.fareMyr == nil { return String(localized: "Toll ahead · fare unknown") }
        return nil
    }

    /// CarPlay / Android Auto alert subtitle: "900 m · RM 2.10".
    static func carSubtitle(_ t: RouteToll, distanceM: Double) -> String {
        let d = ManeuverFormatter.distance(distanceM)
        if let fare = t.fare { return "\(d) · \(TollBadge.myr(fare))" }
        return "\(d) · \(fareLine(t) ?? "")"
    }
}

/// What the voice says for a plaza ahead, in the voice's language ("en" / "ms").
enum TollSpeech {
    static func text(for t: RouteToll, language: String) -> String {
        let name = t.shortName
        let ms = language.hasPrefix("ms")
        if t.isClosedEntry { return ms ? "Tol masuk \(name) di hadapan." : "\(name) toll entry ahead." }
        guard let fare = t.plaza.fareMyr, fare > 0 else { return ms ? "Tol \(name) di hadapan." : "\(name) toll ahead." }
        return ms ? "Tol \(name) di hadapan, \(MoneyWords.malay(fare))." : "\(name) toll ahead, \(MoneyWords.english(fare))."
    }
}

/// Ringgit amounts as words for speech: "two ringgit ten" / "dua ringgit sepuluh sen".
enum MoneyWords {
    static func split(_ v: Double) -> (ringgit: Int, sen: Int) {
        let cents = Int((v * 100).rounded())
        return (cents / 100, cents % 100)
    }

    static func english(_ v: Double) -> String {
        let (rm, sen) = split(v)
        if rm == 0 { return "\(englishNumber(sen)) sen" }
        if sen == 0 { return "\(englishNumber(rm)) ringgit" }
        return "\(englishNumber(rm)) ringgit \(englishNumber(sen))"
    }

    static func malay(_ v: Double) -> String {
        let (rm, sen) = split(v)
        if rm == 0 { return "\(malayNumber(sen)) sen" }
        if sen == 0 { return "\(malayNumber(rm)) ringgit" }
        return "\(malayNumber(rm)) ringgit \(malayNumber(sen)) sen"
    }

    private static let enOnes = ["zero", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten", "eleven",
                                 "twelve", "thirteen", "fourteen", "fifteen", "sixteen", "seventeen", "eighteen", "nineteen"]
    private static let enTens = ["", "", "twenty", "thirty", "forty", "fifty", "sixty", "seventy", "eighty", "ninety"]

    static func englishNumber(_ n: Int) -> String {
        if n < 20 { return enOnes[max(0, n)] }
        if n < 100 { return n % 10 == 0 ? enTens[n / 10] : "\(enTens[n / 10])-\(enOnes[n % 10])" }
        if n < 1000 {
            let rest = n % 100
            return rest == 0 ? "\(enOnes[n / 100]) hundred" : "\(enOnes[n / 100]) hundred and \(englishNumber(rest))"
        }
        return String(n)
    }

    private static let msOnes = ["kosong", "satu", "dua", "tiga", "empat", "lima", "enam", "tujuh", "lapan", "sembilan"]

    static func malayNumber(_ n: Int) -> String {
        switch n {
        case ..<10: return msOnes[max(0, n)]
        case 10: return "sepuluh"
        case 11: return "sebelas"
        case 12..<20: return "\(msOnes[n - 10]) belas"
        case 20..<100: return n % 10 == 0 ? "\(msOnes[n / 10]) puluh" : "\(msOnes[n / 10]) puluh \(msOnes[n % 10])"
        case 100..<1000:
            let head = n / 100 == 1 ? "seratus" : "\(msOnes[n / 100]) ratus"
            return n % 100 == 0 ? head : "\(head) \(malayNumber(n % 100))"
        default: return String(n)
        }
    }
}
