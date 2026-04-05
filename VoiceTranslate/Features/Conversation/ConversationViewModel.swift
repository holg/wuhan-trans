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
    var translationEngine: TranslationEngine = .apple {
        didSet {
            guard !isLoadingSettings, oldValue != translationEngine else { return }
            saveSettings()
        }
    }
    var errorMessage: String?

    var translationConfig: TranslationSession.Configuration?
    var translationSession: TranslationSession?
    private var nllbTranslator: NLLBTranslator?

    var sourceLanguage: SupportedLanguage = .chinese {
        didSet {
            guard !isLoadingSettings, oldValue != sourceLanguage else { return }
            invalidateTranslation()
            saveSettings()
            syncLanguagesToWatch()
        }
    }
    var targetLanguage: SupportedLanguage = .english {
        didSet {
            guard !isLoadingSettings, oldValue != targetLanguage else { return }
            invalidateTranslation()
            saveSettings()
            syncLanguagesToWatch()
        }
    }

    var activeLanguages: [SupportedLanguage] = SupportedLanguage.defaultActiveLanguages {
        didSet {
            guard !isLoadingSettings else { return }
            if !activeLanguages.contains(sourceLanguage) {
                sourceLanguage = activeLanguages.first ?? .english
            }
            if !activeLanguages.contains(targetLanguage) {
                targetLanguage = activeLanguages.last ?? .english
            }
            saveSettings()
        }
    }

    private var isLoadingSettings = false
    let downloader = ModelDownloader()

    init() {
        loadSettings()
    }
    let phoneConnectivity = PhoneConnectivityService()
    var peerSession: (any SessionTransport)?

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
        saveSettings()
    }

    func replayTranslation(_ message: ConversationMessage) {
        Task {
            await tts.speak(text: message.translatedText, language: message.targetLanguage)
        }
    }

    func translateTypedText(_ text: String) {
        guard !text.isEmpty, !isProcessing else { return }
        isProcessing = true
        errorMessage = nil

        Task {
            defer { isProcessing = false }
            do {
                let translated = try await translateText(text, from: sourceLanguage, to: targetLanguage)

                let message = ConversationMessage(
                    originalText: text,
                    translatedText: translated,
                    sourceLanguage: sourceLanguage,
                    targetLanguage: targetLanguage,
                    asrEngine: "typed",
                    translationEngine: translationEngine.displayName
                )
                messages.append(message)

                sendToPeer(message)

                await tts.speak(text: translated, language: targetLanguage)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
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

        isRecording = true

        Task {
            do {
                let service = try await getOrCreateASR()
                errorMessage = nil  // clear only after successful load
                try await service.startRecording(language: sourceLanguage)
                print("[VM] Recording started with \(currentEngine.displayName)")
            } catch {
                isRecording = false
                asrService = nil
                loadedEngine = nil
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

                let translated = try await translateText(transcript, from: sourceLanguage, to: targetLanguage)

                let message = ConversationMessage(
                    originalText: transcript,
                    translatedText: translated,
                    sourceLanguage: sourceLanguage,
                    targetLanguage: targetLanguage,
                    asrEngine: currentEngine.displayName,
                    translationEngine: translationEngine.displayName
                )
                messages.append(message)
                isProcessing = false

                sendToPeer(message)

                await tts.speak(text: translated, language: targetLanguage)
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

        let translated = try await translateText(transcript, from: src, to: tgt)

        let message = ConversationMessage(
            originalText: transcript,
            translatedText: translated,
            sourceLanguage: src,
            targetLanguage: tgt,
            asrEngine: currentEngine.displayName,
            translationEngine: translationEngine.displayName
        )
        messages.append(message)

        if let peer = peerSession, peer.connectionState == .connected {
            try? peer.send(PeerMessage(from: message))
        }

        await tts.speak(text: translated, language: tgt)
        return message
    }

    // MARK: - Peer

    private func sendToPeer(_ message: ConversationMessage) {
        guard let peer = peerSession, peer.connectionState == .connected else { return }
        if peer is RelaySessionManager {
            // Relay mode: send original text only, each receiver translates locally
            let deviceName = (peer as? RelaySessionManager)?.deviceName ?? ""
            try? peer.send(PeerMessage(originalText: message.originalText, sourceLanguage: message.sourceLanguage, senderName: deviceName))
        } else {
            // Local peer mode: send pre-translated
            try? peer.send(PeerMessage(from: message))
        }
    }

    func configurePeerSession(_ session: any SessionTransport) {
        self.peerSession = session
        session.onMessageReceived = { [weak self] msg in
            self?.receiveRemoteMessage(msg)
        }
    }

    private func receiveRemoteMessage(_ peerMessage: PeerMessage) {
        if peerMessage.needsTranslation {
            // Relay mode: translate locally into our target language
            Task {
                do {
                    let translated = try await translateText(peerMessage.originalText, from: peerMessage.sourceLanguage, to: targetLanguage)

                    let message = ConversationMessage(
                        originalText: peerMessage.originalText,
                        translatedText: translated,
                        sourceLanguage: peerMessage.sourceLanguage,
                        targetLanguage: targetLanguage,
                        isRemote: true,
                        asrEngine: "remote",
                        translationEngine: translationEngine.displayName
                    )
                    messages.append(message)
                    await tts.speak(text: translated, language: targetLanguage)
                } catch {
                    print("[VM] Remote translation failed: \(error)")
                }
            }
        } else {
            // Local peer mode: already translated
            let message = ConversationMessage(peerMessage: peerMessage)
            messages.append(message)
            Task {
                await tts.speak(text: peerMessage.translatedText, language: peerMessage.targetLanguage)
            }
        }
    }

    // MARK: - Persistence

    func loadSettings() {
        isLoadingSettings = true
        defer { isLoadingSettings = false }

        let defaults = UserDefaults.standard
        // Load active languages first (so source/target are valid in the set)
        if let data = defaults.data(forKey: "activeLanguages"),
           let langs = try? JSONDecoder().decode([SupportedLanguage].self, from: data),
           langs.count == 3 {
            activeLanguages = langs
        }
        if let src = defaults.string(forKey: "sourceLanguage"),
           let lang = SupportedLanguage(rawValue: src) {
            sourceLanguage = lang
        }
        if let tgt = defaults.string(forKey: "targetLanguage"),
           let lang = SupportedLanguage(rawValue: tgt) {
            targetLanguage = lang
        }
        if let eng = defaults.string(forKey: "currentEngine"),
           let engine = ASREngine(rawValue: eng) {
            currentEngine = engine
        }
        if let te = defaults.string(forKey: "translationEngine"),
           let engine = TranslationEngine(rawValue: te) {
            translationEngine = engine
        }
        print("[VM] Settings loaded: translation=\(translationEngine.displayName) \(sourceLanguage.flag)→\(targetLanguage.flag) slots=\(activeLanguages.map(\.flag)) engine=\(currentEngine.displayName)")
    }

    private func saveSettings() {
        let defaults = UserDefaults.standard
        defaults.set(sourceLanguage.rawValue, forKey: "sourceLanguage")
        defaults.set(targetLanguage.rawValue, forKey: "targetLanguage")
        if let data = try? JSONEncoder().encode(activeLanguages) {
            defaults.set(data, forKey: "activeLanguages")
        }
        defaults.set(currentEngine.rawValue, forKey: "currentEngine")
        defaults.set(translationEngine.rawValue, forKey: "translationEngine")
    }

    private func syncLanguagesToWatch() {
        phoneConnectivity.syncLanguages(source: sourceLanguage, target: targetLanguage)
    }

    /// Translate text using the selected translation engine
    func translateText(_ text: String, from source: SupportedLanguage, to target: SupportedLanguage) async throws -> String {
        switch translationEngine {
        case .apple:
            guard let session = translationSession else {
                throw NSError(domain: "VoiceTranslate", code: 0, userInfo: [NSLocalizedDescriptionKey: "Apple Translation not ready"])
            }
            nonisolated(unsafe) let s = session
            let response = try await s.translate(text)
            return response.targetText
        case .nllb:
            if nllbTranslator == nil || !nllbTranslator!.isLoaded {
                let dir = downloader.modelDirectory(for: TranslationEngine.nllb)
                let translator = NLLBTranslator(modelDirectory: dir)
                try await translator.loadModels()
                nllbTranslator = translator
            }
            return try await nllbTranslator!.translate(text: text, from: source, to: target)
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

        // Auto-switch: use SenseVoice for Chinese/Japanese/Korean when not using Apple Speech
        let useSenseVoice = currentEngine != .appleSpeech
            && SenseVoiceASR.supportedLanguages.contains(sourceLanguage)
            && sourceLanguage != .english  // SenseVoice supports English but Whisper is better for it

        let effectiveEngine = useSenseVoice ? "SenseVoice" : currentEngine.displayName

        // Reuse existing service if already loaded for this engine
        if let existing = asrService, loadedEngine == currentEngine, !useSenseVoice {
            print("[VM] Reusing existing \(currentEngine.displayName)")
            return existing
        }
        if let existing = asrService as? SenseVoiceASR, useSenseVoice {
            print("[VM] Reusing existing SenseVoice")
            return existing
        }

        // Need to load a new model
        asrService = nil
        loadedEngine = nil
        isLoadingModel = true
        defer { isLoadingModel = false }

        print("[VM] Loading \(effectiveEngine)...")

        let service: any ASRService
        if useSenseVoice {
            // SenseVoice for Chinese/Japanese/Korean
            let sv = SenseVoiceASR(modelDirectory: downloader.modelDirectory(for: ModelDownloader.SpecialModel.sensevoice))
            try await sv.loadModel()
            service = sv
        } else {
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
        }

        asrService = service
        loadedEngine = currentEngine
        print("[VM] ✓ Loaded \(currentEngine.displayName)")
        return service
    }
}
