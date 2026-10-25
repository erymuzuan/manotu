import AVFoundation
import Foundation

enum SoundMode: String, CaseIterable, Sendable {
    case on, alertsOnly, off

    var next: SoundMode {
        switch self {
        case .on: .alertsOnly
        case .alertsOnly: .off
        case .off: .on
        }
    }

    var systemImage: String {
        switch self {
        case .on: "speaker.wave.2.fill"
        case .alertsOnly: "exclamationmark.bubble"
        case .off: "speaker.slash.fill"
        }
    }

    var title: LocalizedStringResource {
        switch self {
        case .on: "Sound on"
        case .alertsOnly: "Alerts only"
        case .off: "Sound off"
        }
    }

    /// Row title in the sound selector (board NavBunyi).
    var rowTitle: LocalizedStringResource {
        switch self {
        case .on: "Full sound"
        case .alertsOnly: "Alerts only"
        case .off: "Mute"
        }
    }

    var rowSubtitle: LocalizedStringResource {
        switch self {
        case .on: "Voice directions + alerts"
        case .alertsOnly: "Police, accidents, closed roads"
        case .off: "No sound"
        }
    }

    /// 2 s toast and the VoiceOver announcement after a change.
    var changedMessage: LocalizedStringResource {
        switch self {
        case .on: "Full sound · voice directions and alerts"
        case .alertsOnly: "Alerts only · voice directions off"
        case .off: "Mute · no sound"
        }
    }

    var flatIcon: FlatIcon {
        switch self {
        case .on: .soundOn
        case .alertsOnly: .soundAlerts
        case .off: .soundOff
        }
    }

    /// Persisted value (same names as Android's SoundMode: ON / ALERTS_ONLY / OFF).
    var storageValue: String {
        switch self {
        case .on: "on"
        case .alertsOnly: "alerts_only"
        case .off: "off"
        }
    }

    init?(storageValue: String?) {
        switch storageValue {
        case "on": self = .on
        case "alerts_only": self = .alertsOnly
        case "off": self = .off
        default: return nil
        }
    }

    /// Long-press on the sound button: straight to Mute, or back to the mode before it.
    static func quickMute(current: SoundMode, last: SoundMode) -> (mode: SoundMode, last: SoundMode) {
        current == .off ? (last == .off ? .on : last, .off) : (.off, current)
    }
}

/// Spoken guidance via AVSpeechSynthesizer, in the app language (en / ms), ducking other audio.
///
/// One voice for the whole app: the phone's NavigationSession owns it and the CarPlay scene never speaks, so with
/// both scenes active a prompt is said once (through the car's speakers when CarPlay is connected). Other audio is
/// ducked only while a prompt plays (the session is released afterwards), and nothing is said during an audio
/// interruption such as a phone call; prompts missed then are not replayed afterwards.
@MainActor
final class VoiceGuide {
    var mode: SoundMode = .on
    /// App voice volume (0…1, Settings in the sound selector), applied to each utterance; the system volume is separate.
    var volume: Float = 1
    /// Tests: called for every prompt actually handed to the synthesizer.
    var onSpeak: ((String, Kind) -> Void)?
    /// Tests: false keeps the synthesizer and the audio session untouched.
    var usesAudio = true
    /// A phone call or another app took the audio (AVAudioSession interruption).
    private(set) var isInterrupted = false

    nonisolated static let category: AVAudioSession.Category = .playback
    nonisolated static let audioMode: AVAudioSession.Mode = .voicePrompt
    nonisolated static let options: AVAudioSession.CategoryOptions = [.duckOthers, .interruptSpokenAudioAndMixWithOthers]

    private let synth = AVSpeechSynthesizer()
    private let finish = SpeechFinish()
    private var interruptionObserver: NSObjectProtocol?

    init() {
        synth.delegate = finish
        interruptionObserver = NotificationCenter.default.addObserver(forName: AVAudioSession.interruptionNotification, object: nil,
                                                                      queue: .main) { [weak self] note in
            let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            let began = raw.flatMap(AVAudioSession.InterruptionType.init(rawValue:)) == .began
            MainActor.assumeIsolated { self?.handleInterruption(began: began) }
        }
    }

    static var languageCode: String {
        let lang = Bundle.main.preferredLocalizations.first ?? Locale.current.language.languageCode?.identifier ?? "en"
        return lang.hasPrefix("ms") ? "ms" : "en"
    }

