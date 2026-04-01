import AVFoundation

final class SpeechSynthesizer: NSObject, @unchecked Sendable {
    private let synthesizer = AVSpeechSynthesizer()

    func speak(text: String, language: SupportedLanguage) async {
        #if os(iOS)
        // Use playAndRecord so we don't break the mic for the next recording
        try? AVAudioSession.sharedInstance().setCategory(
            .playAndRecord, mode: .default, options: [.defaultToSpeaker]
        )
        try? AVAudioSession.sharedInstance().setActive(true)
        #endif

        // Stop any ongoing speech first
        if synthesizer.isSpeaking {
            synthesizer.stopSpeaking(at: .immediate)
        }

        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: language.localeIdentifier)
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate

        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            let delegate = SpeechDelegate(continuation: cont)
            objc_setAssociatedObject(
                self.synthesizer, "delegate", delegate, .OBJC_ASSOCIATION_RETAIN
            )
            self.synthesizer.delegate = delegate
            self.synthesizer.speak(utterance)
        }
    }
}

private final class SpeechDelegate: NSObject, AVSpeechSynthesizerDelegate, @unchecked Sendable {
    private var continuation: CheckedContinuation<Void, Never>?

    init(continuation: CheckedContinuation<Void, Never>) {
        self.continuation = continuation
    }

    func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        didFinish utterance: AVSpeechUtterance
    ) {
        continuation?.resume()
        continuation = nil
    }

    func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        didCancel utterance: AVSpeechUtterance
    ) {
        continuation?.resume()
        continuation = nil
    }
}
