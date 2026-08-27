import Foundation
import OSLog

public struct LibraryScanner: Sendable {
    private static let logger = Logger(subsystem: "com.fcplibrarycleaner", category: "LibraryScanner")

    public init() {}

    /// Performs read-only filesystem analysis away from the caller's executor.
    public func scan(libraryURL: URL) async throws -> LibraryScanResult {
        try await scan(libraryURL: libraryURL, control: ScanControl(), onProgress: { _ in })
    }

    /// Progress is reported while traversing the Library. Cancellation never changes files.
    public func scan(
        libraryURL: URL,
        control: ScanControl,
        onProgress: @escaping @Sendable (ScanProgress) -> Void
    ) async throws -> LibraryScanResult {
        let standardizedURL = libraryURL.standardizedFileURL
        return try await Task.detached(priority: .userInitiated) {
            try Self.performScan(libraryURL: standardizedURL, control: control, onProgress: onProgress)
        }.value
    }

    /// Builds the validation token used by the app-level scan cache without traversing original
    /// media. Recognized generated directories are fingerprinted recursively.
    public func changeToken(libraryURL: URL) async throws -> LibraryChangeToken {
        let standardizedURL = libraryURL.standardizedFileURL
        return try await Task.detached(priority: .utility) {
            try Self.makeChangeToken(libraryURL: standardizedURL)
        }.value
    }

    private static func performScan(
        libraryURL: URL,
        control: ScanControl,
        onProgress: @escaping @Sendable (ScanProgress) -> Void
    ) throws -> LibraryScanResult {
        let fileManager = FileManager.default
        try validateLibrary(libraryURL, fileManager: fileManager)

        var issues: [ScanIssue] = []
        let libraryDatabaseURL = libraryURL.appendingPathComponent(FCPStructureRules.libraryDatabaseName)
        var coreDataSnapshots = [try coreDataSnapshot(for: libraryDatabaseURL, fileManager: fileManager)]
        var protectedItems = [ProtectedItem(url: libraryDatabaseURL, reason: .libraryDatabase)]
        var cacheItems: [CacheItem] = []
        var observedCacheItems: [ObservedCacheItem] = []
        let classifier = CacheClassifier()

        for (rule, candidateURL) in classifier.confirmedSharedCandidates(inLibrary: libraryURL, fileManager: fileManager) {
            try throwIfCancelled(control)
            cacheItems.append(try makeCacheItem(candidateURL, rule: rule, control: control, issues: &issues))
        }

        let children = try directChildren(of: libraryURL, fileManager: fileManager)
        var eventNames: [String] = []
        for child in children {
            try throwIfCancelled(control)
            let values = try resourceValues(for: child)

            if values.isSymbolicLink == true {
                protectedItems.append(ProtectedItem(url: child, reason: .symbolicLink))
                continue
            }
            guard values.isDirectory == true else {
                if child.lastPathComponent != FCPStructureRules.libraryDatabaseName {
                    protectedItems.append(ProtectedItem(url: child, reason: .unknownStructure))
                }
                continue
            }

            if isEventDirectory(child, fileManager: fileManager) {
                eventNames.append(child.lastPathComponent)
                let eventDatabaseURL = child.appendingPathComponent(FCPStructureRules.eventDatabaseName)
                coreDataSnapshots.append(try coreDataSnapshot(for: eventDatabaseURL, fileManager: fileManager))
                protectedItems.append(ProtectedItem(
                    url: eventDatabaseURL,
                    reason: .eventDatabase
                ))
                try appendEventItems(
                    eventURL: child,
                    classifier: classifier,
                    fileManager: fileManager,
                    control: control,
                    cacheItems: &cacheItems,
                    observedCacheItems: &observedCacheItems,
                    protectedItems: &protectedItems,
                    issues: &issues
                )
            } else if !FCPStructureRules.libraryCandidateRules.contains(where: { $0.relativePath.first == child.lastPathComponent }) {
                protectedItems.append(ProtectedItem(url: child, reason: .unknownStructure))
            }
        }

        if let cacheRoot = FCPStructureRules.externalCacheRoot(for: libraryURL, fileManager: fileManager) {
            for (rule, candidateURL) in classifier.confirmedExternalCandidates(
                cacheRoot: cacheRoot,
                eventNames: eventNames,
                fileManager: fileManager
            ) {
                try throwIfCancelled(control)
                cacheItems.append(try makeCacheItem(
                    candidateURL,
                    rule: rule,
                    storage: .external,
                    ruleID: FCPStructureRules.externalRulePrefix + rule.id,
                    control: control,
                    issues: &issues
                ))
            }
        }

        let total = try directorySize(
            of: libraryURL,
            fileManager: fileManager,
            control: control,
            onProgress: onProgress,
            issues: &issues
        )
        for snapshot in coreDataSnapshots {
            guard try coreDataSnapshot(for: snapshot.url, fileManager: fileManager) == snapshot else {
                throw CleanupError.fileChanged(snapshot.url)
            }
        }
        logger.info("Scanned \(libraryURL.path, privacy: .private(mask: .hash))")
        return LibraryScanResult(
            libraryURL: libraryURL,
            totalAllocatedSize: total.allocated,
            totalLogicalSize: total.logical,
            coreDataSnapshots: coreDataSnapshots.sorted { $0.url.path < $1.url.path },
            cacheItems: cacheItems.sorted { $0.url.path < $1.url.path },
            observedCacheItems: observedCacheItems.sorted { $0.url.path < $1.url.path },
            protectedItems: protectedItems.sorted { $0.url.path < $1.url.path },
            issues: issues
        )
    }

