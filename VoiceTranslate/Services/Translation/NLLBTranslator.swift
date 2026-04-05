import CoreML
import Foundation

/// On-device NLLB-200 translation — fully GDPR compliant, no Apple frameworks.
/// Encoder-decoder seq2seq with SentencePiece tokenizer.
final class NLLBTranslator: @unchecked Sendable {
    private var encoder: MLModel?
    private var decoder: MLModel?
    private var tokenizer: NLLBTokenizer?
    private let maxLen = 256
    private let eosTokenID: Int32 = 2
    private let padTokenID: Int32 = 1

    private let modelDirectory: URL

    init(modelDirectory: URL) {
        self.modelDirectory = modelDirectory
    }

    var isLoaded: Bool { encoder != nil && decoder != nil && tokenizer != nil }

    func loadModels() async throws {
        let config = MLModelConfiguration()
        config.computeUnits = .cpuAndGPU

        let encoderURL = modelDirectory.appending(path: "NLLB_Encoder_256.mlmodelc")
        let decoderURL = modelDirectory.appending(path: "NLLB_Decoder_256.mlmodelc")
        let tokenizerURL = modelDirectory.appending(path: "tokenizer/tokenizer.json")

        guard FileManager.default.fileExists(atPath: encoderURL.path()),
              FileManager.default.fileExists(atPath: decoderURL.path()),
              FileManager.default.fileExists(atPath: tokenizerURL.path()) else {
            throw NLLBError.modelsNotFound
        }

        print("[NLLB] Loading encoder...")
        encoder = try await MLModel.load(contentsOf: encoderURL, configuration: config)
        print("[NLLB] Loading decoder...")
        decoder = try await MLModel.load(contentsOf: decoderURL, configuration: config)
        print("[NLLB] Loading tokenizer...")
        tokenizer = try NLLBTokenizer(tokenizerURL: tokenizerURL)
        print("[NLLB] ✓ All models loaded")
    }

    func translate(text: String, from source: SupportedLanguage, to target: SupportedLanguage) async throws -> String {
        guard let encoder, let decoder, let tokenizer else {
            throw NLLBError.modelsNotLoaded
        }

        // 1. Tokenize input with source language prefix
        let inputIDs = tokenizer.encode(text: text, sourceLanguage: source.nllbCode, maxLength: maxLen)
        let attentionMask = inputIDs.map { $0 != padTokenID ? Int32(1) : Int32(0) }

        print("[NLLB] Input tokens: \(inputIDs.prefix(20))... (\(inputIDs.filter { $0 != padTokenID }.count) real tokens)")

        // 2. Run encoder
        let inputIDsArray = try mlArray(from: inputIDs, shape: [1, maxLen])
        let maskArray = try mlArray(from: attentionMask, shape: [1, maxLen])

        let encInput = try MLDictionaryFeatureProvider(dictionary: [
            "input_ids": MLFeatureValue(multiArray: inputIDsArray),
            "attention_mask": MLFeatureValue(multiArray: maskArray)
        ])
        let encOutput = try await encoder.prediction(from: encInput)

        // Find encoder hidden states output
        guard let hiddenStates = encOutput.featureNames.compactMap({ encOutput.featureValue(for: $0)?.multiArrayValue }).first else {
            throw NLLBError.encoderFailed
        }

        print("[NLLB] Encoder done")

        // 3. Autoregressive decoding
        let targetLangToken = tokenizer.languageToken(for: target.nllbCode)
        var currentTokens: [Int32] = [eosTokenID, Int32(targetLangToken)]

        for _ in 0..<(maxLen - 2) {
            let decoderInput = try makeDecoderInput(
                tokens: currentTokens,
                hiddenStates: hiddenStates,
                encoderMask: maskArray
            )

            let decOutput = try await decoder.prediction(from: decoderInput)

            // Find logits output (largest array)
            guard let logits = decOutput.featureNames
                .compactMap({ decOutput.featureValue(for: $0)?.multiArrayValue })
                .max(by: { $0.count < $1.count }) else {
                throw NLLBError.decoderFailed
            }

            // Get next token: argmax of logits at position (currentTokens.count - 1)
            let vocabSize = 256206
            let pos = currentTokens.count - 1
            let offset = pos * vocabSize
            let ptr = logits.dataPointer.bindMemory(to: Float16.self, capacity: logits.count)

            var maxVal: Float = -Float.infinity
            var maxIdx: Int32 = 0
            for i in 0..<vocabSize {
                let val = Float(ptr[offset + i])
                if val > maxVal {
                    maxVal = val
                    maxIdx = Int32(i)
                }
            }

            if maxIdx == eosTokenID { break }
            currentTokens.append(maxIdx)
        }

        // 4. Decode tokens (skip BOS + language token)
        let outputTokens = Array(currentTokens.dropFirst(2))
        let result = tokenizer.decode(tokens: outputTokens)
        print("[NLLB] Translated: \(result.prefix(80))")
        return result
    }

    // MARK: - Helpers

