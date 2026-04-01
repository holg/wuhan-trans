import AppIntents

struct RecordTranslateIntent: AppIntent {
    static let title: LocalizedStringResource = "Record Translation"
    static let description: IntentDescription = "Start or stop voice recording for translation"
    static let openAppWhenRun: Bool = true

    func perform() async throws -> some IntentResult {
        await RecordTranslateIntent.toggle()
        return .result()
    }

    @MainActor
    static func toggle() {
        guard let viewModel = SharedState.viewModel else { return }
        if viewModel.isRecording {
            viewModel.stopAndTranslate()
        } else {
            viewModel.startListening()
        }
    }
}

/// Shared reference so the AppIntent can access the ViewModel
@MainActor
enum SharedState {
    static weak var viewModel: ConversationViewModel?
}
