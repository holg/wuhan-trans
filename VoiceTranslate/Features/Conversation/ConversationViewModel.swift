import Foundation
import Observation
import Translation

@Observable
@MainActor
final class ConversationViewModel {
    var messages: [ConversationMessage] = []
    var isProcessing = false
    var isRecording = false
    var isLoadingModel = false
    var currentEngine: ASREngine = ASREngine.platformDefault
    var loadedEngine: ASREngine?  // Which engine is actually loaded in memory
    var errorMessage: String?

    var translationConfig: TranslationSession.Configuration?
    var translationSession: TranslationSession?

    var sourceLanguage: SupportedLanguage = .chinese {
        didSet {
            if oldValue != sourceLanguage { invalidateTranslation() }
        }
    }
    var targetLanguage: SupportedLanguage = .english {
        didSet {
            if oldValue != targetLanguage { invalidateTranslation() }
        }
    }

    /// The 3 languages shown in the main view quick selector
    var activeLanguages: [SupportedLanguage] = SupportedLanguage.defaultActiveLanguages {
        didSet {
            // Ensure source/target are still in the active set
            if !activeLanguages.contains(sourceLanguage) {
                sourceLanguage = activeLanguages.first ?? .english
            }
            if !activeLanguages.contains(targetLanguage) {
                targetLanguage = activeLanguages.last ?? .english
            }
        }
    }

    let downloader = ModelDownloader()
    var peerSession: PeerSessionManager?

    private var asrService: (any ASRService)?
    private let tts = SpeechSynthesizer()

    func ensureTranslationConfig() {
        guard translationConfig == nil else { return }
        translationConfig = TranslationSession.Configuration(
            source: Locale.Language(identifier: sourceLanguage.translationLanguageCode),
            target: Locale.Language(identifier: targetLanguage.translationLanguageCode)
        )
    }

    func setTranslationSession(_ session: TranslationSession) {
        translationSession = session
    }

    func setEngine(_ engine: ASREngine) {
        guard engine != currentEngine else { return }
        currentEngine = engine
        asrService = nil
        loadedEngine = nil
        errorMessage = nil
    }

    func startListening() {
        guard !isRecording, !isProcessing, !isLoadingModel else { return }

        // For non-WhisperKit downloadable models, check download state
        if currentEngine.requiresModelDownload && !currentEngine.isWhisperKit {
            guard downloader.state(for: currentEngine) == .downloaded else {
                errorMessage = "Model not downloaded yet"
                return
            }
        }

        isRecording = true
        errorMessage = nil

        Task {
            do {
                let service = try await getOrCreateASR()
                try await service.startRecording(language: sourceLanguage)
            } catch {
                isRecording = false
                errorMessage = error.localizedDescription
            }
        }
    }

    func stopAndTranslate() {
        guard isRecording else { return }
        isRecording = false
        isProcessing = true

        Task {
            do {
                guard let service = asrService else {
                    isProcessing = false
                    return
                }
                let transcript = try await service.stopRecording()
                guard !transcript.isEmpty else {
                    isProcessing = false
                    return
                }

                guard let session = translationSession else {
                    isProcessing = false
                    errorMessage = "Translation not ready"
                    return
                }

                nonisolated(unsafe) let s = session
                let response = try await s.translate(transcript)

                let message = ConversationMessage(
                    originalText: transcript,
                    translatedText: response.targetText,
                    sourceLanguage: sourceLanguage,
                    targetLanguage: targetLanguage
                )
                messages.append(message)
                isProcessing = false

                // Send to peer if connected
                if let peer = peerSession, peer.connectionState == .connected {
                    try? peer.send(PeerMessage(from: message))
                }

                await tts.speak(text: response.targetText, language: targetLanguage)
            } catch {
                isProcessing = false
                errorMessage = error.localizedDescription
            }
        }
    }

    func didFailTranslation(_ error: Error) {
        errorMessage = error.localizedDescription
        isProcessing = false
    }

    // MARK: - Peer

    func configurePeerSession(_ session: PeerSessionManager) {
        self.peerSession = session
        session.onMessageReceived = { [weak self] msg in
            self?.receiveRemoteMessage(msg)
        }
    }

    private func receiveRemoteMessage(_ peerMessage: PeerMessage) {
        let message = ConversationMessage(peerMessage: peerMessage)
        messages.append(message)
        Task {
            await tts.speak(text: peerMessage.translatedText, language: peerMessage.targetLanguage)
        }
    }

    private func invalidateTranslation() {
        translationSession = nil
        translationConfig = TranslationSession.Configuration(
            source: Locale.Language(identifier: sourceLanguage.translationLanguageCode),
            target: Locale.Language(identifier: targetLanguage.translationLanguageCode)
        )
    }

    private func getOrCreateASR() async throws -> any ASRService {
        // Apple Speech: always create fresh
        if currentEngine == .appleSpeech {
            let service = AppleSpeechASR()
            asrService = service
            loadedEngine = .appleSpeech
            return service
        }

        // Reuse existing service if available
        if let existing = asrService { return existing }

        isLoadingModel = true
        defer { isLoadingModel = false }

        let service: any ASRService
        switch currentEngine {
        case .appleSpeech:
            service = AppleSpeechASR()
        case .cohereTranscribe:
            let cohere = CohereASR(modelDirectory: downloader.modelDirectory(for: currentEngine))
            try await cohere.loadModel()
            service = cohere
        case .whisperKitMedium, .whisperKitLargeV3, .whisperKitLargeV3Turbo, .whisperKitBelleLargeZh:
            let whisper = WhisperKitASR(engine: currentEngine)
            try await whisper.loadModel()
            service = whisper
        }
        asrService = service
        loadedEngine = currentEngine
        return service
    }
}
