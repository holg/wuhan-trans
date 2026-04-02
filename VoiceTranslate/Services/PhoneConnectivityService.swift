#if os(iOS)
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

    nonisolated func session(_ session: WCSession, didReceive file: WCSessionFile) {
        guard let metadata = file.metadata,
              let type = metadata["type"] as? String, type == "audio",
              let sourceRaw = metadata["source"] as? String,
              let targetRaw = metadata["target"] as? String,
              let source = SupportedLanguage(rawValue: sourceRaw),
              let target = SupportedLanguage(rawValue: targetRaw) else {
            print("[PhoneWC] Received file with invalid metadata")
            Task { @MainActor in self.lastEvent = "Received file: invalid metadata" }
            return
        }

        guard let audioData = try? Data(contentsOf: file.fileURL) else {
            print("[PhoneWC] Failed to read audio file")
            Task { @MainActor in self.lastEvent = "Received file: read failed" }
            return
        }

        let samples = audioData.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        print("[PhoneWC] Received \(samples.count) samples (\(audioData.count / 1024) KB) from watch, \(source.rawValue)→\(target.rawValue)")

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
}
#endif
