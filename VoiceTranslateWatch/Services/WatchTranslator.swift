import AVFoundation
import Foundation
import Observation
import WatchKit

/// Watch translator: uses system dictation for ASR, sends text to phone for translation.
/// TTS plays directly on watch.
@Observable
@MainActor
final class WatchTranslator {
    var messages: [ConversationMessage] = []
    var isProcessing = false
    var errorMessage: String?
    var sourceLanguage: SupportedLanguage = .chinese
    var targetLanguage: SupportedLanguage = .english

    private let synthesizer = AVSpeechSynthesizer()

    init() {
        let defaults = UserDefaults.standard
        if let src = defaults.string(forKey: "watchSourceLang"), let l = SupportedLanguage(rawValue: src) {
            sourceLanguage = l
        }
        if let tgt = defaults.string(forKey: "watchTargetLang"), let l = SupportedLanguage(rawValue: tgt) {
            targetLanguage = l
        }
    }

    func setSourceLanguage(_ lang: SupportedLanguage) {
        guard lang != sourceLanguage else { return }
        sourceLanguage = lang
        UserDefaults.standard.set(lang.rawValue, forKey: "watchSourceLang")
    }

    func setTargetLanguage(_ lang: SupportedLanguage) {
        guard lang != targetLanguage else { return }
        targetLanguage = lang
        UserDefaults.standard.set(lang.rawValue, forKey: "watchTargetLang")
    }

    /// Called when translation result arrives from phone
    func didReceiveTranslation(_ message: ConversationMessage) {
        messages.append(message)
        isProcessing = false
        errorMessage = nil
        speak(message.translatedText, language: message.targetLanguage)
        WKInterfaceDevice.current().play(.success)
    }

    func translationFailed(_ error: String) {
        isProcessing = false
        errorMessage = error
    }

    func replay(_ message: ConversationMessage) {
        speak(message.translatedText, language: message.targetLanguage)
    }

    // MARK: - TTS

    private func speak(_ text: String, language: SupportedLanguage) {
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: language.localeIdentifier)

        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
        try? AVAudioSession.sharedInstance().setActive(true)

        if synthesizer.isSpeaking {
            synthesizer.stopSpeaking(at: .immediate)
        }
        synthesizer.speak(utterance)
    }
}
