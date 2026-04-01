import Foundation

enum SupportedLanguage: String, CaseIterable, Identifiable, Codable, Sendable, Comparable {
    // Core languages
    case chinese
    case english
    case german

    // Extended (Whisper + Cohere shared)
    case arabic
    case french
    case spanish
    case italian
    case japanese
    case korean
    case dutch
    case polish
    case portuguese
    case russian
    case turkish
    case vietnamese
    case greek
    case hindi
    case thai
    case swedish
    case danish
    case norwegian
    case finnish
    case czech
    case hungarian
    case indonesian
    case ukrainian

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .chinese: "中文"
        case .english: "English"
        case .german: "Deutsch"
        case .arabic: "العربية"
        case .french: "Français"
        case .spanish: "Español"
        case .italian: "Italiano"
        case .japanese: "日本語"
        case .korean: "한국어"
        case .dutch: "Nederlands"
        case .polish: "Polski"
        case .portuguese: "Português"
        case .russian: "Русский"
        case .turkish: "Türkçe"
        case .vietnamese: "Tiếng Việt"
        case .greek: "Ελληνικά"
        case .hindi: "हिन्दी"
        case .thai: "ไทย"
        case .swedish: "Svenska"
        case .danish: "Dansk"
        case .norwegian: "Norsk"
        case .finnish: "Suomi"
        case .czech: "Čeština"
        case .hungarian: "Magyar"
        case .indonesian: "Bahasa Indonesia"
        case .ukrainian: "Українська"
        }
    }

    var flag: String {
        switch self {
        case .chinese: "🇨🇳"
        case .english: "🇬🇧"
        case .german: "🇩🇪"
        case .arabic: "🇸🇦"
        case .french: "🇫🇷"
        case .spanish: "🇪🇸"
        case .italian: "🇮🇹"
        case .japanese: "🇯🇵"
        case .korean: "🇰🇷"
        case .dutch: "🇳🇱"
        case .polish: "🇵🇱"
        case .portuguese: "🇧🇷"
        case .russian: "🇷🇺"
        case .turkish: "🇹🇷"
        case .vietnamese: "🇻🇳"
        case .greek: "🇬🇷"
        case .hindi: "🇮🇳"
        case .thai: "🇹🇭"
        case .swedish: "🇸🇪"
        case .danish: "🇩🇰"
        case .norwegian: "🇳🇴"
        case .finnish: "🇫🇮"
        case .czech: "🇨🇿"
        case .hungarian: "🇭🇺"
        case .indonesian: "🇮🇩"
        case .ukrainian: "🇺🇦"
        }
    }

    var localeIdentifier: String {
        switch self {
        case .chinese: "zh-CN"
        case .english: "en-US"
        case .german: "de-DE"
        case .arabic: "ar-SA"
        case .french: "fr-FR"
        case .spanish: "es-ES"
        case .italian: "it-IT"
        case .japanese: "ja-JP"
        case .korean: "ko-KR"
        case .dutch: "nl-NL"
        case .polish: "pl-PL"
        case .portuguese: "pt-BR"
        case .russian: "ru-RU"
        case .turkish: "tr-TR"
        case .vietnamese: "vi-VN"
        case .greek: "el-GR"
        case .hindi: "hi-IN"
        case .thai: "th-TH"
        case .swedish: "sv-SE"
        case .danish: "da-DK"
        case .norwegian: "nb-NO"
        case .finnish: "fi-FI"
        case .czech: "cs-CZ"
        case .hungarian: "hu-HU"
        case .indonesian: "id-ID"
        case .ukrainian: "uk-UA"
        }
    }

    /// BCP 47 language tag for Apple Translation framework
    var translationLanguageCode: String {
        switch self {
        case .chinese: "zh-Hans"
        case .english: "en"
        case .german: "de"
        case .arabic: "ar"
        case .french: "fr"
        case .spanish: "es"
        case .italian: "it"
        case .japanese: "ja"
        case .korean: "ko"
        case .dutch: "nl"
        case .polish: "pl"
        case .portuguese: "pt"
        case .russian: "ru"
        case .turkish: "tr"
        case .vietnamese: "vi"
        case .greek: "el"
        case .hindi: "hi"
        case .thai: "th"
        case .swedish: "sv"
        case .danish: "da"
        case .norwegian: "nb"
        case .finnish: "fi"
        case .czech: "cs"
        case .hungarian: "hu"
        case .indonesian: "id"
        case .ukrainian: "uk"
        }
    }

    var whisperCode: String {
        switch self {
        case .chinese: "zh"
        case .english: "en"
        case .german: "de"
        case .arabic: "ar"
        case .french: "fr"
        case .spanish: "es"
        case .italian: "it"
        case .japanese: "ja"
        case .korean: "ko"
        case .dutch: "nl"
        case .polish: "pl"
        case .portuguese: "pt"
        case .russian: "ru"
        case .turkish: "tr"
        case .vietnamese: "vi"
        case .greek: "el"
        case .hindi: "hi"
        case .thai: "th"
        case .swedish: "sv"
        case .danish: "da"
        case .norwegian: "no"
        case .finnish: "fi"
        case .czech: "cs"
        case .hungarian: "hu"
        case .indonesian: "id"
        case .ukrainian: "uk"
        }
    }

    /// NLLB-200 language codes (flores-200 format)
    var nllbCode: String {
        switch self {
        case .chinese: "zho_Hans"
        case .english: "eng_Latn"
        case .german: "deu_Latn"
        case .arabic: "arb_Arab"
        case .french: "fra_Latn"
        case .spanish: "spa_Latn"
        case .italian: "ita_Latn"
        case .japanese: "jpn_Jpan"
        case .korean: "kor_Hang"
        case .dutch: "nld_Latn"
        case .polish: "pol_Latn"
        case .portuguese: "por_Latn"
        case .russian: "rus_Cyrl"
        case .turkish: "tur_Latn"
        case .vietnamese: "vie_Latn"
        case .greek: "ell_Grek"
        case .hindi: "hin_Deva"
        case .thai: "tha_Thai"
        case .swedish: "swe_Latn"
        case .danish: "dan_Latn"
        case .norwegian: "nob_Latn"
        case .finnish: "fin_Latn"
        case .czech: "ces_Latn"
        case .hungarian: "hun_Latn"
        case .indonesian: "ind_Latn"
        case .ukrainian: "ukr_Cyrl"
        }
    }

    static func < (lhs: SupportedLanguage, rhs: SupportedLanguage) -> Bool {
        lhs.displayName.localizedCompare(rhs.displayName) == .orderedAscending
    }

    /// Default 3 languages for the quick selector
    static let defaultActiveLanguages: [SupportedLanguage] = [.chinese, .english, .german]
}
