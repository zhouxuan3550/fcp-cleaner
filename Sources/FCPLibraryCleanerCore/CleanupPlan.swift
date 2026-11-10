import Darwin
import Foundation

public struct FileFingerprint: Codable, Hashable, Sendable {
    public let allocatedSize: Int64
    public let logicalSize: Int64
    public let entryCount: Int
    public let contentsSignature: UInt64

    public init(allocatedSize: Int64, logicalSize: Int64, entryCount: Int, contentsSignature: UInt64) {
        self.allocatedSize = allocatedSize
        self.logicalSize = logicalSize
        self.entryCount = entryCount
        self.contentsSignature = contentsSignature
    }
}

struct FingerprintMeasurement: Sendable {
    let fingerprint: FileFingerprint
    let reclaimable: ReclaimableSpaceEstimate?
}

public struct CleanupPlanEntry: Codable, Hashable, Sendable, Identifiable {
    public let item: CacheItem
    public let fingerprint: FileFingerprint

    public var id: URL { item.url }
}

public struct CleanupPlan: Codable, Sendable {
    public let libraryURL: URL
    public let coreDataSnapshots: [CoreDataSnapshot]
    public let entries: [CleanupPlanEntry]

    public var spaceToFree: Int64 {
        entries.reduce(0) { $0 + $1.item.allocatedSize }
    }

    public init(scanResult: LibraryScanResult, categories: Set<CacheCategory>) throws {
        libraryURL = scanResult.libraryURL
        coreDataSnapshots = scanResult.coreDataSnapshots
        guard !coreDataSnapshots.isEmpty else { throw CleanupError.scanIncomplete(scanResult.libraryURL) }
        entries = scanResult.cacheItems
            .filter { $0.confidence == .confirmed && categories.contains($0.category) }
            .map { item in
                CleanupPlanEntry(item: item, fingerprint: item.fingerprint)
            }
    }

    public func retryingItemsNotCompleted(in result: CleanupResult) -> CleanupPlan? {
        let completedURLs = Set(result.movedToTrash)
        let remainingEntries = entries.filter { !completedURLs.contains($0.item.url) }
        guard !remainingEntries.isEmpty else { return nil }
        return CleanupPlan(
            libraryURL: libraryURL,
            coreDataSnapshots: coreDataSnapshots,
            entries: remainingEntries
        )
    }

    /// 按用户在确认弹窗中的勾选裁剪计划：只保留所选条目，库与数据库快照原样保留。
    /// 裁剪只缩小清理范围——裁剪后的计划每一条仍要经过完整预检与指纹复核，
    /// 不产生任何"绕过验证"的捷径（与 retryingItemsNotCompleted 同一安全模型）。
    public func filtering(keeping itemURLs: Set<URL>) -> CleanupPlan {
        let kept = entries.filter { itemURLs.contains($0.item.url) }
        return CleanupPlan(
            libraryURL: libraryURL,
            coreDataSnapshots: coreDataSnapshots,
            entries: kept
        )
    }

    /// 中断恢复（P4-7）：从事务日志重建"待清计划"。
    /// 仅保留仍未移入废纸篓（`isCompleted` 依据清理历史判定）且仍存在于原路径（`exists`）的条目；
    /// 全部无需重做时返回 nil。重建出的计划仍要走完整预检与指纹复核，绝不跳过任何安全验证。
    public func planForPendingEntries(
        exists: @Sendable (URL) -> Bool,
        isCompleted: @Sendable (URL) -> Bool
    ) -> CleanupPlan? {
        let pending = entries.filter { !isCompleted($0.item.url) && exists($0.item.url) }
        guard !pending.isEmpty else { return nil }
        return CleanupPlan(
            libraryURL: libraryURL,
            coreDataSnapshots: coreDataSnapshots,
            entries: pending
        )
    }

