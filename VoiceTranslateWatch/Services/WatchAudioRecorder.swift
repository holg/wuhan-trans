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

        inputNode.installTap(onBus: 0, bufferSize: 4096, format: nativeFormat) { [weak self] buffer, _ in
            guard let self else { return }
            let channelData = buffer.floatChannelData![0]
            let frameCount = Int(buffer.frameLength)
            let samples = Array(UnsafeBufferPointer(start: channelData, count: frameCount))
            Task { @MainActor in
                self.audioBuffer.append(contentsOf: samples)
            }
        }

        engine.prepare()
        try engine.start()
        audioEngine = engine
        isRecording = true
    }

    func stopCapture() -> [Float] {
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine?.stop()
        audioEngine = nil
        isRecording = false
        try? AVAudioSession.sharedInstance().setActive(false)
        return audioBuffer
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
