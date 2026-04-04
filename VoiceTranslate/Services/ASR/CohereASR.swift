import AVFoundation
import CoreML

/// ASR service for Cohere Transcribe CoreML model.
/// Models loaded on-demand to minimize memory.
final class CohereASR: ASRService, @unchecked Sendable {
    private var audioEngine: AVAudioEngine?
    private var audioBuffer: [Float] = []
    private var language: SupportedLanguage = .chinese
    private(set) var isRecording = false

    private var manifest: CohereManifest?
    private let modelDirectory: URL
    private let mlConfig: MLModelConfiguration

    init(modelDirectory: URL) {
        self.modelDirectory = modelDirectory
        self.mlConfig = MLModelConfiguration()
        mlConfig.computeUnits = .cpuAndGPU
    }

    func loadModel() async throws {
        let manifestURL = modelDirectory.appending(path: "coreml_manifest.json")
        let data = try Data(contentsOf: manifestURL)
        manifest = try JSONDecoder().decode(CohereManifest.self, from: data)

        let required = [
            ".compiled/cohere_frontend.mlmodelc",
            ".compiled/cohere_encoder.mlmodelc",
            ".compiled/cohere_decoder_cached.mlmodelc",
            ".compiled/cohere_cross_kv_projector.mlmodelc",
            ".compiled/cohere_decoder_fullseq_masked.mlmodelc",
        ]
        for path in required {
            let url = modelDirectory.appending(path: path)
            guard FileManager.default.fileExists(atPath: url.path()) else {
                throw CohereASRError.inferenceError("Missing model: \(path)")
            }
        }
        print("[Cohere] Manifest loaded, all model files verified")
    }

    private func loadModel(_ name: String) async throws -> MLModel {
        let path = ".compiled/\(name).mlmodelc"
        let url = modelDirectory.appending(path: path)
        print("[Cohere] Loading \(name)...")
        return try await MLModel.load(contentsOf: url, configuration: mlConfig)
    }

