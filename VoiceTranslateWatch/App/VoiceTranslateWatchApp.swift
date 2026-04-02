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
                    let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
                    let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
                    WatchCrashLog.log("App launched v\(version)(\(build))")
                }
        }
    }
}

struct WatchLogView: View {
    @State private var logText = WatchCrashLog.read()

    private var versionString: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        return "v\(v) build \(b)"
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 4) {
                Text(versionString)
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundStyle(.blue)
                Text(logText)
                    .font(.system(size: 10, design: .monospaced))
            }
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
