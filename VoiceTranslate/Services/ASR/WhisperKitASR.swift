import AVFoundation
import WhisperKit

final class WhisperKitASR: ASRService, @unchecked Sendable {
    private var whisperKit: WhisperKit?
    private var audioEngine: AVAudioEngine?
    private var audioBuffer: [Float] = []
    private let engine: ASREngine
    private var language: SupportedLanguage = .chinese
    private(set) var isRecording = false

    init(engine: ASREngine) {
        precondition(engine.isWhisperKit, "WhisperKitASR requires a WhisperKit engine")
        self.engine = engine
    }

    func loadModel() async throws {
        guard let modelName = engine.whisperKitModelName else {
            throw WhisperKitASRError.invalidEngine
        }

        let repo = engine.huggingFaceRepo
        let config = WhisperKitConfig(
            model: modelName,
            modelRepo: repo,
            verbose: true,
            prewarm: true,
            load: true
        )
        whisperKit = try await WhisperKit(config)
    }

    func startRecording(language: SupportedLanguage) async throws {
        guard !isRecording else { return }
        guard whisperKit != nil else {
            throw WhisperKitASRError.modelNotLoaded
        }
        self.language = language
        audioBuffer = []

        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetoothHFP])
        try session.setActive(true)
        try await Task.sleep(for: .milliseconds(100))
        #endif

        let audioEngine = AVAudioEngine()
        let inputNode = audioEngine.inputNode
        let recordingFormat = inputNode.outputFormat(forBus: 0)

        guard recordingFormat.sampleRate > 0, recordingFormat.channelCount > 0 else {
            throw ASRError.audioFormatInvalid
        }

        inputNode.installTap(onBus: 0, bufferSize: 4096, format: recordingFormat) { [weak self] buffer, _ in
            guard let self else { return }
            let channelData = buffer.floatChannelData![0]
            let frameCount = Int(buffer.frameLength)
            let samples = Array(UnsafeBufferPointer(start: channelData, count: frameCount))
            self.audioBuffer.append(contentsOf: samples)
        }

        audioEngine.prepare()
        try audioEngine.start()
        self.audioEngine = audioEngine
        isRecording = true
    }

    func stopRecording() async throws -> String {
        guard isRecording else { return "" }
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine?.stop()
        audioEngine = nil
        isRecording = false

        guard let whisperKit, !audioBuffer.isEmpty else {
            return ""
        }

        let result = try await whisperKit.transcribe(
            audioArray: audioBuffer,
            decodeOptions: DecodingOptions(language: language.whisperCode)
        )
        return result.map(\.text).joined(separator: " ").trimmingCharacters(in: .whitespaces)
    }

    func transcribe(samples: [Float], language: SupportedLanguage) async throws -> String {
        guard let whisperKit else { throw WhisperKitASRError.modelNotLoaded }
        let result = try await whisperKit.transcribe(
            audioArray: samples,
            decodeOptions: DecodingOptions(language: language.whisperCode)
        )
        return result.map(\.text).joined(separator: " ").trimmingCharacters(in: .whitespaces)
    }
}

enum WhisperKitASRError: Error, LocalizedError {
    case invalidEngine
    case modelNotLoaded

    var errorDescription: String? {
        switch self {
        case .invalidEngine: "Invalid WhisperKit engine configuration"
        case .modelNotLoaded: "WhisperKit model not loaded"
        }
    }
}
