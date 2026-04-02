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

    func sendAudio(_ samples: [Float], source: SupportedLanguage, target: SupportedLanguage) {
        guard let session, session.isReachable else {
            errorMessage = "iPhone not reachable"
            return
        }
        isSending = true
        errorMessage = nil

        // Send as dictionary message (more efficient than JSON-encoded Data)
        let audioData = samples.withUnsafeBytes { Data($0) }
        let metadata: [String: Any] = [
            "type": "audio",
            "source": source.rawValue,
            "target": target.rawValue,
            "sampleCount": samples.count
        ]

        // Use transferFile for large audio data
        let tempURL = FileManager.default.temporaryDirectory.appending(path: "watch_audio.pcm")
        do {
            try audioData.write(to: tempURL)
        } catch {
            isSending = false
            errorMessage = "Failed to prepare audio"
            return
        }

        session.transferFile(tempURL, metadata: metadata)
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
