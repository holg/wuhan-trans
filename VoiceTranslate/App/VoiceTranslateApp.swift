import SwiftUI

@main
struct VoiceTranslateApp: App {
    @State private var viewModel = ConversationViewModel()
    @State private var phoneConnectivity = PhoneConnectivityService()

    var body: some Scene {
        WindowGroup {
            ContentView(viewModel: viewModel)
                .onAppear {
                    SharedState.viewModel = viewModel
                    phoneConnectivity.viewModel = viewModel
                }
        }
        #if os(macOS)
        Settings {
            SettingsView(viewModel: viewModel)
        }
        #endif
    }
}
