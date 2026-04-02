#if os(iOS)
import Foundation
import Observation
import WatchConnectivity

@Observable
@MainActor
final class PhoneConnectivityService: NSObject {
    var isWatchReachable = false
    weak var viewModel: ConversationViewModel?

    private var session: WCSession?

    override init() {
        super.init()
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        session.delegate = self
        session.activate()
        self.session = session
    }

    func syncLanguages(source: SupportedLanguage, target: SupportedLanguage) {
        guard let session, session.isReachable else { return }
        let payload = LanguageSyncPayload(sourceLanguage: source, targetLanguage: target)
        guard let payloadData = try? JSONEncoder().encode(payload),
              let msgData = try? WatchMessage(type: .languageSync, payload: payloadData).encode() else { return }
        session.sendMessageData(msgData, replyHandler: nil, errorHandler: nil)
    }

    private func sendTranslationToWatch(_ message: ConversationMessage) {
        guard let session, session.isReachable else { return }
        let payload = TranslationResultPayload(message: message)
        guard let payloadData = try? JSONEncoder().encode(payload),
              let msgData = try? WatchMessage(type: .translationResult, payload: payloadData).encode() else { return }
        session.sendMessageData(msgData, replyHandler: nil, errorHandler: nil)
    }
}

extension PhoneConnectivityService: WCSessionDelegate {
    nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        let reachable = session.isReachable
        Task { @MainActor in
            self.isWatchReachable = reachable
        }
    }

    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}
    nonisolated func sessionDidDeactivate(_ session: WCSession) {
        session.activate()
    }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        let reachable = session.isReachable
        Task { @MainActor in
            self.isWatchReachable = reachable
            if reachable, let vm = self.viewModel {
                self.syncLanguages(source: vm.sourceLanguage, target: vm.targetLanguage)
            }
        }
    }

    // Receive audio file from watch
    nonisolated func session(_ session: WCSession, didReceive file: WCSessionFile) {
        guard let metadata = file.metadata,
              let type = metadata["type"] as? String, type == "audio",
              let sourceRaw = metadata["source"] as? String,
              let targetRaw = metadata["target"] as? String,
              let source = SupportedLanguage(rawValue: sourceRaw),
              let target = SupportedLanguage(rawValue: targetRaw) else {
            return
        }

        // Read audio data from file
        guard let audioData = try? Data(contentsOf: file.fileURL) else { return }
        let samples = audioData.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }

        print("[Phone] Received \(samples.count) samples from watch")

        Task { @MainActor in
            guard let vm = self.viewModel else { return }
            do {
                let message = try await vm.processWatchAudio(
                    samples: samples,
                    sourceLanguage: source,
                    targetLanguage: target
                )
                self.sendTranslationToWatch(message)
            } catch {
                print("[Phone] Watch audio processing failed: \(error.localizedDescription)")
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
    weak var viewModel: ConversationViewModel?
}
#endif
