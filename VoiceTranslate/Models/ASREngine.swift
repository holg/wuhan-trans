import Foundation

enum ASREngine: String, CaseIterable, Identifiable, Codable, Sendable {
    case appleSpeech
    case cohereTranscribe
    case whisperKitMedium
    case whisperKitLargeV3
    case whisperKitLargeV3Turbo
    case whisperKitBelleLargeZh

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .appleSpeech: "Apple Speech"
        case .cohereTranscribe: "Cohere Transcribe"
        case .whisperKitMedium: "Whisper Medium"
        case .whisperKitLargeV3: "Whisper Large v3"
        case .whisperKitLargeV3Turbo: "Whisper Large v3 Turbo"
        case .whisperKitBelleLargeZh: "Belle Large v3 Chinese"
        }
    }

    var modelDescription: String {
        switch self {
        case .appleSpeech: "OS-provided — No download"
        case .cohereTranscribe: "~1.4 GB — 14 languages, 6-bit CoreML"
        case .whisperKitMedium: "~500 MB — Good multilingual"
        case .whisperKitLargeV3: "~947 MB — Best accuracy (quantized)"
        case .whisperKitLargeV3Turbo: "~954 MB — Fast, near-best (quantized)"
        case .whisperKitBelleLargeZh: "~2.9 GB — Best Chinese accuracy"
        }
    }

    var requiresModelDownload: Bool {
        self != .appleSpeech
    }

    var isWhisperKit: Bool {
        switch self {
        case .whisperKitMedium, .whisperKitLargeV3, .whisperKitLargeV3Turbo, .whisperKitBelleLargeZh: true
        default: false
        }
    }

    /// WhisperKit model variant name
    var whisperKitModelName: String? {
        switch self {
        case .whisperKitMedium: "openai_whisper-medium"
        case .whisperKitLargeV3: "openai_whisper-large-v3_947MB"
        case .whisperKitLargeV3Turbo: "openai_whisper-large-v3_turbo_954MB"
        case .whisperKitBelleLargeZh: "BELLE-2_Belle-whisper-large-v3-zh"
        default: nil
        }
    }

    /// HuggingFace repo ID
    var huggingFaceRepo: String? {
        switch self {
        case .appleSpeech: nil
        case .cohereTranscribe: "holgt/cohere-transcribe-coreml-compiled"
        case .whisperKitMedium, .whisperKitLargeV3, .whisperKitLargeV3Turbo: "argmaxinc/whisperkit-coreml"
        case .whisperKitBelleLargeZh: "holgt/belle-whisper-large-v3-zh-coreml"
        }
    }

    /// Top-level items to download (files and directories)
    var modelFiles: [String] {
        switch self {
        case .appleSpeech: []
        case .cohereTranscribe: [
            "coreml_manifest.json",
            ".compiled/cohere_frontend.mlmodelc",
            ".compiled/cohere_encoder.mlmodelc",
            ".compiled/cohere_decoder_cached.mlmodelc",
            ".compiled/cohere_cross_kv_projector.mlmodelc",
            ".compiled/cohere_decoder_fullseq_masked.mlmodelc",
        ]
        case .whisperKitMedium, .whisperKitLargeV3, .whisperKitLargeV3Turbo, .whisperKitBelleLargeZh: []
        }
    }

    var localDirectoryName: String { rawValue }

    static var platformDefault: ASREngine { .appleSpeech }
}
