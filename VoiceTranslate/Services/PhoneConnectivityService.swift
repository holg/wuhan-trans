#if os(iOS)
import AVFoundation
import Foundation
import Observation
import WatchConnectivity

@Observable
@MainActor
final class PhoneConnectivityService: NSObject {
    var isWatchReachable = false
    var isWatchPaired = false
    var isWatchAppInstalled = false
    var activationState: String = "unknown"
    var lastEvent: String = "none"
    var receivedAudioCount = 0
    var lastAudioSamples = 0
    var lastError: String?

    weak var viewModel: ConversationViewModel?

    private var session: WCSession?

    override init() {
        super.init()
        guard WCSession.isSupported() else {
            activationState = "WCSession not supported"
            return
        }
        let session = WCSession.default
        session.delegate = self
        session.activate()
        self.session = session
        activationState = "activating..."
    }

    func syncLanguages(source: SupportedLanguage, target: SupportedLanguage) {
        guard let session, session.isReachable else { return }
        let payload = LanguageSyncPayload(sourceLanguage: source, targetLanguage: target)
        guard let payloadData = try? JSONEncoder().encode(payload),
              let msgData = try? WatchMessage(type: .languageSync, payload: payloadData).encode() else { return }
        session.sendMessageData(msgData, replyHandler: nil, errorHandler: nil)
        lastEvent = "Synced languages → watch"
    }

    private func sendTranslationToWatch(_ message: ConversationMessage) {
        guard let session, session.isReachable else { return }
        let payload = TranslationResultPayload(message: message)
        guard let payloadData = try? JSONEncoder().encode(payload),
              let msgData = try? WatchMessage(type: .translationResult, payload: payloadData).encode() else { return }
        session.sendMessageData(msgData, replyHandler: nil, errorHandler: nil)
        lastEvent = "Sent translation → watch"
    }

    private func updateSessionInfo() {
        guard let session else { return }
        isWatchPaired = session.isPaired
        isWatchAppInstalled = session.isWatchAppInstalled
        isWatchReachable = session.isReachable
    }
}

extension PhoneConnectivityService: WCSessionDelegate {
    nonisolated func session(_ session: WCSession, activationDidCompleteWith state: WCSessionActivationState, error: Error?) {
        let reachable = session.isReachable
        let paired = session.isPaired
        let installed = session.isWatchAppInstalled
        let stateStr: String
        switch state {
        case .activated: stateStr = "activated"
        case .inactive: stateStr = "inactive"
        case .notActivated: stateStr = "notActivated"
        @unknown default: stateStr = "unknown"
        }
        let errStr = error?.localizedDescription

        print("[PhoneWC] Activation: \(stateStr), paired=\(paired), installed=\(installed), reachable=\(reachable), error=\(errStr ?? "none")")

        Task { @MainActor in
            self.activationState = stateStr
            self.isWatchReachable = reachable
            self.isWatchPaired = paired
            self.isWatchAppInstalled = installed
            self.lastError = errStr
            self.lastEvent = "Activation: \(stateStr)"
            if reachable, let vm = self.viewModel {
                self.syncLanguages(source: vm.sourceLanguage, target: vm.targetLanguage)
            }
        }
    }

    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {
        print("[PhoneWC] Session became inactive")
        Task { @MainActor in
            self.activationState = "inactive"
            self.lastEvent = "Session inactive"
        }
    }

