import Foundation

enum WatchMessageType: String, Codable, Sendable {
    case audioData          // watch → phone
    case translationResult  // phone → watch
    case languageSync       // phone → watch
}

struct WatchMessage: Codable, Sendable {
    let type: WatchMessageType
    let payload: Data

    func encode() throws -> Data {
        try JSONEncoder().encode(self)
    }

    static func decode(from data: Data) throws -> WatchMessage {
        try JSONDecoder().decode(WatchMessage.self, from: data)
    }
}

/// Watch → phone: raw audio for ASR + translation
struct AudioPayload: Codable, Sendable {
    let samples: Data  // Float32 PCM, 16kHz mono, raw bytes
    let sourceLanguage: SupportedLanguage
    let targetLanguage: SupportedLanguage

    init(samples: [Float], sourceLanguage: SupportedLanguage, targetLanguage: SupportedLanguage) {
        self.samples = samples.withUnsafeBytes { Data($0) }
        self.sourceLanguage = sourceLanguage
        self.targetLanguage = targetLanguage
    }

    func floatSamples() -> [Float] {
        samples.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
    }
}

/// Phone → watch: completed translation
struct TranslationResultPayload: Codable, Sendable {
    let message: ConversationMessage
}

/// Phone → watch: current language config
struct LanguageSyncPayload: Codable, Sendable {
    let sourceLanguage: SupportedLanguage
    let targetLanguage: SupportedLanguage
}
