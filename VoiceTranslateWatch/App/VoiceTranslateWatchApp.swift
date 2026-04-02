import SwiftUI

@main
struct VoiceTranslateWatchApp: App {
    @State private var connectivity = WatchConnectivityClient()
    @State private var recorder = WatchAudioRecorder()

    var body: some Scene {
        WindowGroup {
            WatchConversationView(connectivity: connectivity, recorder: recorder)
        }
    }
}
