import AppKit
import Foundation
import Observation
import SwiftUI
import UniformTypeIdentifiers
import FCPLibraryCleanerCore

enum DiscoverySource: String, Codable, Sendable {
    case manualAdd
    case workDirectory
    case spotlightSearch

    /// Sidebar-row suffix; manually added libraries stay unlabeled.
    var title: String? {
        switch self {
        case .manualAdd: nil
        case .workDirectory: "工作目录"
        case .spotlightSearch: "本机发现"
        }
    }
}

@Observable @MainActor
final class LibraryRecord: Identifiable {
    let id = UUID()
    let url: URL
    let volumeURL: URL
    let volumeName: String
    let volumeID: String?
    var scanResult: LibraryScanResult?
    var isScanning = false
    var isQueued = false
    var usedCachedScan = false
    var scanProgress = ScanProgress(files: 0, directories: 0, allocatedBytes: 0)
    var scanError: String?
    var cleanupError: String?
    var lastCleanup: CleanupResult?
    var failedCleanupPlan: CleanupPlan?
    var cleanupBeforeSize: Int64?
    var cleanupAfterSize: Int64?
    var inspectorReport: InspectionReport?
    var isInspecting = false
    var accessReport: VolumeAccessReport?
    var isDiagnosingVolume = false
    var lastAccessibleAt: Date?
    var lastScanned: Date?
    var lastKnownTotalSize: Int64?
    var lastKnownCleanableSize: Int64?
    var pendingFreedSize: Int64 = 0
    var lastActivity: Date?
    var ignoredUntil: Date?
    let discoverySource: DiscoverySource?
    @ObservationIgnored var scanControl: ScanControl?

    init(url: URL, restored: RestoredLibrary? = nil, discoveredVia source: DiscoverySource? = nil) {
        self.url = url
        let values = try? url.resourceValues(forKeys: [.volumeURLKey, .volumeNameKey, .volumeUUIDStringKey])
        volumeURL = values?.allValues[.volumeURLKey] as? URL ?? URL(fileURLWithPath: "/")
        volumeName = values?.volumeName ?? volumeURL.lastPathComponent
        volumeID = values?.volumeUUIDString
        lastScanned = restored?.metadata.lastScanned
        lastKnownTotalSize = restored?.metadata.totalAllocatedSize
        lastKnownCleanableSize = restored?.metadata.cleanableSize
        lastActivity = restored?.metadata.lastActivity ?? Self.activityDate(for: url)
        ignoredUntil = restored?.metadata.ignoredUntil
        discoverySource = restored?.metadata.discoverySourceRaw.flatMap(DiscoverySource.init(rawValue:)) ?? source
    }

    fileprivate static func activityDate(for libraryURL: URL) -> Date? {
        let database = libraryURL.appendingPathComponent(FCPStructureRules.libraryDatabaseName)
        return (try? FileManager.default.attributesOfItem(atPath: database.path)[.modificationDate]) as? Date
    }

    var displayName: String { url.deletingPathExtension().lastPathComponent }
    var spaceToFree: Int64 {
        guard let scanResult else { return 0 }
        return scanResult.cacheItems
            .reduce(0) { $0 + $1.allocatedSize }
    }
}

enum LibraryFilter: String, CaseIterable, Identifiable {
    case waiting
    case scanning
    case skipped
    case ignored

    var id: Self { self }

    var title: String {
        switch self {
        case .waiting: "待清理"
        case .scanning: "扫描中"
        case .skipped: "已跳过"
        case .ignored: "已忽略"
        }
    }
}

enum InactivityFilter: Int, CaseIterable, Identifiable {
    case all = 0
    case days30 = 30
    case days90 = 90
    case days180 = 180

    var id: Self { self }
    var title: String { self == .all ? "全部时间" : "\(rawValue) 天未使用" }
}

enum LibrarySort: String, CaseIterable, Identifiable {
    case sizeDescending
    case name
    case recentActivity

    var id: Self { self }

    var title: String {
        switch self {
        case .sizeDescending: "按大小"
        case .name: "按名称"
        case .recentActivity: "按最近使用"
        }
    }
}

enum AppearanceMode: Int, CaseIterable, Identifiable {
    case system = 0
    case dark = 1
    case light = 2

    var id: Self { self }

    var title: String {
        switch self {
        case .system: "跟随系统"
        case .dark: "暗色"
        case .light: "亮色"
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .dark: .dark
        case .light: .light
        }
    }

    var nsAppearance: NSAppearance? {
        switch self {
        case .system: nil
        case .dark: NSAppearance(named: .darkAqua)
        case .light: NSAppearance(named: .aqua)
        }
    }

    @MainActor
    func applyToApplication() {
        NSApplication.shared.appearance = nsAppearance
    }
}

@Observable @MainActor
final class LibraryStore: NSObject {
    static let shared = LibraryStore()
    nonisolated static let minimumCleanableSize: Int64 = 200 * 1_024 * 1_024

