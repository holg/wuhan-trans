import Foundation
import Observation
#if canImport(UIKit)
import UIKit
#endif

@Observable
@MainActor
final class RelaySessionManager: SessionTransport {
    var connectionState: PeerConnectionState = .disconnected
    var connectedPeerName: String?
    var onMessageReceived: (@MainActor (PeerMessage) -> Void)?
    var roomCode: String?
    var saveEnabled = false
    var savingActive = false
    var participants: [String] = []
    var deviceName: String = {
        #if os(watchOS)
        "Apple Watch"
        #elseif canImport(UIKit)
        UIDevice.current.name
        #else
        Host.current().localizedName ?? "Mac"
        #endif
    }()

    private var webSocketTask: URLSessionWebSocketTask?
    private var receiveTask: Task<Void, Never>?
    private var pingTask: Task<Void, Never>?
    private var serverURL: URL

    static let defaultServerURL = "wss://voice.rlxapi.eu"

    init() {
        let saved = UserDefaults.standard.string(forKey: "relayServerURL") ?? Self.defaultServerURL
        self.serverURL = URL(string: saved) ?? URL(string: Self.defaultServerURL)!
    }

    func updateServerURL(_ urlString: String) {
        guard let url = URL(string: urlString) else { return }
        serverURL = url
        UserDefaults.standard.set(urlString, forKey: "relayServerURL")
    }

    // MARK: - Room management

    private var baseHTTPURL: String {
        let scheme = serverURL.scheme == "wss" ? "https" : "http"
        let host = serverURL.host() ?? "localhost"
        let port = serverURL.port.map { ":\($0)" } ?? ""
        return "\(scheme)://\(host)\(port)"
    }

    func createRoom() async throws {
        let url = URL(string: "\(baseHTTPURL)/room")!

        var request = URLRequest(url: url)
        request.httpMethod = "POST"

        let (data, _) = try await URLSession.shared.data(for: request)
        struct RoomResponse: Decodable { let code: String }
        let response = try JSONDecoder().decode(RoomResponse.self, from: data)
        roomCode = response.code
        print("[Relay] Created room: \(response.code)")
        connectWebSocket(code: response.code)
    }

    func joinRoom(code: String) {
        roomCode = code
        print("[Relay] Joining room: \(code)")
        connectWebSocket(code: code)
    }

    // MARK: - SessionTransport

    func send(_ message: PeerMessage) throws {
        guard let task = webSocketTask else { return }
        let data = try message.encode()
        let string = String(data: data, encoding: .utf8) ?? ""
        task.send(.string(string)) { error in
            if let error { print("[Relay] Send error: \(error)") }
        }
    }

    func disconnect() {
        receiveTask?.cancel()
        receiveTask = nil
        pingTask?.cancel()
        pingTask = nil
        webSocketTask?.cancel(with: .normalClosure, reason: nil)
        webSocketTask = nil
        connectionState = .disconnected
        connectedPeerName = nil
        roomCode = nil
        saveEnabled = false
        savingActive = false
    }

    func toggleSave() {
        saveEnabled.toggle()
        let msg = saveEnabled ? "{\"type\":\"enable_save\"}" : "{\"type\":\"disable_save\"}"
        webSocketTask?.send(.string(msg)) { _ in }
    }

    // MARK: - WebSocket

    private func connectWebSocket(code: String) {
        let wsURL = URL(string: "\(serverURL.absoluteString)/ws/\(code)")!
        let task = URLSession.shared.webSocketTask(with: wsURL)
        task.resume()
        webSocketTask = task
        connectionState = .connecting

        // Send our device name
        let setName = "{\"type\":\"set_name\",\"name\":\"\(deviceName)\"}"
        task.send(.string(setName)) { _ in }

        startReceiveLoop()
        startPingLoop()
    }

    private func startReceiveLoop() {
        receiveTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                guard let task = self.webSocketTask else { break }
                do {
                    let message = try await task.receive()
                    switch message {
                    case .string(let text):
                        self.handleMessage(text)
                    case .data(let data):
                        if let text = String(data: data, encoding: .utf8) {
                            self.handleMessage(text)
                        }
                    @unknown default:
                        break
                    }
                } catch {
                    print("[Relay] Receive error: \(error)")
                    if !Task.isCancelled {
                        self.connectionState = .disconnected
                        self.connectedPeerName = nil
                        // Auto-reconnect
                        if let code = self.roomCode {
                            try? await Task.sleep(for: .seconds(2))
                            if !Task.isCancelled {
                                self.connectWebSocket(code: code)
                            }
                        }
                    }
                    break
                }
            }
        }
    }

    private func startPingLoop() {
        pingTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                self?.webSocketTask?.sendPing { _ in }
            }
        }
    }

    private func handleMessage(_ text: String) {
        struct ControlMsg: Decodable {
            let type: String
            let peer: String?
            let active: Bool?
            let message: String?
            let participants: [String]?
            let count: Int?
        }

        if let ctrl = try? JSONDecoder().decode(ControlMsg.self, from: Data(text.utf8)) {
            switch ctrl.type {
            case "roster":
                let names = ctrl.participants ?? []
                participants = names.filter { $0 != deviceName }
                let count = ctrl.count ?? names.count
                if count >= 2 {
                    connectionState = .connected
                    connectedPeerName = participants.joined(separator: ", ")
                } else {
                    connectionState = .connecting
                    connectedPeerName = nil
                }
                print("[Relay] Roster: \(names) (\(count) total)")
            case "paired":
                connectionState = .connected
                connectedPeerName = ctrl.peer ?? "Remote Device"
            case "peer_left":
                // Roster update will follow
                break
            case "save_status":
                savingActive = ctrl.active ?? false
            case "error":
                print("[Relay] Error: \(ctrl.message ?? "unknown")")
                disconnect()
            default:
                break
            }
            return
        }

        // Data message — decode as PeerMessage
        if let data = text.data(using: .utf8),
           let peerMessage = try? PeerMessage.decode(from: data) {
            onMessageReceived?(peerMessage)
        }
    }
}