    private init(
        libraryURL: URL,
        coreDataSnapshots: [CoreDataSnapshot],
        entries: [CleanupPlanEntry]
    ) {
        self.libraryURL = libraryURL
        self.coreDataSnapshots = coreDataSnapshots
        self.entries = entries
    }

    private static let fingerprintKeys: Set<URLResourceKey> = [
        .isDirectoryKey,
        .isSymbolicLinkKey,
        .fileSizeKey,
        .fileAllocatedSizeKey,
        .contentModificationDateKey,
        // 持久文件身份。documentIdentifier 在 macOS 26+ 已全上下文返回 nil（实测），
        // fileIdentifier（即 st_ino）在直取与枚举器预取两种上下文都真实可用。
        .fileIdentifierKey,
    ]

    public static func fingerprint(for url: URL) throws -> FileFingerprint {
        do {
            return try bulkFingerprint(for: url)
        } catch BulkDirectoryWalker.Failure.unsupported {
            return try foundationFingerprint(for: url)
        } catch is BulkDirectoryWalker.Failure {
            throw CleanupError.permissionDenied(url)
        }
    }

    static func bulkFingerprint(for url: URL) throws -> FileFingerprint {
        try bulkMeasurement(for: url, includeEstimate: false).fingerprint
    }

    static func scanMeasurement(for url: URL) throws -> FingerprintMeasurement {
        let includeEstimate = try ReclaimableSpaceEstimate.isAPFS(url)
        do {
            return try bulkMeasurement(for: url, includeEstimate: includeEstimate)
        } catch BulkDirectoryWalker.Failure.unsupported {
            do {
                return try FingerprintMeasurement(fingerprint: bulkFingerprint(for: url), reclaimable: nil)
            } catch BulkDirectoryWalker.Failure.unsupported {
                return try FingerprintMeasurement(fingerprint: foundationFingerprint(for: url), reclaimable: nil)
            } catch is BulkDirectoryWalker.Failure {
                throw CleanupError.permissionDenied(url)
            }
        } catch is BulkDirectoryWalker.Failure {
            throw CleanupError.permissionDenied(url)
        }
    }

    private static func bulkMeasurement(for url: URL, includeEstimate: Bool) throws -> FingerprintMeasurement {
        var allocatedSize: Int64 = 0
        var logicalSize: Int64 = 0
        var entryCount = 0
        var contentsSignature: UInt64 = 0
        var parentHashes: [String: FNVHasher] = [:]
        var estimate = ReclaimableSpaceEstimate.Accumulator()
        try BulkDirectoryWalker.walk(url, includePrivateSize: includeEstimate) { entry in
            if includeEstimate { estimate.add(entry) }
            guard entry.type != UInt32(VDIR.rawValue), entry.type != UInt32(VLNK.rawValue) else { return }
            allocatedSize += entry.allocatedSize
            logicalSize += entry.logicalSize
            entryCount += 1
            var hasher: FNVHasher
            if let parent = parentHashes[entry.parentPath] {
                hasher = parent
            } else {
                var parent = FNVHasher()
                parent.combine(entry.parentPath.utf8)
                if entry.parentPath != "/" { parent.combine(UInt8(ascii: "/")) }
                parentHashes[entry.parentPath] = parent
                hasher = parent
            }
            hasher.combine(entry.name.utf8)
            hasher.combine(UInt8(ascii: "|"))
            hasher.combine(entry.allocatedSize)
            hasher.combine(UInt8(ascii: "|"))
            hasher.combine(entry.logicalSize)
            hasher.combine(UInt8(ascii: "|"))
            hasher.combine(entry.modificationTime)
            hasher.combine(UInt8(ascii: "|"))
            hasher.combine(entry.fileID)
            contentsSignature &+= hasher.hash
        }
        return FingerprintMeasurement(
            fingerprint: FileFingerprint(allocatedSize: allocatedSize, logicalSize: logicalSize,
                                         entryCount: entryCount, contentsSignature: contentsSignature),
            reclaimable: includeEstimate ? estimate.result : nil
        )
    }

