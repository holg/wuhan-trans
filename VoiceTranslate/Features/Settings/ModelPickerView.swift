import SwiftUI

struct ModelPickerView: View {
    @Binding var selectedEngine: ASREngine
    let downloader: ModelDownloader
    let onSelect: (ASREngine) -> Void

    var body: some View {
        ForEach(ASREngine.allCases) { engine in
            let state = downloader.state(for: engine)

            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(engine.displayName)
                            .foregroundStyle(.primary)
                        if engine == selectedEngine {
                            Image(systemName: "checkmark")
                                .font(.caption)
                                .foregroundStyle(.blue)
                        }
                    }
                    if case .failed(let msg) = state {
                        Text(msg)
                            .font(.caption)
                            .foregroundStyle(.red)
                    } else {
                        Text(engine.modelDescription)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer()

                downloadButton(engine: engine, state: state)
            }
            .contentShape(Rectangle())
            .onTapGesture {
                if !engine.requiresModelDownload || state == .downloaded {
                    selectedEngine = engine
                    onSelect(engine)
                }
            }
        }
    }

    @ViewBuilder
    private func downloadButton(engine: ASREngine, state: DownloadState) -> some View {
        switch state {
        case .notDownloaded:
            Button {
                downloader.download(engine)
            } label: {
                Image(systemName: "arrow.down.circle")
                    .font(.title3)
                    .foregroundStyle(.blue)
            }
            .buttonStyle(.plain)

        case .downloading(let progress):
            ZStack {
                CircularProgressView(progress: progress)
                    .frame(width: 28, height: 28)
                Button {
                    downloader.cancelDownload(engine)
                } label: {
                    Image(systemName: "xmark")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }

        case .downloaded:
            if engine.requiresModelDownload {
                Menu {
                    Button("Delete Model", systemImage: "trash", role: .destructive) {
                        downloader.deleteModel(engine)
                        if selectedEngine == engine {
                            selectedEngine = .appleSpeech
                            onSelect(.appleSpeech)
                        }
                    }
                } label: {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.title3)
                        .foregroundStyle(.green)
                }
            }

        case .failed(let message):
            Button {
                downloader.download(engine)
            } label: {
                Image(systemName: "exclamationmark.triangle")
                    .font(.title3)
                    .foregroundStyle(.red)
            }
            .buttonStyle(.plain)
            .help(message)
        }
    }
}

struct CircularProgressView: View {
    let progress: Double

    var body: some View {
        ZStack {
            Circle()
                .stroke(.quaternary, lineWidth: 3)
            Circle()
                .trim(from: 0, to: progress)
                .stroke(.blue, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
    }
}