    private func mlArray(from values: [Int32], shape: [Int]) throws -> MLMultiArray {
        let nsShape = shape.map { $0 as NSNumber }
        let arr = try MLMultiArray(shape: nsShape, dataType: .int32)
        let ptr = arr.dataPointer.bindMemory(to: Int32.self, capacity: values.count)
        for i in 0..<values.count { ptr[i] = values[i] }
        return arr
    }

    private func makeDecoderInput(tokens: [Int32], hiddenStates: MLMultiArray, encoderMask: MLMultiArray) throws -> MLDictionaryFeatureProvider {
        let decoderIDs = try MLMultiArray(shape: [1, maxLen as NSNumber], dataType: .int32)
        let ptr = decoderIDs.dataPointer.bindMemory(to: Int32.self, capacity: maxLen)
        for i in 0..<maxLen {
            ptr[i] = i < tokens.count ? tokens[i] : padTokenID
        }

        return try MLDictionaryFeatureProvider(dictionary: [
            "decoder_input_ids": MLFeatureValue(multiArray: decoderIDs),
            "encoder_hidden_states": MLFeatureValue(multiArray: hiddenStates),
            "encoder_attention_mask": MLFeatureValue(multiArray: encoderMask)
        ])
    }
}

// MARK: - Simple tokenizer using tokenizer.json

final class NLLBTokenizer {
    private let vocab: [String: Int]     // token string → ID
    private let reverseVocab: [Int: String]  // ID → token string
    private let merges: [(String, String)]

    init(tokenizerURL: URL) throws {
        let data = try Data(contentsOf: tokenizerURL)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]

        // Extract vocabulary
        let model = json["model"] as! [String: Any]
        let vocabDict = model["vocab"] as! [String: Int]
        self.vocab = vocabDict
        self.reverseVocab = Dictionary(uniqueKeysWithValues: vocabDict.map { ($0.value, $0.key) })

        // Extract merges — can be [[String, String]] or ["a b"] format
        if let pairMerges = model["merges"] as? [[String]] {
            self.merges = pairMerges.compactMap { pair in
                pair.count == 2 ? (pair[0], pair[1]) : nil
            }
        } else if let stringMerges = model["merges"] as? [String] {
            self.merges = stringMerges.map { line in
                let parts = line.split(separator: " ", maxSplits: 1)
                return (String(parts[0]), String(parts.count > 1 ? parts[1] : ""))
            }
        } else {
            self.merges = []
        }

        print("[NLLBTokenizer] Loaded \(vocab.count) tokens, \(merges.count) merges")
    }

    func languageToken(for nllbCode: String) -> Int {
        vocab[nllbCode] ?? vocab["eng_Latn"] ?? 256047
    }

    func encode(text: String, sourceLanguage: String, maxLength: Int) -> [Int32] {
        // Simple word-level tokenization with BPE
        // Prepend source language token
        let langToken = Int32(languageToken(for: sourceLanguage))

        // Tokenize text using basic BPE
        let textTokens = bpeEncode(text)

        // Build: [lang_token, ...text_tokens, EOS, padding...]
        var ids: [Int32] = [langToken]
        ids.append(contentsOf: textTokens.prefix(maxLength - 2))
        ids.append(2) // EOS

        // Pad to maxLength
        while ids.count < maxLength {
            ids.append(1) // pad
        }
        return ids
    }

    func decode(tokens: [Int32]) -> String {
        let pieces = tokens.compactMap { reverseVocab[Int($0)] }
        // SentencePiece uses ▁ (U+2581) as word boundary
        let text = pieces.joined()
            .replacingOccurrences(of: "▁", with: " ")
            .trimmingCharacters(in: .whitespaces)
        return text
    }

    private func bpeEncode(_ text: String) -> [Int32] {
        // Simple character-level + merge-based BPE encoding
        // First, split into words and prepend ▁ to each word
        let words = text.split(separator: " ", omittingEmptySubsequences: true)
        var allTokens: [Int32] = []

        for (i, word) in words.enumerated() {
            let prefix = i == 0 ? "▁" : "▁"
            let wordStr = prefix + word

            // Try to find the full word in vocab
            if let id = vocab[wordStr] {
                allTokens.append(Int32(id))
                continue
            }

            // Fall back to character-level encoding
            var chars = wordStr.map { String($0) }

            // Apply BPE merges
            for (left, right) in merges {
                var i = 0
                while i < chars.count - 1 {
                    if chars[i] == left && chars[i + 1] == right {
                        chars[i] = left + right
                        chars.remove(at: i + 1)
                    } else {
                        i += 1
                    }
                }
            }

            // Convert to IDs
            for piece in chars {
                if let id = vocab[piece] {
                    allTokens.append(Int32(id))
                } else {
                    // Unknown token — use UNK (3)
                    allTokens.append(3)
                }
            }
        }

        return allTokens
    }
}

enum NLLBError: Error, LocalizedError {
    case modelsNotFound
    case modelsNotLoaded
    case encoderFailed
    case decoderFailed

    var errorDescription: String? {
        switch self {
        case .modelsNotFound: "NLLB models not downloaded"
        case .modelsNotLoaded: "NLLB models not loaded"
        case .encoderFailed: "NLLB encoder failed"
        case .decoderFailed: "NLLB decoder failed"
        }
    }
}