    private lazy var voice: AVSpeechSynthesisVoice? = {
        if Self.languageCode == "ms" {
            // Malay voices aren't installed on every device; Indonesian is the closest fallback.
            return AVSpeechSynthesisVoice(language: "ms-MY") ?? AVSpeechSynthesisVoice(language: "id-ID") ?? AVSpeechSynthesisVoice(language: "en-GB")
        }
        return AVSpeechSynthesisVoice(language: "en-GB") ?? AVSpeechSynthesisVoice(language: "en-US")
    }()

    enum Kind { case guidance, alert }

    /// Whether a prompt of this kind is said in this sound mode (Alerts only keeps alerts such as tolls; Mute nothing).
    nonisolated static func shouldSpeak(mode: SoundMode, kind: Kind, interrupted: Bool) -> Bool {
        if interrupted { return false }
        switch (mode, kind) {
        case (.off, _), (.alertsOnly, .guidance): return false
        default: return true
        }
    }

    func speak(_ text: String, kind: Kind = .guidance) {
        guard Self.shouldSpeak(mode: mode, kind: kind, interrupted: isInterrupted) else { return }
        onSpeak?(text, kind)
        guard usesAudio else { return }
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(Self.category, mode: Self.audioMode, options: Self.options)
        try? session.setActive(true)
        let u = AVSpeechUtterance(string: text)
        u.voice = voice
        u.rate = AVSpeechUtteranceDefaultSpeechRate * 1.02
        u.volume = Self.utteranceVolume(volume)
        if synth.isSpeaking { synth.stopSpeaking(at: .word) }
        synth.speak(u)
    }

    /// A call (or Siri, another navigation app…) began: stop at once and stay quiet until it ends.
    func handleInterruption(began: Bool) {
        isInterrupted = began
        if began, usesAudio { synth.stopSpeaking(at: .immediate) }
    }

    /// Clamped to 0…1; never fully silent while sound is on (Mute is the way to silence).
    nonisolated static func utteranceVolume(_ v: Float) -> Float { min(1, max(0.1, v)) }

    func stop() {
        guard usesAudio else { return }
        synth.stopSpeaking(at: .immediate)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}

/// Releases the audio session when a prompt ends, so music and podcasts come back to full volume between prompts.
private final class SpeechFinish: NSObject, AVSpeechSynthesizerDelegate {
    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        guard !synthesizer.isSpeaking else { return }
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}

/// Decides which prompt to speak for the upcoming maneuver. Pure, so it is unit-testable.
struct VoiceAnnouncer: Sendable {
    enum Stage: Int, Sendable { case early, near }
    private var spoken: Set<String> = []
    var mode: Vehicle = .car

    init(mode: Vehicle = .car) { self.mode = mode }

    /// Early prompt distance grows with speed (highways); short for walking and cycling.
    static func earlyDistance(speedKmh: Double, mode: Vehicle = .car) -> Double {
        switch mode {
        case .walk: 120
        case .bicycle: 250
        default: speedKmh > 75 ? 1500 : 600
        }
    }

    static func nearDistance(speedKmh: Double, mode: Vehicle = .car) -> Double {
        switch mode {
        case .walk: 20
        case .bicycle: 40
        default: max(80, speedKmh / 3.6 * 7)
        }
    }

    mutating func prompt(maneuverIndex: Int, maneuver: Maneuver, distanceM: Double, speedKmh: Double, stopName: String? = nil) -> String? {
        let early = Self.earlyDistance(speedKmh: speedKmh, mode: mode)
        let near = Self.nearDistance(speedKmh: speedKmh, mode: mode)
        if distanceM <= near {
            guard spoken.insert("\(maneuverIndex)-near").inserted else { return nil }
            spoken.insert("\(maneuverIndex)-early")
            return ManeuverFormatter.voicePrompt(for: maneuver, distanceM: nil, mode: mode, stopName: stopName)
        }
        if distanceM <= early, distanceM > near + min(100, early / 4) {
            guard spoken.insert("\(maneuverIndex)-early").inserted else { return nil }
            // Our own localized phrasing (en/ms) rather than the backend's English verbalPre.
            return ManeuverFormatter.voicePrompt(for: maneuver, distanceM: distanceM, mode: mode, stopName: stopName)
        }
        return nil
    }

    mutating func reset() { spoken.removeAll() }
}
