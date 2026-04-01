import Foundation
import Translation

/// Pending translation request, set by the ViewModel, consumed by the View's .translationTask modifier.
struct PendingTranslation: Sendable {
    let text: String
    let source: SupportedLanguage
    let target: SupportedLanguage
}
