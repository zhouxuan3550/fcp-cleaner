import Foundation

public struct CleanupThroughputSample: Sendable, Codable, Equatable {
    public let date: Date
    public let bytes: Int64
    public let seconds: Double

    public init(date: Date, bytes: Int64, seconds: Double) {
        self.date = date
        self.bytes = bytes
        self.seconds = seconds
    }
}

/// Rolling per-volume cleanup throughput history.
///
/// Samples are bucketed by volume so slow external drives never get flattened
/// into an average dominated by fast internal-SSD cleanups.
public struct CleanupThroughputIndex: Sendable, Codable, Equatable {
    public private(set) var buckets: [String: [CleanupThroughputSample]] = [:]
    public static let maxSamplesPerVolume = 10
    public static let minimumSampleSeconds = 0.05

    public init() {}

    public init(buckets: [String: [CleanupThroughputSample]]) {
        self.buckets = buckets
    }

    public mutating func record(volumeID: String, bytes: Int64, seconds: Double) {
        guard seconds >= Self.minimumSampleSeconds, bytes > 0 else { return }
        var samples = buckets[volumeID] ?? []
        samples.append(CleanupThroughputSample(date: Date(), bytes: bytes, seconds: seconds))
        if samples.count > Self.maxSamplesPerVolume {
            samples.removeFirst(samples.count - Self.maxSamplesPerVolume)
        }
        buckets[volumeID] = samples
    }

    /// Byte-weighted mean across the rolling window; nil when the volume has no usable history yet.
    public func averageBytesPerSecond(volumeID: String) -> Double? {
        guard let samples = buckets[volumeID], !samples.isEmpty else { return nil }
        let totalBytes = samples.reduce(Int64(0)) { $0 + $1.bytes }
        let totalSeconds = samples.reduce(0.0) { $0 + $1.seconds }
        guard totalSeconds > 0 else { return nil }
        return Double(totalBytes) / totalSeconds
    }
}
