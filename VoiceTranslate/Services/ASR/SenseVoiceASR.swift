import AVFoundation
import Accelerate
import CoreML

/// SenseVoice ASR — Chinese-optimized speech recognition.
/// Supports: zh, en, ja, ko, yue (Cantonese)
/// Pipeline: audio → mel spectrogram → LFR stacking → CMVN → CoreML → CTC decode
final class SenseVoiceASR: ASRService, @unchecked Sendable {
    private var model: MLModel?
    private var cmvnShift: [Float] = []  // 560 values
    private var cmvnScale: [Float] = []  // 560 values
    private var vocab: [Int: String] = [:]
    private var audioEngine: AVAudioEngine?
    private var audioBuffer: [Float] = []
    private let lock = NSLock()
    private(set) var isRecording = false

    private let modelDirectory: URL

    private func resetBuffer() {
        lock.lock()
        audioBuffer = []
        lock.unlock()
    }

    private func getAndClearBuffer() -> [Float] {
        lock.lock()
        let result = audioBuffer
        audioBuffer = []
        lock.unlock()
        return result
    }

    init(modelDirectory: URL) {
        self.modelDirectory = modelDirectory
    }

    func loadModel() async throws {
        let config = MLModelConfiguration()
        config.computeUnits = .cpuAndGPU

        let modelURL = modelDirectory.appending(path: "SenseVoiceSmall.mlmodelc")
        guard FileManager.default.fileExists(atPath: modelURL.path()) else {
            throw SenseVoiceError.modelNotFound
        }

        print("[SenseVoice] Loading model...")
        model = try await MLModel.load(contentsOf: modelURL, configuration: config)

        // Load CMVN
        let cmvnURL = modelDirectory.appending(path: "am.mvn")
        try loadCMVN(from: cmvnURL)

        // Load vocabulary from BPE model (we use a simple token list)
        let vocabURL = modelDirectory.appending(path: "tokens.bpe.model")
        try loadVocab(from: vocabURL)

        print("[SenseVoice] ✓ Loaded, vocab=\(vocab.count) tokens")
    }

    // MARK: - ASRService