    func startRecording(language: SupportedLanguage) async throws {
        guard !isRecording else { return }
        guard manifest != nil else { throw CohereASRError.modelNotLoaded }
        self.language = language
        audioBuffer = []

        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetoothHFP])
        try session.setActive(true)
        try await Task.sleep(for: .milliseconds(100))
        #endif

        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        let nativeFormat = inputNode.outputFormat(forBus: 0)

        guard nativeFormat.sampleRate > 0, nativeFormat.channelCount > 0 else {
            throw ASRError.audioFormatInvalid
        }

        // Cohere expects 16kHz mono Float32
        let targetFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!
        let converter = AVAudioConverter(from: nativeFormat, to: targetFormat)

        inputNode.installTap(onBus: 0, bufferSize: 4096, format: nativeFormat) { [weak self] buffer, _ in
            guard let self else { return }

            if let converter, nativeFormat.sampleRate != 16000 {
                let ratio = 16000.0 / nativeFormat.sampleRate
                let outputFrames = AVAudioFrameCount(Double(buffer.frameLength) * ratio)
                guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: outputFrames) else { return }
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
                guard let channelData = buffer.floatChannelData?[0] else { return }
                let samples = Array(UnsafeBufferPointer(start: channelData, count: Int(buffer.frameLength)))
                self.audioBuffer.append(contentsOf: samples)
            }
        }

        engine.prepare()
        try engine.start()
        self.audioEngine = engine
        isRecording = true
    }

    func stopRecording() async throws -> String {
        guard isRecording else { return "" }
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine?.stop()
        audioEngine = nil
        isRecording = false

        guard !audioBuffer.isEmpty else { return "" }
        return try await transcribe(audioBuffer)
    }

    func transcribe(samples: [Float], language: SupportedLanguage) async throws -> String {
        self.language = language
        return try await transcribe(samples)
    }

    // MARK: - Inference

    private func transcribe(_ audio: [Float]) async throws -> String {
        guard let manifest else { throw CohereASRError.modelNotLoaded }

        // Single chunk for now (up to 35s)
        let maxSamples = 560000  // model's actual input size
        let chunk = Array(audio.prefix(maxSamples))
        let tokens = try await transcribeChunk(chunk, manifest: manifest)
        return decodeTokens(tokens, manifest: manifest)
    }

    private func transcribeChunk(_ audio: [Float], manifest: CohereManifest) async throws -> [Int] {
        // 1. Frontend (~1 MB)
        let frontend = try await loadModel("cohere_frontend")
        let (features, featureLength) = try runFrontend(audio, model: frontend)
        print("[Cohere] Frontend done: \(featureLength) frames")

        // 2. Encoder (~1.3 GB) — load, run, release
        let encoder = try await loadModel("cohere_encoder")
        let (hiddenStates, encoderLength) = try runEncoder(features, featureLength: featureLength, model: encoder)
        print("[Cohere] Encoder done: \(encoderLength) frames")

        // 3. Cross-KV projector (~12 MB)
        let crossKV = try await loadModel("cohere_cross_kv_projector")
        let (crossK, crossV) = try runCrossKVProjector(hiddenStates, model: crossKV)
        print("[Cohere] Cross-KV done")

        // 4. Fullseq decoder (~109 MB) — get first token
        // Fullseq decoder expects [1, 438, 1024] but encoder outputs [1, 376, 1024]
        // Pad hidden states to 438 frames
        let paddedHiddenStates = padMultiArray(hiddenStates, toDim1: 438)
        let promptIDs = buildPrompt(manifest: manifest)
        let crossMaskFullseq = makeFloat16Mask4D(length: encoderLength, maxLength: 438)
        let fullseqDecoder = try await loadModel("cohere_decoder_fullseq_masked")
        let firstLogits = try runFullseqDecoder(
            hiddenStates: paddedHiddenStates, promptIDs: promptIDs,
            crossMask: crossMaskFullseq, model: fullseqDecoder, manifest: manifest
        )

        let promptLen = promptIDs.count
        let firstToken = argmax(firstLogits, offset: (promptLen - 1) * manifest.vocabSize, count: manifest.vocabSize)
        print("[Cohere] First token: \(firstToken) = \(manifest.idToToken[firstToken])")

        // 5. Cached decoder (~109 MB) — autoregressive
        let crossMaskCached = makeFloat16Mask4D(length: encoderLength, maxLength: 376)
        let cachedDecoder = try await loadModel("cohere_decoder_cached")
        var tokens: [Int] = [firstToken]
        var cacheK = makeZeroFloat16(shape: [8, 8, 108, 128])
        var cacheV = makeZeroFloat16(shape: [8, 8, 108, 128])
        var currentToken = firstToken

        for step in 0..<manifest.defaultMaxNewTokens {
            if currentToken == manifest.eosTokenID { break }

            let result = try runCachedDecoder(
                crossK: crossK, crossV: crossV,
                inputID: currentToken,
                cacheK: cacheK, cacheV: cacheV,
                step: promptLen + step,
                crossMask: crossMaskCached,
                model: cachedDecoder, manifest: manifest
            )

            let nextToken = argmax(result.logits, offset: 0, count: manifest.vocabSize)
            tokens.append(nextToken)
            cacheK = result.cacheK
            cacheV = result.cacheV
            currentToken = nextToken
        }

        print("[Cohere] Generated \(tokens.count) tokens")
        return tokens
    }

    // MARK: - Model Runners

    private func runFrontend(_ audio: [Float], model: MLModel) throws -> (MLMultiArray, Int) {
        let maxSamples = 560000
        let samples = try MLMultiArray(shape: [1, maxSamples as NSNumber], dataType: .float16)
        let count = min(audio.count, maxSamples)
        let ptr = samples.dataPointer.bindMemory(to: Float16.self, capacity: maxSamples)
        for i in 0..<count { ptr[i] = Float16(audio[i]) }

        let lengthArray = try MLMultiArray(shape: [1], dataType: .int32)
        lengthArray[0] = NSNumber(value: count)

        let input = try MLDictionaryFeatureProvider(dictionary: [
            "audio_samples": MLFeatureValue(multiArray: samples),
            "audio_length": MLFeatureValue(multiArray: lengthArray)
        ])

        let output = try model.prediction(from: input)
        let features = output.featureValue(for: "var_6916")!.multiArrayValue!
        let featureLen = output.featureValue(for: "cast_2")!.multiArrayValue![0].intValue
        return (features, featureLen)
    }

    private func runEncoder(_ features: MLMultiArray, featureLength: Int, model: MLModel) throws -> (MLMultiArray, Int) {
        let lenArray = try MLMultiArray(shape: [1], dataType: .int32)
        lenArray[0] = NSNumber(value: featureLength)

        let input = try MLDictionaryFeatureProvider(dictionary: [
            "input_features": MLFeatureValue(multiArray: features),
            "feature_length": MLFeatureValue(multiArray: lenArray)
        ])

        let output = try model.prediction(from: input)
        let hidden = output.featureValue(for: "var_8638")!.multiArrayValue!
        let encLen = output.featureValue(for: "cast_353")!.multiArrayValue![0].intValue
        return (hidden, encLen)
    }

    private func runCrossKVProjector(_ hiddenStates: MLMultiArray, model: MLModel) throws -> (MLMultiArray, MLMultiArray) {
        let input = try MLDictionaryFeatureProvider(dictionary: [
            "encoder_hidden_states": MLFeatureValue(multiArray: hiddenStates)
        ])
        let output = try model.prediction(from: input)
        return (
            output.featureValue(for: "var_356")!.multiArrayValue!,
            output.featureValue(for: "var_359")!.multiArrayValue!
        )
    }

    private func runFullseqDecoder(
        hiddenStates: MLMultiArray, promptIDs: [Int],
        crossMask: MLMultiArray, model: MLModel, manifest: CohereManifest
    ) throws -> [Float] {
        let maxLen = 268  // actual model input size

        let inputIDs = try MLMultiArray(shape: [1, maxLen as NSNumber], dataType: .int32)
        let decoderMask = try MLMultiArray(shape: [1, maxLen as NSNumber], dataType: .int32)
        let idsPtr = inputIDs.dataPointer.bindMemory(to: Int32.self, capacity: maxLen)
        let maskPtr = decoderMask.dataPointer.bindMemory(to: Int32.self, capacity: maxLen)
        for i in 0..<maxLen {
            if i < promptIDs.count {
                idsPtr[i] = Int32(promptIDs[i])
                maskPtr[i] = 1
            } else {
                idsPtr[i] = Int32(manifest.padTokenID)
                maskPtr[i] = 0
            }
        }

        let input = try MLDictionaryFeatureProvider(dictionary: [
            "encoder_hidden_states": MLFeatureValue(multiArray: hiddenStates),
            "input_ids": MLFeatureValue(multiArray: inputIDs),
            "decoder_attention_mask": MLFeatureValue(multiArray: decoderMask),
            "cross_attention_mask": MLFeatureValue(multiArray: crossMask)
        ])

        let output = try model.prediction(from: input)
        let logits = output.featureValue(for: "var_1009")!.multiArrayValue!

        // Shape: [1, 268, 16384] as Float16
        let totalCount = logits.count
        let logitsPtr = logits.dataPointer.bindMemory(to: Float16.self, capacity: totalCount)
        return (0..<totalCount).map { Float(logitsPtr[$0]) }
    }

    struct CachedDecoderResult {
        let logits: [Float]
        let cacheK: MLMultiArray
        let cacheV: MLMultiArray
    }

    private func runCachedDecoder(
        crossK: MLMultiArray, crossV: MLMultiArray,
        inputID: Int,
        cacheK: MLMultiArray, cacheV: MLMultiArray,
        step: Int,
        crossMask: MLMultiArray,
        model: MLModel, manifest: CohereManifest
    ) throws -> CachedDecoderResult {
        let idArray = try MLMultiArray(shape: [1, 1], dataType: .int32)
        idArray[0] = NSNumber(value: inputID)

        let stepArray = try MLMultiArray(shape: [1], dataType: .int32)
        stepArray[0] = NSNumber(value: step)

        let input = try MLDictionaryFeatureProvider(dictionary: [
            "cross_k": MLFeatureValue(multiArray: crossK),
            "cross_v": MLFeatureValue(multiArray: crossV),
            "input_id": MLFeatureValue(multiArray: idArray),
            "cache_k": MLFeatureValue(multiArray: cacheK),
            "cache_v": MLFeatureValue(multiArray: cacheV),
            "step": MLFeatureValue(multiArray: stepArray),
            "cross_attention_mask": MLFeatureValue(multiArray: crossMask)
        ])

        let output = try model.prediction(from: input)
        let logitsMA = output.featureValue(for: "var_2620")!.multiArrayValue!
        let newCacheK = output.featureValue(for: "var_2623")!.multiArrayValue!
        let newCacheV = output.featureValue(for: "var_2626")!.multiArrayValue!

        // Shape: [1, 16384] as Float16
        let count = logitsMA.count
        let ptr = logitsMA.dataPointer.bindMemory(to: Float16.self, capacity: count)
        let logits = (0..<count).map { Float(ptr[$0]) }

        return CachedDecoderResult(logits: logits, cacheK: newCacheK, cacheV: newCacheV)
    }

    // MARK: - Helpers

    private func buildPrompt(manifest: CohereManifest) -> [Int] {
        var prompt = manifest.promptIDs
        let langToken = cohereLanguageToken(for: language, manifest: manifest)
        if prompt.count > 5 {
            prompt[4] = langToken
            prompt[5] = langToken
        }
        return prompt
    }

    private func cohereLanguageToken(for lang: SupportedLanguage, manifest: CohereManifest) -> Int {
        let tag = "<|\(lang.whisperCode)|>"
        if let idx = manifest.idToToken.firstIndex(of: tag) { return idx }
        return 62
    }

    /// Pad a [1, N, D] Float16 MLMultiArray to [1, targetN, D] with zeros
    private func padMultiArray(_ arr: MLMultiArray, toDim1 targetDim1: Int) -> MLMultiArray {
        let shape = arr.shape.map { $0.intValue }
        guard shape.count == 3, shape[1] < targetDim1 else { return arr }

        let dim0 = shape[0]
        let dim1Current = shape[1]
        let dim2 = shape[2]
        let padded = try! MLMultiArray(shape: [dim0 as NSNumber, targetDim1 as NSNumber, dim2 as NSNumber], dataType: .float16)

        let srcPtr = arr.dataPointer.bindMemory(to: Float16.self, capacity: arr.count)
        let dstPtr = padded.dataPointer.bindMemory(to: Float16.self, capacity: padded.count)

        // Zero fill
        for i in 0..<padded.count { dstPtr[i] = 0 }

        // Copy original data
        let copyCount = dim0 * dim1Current * dim2
        for i in 0..<copyCount {
            dstPtr[i] = srcPtr[i]
        }

        return padded
    }

    /// 4D float16 mask: [1, 1, 1, maxLength] with 1s up to length, 0s after
    private func makeFloat16Mask4D(length: Int, maxLength: Int) -> MLMultiArray {
        let mask = try! MLMultiArray(shape: [1, 1, 1, maxLength as NSNumber], dataType: .float16)
        let ptr = mask.dataPointer.bindMemory(to: Float16.self, capacity: maxLength)
        for i in 0..<maxLength { ptr[i] = i < length ? Float16(1) : Float16(0) }
        return mask
    }

    private func makeZeroFloat16(shape: [Int]) -> MLMultiArray {
        let nsShape = shape.map { $0 as NSNumber }
        let arr = try! MLMultiArray(shape: nsShape, dataType: .float16)
        let count = arr.count
        let ptr = arr.dataPointer.bindMemory(to: Float16.self, capacity: count)
        for i in 0..<count { ptr[i] = 0 }
        return arr
    }

    private func argmax(_ array: [Float], offset: Int, count: Int) -> Int {
        var maxVal: Float = -Float.infinity
        var maxIdx = 0
        for i in 0..<count {
            let val = array[offset + i]
            if val > maxVal { maxVal = val; maxIdx = i }
        }
        return maxIdx
    }

    private func decodeTokens(_ tokens: [Int], manifest: CohereManifest) -> String {
        let vocab = manifest.idToToken
        var text = ""
        for token in tokens {
            if token == manifest.eosTokenID || token == manifest.padTokenID { continue }
            if token < 255 { continue } // skip all special/control/language/speaker tokens
            guard token < vocab.count else { continue }
            var piece = vocab[token]
            piece = piece.replacingOccurrences(of: "\u{2581}", with: " ")
            text += piece
        }
        return text.trimmingCharacters(in: .whitespaces)
    }
}

