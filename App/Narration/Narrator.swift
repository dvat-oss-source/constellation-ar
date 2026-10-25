import AVFoundation
import Observation

/// Reads the card aloud with the best installed voice for the current English locale (premium > enhanced > default).
@MainActor
@Observable
final class Narrator: NSObject {
    private static let mutedKey = "narrationMuted"

    var isMuted: Bool {
        didSet {
            UserDefaults.standard.set(isMuted, forKey: Self.mutedKey)
            if isMuted { stop() }
        }
    }
    private(set) var isSpeaking = false
    private(set) var voiceDescription: String?

    @ObservationIgnored private let synthesizer = AVSpeechSynthesizer()

    override init() {
        isMuted = UserDefaults.standard.bool(forKey: Self.mutedKey)
        super.init()
        synthesizer.delegate = self
    }

    static func bestVoice(among voices: [AVSpeechSynthesisVoice] = AVSpeechSynthesisVoice.speechVoices(),
                          preferredLanguage: String = AVSpeechSynthesisVoice.currentLanguageCode()) -> AVSpeechSynthesisVoice? {
        let english = voices.filter { $0.language.hasPrefix("en") }
        func rank(_ voice: AVSpeechSynthesisVoice) -> (Int, Int) {
            let quality = switch voice.quality {
            case .premium: 3
            case .enhanced: 2
            default: 1
            }
            return (quality, voice.language == preferredLanguage ? 2 : (voice.language.hasPrefix(preferredLanguage.prefix(2)) ? 1 : 0))
        }
        return english.max { a, b in
            let (ra, rb) = (rank(a), rank(b))
            return ra.0 != rb.0 ? ra.0 < rb.0 : ra.1 < rb.1
        }
    }

    func speak(_ text: String) {
        guard !isMuted, !text.isEmpty else { return }
        stop()
        let utterance = AVSpeechUtterance(string: text)
        if let voice = Self.bestVoice() {
            utterance.voice = voice
            voiceDescription = voice.name
        }
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate * 0.95
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
        try? AVAudioSession.sharedInstance().setActive(true)
        synthesizer.speak(utterance)
    }

    func stop() {
        if synthesizer.isSpeaking { synthesizer.stopSpeaking(at: .immediate) }
    }
}

extension Narrator: AVSpeechSynthesizerDelegate {
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance) {
        Task { @MainActor in isSpeaking = true }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in isSpeaking = false }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in isSpeaking = false }
    }
}
