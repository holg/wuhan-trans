import SwiftUI

struct PeerConnectionView: View {
    @Bindable var peerSession: PeerSessionManager
    @Bindable var relaySession: RelaySessionManager
    var onSessionChanged: (any SessionTransport) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var mode: ConnectionMode = .nearby
    @State private var joinCode = ""

    enum ConnectionMode: String, CaseIterable {
        case nearby = "Nearby"
        case internet = "Internet"
    }

    var body: some View {
        VStack(spacing: 20) {
            // Show mode picker only when disconnected
            if peerSession.connectionState == .disconnected && relaySession.connectionState == .disconnected {
                Picker("Mode", selection: $mode) {
                    ForEach(ConnectionMode.allCases, id: \.self) { m in
                        Text(m.rawValue).tag(m)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
            }

            switch mode {
            case .nearby:
                nearbyView
            case .internet:
                internetView
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Nearby (MultipeerConnectivity)

    @ViewBuilder
    private var nearbyView: some View {
        switch peerSession.connectionState {
        case .disconnected:
            Text("Pair with a nearby device")
                .font(.headline)
            HStack(spacing: 20) {
                Button {
                    peerSession.startHosting()
                    onSessionChanged(peerSession)
                } label: {
                    Label("Host", systemImage: "antenna.radiowaves.left.and.right")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)

                Button {
                    peerSession.startJoining()
                    onSessionChanged(peerSession)
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

        case .connected:
            connectedView(name: peerSession.connectedPeerName, onDisconnect: { peerSession.disconnect() })
        }
    }

    // MARK: - Internet (Relay Server)

    @ViewBuilder
    private var internetView: some View {
        switch relaySession.connectionState {
        case .disconnected:
            Text("Connect via internet")
                .font(.headline)
            Text("One device creates a room, the other joins with the code")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Button {
                Task {
                    try? await relaySession.createRoom()
                    onSessionChanged(relaySession)
                }
            } label: {
                Label("Create Room", systemImage: "plus.circle")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)

            HStack {
                TextField("Enter code", text: $joinCode)
                    .textFieldStyle(.roundedBorder)
                    #if os(iOS)
                    .keyboardType(.numberPad)
                    #endif
                Button("Join") {
                    relaySession.joinRoom(code: joinCode)
                    onSessionChanged(relaySession)
                }
                .buttonStyle(.bordered)
                .disabled(joinCode.count != 6)
            }

        case .connecting:
            ProgressView()
            if let code = relaySession.roomCode {
                Text("Room: \(code)")
                    .font(.system(.title, design: .monospaced, weight: .bold))
                Text("Share this code with the other person")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("Connecting...")
            }
            Button("Cancel") { relaySession.disconnect() }
                .buttonStyle(.bordered)

        case .advertising, .browsing:
            // Not used for relay, but handle anyway
            ProgressView()

        case .connected:
            connectedView(name: relaySession.connectedPeerName, onDisconnect: { relaySession.disconnect() })

            // Save toggle
            Toggle("Save conversation on server", isOn: Binding(
                get: { relaySession.saveEnabled },
                set: { _ in relaySession.toggleSave() }
            ))
            .font(.caption)

            if relaySession.savingActive {
                Label("Both sides agreed — saving", systemImage: "circle.fill")
                    .font(.caption2)
                    .foregroundStyle(.red)
            }
        }
    }

    // MARK: - Connected state (shared)

    private func connectedView(name: String?, onDisconnect: @escaping () -> Void) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 48))
                .foregroundStyle(.green)
            Text("Connected to \(name ?? "device")")
                .font(.headline)
            Text("Translations will be shared between devices")
                .font(.caption)
                .foregroundStyle(.secondary)

            Button("Disconnect", role: .destructive) {
                onDisconnect()
            }
            .buttonStyle(.bordered)

            Button("Done") { dismiss() }
                .buttonStyle(.borderedProminent)
        }
    }
}
