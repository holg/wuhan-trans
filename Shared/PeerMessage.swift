import Foundation

/// Message sent between paired devices over MultipeerConnectivity.
struct PeerMessage: Codable, Sendable {
    let id: UUID
    let originalText: String
    let translatedText: String
    let sourceLanguage: SupportedLanguage
    let targetLanguage: SupportedLanguage
    let timestamp: Date

    init(from message: ConversationMessage) {
        self.id = message.id
        self.originalText = message.originalText
        self.translatedText = message.translatedText
        self.sourceLanguage = message.sourceLanguage
        self.targetLanguage = message.targetLanguage
        self.timestamp = message.timestamp
    }

    func encode() throws -> Data {
        try JSONEncoder().encode(self)
    }

    static func decode(from data: Data) throws -> PeerMessage {
        try JSONDecoder().decode(PeerMessage.self, from: data)
    }
}
