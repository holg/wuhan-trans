import Foundation
import Observation
import WatchConnectivity
import WatchKit

@Observable
@MainActor
final class WatchConnectivityClient: NSObject {
    var isReachable = false
    var errorMessage: String?

    weak var translator: WatchTranslator?
    private var session: WCSession?

    override init() {
        super.init()
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        session.delegate = self
        session.activate()
        self.session = session
    }

    /// Send dictated text to phone for translation (tiny payload, very fast)
    func sendTextForTranslation(_ text: String, source: SupportedLanguage, target: SupportedLanguage) {
        guard let session, session.isReachable else {
            errorMessage = "iPhone not reachable"
            return
        }
        errorMessage = nil

        let payload: [String: String] = [
            "type": "translateText",
            "text": text,
            "source": source.rawValue,
            "target": target.rawValue,
        ]

        // Use sendMessage for instant delivery (text is ~100 bytes)
        session.sendMessage(payload, replyHandler: { [weak self] reply in
            // Reply contains the translation result
            guard let resultJSON = reply["result"] as? String,
                  let data = resultJSON.data(using: .utf8),
                  let message = try? JSONDecoder().decode(ConversationMessage.self, from: data) else {
                Task { @MainActor in
                    self?.translator?.translationFailed("Invalid response from iPhone")
                }
                return
            }
            Task { @MainActor in
                self?.translator?.didReceiveTranslation(message)
            }
        }, errorHandler: { [weak self] error in
            Task { @MainActor in
                self?.translator?.translationFailed(error.localizedDescription)
            }
        })
    }

    /// Sync a completed translation to the phone (best effort)
    func syncMessage(_ message: ConversationMessage) {
        guard let session, session.isReachable else { return }
        let payload = TranslationResultPayload(message: message)
        guard let payloadData = try? JSONEncoder().encode(payload),
              let msgData = try? WatchMessage(type: .translationResult, payload: payloadData).encode() else { return }
        session.sendMessageData(msgData, replyHandler: nil, errorHandler: nil)
    }

    func sendCrashLog() {
        guard let session, session.isReachable else { return }
        let log = WatchCrashLog.read()
        let context: [String: Any] = ["type": "crashlog", "log": log]
        session.sendMessage(context, replyHandler: nil, errorHandler: nil)
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
            if reachable {
                self.sendCrashLog()
            }
        }
    }

    // Receive language sync from phone
    nonisolated func session(_ session: WCSession, didReceiveMessageData messageData: Data) {
        guard let msg = try? WatchMessage.decode(from: messageData) else { return }

        switch msg.type {
        case .languageSync:
            guard let sync = try? JSONDecoder().decode(LanguageSyncPayload.self, from: msg.payload) else { return }
            Task { @MainActor in
                self.translator?.setSourceLanguage(sync.sourceLanguage)
                self.translator?.setTargetLanguage(sync.targetLanguage)
            }
        default:
            break
        }
    }
}
