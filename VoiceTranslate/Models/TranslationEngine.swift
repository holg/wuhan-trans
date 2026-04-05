import Foundation

enum TranslationEngine: String, CaseIterable, Identifiable, Codable, Sendable {
    case apple
    case nllb

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .apple: "Apple Translation (on-device)"
        case .nllb: "NLLB-200 (on-device, GDPR)"
        }
    }

    var modelDescription: String {
        switch self {
        case .apple: "Built-in, no download — GDPR status unclear"
        case .nllb: "~1.7 GB download — fully GDPR compliant"
        }
    }

    var requiresDownload: Bool {
        self == .nllb
    }
}
