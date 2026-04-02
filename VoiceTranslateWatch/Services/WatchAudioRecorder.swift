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
        WatchCrashLog.log("startCapture: begin")

        lock.lock()
        audioBuffer = []
        lock.unlock()

        do {
            let session = AVAudioSession.sharedInstance()
            WatchCrashLog.log("startCapture: setCategory")
            try session.setCategory(.record, mode: .default)
            WatchCrashLog.log("startCapture: setActive")
            try session.setActive(true)
        } catch {
            WatchCrashLog.log("startCapture: audio session failed: \(error)")
            throw error
        }

        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        let nativeFormat = inputNode.outputFormat(forBus: 0)
        WatchCrashLog.log("startCapture: format=\(nativeFormat.sampleRate)Hz \(nativeFormat.channelCount)ch")

        guard nativeFormat.sampleRate > 0, nativeFormat.channelCount > 0 else {
            WatchCrashLog.log("startCapture: INVALID FORMAT")
            throw WatchRecorderError.audioFormatInvalid
        }

        let maxSamples = Int(nativeFormat.sampleRate * 30)

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

        WatchCrashLog.log("startCapture: prepare + start engine")
        do {
            engine.prepare()
            try engine.start()
        } catch {
            WatchCrashLog.log("startCapture: engine start failed: \(error)")
            throw error
        }

        audioEngine = engine
        isRecording = true
        WatchCrashLog.log("startCapture: recording started OK")
    }

    func stopCapture() -> [Float] {
        WatchCrashLog.log("stopCapture: begin, isRecording=\(isRecording)")
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
        WatchCrashLog.log("stopCapture: \(result.count) samples captured")
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
