import SwiftUI

struct ContentView: View {
    @Bindable var viewModel: ConversationViewModel
    @State private var showSettings = false
    @State private var showPeerConnection = false
    @State private var peerSession = PeerSessionManager()
    @State private var relaySession = RelaySessionManager()
    @State private var selectedTab = "translate"

    private var isConnected: Bool {
        peerSession.connectionState == .connected || relaySession.connectionState == .connected
    }

    var body: some View {
        #if os(iOS)
        GeometryReader { _ in
            ConversationView(viewModel: viewModel)
        }
        .overlay(alignment: .topTrailing) {
            HStack(spacing: 8) {
                Button {
                    showPeerConnection = true
                } label: {
                    Image(systemName: isConnected
                          ? "antenna.radiowaves.left.and.right.circle.fill"
                          : "antenna.radiowaves.left.and.right")
                        .font(.body)
                        .foregroundStyle(isConnected ? .green : .primary)
                        .padding(10)
                        .background(.ultraThinMaterial, in: Circle())
                }

                Button {
                    showSettings = true
                } label: {
                    Image(systemName: "gear")
                        .font(.body)
                        .padding(10)
                        .background(.ultraThinMaterial, in: Circle())
                }
            }
            .padding(.trailing, 12)
            .padding(.top, 4)
        }
        .sheet(isPresented: $showSettings) {
            NavigationStack {
                SettingsView(viewModel: viewModel)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") { showSettings = false }
                        }
                    }
            }
        }
        .sheet(isPresented: $showPeerConnection) {
            PeerConnectionView(
                peerSession: peerSession,
                relaySession: relaySession,
                onSessionChanged: { session in
                    viewModel.configurePeerSession(session)
                }
            )
            .presentationDetents([.large])
        }
        .onAppear {
            viewModel.configurePeerSession(peerSession)
        }
        #else
        NavigationSplitView {
            List(selection: $selectedTab) {
                Label("Translate", systemImage: "mic.badge.waveform").tag("translate")
                Label("Settings", systemImage: "gear").tag("settings")
            }
            .navigationTitle("VoiceTranslate")
            .toolbar {
                ToolbarItem {
                    Button {
                        showPeerConnection = true
                    } label: {
                        Image(systemName: isConnected
                              ? "antenna.radiowaves.left.and.right.circle.fill"
                              : "antenna.radiowaves.left.and.right")
                            .foregroundStyle(isConnected ? .green : .primary)
                    }
                }
            }
        } detail: {
            switch selectedTab {
            case "settings":
                SettingsView(viewModel: viewModel)
            default:
                ConversationView(viewModel: viewModel)
            }
        }
        .sheet(isPresented: $showPeerConnection) {
            PeerConnectionView(
                peerSession: peerSession,
                relaySession: relaySession,
                onSessionChanged: { session in
                    viewModel.configurePeerSession(session)
                }
            )
            .frame(minWidth: 400, minHeight: 350)
        }
        .onAppear {
            viewModel.configurePeerSession(peerSession)
        }
        #endif
    }
}
