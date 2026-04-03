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

    /// Send compressed audio file to phone for ASR + translation
    func sendAudioFile(_ fileURL: URL, source: SupportedLanguage, target: SupportedLanguage) {
        guard let session, session.isReachable else {
            errorMessage = "iPhone not reachable"
            translator?.isProcessing = false
            return
        }
        errorMessage = nil

        let size = (try? FileManager.default.attributesOfItem(atPath: fileURL.path())[.size] as? Int) ?? 0
        WatchCrashLog.log("sendAudio: \(size / 1024) KB, \(source.rawValue)→\(target.rawValue)")

        let metadata: [String: Any] = [
            "type": "audioFile",
            "source": source.rawValue,
            "target": target.rawValue,
            "format": "m4a"
        ]

        session.transferFile(fileURL, metadata: metadata)
    }

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
        session.sendMessage(["type": "crashlog", "log": log], replyHandler: nil, errorHandler: nil)
    }
}

extension WatchConnectivityClient: WCSessionDelegate {
    nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        let reachable = session.isReachable
        Task { @MainActor in self.isReachable = reachable }
    }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        let reachable = session.isReachable
        Task { @MainActor in
            self.isReachable = reachable
            if reachable { self.sendCrashLog() }
        }
    }

    // Receive translation result or language sync from phone
    nonisolated func session(_ session: WCSession, didReceiveMessageData messageData: Data) {
        guard let msg = try? WatchMessage.decode(from: messageData) else { return }

        switch msg.type {
        case .translationResult:
            guard let result = try? JSONDecoder().decode(TranslationResultPayload.self, from: msg.payload) else {
                Task { @MainActor in self.translator?.translationFailed("Bad response") }
                return
            }
            Task { @MainActor in
                self.translator?.didReceiveTranslation(result.message)
            }
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

    // File transfer finished
    nonisolated func session(_ session: WCSession, didFinish fileTransfer: WCSessionFileTransfer, error: Error?) {
        WatchCrashLog.log("transfer done, error=\(error?.localizedDescription ?? "none")")
        if let error {
            Task { @MainActor in
                self.translator?.translationFailed("Send failed: \(error.localizedDescription)")
            }
        }
        // Timeout: if no translation in 30s, reset
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(30))
            if self.translator?.isProcessing == true {
                self.translator?.translationFailed("Translation timed out")
            }
        }
        try? FileManager.default.removeItem(at: fileTransfer.file.fileURL)
    }
}