    private static func makeChangeToken(libraryURL: URL) throws -> LibraryChangeToken {
        let fileManager = FileManager.default
        try validateLibrary(libraryURL, fileManager: fileManager)
        let classifier = CacheClassifier()
        var databases = [try coreDataSnapshot(
            for: libraryURL.appendingPathComponent(FCPStructureRules.libraryDatabaseName),
            fileManager: fileManager
        )]
        var generatedURLs = classifier.confirmedSharedCandidates(
            inLibrary: libraryURL,
            fileManager: fileManager
        ).map(\.1)
        var eventNames: [String] = []

        for child in try directChildren(of: libraryURL, fileManager: fileManager)
            where isEventDirectory(child, fileManager: fileManager) {
            eventNames.append(child.lastPathComponent)
            databases.append(try coreDataSnapshot(
                for: child.appendingPathComponent(FCPStructureRules.eventDatabaseName),
                fileManager: fileManager
            ))
            generatedURLs.append(contentsOf: classifier.confirmedCandidates(
                inEvent: child,
                fileManager: fileManager
            ).map(\.1))
            generatedURLs.append(contentsOf: classifier.observedProtectedDirectories(
                inEvent: child,
                fileManager: fileManager
            ).map(\.1))
        }

        if let cacheRoot = FCPStructureRules.externalCacheRoot(for: libraryURL, fileManager: fileManager) {
            generatedURLs.append(contentsOf: classifier.confirmedExternalCandidates(
                cacheRoot: cacheRoot,
                eventNames: eventNames,
                fileManager: fileManager
            ).map(\.1))
        }

        let generated = try Set(generatedURLs.map(\.standardizedFileURL))
            .map { url in
                DirectoryChangeSnapshot(url: url, fingerprint: try CleanupPlan.fingerprint(for: url))
            }
            .sorted { $0.url.path < $1.url.path }
        return LibraryChangeToken(
            coreDataSnapshots: databases.sorted { $0.url.path < $1.url.path },
            generatedDirectories: generated
        )
    }

    private static func appendEventItems(
        eventURL: URL,
        classifier: CacheClassifier,
        fileManager: FileManager,
        control: ScanControl,
        cacheItems: inout [CacheItem],
        observedCacheItems: inout [ObservedCacheItem],
        protectedItems: inout [ProtectedItem],
        issues: inout [ScanIssue]
    ) throws {
        for (rule, candidateURL) in classifier.confirmedCandidates(inEvent: eventURL, fileManager: fileManager) {
            try throwIfCancelled(control)
            cacheItems.append(try makeCacheItem(candidateURL, rule: rule, control: control, issues: &issues))
        }

        for (rule, observedURL) in classifier.observedProtectedDirectories(inEvent: eventURL, fileManager: fileManager) {
            try throwIfCancelled(control)
            let size = try directorySize(of: observedURL, fileManager: fileManager, control: control, onProgress: { _ in }, issues: &issues)
            observedCacheItems.append(ObservedCacheItem(
                url: observedURL,
                category: rule.category,
                allocatedSize: size.allocated,
                logicalSize: size.logical,
                confidence: .likely,
                ruleID: rule.id
            ))
        }

        let originalMedia = eventURL.appendingPathComponent(FCPStructureRules.originalMediaName, isDirectory: true)
        if fileManager.fileExists(atPath: originalMedia.path) ||
            (try? fileManager.destinationOfSymbolicLink(atPath: originalMedia.path)) != nil {
            protectedItems.append(ProtectedItem(url: originalMedia, reason: .originalMedia))
        }

        // Show direct Event children that are not part of a confirmed rule, but never descend
        // into them or infer that a familiar-looking name is safe to remove.
        let candidateRoots = Set(FCPStructureRules.eventCandidateRules.compactMap(\.relativePath.first))
        let observedRoots = Set(FCPStructureRules.eventObservationRules.compactMap(\.relativePath.first))
        let children = try directChildren(of: eventURL, fileManager: fileManager)
        for child in children where child.lastPathComponent != FCPStructureRules.eventDatabaseName {
            if child.lastPathComponent == FCPStructureRules.originalMediaName {
                if !protectedItems.contains(where: { $0.url == child && $0.reason == .originalMedia }) {
                    protectedItems.append(ProtectedItem(url: child, reason: .originalMedia))
                }
                continue
            }
            guard !candidateRoots.contains(child.lastPathComponent) else { continue }
            guard !observedRoots.contains(child.lastPathComponent) else { continue }
            protectedItems.append(ProtectedItem(url: child, reason: .unknownStructure))
        }
    }

