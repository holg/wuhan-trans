import SwiftUI

struct SettingsView: View {
    @Bindable var viewModel: ConversationViewModel

    var body: some View {
        Form {
            Section("Speech Recognition") {
                ModelPickerView(
                    selectedEngine: $viewModel.currentEngine,
                    downloader: viewModel.downloader,
                    onSelect: { viewModel.setEngine($0) }
                )
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
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Settings")
    }
}
