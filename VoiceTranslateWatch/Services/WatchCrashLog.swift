import Foundation

/// Simple crash/error log that persists to disk on watchOS
enum WatchCrashLog {
    private static let logURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        .appending(path: "crash_log.txt")

    static func log(_ message: String) {
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let entry = "[\(timestamp)] \(message)\n"
        print("[WatchLog] \(message)")

        if let handle = try? FileHandle(forWritingTo: logURL) {
            handle.seekToEndOfFile()
            handle.write(entry.data(using: .utf8) ?? Data())
            handle.closeFile()
        } else {
            try? entry.data(using: .utf8)?.write(to: logURL)
        }
    }

    static func read() -> String {
        (try? String(contentsOf: logURL, encoding: .utf8)) ?? "No logs"
    }

    static func clear() {
        try? FileManager.default.removeItem(at: logURL)
    }
}