enum CohereASRError: Error, LocalizedError {
    case modelNotLoaded
    case inferenceError(String)

    var errorDescription: String? {
        switch self {
        case .modelNotLoaded: "Cohere model not loaded"
        case .inferenceError(let msg): "Cohere inference error: \(msg)"
        }
    }
}

struct CohereManifest: Codable, Sendable {
    let modelID: String
    let sampleRate: Int
    let preemph: Float
    let maxAudioSamples: Int
    let maxAudioSeconds: Float
    let overlapSeconds: Float
    let overlapSamples: Int
    let maxFeatureFrames: Int
    let maxEncoderFrames: Int
    let encoderHiddenSize: Int
    let decoderMaxLen: Int
    let defaultMaxNewTokens: Int
    let promptIDs: [Int]
    let eosTokenID: Int
    let padTokenID: Int
    let idToToken: [String]

    var numLayers: Int { 8 }
    var numHeads: Int { 8 }
    var headDim: Int { 128 }
    var vocabSize: Int { idToToken.count }

    enum CodingKeys: String, CodingKey {
        case modelID = "model_id"
        case sampleRate = "sample_rate"
        case preemph
        case maxAudioSamples = "max_audio_samples"
        case maxAudioSeconds = "max_audio_seconds"
        case overlapSeconds = "overlap_seconds"
        case overlapSamples = "overlap_samples"
        case maxFeatureFrames = "max_feature_frames"
        case maxEncoderFrames = "max_encoder_frames"
        case encoderHiddenSize = "encoder_hidden_size"
        case decoderMaxLen = "decoder_max_len"
        case defaultMaxNewTokens = "default_max_new_tokens"
        case promptIDs = "prompt_ids"
        case eosTokenID = "eos_token_id"
        case padTokenID = "pad_token_id"
        case idToToken = "id_to_token"
    }
}
