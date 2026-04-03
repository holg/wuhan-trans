import SwiftUI

struct WatchConversationView: View {
    @Bindable var translator: WatchTranslator
    let connectivity: WatchConnectivityClient

    @State private var dictatedText = ""
    @State private var showDictation = false

    var body: some View {
        VStack(spacing: 0) {
            languageBar

            if translator.messages.isEmpty && !translator.isProcessing {
                Spacer()
                Image(systemName: "mic")
                    .font(.title2)
                    .foregroundStyle(.secondary)
                Text("Tap mic to speak")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
            } else {
                messageList
            }

            statusBar

            dictateButton
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
            if translator.isProcessing {
                Text("Translating...")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            } else if let error = translator.errorMessage {
                Text(error)
                    .font(.caption2)
                    .foregroundStyle(.red)
                    .lineLimit(2)
            } else if !connectivity.isReachable {
                Text("iPhone needed for translation")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }
        }
    }

    private var dictateButton: some View {
        Button {
            dictatedText = ""
            showDictation = true
        } label: {
            Image(systemName: "mic.fill")
                .font(.title3)
                .frame(width: 44, height: 44)
        }
        .buttonStyle(.borderedProminent)
        .tint(connectivity.isReachable ? .blue : .gray)
        .disabled(translator.isProcessing || !connectivity.isReachable)
        .sheet(isPresented: $showDictation) {
            DictationSheet(text: $dictatedText) {
                guard !dictatedText.isEmpty else { return }
                translator.isProcessing = true
                connectivity.sendTextForTranslation(
                    dictatedText,
                    source: translator.sourceLanguage,
                    target: translator.targetLanguage
                )
            }
        }
    }
}

struct DictationSheet: View {
    @Binding var text: String
    let onDone: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 12) {
            Text("Speak now")
                .font(.headline)
            TextField("Tap to dictate...", text: $text)
                .multilineTextAlignment(.center)
            Button("Translate") {
                dismiss()
                onDone()
            }
            .buttonStyle(.borderedProminent)
            .disabled(text.isEmpty)
        }
        .padding()
    }
}
