import AppKit
import Foundation
import UniformTypeIdentifiers
import FCPLibraryCleanerCore

// MARK: - 发现：Spotlight / 工作目录 / 手动添加与候选校验
extension LibraryStore {
    func discoverLibraries() {
        discoveryRunID = UUID()
        orphanDiscoveryTask?.cancel()
        possibleOrphanCaches = []
        if let metadataQuery {
            metadataQuery.stop()
            NotificationCenter.default.removeObserver(self, name: .NSMetadataQueryDidFinishGathering, object: metadataQuery)
            NotificationCenter.default.removeObserver(self, name: .NSMetadataQueryDidUpdate, object: metadataQuery)
        }

        discoveryError = nil
        isDiscovering = true
        if !workDirectories.isEmpty {
            let runID = discoveryRunID
            let roots = workDirectories
            Task {
                let outcome = await Task.detached(priority: .userInitiated) {
                    Self.findLibraries(in: roots)
                }.value
                guard runID == discoveryRunID else { return }
                merge(
                    libraryURLs: outcome.byRoot.values.flatMap { $0 },
                    selectNewest: selectedID == nil,
                    source: .workDirectory
                )
                let now = Date()
                workDirectoryStatuses = Dictionary(
                    uniqueKeysWithValues: outcome.byRoot.map { rootURL, libs in
                        (rootURL, WorkDirectoryStatus(
                            discoveredCount: libs.count,
                            failed: outcome.failedRoots.contains(rootURL),
                            updatedAt: now
                        ))
                    }
                )
                isDiscovering = false
                let knownLibraries = Array(Set(libraries.map(\.url) + outcome.byRoot.values.flatMap { $0 }))
                orphanDiscoveryTask = Task {
                    let references = await Task.detached(priority: .utility) {
                        knownLibraries.compactMap { FCPStructureRules.externalCacheRoot(for: $0) }
                    }.value
                    let candidates = outcome.orphanCandidates.candidates(referencedRoots: references)
                    for candidate in candidates {
                        guard !Task.isCancelled, runID == discoveryRunID else { return }
                        let result = await OrphanCacheDiscovery.measure(candidate)
                        guard !Task.isCancelled, runID == discoveryRunID else { return }
                        possibleOrphanCaches.append(result)
                    }
                }
            }
            return
        }

        let query = NSMetadataQuery()
        query.searchScopes = [NSMetadataQueryLocalComputerScope]
        query.predicate = NSPredicate(
            format: "%K ENDSWITH[c] %@",
            NSMetadataItemFSNameKey,
            ".fcpbundle"
        )
        query.sortDescriptors = [NSSortDescriptor(key: NSMetadataItemPathKey, ascending: true)]
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(metadataQueryDidFinish(_:)),
            name: .NSMetadataQueryDidFinishGathering,
            object: query
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(metadataQueryDidUpdate(_:)),
            name: .NSMetadataQueryDidUpdate,
            object: query
        )
        metadataQuery = query
        if !query.start() {
            isDiscovering = false
            discoveryError = "自动扫描未能启动"
        }
    }

    @objc private func metadataQueryDidFinish(_ notification: Notification) {
        ingestMetadataResults()
        isDiscovering = false
    }

    @objc private func metadataQueryDidUpdate(_ notification: Notification) {
        ingestMetadataResults()
    }

    private func ingestMetadataResults() {
        guard let query = metadataQuery else { return }
        query.disableUpdates()
        let urls = query.results.compactMap { result -> URL? in
            guard let item = result as? NSMetadataItem else { return nil }
            return item.value(forAttribute: NSMetadataItemURLKey) as? URL
        }
        merge(libraryURLs: urls, selectNewest: selectedID == nil, source: .spotlightSearch)
        query.enableUpdates()
    }

    func openLibraryPanel() {
        let panel = NSOpenPanel()
        panel.title = "选择 Final Cut Pro 资源库"
        panel.prompt = "选择资源库"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.treatsFilePackagesAsDirectories = false
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [UTType(importedAs: "com.apple.finalcutprolibrary")]
        panel.directoryURL = selectedLibrary?.url.deletingLastPathComponent() ?? workDirectories.first
        if panel.runModal() == .OK {
            add(libraryURLs: panel.urls)
        }
    }

    func openWorkDirectoryPanel() {
        let panel = NSOpenPanel()
        panel.title = "选择工作目录"
        panel.prompt = "设为工作目录"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = true
        panel.directoryURL = workDirectories.first
        if panel.runModal() == .OK {
            addWorkDirectories(panel.urls)
        }
    }

    func addWorkDirectories(_ urls: [URL]) {
        let existing = Set(workDirectories)
        workDirectories.append(contentsOf: urls.map(\.standardizedFileURL).filter { !existing.contains($0) })
        workDirectories.sort { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
        bookmarks.saveWorkDirectories(workDirectories)
        workDirectoryMonitor?.updateWatched(paths: workDirectories.map(\.path))
        discoverLibraries()
    }

    func removeWorkDirectory(_ url: URL) {
        workDirectories.removeAll { $0 == url.standardizedFileURL }
        workDirectoryStatuses.removeValue(forKey: url.standardizedFileURL)
        workDirectoryStatuses.removeValue(forKey: url)
        bookmarks.saveWorkDirectories(workDirectories)
        workDirectoryMonitor?.updateWatched(paths: workDirectories.map(\.path))
        discoverLibraries()
    }

    func add(libraryURLs: [URL]) {
        merge(libraryURLs: libraryURLs, selectNewest: true, source: .manualAdd)
    }

    private func merge(libraryURLs: [URL], selectNewest: Bool, source: DiscoverySource) {
        // 候选校验涉及 fileExists/statfs/数据库探测，网络路径可能阻塞——全部后台执行。
        // 已入库的 URL 跳过重验：Spotlight 的 DidUpdate 会高频触发，
        // 对几十上百个已知库反复做三次文件系统调用纯属浪费。
        let knownURLs = Set(libraries.map(\.url.standardizedFileURL))
        let ignoredDirectories = ignoredLibraryDirectories
        pendingMergeCount += 1
        Task { [weak self] in
            let candidates = await Task.detached(priority: .utility) {
                Self.validateCandidatesWithMetadata(
                    libraryURLs,
                    source: source,
                    knownURLs: knownURLs,
                    ignoredDirectoryPaths: ignoredDirectories
                )
            }.value
            guard let self else { return }
            applyValidatedCandidates(candidates, selectNewest: selectNewest, source: source)
            pendingMergeCount -= 1
        }
    }

    /// internal 以便 App 测试直接验证发现层忽略闸门。
    nonisolated static func validateCandidates(
        _ libraryURLs: [URL],
        source: DiscoverySource,
        knownURLs: Set<URL> = [],
        ignoredDirectoryPaths: [String] = []
    ) -> [URL] {
        validateCandidatesWithMetadata(
            libraryURLs,
            source: source,
            knownURLs: knownURLs,
            ignoredDirectoryPaths: ignoredDirectoryPaths
        ).map(\.url)
    }

    /// 校验 + 建档元数据一次取齐。卷信息查询与数据库 stat 都是文件系统调用，
    /// 必须留在后台发现流程里完成，主线程只做纯内存建档。
    nonisolated static func validateCandidatesWithMetadata(
        _ libraryURLs: [URL],
        source: DiscoverySource,
        knownURLs: Set<URL> = [],
        ignoredDirectoryPaths: [String] = []
    ) -> [ValidatedLibraryCandidate] {
        Set(libraryURLs.map(\.standardizedFileURL))
            .filter { url in
                if knownURLs.contains(url) { return true } // 已验证过，直接放行
                guard url.pathExtension.lowercased() == "fcpbundle" else { return false }
                // 目录级忽略只拦自动发现（工作目录/Spotlight）；手动添加是显式意图，不拦。
                if source != .manualAdd,
                   LibraryIgnoreRules.isInsideIgnoredDirectory(recordPath: url.path, directoryPaths: ignoredDirectoryPaths) {
                    return false
                }
                var isDirectory: ObjCBool = false
                guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
                      isDirectory.boolValue else { return false }
                if source == .spotlightSearch, !allowsSpotlightDiscovery(url) { return false }
                return libraryDatabaseExists(at: url)
            }
            .sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
            .map { url in
                // 已入库的 URL 会命中现有记录，无需为它探测元数据。
                guard !knownURLs.contains(url) else {
                    return ValidatedLibraryCandidate(url: url)
                }
                let metadata = prefetchRecordMetadata(for: url)
                return ValidatedLibraryCandidate(
                    url: url,
                    volumeURL: metadata.volumeURL,
                    volumeName: metadata.volumeName,
                    volumeID: metadata.volumeID,
                    lastActivity: metadata.lastActivity
                )
            }
    }

    nonisolated private static func prefetchRecordMetadata(
        for url: URL
    ) -> (volumeURL: URL, volumeName: String, volumeID: String?, lastActivity: Date?) {
        let values = try? url.resourceValues(forKeys: [.volumeURLKey, .volumeNameKey, .volumeUUIDStringKey])
        let volumeURL = values?.allValues[.volumeURLKey] as? URL ?? URL(fileURLWithPath: "/")
        let lastActivity = (try? FileManager.default.attributesOfItem(
            atPath: url.appendingPathComponent(FCPStructureRules.libraryDatabaseName).path
        )[.modificationDate]) as? Date
        return (volumeURL, values?.volumeName ?? volumeURL.lastPathComponent, values?.volumeUUIDString, lastActivity)
    }

    @MainActor
    private func applyValidatedCandidates(_ candidates: [ValidatedLibraryCandidate], selectNewest: Bool, source: DiscoverySource) {
        guard !candidates.isEmpty else { return }
        var newRecords: [LibraryRecord] = []
        var recordsByURL = Dictionary(
            libraries.map { ($0.url.standardizedFileURL, $0) },
            uniquingKeysWith: { existing, _ in existing }
        )
        for candidate in candidates {
            let standardizedURL = candidate.url
            if let existing = recordsByURL[standardizedURL] {
                if selectNewest { selectedID = existing.id }
                continue
            }
            let record = LibraryRecord(url: standardizedURL, discoveredVia: source, prefetched: candidate)
            libraries.append(record)
            recordsByURL[standardizedURL] = record
            newRecords.append(record)
            if selectNewest { selectedID = record.id }
        }

        libraries.sort { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
        if selectedID == nil { selectedID = libraries.first?.id }
        for record in newRecords { scan(record, force: false) }
        if !newRecords.isEmpty { saveRecents() }
    }

    @MainActor
    private func applyValidatedCandidates(_ candidates: [URL], selectNewest: Bool, source: DiscoverySource) {
        guard !candidates.isEmpty else { return }
        var newRecords: [LibraryRecord] = []
        var recordsByURL = Dictionary(
            libraries.map { ($0.url.standardizedFileURL, $0) },
            uniquingKeysWith: { existing, _ in existing }
        )
        for url in candidates {
            let standardizedURL = url.standardizedFileURL
            if let existing = recordsByURL[standardizedURL] {
                if selectNewest { selectedID = existing.id }
                continue
            }
            let record = LibraryRecord(url: standardizedURL, discoveredVia: source)
            libraries.append(record)
            recordsByURL[standardizedURL] = record
            newRecords.append(record)
            if selectNewest { selectedID = record.id }
        }

        libraries.sort { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
        if selectedID == nil { selectedID = libraries.first?.id }
        for record in newRecords { scan(record, force: false) }
        if !newRecords.isEmpty { saveRecents() }
    }

    nonisolated static func findLibraries(
        in roots: [URL]
    ) -> (byRoot: [URL: [URL]], failedRoots: Set<URL>, orphanCandidates: OrphanCacheDiscovery) {
        let fileManager = FileManager.default
        var byRoot: [URL: [URL]] = [:]
        var failedRoots = Set<URL>()
        var orphanCandidates = OrphanCacheDiscovery()
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey]

        for root in roots {
            let standardizedRoot = root.standardizedFileURL
            if isLibraryDirectory(standardizedRoot, fileManager: fileManager) {
                byRoot[standardizedRoot] = [standardizedRoot]
                continue
            }
            final class LockedFlag: @unchecked Sendable {
                private let lock = NSLock()
                private var value = false
                var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
                func set() { lock.lock(); value = true; lock.unlock() }
            }
            let hadError = LockedFlag()
            guard let enumerator = fileManager.enumerator(
                at: standardizedRoot,
                includingPropertiesForKeys: keys,
                options: [.skipsHiddenFiles, .skipsPackageDescendants],
                errorHandler: { _, _ in
                    hadError.set()
                    return true
                }
            ) else {
                failedRoots.insert(standardizedRoot)
                continue
            }

            var found: [URL] = []
            for case let url as URL in enumerator {
                if url.pathExtension.lowercased() == "fcpbundle" {
                    if isLibraryDirectory(url, fileManager: fileManager) {
                        found.append(url.standardizedFileURL)
                        enumerator.skipDescendants()
                    }
                } else if OrphanCacheDiscovery.recognizedNames.contains(url.lastPathComponent),
                          let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
                          values.isDirectory == true, values.isSymbolicLink != true {
                    orphanCandidates.observe(url, under: standardizedRoot)
                }
            }
            if hadError.isSet { failedRoots.insert(standardizedRoot) }
            byRoot[standardizedRoot] = found.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
        }
        return (byRoot, failedRoots, orphanCandidates)
    }

    nonisolated private static func isLibraryDirectory(_ url: URL, fileManager: FileManager) -> Bool {
        guard url.pathExtension.lowercased() == "fcpbundle",
              let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]) else {
            return false
        }
        return values.isDirectory == true && values.isSymbolicLink != true
    }

    nonisolated private static func allowsSpotlightDiscovery(_ libraryURL: URL) -> Bool {
        var volumeStat = statfs()
        guard statfs(libraryURL.path, &volumeStat) == 0,
              let values = try? libraryURL.resourceValues(forKeys: [.volumeURLKey]),
              let volumeURL = values.allValues[.volumeURLKey] as? URL else { return false }
        let localMount = volumeStat.f_flags & UInt32(MNT_LOCAL) != 0
        return LibraryDiscoveryRules.allowsSpotlightDiscovery(
            localMount: localMount,
            volumeName: volumeURL.lastPathComponent
        )
    }

    /// Cheap structural validation before a candidate earns a scan slot.
    nonisolated private static func libraryDatabaseExists(at libraryURL: URL) -> Bool {
        FileManager.default.fileExists(atPath: libraryURL.appendingPathComponent(FCPStructureRules.libraryDatabaseName).path)
    }
}
