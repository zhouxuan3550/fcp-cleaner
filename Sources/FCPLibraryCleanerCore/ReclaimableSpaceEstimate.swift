import Darwin
import Foundation

/// An estimate for permanently removing the measured tree, not for moving it to Trash.
public struct ReclaimableSpaceEstimate: Codable, Hashable, Sendable {
    public let minimumBytes: Int64
    public let maximumBytes: Int64

    public init(minimumBytes: Int64, maximumBytes: Int64) {
        self.minimumBytes = minimumBytes
        self.maximumBytes = maximumBytes
    }

    /// Unsupported filesystems or unavailable metadata have no reliable range.
    public static func measure(at url: URL) throws -> ReclaimableSpaceEstimate? {
        guard try isAPFS(url) else { return nil }
        var accumulator = Accumulator()
        do {
            try BulkDirectoryWalker.walk(url, includePrivateSize: true) { accumulator.add($0) }
        } catch BulkDirectoryWalker.Failure.unsupported {
            return nil
        } catch is BulkDirectoryWalker.Failure {
            throw CleanupError.permissionDenied(url)
        }
        return accumulator.result
    }

    static func isAPFS(_ url: URL) throws -> Bool {
        var volume = statfs()
        guard statfs(url.path, &volume) == 0 else { throw CleanupError.volumeOffline(url) }
        let format = withUnsafeBytes(of: &volume.f_fstypename) {
            String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self)
        }
        return format == "apfs"
    }

    struct Accumulator {
        private var minimum: Int64 = 0
        private var maximum: Int64 = 0
        private var complete = true

        mutating func add(_ entry: BulkDirectoryWalker.Entry) {
            guard entry.type != UInt32(VDIR.rawValue), entry.type != UInt32(VLNK.rawValue) else { return }
            guard let privateBytes = entry.privateSize, let links = entry.linkCount, links > 0,
                  entry.totalAllocatedSize >= 0, privateBytes <= entry.totalAllocatedSize else {
                complete = false
                return
            }
            let lower = links == 1 ? privateBytes : 0
            let (newMinimum, minOverflow) = minimum.addingReportingOverflow(lower)
            let (newMaximum, maxOverflow) = maximum.addingReportingOverflow(entry.totalAllocatedSize)
            guard !minOverflow, !maxOverflow else { complete = false; return }
            minimum = newMinimum
            maximum = newMaximum
        }

        var result: ReclaimableSpaceEstimate? {
            complete ? ReclaimableSpaceEstimate(minimumBytes: minimum, maximumBytes: maximum) : nil
        }
    }
}
