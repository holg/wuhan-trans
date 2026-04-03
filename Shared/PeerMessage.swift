import Foundation

/// Message sent between devices (local or relay).
/// In multi-user mode: only originalText + sourceLanguage are set by sender.
/// Each receiver translates locally into their own target language.
struct PeerMessage: Codable, Sendable {
    let id: UUID
    let originalText: String
    let translatedText: String  // empty in relay mode (receiver translates locally)
    let sourceLanguage: SupportedLanguage
    let targetLanguage: SupportedLanguage  // sender's target (for local peer mode)
    let senderName: String
    let timestamp: Date

    /// For local peer mode (pre-translated)
    init(from message: ConversationMessage, senderName: String = "") {
        self.id = message.id
        self.originalText = message.originalText
        self.translatedText = message.translatedText
        self.sourceLanguage = message.sourceLanguage
        self.targetLanguage = message.targetLanguage
        self.senderName = senderName
        self.timestamp = message.timestamp
    }

    /// For relay mode (original text only, receiver translates)
    init(originalText: String, sourceLanguage: SupportedLanguage, senderName: String) {
        self.id = UUID()
        self.originalText = originalText
        self.translatedText = ""
        self.sourceLanguage = sourceLanguage
        self.targetLanguage = sourceLanguage  // placeholder
        self.senderName = senderName
        self.timestamp = Date()
    }

    func encode() throws -> Data {
        try JSONEncoder().encode(self)
    }

    static func decode(from data: Data) throws -> PeerMessage {
        try JSONDecoder().decode(PeerMessage.self, from: data)
    }

    /// Whether this message needs local translation (relay mode)
    var needsTranslation: Bool {
        translatedText.isEmpty
    }
}
