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
    var loadedEngine: ASREngine?
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

    var activeLanguages: [SupportedLanguage] = SupportedLanguage.defaultActiveLanguages {
        didSet {
            if !activeLanguages.contains(sourceLanguage) {
                sourceLanguage = activeLanguages.first ?? .english
            }
            if !activeLanguages.contains(targetLanguage) {
                targetLanguage = activeLanguages.last ?? .english
            }
        }
    }

    let downloader = ModelDownloader()
    let phoneConnectivity = PhoneConnectivityService()
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
        print("[VM] Switching engine: \(currentEngine.displayName) → \(engine.displayName)")
        currentEngine = engine
        asrService = nil
        loadedEngine = nil
        errorMessage = nil
    }

    func startListening() {
        guard !isRecording, !isProcessing, !isLoadingModel else { return }

        // Check download state for all downloadable models
        if currentEngine.requiresModelDownload {
            let state = downloader.state(for: currentEngine)
            if state != .downloaded {
                // WhisperKit models download on first load, that's ok
                if !currentEngine.isWhisperKit {
                    errorMessage = "Model not downloaded yet"
                    return
                }
            }
        }

        errorMessage = nil
        isRecording = true

        Task {
            do {
                let service = try await getOrCreateASR()
                try await service.startRecording(language: sourceLanguage)
                print("[VM] Recording started with \(currentEngine.displayName)")
            } catch {
                isRecording = false
                errorMessage = "[\(currentEngine.displayName)] \(error.localizedDescription)"
                print("[VM] startListening failed: \(error)")
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
                    errorMessage = "No ASR service loaded"
                    return
                }
                let transcript = try await service.stopRecording()
                print("[VM] Transcript (\(loadedEngine?.displayName ?? "?")): \(transcript)")

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

                if let peer = peerSession, peer.connectionState == .connected {
                    try? peer.send(PeerMessage(from: message))
                }

                await tts.speak(text: response.targetText, language: targetLanguage)
            } catch {
                isProcessing = false
                errorMessage = error.localizedDescription
                print("[VM] stopAndTranslate failed: \(error)")
            }
        }
    }

    func didFailTranslation(_ error: Error) {
        errorMessage = error.localizedDescription
        isProcessing = false
    }

    // MARK: - Watch Audio

    func processWatchAudio(
        samples: [Float],
        sourceLanguage src: SupportedLanguage,
        targetLanguage tgt: SupportedLanguage
    ) async throws -> ConversationMessage {
        let service = try await getOrCreateASR()
        let transcript = try await service.transcribe(samples: samples, language: src)
        guard !transcript.isEmpty else {
            throw NSError(domain: "VoiceTranslate", code: 0, userInfo: [NSLocalizedDescriptionKey: "No speech detected"])
        }

        guard let session = translationSession else {
            throw NSError(domain: "VoiceTranslate", code: 1, userInfo: [NSLocalizedDescriptionKey: "Translation not ready"])
        }

        nonisolated(unsafe) let s = session
        let response = try await s.translate(transcript)

        let message = ConversationMessage(
            originalText: transcript,
            translatedText: response.targetText,
            sourceLanguage: src,
            targetLanguage: tgt
        )
        messages.append(message)

        if let peer = peerSession, peer.connectionState == .connected {
            try? peer.send(PeerMessage(from: message))
        }

        await tts.speak(text: response.targetText, language: tgt)
        return message
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
        // Apple Speech: always create fresh (audio engine state invalidates between sessions)
        if currentEngine == .appleSpeech {
            print("[VM] Creating fresh AppleSpeechASR")
            let service = AppleSpeechASR()
            asrService = service
            loadedEngine = .appleSpeech
            return service
        }

        // Reuse existing service if already loaded for this engine
        if let existing = asrService, loadedEngine == currentEngine {
            print("[VM] Reusing existing \(currentEngine.displayName)")
            return existing
        }

        // Need to load a new model
        asrService = nil
        loadedEngine = nil
        isLoadingModel = true
        defer { isLoadingModel = false }

        print("[VM] Loading \(currentEngine.displayName)...")

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
        print("[VM] ✓ Loaded \(currentEngine.displayName)")
        return service
    }
}
