import SwiftUI

struct SettingsView: View {
    @Bindable var viewModel: ConversationViewModel

    private var relayURLBinding: Binding<String> {
        Binding(
            get: { UserDefaults.standard.string(forKey: "relayServerURL") ?? RelaySessionManager.defaultServerURL },
            set: { UserDefaults.standard.set($0, forKey: "relayServerURL") }
        )
    }

    var body: some View {
        Form {
            Section("Speech Recognition") {
                ModelPickerView(
                    selectedEngine: $viewModel.currentEngine,
                    downloader: viewModel.downloader,
                    onSelect: { viewModel.setEngine($0) }
                )
            }

            Section("Translation Engine") {
                ForEach(TranslationEngine.allCases) { engine in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text(engine.displayName)
                                if engine == viewModel.translationEngine {
                                    Image(systemName: "checkmark")
                                        .font(.caption)
                                        .foregroundStyle(.blue)
                                }
                            }
                            Text(engine.modelDescription)
                                .font(.caption)
                                .foregroundStyle(engine == .apple ? .orange : .green)
                        }
                        Spacer()
                    }
                    .contentShape(Rectangle())
                    .onTapGesture {
                        viewModel.translationEngine = engine
                    }
                }
            }

            Section("Quick Select Languages") {
                LanguagePickerView(activeLanguages: $viewModel.activeLanguages)
            }

            Section("System") {
                let monitor = MemoryMonitor()
                LabeledContent("Available Memory") {
                    Text("\(monitor.availableMemoryMB) MB")
                        .foregroundStyle(monitor.isUnderPressure ? .red : .primary)
                }
                LabeledContent("ASR Engine") {
                    Text(viewModel.loadedEngine?.displayName ?? "none")
                        .foregroundStyle(viewModel.loadedEngine != nil ? .green : .secondary)
                }
            }

            watchDebugSection

            Section("Relay Server") {
                TextField("Server URL", text: relayURLBinding)
                    .textFieldStyle(.roundedBorder)
                    .font(.caption)
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    .keyboardType(.URL)
                    #endif
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Settings")
    }

    private var watchDebugSection: some View {
        Section("Apple Watch") {
            let wc = viewModel.phoneConnectivity
            LabeledContent("Session") {
                Text(wc.activationState)
            }
            LabeledContent("Paired") {
                Image(systemName: wc.isWatchPaired ? "checkmark.circle.fill" : "xmark.circle")
                    .foregroundStyle(wc.isWatchPaired ? .green : .red)
            }
            LabeledContent("App Installed") {
                Image(systemName: wc.isWatchAppInstalled ? "checkmark.circle.fill" : "xmark.circle")
                    .foregroundStyle(wc.isWatchAppInstalled ? .green : .red)
            }
            LabeledContent("Reachable") {
                Image(systemName: wc.isWatchReachable ? "checkmark.circle.fill" : "xmark.circle")
                    .foregroundStyle(wc.isWatchReachable ? .green : .red)
            }
            LabeledContent("Last Event") {
                Text(wc.lastEvent)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            LabeledContent("Audio Received") {
                Text("\(wc.receivedAudioCount)x (\(wc.lastAudioSamples) samples)")
                    .font(.caption)
            }
            if let error = wc.lastError {
                LabeledContent("Error") {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
        }
    }
}
