import Foundation

public enum InspectionDisposition: String, Codable, Sendable {
    case cleanupCandidate
    case protectedData
    case unknown
}

public struct InspectionEntry: Codable, Hashable, Sendable, Identifiable {
    public let url: URL
    public let isDirectory: Bool
    public let disposition: InspectionDisposition

    public var id: URL { url }
}

public struct InspectionReport: Codable, Sendable {
    public let entries: [InspectionEntry]
    public let isTruncated: Bool
}

/// Developer-oriented directory tree. It deliberately skips Original Media descendants and caps
/// results, so opening the inspector cannot exhaust memory on a multi-terabyte Library.
public struct LibraryInspector: Sendable {
    public init() {}

    public func inspect(
        scanResult: LibraryScanResult,
        maximumEntries: Int = 20_000,
        control: ScanControl = ScanControl()
    ) async throws -> InspectionReport {
        try await Task.detached(priority: .utility) {
            try Self.inspectSynchronously(scanResult: scanResult, maximumEntries: maximumEntries, control: control)
        }.value
    }

    private static func inspectSynchronously(
        scanResult: LibraryScanResult,
        maximumEntries: Int,
        control: ScanControl
    ) throws -> InspectionReport {
        let fileManager = FileManager.default
        let libraryURL = scanResult.libraryURL
        let candidateURLs = Set(scanResult.cacheItems.map(\.url))
        let protectedReasons = Dictionary(uniqueKeysWithValues: scanResult.protectedItems.map { ($0.url, $0.reason) })
        let observedURLs = Set(scanResult.observedCacheItems.map(\.url))
        let originalMediaURLs = Set(scanResult.protectedItems.filter { $0.reason == .originalMedia }.map(\.url))
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isSymbolicLinkKey]
        var entries: [InspectionEntry] = []
        var truncated = false

        guard let enumerator = fileManager.enumerator(
            at: libraryURL,
            includingPropertiesForKeys: Array(keys),
            options: [],
            errorHandler: { _, _ in false }
        ) else {
            throw CleanupError.permissionDenied(libraryURL)
        }

        for case let url as URL in enumerator {
            if control.isCancelled { throw CancellationError() }
            if entries.count >= maximumEntries {
                truncated = true
                break
            }

            let values: URLResourceValues
            do {
                values = try url.resourceValues(forKeys: keys)
            } catch {
                throw CleanupError.permissionDenied(url)
            }

            let disposition: InspectionDisposition
            if candidateURLs.contains(url) {
                disposition = .cleanupCandidate
                if values.isDirectory == true { enumerator.skipDescendants() }
            } else if observedURLs.contains(url) || (protectedReasons[url].map { $0 != .unknownStructure } ?? false) {
                disposition = .protectedData
                if originalMediaURLs.contains(url), values.isDirectory == true { enumerator.skipDescendants() }
            } else if values.isSymbolicLink == true {
                disposition = .protectedData
                if values.isDirectory == true { enumerator.skipDescendants() }
            } else {
                disposition = .unknown
            }

            entries.append(InspectionEntry(url: url, isDirectory: values.isDirectory == true, disposition: disposition))
        }

        return InspectionReport(entries: entries, isTruncated: truncated)
    }
}
