import AVFoundation
import Foundation
import Speech

final class AppleSpeechASR: ASRService, @unchecked Sendable {
    private var recognizer: SFSpeechRecognizer?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var audioEngine: AVAudioEngine?
    private var transcribedText = ""
    private(set) var isRecording = false

    func startRecording(language: SupportedLanguage) async throws {
        guard !isRecording else { return }

        cleanup()

        let status = SFSpeechRecognizer.authorizationStatus()
        if status == .notDetermined {
            await withCheckedContinuation { cont in
                SFSpeechRecognizer.requestAuthorization { _ in cont.resume() }
            }
        }

        guard SFSpeechRecognizer.authorizationStatus() == .authorized else {
            throw ASRError.notAuthorized
        }

        let locale = Locale(identifier: language.localeIdentifier)
        recognizer = SFSpeechRecognizer(locale: locale)
        guard let recognizer, recognizer.isAvailable else {
            throw ASRError.engineUnavailable
        }

        // Set audio session BEFORE creating AVAudioEngine
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetooth])
        try session.setActive(true, options: [])
        // Let the audio system settle after session change
        try await Task.sleep(for: .milliseconds(100))
        #endif

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.requiresOnDeviceRecognition = true
        recognitionRequest = request

        transcribedText = ""
        recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, _ in
            if let result {
                self?.transcribedText = result.bestTranscription.formattedString
            }
        }

        // Create engine AFTER audio session is configured
        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        let recordingFormat = inputNode.outputFormat(forBus: 0)

        guard recordingFormat.sampleRate > 0, recordingFormat.channelCount > 0 else {
            recognitionRequest?.endAudio()
            recognitionRequest = nil
            recognitionTask?.cancel()
            recognitionTask = nil
            throw ASRError.audioFormatInvalid
        }

        inputNode.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) { buffer, _ in
            request.append(buffer)
        }

        engine.prepare()
        try engine.start()
        self.audioEngine = engine
        isRecording = true
    }

    func stopRecording() async throws -> String {
        guard isRecording else { return "" }
        cleanup()

        // Let the recognition task finalize
        try? await Task.sleep(for: .milliseconds(300))

        return transcribedText
    }

    private func cleanup() {
        if let audioEngine {
            audioEngine.inputNode.removeTap(onBus: 0)
            audioEngine.stop()
            self.audioEngine = nil
        }
        recognitionRequest?.endAudio()
        recognitionRequest = nil
        recognitionTask?.cancel()
        recognitionTask = nil
        isRecording = false
    }

    func transcribe(samples: [Float], language: SupportedLanguage) async throws -> String {
        let locale = Locale(identifier: language.localeIdentifier)
        guard let recognizer = SFSpeechRecognizer(locale: locale), recognizer.isAvailable else {
            throw ASRError.engineUnavailable
        }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.requiresOnDeviceRecognition = true

        // Create PCM buffer from float samples
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count))!
        buffer.frameLength = AVAudioFrameCount(samples.count)
        let channelData = buffer.floatChannelData![0]
        for i in 0..<samples.count { channelData[i] = samples[i] }

        request.append(buffer)
        request.endAudio()

        return try await withCheckedThrowingContinuation { cont in
            recognizer.recognitionTask(with: request) { result, error in
                if let result, result.isFinal {
                    cont.resume(returning: result.bestTranscription.formattedString)
                } else if let error {
                    cont.resume(throwing: error)
                }
            }
        }
    }
}

enum ASRError: Error, LocalizedError {
    case notAuthorized
    case engineUnavailable
    case audioFormatInvalid

    var errorDescription: String? {
        switch self {
        case .notAuthorized: "Speech recognition not authorized"
        case .engineUnavailable: "Speech recognition engine unavailable"
        case .audioFormatInvalid: "Microphone audio format unavailable — try again"
        }
    }
}
