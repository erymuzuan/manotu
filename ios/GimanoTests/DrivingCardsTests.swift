import Foundation
import Testing
@testable import Gimano

/// Driving: confirm card + sound selector (boards NavFlow / NavSahkan / NavBunyi / NavBunyiKeadaan).
@Suite("Driving cards")
struct DrivingCardsTests {
    @Test("Confirm card: 10 s countdown ring, then it closes with no answer")
    func countdown() {
        #expect(ConfirmCountdown.seconds == 10)
        #expect(ConfirmCountdown.remaining(elapsed: 0) == 10)
        #expect(ConfirmCountdown.remaining(elapsed: 2.1) == 8)
        #expect(ConfirmCountdown.remaining(elapsed: 10) == 0)
        #expect(ConfirmCountdown.remaining(elapsed: 15) == 0)
        #expect(ConfirmCountdown.progress(elapsed: 0) == 1)
        #expect(ConfirmCountdown.progress(elapsed: 5) == 0.5)
        #expect(ConfirmCountdown.progress(elapsed: 12) == 0)
    }

    @Test("Confirm card: 84 pt buttons, full labels on at most 2 lines (the font shrinks first)")
    func labelRules() {
        #expect(ConfirmCountdown.buttonHeight == 84)
        #expect(ConfirmCountdown.maxLabelLines == 2)
        #expect(ConfirmCountdown.minLabelScale < 1 && ConfirmCountdown.minLabelScale >= 0.5)
    }

    @Test("Still there? card: kind · subtype · street · age, or the distance ahead without a street")
    func alertSubtitle() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        var r = Report(id: "r", type: .police, subtype: "visible", lat: 3.1, lng: 101.6, heading: nil, street: "Jalan SS 2/3",
                       reportedBy: nil, createdAt: now.addingTimeInterval(-300), expiresAt: now.addingTimeInterval(600),
                       confirmations: 1, thanks: 0)
        let a = AlertConfirmText.subtitle(r, distanceM: 350, now: now).components(separatedBy: " · ")
        #expect(a.count == 4)
        #expect(a[0] == String(localized: ReportType.police.title))
        #expect(a[2] == "Jalan SS 2/3")
        #expect(!a.contains { $0.contains("350") }, "the street wins over the distance")
        r.street = nil
        r.subtype = nil
        let b = AlertConfirmText.subtitle(r, distanceM: 350, now: now).components(separatedBy: " · ")
        #expect(b.count == 3)
        #expect(b[1].contains("350"))
        // A clock a little behind the server never says "in 5 minutes".
        r.createdAt = now.addingTimeInterval(30)
        #expect(!AlertConfirmText.subtitle(r, distanceM: nil, now: now).lowercased().contains("in "))
    }

    @Test("Picking Mute in the panel remembers the mode before it; picking another mode keeps it")
    func pick() {
        let a = SoundMode.pick(.off, current: .alertsOnly, last: .on)
        #expect(a.mode == .off && a.last == .alertsOnly)
        // Then a long-press goes back to Alerts only.
        #expect(SoundMode.quickMute(current: a.mode, last: a.last).mode == .alertsOnly)
        let b = SoundMode.pick(.on, current: .alertsOnly, last: .alertsOnly)
        #expect(b.mode == .on && b.last == .alertsOnly)
        let c = SoundMode.pick(.off, current: .off, last: .on)
        #expect(c.mode == .off && c.last == .on, "muting again keeps the earlier mode")
    }

    @Test("Sound modes are stored with Android's names and come back the same")
    func storage() {
        #expect(SoundMode.allCases.map(\.storageValue) == ["on", "alerts_only", "off"])
        for m in SoundMode.allCases { #expect(SoundMode(storageValue: m.storageValue) == m) }
        #expect(SoundMode(storageValue: nil) == nil)
        #expect(SoundMode(storageValue: "loud") == nil)
    }

    @Test("Long-press: mute at once, then back to the mode before")
    func quickMute() {
        let a = SoundMode.quickMute(current: .alertsOnly, last: .on)
        #expect(a.mode == .off && a.last == .alertsOnly)
        let b = SoundMode.quickMute(current: .off, last: a.last)
        #expect(b.mode == .alertsOnly)
        // Muted with no earlier mode: back to Full sound.
        #expect(SoundMode.quickMute(current: .off, last: .off).mode == .on)
    }

    @Test("Each mode has its own icon; the voice volume is clamped and never silent")
    func iconsAndVolume() {
        #expect(Set(SoundMode.allCases.map(\.flatIcon)).count == 3)
        for icon in [FlatIcon.soundOn, .soundAlerts, .soundOff] {
            #expect(!SVGPath.parse(icon.paths.base).fill.isEmpty && !SVGPath.parse(icon.paths.detail).fill.isEmpty)
        }
        #expect(VoiceGuide.utteranceVolume(0.7) == 0.7)
        #expect(VoiceGuide.utteranceVolume(2) == 1)
        #expect(VoiceGuide.utteranceVolume(0) == 0.1)
    }

    @Test("The confirm card's street comes from the snapped segment the server sends")
    func streetFromSegment() throws {
        let json = #"{"id":"i","kind":"turn_not_allowed","state":"confirmed","lat":3.1,"lng":101.6,"segment":{"wayId":7,"seq":1,"name":"Jalan SS 2/3","direction":"both"}}"#
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        let issue = try d.decode(Issue.self, from: Data(json.utf8))
        #expect(issue.streetName == "Jalan SS 2/3")
    }
}
