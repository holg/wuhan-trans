import Foundation

struct ConversationMessage: Identifiable, Sendable, Codable {
    let id: UUID
    let originalText: String
    let translatedText: String
    let sourceLanguage: SupportedLanguage
    let targetLanguage: SupportedLanguage
    let timestamp: Date
    let isRemote: Bool

    init(
        id: UUID = UUID(),
        originalText: String,
        translatedText: String,
        sourceLanguage: SupportedLanguage,
        targetLanguage: SupportedLanguage,
        timestamp: Date = Date(),
        isRemote: Bool = false
    ) {
        self.id = id
        self.originalText = originalText
        self.translatedText = translatedText
        self.sourceLanguage = sourceLanguage
        self.targetLanguage = targetLanguage
        self.timestamp = timestamp
        self.isRemote = isRemote
    }

    init(peerMessage: PeerMessage) {
        self.id = peerMessage.id
        self.originalText = peerMessage.originalText
        self.translatedText = peerMessage.translatedText
        self.sourceLanguage = peerMessage.sourceLanguage
        self.targetLanguage = peerMessage.targetLanguage
        self.timestamp = peerMessage.timestamp
        self.isRemote = true
    }
}
