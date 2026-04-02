import SwiftUI

@main
struct VoiceTranslateWatchApp: App {
    @State private var connectivity = WatchConnectivityClient()
    @State private var recorder = WatchAudioRecorder()
    @State private var showLog = false

    var body: some Scene {
        WindowGroup {
            WatchConversationView(connectivity: connectivity, recorder: recorder)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button {
                            showLog = true
                        } label: {
                            Image(systemName: "doc.text")
                                .font(.caption2)
                        }
                    }
                }
                .sheet(isPresented: $showLog) {
                    WatchLogView()
                }
                .onAppear {
                    WatchCrashLog.log("App launched")
                }
        }
    }
}

struct WatchLogView: View {
    @State private var logText = WatchCrashLog.read()

    var body: some View {
        ScrollView {
            Text(logText)
                .font(.system(size: 10, design: .monospaced))
                .padding(4)
        }
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Clear") {
                    WatchCrashLog.clear()
                    logText = "Cleared"
                }
            }
        }
    }
}
