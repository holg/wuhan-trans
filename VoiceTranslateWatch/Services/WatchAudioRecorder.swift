import AVFoundation
import Observation

@Observable
@MainActor
final class WatchAudioRecorder {
    private(set) var isRecording = false
    private var audioEngine: AVAudioEngine?
    private var audioBuffer: [Float] = []

    func startCapture() throws {
        guard !isRecording else { return }
        audioBuffer = []

        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.record, mode: .default)
        try session.setActive(true)

        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        let nativeFormat = inputNode.outputFormat(forBus: 0)

        guard nativeFormat.sampleRate > 0, nativeFormat.channelCount > 0 else {
            throw WatchRecorderError.audioFormatInvalid
        }

        // Watch mic is typically 16kHz or 44.1kHz mono
        // Record in native format, we'll send raw and let the phone handle resampling if needed
        let sampleRate = nativeFormat.sampleRate
        let maxSeconds = 30.0
        let maxSamples = Int(sampleRate * maxSeconds)

        inputNode.installTap(onBus: 0, bufferSize: 4096, format: nativeFormat) { [weak self] buffer, _ in
            guard let channelData = buffer.floatChannelData?[0] else { return }
            let frameCount = Int(buffer.frameLength)
            let samples = Array(UnsafeBufferPointer(start: channelData, count: frameCount))
            Task { @MainActor in
                guard let self, self.isRecording else { return }
                if self.audioBuffer.count < maxSamples {
                    self.audioBuffer.append(contentsOf: samples)
                }
            }
        }

        engine.prepare()
        try engine.start()
        audioEngine = engine
        isRecording = true
    }

    func stopCapture() -> [Float] {
        guard isRecording else { return [] }
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine?.stop()
        audioEngine = nil
        isRecording = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        let result = audioBuffer
        audioBuffer = []
        return result
    }
}

enum WatchRecorderError: Error, LocalizedError {
    case audioFormatInvalid

    var errorDescription: String? {
        switch self {
        case .audioFormatInvalid: "Watch microphone unavailable"
        }
    }
}
