import Foundation
#if canImport(Darwin)
import Darwin
#endif

final class MemoryMonitor: Sendable {
    /// Available memory in megabytes
    var availableMemoryMB: Int {
        #if os(iOS) || os(tvOS) || os(watchOS)
        Int(os_proc_available_memory()) / 1_048_576
        #elseif os(macOS)
        Int(ProcessInfo.processInfo.physicalMemory) / 1_048_576
        #endif
    }

    /// True when available memory drops below 500 MB
    var isUnderPressure: Bool {
        availableMemoryMB < 500
    }

    /// Suggest a smaller ASR engine when memory is tight
    var recommendedEngine: ASREngine {
        let available = availableMemoryMB
        if available > 2000 {
            return .cohereTranscribe
        } else if available > 1000 {
            return .whisperKitMedium
        } else {
            return .appleSpeech
        }
    }
}