    static func foundationFingerprint(for url: URL) throws -> FileFingerprint {
        let fileManager = FileManager.default
        var enumerationError: Error?
        guard let enumerator = fileManager.enumerator(
            at: url,
            includingPropertiesForKeys: Array(fingerprintKeys),
            options: [],
            errorHandler: { _, error in
                enumerationError = error
                return false
            }
        ) else {
            throw CleanupError.permissionDenied(url)
        }

        var allocatedSize: Int64 = 0
        var logicalSize: Int64 = 0
        var entryCount = 0
        var contentsSignature: UInt64 = 0
        for case let child as URL in enumerator {
            let values = try child.resourceValues(forKeys: fingerprintKeys)
            if values.isSymbolicLink == true {
                if values.isDirectory == true { enumerator.skipDescendants() }
                continue
            }
            guard values.isDirectory != true else { continue }
            let logical = Int64(values.fileSize ?? 0)
            let allocated = Int64(values.fileAllocatedSize ?? values.fileSize ?? 0)
            let modified = values.contentModificationDate?.timeIntervalSinceReferenceDate ?? 0
            let fileID = values.fileIdentifier ?? 0
            allocatedSize += allocated
            logicalSize += logical
            entryCount += 1
            var hasher = FNVHasher()
            hasher.combine(child.path.utf8)
            hasher.combine(UInt8(ascii: "|"))
            hasher.combine(allocated)
            hasher.combine(UInt8(ascii: "|"))
            hasher.combine(logical)
            hasher.combine(UInt8(ascii: "|"))
            hasher.combine(modified)
            hasher.combine(UInt8(ascii: "|"))
            hasher.combine(UInt64(bitPattern: Int64(fileID)))
            contentsSignature &+= hasher.hash
        }
        if enumerationError != nil {
            throw CleanupError.permissionDenied(url)
        }

        return FileFingerprint(
            allocatedSize: allocatedSize,
            logicalSize: logicalSize,
            entryCount: entryCount,
            contentsSignature: contentsSignature
        )
    }

    private struct FNVHasher {
        private(set) var hash: UInt64 = 1_469_598_103_934_665_603

        @inline(__always)
        mutating func combine(_ byte: UInt8) {
            hash = (hash ^ UInt64(byte)) &* 1_099_511_628_211
        }

        @inline(__always)
        mutating func combine<S: Sequence>(_ bytes: S) where S.Element == UInt8 {
            for byte in bytes {
                combine(byte)
            }
        }

        @inline(__always)
        mutating func combine(_ value: Int64) {
            combine(UInt64(bitPattern: value))
        }

        @inline(__always)
        mutating func combine(_ value: UInt64) {
            var v = value.littleEndian
            withUnsafeBytes(of: &v) { bytes in
                for byte in bytes {
                    combine(byte)
                }
            }
        }

        @inline(__always)
        mutating func combine(_ value: Double) {
            combine(value.bitPattern)
        }
    }
}

public struct TrashedItem: Sendable {
    public let originalURL: URL
    public let trashURL: URL
    public let snapshot: TrashItemSnapshot?

    public init(originalURL: URL, trashURL: URL, snapshot: TrashItemSnapshot? = nil) {
        self.originalURL = originalURL
        self.trashURL = trashURL
        self.snapshot = snapshot
    }
}

public struct CleanupResult: Sendable {
    public let movedToTrash: [URL]
    public let trashedItems: [TrashedItem]
    public let freedAllocatedSize: Int64
    public let errors: [CleanupError]

    public init(
        movedToTrash: [URL],
        trashedItems: [TrashedItem] = [],
        freedAllocatedSize: Int64,
        errors: [CleanupError]
    ) {
        self.movedToTrash = movedToTrash
        self.trashedItems = trashedItems
        self.freedAllocatedSize = freedAllocatedSize
        self.errors = errors
    }
}
