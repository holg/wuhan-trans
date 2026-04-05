import Foundation
import Observation
import WhisperKit

enum DownloadState: Sendable, Equatable {
    case notDownloaded
    case downloading(progress: Double)
    case downloaded
    case failed(String)
}

@Observable
@MainActor
final class ModelDownloader {
    var engineStates: [ASREngine: DownloadState] = [:]

    private var activeTasks: [ASREngine: Task<Void, Never>] = [:]

    /// Base directory for all downloaded models
    static var modelsDirectory: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        return docs.appending(path: "Models", directoryHint: .isDirectory)
    }

    var nllbState: DownloadState = .notDownloaded
    var senseVoiceState: DownloadState = .notDownloaded

    init() {
        for engine in ASREngine.allCases {
            if engine.requiresModelDownload {
                engineStates[engine] = isModelDownloaded(engine) ? .downloaded : .notDownloaded
            }
        }
        nllbState = isNLLBDownloaded() ? .downloaded : .notDownloaded
        senseVoiceState = isSenseVoiceDownloaded() ? .downloaded : .notDownloaded
    }

    func state(for engine: ASREngine) -> DownloadState {
        if !engine.requiresModelDownload { return .downloaded }
        return engineStates[engine] ?? .notDownloaded
    }

    func isSenseVoiceDownloaded() -> Bool {
        let dir = modelDirectory(for: SpecialModel.sensevoice)
        return FileManager.default.fileExists(atPath: dir.appending(path: "SenseVoiceSmall.mlmodelc").path())
            && FileManager.default.fileExists(atPath: dir.appending(path: "tokens.bpe.model").path())
    }

    func downloadSenseVoice() {
        guard senseVoiceState != .downloaded else { return }
        if case .downloading = senseVoiceState { return }

        senseVoiceState = .downloading(progress: 0)

        Task {
            do {
                try await downloadSenseVoiceModels()
                senseVoiceState = .downloaded
            } catch {
                if !Task.isCancelled {
                    senseVoiceState = .failed(error.localizedDescription)
                }
            }
        }
    }

    private func downloadSenseVoiceModels() async throws {
        let repo = "holgt/sensevoice-small-coreml"
        let destDir = modelDirectory(for: SpecialModel.sensevoice)
        try FileManager.default.createDirectory(at: destDir, withIntermediateDirectories: true)

        let items = [
            ("SenseVoiceSmall.mlmodelc", true),   // directory
            ("am.mvn", false),                      // file
            ("tokens.bpe.model", false),             // file
        ]

        for (index, (item, isDir)) in items.enumerated() {
            try Task.checkCancellation()
            let destItem = destDir.appending(path: item)
            if FileManager.default.fileExists(atPath: destItem.path()) {
                senseVoiceState = .downloading(progress: Double(index + 1) / Double(items.count))
                continue
            }
            if isDir {
                try await downloadDirectory(repo: repo, path: item, to: destItem)
            } else {
                let url = URL(string: "https://huggingface.co/\(repo)/resolve/main/\(item)")!
                try await downloadFile(from: url, to: destItem, engine: .appleSpeech, fileIndex: index, totalFiles: items.count)
            }
            senseVoiceState = .downloading(progress: Double(index + 1) / Double(items.count))
        }
    }

    func isNLLBDownloaded() -> Bool {
        let dir = modelDirectory(for: TranslationEngine.nllb)
        return FileManager.default.fileExists(atPath: dir.appending(path: "NLLB_Encoder_256.mlmodelc").path())
            && FileManager.default.fileExists(atPath: dir.appending(path: "tokenizer/tokenizer.json").path())
    }

    func downloadNLLB() {
        guard nllbState != .downloaded else { return }
        if case .downloading = nllbState { return }

        nllbState = .downloading(progress: 0)

        let task = Task {
            do {
                try await downloadNLLBModels()
                nllbState = .downloaded
            } catch {
                if !Task.isCancelled {
                    nllbState = .failed(error.localizedDescription)
                }
            }
        }
        activeTasks[.appleSpeech] = task // reuse slot, only one NLLB download at a time
    }

    private func downloadNLLBModels() async throws {
        let repo = "holgt/nllb-200-coreml"
        let destDir = modelDirectory(for: TranslationEngine.nllb)
        try FileManager.default.createDirectory(at: destDir, withIntermediateDirectories: true)

        let items = [
            "NLLB_Encoder_256.mlmodelc",
            "NLLB_Decoder_256.mlmodelc",
            "tokenizer",
        ]

        for (index, item) in items.enumerated() {
            try Task.checkCancellation()
            let destItem = destDir.appending(path: item)
            if FileManager.default.fileExists(atPath: destItem.path()) {
                nllbState = .downloading(progress: Double(index + 1) / Double(items.count))
                continue
            }
            try await downloadDirectory(repo: repo, path: item, to: destItem)
            nllbState = .downloading(progress: Double(index + 1) / Double(items.count))
        }
    }

    func modelDirectory(for engine: ASREngine) -> URL {
        Self.modelsDirectory.appending(path: engine.localDirectoryName, directoryHint: .isDirectory)
    }

    func modelDirectory(for engine: TranslationEngine) -> URL {
        Self.modelsDirectory.appending(path: engine.rawValue, directoryHint: .isDirectory)
    }

    func modelDirectory(for specialModel: SpecialModel) -> URL {
        Self.modelsDirectory.appending(path: specialModel.rawValue, directoryHint: .isDirectory)
    }

    enum SpecialModel: String {
        case sensevoice
    }

    func isModelDownloaded(_ engine: ASREngine) -> Bool {
        let dir = modelDirectory(for: engine)
        if engine.isWhisperKit {
            // WhisperKit manages its own model cache, check for marker file
            return FileManager.default.fileExists(atPath: dir.appending(path: ".ready").path())
        }
        // For Cohere: check that the manifest exists
        if engine == .cohereTranscribe {
            return FileManager.default.fileExists(
                atPath: dir.appending(path: "coreml_manifest.json").path()
            )
        }
        return false
    }

    func download(_ engine: ASREngine) {
        guard engine.requiresModelDownload else { return }
        guard state(for: engine) != .downloaded else { return }
        if case .downloading = state(for: engine) { return }

        engineStates[engine] = .downloading(progress: 0)

        let task = Task {
            do {
                if engine.isWhisperKit {
                    try await downloadWhisperKitModel(engine)
                } else {
                    try await downloadHuggingFaceModel(engine)
                }
                engineStates[engine] = .downloaded
            } catch {
                if !Task.isCancelled {
                    engineStates[engine] = .failed(error.localizedDescription)
                }
            }
            activeTasks[engine] = nil
        }
        activeTasks[engine] = task
    }

    func cancelDownload(_ engine: ASREngine) {
        activeTasks[engine]?.cancel()
        activeTasks[engine] = nil
        engineStates[engine] = .notDownloaded
    }

    func deleteModel(_ engine: ASREngine) {
        cancelDownload(engine)
        let dir = modelDirectory(for: engine)
        try? FileManager.default.removeItem(at: dir)
        engineStates[engine] = .notDownloaded
    }

    // MARK: - HuggingFace download (Cohere model)

    private func downloadHuggingFaceModel(_ engine: ASREngine) async throws {
        guard let repo = engine.huggingFaceRepo else { return }
        let files = engine.modelFiles
        let destDir = modelDirectory(for: engine)

        try FileManager.default.createDirectory(at: destDir, withIntermediateDirectories: true)

        for (index, file) in files.enumerated() {
            try Task.checkCancellation()

            let url = URL(string: "https://huggingface.co/\(repo)/resolve/main/\(file)")!
            let destFile = destDir.appending(path: file)

            // Skip if already exists
            if FileManager.default.fileExists(atPath: destFile.path()) {
                let progress = Double(index + 1) / Double(files.count)
                engineStates[engine] = .downloading(progress: progress)
                continue
            }

            // Directories (.mlpackage, .mlmodelc) need recursive download
            if file.hasSuffix(".mlpackage") || file.hasSuffix(".mlmodelc") {
                try await downloadDirectory(repo: repo, path: file, to: destFile)
            } else {
                try await downloadFile(from: url, to: destFile, engine: engine, fileIndex: index, totalFiles: files.count)
            }

            let progress = Double(index + 1) / Double(files.count)
            engineStates[engine] = .downloading(progress: progress)
        }
    }

    private func downloadFile(
        from url: URL,
        to destination: URL,
        engine: ASREngine,
        fileIndex: Int,
        totalFiles: Int
    ) async throws {
        let (tempURL, response) = try await URLSession.shared.download(from: url)
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw DownloadError.httpError(url.lastPathComponent)
        }
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if FileManager.default.fileExists(atPath: destination.path()) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.moveItem(at: tempURL, to: destination)
    }

    private func downloadDirectory(repo: String, path: String, to destination: URL) async throws {
        // URL-encode the path, but preserve /
        let pathComponents = path.components(separatedBy: "/")
        let encodedComponents = pathComponents.map { $0.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? $0 }
        let encodedPath = encodedComponents.joined(separator: "/")

        let apiURLString = "https://huggingface.co/api/models/\(repo)/tree/main/\(encodedPath)"
        guard let apiURL = URL(string: apiURLString) else {
            throw DownloadError.httpError("Invalid URL: \(apiURLString)")
        }

        print("[Download] Listing directory: \(path)")
        let (data, response) = try await URLSession.shared.data(from: apiURL)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            print("[Download] Directory listing failed: \(path) status=\(status)")
            throw DownloadError.httpError("\(path) (HTTP \(status))")
        }

        struct HFEntry: Decodable {
            let path: String
            let type: String
        }

        let entries = try JSONDecoder().decode([HFEntry].self, from: data)
        print("[Download] Found \(entries.count) entries in \(path)")

        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)

        for entry in entries {
            try Task.checkCancellation()

            // Get just the filename (last component of the entry path)
            let fileName = entry.path.components(separatedBy: "/").last ?? entry.path
            let destItem = destination.appending(path: fileName)

            if entry.type == "directory" {
                try await downloadDirectory(repo: repo, path: entry.path, to: destItem)
            } else {
                guard !FileManager.default.fileExists(atPath: destItem.path()) else { continue }
                // Encode each path component separately
                let fileComponents = entry.path.components(separatedBy: "/")
                let encodedFileComponents = fileComponents.map { $0.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? $0 }
                let encodedFilePath = encodedFileComponents.joined(separator: "/")
                guard let fileURL = URL(string: "https://huggingface.co/\(repo)/resolve/main/\(encodedFilePath)") else { continue }

                print("[Download] Downloading: \(entry.path)")
                try FileManager.default.createDirectory(
                    at: destItem.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                let (tempURL, dlResponse) = try await URLSession.shared.download(from: fileURL)
                guard let dlHttp = dlResponse as? HTTPURLResponse, dlHttp.statusCode == 200 else {
                    let status = (dlResponse as? HTTPURLResponse)?.statusCode ?? 0
                    print("[Download] File download failed: \(entry.path) status=\(status)")
                    throw DownloadError.httpError("\(fileName) (HTTP \(status))")
                }
                if FileManager.default.fileExists(atPath: destItem.path()) {
                    try FileManager.default.removeItem(at: destItem)
                }
                try FileManager.default.moveItem(at: tempURL, to: destItem)
            }
        }
    }

    // MARK: - WhisperKit download

    private func downloadWhisperKitModel(_ engine: ASREngine) async throws {
        guard let modelName = engine.whisperKitModelName else { return }

        engineStates[engine] = .downloading(progress: 0.1)

        let config = WhisperKitConfig(
            model: modelName,
            modelRepo: engine.huggingFaceRepo,
            verbose: true,
            prewarm: false,
            load: false
        )

        engineStates[engine] = .downloading(progress: 0.3)

        // This triggers the download
        _ = try await WhisperKit(config)

        // Mark as downloaded
        let destDir = modelDirectory(for: engine)
        try FileManager.default.createDirectory(at: destDir, withIntermediateDirectories: true)
        let marker = destDir.appending(path: ".ready")
        try Data().write(to: marker)

        engineStates[engine] = .downloading(progress: 1.0)
    }
}

enum DownloadError: Error, LocalizedError {
    case httpError(String)

    var errorDescription: String? {
        switch self {
        case .httpError(let file): "Download failed: \(file)"
        }
    }
}
