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
    var errorMessage: String?

    private var session: WCSession?

    override init() {
        super.init()
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        session.delegate = self
        session.activate()
        self.session = session
    }

    func sendCrashLog() {
        guard let session, session.isReachable else { return }
        let log = WatchCrashLog.read()
        let context: [String: Any] = ["type": "crashlog", "log": log]
        session.sendMessage(context, replyHandler: nil, errorHandler: nil)
    }

    func sendAudioFile(_ fileURL: URL, source: SupportedLanguage, target: SupportedLanguage) {
        WatchCrashLog.log("sendAudio: \(source.rawValue)→\(target.rawValue)")

        guard let session, session.isReachable else {
            errorMessage = "iPhone not reachable"
            WatchCrashLog.log("sendAudio: iPhone not reachable")
            return
        }

        let size = (try? FileManager.default.attributesOfItem(atPath: fileURL.path())[.size] as? Int) ?? 0
        WatchCrashLog.log("sendAudio: file size = \(size / 1024) KB")

        isSending = true
        errorMessage = nil

        let metadata: [String: Any] = [
            "type": "audioFile",
            "source": source.rawValue,
            "target": target.rawValue,
            "format": "m4a"
        ]

        WatchCrashLog.log("sendAudio: transferring...")
        session.transferFile(fileURL, metadata: metadata)
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

    // Receive translation results from phone
    nonisolated func session(_ session: WCSession, didReceiveMessageData messageData: Data) {
        guard let msg = try? WatchMessage.decode(from: messageData) else { return }

        switch msg.type {
        case .translationResult:
            guard let result = try? JSONDecoder().decode(TranslationResultPayload.self, from: msg.payload) else { return }
            Task { @MainActor in
                self.receivedMessages.append(result.message)
                self.isSending = false
                WKInterfaceDevice.current().play(.notification)
            }
        case .languageSync:
            guard let sync = try? JSONDecoder().decode(LanguageSyncPayload.self, from: msg.payload) else { return }
            Task { @MainActor in
                self.sourceLanguage = sync.sourceLanguage
                self.targetLanguage = sync.targetLanguage
            }
        case .audioData:
            break
        }
    }

    // Receive confirmation that file was delivered
    nonisolated func session(_ session: WCSession, didFinish fileTransfer: WCSessionFileTransfer, error: Error?) {
        if let error {
            Task { @MainActor in
                self.isSending = false
                self.errorMessage = "Send failed: \(error.localizedDescription)"
            }
        }
        // Clean up temp file
        try? FileManager.default.removeItem(at: fileTransfer.file.fileURL)
    }
}