    func startRecording(language: SupportedLanguage) async throws {
        guard !isRecording else { return }
        guard model != nil else { throw SenseVoiceError.modelNotLoaded }

        resetBuffer()

        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetoothHFP])
        try session.setActive(true)
        try await Task.sleep(for: .milliseconds(100))
        #endif

        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        let nativeFormat = inputNode.outputFormat(forBus: 0)

        guard nativeFormat.sampleRate > 0 else {
            throw ASRError.audioFormatInvalid
        }

        // Resample to 16kHz
        let targetFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!
        let converter = AVAudioConverter(from: nativeFormat, to: targetFormat)

        nonisolated(unsafe) let unsafeSelf = self
        inputNode.installTap(onBus: 0, bufferSize: 4096, format: nativeFormat) { buffer, _ in
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
                    unsafeSelf.lock.lock()
                    unsafeSelf.audioBuffer.append(contentsOf: samples)
                    unsafeSelf.lock.unlock()
                }
            } else {
                guard let channelData = buffer.floatChannelData?[0] else { return }
                let samples = Array(UnsafeBufferPointer(start: channelData, count: Int(buffer.frameLength)))
                unsafeSelf.lock.lock()
                unsafeSelf.audioBuffer.append(contentsOf: samples)
                unsafeSelf.lock.unlock()
            }
        }

        engine.prepare()
        try engine.start()
        audioEngine = engine
        isRecording = true
    }

    func stopRecording() async throws -> String {
        guard isRecording else { return "" }
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine?.stop()
        audioEngine = nil
        isRecording = false

        let audio = getAndClearBuffer()

        guard !audio.isEmpty else { return "" }
        return try transcribe(audio, language: .chinese)
    }

    func transcribe(samples: [Float], language: SupportedLanguage) async throws -> String {
        try transcribe(samples, language: language)
    }

    // MARK: - Inference Pipeline

    private func transcribe(_ audio: [Float], language: SupportedLanguage) throws -> String {
        guard let model else { throw SenseVoiceError.modelNotLoaded }

        // 1. Compute mel spectrogram (80 bands, 25ms window, 10ms shift at 16kHz)
        let melFeatures = computeMelSpectrogram(audio: audio, sampleRate: 16000, nMels: 80)
        print("[SenseVoice] Mel: \(melFeatures.count) frames x 80")

        // 2. LFR (Low Frame Rate) — stack 7 frames, skip 6
        let lfrFeatures = applyLFR(melFeatures, lfrM: 7, lfrN: 6)
        print("[SenseVoice] LFR: \(lfrFeatures.count) frames x 560")

        // 3. CMVN normalization
        let normalizedFeatures = applyCMVN(lfrFeatures)

        // 4. Build CoreML input
        let T = normalizedFeatures.count
        let speechArray = try MLMultiArray(shape: [1, T as NSNumber, 560], dataType: .float32)
        let ptr = speechArray.dataPointer.bindMemory(to: Float.self, capacity: T * 560)
        for i in 0..<T {
            for j in 0..<560 {
                ptr[i * 560 + j] = normalizedFeatures[i][j]
            }
        }

        let lengthArray = try MLMultiArray(shape: [1], dataType: .int32)
        lengthArray[0] = NSNumber(value: T)

        let langID = senseVoiceLanguageID(for: language)
        let langArray = try MLMultiArray(shape: [1], dataType: .int32)
        langArray[0] = NSNumber(value: langID)

        let textnormArray = try MLMultiArray(shape: [1], dataType: .int32)
        textnormArray[0] = NSNumber(value: 15) // woitn (without inverse text norm)

        let input = try MLDictionaryFeatureProvider(dictionary: [
            "speech": MLFeatureValue(multiArray: speechArray),
            "speech_lengths": MLFeatureValue(multiArray: lengthArray),
            "language": MLFeatureValue(multiArray: langArray),
            "textnorm": MLFeatureValue(multiArray: textnormArray),
        ])

        // 5. Run model
        print("[SenseVoice] Running inference...")
        let output = try model.prediction(from: input)

        guard let ctcLogits = output.featureValue(for: "ctc_logits")?.multiArrayValue else {
            throw SenseVoiceError.inferenceFailed
        }

        // 6. CTC greedy decode
        let text = ctcGreedyDecode(logits: ctcLogits)
        print("[SenseVoice] Transcript: \(text.prefix(80))")
        return text
    }

    // MARK: - Audio Preprocessing

    private func computeMelSpectrogram(audio: [Float], sampleRate: Int, nMels: Int) -> [[Float]] {
        let nFFT = 400 // 25ms at 16kHz
        let hopLength = 160 // 10ms at 16kHz
        let numFrames = max(0, (audio.count - nFFT) / hopLength + 1)

        var frames: [[Float]] = []
        let window = hanningWindow(size: nFFT)

        for i in 0..<numFrames {
            let start = i * hopLength
            let end = min(start + nFFT, audio.count)

            // Apply window
            var frame = [Float](repeating: 0, count: nFFT)
            for j in 0..<(end - start) {
                frame[j] = audio[start + j] * window[j]
            }

            // FFT
            let magnitudes = fftMagnitudes(frame)

            // Mel filterbank (simplified — linear spacing)
            let melFrame = applyMelFilterbank(magnitudes: magnitudes, nMels: nMels, nFFT: nFFT, sampleRate: sampleRate)
            frames.append(melFrame)
        }

        return frames
    }

    private func hanningWindow(size: Int) -> [Float] {
        (0..<size).map { 0.5 * (1 - cos(2 * Float.pi * Float($0) / Float(size - 1))) }
    }

    private func fftMagnitudes(_ frame: [Float]) -> [Float] {
        let n = frame.count
        let log2n = vDSP_Length(log2(Float(n)))

        guard let fftSetup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else {
            return [Float](repeating: 0, count: n / 2 + 1)
        }
        defer { vDSP_destroy_fftsetup(fftSetup) }

        var realp = [Float](repeating: 0, count: n / 2)
        var imagp = [Float](repeating: 0, count: n / 2)
        var splitComplex = DSPSplitComplex(realp: &realp, imagp: &imagp)

        frame.withUnsafeBufferPointer { ptr in
            ptr.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: n / 2) { complexPtr in
                vDSP_ctoz(complexPtr, 2, &splitComplex, 1, vDSP_Length(n / 2))
            }
        }

        vDSP_fft_zrip(fftSetup, &splitComplex, 1, log2n, FFTDirection(FFT_FORWARD))

        var magnitudes = [Float](repeating: 0, count: n / 2 + 1)
        vDSP_zvmags(&splitComplex, 1, &magnitudes, 1, vDSP_Length(n / 2))
        magnitudes[n / 2] = splitComplex.imagp[0] * splitComplex.imagp[0]

        // Convert to power spectrum
        var scale = Float(1.0 / Float(n))
        vDSP_vsmul(magnitudes, 1, &scale, &magnitudes, 1, vDSP_Length(n / 2 + 1))

        return magnitudes
    }

    private func applyMelFilterbank(magnitudes: [Float], nMels: Int, nFFT: Int, sampleRate: Int) -> [Float] {
        let nBins = nFFT / 2 + 1
        let fMax = Float(sampleRate) / 2
        let melMax = 2595 * log10(1 + fMax / 700)
        let melMin: Float = 0

        let melPoints = (0...(nMels + 1)).map { melMin + Float($0) * (melMax - melMin) / Float(nMels + 1) }
        let hzPoints = melPoints.map { 700 * (pow(10, $0 / 2595) - 1) }
        let binPoints = hzPoints.map { Int($0 / fMax * Float(nBins - 1)) }

        var melFrame = [Float](repeating: 0, count: nMels)
        for m in 0..<nMels {
            let left = binPoints[m]
            let center = binPoints[m + 1]
            let right = binPoints[m + 2]

            for k in left..<center {
                guard k < magnitudes.count else { break }
                let weight = Float(k - left) / max(Float(center - left), 1)
                melFrame[m] += magnitudes[k] * weight
            }
            for k in center..<right {
                guard k < magnitudes.count else { break }
                let weight = Float(right - k) / max(Float(right - center), 1)
                melFrame[m] += magnitudes[k] * weight
            }

            // Log mel
            melFrame[m] = log(max(melFrame[m], 1e-10))
        }

        return melFrame
    }

    // MARK: - LFR + CMVN

    private func applyLFR(_ features: [[Float]], lfrM: Int, lfrN: Int) -> [[Float]] {
        let T = features.count
        var lfr: [[Float]] = []
        var i = 0
        while i < T {
            var stacked: [Float] = []
            for j in 0..<lfrM {
                let idx = min(i + j, T - 1)
                stacked.append(contentsOf: features[idx])
            }
            lfr.append(stacked)
            i += lfrN
        }
        return lfr
    }

    private func applyCMVN(_ features: [[Float]]) -> [[Float]] {
        guard cmvnShift.count == 560, cmvnScale.count == 560 else { return features }
        return features.map { frame in
            zip(zip(frame, cmvnShift), cmvnScale).map { (pair, scale) in
                (pair.0 + pair.1) * scale
            }
        }
    }

    // MARK: - CTC Decoding

    private func ctcGreedyDecode(logits: MLMultiArray) -> String {
        let shape = logits.shape.map { $0.intValue }
        guard shape.count >= 2 else { return "" }

        let T = shape.count == 3 ? shape[1] : shape[0]
        let vocabSize = shape.last!

        var tokens: [Int] = []
        var lastToken = -1

        // Skip first 4 frames (special tokens: lang, event, emotion, textnorm)
        let startFrame = 4

        for t in startFrame..<T {
            var maxVal: Float = -Float.infinity
            var maxIdx = 0

            for v in 0..<vocabSize {
                let val: Float
                if shape.count == 3 {
                    val = logits[[0, t, v] as [NSNumber]].floatValue
                } else {
                    val = logits[[t, v] as [NSNumber]].floatValue
                }
                if val > maxVal {
                    maxVal = val
                    maxIdx = v
                }
            }

            // CTC: skip blank (0) and collapse repeats
            if maxIdx != 0 && maxIdx != lastToken {
                tokens.append(maxIdx)
            }
            lastToken = maxIdx
        }

        // Decode tokens to text
        let text = tokens.compactMap { vocab[$0] }.joined()
            .replacingOccurrences(of: "▁", with: " ")
            .trimmingCharacters(in: .whitespaces)

        return text
    }

    // MARK: - File Loading

    private func loadCMVN(from url: URL) throws {
        let content = try String(contentsOf: url, encoding: .utf8)
        let lines = content.components(separatedBy: "\n")

        // Parse Kaldi-format CMVN: AddShift values, then Rescale values
        var shifts: [Float] = []
        var scales: [Float] = []
        var readingShift = false
        var readingScale = false

        for line in lines {
            if line.contains("AddShift") { readingShift = true; readingScale = false; continue }
            if line.contains("Rescale") { readingScale = true; readingShift = false; continue }

            if (readingShift || readingScale) && line.contains("[") {
                let numStr = line.replacingOccurrences(of: "[", with: "")
                    .replacingOccurrences(of: "]", with: "")
                    .trimmingCharacters(in: .whitespaces)
                let values = numStr.split(separator: " ").compactMap { Float($0) }
                if readingShift { shifts.append(contentsOf: values) }
                if readingScale { scales.append(contentsOf: values) }
            }
        }

        cmvnShift = shifts.isEmpty ? [Float](repeating: 0, count: 560) : shifts
        cmvnScale = scales.isEmpty ? [Float](repeating: 1, count: 560) : scales
        print("[SenseVoice] CMVN: shift=\(cmvnShift.count), scale=\(cmvnScale.count)")
    }

    private func loadVocab(from url: URL) throws {
        // SentencePiece .bpe.model is a protobuf file — parse tokens from it
        // For simplicity, we extract printable token strings
        let data = try Data(contentsOf: url)

        // Simple protobuf token extraction: look for readable strings
        // Token IDs are sequential starting from 0
        var tokens: [Int: String] = [:]
        var tokenID = 0
        var i = 0

        while i < data.count - 1 {
            // SentencePiece protobuf: field 1 (pieces), sub-field 1 (piece string)
            if data[i] == 0x0A { // field 1, wire type 2 (length-delimited)
                i += 1
                guard i < data.count else { break }
                let outerLen = Int(data[i])
                i += 1
                guard i < data.count else { break }

                if data[i] == 0x0A { // sub-field 1 (piece)
                    i += 1
                    guard i < data.count else { break }
                    let strLen = Int(data[i])
                    i += 1

                    if strLen > 0 && strLen < 100 && i + strLen <= data.count {
                        if let str = String(data: data[i..<(i + strLen)], encoding: .utf8) {
                            tokens[tokenID] = str
                        }
                        tokenID += 1
                    }
                    i += max(0, outerLen - strLen - 2)
                } else {
                    i += outerLen
                }
            } else {
                i += 1
            }
        }

        vocab = tokens
        print("[SenseVoice] Vocab: \(tokens.count) tokens parsed from BPE model")
    }

    private func senseVoiceLanguageID(for lang: SupportedLanguage) -> Int {
        switch lang {
        case .chinese: return 3
        case .english: return 4
        case .japanese: return 11
        case .korean: return 12
        default: return 0 // auto
        }
    }

    /// Languages supported by SenseVoice
    static let supportedLanguages: Set<SupportedLanguage> = [.chinese, .english, .japanese, .korean]
}

enum SenseVoiceError: Error, LocalizedError {
    case modelNotFound
    case modelNotLoaded
    case inferenceFailed

    var errorDescription: String? {
        switch self {
        case .modelNotFound: "SenseVoice model not downloaded"
        case .modelNotLoaded: "SenseVoice model not loaded"
        case .inferenceFailed: "SenseVoice inference failed"
        }
    }
}
