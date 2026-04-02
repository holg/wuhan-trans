import Foundation

protocol ASRService: AnyObject, Sendable {
    func startRecording(language: SupportedLanguage) async throws
    func stopRecording() async throws -> String
    var isRecording: Bool { get }

    /// Transcribe pre-recorded audio samples (e.g. from Apple Watch)
    func transcribe(samples: [Float], language: SupportedLanguage) async throws -> String
}
