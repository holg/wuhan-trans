import SwiftUI

struct WatchConversationView: View {
    @Bindable var translator: WatchTranslator
    let connectivity: WatchConnectivityClient

    var body: some View {
        VStack(spacing: 0) {
            languageBar

            if translator.messages.isEmpty && !translator.isProcessing && !translator.isRecording {
                Spacer()
                Image(systemName: "mic")
                    .font(.title2)
                    .foregroundStyle(.secondary)
                Text("Tap to speak")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
            } else {
                messageList
            }

            statusBar

            recordButton
                .padding(.bottom, 4)
        }
    }

    private var languageBar: some View {
        HStack(spacing: 4) {
            Picker("", selection: Binding(
                get: { translator.sourceLanguage },
                set: { translator.setSourceLanguage($0) }
            )) {
                ForEach(SupportedLanguage.allCases) { lang in
                    Text(lang.flag).tag(lang)
                }
            }
            .frame(width: 50)

            Image(systemName: "arrow.right")
                .font(.caption2)
                .foregroundStyle(.secondary)

            Picker("", selection: Binding(
                get: { translator.targetLanguage },
                set: { translator.setTargetLanguage($0) }
            )) {
                ForEach(SupportedLanguage.allCases) { lang in
                    Text(lang.flag).tag(lang)
                }
            }
            .frame(width: 50)

            Spacer()

            Circle()
                .fill(connectivity.isReachable ? .green : .gray)
                .frame(width: 6, height: 6)
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 2)
    }

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 6) {
                    ForEach(translator.messages) { msg in
                        WatchMessageRow(message: msg)
                            .id(msg.id)
                            .onTapGesture {
                                translator.replay(msg)
                            }
                    }
                }
            }
            .onChange(of: translator.messages.count) {
                if let last = translator.messages.last {
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
                Text("iPhone needed")
                    .font(.caption2)
                    .foregroundStyle(.red)
            } else if translator.isProcessing {
                Text("Translating...")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            } else if let error = translator.errorMessage {
                Text(error)
                    .font(.caption2)
                    .foregroundStyle(.red)
                    .lineLimit(2)
            }
        }
    }

    private var recordButton: some View {
        Button {
            if translator.isRecording {
                translator.stopAndSend(via: connectivity)
            } else {
                translator.startRecording()
            }
        } label: {
            Image(systemName: translator.isRecording ? "stop.fill" : "mic.fill")
                .font(.title3)
                .frame(width: 44, height: 44)
        }
        .buttonStyle(.borderedProminent)
        .tint(translator.isRecording ? .red : .blue)
        .disabled(!connectivity.isReachable || translator.isProcessing)
    }
}