    var libraries: [LibraryRecord] = []
    var workDirectories: [URL] = []
    var workDirectoryStatuses: [URL: WorkDirectoryStatus] = [:]
    /// 目录级忽略集（标准化的绝对路径）。仅作用于自动发现与列表分层，
    /// 手动添加/拖入不受影响；绝不影响清理链路。
    var ignoredLibraryDirectories: [String] = UserDefaults.standard.stringArray(forKey: "ignoredLibraryDirectories") ?? [] {
        didSet {
            UserDefaults.standard.set(ignoredLibraryDirectories, forKey: "ignoredLibraryDirectories")
        }
    }
    var selectedID: LibraryRecord.ID?
    var selectedVolumeURL: URL?
    var libraryFilter: LibraryFilter = .waiting
    var inactivityFilter: InactivityFilter = .all
    var librarySort: LibrarySort = .sizeDescending
    var searchText = ""
    var appearanceMode = AppearanceMode(rawValue: UserDefaults.standard.integer(forKey: "appearanceMode")) ?? .dark {
        didSet {
            UserDefaults.standard.set(appearanceMode.rawValue, forKey: "appearanceMode")
        }
    }
    var batchSelectedIDs = Set<LibraryRecord.ID>()
    var cleanConfirmation: CleanConfirmation?
    var batchCleanConfirmation: BatchCleanConfirmation?
    var isBatchCleaning = false
    var isCleaning = false
    var isPreflighting = false
    var cleanupPreparationCompleted = 0
    var cleanupPreparationTotal = 0
    var batchCleanupCompleted = 0
    var batchCleanupTotal = 0
    var isDiscovering = false
    var discoveryError: String?
    var cleanupNotice: CleanupNotice?
    var cleanupSummary: CleanupSummary?
    var lowSpaceWarnings: [DiskSpaceWarning] = []
    var notificationsEnabled = UserDefaults.standard.object(forKey: "notificationsEnabled") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(notificationsEnabled, forKey: "notificationsEnabled")
            NotificationController.shared.requestAuthorizationIfNeeded(enabled: notificationsEnabled)
        }
    }
    var lowSpaceWarningGB = max(10, UserDefaults.standard.integer(forKey: "lowSpaceWarningGB")) {
        didSet {
            UserDefaults.standard.set(lowSpaceWarningGB, forKey: "lowSpaceWarningGB")
            evaluateLowSpace()
        }
    }
    var scheduledCheckFrequency = ScheduledCheckFrequency(
        rawValue: UserDefaults.standard.string(forKey: ScheduledCheckController.frequencyStorageKey) ?? ""
    ) ?? .off {
        didSet {
            UserDefaults.standard.set(scheduledCheckFrequency.rawValue, forKey: ScheduledCheckController.frequencyStorageKey)
            scheduledCheckController.restart()
        }
    }
    let cleanupHistory = CleanupHistoryStore()
    @ObservationIgnored private let bookmarks = SecurityScopedBookmarkManager()
    @ObservationIgnored private lazy var scheduledCheckController = ScheduledCheckController(store: self)
    @ObservationIgnored private let scanCache = ScanResultCache()
    @ObservationIgnored private var metadataQuery: NSMetadataQuery?
    @ObservationIgnored private var didBeginAutomaticDiscovery = false
    @ObservationIgnored private var discoveryRunID = UUID()
    @ObservationIgnored private var scanQueue: [ScanRequest] = []
    @ObservationIgnored private var activeScanIDs = Set<LibraryRecord.ID>()
    @ObservationIgnored private var noticeDismissalTask: Task<Void, Never>?
    @ObservationIgnored private var lastLowSpaceNotification: [URL: Date] = [:]
    @ObservationIgnored private var lastAutomaticLowSpaceScan: [URL: Date] = [:]
    @ObservationIgnored private var spaceMonitorTask: Task<Void, Never>?
    @ObservationIgnored private var isEvaluatingLowSpace = false
    @ObservationIgnored private var workDirectoryMonitor: WorkDirectoryMonitor?
    @ObservationIgnored private var volumeMountMonitor: VolumeMountMonitor?
    private let maximumConcurrentScans = 3

    private override init() {
        super.init()
        let restored = bookmarks.restore()
        // 卷身份绑定：同一路径当前挂载的若是另一块盘（UUID 不同），拒绝复活旧条目，
        // 防止把上一块盘的扫描元数据安到异盘同名资源库上。
        libraries = restored.compactMap { entry -> LibraryRecord? in
            let record = LibraryRecord(url: entry.metadata.url, restored: entry)
            if let saved = entry.metadata.volumeUUIDRaw,
               let current = record.volumeID,
               saved != current {
                return nil
            }
            return record
        }
        workDirectories = bookmarks.restoreWorkDirectories()
        selectedID = libraries.first?.id
        if UserDefaults.standard.object(forKey: "lowSpaceWarningGB") == nil { lowSpaceWarningGB = 100 }
    }

    var selectedLibrary: LibraryRecord? {
        if let selectedID,
           let selected = filteredLibraries.first(where: { $0.id == selectedID }) {
            return selected
        }
        return filteredLibraries.first
    }

    var waitingLibraries: [LibraryRecord] {
        libraries.filter { record in
            !record.isScanning && !record.isQueued
                && !isLibraryIgnored(record)
                && knownCleanableSize(for: record) >= Self.minimumCleanableSize
        }
    }

    var scanningLibraries: [LibraryRecord] {
        libraries.filter { $0.isScanning || $0.isQueued }
    }

    /// 还有排队或运行中的扫描（定时检查与 Shortcuts 意图据此等待静默）。
    var isScanPending: Bool {
        !scanQueue.isEmpty || !activeScanIDs.isEmpty
    }

    var skippedLibraries: [LibraryRecord] {
        libraries.filter { record in
            !record.isScanning && !record.isQueued
                && !isLibraryIgnored(record)
                && knownCleanableSize(for: record) < Self.minimumCleanableSize
        }
    }

    var ignoredLibraries: [LibraryRecord] {
        libraries.filter { record in
            !record.isScanning && !record.isQueued && isLibraryIgnored(record)
        }
    }

    var filteredLibraries: [LibraryRecord] {
        let base: [LibraryRecord]
        switch libraryFilter {
        case .waiting:
            base = selectedVolumeURL == nil ? waitingLibraries : waitingLibraries.filter { $0.volumeURL == selectedVolumeURL }
        case .scanning: base = scanningLibraries
        case .skipped: base = skippedLibraries
        case .ignored:
            base = selectedVolumeURL == nil ? ignoredLibraries : ignoredLibraries.filter { $0.volumeURL == selectedVolumeURL }
        }
        var result = base.filter(matchesInactivity)
        if !searchText.isEmpty {
            result = result.filter { $0.displayName.localizedStandardContains(searchText) }
        }
        switch librarySort {
        case .sizeDescending:
            result.sort { knownCleanableSize(for: $0) > knownCleanableSize(for: $1) }
        case .name:
            result.sort { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
        case .recentActivity:
            result.sort { ($0.lastActivity ?? .distantPast) > ($1.lastActivity ?? .distantPast) }
        }
        return result
    }

    var batchCleanableLibraries: [LibraryRecord] {
        filteredLibraries.filter {
            $0.scanResult != nil && $0.spaceToFree >= Self.minimumCleanableSize && !$0.isScanning
        }
    }

    func count(for filter: LibraryFilter) -> Int {
        switch filter {
        case .waiting: waitingLibraries.filter(matchesInactivity).count
        case .scanning: scanningLibraries.filter(matchesInactivity).count
        case .skipped: skippedLibraries.filter(matchesInactivity).count
        case .ignored: ignoredLibraries.filter(matchesInactivity).count
        }
    }

    func setInactivityFilter(_ filter: InactivityFilter) {
        inactivityFilter = filter
        batchSelectedIDs.removeAll()
        selectedID = filteredLibraries.first?.id
    }

    func setFilter(_ filter: LibraryFilter) {
        libraryFilter = filter
        if filter != .waiting { selectedVolumeURL = nil }
        selectedID = filteredLibraries.first?.id
    }

    func selectVolume(_ volumeURL: URL) {
        libraryFilter = .waiting
        selectedVolumeURL = selectedVolumeURL == volumeURL ? nil : volumeURL
        batchSelectedIDs.removeAll()
        selectedID = filteredLibraries.first?.id
        drainScanQueue()
    }

    func select(_ record: LibraryRecord) {
        if !matchesInactivity(record) { inactivityFilter = .all }
        libraryFilter = filter(for: record)
        selectedID = record.id
        drainScanQueue()
    }

    var areAllCleanableLibrariesSelected: Bool {
        let cleanableIDs = Set(batchCleanableLibraries.map(\.id))
        return !cleanableIDs.isEmpty && cleanableIDs.isSubset(of: batchSelectedIDs)
    }

    var selectedBatchSpace: Int64 {
        batchCleanableLibraries
            .filter { batchSelectedIDs.contains($0.id) }
            .reduce(0) { $0 + $1.spaceToFree }
    }

    var diskCleanupSummaries: [DiskCleanupSummary] {
        let allCleanable = waitingLibraries.filter(matchesInactivity).filter {
            $0.scanResult != nil && $0.spaceToFree >= Self.minimumCleanableSize && !$0.isScanning
        }
        let grouped = Dictionary(grouping: allCleanable, by: \.volumeURL)
        return grouped.map { volumeURL, records in
            DiskCleanupSummary(
                volumeURL: volumeURL,
                name: records.first?.volumeName ?? volumeURL.lastPathComponent,
                cleanableSize: records.reduce(0) { $0 + $1.spaceToFree },
                libraryCount: records.count
            )
        }
        .sorted { $0.cleanableSize > $1.cleanableSize }
    }

    func toggleBatchSelection(_ record: LibraryRecord) {
        guard record.scanResult != nil,
              record.spaceToFree >= Self.minimumCleanableSize,
              !record.isScanning else { return }
        if batchSelectedIDs.contains(record.id) {
            batchSelectedIDs.remove(record.id)
        } else {
            batchSelectedIDs.insert(record.id)
        }
    }

    func toggleSelectAllCleanableLibraries() {
        let cleanableIDs = Set(batchCleanableLibraries.map(\.id))
        if !cleanableIDs.isEmpty && cleanableIDs.isSubset(of: batchSelectedIDs) {
            batchSelectedIDs.subtract(cleanableIDs)
        } else {
            batchSelectedIDs.formUnion(cleanableIDs)
        }
    }

    func beginAutomaticDiscovery() {
        guard !didBeginAutomaticDiscovery else { return }
        didBeginAutomaticDiscovery = true
        NotificationController.shared.requestAuthorizationIfNeeded(enabled: notificationsEnabled)
        startSpaceMonitoring()
        if workDirectoryMonitor == nil { workDirectoryMonitor = WorkDirectoryMonitor(store: self) }
        workDirectoryMonitor?.updateWatched(paths: workDirectories.map(\.path))
        if volumeMountMonitor == nil { volumeMountMonitor = VolumeMountMonitor(store: self) }
        volumeMountMonitor?.start()
        scheduledCheckController.restart()

        for library in libraries where library.scanResult == nil && !library.isScanning {
            scan(library, force: false)
        }
        discoverLibraries()
    }

    func discoverLibraries() {
        discoveryRunID = UUID()
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
        Task { [weak self] in
            let candidates = await Task.detached(priority: .utility) {
                Self.validateCandidates(
                    libraryURLs,
                    source: source,
                    knownURLs: knownURLs,
                    ignoredDirectoryPaths: ignoredDirectories
                )
            }.value
            self?.applyValidatedCandidates(candidates, selectNewest: selectNewest, source: source)
        }
    }

    /// internal 以便 App 测试直接验证发现层忽略闸门。
    nonisolated static func validateCandidates(
        _ libraryURLs: [URL],
        source: DiscoverySource,
        knownURLs: Set<URL> = [],
        ignoredDirectoryPaths: [String] = []
    ) -> [URL] {
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

    nonisolated private static func findLibraries(
        in roots: [URL]
    ) -> (byRoot: [URL: [URL]], failedRoots: Set<URL>) {
        let fileManager = FileManager.default
        var byRoot: [URL: [URL]] = [:]
        var failedRoots = Set<URL>()
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
            for case let url as URL in enumerator where url.pathExtension.lowercased() == "fcpbundle" {
                if isLibraryDirectory(url, fileManager: fileManager) {
                    found.append(url.standardizedFileURL)
                }
                enumerator.skipDescendants()
            }
            if hadError.isSet { failedRoots.insert(standardizedRoot) }
            byRoot[standardizedRoot] = found.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
        }
        return (byRoot, failedRoots)
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

    func scan(_ record: LibraryRecord, preserveLastCleanup: Bool = false, force: Bool = true) {
        guard !record.isScanning else { return }
        if let index = scanQueue.firstIndex(where: { $0.record.id == record.id }) {
            scanQueue[index].force = scanQueue[index].force || force
            scanQueue[index].preserveLastCleanup = scanQueue[index].preserveLastCleanup || preserveLastCleanup
            drainScanQueue()
            return
        }
        record.isQueued = true
        scanQueue.append(ScanRequest(record: record, preserveLastCleanup: preserveLastCleanup, force: force))
        drainScanQueue()
    }

    private func drainScanQueue() {
        while activeScanIDs.count < maximumConcurrentScans, !scanQueue.isEmpty {
            let nextIndex = scanQueue.firstIndex { $0.record.id == selectedID } ?? scanQueue.startIndex
            let request = scanQueue.remove(at: nextIndex)
            startScan(request)
        }
    }

    private func startScan(_ request: ScanRequest) {
        let record = request.record
        guard !activeScanIDs.contains(record.id) else { return }
        activeScanIDs.insert(record.id)
        record.isQueued = false
        let control = ScanControl()
        record.scanControl = control
        record.isScanning = true
        record.usedCachedScan = false
        record.scanProgress = ScanProgress(files: 0, directories: 0, allocatedBytes: 0)
        record.scanError = nil
        if !request.preserveLastCleanup {
            record.lastCleanup = nil
            record.failedCleanupPlan = nil
            record.cleanupError = nil
        }
        record.inspectorReport = nil
        Task { [weak self, weak record] in
            guard let self, let record else { return }
            // 防止 App Nap 节流长扫描（笔记本合盖场景下吞吐会莫名劣化）
            let scanActivity = ProcessInfo.processInfo.beginActivity(
                options: [.userInitiatedAllowingIdleSystemSleep],
                reason: "FCP Cleaner 扫描资源库"
            )
            defer { ProcessInfo.processInfo.endActivity(scanActivity) }
            do {
                let result: LibraryScanResult
                if !request.force, let cached = await scanCache.loadIfCurrent(libraryURL: record.url) {
                    result = cached
                    record.usedCachedScan = true
                } else {
                    let progressCoalescer = ScanProgressCoalescer()
                    result = try await LibraryScanner().scan(
                        libraryURL: record.url,
                        control: control,
                        onProgress: { [weak record] progress in
                            if let merged = progressCoalescer.consume(progress) {
                                Task { @MainActor [weak record] in
                                    record?.scanProgress = merged
                                }
                            }
                        }
                    )
                    await scanCache.save(result)
                }
                record.scanResult = result
                record.lastScanned = Date()
                record.lastKnownTotalSize = record.scanResult?.totalAllocatedSize
                record.lastKnownCleanableSize = record.scanResult?.confirmedCleanableSize
                record.lastActivity = LibraryRecord.activityDate(for: record.url)
                record.lastAccessibleAt = Date()
                LibrarySizeTrend.record(
                    libraryURL: record.url,
                    totalAllocatedSize: result.totalAllocatedSize,
                    cleanableSize: result.confirmedCleanableSize
                )
                saveRecents()
                evaluateLowSpace()
                if request.preserveLastCleanup, record.lastCleanup != nil {
                    record.cleanupAfterSize = record.scanResult?.totalAllocatedSize
                }
                record.pendingFreedSize = 0
            } catch is CancellationError {
                record.scanError = nil
            } catch {
                record.scanError = error.localizedDescription
                record.scanResult = nil
                record.pendingFreedSize = 0
            }
            record.isScanning = false
            record.scanControl = nil
            activeScanIDs.remove(record.id)
            reconcileFilteredLibraries()
            drainScanQueue()
        }
    }

    func cancelScan(_ record: LibraryRecord) {
        if let index = scanQueue.firstIndex(where: { $0.record.id == record.id }) {
            scanQueue.remove(at: index)
            record.isQueued = false
            reconcileFilteredLibraries()
            return
        }
        record.scanControl?.cancel()
    }

    func inspect(_ record: LibraryRecord) {
        guard let scanResult = record.scanResult, !record.isInspecting else { return }
        record.isInspecting = true
        Task { [weak record] in
            guard let record else { return }
            do {
                record.inspectorReport = try await LibraryInspector().inspect(scanResult: scanResult)
            } catch is CancellationError {
                record.inspectorReport = nil
            } catch {
                record.scanError = error.localizedDescription
            }
            record.isInspecting = false
        }
    }

    func requestClean(_ record: LibraryRecord) {
        guard !isPreflighting, !isCleaning else { return }
        guard let result = record.scanResult,
              record.spaceToFree >= Self.minimumCleanableSize else { return }
        do {
            let plan = try CleanupPlan(scanResult: result, categories: Set(CacheCategory.cleanableCases))
            guard !plan.entries.isEmpty else { return }
            preflight(record: record, plan: plan, isRetry: false)
        } catch {
            showPreflightFailure(error, record: record)
        }
    }

    var canRescanSelectedLibrary: Bool {
        guard let selected = selectedLibrary else { return false }
        return !selected.isScanning && !selected.isQueued
    }

    var canRequestCleanupForSelection: Bool {
        guard !isPreflighting, !isCleaning, !isBatchCleaning else { return false }
        if !batchSelectedIDs.isEmpty { return true }
        guard let selected = selectedLibrary else { return false }
        return selected.scanResult != nil
            && selected.spaceToFree >= Self.minimumCleanableSize
            && !selected.isScanning
    }

    var hasSelectableBatchCandidates: Bool {
        !batchCleanableLibraries.isEmpty && !isPreflighting && !isCleaning && !isBatchCleaning
    }

    func requestRetry(_ record: LibraryRecord) {
        guard !isPreflighting, !isCleaning else { return }
        guard let plan = record.failedCleanupPlan else { return }
        preflight(record: record, plan: plan, isRetry: true)
    }

    func requestBatchClean() {
        guard !isPreflighting, !isCleaning else { return }
        isPreflighting = true
        cleanupPreparationCompleted = 0
        cleanupPreparationTotal = batchSelectedIDs.count
        var entries: [BatchCleanupEntry] = []
        for record in libraries where batchSelectedIDs.contains(record.id) {
            guard let result = record.scanResult,
                  record.spaceToFree >= Self.minimumCleanableSize else { continue }
            do {
                let plan = try CleanupPlan(scanResult: result, categories: Set(CacheCategory.cleanableCases))
                if !plan.entries.isEmpty {
                    entries.append(BatchCleanupEntry(record: record, plan: plan))
                }
            } catch {
                showPreflightFailure(error, record: record)
            }
        }
        guard !entries.isEmpty else {
            isPreflighting = false
            cleanupPreparationTotal = 0
            return
        }
        cleanupPreparationTotal = entries.count
        Task {
            // 移动大目录期间避免系统休眠/节流
            let batchActivity = ProcessInfo.processInfo.beginActivity(
                options: [.userInitiatedAllowingIdleSystemSleep],
                reason: "FCP Cleaner 批量预检与清理"
            )
            defer { ProcessInfo.processInfo.endActivity(batchActivity) }
            var failure: (Error, LibraryRecord)?
            for entry in entries {
                do {
                    try await CleanupEngine().preflight(plan: entry.plan, verifyContents: false)
                } catch {
                    failure = (error, entry.record)
                    break
                }
                cleanupPreparationCompleted += 1
            }
            if let failure {
                showPreflightFailure(failure.0, record: failure.1)
            } else {
                batchCleanConfirmation = BatchCleanConfirmation(entries: entries)
            }
            isPreflighting = false
            cleanupPreparationCompleted = 0
            cleanupPreparationTotal = 0
        }
    }

    private func preflight(record: LibraryRecord, plan: CleanupPlan, isRetry: Bool) {
        isPreflighting = true
        Task {
            do {
                cleanupPreparationCompleted = 0
                cleanupPreparationTotal = 1
                try await CleanupEngine().preflight(plan: plan, verifyContents: false)
                cleanupPreparationCompleted = 1
                cleanConfirmation = CleanConfirmation(record: record, plan: plan, isRetry: isRetry)
            } catch {
                showPreflightFailure(error, record: record)
            }
            isPreflighting = false
            cleanupPreparationCompleted = 0
            cleanupPreparationTotal = 0
        }
    }

    private func showPreflightFailure(_ error: Error, record: LibraryRecord?) {
        let message = error.localizedDescription
        record?.cleanupError = message
        showCleanupNotice(CleanupNotice(
            title: "清理前检查未通过",
            libraryCount: record == nil ? 0 : 1,
            freedSize: 0,
            cleanedItemCount: 0,
            categories: [],
            errorCount: 1,
            errorMessage: message
        ))
    }

    func performConfirmedBatchCleanup(_ confirmation: BatchCleanConfirmation) {
        guard !isCleaning else { return }
        batchCleanConfirmation = nil
        isBatchCleaning = true
        isCleaning = true
        batchCleanupCompleted = 0
        batchCleanupTotal = confirmation.entries.count
        Task {
            let batchStart = ContinuousClock.now
            var freedSize: Int64 = 0
            var cleanedItemCount = 0
            var errorCount = 0
            var firstErrorMessage: String?
            var categories = Set<CacheCategory>()
            var recordsToRescan: [LibraryRecord] = []
            var summaryLibraries: [CleanupSummaryLibrary] = []
            for entry in confirmation.entries {
                let record = entry.record
                record.cleanupBeforeSize = record.scanResult?.totalAllocatedSize
                record.cleanupAfterSize = nil
                do {
                    let start = ContinuousClock.now
                    let result = try await CleanupEngine().execute(plan: entry.plan)
                    let elapsed = ContinuousClock.now - start
                    CleanupThroughputStore.record(volumeID: entry.record.volumeID, bytes: result.freedAllocatedSize, seconds: Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18)
                    record.lastCleanup = result
                    applyImmediateCleanupDelta(record, freed: result.freedAllocatedSize)
                    cleanupHistory.append(libraryName: record.displayName, libraryURL: record.url, plan: entry.plan, result: result)
                    record.failedCleanupPlan = result.errors.isEmpty
                        ? nil
                        : entry.plan.retryingItemsNotCompleted(in: result)
                    freedSize += result.freedAllocatedSize
                    cleanedItemCount += result.movedToTrash.count
                    errorCount += result.errors.count
                    firstErrorMessage = firstErrorMessage ?? result.errors.first?.localizedDescription
                    categories.formUnion(entry.plan.entries.map(\.item.category))
                    record.cleanupError = result.errors.isEmpty
                        ? nil
                        : result.errors.map(\.localizedDescription).joined(separator: "\n")
                    recordsToRescan.append(record)
                    summaryLibraries.append(CleanupSummaryLibrary(
                        name: record.displayName,
                        url: record.url,
                        freedSize: result.freedAllocatedSize,
                        itemCount: result.movedToTrash.count,
                        errorCount: result.errors.count,
                        errorMessage: result.errors.first?.localizedDescription,
                        succeeded: result.errors.isEmpty
                    ))
                } catch {
                    errorCount += 1
                    firstErrorMessage = firstErrorMessage ?? error.localizedDescription
                    record.failedCleanupPlan = entry.plan
                    record.cleanupError = error.localizedDescription
                    cleanupHistory.appendFailure(libraryName: record.displayName, libraryURL: record.url, plan: entry.plan, error: error)
                    summaryLibraries.append(CleanupSummaryLibrary(
                        name: record.displayName,
                        url: record.url,
                        freedSize: 0,
                        itemCount: 0,
                        errorCount: 1,
                        errorMessage: error.localizedDescription,
                        succeeded: false
                    ))
                }
                batchCleanupCompleted += 1
            }
            let batchElapsed = ContinuousClock.now - batchStart
            let batchSeconds = Double(batchElapsed.components.seconds) + Double(batchElapsed.components.attoseconds) / 1e18
            batchSelectedIDs.removeAll()
            isBatchCleaning = false
            isCleaning = false
            batchCleanupCompleted = 0
            batchCleanupTotal = 0
            for record in recordsToRescan {
                scan(record, preserveLastCleanup: true, force: true)
            }
            showCleanupNotice(CleanupNotice(
                title: "批量清理完成",
                libraryCount: confirmation.entries.count,
                freedSize: freedSize,
                cleanedItemCount: cleanedItemCount,
                categories: categories,
                errorCount: errorCount,
                errorMessage: firstErrorMessage
            ))
            cleanupSummary = CleanupSummary(
                title: "批量清理完成",
                libraryCount: confirmation.entries.count,
                totalFreedSize: freedSize,
                totalItemCount: cleanedItemCount,
                categories: categories,
                errorCount: errorCount,
                errorMessage: firstErrorMessage,
                elapsedSeconds: batchSeconds,
                libraries: summaryLibraries
            )
            NotificationController.shared.cleanupFinished(
                freedSize: freedSize,
                libraryCount: confirmation.entries.count,
                errorCount: errorCount,
                enabled: notificationsEnabled
            )
        }
    }

    func performConfirmedCleanup(_ confirmation: CleanConfirmation) {
        guard !isCleaning else { return }
        cleanConfirmation = nil
        isCleaning = true
        let record = confirmation.record
        record.cleanupBeforeSize = record.scanResult?.totalAllocatedSize
        record.cleanupAfterSize = nil
        Task {
            // 单库清理同样不可被节流打断
            let cleanActivity = ProcessInfo.processInfo.beginActivity(
                options: [.userInitiatedAllowingIdleSystemSleep],
                reason: "FCP Cleaner 清理资源库"
            )
            defer { ProcessInfo.processInfo.endActivity(cleanActivity) }
            do {
                let start = ContinuousClock.now
                let result = try await CleanupEngine().execute(plan: confirmation.plan)
                let elapsed = ContinuousClock.now - start
                CleanupThroughputStore.record(volumeID: record.volumeID, bytes: result.freedAllocatedSize, seconds: Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18)
                record.lastCleanup = result
                applyImmediateCleanupDelta(record, freed: result.freedAllocatedSize)
                cleanupHistory.append(libraryName: record.displayName, libraryURL: record.url, plan: confirmation.plan, result: result)
                record.failedCleanupPlan = result.errors.isEmpty
                    ? nil
                    : confirmation.plan.retryingItemsNotCompleted(in: result)
                showCleanupNotice(CleanupNotice(
                    title: record.displayName,
                    libraryCount: 1,
                    freedSize: result.freedAllocatedSize,
                    cleanedItemCount: result.movedToTrash.count,
                    categories: Set(confirmation.plan.entries.map(\.item.category)),
                    errorCount: result.errors.count,
                    errorMessage: result.errors.first?.localizedDescription
                ))
                record.cleanupError = result.errors.isEmpty
                    ? nil
                    : result.errors.map(\.localizedDescription).joined(separator: "\n")
                scan(record, preserveLastCleanup: true, force: true)
                NotificationController.shared.cleanupFinished(
                    freedSize: result.freedAllocatedSize,
                    libraryCount: 1,
                    errorCount: result.errors.count,
                    enabled: notificationsEnabled
                )
            } catch {
                record.cleanupError = error.localizedDescription
                record.failedCleanupPlan = confirmation.plan
                cleanupHistory.appendFailure(libraryName: record.displayName, libraryURL: record.url, plan: confirmation.plan, error: error)
                showCleanupNotice(CleanupNotice(
                    title: record.displayName,
                    libraryCount: 1,
                    freedSize: 0,
                    cleanedItemCount: 0,
                    categories: Set(confirmation.plan.entries.map(\.item.category)),
                    errorCount: 1,
                    errorMessage: error.localizedDescription
                ))
                NotificationController.shared.cleanupFinished(
                    freedSize: 0,
                    libraryCount: 1,
                    errorCount: 1,
                    enabled: notificationsEnabled
                )
            }
            isCleaning = false
        }
    }

    func remove(_ records: [LibraryRecord]) {
        let ids = Set(records.map(\.id))
        for record in records {
            if let index = scanQueue.firstIndex(where: { $0.record.id == record.id }) {
                scanQueue.remove(at: index)
                record.isQueued = false
            }
            record.scanControl?.cancel()
        }
        libraries.removeAll { ids.contains($0.id) }
        batchSelectedIDs.subtract(ids)
        selectedID = nil
        reconcileFilteredLibraries()
        saveRecents()
    }

    private func reconcileFilteredLibraries() {
        let waitingIDs = Set(waitingLibraries.map(\.id))
        batchSelectedIDs.formIntersection(waitingIDs)
        let filteredIDs = Set(filteredLibraries.map(\.id))
        if let selectedID, filteredIDs.contains(selectedID) { return }
        selectedID = filteredLibraries.first?.id
    }

    func knownCleanableSize(for record: LibraryRecord) -> Int64 {
        if record.scanResult != nil { return record.spaceToFree }
        return record.lastKnownCleanableSize ?? 0
    }

    /// 该库相对约一周前的总体积增长；采样不足返回 nil。
    func weeklyGrowth(for record: LibraryRecord) -> Int64? {
        LibrarySizeTrend.weeklyGrowth(samples: LibrarySizeTrend.samples(for: record.url))
    }

    /// 待清理列表中周增长最大者（须为正增长），供列表突出显示。
    var fastestGrowingLibraryID: LibraryRecord.ID? {
        var bestID: LibraryRecord.ID?
        var bestGrowth: Int64 = 0
        for record in waitingLibraries {
            guard let growth = weeklyGrowth(for: record), growth > bestGrowth else { continue }
            bestGrowth = growth
            bestID = record.id
        }
        return bestID
    }

    func effectiveCleanableSize(for record: LibraryRecord) -> Int64 {
        let base = knownCleanableSize(for: record)
        let penalty = record.scanResult != nil ? record.pendingFreedSize : 0
        return max(0, base - penalty)
    }

    func estimatedCleanupDuration(forBytes bytes: Int64, volumeID: String?) -> Double? {
        guard let volumeID,
              let bytesPerSecond = CleanupThroughputStore.averageBytesPerSecond(volumeID: volumeID),
              bytesPerSecond > 0 else { return nil }
        return Double(bytes) / bytesPerSecond
    }

    /// Batch ETA sums per-entry estimates; nil when any involved volume lacks history.
    func estimatedBatchCleanupDuration(entries: [(bytes: Int64, volumeID: String?)]) -> Double? {
        guard !entries.isEmpty else { return nil }
        var total = 0.0
        for entry in entries {
            guard let duration = estimatedCleanupDuration(forBytes: entry.bytes, volumeID: entry.volumeID) else {
                return nil
            }
            total += duration
        }
        return total
    }

    private func applyImmediateCleanupDelta(_ record: LibraryRecord, freed: Int64) {
        guard freed > 0 else { return }
        record.pendingFreedSize += freed
        let known = record.lastKnownCleanableSize ?? knownCleanableSize(for: record)
        record.lastKnownCleanableSize = max(0, known - freed)
        if let total = record.lastKnownTotalSize {
            record.lastKnownTotalSize = max(0, total - freed)
        }
        saveRecents()
    }

    private func matchesInactivity(_ record: LibraryRecord) -> Bool {
        guard inactivityFilter != .all else { return true }
        guard let lastActivity = record.lastActivity else { return true }
        let cutoff = Calendar.current.date(byAdding: .day, value: -inactivityFilter.rawValue, to: Date()) ?? Date()
        return lastActivity <= cutoff
    }

    // MARK: 忽略与稍后（仅作用于发现/列表分层，绝不进入清理链路）

    func isLibraryIgnored(_ record: LibraryRecord) -> Bool {
        LibraryIgnoreRules.isSnoozed(until: record.ignoredUntil)
            || LibraryIgnoreRules.isInsideIgnoredDirectory(recordPath: record.url.path, directoryPaths: ignoredLibraryDirectories)
    }

    func isDirectoryIgnored(_ url: URL) -> Bool {
        ignoredLibraryDirectories.contains(url.standardizedFileURL.path)
    }

    /// 行操作「7 天内不再提醒」：到期后自动回到原分层。
    func snoozeLibrary(_ record: LibraryRecord, days: Int = LibraryIgnoreRules.defaultSnoozeDays) {
        record.ignoredUntil = Calendar.current.date(byAdding: .day, value: days, to: Date())
        reconcileFilteredLibraries()
        saveRecents()
    }

    func resumeLibrary(_ record: LibraryRecord) {
        record.ignoredUntil = nil
        // 处于目录级忽略中的库被显式恢复时，连同所在目录一起解除，
        // 否则该库会立即被目录规则重新吞回"已忽略"。
        if let directory = ignoredLibraryDirectories.first(where: {
            LibraryIgnoreRules.isInsideIgnoredDirectory(recordPath: record.url.path, directoryPaths: [$0])
        }) {
            ignoredLibraryDirectories.removeAll { $0 == directory }
        }
        reconcileFilteredLibraries()
        saveRecents()
    }

    func ignoreDirectory(_ url: URL) {
        let path = url.standardizedFileURL.path
        guard !ignoredLibraryDirectories.contains(path) else { return }
        ignoredLibraryDirectories.append(path)
        reconcileFilteredLibraries()
        saveRecents()
    }

    func resumeDirectory(_ path: String) {
        ignoredLibraryDirectories.removeAll { $0 == path }
        reconcileFilteredLibraries()
        saveRecents()
    }

    /// 扫描健康度：让"自动扫描是否真正完成"不依赖日志即可判断。
    var scanHealthSummary: ScanHealthSummary {
        let failed = libraries.filter { $0.scanError != nil }.map(\.displayName)
        return ScanHealthSummary(
            total: libraries.count,
            scanned: libraries.count(where: { $0.scanResult != nil }),
            cacheReused: libraries.count(where: { $0.usedCachedScan }),
            failed: failed,
            neverScanned: libraries.count(where: { $0.scanResult == nil && $0.scanError == nil && !$0.isScanning && !$0.isQueued })
        )
    }

    var totalCleanableSize: Int64 {
        libraries.reduce(Int64(0)) { partial, record in
            let size = effectiveCleanableSize(for: record)
            return size >= Self.minimumCleanableSize ? partial + size : partial
        }
    }

    func showMainWindow() {
        NSApplication.shared.activate(ignoringOtherApps: true)
        if let window = NSApplication.shared.windows.first(where: { $0.title == "FCP Cleaner" || $0.canBecomeMain }) {
            window.makeKeyAndOrderFront(nil)
        }
    }

    func requestMenuBarCleanup() {
        guard !isPreflighting, !isCleaning else { return }
        libraryFilter = .waiting
        inactivityFilter = .all
        selectedVolumeURL = nil
        let records = waitingLibraries.filter {
            $0.scanResult != nil && $0.spaceToFree >= Self.minimumCleanableSize && !$0.isScanning
        }
        guard !records.isEmpty else {
            showMainWindow()
            return
        }
        batchSelectedIDs = Set(records.map(\.id))
        selectedID = records.first?.id
        showMainWindow()
        requestBatchClean()
    }

    /// 卷容量探测全部在后台执行——网络卷上这类调用可能阻塞数秒，绝不能上主线程。
    func evaluateLowSpace() {
        guard !isEvaluatingLowSpace else { return }
        isEvaluatingLowSpace = true
        let threshold = Int64(lowSpaceWarningGB) * 1_024 * 1_024 * 1_024
        let volumeURLs = Array(Set(libraries.map(\.volumeURL)))
        let nameByVolume = Dictionary(libraries.map { ($0.volumeURL, $0.volumeName) }, uniquingKeysWith: { first, _ in first })
        let cleanableByVolume = Dictionary(grouping: libraries, by: \.volumeURL)
            .mapValues { $0.reduce(Int64(0)) { $0 + $1.spaceToFree } }
        Task { [weak self] in
            let lowSpaces = await Task.detached(priority: .utility) {
                Self.probeVolumeAvailability(volumeURLs, threshold: threshold)
            }.value
            guard let self else { return }
            isEvaluatingLowSpace = false
            applyLowSpaceResults(
                lowSpaces,
                nameByVolume: nameByVolume,
                cleanableByVolume: cleanableByVolume
            )
        }
    }

    nonisolated private static func probeVolumeAvailability(
        _ volumeURLs: [URL],
        threshold: Int64
    ) -> [(volumeURL: URL, availableSize: Int64)] {
        volumeURLs.compactMap { volumeURL in
            guard let values = try? volumeURL.resourceValues(forKeys: [
                .volumeAvailableCapacityForImportantUsageKey,
                .volumeAvailableCapacityKey,
            ]),
                let available = values.volumeAvailableCapacityForImportantUsage
                    ?? values.volumeAvailableCapacity.map(Int64.init),
                available < threshold else { return nil }
            return (volumeURL, available)
        }
    }

    private func applyLowSpaceResults(
        _ lowSpaces: [(volumeURL: URL, availableSize: Int64)],
        nameByVolume: [URL: String],
        cleanableByVolume: [URL: Int64]
    ) {
        var warnings: [DiskSpaceWarning] = []
        for item in lowSpaces {
            let name = nameByVolume[item.volumeURL] ?? item.volumeURL.lastPathComponent
            let cleanable = cleanableByVolume[item.volumeURL] ?? 0
            warnings.append(DiskSpaceWarning(
                volumeURL: item.volumeURL,
                name: name,
                availableSize: item.availableSize,
                cleanableSize: cleanable
            ))
            let lastNotification = lastLowSpaceNotification[item.volumeURL] ?? .distantPast
            if cleanable >= Self.minimumCleanableSize, Date().timeIntervalSince(lastNotification) > 86_400 {
                NotificationController.shared.lowSpace(
                    volumeName: name,
                    availableSize: item.availableSize,
                    cleanableSize: cleanable,
                    enabled: notificationsEnabled
                )
                lastLowSpaceNotification[item.volumeURL] = Date()
            }
        }
        lowSpaceWarnings = warnings.sorted { $0.availableSize < $1.availableSize }
    }

    private func startSpaceMonitoring() {
        guard spaceMonitorTask == nil else { return }
        spaceMonitorTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(900))
                guard !Task.isCancelled, let self else { return }
                evaluateLowSpace()
                let now = Date()
                for warning in lowSpaceWarnings {
                    let lastScan = lastAutomaticLowSpaceScan[warning.volumeURL] ?? .distantPast
                    guard now.timeIntervalSince(lastScan) >= 6 * 60 * 60 else { continue }
                    lastAutomaticLowSpaceScan[warning.volumeURL] = now
                    for record in libraries where record.volumeURL == warning.volumeURL {
                        scan(record, force: false)
                    }
                }
            }
        }
    }

    /// 定时检查：自动发现 + 全库增量扫描 + 完成通知。
    /// 产品红线：本路径绝不创建清理计划、绝不调用 CleanupEngine。
    func runScheduledCheck() async {
        discoverLibraries()
        for record in libraries {
            scan(record, force: false)
        }
        // 等待扫描队列静默（上限 15 分钟），扫描本身已在后台并发执行
        let deadline = Date().addingTimeInterval(900)
        while (!scanQueue.isEmpty || !activeScanIDs.isEmpty), Date() < deadline {
            try? await Task.sleep(for: .seconds(1))
        }
        evaluateLowSpace()
        let cleanableRecords = libraries.filter { effectiveCleanableSize(for: $0) >= Self.minimumCleanableSize }
        let total = cleanableRecords.reduce(Int64(0)) { $0 + effectiveCleanableSize(for: $1) }
        NotificationController.shared.scheduledCheckFinished(
            cleanableSize: total,
            libraryCount: cleanableRecords.count,
            enabled: notificationsEnabled
        )
    }

    private func filter(for record: LibraryRecord) -> LibraryFilter {
        if record.isScanning || record.isQueued { return .scanning }
        if isLibraryIgnored(record) { return .ignored }
        return knownCleanableSize(for: record) >= Self.minimumCleanableSize ? .waiting : .skipped
    }

    func dismissCleanupNotice() {
        noticeDismissalTask?.cancel()
        cleanupNotice = nil
    }

    private func showCleanupNotice(_ notice: CleanupNotice) {
        noticeDismissalTask?.cancel()
        cleanupNotice = notice
        noticeDismissalTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(8))
            guard !Task.isCancelled, self?.cleanupNotice?.id == notice.id else { return }
            self?.cleanupNotice = nil
        }
    }

    func diagnoseVolumeAccess(_ record: LibraryRecord) {
        guard !record.isDiagnosingVolume else { return }
        record.isDiagnosingVolume = true
        let url = record.url
        Task { [weak record] in
            let report = await Task.detached(priority: .utility) {
                Self.probeVolumeAccess(url)
            }.value
            guard let record else { return }
            record.accessReport = report
            if report.mounted { record.lastAccessibleAt = Date() }
            record.isDiagnosingVolume = false
        }
    }

    nonisolated private static func probeVolumeAccess(_ url: URL) -> VolumeAccessReport {
        var isDirectory: ObjCBool = false
        let mounted = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
        let writable = mounted && FileManager.default.isWritableFile(atPath: url.path)
        let volumeName = try? url.resourceValues(forKeys: [.volumeNameKey]).volumeName
        return VolumeAccessReport(
            libraryURL: url,
            volumeName: volumeName,
            mounted: mounted,
            writable: writable,
            checkedAt: Date()
        )
    }

    /// 外置卷重新挂载：库内该卷资源库入队增量扫描（有效缓存直接复用），
    /// 工作目录所在卷重连后重新发现一次。判断本身是纯路径匹配，无主线程 I/O。
    func handleVolumeMount(volumeURL: URL) {
        let volumePath = volumeURL.standardizedFileURL.path
        let affected = libraries.filter {
            VolumeMountRules.residesOnVolume(recordPath: $0.url.path, volumePath: volumePath)
        }
        let workDirsOnVolume = workDirectories.contains {
            VolumeMountRules.residesOnVolume(recordPath: $0.path, volumePath: volumePath)
        }
        guard !affected.isEmpty || workDirsOnVolume else { return }
        for record in affected {
            record.lastAccessibleAt = Date()
            record.accessReport = nil
            scan(record, force: false)
        }
        if workDirsOnVolume {
            discoverLibraries()
        }
    }

    /// 外置卷卸载：保留记录与 lastKnownCleanableSize 兜底显示；取消排队/运行中的扫描，
    /// 避免离线扫描产生"卷已离线"噪声错误；诊断状态联动标为已断开。
    func handleVolumeUnmount(volumeURL: URL) {
        let volumePath = volumeURL.standardizedFileURL.path
        let affected = libraries.filter {
            VolumeMountRules.residesOnVolume(recordPath: $0.url.path, volumePath: volumePath)
        }
        guard !affected.isEmpty else { return }
        for record in affected {
            if let index = scanQueue.firstIndex(where: { $0.record.id == record.id }) {
                scanQueue.remove(at: index)
                record.isQueued = false
            }
            record.scanControl?.cancel()
            record.accessReport = VolumeAccessReport(
                libraryURL: record.url,
                volumeName: record.volumeName,
                mounted: false,
                writable: false,
                checkedAt: Date()
            )
        }
        reconcileFilteredLibraries()
        saveRecents()
    }

    /// Re-mints the security-scoped bookmark by having the user pick the same
    /// package again — the standard remedy after a scope went stale.
    func reauthorizeLibraryAccess(_ record: LibraryRecord) {
        let panel = NSOpenPanel()
        panel.title = "重新授权资源库访问"
        panel.prompt = "重新授权"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [UTType(importedAs: "com.apple.finalcutprolibrary")]
        panel.directoryURL = record.url.deletingLastPathComponent()
        guard panel.runModal() == .OK, let picked = panel.urls.first else { return }
        guard picked.standardizedFileURL == record.url.standardizedFileURL else {
            showCleanupNotice(CleanupNotice(
                title: "重新授权未完成",
                libraryCount: 1,
                freedSize: 0,
                cleanedItemCount: 0,
                categories: [],
                errorCount: 1,
                errorMessage: "所选的不是原资源库（\(record.displayName)），请重新选择同一个 .fcpbundle"
            ))
            return
        }
        bookmarks.save(
            currentRecentsMetadata(),
            replacementURLs: [record.url.standardizedFileURL: picked.standardizedFileURL]
        )
        record.accessReport = Self.probeVolumeAccess(record.url)
        if record.accessReport?.mounted == true { record.lastAccessibleAt = Date() }
        scan(record, force: false)
    }

    private func saveRecents() {
        bookmarks.save(currentRecentsMetadata())
    }

    private func currentRecentsMetadata() -> [RecentLibraryMetadata] {
        libraries.map {
            RecentLibraryMetadata(
                url: $0.url,
                lastScanned: $0.lastScanned,
                totalAllocatedSize: $0.lastKnownTotalSize,
                cleanableSize: $0.lastKnownCleanableSize,
                lastActivity: $0.lastActivity,
                discoverySourceRaw: $0.discoverySource?.rawValue,
                volumeUUIDRaw: $0.volumeID,
                ignoredUntil: $0.ignoredUntil
            )
        }
    }
}

