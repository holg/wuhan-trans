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

    private func sendTranslationResult(_ message: ConversationMessage, via replyHandler: @escaping (Data) -> Void) {
        let payload = TranslationResultPayload(message: message)
        guard let payloadData = try? JSONEncoder().encode(payload),
              let msgData = try? WatchMessage(type: .translationResult, payload: payloadData).encode() else { return }
        replyHandler(msgData)
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

    nonisolated func session(_ session: WCSession, didReceiveMessageData messageData: Data, replyHandler: @escaping (Data) -> Void) {
        guard let msg = try? WatchMessage.decode(from: messageData),
              msg.type == .audioData,
              let audioPayload = try? JSONDecoder().decode(AudioPayload.self, from: msg.payload) else {
            return
        }

        let samples = audioPayload.floatSamples()
        let source = audioPayload.sourceLanguage
        let target = audioPayload.targetLanguage
        nonisolated(unsafe) let reply = replyHandler

        Task { @MainActor in
            guard let vm = self.viewModel else { return }
            do {
                let message = try await vm.processWatchAudio(
                    samples: samples,
                    sourceLanguage: source,
                    targetLanguage: target
                )
                self.sendTranslationResult(message, via: reply)
            } catch {
                print("[Phone] Watch audio processing failed: \(error.localizedDescription)")
            }
        }
    }
}

#else
// macOS stub — no WatchConnectivity
import Foundation
import Observation

@Observable
@MainActor
final class PhoneConnectivityService: NSObject {
    var isWatchReachable = false
    weak var viewModel: ConversationViewModel?
}
#endif
