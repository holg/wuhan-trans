import Foundation
import MultipeerConnectivity
import Observation

private let serviceType = "vtranslate"

enum PeerConnectionState: Sendable {
    case disconnected
    case advertising
    case browsing
    case connecting
    case connected
}

@Observable
@MainActor
final class PeerSessionManager {
    var connectionState: PeerConnectionState = .disconnected
    var connectedPeerName: String?
    var onMessageReceived: (@MainActor (PeerMessage) -> Void)?

    private var session: MCSession?
    private var advertiser: MCNearbyServiceAdvertiser?
    private var browser: MCNearbyServiceBrowser?
    private var myPeerID: MCPeerID
    private var coordinator: Coordinator?

    init() {
        #if os(iOS)
        let name = UIDevice.current.name
        #else
        let name = Host.current().localizedName ?? "Mac"
        #endif
        myPeerID = MCPeerID(displayName: name)
    }

    func startHosting() {
        disconnect()
        let session = MCSession(peer: myPeerID, securityIdentity: nil, encryptionPreference: .optional)
        let coord = Coordinator(manager: self, session: session)
        session.delegate = coord
        self.session = session
        self.coordinator = coord

        let advertiser = MCNearbyServiceAdvertiser(peer: myPeerID, discoveryInfo: nil, serviceType: serviceType)
        advertiser.delegate = coord
        advertiser.startAdvertisingPeer()
        self.advertiser = advertiser
        connectionState = .advertising
    }

    func startJoining() {
        disconnect()
        let session = MCSession(peer: myPeerID, securityIdentity: nil, encryptionPreference: .optional)
        let coord = Coordinator(manager: self, session: session)
        session.delegate = coord
        self.session = session
        self.coordinator = coord

        let browser = MCNearbyServiceBrowser(peer: myPeerID, serviceType: serviceType)
        browser.delegate = coord
        browser.startBrowsingForPeers()
        self.browser = browser
        connectionState = .browsing
    }

    func disconnect() {
        advertiser?.stopAdvertisingPeer()
        advertiser = nil
        browser?.stopBrowsingForPeers()
        browser = nil
        session?.disconnect()
        session = nil
        coordinator = nil
        connectionState = .disconnected
        connectedPeerName = nil
    }

    func send(_ message: PeerMessage) throws {
        guard let session, !session.connectedPeers.isEmpty else { return }
        let data = try message.encode()
        try session.send(data, toPeers: session.connectedPeers, with: .reliable)
    }

    // MARK: - Coordinator (MPC Delegates)

    private final class Coordinator: NSObject, MCSessionDelegate, MCNearbyServiceBrowserDelegate, MCNearbyServiceAdvertiserDelegate, @unchecked Sendable {
        private weak var manager: PeerSessionManager?
        let mcSession: MCSession  // Direct reference, avoids MainActor access

        init(manager: PeerSessionManager, session: MCSession) {
            self.manager = manager
            self.mcSession = session
        }

        // MARK: MCSessionDelegate

        func session(_ session: MCSession, peer peerID: MCPeerID, didChange state: MCSessionState) {
            let peerName = peerID.displayName
            Task { @MainActor in
                guard let manager else { return }
                switch state {
                case .connected:
                    manager.connectionState = .connected
                    manager.connectedPeerName = peerName
                    manager.advertiser?.stopAdvertisingPeer()
                    manager.browser?.stopBrowsingForPeers()
                case .connecting:
                    manager.connectionState = .connecting
                case .notConnected:
                    manager.connectionState = .disconnected
                    manager.connectedPeerName = nil
                @unknown default:
                    break
                }
            }
        }

        func session(_ session: MCSession, didReceive data: Data, fromPeer peerID: MCPeerID) {
            guard let message = try? PeerMessage.decode(from: data) else { return }
            Task { @MainActor in
                manager?.onMessageReceived?(message)
            }
        }

        func session(_ session: MCSession, didReceive stream: InputStream, withName streamName: String, fromPeer peerID: MCPeerID) {}
        func session(_ session: MCSession, didStartReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, with progress: Progress) {}
        func session(_ session: MCSession, didFinishReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, at localURL: URL?, withError error: Error?) {}

        // MARK: MCNearbyServiceBrowserDelegate

        func browser(_ browser: MCNearbyServiceBrowser, foundPeer peerID: MCPeerID, withDiscoveryInfo info: [String: String]?) {
            // Auto-invite discovered peers
            browser.invitePeer(peerID, to: mcSession, withContext: nil, timeout: 30)
        }

        func browser(_ browser: MCNearbyServiceBrowser, lostPeer peerID: MCPeerID) {}

        func browser(_ browser: MCNearbyServiceBrowser, didNotStartBrowsingForPeers error: Error) {
            print("Browser failed: \(error.localizedDescription)")
            Task { @MainActor in
                manager?.connectionState = .disconnected
                manager?.connectedPeerName = "Browse failed: \(error.localizedDescription)"
            }
        }

        // MARK: MCNearbyServiceAdvertiserDelegate

        func advertiser(_ advertiser: MCNearbyServiceAdvertiser, didReceiveInvitationFromPeer peerID: MCPeerID, withContext context: Data?, invitationHandler: @escaping (Bool, MCSession?) -> Void) {
            print("Received invitation from \(peerID.displayName)")
            invitationHandler(true, mcSession)
        }

        func advertiser(_ advertiser: MCNearbyServiceAdvertiser, didNotStartAdvertisingPeer error: Error) {
            print("Advertiser failed: \(error.localizedDescription)")
            Task { @MainActor in
                manager?.connectionState = .disconnected
                manager?.connectedPeerName = "Advertise failed: \(error.localizedDescription)"
            }
        }
    }
}
