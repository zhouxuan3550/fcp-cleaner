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

    public static func fingerprint(for url: URL) throws -> FileFingerprint {
        let fileManager = FileManager.default
        var enumerationError: Error?
        guard let enumerator = fileManager.enumerator(
            at: url,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey, .fileAllocatedSizeKey, .fileSizeKey, .contentModificationDateKey],
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
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isSymbolicLinkKey]
        for case let child as URL in enumerator {
            let values = try child.resourceValues(forKeys: keys)
            if values.isSymbolicLink == true {
                if values.isDirectory == true { enumerator.skipDescendants() }
                continue
            }
            guard values.isDirectory != true else { continue }
            let attributes = try fileManager.attributesOfItem(atPath: child.path)
            let logical = (attributes[.size] as? NSNumber)?.int64Value ?? 0
            let allocated = Int64((try? child.resourceValues(forKeys: [.fileAllocatedSizeKey]).fileAllocatedSize) ?? Int(logical))
            let modified = (attributes[.modificationDate] as? Date)?.timeIntervalSinceReferenceDate ?? 0
            let inode = (attributes[.systemFileNumber] as? NSNumber)?.int64Value ?? 0
            allocatedSize += allocated
            logicalSize += logical
            entryCount += 1
            contentsSignature &+= stableHash(
                "\(child.path)|\(allocated)|\(logical)|\(modified)|\(inode)"
            )
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

    private static func stableHash(_ string: String) -> UInt64 {
        // FNV-1a is sufficient here: this compares one plan within one cleanup session,
        // not an adversarial integrity proof.
        string.utf8.reduce(1_469_598_103_934_665_603) { hash, byte in
            (hash ^ UInt64(byte)) &* 1_099_511_628_211
        }
    }
}

public struct TrashedItem: Sendable {
    public let originalURL: URL
    public let trashURL: URL

    public init(originalURL: URL, trashURL: URL) {
        self.originalURL = originalURL
        self.trashURL = trashURL
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
