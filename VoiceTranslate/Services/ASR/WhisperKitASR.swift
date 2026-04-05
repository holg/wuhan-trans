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
        let mem = MemoryMonitor()
        print("[WhisperKit] Loading model=\(modelName) repo=\(repo ?? "default") freeMB=\(mem.availableMemoryMB)")

        if mem.availableMemoryMB < 500 {
            throw WhisperKitASRError.insufficientMemory(available: mem.availableMemoryMB)
        }

        let config = WhisperKitConfig(
            model: modelName,
            modelRepo: repo,
            verbose: true,
            prewarm: false,
            load: true
        )
        let kit = try await WhisperKit(config)

        let memAfter = MemoryMonitor()
        guard kit.modelState == .loaded else {
            print("[WhisperKit] Model state: \(kit.modelState) — not loaded! freeMB=\(memAfter.availableMemoryMB)")
            throw WhisperKitASRError.modelNotLoaded
        }
        print("[WhisperKit] ✓ Loaded, state=\(kit.modelState) freeMB=\(memAfter.availableMemoryMB)")
        whisperKit = kit
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

        // WhisperKit requires 16kHz mono Float32
        guard let whisperFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false) else {
            throw ASRError.audioFormatInvalid
        }

        let nativeFormat = inputNode.outputFormat(forBus: 0)
        guard nativeFormat.sampleRate > 0, nativeFormat.channelCount > 0 else {
            throw ASRError.audioFormatInvalid
        }

        // Install tap with converter to 16kHz if needed
        let converter = AVAudioConverter(from: nativeFormat, to: whisperFormat)

        inputNode.installTap(onBus: 0, bufferSize: 4096, format: nativeFormat) { [weak self] buffer, _ in
            guard let self else { return }

            if let converter, nativeFormat.sampleRate != 16000 {
                // Resample to 16kHz
                let ratio = 16000.0 / nativeFormat.sampleRate
                let outputFrames = AVAudioFrameCount(Double(buffer.frameLength) * ratio)
                guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: whisperFormat, frameCapacity: outputFrames) else { return }

                var error: NSError?
                converter.convert(to: outputBuffer, error: &error) { _, outStatus in
                    outStatus.pointee = .haveData
                    return buffer
                }
                if error == nil, let channelData = outputBuffer.floatChannelData?[0] {
                    let samples = Array(UnsafeBufferPointer(start: channelData, count: Int(outputBuffer.frameLength)))
                    self.audioBuffer.append(contentsOf: samples)
                }
            } else {
                // Already 16kHz
                guard let channelData = buffer.floatChannelData?[0] else { return }
                let samples = Array(UnsafeBufferPointer(start: channelData, count: Int(buffer.frameLength)))
                self.audioBuffer.append(contentsOf: samples)
            }
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
    case insufficientMemory(available: Int)

    var errorDescription: String? {
        switch self {
        case .invalidEngine: "Invalid WhisperKit engine configuration"
        case .modelNotLoaded: "WhisperKit model failed to load — try a smaller model"
        case .insufficientMemory(let mb): "Not enough memory (\(mb) MB free) — try a smaller model"
        }
    }
}
