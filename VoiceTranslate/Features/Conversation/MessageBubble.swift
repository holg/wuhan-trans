import SwiftUI

struct MessageBubble: View {
    let message: ConversationMessage
    var onReplay: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                if message.isRemote {
                    Image(systemName: "person.wave.2")
                        .foregroundStyle(.blue)
                }
                Text(message.sourceLanguage.flag)
                Text("→")
                    .foregroundStyle(.secondary)
                Text(message.targetLanguage.flag)
                Spacer()
                Button {
                    onReplay?()
                } label: {
                    Image(systemName: "speaker.wave.2.fill")
                        .font(.caption)
                        .foregroundStyle(.blue)
                }
                .buttonStyle(.plain)
                Text(message.timestamp, style: .time)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .font(.caption2)

            Text(message.originalText)
                .font(.callout)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)

            Text(message.translatedText)
                .font(.callout.weight(.medium))
                .textSelection(.enabled)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            message.isRemote ? AnyShapeStyle(.blue.opacity(0.08)) : AnyShapeStyle(.fill.quaternary),
            in: RoundedRectangle(cornerRadius: 10)
        )
        .contextMenu {
            Button("Copy Original", systemImage: "doc.on.doc") {
                copyToClipboard(message.originalText)
            }
            Button("Copy Translation", systemImage: "doc.on.doc.fill") {
                copyToClipboard(message.translatedText)
            }
            Button("Copy Both", systemImage: "doc.on.doc") {
                copyToClipboard("\(message.originalText)\n\(message.translatedText)")
            }
        }
    }

    private func copyToClipboard(_ text: String) {
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #else
        UIPasteboard.general.string = text
        #endif
    }
}