@MainActor
private struct ScanRequest {
    let record: LibraryRecord
    var preserveLastCleanup: Bool
    var force: Bool
}

struct CleanupNotice: Identifiable {
    let id = UUID()
    let title: String
    let libraryCount: Int
    let freedSize: Int64
    let cleanedItemCount: Int
    let categories: Set<CacheCategory>
    let errorCount: Int
    let errorMessage: String?
}

struct DiskCleanupSummary: Identifiable {
    var id: URL { volumeURL }
    let volumeURL: URL
    let name: String
    let cleanableSize: Int64
    let libraryCount: Int
}

struct ScanHealthSummary: Sendable {
    let total: Int
    let scanned: Int
    let cacheReused: Int
    let failed: [String]
    let neverScanned: Int
}

struct WorkDirectoryStatus: Sendable {
    let discoveredCount: Int
    let failed: Bool
    let updatedAt: Date
}

struct DiskSpaceWarning: Identifiable {
    var id: URL { volumeURL }
    let volumeURL: URL
    let name: String
    let availableSize: Int64
    let cleanableSize: Int64
}

struct VolumeAccessReport: Identifiable {
    var id: URL { libraryURL }
    let libraryURL: URL
    let volumeName: String?
    let mounted: Bool
    let writable: Bool
    let checkedAt: Date
}

@MainActor
final class CleanConfirmation: Identifiable {
    let id = UUID()
    let record: LibraryRecord
    let plan: CleanupPlan
    let isRetry: Bool

    init(record: LibraryRecord, plan: CleanupPlan, isRetry: Bool = false) {
        self.record = record
        self.plan = plan
        self.isRetry = isRetry
    }
}

@MainActor
struct BatchCleanupEntry {
    let record: LibraryRecord
    let plan: CleanupPlan
}

@MainActor
final class BatchCleanConfirmation: Identifiable {
    let id = UUID()
    let entries: [BatchCleanupEntry]

    init(entries: [BatchCleanupEntry]) {
        self.entries = entries
    }

    var totalSpaceToFree: Int64 {
        entries.reduce(0) { $0 + $1.plan.spaceToFree }
    }
}
