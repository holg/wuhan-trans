import SwiftUI

struct WatchMessageRow: View {
    let message: ConversationMessage

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 2) {
                Text(message.sourceLanguage.flag)
                Text("→")
                    .foregroundStyle(.secondary)
                Text(message.targetLanguage.flag)
            }
            .font(.caption2)

            Text(message.originalText)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(2)

            Text(message.translatedText)
                .font(.body)
                .lineLimit(3)
        }
    }
}
