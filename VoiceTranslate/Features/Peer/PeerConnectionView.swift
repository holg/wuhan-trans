import SwiftUI

struct PeerConnectionView: View {
    @Bindable var peerSession: PeerSessionManager
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 24) {
            switch peerSession.connectionState {
            case .disconnected:
                Text("Pair with another device")
                    .font(.headline)
                Text("Both devices must run VoiceTranslate")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                HStack(spacing: 20) {
                    Button {
                        peerSession.startHosting()
                    } label: {
                        Label("Host", systemImage: "antenna.radiowaves.left.and.right")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)

                    Button {
                        peerSession.startJoining()
                    } label: {
                        Label("Join", systemImage: "magnifyingglass")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                }

            case .advertising:
                ProgressView()
                Text("Waiting for a device to join...")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Button("Cancel") { peerSession.disconnect() }
                    .buttonStyle(.bordered)

            case .browsing:
                ProgressView()
                Text("Looking for nearby devices...")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Button("Cancel") { peerSession.disconnect() }
                    .buttonStyle(.bordered)

            case .connecting:
                ProgressView()
                Text("Connecting...")
                    .font(.subheadline)

            case .connected:
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 48))
                    .foregroundStyle(.green)
                Text("Connected to \(peerSession.connectedPeerName ?? "device")")
                    .font(.headline)
                Text("Translations will be shared between devices")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Button("Disconnect", role: .destructive) {
                    peerSession.disconnect()
                }
                .buttonStyle(.bordered)

                Button("Done") { dismiss() }
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
