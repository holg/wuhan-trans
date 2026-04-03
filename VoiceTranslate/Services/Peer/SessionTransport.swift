import Foundation

/// Protocol for device-to-device communication (local or internet relay)
@MainActor
protocol SessionTransport: AnyObject {
    var connectionState: PeerConnectionState { get }
    var connectedPeerName: String? { get }
    var onMessageReceived: (@MainActor (PeerMessage) -> Void)? { get set }
    func send(_ message: PeerMessage) throws
    func disconnect()
}
