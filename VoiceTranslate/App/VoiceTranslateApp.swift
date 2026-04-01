import SwiftUI

@main
struct VoiceTranslateApp: App {
    @State private var viewModel = ConversationViewModel()

    var body: some Scene {
        WindowGroup {
            ContentView(viewModel: viewModel)
                .onAppear {
                    SharedState.viewModel = viewModel
                }
        }
        #if os(macOS)
        Settings {
            SettingsView(viewModel: viewModel)
        }
        #endif
    }
}
