import Foundation
import Observation
import WatchConnectivity
import WatchKit

@Observable
@MainActor
final class WatchConnectivityClient: NSObject {
    var isReachable = false
    var receivedMessages: [ConversationMessage] = []
    var sourceLanguage: SupportedLanguage = .chinese
    var targetLanguage: SupportedLanguage = .english
    var isSending = false

    private var session: WCSession?

    override init() {
        super.init()
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        session.delegate = self
        session.activate()
        self.session = session
    }

    func sendAudio(_ samples: [Float], source: SupportedLanguage, target: SupportedLanguage) {
        guard let session, session.isReachable else { return }
        isSending = true

        let payload = AudioPayload(samples: samples, sourceLanguage: source, targetLanguage: target)
        guard let payloadData = try? JSONEncoder().encode(payload),
              let messageData = try? WatchMessage(type: .audioData, payload: payloadData).encode() else {
            isSending = false
            return
        }

        session.sendMessageData(messageData, replyHandler: { [weak self] replyData in
            guard let reply = try? WatchMessage.decode(from: replyData),
                  reply.type == .translationResult,
                  let result = try? JSONDecoder().decode(TranslationResultPayload.self, from: reply.payload) else {
                Task { @MainActor in self?.isSending = false }
                return
            }
            Task { @MainActor in
                self?.receivedMessages.append(result.message)
                self?.isSending = false
                WKInterfaceDevice.current().play(.notification)
            }
        }, errorHandler: { [weak self] error in
            print("[Watch] Send failed: \(error.localizedDescription)")
            Task { @MainActor in self?.isSending = false }
        })
    }
}

extension WatchConnectivityClient: WCSessionDelegate {
    nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        let reachable = session.isReachable
        Task { @MainActor in
            self.isReachable = reachable
        }
    }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        let reachable = session.isReachable
        Task { @MainActor in
            self.isReachable = reachable
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveMessageData messageData: Data) {
        guard let msg = try? WatchMessage.decode(from: messageData) else { return }

        switch msg.type {
        case .translationResult:
            guard let result = try? JSONDecoder().decode(TranslationResultPayload.self, from: msg.payload) else { return }
            Task { @MainActor in
                self.receivedMessages.append(result.message)
                WKInterfaceDevice.current().play(.notification)
            }
        case .languageSync:
            guard let sync = try? JSONDecoder().decode(LanguageSyncPayload.self, from: msg.payload) else { return }
            Task { @MainActor in
                self.sourceLanguage = sync.sourceLanguage
                self.targetLanguage = sync.targetLanguage
            }
        case .audioData:
            break // Watch doesn't receive audio
        }
    }
}
