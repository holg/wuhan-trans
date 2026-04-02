import AVFoundation
import Observation

/// Records audio on watch to a compressed file, then provides the file URL for transfer.
@Observable
@MainActor
final class WatchAudioRecorder {
    private(set) var isRecording = false
    private var audioRecorder: AVAudioRecorder?
    private let recordingURL: URL

    init() {
        recordingURL = FileManager.default.temporaryDirectory.appending(path: "watch_recording.m4a")
    }

    func startCapture() throws {
        guard !isRecording else { return }
        WatchCrashLog.log("startCapture: begin")

        // Clean up old recording
        try? FileManager.default.removeItem(at: recordingURL)

        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.record, mode: .default)
        try session.setActive(true)
        WatchCrashLog.log("startCapture: audio session active")

        // Record as compressed AAC — much smaller than raw PCM
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 16000,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
        ]

        let recorder = try AVAudioRecorder(url: recordingURL, settings: settings)
        recorder.record(forDuration: 30) // max 30 seconds
        audioRecorder = recorder
        isRecording = true
        WatchCrashLog.log("startCapture: recording started OK")
    }

    /// Stop recording and return the URL of the compressed audio file
    func stopCapture() -> URL? {
        WatchCrashLog.log("stopCapture: begin")
        guard isRecording, let recorder = audioRecorder else { return nil }

        recorder.stop()
        audioRecorder = nil
        isRecording = false

        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)

        guard FileManager.default.fileExists(atPath: recordingURL.path()) else {
            WatchCrashLog.log("stopCapture: no file created")
            return nil
        }

        let size = (try? FileManager.default.attributesOfItem(atPath: recordingURL.path())[.size] as? Int) ?? 0
        WatchCrashLog.log("stopCapture: file size = \(size / 1024) KB")
        return recordingURL
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