    nonisolated func sessionDidDeactivate(_ session: WCSession) {
        print("[PhoneWC] Session deactivated, reactivating...")
        session.activate()
        Task { @MainActor in
            self.activationState = "reactivating..."
            self.lastEvent = "Session deactivated → reactivating"
        }
    }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        let reachable = session.isReachable
        print("[PhoneWC] Reachability changed: \(reachable)")
        Task { @MainActor in
            self.isWatchReachable = reachable
            self.lastEvent = "Reachability: \(reachable)"
            if reachable, let vm = self.viewModel {
                self.syncLanguages(source: vm.sourceLanguage, target: vm.targetLanguage)
            }
        }
    }

    // Receive text-for-translation from watch (dictation mode)
    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any], replyHandler: @escaping ([String: Any]) -> Void) {
        guard let type = message["type"] as? String else { return }

        if type == "translateText",
           let text = message["text"] as? String,
           let sourceRaw = message["source"] as? String,
           let targetRaw = message["target"] as? String,
           let source = SupportedLanguage(rawValue: sourceRaw),
           let target = SupportedLanguage(rawValue: targetRaw) {
            nonisolated(unsafe) let reply = replyHandler
            print("[PhoneWC] Watch dictation: \"\(text.prefix(50))\" \(source.rawValue)→\(target.rawValue)")
            Task { @MainActor in
                self.lastEvent = "Watch text: \(text.prefix(30))"
                guard let vm = self.viewModel else {
                    reply(["error": "ViewModel not ready"])
                    return
                }
                do {
                    // Use the existing translation session on the phone
                    guard let ts = vm.translationSession else {
                        reply(["error": "Translation not ready"])
                        return
                    }
                    nonisolated(unsafe) let s = ts
                    let response = try await s.translate(text)

                    let msg = ConversationMessage(
                        originalText: text,
                        translatedText: response.targetText,
                        sourceLanguage: source,
                        targetLanguage: target,
                        isRemote: true
                    )
                    vm.messages.append(msg)

                    // Send result back to watch
                    if let data = try? JSONEncoder().encode(msg) {
                        reply(["result": String(data: data, encoding: .utf8) ?? ""])
                    }

                    // TTS on phone too
                    self.lastEvent = "Translated for watch: \(response.targetText.prefix(30))"
                } catch {
                    reply(["error": error.localizedDescription])
                    self.lastEvent = "Watch translation failed: \(error.localizedDescription)"
                }
            }
        }
    }

    // Receive synced translation from watch
    nonisolated func session(_ session: WCSession, didReceiveMessageData messageData: Data) {
        guard let msg = try? WatchMessage.decode(from: messageData),
              msg.type == .translationResult,
              let result = try? JSONDecoder().decode(TranslationResultPayload.self, from: msg.payload) else {
            return
        }
        print("[PhoneWC] Received synced translation from watch")
        Task { @MainActor in
            self.lastEvent = "Watch sync: translation received"
            // Add to conversation on the phone
            let message = ConversationMessage(
                id: result.message.id,
                originalText: result.message.originalText,
                translatedText: result.message.translatedText,
                sourceLanguage: result.message.sourceLanguage,
                targetLanguage: result.message.targetLanguage,
                timestamp: result.message.timestamp,
                isRemote: true
            )
            self.viewModel?.messages.append(message)
        }
    }

    // Receive audio file from watch (legacy connected mode)
    nonisolated func session(_ session: WCSession, didReceive file: WCSessionFile) {
        guard let metadata = file.metadata,
              let type = metadata["type"] as? String,
              (type == "audio" || type == "audioFile"),
              let sourceRaw = metadata["source"] as? String,
              let targetRaw = metadata["target"] as? String,
              let source = SupportedLanguage(rawValue: sourceRaw),
              let target = SupportedLanguage(rawValue: targetRaw) else {
            print("[PhoneWC] Received file with invalid metadata: \(file.metadata ?? [:])")
            Task { @MainActor in self.lastEvent = "Received file: invalid metadata" }
            return
        }

        let format = metadata["format"] as? String ?? "pcm"
        print("[PhoneWC] Received \(format) audio from watch")

        let samples: [Float]
        if format == "m4a" {
            guard let decoded = Self.decodeAudioFile(file.fileURL) else {
                print("[PhoneWC] Failed to decode M4A")
                Task { @MainActor in self.lastEvent = "Decode M4A failed" }
                return
            }
            samples = decoded
        } else {
            guard let audioData = try? Data(contentsOf: file.fileURL) else {
                print("[PhoneWC] Failed to read audio file")
                Task { @MainActor in self.lastEvent = "Read file failed" }
                return
            }
            samples = audioData.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        }
        print("[PhoneWC] Decoded \(samples.count) samples from watch")

        Task { @MainActor in
            self.receivedAudioCount += 1
            self.lastAudioSamples = samples.count
            self.lastEvent = "Received audio: \(samples.count) samples"
            self.lastError = nil

            guard let vm = self.viewModel else {
                self.lastError = "ViewModel not connected"
                return
            }
            do {
                let message = try await vm.processWatchAudio(
                    samples: samples,
                    sourceLanguage: source,
                    targetLanguage: target
                )
                self.sendTranslationToWatch(message)
                self.lastEvent = "Processed + sent translation back"
            } catch {
                self.lastError = error.localizedDescription
                self.lastEvent = "Processing failed"
                print("[PhoneWC] Watch audio processing failed: \(error)")
            }
        }
    }

    /// Decode a compressed audio file (M4A/AAC) to Float32 PCM samples at 16kHz
    nonisolated static func decodeAudioFile(_ url: URL) -> [Float]? {
        guard let audioFile = try? AVAudioFile(forReading: url) else { return nil }
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(audioFile.length)) else { return nil }
        do {
            try audioFile.read(into: buffer)
        } catch {
            print("[PhoneWC] Audio decode error: \(error)")
            return nil
        }
        let channelData = buffer.floatChannelData![0]
        return Array(UnsafeBufferPointer(start: channelData, count: Int(buffer.frameLength)))
    }
}

#else
import Foundation
import Observation

@Observable
@MainActor
final class PhoneConnectivityService: NSObject {
    var isWatchReachable = false
    var isWatchPaired = false
    var isWatchAppInstalled = false
    var activationState: String = "macOS (no WatchConnectivity)"
    var lastEvent: String = "n/a"
    var receivedAudioCount = 0
    var lastAudioSamples = 0
    var lastError: String?
    weak var viewModel: ConversationViewModel?

    func syncLanguages(source: SupportedLanguage, target: SupportedLanguage) {}
}
#endif
