import Foundation
import OSLog

public struct LibraryScanner: Sendable {
    private static let logger = Logger(subsystem: "com.fcplibrarycleaner", category: "LibraryScanner")
    /// Instruments 与 Console.app 都能直接看到每次扫描的区间与耗时。
    private static let signposter = OSSignposter(subsystem: "com.fcplibrarycleaner", category: "scan")

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
            try await Self.performScan(libraryURL: standardizedURL, control: control, onProgress: onProgress)
        }.value
    }

    /// Builds the validation token used by the app-level scan cache without traversing original
    /// media. Recognized generated directories are fingerprinted recursively.
    public func changeToken(libraryURL: URL) async throws -> LibraryChangeToken {
        let standardizedURL = libraryURL.standardizedFileURL
        return try await Task.detached(priority: .utility) {
            try await Self.makeChangeToken(libraryURL: standardizedURL)
        }.value
    }

    /// 指纹收集队列的待办项：先做便宜的枚举与分类（几次 stat），把重量级的
    /// 逐文件遍历集中到统一的并行阶段。
    private enum PendingFingerprint: Sendable {
        case cacheItem(rule: FCPStructureRules.CandidateRule, url: URL, storage: CacheStorage, ruleID: String?)
        case observed(rule: FCPStructureRules.ObservationRule, url: URL)

        var url: URL {
            switch self {
            case .cacheItem(_, let url, _, _): url
            case .observed(_, let url): url
            }
        }
    }

    private static func performScan(
        libraryURL: URL,
        control: ScanControl,
        onProgress: @escaping @Sendable (ScanProgress) -> Void
    ) async throws -> LibraryScanResult {
        let startedAt = ContinuousClock.now
        let signpostState = signposter.beginInterval("ScanLibrary")
        defer { signposter.endInterval("ScanLibrary", signpostState) }
        let fileManager = FileManager.default
        try validateLibrary(libraryURL, fileManager: fileManager)

        let libraryDatabaseURL = libraryURL.appendingPathComponent(FCPStructureRules.libraryDatabaseName)
        var coreDataSnapshots = [try coreDataSnapshot(for: libraryDatabaseURL, fileManager: fileManager)]
        var protectedItems = [ProtectedItem(url: libraryDatabaseURL, reason: .libraryDatabase)]
        var pending: [PendingFingerprint] = []
        var eventNames: [String] = []
        let classifier = CacheClassifier()

        for (rule, candidateURL) in classifier.confirmedSharedCandidates(inLibrary: libraryURL, fileManager: fileManager) {
            try throwIfCancelled(control)
            pending.append(.cacheItem(rule: rule, url: candidateURL, storage: .library, ruleID: nil))
        }

        let children = try directChildren(of: libraryURL, fileManager: fileManager)
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
                try collectEventEntries(
                    eventURL: child,
                    classifier: classifier,
                    fileManager: fileManager,
                    pending: &pending,
                    protectedItems: &protectedItems
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
                pending.append(.cacheItem(
                    rule: rule,
                    url: candidateURL,
                    storage: .external,
                    ruleID: FCPStructureRules.externalRulePrefix + rule.id
                ))
            }
        }

        // 重量级指纹阶段：多 Event 库有几十棵缓存目录树，逐棵串行遍历时
        // 每棵的 I/O 延迟线性叠加；有界并行是扫描墙钟时间的最大杠杆。
        // 有界而非无界，避免机械盘被并发寻道拖垮。
        let fingerprints = try await fingerprintAll(pending.map(\.url), control: control)

        var cacheItems: [CacheItem] = []
        var observedCacheItems: [ObservedCacheItem] = []
        var observedFingerprints: [(URL, FileFingerprint)] = []
        cacheItems.reserveCapacity(pending.count)
        for (entry, fingerprint) in zip(pending, fingerprints) {
            switch entry {
            case .cacheItem(let rule, let url, let storage, let ruleID):
                cacheItems.append(makeCacheItem(url: url, rule: rule, storage: storage, ruleID: ruleID, fingerprint: fingerprint))
            case .observed(let rule, let url):
                observedCacheItems.append(ObservedCacheItem(
                    url: url,
                    category: rule.category,
                    allocatedSize: fingerprint.allocatedSize,
                    logicalSize: fingerprint.logicalSize,
                    confidence: .likely,
                    ruleID: rule.id
                ))
                observedFingerprints.append((url, fingerprint))
            }
        }
        try throwIfCancelled(control)

        // 库内缓存目录在上面已逐文件做过指纹遍历；总量遍历复用指纹结果并跳过这些
        // 子树，避免对渲染/代理/优化媒体（通常占文件数大头）做第二次全量遍历。
        var preCounted: [String: (allocated: Int64, logical: Int64, files: Int)] = [:]
        for item in cacheItems where item.storage == .library {
            preCounted[item.url.path] = (
                item.fingerprint.allocatedSize,
                item.fingerprint.logicalSize,
                item.fingerprint.entryCount
            )
        }
        for (url, fingerprint) in observedFingerprints {
            preCounted[url.path] = (fingerprint.allocatedSize, fingerprint.logicalSize, fingerprint.entryCount)
        }

        let totals = try directorySize(
            of: libraryURL,
            fileManager: fileManager,
            control: control,
            preCounted: preCounted,
            onProgress: onProgress
        )
        for snapshot in coreDataSnapshots {
            guard try coreDataSnapshot(for: snapshot.url, fileManager: fileManager) == snapshot else {
                throw CleanupError.fileChanged(snapshot.url)
            }
        }
        var generatedSnapshots: [DirectoryChangeSnapshot] = []
        for item in cacheItems {
            generatedSnapshots.append(DirectoryChangeSnapshot(url: item.url.standardizedFileURL, fingerprint: item.fingerprint))
        }
        for (url, fp) in observedFingerprints {
            generatedSnapshots.append(DirectoryChangeSnapshot(url: url.standardizedFileURL, fingerprint: fp))
        }
        var uniqueByPath: [String: DirectoryChangeSnapshot] = [:]
        for snap in generatedSnapshots {
            uniqueByPath[snap.url.path] = snap
        }
        let precomputedToken = LibraryChangeToken(
            coreDataSnapshots: coreDataSnapshots.sorted { $0.url.path < $1.url.path },
            generatedDirectories: uniqueByPath.values.sorted { $0.url.path < $1.url.path }
        )
        let elapsed = ContinuousClock.now - startedAt
        let elapsedMs = Int(elapsed.components.seconds) * 1000
            + Int(elapsed.components.attoseconds / 1_000_000_000_000_000)
        logger.info("Scan finished: \(totals.files) files / \(totals.directories) dirs / \(totals.allocated) bytes in \(elapsedMs)ms")
        // issues 恒为空：结构化问题清单的字段保留是为了缓存 schema 稳定（v4）。
        return LibraryScanResult(
            libraryURL: libraryURL,
            totalAllocatedSize: totals.allocated,
            totalLogicalSize: totals.logical,
            coreDataSnapshots: coreDataSnapshots.sorted { $0.url.path < $1.url.path },
            cacheItems: cacheItems.sorted { $0.url.path < $1.url.path },
            observedCacheItems: observedCacheItems.sorted { $0.url.path < $1.url.path },
            protectedItems: protectedItems.sorted { $0.url.path < $1.url.path },
            issues: [],
            changeToken: precomputedToken
        )
    }

    private static func makeChangeToken(libraryURL: URL) async throws -> LibraryChangeToken {
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

        let unique = Array(Set(generatedURLs.map(\.standardizedFileURL))).sorted { $0.path < $1.path }
        // 令牌构建与扫描共用同一并行指纹阶段；增量扫描每次都要走这趟，墙钟同等受益。
        let fingerprints = try await fingerprintAll(unique, control: ScanControl())
        let generated = zip(unique, fingerprints).map { url, fingerprint in
            DirectoryChangeSnapshot(url: url, fingerprint: fingerprint)
        }
        return LibraryChangeToken(
            coreDataSnapshots: databases.sorted { $0.url.path < $1.url.path },
            generatedDirectories: generated
        )
    }

    /// 有界并行的指纹收集。结果按入参顺序返回（索引即顺序），保证输出确定性；
    /// 首个错误会取消其余任务并原样抛出，保守失败语义与串行版本一致。
    private static func fingerprintAll(_ urls: [URL], control: ScanControl) async throws -> [FileFingerprint] {
        guard !urls.isEmpty else { return [] }
        var results = [FileFingerprint?](repeating: nil, count: urls.count)
        let limit = max(2, min(8, ProcessInfo.processInfo.activeProcessorCount))
        try await withThrowingTaskGroup(of: (index: Int, fingerprint: FileFingerprint).self) { group in
            var next = 0
            var inFlight = 0
            while next < urls.count || inFlight > 0 {
                if next < urls.count && inFlight < limit {
                    let index = next
                    next += 1
                    inFlight += 1
                    group.addTask {
                        try throwIfCancelled(control)
                        return (index, try CleanupPlan.fingerprint(for: urls[index]))
                    }
                } else {
                    guard let (index, fingerprint) = try await group.next() else { break }
                    results[index] = fingerprint
                    inFlight -= 1
                }
            }
        }
        return results.map { $0! }
    }

    /// 枚举一个 Event 的指纹待办与受保护条目；只做目录 stat，不做重量级遍历。
    private static func collectEventEntries(
        eventURL: URL,
        classifier: CacheClassifier,
        fileManager: FileManager,
        pending: inout [PendingFingerprint],
        protectedItems: inout [ProtectedItem]
    ) throws {
        for (rule, candidateURL) in classifier.confirmedCandidates(inEvent: eventURL, fileManager: fileManager) {
            pending.append(.cacheItem(rule: rule, url: candidateURL, storage: .library, ruleID: nil))
        }

        for (rule, observedURL) in classifier.observedProtectedDirectories(inEvent: eventURL, fileManager: fileManager) {
            pending.append(.observed(rule: rule, url: observedURL))
        }

        let originalMedia = eventURL.appendingPathComponent(FCPStructureRules.originalMediaName, isDirectory: true)
        var recordedOriginalMedia = false
        if fileManager.fileExists(atPath: originalMedia.path) ||
            (try? fileManager.destinationOfSymbolicLink(atPath: originalMedia.path)) != nil {
            protectedItems.append(ProtectedItem(url: originalMedia, reason: .originalMedia))
            recordedOriginalMedia = true
        }

        // Show direct Event children that are not part of a confirmed rule, but never descend
        // into them or infer that a familiar-looking name is safe to remove.
        let candidateRoots = Set(FCPStructureRules.eventCandidateRules.compactMap(\.relativePath.first))
        let observedRoots = Set(FCPStructureRules.eventObservationRules.compactMap(\.relativePath.first))
        let children = try directChildren(of: eventURL, fileManager: fileManager)
        for child in children where child.lastPathComponent != FCPStructureRules.eventDatabaseName {
            if child.lastPathComponent == FCPStructureRules.originalMediaName {
                if !recordedOriginalMedia {
                    protectedItems.append(ProtectedItem(url: child, reason: .originalMedia))
                    recordedOriginalMedia = true
                }
                continue
            }
            guard !candidateRoots.contains(child.lastPathComponent) else { continue }
            guard !observedRoots.contains(child.lastPathComponent) else { continue }
            protectedItems.append(ProtectedItem(url: child, reason: .unknownStructure))
        }
    }

    /// 纯构造：指纹已由并行阶段算好，这里只组装模型。
    private static func makeCacheItem(
        url: URL,
        rule: FCPStructureRules.CandidateRule,
        storage: CacheStorage,
        ruleID: String?,
        fingerprint: FileFingerprint
    ) -> CacheItem {
        CacheItem(
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
        guard let values = try? resourceValues(for: url) else { return false }
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

    private static let traversalKeys: Set<URLResourceKey> = [
        .isDirectoryKey,
        .isSymbolicLinkKey,
        .fileAllocatedSizeKey,
        .fileSizeKey,
    ]

    private struct TraversalTotals: Sendable {
        let allocated: Int64
        let logical: Int64
        let files: Int
        let directories: Int
    }

    private static func directorySize(
        of rootURL: URL,
        fileManager: FileManager,
        control: ScanControl,
        preCounted: [String: (allocated: Int64, logical: Int64, files: Int)],
        onProgress: @escaping @Sendable (ScanProgress) -> Void
    ) throws -> TraversalTotals {
        var allocated: Int64 = 0
        var logical: Int64 = 0
        var files = 0
        var directories = 0
        var entriesSinceCancelCheck = 0
        var lastHeartbeat = ContinuousClock.now
        let keys = traversalKeys
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
            // Kept outside the do/catch below so a cancel never gets rewrapped as a read error.
            // Sampling every 64 entries keeps the lock off the per-file hot path.
            if entriesSinceCancelCheck >= 64 {
                try throwIfCancelled(control)
                entriesSinceCancelCheck = 0
            }
            entriesSinceCancelCheck += 1
            do {
                let values = try url.resourceValues(forKeys: keys)
                if values.isSymbolicLink == true {
                    if values.isDirectory == true { enumerator.skipDescendants() }
                    continue
                }
                if values.isDirectory == true {
                    directories += 1
                    if let counted = preCounted[url.path] {
                        allocated += counted.allocated
                        logical += counted.logical
                        files += counted.files
                        enumerator.skipDescendants()
                        // 跳过的子树不会再按 256 个文件报点；跨越一档才补发一次进度
                        if counted.files >= 256 {
                            onProgress(ScanProgress(files: files, directories: directories, allocatedBytes: allocated))
                        }
                    }
                    continue
                }
                allocated += Int64(values.fileAllocatedSize ?? values.fileSize ?? 0)
                logical += Int64(values.fileSize ?? 0)
                files += 1
                if files.isMultiple(of: 256) {
                    onProgress(ScanProgress(files: files, directories: directories, allocatedBytes: allocated))
                    // 心跳：让"看起来卡住"可以从日志直接区分是慢还是真死
                    let now = ContinuousClock.now
                    if now - lastHeartbeat > .seconds(30) {
                        lastHeartbeat = now
                        logger.info("Scan heartbeat \(files) files / \(directories) dirs / \(allocated) bytes in \(rootURL.path, privacy: .private(mask: .hash))")
                    }
                }
            } catch {
                throw CleanupError.permissionDenied(url)
            }
        }
        try throwIfCancelled(control)
        if enumerationFailure != nil {
            throw CleanupError.permissionDenied(rootURL)
        }
        onProgress(ScanProgress(files: files, directories: directories, allocatedBytes: allocated))
        return TraversalTotals(allocated: allocated, logical: logical, files: files, directories: directories)
    }

    private static func throwIfCancelled(_ control: ScanControl) throws {
        if control.isCancelled { throw CancellationError() }
    }
}
