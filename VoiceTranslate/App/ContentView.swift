import SwiftUI

struct ContentView: View {
    @Bindable var viewModel: ConversationViewModel
    @State private var showSettings = false
    @State private var showPeerConnection = false
    @State private var peerSession = PeerSessionManager()

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
                    Image(systemName: peerSession.connectionState == .connected
                          ? "antenna.radiowaves.left.and.right.circle.fill"
                          : "antenna.radiowaves.left.and.right")
                        .font(.body)
                        .foregroundStyle(peerSession.connectionState == .connected ? .green : .primary)
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
            PeerConnectionView(peerSession: peerSession)
                .presentationDetents([.medium])
        }
        .onAppear {
            viewModel.configurePeerSession(peerSession)
        }
        #else
        NavigationSplitView {
            List {
                NavigationLink("Translate", value: "conversation")
                NavigationLink("Settings", value: "settings")
            }
            .navigationTitle("VoiceTranslate")
            .toolbar {
                ToolbarItem {
                    Button {
                        showPeerConnection = true
                    } label: {
                        Image(systemName: peerSession.connectionState == .connected
                              ? "antenna.radiowaves.left.and.right.circle.fill"
                              : "antenna.radiowaves.left.and.right")
                            .foregroundStyle(peerSession.connectionState == .connected ? .green : .primary)
                    }
                }
            }
        } detail: {
            ConversationView(viewModel: viewModel)
        }
        .sheet(isPresented: $showPeerConnection) {
            PeerConnectionView(peerSession: peerSession)
                .frame(minWidth: 300, minHeight: 250)
        }
        .onAppear {
            viewModel.configurePeerSession(peerSession)
        }
        #endif
    }
}
