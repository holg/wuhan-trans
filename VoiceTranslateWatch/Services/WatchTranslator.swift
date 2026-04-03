import AVFoundation
import Foundation
import Observation
import WatchKit

@Observable
@MainActor
final class WatchTranslator {
    var messages: [ConversationMessage] = []
    var isRecording = false
    var isProcessing = false
    var errorMessage: String?
    var sourceLanguage: SupportedLanguage = .chinese
    var targetLanguage: SupportedLanguage = .english

    private var audioRecorder: AVAudioRecorder?
    private let recordingURL: URL
    private let synthesizer = AVSpeechSynthesizer()

    init() {
        recordingURL = FileManager.default.temporaryDirectory.appending(path: "watch_rec.m4a")
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

    // MARK: - Recording

    func startRecording() {
        guard !isRecording, !isProcessing else { return }
        WatchCrashLog.log("startRecording")
        errorMessage = nil

        do {
            try? FileManager.default.removeItem(at: recordingURL)
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.record, mode: .default)
            try session.setActive(true)

            let settings: [String: Any] = [
                AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
                AVSampleRateKey: 16000,
                AVNumberOfChannelsKey: 1,
                AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
            ]

            let recorder = try AVAudioRecorder(url: recordingURL, settings: settings)
            recorder.record(forDuration: 30)
            audioRecorder = recorder
            isRecording = true
        } catch {
            errorMessage = error.localizedDescription
            WatchCrashLog.log("startRecording FAILED: \(error)")
        }
    }

    func stopAndSend(via connectivity: WatchConnectivityClient) {
        guard isRecording else { return }
        WatchCrashLog.log("stopAndSend")

        audioRecorder?.stop()
        audioRecorder = nil
        isRecording = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)

        guard FileManager.default.fileExists(atPath: recordingURL.path()) else {
            errorMessage = "No audio captured"
            return
        }

        let size = (try? FileManager.default.attributesOfItem(atPath: recordingURL.path())[.size] as? Int) ?? 0
        WatchCrashLog.log("audio file: \(size / 1024) KB")

        guard size > 0 else {
            errorMessage = "Empty recording"
            return
        }

        isProcessing = true
        connectivity.sendAudioFile(
            recordingURL,
            source: sourceLanguage,
            target: targetLanguage
        )
    }

    // MARK: - Receive translation from phone

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
        if synthesizer.isSpeaking { synthesizer.stopSpeaking(at: .immediate) }
        synthesizer.speak(utterance)
    }
}
