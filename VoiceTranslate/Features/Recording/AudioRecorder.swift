import AVFoundation
import Observation

@Observable
@MainActor
final class AudioRecorder {
    private(set) var isRecording = false
    private var audioEngine: AVAudioEngine?
    private var audioBuffer: [Float] = []

    func startCapture() throws {
        guard !isRecording else { return }
        audioBuffer = []

        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16000,
            channels: 1,
            interleaved: false
        )!

        inputNode.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
            let channelData = buffer.floatChannelData![0]
            let frameCount = Int(buffer.frameLength)
            let samples = Array(UnsafeBufferPointer(start: channelData, count: frameCount))
            Task { @MainActor in
                self?.audioBuffer.append(contentsOf: samples)
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
        return audioBuffer
    }
}
