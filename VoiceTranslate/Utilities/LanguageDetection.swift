import Foundation
import NaturalLanguage

struct LanguageDetection: Sendable {
    /// Detect the dominant language of the given text.
    /// Returns nil if confidence is too low.
    /// Note: unreliable for short utterances, especially zh↔en code-switching.
    func detect(text: String) -> SupportedLanguage? {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        guard let dominant = recognizer.dominantLanguage else { return nil }

        switch dominant {
        case .simplifiedChinese, .traditionalChinese: return .chinese
        case .english: return .english
        case .german: return .german
        default: return nil
        }
    }
}
