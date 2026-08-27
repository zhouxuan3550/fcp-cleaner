import Foundation

public enum CacheCategory: String, CaseIterable, Codable, Sendable {
    case renderFiles
    case proxyMedia
    case optimizedMedia
    case analysisFiles
    case opticalFlow
    case stabilization
    case thumbnails
    case waveform
    case otherCache

    public static let cleanableCases: [CacheCategory] = [.renderFiles, .proxyMedia, .optimizedMedia]

    public var displayName: String {
        switch self {
        case .renderFiles: "Render Files"
        case .proxyMedia: "Proxy Media"
        case .optimizedMedia: "Optimized Media"
        case .analysisFiles: "Analysis Files"
        case .opticalFlow: "Optical Flow"
        case .stabilization: "Stabilization"
        case .thumbnails: "Thumbnail Cache"
        case .waveform: "Waveform Cache"
        case .otherCache: "Other Regeneratable Cache"
        }
    }
}

public enum DetectionConfidence: String, Codable, Sendable {
    case confirmed
    case likely
    case unknown
}

public enum CacheStorage: String, Codable, Sendable {
    case library
    case external
}

public struct CacheItem: Codable, Hashable, Sendable, Identifiable {
    public let url: URL
    public let category: CacheCategory
    public let allocatedSize: Int64
    public let logicalSize: Int64
    public let confidence: DetectionConfidence
    public let ruleID: String
    public let storage: CacheStorage
    public let fingerprint: FileFingerprint

    public var id: URL { url }

    public init(
        url: URL,
        category: CacheCategory,
        allocatedSize: Int64,
        logicalSize: Int64,
        confidence: DetectionConfidence,
        ruleID: String,
        storage: CacheStorage = .library,
        fingerprint: FileFingerprint
    ) {
        self.url = url
        self.category = category
        self.allocatedSize = allocatedSize
        self.logicalSize = logicalSize
        self.confidence = confidence
        self.ruleID = ruleID
        self.storage = storage
        self.fingerprint = fingerprint
    }
}

public enum ProtectionReason: String, Codable, Sendable {
    case libraryDatabase
    case eventDatabase
    case originalMedia
    case symbolicLink
    case unknownStructure
}

public struct ProtectedItem: Codable, Hashable, Sendable, Identifiable {
    public let url: URL
    public let reason: ProtectionReason

    public var id: URL { url }

    public init(url: URL, reason: ProtectionReason) {
        self.url = url
        self.reason = reason
    }
}

public enum ObservedCacheCategory: String, Codable, Sendable {
    case analysisFiles
}

/// A recognized generated-data location that remains excluded from every cleanup plan.
public struct ObservedCacheItem: Codable, Hashable, Sendable, Identifiable {
    public let url: URL
    public let category: ObservedCacheCategory
    public let allocatedSize: Int64
    public let logicalSize: Int64
    public let confidence: DetectionConfidence
    public let ruleID: String

    public var id: URL { url }

    public init(
        url: URL,
        category: ObservedCacheCategory,
        allocatedSize: Int64,
        logicalSize: Int64,
        confidence: DetectionConfidence,
        ruleID: String
    ) {
        self.url = url
        self.category = category
        self.allocatedSize = allocatedSize
        self.logicalSize = logicalSize
        self.confidence = confidence
        self.ruleID = ruleID
    }
}

public struct ScanIssue: Codable, Hashable, Sendable, Identifiable {
    public let url: URL
    public let message: String

    public var id: String { "\(url.path):\(message)" }

    public init(url: URL, message: String) {
        self.url = url
        self.message = message
    }
}

public struct ScanProgress: Sendable, Equatable {
    public let files: Int
    public let directories: Int
    public let allocatedBytes: Int64

    public init(files: Int, directories: Int, allocatedBytes: Int64) {
        self.files = files
        self.directories = directories
        self.allocatedBytes = allocatedBytes
    }
}

/// Snapshot of FCP core data captured during a completed scan.
public struct CoreDataSnapshot: Codable, Hashable, Sendable, Identifiable {
    public let url: URL
    public let size: Int64
    public let modificationTime: TimeInterval

    public var id: URL { url }

    public init(url: URL, size: Int64, modificationTime: TimeInterval) {
        self.url = url
        self.size = size
        self.modificationTime = modificationTime
    }
}

public struct DirectoryChangeSnapshot: Codable, Hashable, Sendable, Identifiable {
    public let url: URL
    public let fingerprint: FileFingerprint

    public var id: URL { url }

    public init(url: URL, fingerprint: FileFingerprint) {
        self.url = url
        self.fingerprint = fingerprint
    }
}

/// A lightweight validation token for reusing a completed scan. It intentionally tracks only
/// FCP databases and recognized generated-data directories; cleanup still performs a fresh
/// fingerprint check immediately before moving anything.
public struct LibraryChangeToken: Codable, Hashable, Sendable {
    public let coreDataSnapshots: [CoreDataSnapshot]
    public let generatedDirectories: [DirectoryChangeSnapshot]

    public init(
        coreDataSnapshots: [CoreDataSnapshot],
        generatedDirectories: [DirectoryChangeSnapshot]
    ) {
        self.coreDataSnapshots = coreDataSnapshots
        self.generatedDirectories = generatedDirectories
    }
}

public struct LibraryScanResult: Codable, Sendable {
    public let libraryURL: URL
    public let totalAllocatedSize: Int64
    public let totalLogicalSize: Int64
    public let coreDataSnapshots: [CoreDataSnapshot]
    public let cacheItems: [CacheItem]
    public let observedCacheItems: [ObservedCacheItem]
    public let protectedItems: [ProtectedItem]
    public let issues: [ScanIssue]

    public var confirmedCleanableSize: Int64 {
        cacheItems
            .filter { $0.confidence == .confirmed }
            .reduce(0) { $0 + $1.allocatedSize }
    }

    public var externalCleanableSize: Int64 {
        cacheItems
            .filter { $0.confidence == .confirmed && $0.storage == .external }
            .reduce(0) { $0 + $1.allocatedSize }
    }
}

public enum CleanupError: Error, LocalizedError, Sendable {
    case invalidLibrary(URL)
    case libraryInUse
    case volumeOffline(URL)
    case readOnlyVolume(URL)
    case permissionDenied(URL)
    case unknownStructure(URL)
    case fileChanged(URL)
    case scanIncomplete(URL)
    case trashFailed(URL, String)

    public var errorDescription: String? {
        switch self {
        case .invalidLibrary(let url): "不是有效的 Final Cut Pro 资源库：\(url.path)"
        case .libraryInUse: "Final Cut Pro 正在使用此资源库，请先关闭该资源库后再清理。"
        case .volumeOffline: "资源库所在磁盘已离线或无法访问。"
        case .readOnlyVolume: "资源库所在磁盘为只读，无法移入废纸篓。"
        case .permissionDenied(let url): "没有访问权限：\(url.path)"
        case .unknownStructure(let url): "资源库结构无法确认：\(url.path)"
        case .fileChanged(let url): "扫描后文件已发生变化：\(url.path)"
        case .scanIncomplete(let url): "资源库未能完整扫描，无法创建清理计划：\(url.path)"
        case .trashFailed(let url, let message): "无法移入废纸篓：\(url.path)（\(message)）"
        }
    }
}
