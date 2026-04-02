import AVFoundation
import Observation

@Observable
@MainActor
final class WatchAudioRecorder {
    private(set) var isRecording = false
    private var audioEngine: AVAudioEngine?
    private var audioBuffer: [Float] = []
    private let lock = NSLock()

    func startCapture() throws {
        guard !isRecording else { return }

        lock.lock()
        audioBuffer = []
        lock.unlock()

        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.record, mode: .default)
        try session.setActive(true)

        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        let nativeFormat = inputNode.outputFormat(forBus: 0)

        print("[WatchRecorder] Native format: \(nativeFormat.sampleRate)Hz, \(nativeFormat.channelCount)ch")

        guard nativeFormat.sampleRate > 0, nativeFormat.channelCount > 0 else {
            throw WatchRecorderError.audioFormatInvalid
        }

        let maxSamples = Int(nativeFormat.sampleRate * 30) // 30 seconds max

        inputNode.installTap(onBus: 0, bufferSize: 4096, format: nativeFormat) { [weak self] buffer, _ in
            guard let self else { return }
            guard let channelData = buffer.floatChannelData?[0] else { return }
            let frameCount = Int(buffer.frameLength)
            guard frameCount > 0 else { return }
            let samples = Array(UnsafeBufferPointer(start: channelData, count: frameCount))
            self.lock.lock()
            if self.audioBuffer.count < maxSamples {
                self.audioBuffer.append(contentsOf: samples)
            }
            self.lock.unlock()
        }

        engine.prepare()
        try engine.start()
        audioEngine = engine
        isRecording = true
        print("[WatchRecorder] Started recording")
    }

    func stopCapture() -> [Float] {
        guard isRecording else { return [] }

        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine?.stop()
        audioEngine = nil
        isRecording = false

        lock.lock()
        let result = audioBuffer
        audioBuffer = []
        lock.unlock()

        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        print("[WatchRecorder] Stopped, captured \(result.count) samples")
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
