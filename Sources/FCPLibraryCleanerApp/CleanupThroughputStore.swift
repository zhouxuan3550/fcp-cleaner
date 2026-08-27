import Foundation

struct CleanupThroughputSample: Codable {
    let date: Date
    let bytes: Int64
    let seconds: Double
}

enum CleanupThroughputStore {
    private static let key = "cleanupThroughputSamples"
    private static let maxSamples = 10

    static func load() -> [CleanupThroughputSample] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let samples = try? JSONDecoder().decode([CleanupThroughputSample].self, from: data) else {
            return []
        }
        return samples
    }

    static func record(bytes: Int64, seconds: Double) {
        guard seconds >= 0.05, bytes > 0 else { return }
        var samples = load()
        samples.append(CleanupThroughputSample(date: Date(), bytes: bytes, seconds: seconds))
        if samples.count > maxSamples {
            samples.removeFirst(samples.count - maxSamples)
        }
        if let data = try? JSONEncoder().encode(samples) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    static func averageBytesPerSecond() -> Double? {
        let samples = load()
        guard !samples.isEmpty else { return nil }
        let totalBytes = samples.reduce(Int64(0)) { $0 + $1.bytes }
        let totalSeconds = samples.reduce(0.0) { $0 + $1.seconds }
        guard totalSeconds > 0 else { return nil }
        return Double(totalBytes) / totalSeconds
    }
}