    private static func makeCacheItem(
        _ url: URL,
        rule: FCPStructureRules.CandidateRule,
        storage: CacheStorage = .library,
        ruleID: String? = nil,
        control: ScanControl,
        issues: inout [ScanIssue]
    ) throws -> CacheItem {
        try throwIfCancelled(control)
        let fingerprint = try CleanupPlan.fingerprint(for: url)
        return CacheItem(
            url: url,
            category: rule.category,
            allocatedSize: fingerprint.allocatedSize,
            logicalSize: fingerprint.logicalSize,
            confidence: .confirmed,
            ruleID: ruleID ?? rule.id,
            storage: storage,
            fingerprint: fingerprint
        )
    }

    private static func validateLibrary(_ url: URL, fileManager: FileManager) throws {
        guard url.pathExtension.lowercased() == "fcpbundle",
              isRealDirectory(url, fileManager: fileManager) else {
            throw CleanupError.invalidLibrary(url)
        }
        let databaseURL = url.appendingPathComponent(FCPStructureRules.libraryDatabaseName)
        guard fileManager.fileExists(atPath: databaseURL.path) else {
            throw CleanupError.invalidLibrary(url)
        }
    }

    private static func isEventDirectory(_ url: URL, fileManager: FileManager) -> Bool {
        let databaseURL = url.appendingPathComponent(FCPStructureRules.eventDatabaseName)
        return fileManager.fileExists(atPath: databaseURL.path)
    }

    private static func isRealDirectory(_ url: URL, fileManager: FileManager) -> Bool {
        guard fileManager.fileExists(atPath: url.path),
              let values = try? resourceValues(for: url) else { return false }
        return values.isDirectory == true && values.isSymbolicLink != true
    }

    private static func directChildren(of url: URL, fileManager: FileManager) throws -> [URL] {
        do {
            return try fileManager.contentsOfDirectory(
                at: url,
                includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                options: []
            )
        } catch CocoaError.fileReadNoPermission {
            throw CleanupError.permissionDenied(url)
        }
    }

    private static func resourceValues(for url: URL) throws -> URLResourceValues {
        try url.resourceValues(forKeys: [
            .isDirectoryKey,
            .isSymbolicLinkKey,
            .fileAllocatedSizeKey,
            .totalFileAllocatedSizeKey,
            .fileSizeKey,
            .totalFileSizeKey,
        ])
    }

    private static func coreDataSnapshot(for url: URL, fileManager: FileManager) throws -> CoreDataSnapshot {
        do {
            let attributes = try fileManager.attributesOfItem(atPath: url.path)
            return CoreDataSnapshot(
                url: url,
                size: (attributes[.size] as? NSNumber)?.int64Value ?? 0,
                modificationTime: (attributes[.modificationDate] as? Date)?.timeIntervalSinceReferenceDate ?? 0
            )
        } catch CocoaError.fileReadNoPermission {
            throw CleanupError.permissionDenied(url)
        }
    }

    private static func directorySize(
        of rootURL: URL,
        fileManager: FileManager,
        control: ScanControl,
        onProgress: @escaping @Sendable (ScanProgress) -> Void,
        issues: inout [ScanIssue]
    ) throws -> (allocated: Int64, logical: Int64) {
        var allocated: Int64 = 0
        var logical: Int64 = 0
        var files = 0
        var directories = 0
        let keys: Set<URLResourceKey> = [
            .isDirectoryKey,
            .isSymbolicLinkKey,
            .fileAllocatedSizeKey,
            .fileSizeKey,
        ]
        var enumerationFailure: Error?
        guard let enumerator = fileManager.enumerator(
            at: rootURL,
            includingPropertiesForKeys: Array(keys),
            options: [],
            errorHandler: { _, error in
                enumerationFailure = error
                return false
            }
        ) else {
            throw CleanupError.permissionDenied(rootURL)
        }

        for case let url as URL in enumerator {
            try throwIfCancelled(control)
            do {
                let values = try url.resourceValues(forKeys: keys)
                if values.isSymbolicLink == true {
                    if values.isDirectory == true { enumerator.skipDescendants() }
                    continue
                }
                if values.isDirectory == true {
                    directories += 1
                    continue
                }
                allocated += Int64(values.fileAllocatedSize ?? values.fileSize ?? 0)
                logical += Int64(values.fileSize ?? 0)
                files += 1
                if files.isMultiple(of: 256) {
                    onProgress(ScanProgress(files: files, directories: directories, allocatedBytes: allocated))
                }
            } catch {
                throw CleanupError.permissionDenied(url)
            }
        }
        if enumerationFailure != nil {
            throw CleanupError.permissionDenied(rootURL)
        }
        onProgress(ScanProgress(files: files, directories: directories, allocatedBytes: allocated))
        return (allocated, logical)
    }

    private static func throwIfCancelled(_ control: ScanControl) throws {
        if control.isCancelled { throw CancellationError() }
    }
}
