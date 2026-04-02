import SwiftUI
import Translation

struct ConversationView: View {
    @Bindable var viewModel: ConversationViewModel

    var body: some View {
        VStack(spacing: 0) {
            languageSelector
                .padding(.horizontal)
                .padding(.vertical, 6)

            Divider()

            messageList

            Divider()

            bottomBar
                .padding(.horizontal)
                .padding(.vertical, 8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            viewModel.ensureTranslationConfig()
        }
        .translationTask(viewModel.translationConfig) { session in
            await MainActor.run {
                viewModel.setTranslationSession(session)
            }
        }
    }

    private var languageSelector: some View {
        HStack(spacing: 12) {
            Picker("Source", selection: $viewModel.sourceLanguage) {
                ForEach(viewModel.activeLanguages) { lang in
                    Text(lang.flag).tag(lang)
                }
            }
            .pickerStyle(.segmented)

            Image(systemName: "arrow.right")
                .foregroundStyle(.secondary)
                .font(.caption)

            Picker("Target", selection: $viewModel.targetLanguage) {
                ForEach(viewModel.activeLanguages) { lang in
                    Text(lang.flag).tag(lang)
                }
            }
            .pickerStyle(.segmented)
        }
    }

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 10) {
                    ForEach(viewModel.messages) { message in
                        MessageBubble(message: message) {
                            viewModel.replayTranslation(message)
                        }
                        .id(message.id)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
            .onChange(of: viewModel.messages.count) {
                if let last = viewModel.messages.last {
                    withAnimation {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
        }
    }

    private var bottomBar: some View {
        VStack(spacing: 4) {
            if viewModel.isLoadingModel {
                Text("Loading \(viewModel.currentEngine.displayName)...")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            } else if let error = viewModel.errorMessage {
                Text(error)
                    .font(.caption2)
                    .foregroundStyle(.red)
                    .lineLimit(2)
            }

            HStack {
                VStack(alignment: .leading, spacing: 1) {
                    Text(viewModel.currentEngine.displayName)
                        .font(.caption2)
                        .foregroundStyle(.primary)
                    if let loaded = viewModel.loadedEngine, loaded == viewModel.currentEngine {
                        Text("active")
                            .font(.system(size: 9))
                            .foregroundStyle(.green)
                    } else if viewModel.loadedEngine != nil {
                        Text("not loaded")
                            .font(.system(size: 9))
                            .foregroundStyle(.orange)
                    }
                }

                Spacer()

                WalkieTalkieButton(
                    isRecording: viewModel.isRecording,
                    isProcessing: viewModel.isProcessing || viewModel.isLoadingModel,
                    onStartRecording: { viewModel.startListening() },
                    onStopRecording: { viewModel.stopAndTranslate() }
                )

                Spacer()

                // Symmetry spacer
                Text(viewModel.currentEngine.displayName)
                    .font(.caption2)
                    .foregroundStyle(.clear)
            }
        }
    }
}
