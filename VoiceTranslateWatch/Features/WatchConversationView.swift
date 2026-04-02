import SwiftUI

struct WatchConversationView: View {
    let connectivity: WatchConnectivityClient
    let recorder: WatchAudioRecorder

    @State private var isRecording = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 0) {
            if connectivity.receivedMessages.isEmpty && !isRecording && !connectivity.isSending {
                ContentUnavailableView {
                    Label("Ready", systemImage: "mic")
                } description: {
                    Text("Tap the mic to speak")
                }
            } else {
                messageList
            }

            Spacer(minLength: 4)

            statusBar

            recordButton
                .padding(.bottom, 4)
        }
    }

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 6) {
                    ForEach(connectivity.receivedMessages) { msg in
                        WatchMessageRow(message: msg)
                            .id(msg.id)
                    }
                }
            }
            .onChange(of: connectivity.receivedMessages.count) {
                if let last = connectivity.receivedMessages.last {
                    withAnimation {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
        }
    }

    private var statusBar: some View {
        Group {
            if !connectivity.isReachable {
                Text("iPhone not reachable")
                    .font(.caption2)
                    .foregroundStyle(.red)
            } else if connectivity.isSending {
                Text("Translating...")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            } else if let error = connectivity.errorMessage {
                Text(error)
                    .font(.caption2)
                    .foregroundStyle(.orange)
            } else if let error = errorMessage {
                Text(error)
                    .font(.caption2)
                    .foregroundStyle(.red)
            } else {
                HStack(spacing: 4) {
                    Text(connectivity.sourceLanguage.flag)
                    Text("→")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text(connectivity.targetLanguage.flag)
                }
                .font(.caption)
            }
        }
    }

    private var recordButton: some View {
        Button {
            toggleRecording()
        } label: {
            Image(systemName: isRecording ? "stop.fill" : "mic.fill")
                .font(.title3)
                .frame(width: 44, height: 44)
        }
        .buttonStyle(.borderedProminent)
        .tint(isRecording ? .red : .blue)
        .disabled(!connectivity.isReachable || connectivity.isSending)
    }

    private func toggleRecording() {
        if isRecording {
            isRecording = false
            let samples = recorder.stopCapture()
            errorMessage = nil

            if samples.isEmpty {
                errorMessage = "No audio captured"
                return
            }

            print("[Watch] Captured \(samples.count) samples, sending...")
            connectivity.sendAudio(
                samples,
                source: connectivity.sourceLanguage,
                target: connectivity.targetLanguage
            )
        } else {
            do {
                errorMessage = nil
                try recorder.startCapture()
                isRecording = true
                print("[Watch] Recording started")
            } catch {
                errorMessage = error.localizedDescription
                print("[Watch] Record failed: \(error)")
            }
        }
    }
}
