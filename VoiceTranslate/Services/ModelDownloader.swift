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

    init() {
        // Check which models are already downloaded
        for engine in ASREngine.allCases {
            if engine.requiresModelDownload {
                engineStates[engine] = isModelDownloaded(engine) ? .downloaded : .notDownloaded
            }
        }
    }

    func state(for engine: ASREngine) -> DownloadState {
        if !engine.requiresModelDownload { return .downloaded }
        return engineStates[engine] ?? .notDownloaded
    }

    func modelDirectory(for engine: ASREngine) -> URL {
        Self.modelsDirectory.appending(path: engine.localDirectoryName, directoryHint: .isDirectory)
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
