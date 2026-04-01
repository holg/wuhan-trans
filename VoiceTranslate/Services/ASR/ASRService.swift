import Foundation

protocol ASRService: AnyObject, Sendable {
    func startRecording(language: SupportedLanguage) async throws
    func stopRecording() async throws -> String
    var isRecording: Bool { get }
}
