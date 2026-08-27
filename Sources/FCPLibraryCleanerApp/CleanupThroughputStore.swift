import Foundation
import FCPLibraryCleanerCore

/// Persists the per-volume cleanup throughput history backing ETA estimates.
///
/// History intentionally lives under a versioned key so switching from the old
/// global-average layout starts clean instead of importing cross-volume data.
enum CleanupThroughputStore {
    private static let storageKey = "cleanupThroughputIndexV2"

    static func currentIndex() -> CleanupThroughputIndex {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let index = try? JSONDecoder().decode(CleanupThroughputIndex.self, from: data) else {
            return CleanupThroughputIndex()
        }
        return index
    }

    static func averageBytesPerSecond(volumeID: String) -> Double? {
        currentIndex().averageBytesPerSecond(volumeID: volumeID)
    }

    @MainActor
    static func record(volumeID: String?, bytes: Int64, seconds: Double) {
        guard let volumeID else { return }
        var index = currentIndex()
        index.record(volumeID: volumeID, bytes: bytes, seconds: seconds)
        if let data = try? JSONEncoder().encode(index) {
            UserDefaults.standard.set(data, forKey: storageKey)
        }
    }
}
