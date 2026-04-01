import AppIntents

struct VoiceTranslateShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: RecordTranslateIntent(),
            phrases: [
                "Record translation with \(.applicationName)",
                "Translate with \(.applicationName)",
                "Start recording in \(.applicationName)"
            ],
            shortTitle: "Record Translation",
            systemImageName: "mic.badge.waveform"
        )
    }
}
